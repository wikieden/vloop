#!/usr/bin/env bash
# vloop adapter layer — multi-backend headless invocation + output normalization.
# bash 3.2 compatible (macOS default). Requires: jq, python3.
# Usage:
#   adapter.sh probe                      -> writes .vloop/backends.json
#   adapter.sh invoke <role> <prompt_file> <outdir>
#     role = executor | judge | planner  (read from .vloop/loop.json)
#     Produces <outdir>/out.stdout, out.stderr, out.json (normalized).

set -u
VLOOP_DIR="${VLOOP_DIR:-.vloop}"
CONFIG="$VLOOP_DIR/loop.json"

die() { echo "vloop-adapter: $*" >&2; exit 1; }

# Portable timeout: GNU timeout > gtimeout > perl alarm fallback.
run_with_timeout() {
  secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"
  fi
}

cfg() { jq -r "$1" "$CONFIG"; }

# ---------------------------------------------------------------- probe
probe() {
  [ -f "$CONFIG" ] || die "no $CONFIG — run setup first"
  out="$VLOOP_DIR/backends.json"
  tmp="$out.tmp.$$"
  echo '{}' > "$tmp"
  for role in executor judge planner; do
    b=$(cfg ".backends.$role.backend // empty"); [ -n "$b" ] || continue
    command -v "$b" >/dev/null 2>&1 || die "backend '$b' (role $role) not on PATH"
    ver=$("$b" --version 2>/dev/null | head -1)
    # flag probe: 'argument missing' error => flag exists even if hidden; 'unknown option' => absent
    case "$b" in
      claude)
        cap='{"json_output":true,"schema_output":true,"budget_cap":true,"turn_cap":true,"resume":true,"readonly_mode":"--permission-mode plan","danger_flag":"--dangerously-skip-permissions"}' ;;
      codex)
        cap='{"json_output":"jsonl","schema_output":true,"budget_cap":false,"turn_cap":false,"resume":true,"readonly_mode":"-s read-only","danger_flag":"--dangerously-bypass-approvals-and-sandbox"}' ;;
      opencode)
        cap='{"json_output":true,"schema_output":false,"budget_cap":false,"turn_cap":false,"resume":true,"readonly_mode":"--agent plan","danger_flag":"--auto"}' ;;
      gemini)
        cap='{"json_output":true,"schema_output":false,"budget_cap":false,"turn_cap":"exit53","resume":true,"readonly_mode":"--approval-mode plan","danger_flag":"--yolo"}' ;;
      aider)
        cap='{"json_output":false,"schema_output":false,"budget_cap":false,"turn_cap":false,"resume":false,"readonly_mode":null,"danger_flag":"--yes-always"}' ;;
      *) cap='{"json_output":false}' ;;
    esac
    jq --arg b "$b" --arg v "$ver" --argjson c "$cap" '.[$b] = ($c + {version:$v})' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  done
  mv "$tmp" "$out"
  echo "probe ok -> $out"
  jq . "$out"
}

# ---------------------------------------------------------------- invoke
invoke() {
  role="$1"; prompt_file="$2"; outdir="$3"
  [ -f "$CONFIG" ] || die "no $CONFIG"
  [ -f "$prompt_file" ] || die "prompt file missing: $prompt_file"
  mkdir -p "$outdir"
  backend=$(cfg ".backends.$role.backend")
  model=$(cfg ".backends.$role.model // empty")
  ro=$(cfg ".backends.$role.readonly // false")
  danger=$(cfg ".backends.$role.danger // false")
  tmo=$(cfg ".caps.iteration_timeout_s // 1800")
  so="$outdir/out.stdout"; se="$outdir/out.stderr"
  start_ts=$(date +%s)

  case "$backend" in
    claude)
      set -- -p --output-format json --max-turns 40
      if [ "$ro" = "true" ]; then set -- "$@" --permission-mode plan
      else set -- "$@" --permission-mode acceptEdits; fi
      [ "$danger" = "true" ] && set -- "$@" --dangerously-skip-permissions
      [ -n "$model" ] && set -- "$@" --model "$model"
      budget=$(cfg ".caps.budget_usd // empty")
      [ -n "$budget" ] && set -- "$@" --max-budget-usd "$budget"
      run_with_timeout "$tmo" claude "$@" < "$prompt_file" > "$so" 2> "$se"
      rc=$?
      ;;
    codex)
      if [ "$ro" = "true" ]; then sb="read-only"; else sb="workspace-write"; fi
      set -- exec "$(cat "$prompt_file")" --json -s "$sb" -o "$outdir/last.txt" --skip-git-repo-check
      [ "$danger" = "true" ] && set -- "$@" --dangerously-bypass-approvals-and-sandbox
      run_with_timeout "$tmo" codex "$@" < /dev/null > "$so" 2> "$se"
      rc=$?
      ;;
    opencode)
      set -- run "$(cat "$prompt_file")" --format json
      [ -n "$model" ] && set -- "$@" -m "$model"
      [ "$ro" = "true" ] && set -- "$@" --agent plan
      [ "$danger" = "true" ] && set -- "$@" --auto
      run_with_timeout "$tmo" opencode "$@" < /dev/null > "$so" 2> "$se"
      rc=$?
      ;;
    gemini)
      if [ "$ro" = "true" ]; then am="plan"; elif [ "$danger" = "true" ]; then am="yolo"; else am="auto_edit"; fi
      set -- -p "$(cat "$prompt_file")" --output-format json --approval-mode "$am"
      [ -n "$model" ] && set -- "$@" -m "$model"
      run_with_timeout "$tmo" gemini "$@" < /dev/null > "$so" 2> "$se"
      rc=$?
      ;;
    aider)
      set -- --message-file "$prompt_file" --yes-always --no-auto-commits
      [ -n "$model" ] && set -- "$@" --model "$model"
      gate1=$(cfg '.gates[0].cmd // empty')
      [ -n "$gate1" ] && set -- "$@" --test-cmd "$gate1" --auto-test
      run_with_timeout "$tmo" aider "$@" < /dev/null > "$so" 2> "$se"
      rc=$?
      ;;
    *) die "unknown backend: $backend" ;;
  esac

  dur=$(( $(date +%s) - start_ts ))
  # 124 = GNU timeout; 142 = perl SIGALRM
  timed_out=false; { [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ]; } && timed_out=true

  BACKEND="$backend" RC="$rc" DUR="$dur" TIMED_OUT="$timed_out" OUTDIR="$outdir" \
  python3 - <<'PY'
import json, os, re, sys
b, rc = os.environ["BACKEND"], int(os.environ["RC"])
outdir, dur = os.environ["OUTDIR"], int(os.environ["DUR"])
timed_out = os.environ["TIMED_OUT"] == "true"
def rd(p):
    try: return open(p, errors="replace").read()
    except OSError: return ""
so, se = rd(f"{outdir}/out.stdout"), rd(f"{outdir}/out.stderr")
n = {"backend": b, "exit_code": rc, "duration_s": dur, "timed_out": timed_out,
     "result_text": "", "session_id": None, "tokens_in": 0, "tokens_out": 0,
     "cost_usd": None, "is_error": rc != 0, "rate_limited": False}
try:
    if b == "claude":
        j = json.loads(so)
        n.update(result_text=j.get("result",""), session_id=j.get("session_id"),
                 cost_usd=j.get("total_cost_usd"), is_error=bool(j.get("is_error")) or rc != 0)
    elif b == "codex":
        n["result_text"] = rd(f"{outdir}/last.txt")
        for line in so.splitlines():
            line = line.strip()
            if not line.startswith("{"): continue
            try: ev = json.loads(line)
            except ValueError: continue
            t = ev.get("type","")
            if t == "thread.started": n["session_id"] = ev.get("thread_id")
            elif t == "turn.completed":
                u = ev.get("usage") or {}
                n["tokens_in"] += u.get("input_tokens",0); n["tokens_out"] += u.get("output_tokens",0)
            elif t in ("error","turn.failed"): n["is_error"] = True
    elif b == "gemini":
        j = json.loads(so)
        n["result_text"] = j.get("response","")
        st = j.get("stats") or {}
        n["tokens_in"] = st.get("input_tokens",0) or 0; n["tokens_out"] = st.get("output_tokens",0) or 0
        if j.get("error"): n["is_error"] = True
        if rc == 53: n["is_error"] = True  # turn limit
    else:  # opencode / aider: best-effort text
        n["result_text"] = so
except (ValueError, KeyError):
    n["result_text"] = so; n["is_error"] = True  # unparseable => failed, never guess success
blob = (so + se).lower()
if re.search(r"rate.?limit|usage limit|429|session limit|resets at|quota exceeded", blob):
    n["rate_limited"] = True
json.dump(n, open(f"{outdir}/out.json","w"), indent=1)
print(f"normalized: rc={rc} err={n['is_error']} rl={n['rate_limited']} cost={n['cost_usd']}")
PY
  return "$rc"
}

case "${1:-}" in
  probe) probe ;;
  invoke) shift; invoke "$@" ;;
  *) die "usage: adapter.sh probe | invoke <role> <prompt_file> <outdir>" ;;
esac
