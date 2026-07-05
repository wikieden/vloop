#!/usr/bin/env bash
# vloop adapter layer — multi-backend headless invocation + output normalization.
# bash 3.2 compatible (macOS default). Requires: jq, python3.
# Usage:
#   adapter.sh probe                      -> writes .vloop/backends.json
#   adapter.sh invoke <role> <prompt_file> <outdir> [agent_tag]
#     role = executor | judge | planner  (read from .vloop/loop.json)
#     agent_tag = optional per-task override: either a bare backend id (reuses
#       role's model/danger/readonly) or a name under .backends.pool.<name>
#       (own backend/model/danger/readonly). Falls back to the role's own
#       backend if omitted or unrecognized (caller should warn on unknown tags).
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
      copilot)
        cap='{"json_output":"jsonl","schema_output":false,"budget_cap":false,"turn_cap":false,"resume":true,"readonly_mode":"--plan","danger_flag":"--allow-all"}' ;;
      cursor-agent)
        cap='{"json_output":true,"schema_output":false,"budget_cap":false,"turn_cap":false,"resume":true,"readonly_mode":"--mode plan","danger_flag":"--force"}' ;;
      droid)
        cap='{"json_output":true,"schema_output":false,"budget_cap":false,"turn_cap":false,"resume":true,"readonly_mode":"default (no --auto)","danger_flag":"--skip-permissions-unsafe"}' ;;
      amp)
        cap='{"json_output":"jsonl","schema_output":false,"budget_cap":false,"turn_cap":false,"resume":true,"readonly_mode":null,"danger_flag":"--dangerously-allow-all"}' ;;
      qwen)
        cap='{"json_output":true,"schema_output":true,"budget_cap":"--max-wall-time","turn_cap":"--max-session-turns","resume":true,"readonly_mode":"--approval-mode plan","danger_flag":"--yolo"}' ;;
      goose)
        cap='{"json_output":true,"schema_output":false,"budget_cap":false,"turn_cap":"--max-turns","resume":false,"readonly_mode":null,"danger_flag":"GOOSE_MODE=auto"}' ;;
      kiro-cli)
        cap='{"json_output":false,"schema_output":false,"budget_cap":false,"turn_cap":false,"resume":true,"readonly_mode":"--trust-tools=fs_read","danger_flag":"--trust-all-tools"}' ;;
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
  role="$1"; prompt_file="$2"; outdir="$3"; tag="${4:-}"
  [ -f "$CONFIG" ] || die "no $CONFIG"
  [ -f "$prompt_file" ] || die "prompt file missing: $prompt_file"
  mkdir -p "$outdir"
  pool_hit=""
  if [ -n "$tag" ]; then
    pool_hit=$(jq -r --arg t "$tag" '.backends.pool[$t].backend // empty' "$CONFIG")
  fi
  if [ -n "$pool_hit" ]; then
    # named pool preset: own backend/model/effort/danger/readonly
    backend="$pool_hit"
    model=$(jq -r --arg t "$tag" '.backends.pool[$t].model // empty' "$CONFIG")
    effort=$(jq -r --arg t "$tag" '.backends.pool[$t].effort // empty' "$CONFIG")
    ro=$(jq -r --arg t "$tag" '.backends.pool[$t].readonly // false' "$CONFIG")
    danger=$(jq -r --arg t "$tag" '.backends.pool[$t].danger // false' "$CONFIG")
  elif [ -n "$tag" ]; then
    # bare backend id override: swap backend, keep role's model/effort/danger/readonly
    backend="$tag"
    model=$(cfg ".backends.$role.model // empty")
    effort=$(cfg ".backends.$role.effort // empty")
    ro=$(cfg ".backends.$role.readonly // false")
    danger=$(cfg ".backends.$role.danger // false")
  else
    backend=$(cfg ".backends.$role.backend")
    model=$(cfg ".backends.$role.model // empty")
    effort=$(cfg ".backends.$role.effort // empty")
    ro=$(cfg ".backends.$role.readonly // false")
    danger=$(cfg ".backends.$role.danger // false")
  fi
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
      [ -n "$model" ] && set -- "$@" -m "$model"
      # reasoning-effort tiering (e.g. xhigh planner / medium executor on the same model)
      [ -n "$effort" ] && set -- "$@" -c "model_reasoning_effort=\"$effort\""
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
    copilot)
      # -s: only agent response; --no-ask-user: never block on questions (unattended)
      set -- -p "$(cat "$prompt_file")" -s --no-ask-user
      if [ "$ro" = "true" ]; then set -- "$@" --plan --allow-all-tools
      elif [ "$danger" = "true" ]; then set -- "$@" --allow-all
      else set -- "$@" --allow-all-tools; fi
      [ -n "$model" ] && set -- "$@" --model "$model"
      [ -n "$effort" ] && set -- "$@" --reasoning-effort "$effort"
      run_with_timeout "$tmo" copilot "$@" < /dev/null > "$so" 2> "$se"
      rc=$?
      ;;
    cursor-agent)
      # --trust required in headless (skips workspace-trust prompt)
      set -- "$(cat "$prompt_file")" -p --output-format text --trust
      if [ "$ro" = "true" ]; then set -- "$@" --mode plan
      else set -- "$@" --force; fi
      [ -n "$model" ] && set -- "$@" --model "$model"
      run_with_timeout "$tmo" cursor-agent "$@" < /dev/null > "$so" 2> "$se"
      rc=$?
      ;;
    droid)
      # no --auto flag = read-only spec mode (native judge); medium = edits+builds+local git
      set -- exec -f "$prompt_file" -o json
      if [ "$ro" = "true" ]; then :
      elif [ "$danger" = "true" ]; then set -- "$@" --skip-permissions-unsafe
      else set -- "$@" --auto medium; fi
      [ -n "$model" ] && set -- "$@" -m "$model"
      run_with_timeout "$tmo" droid "$@" < /dev/null > "$so" 2> "$se"
      rc=$?
      ;;
    amp)
      # -x with no arg reads prompt from stdin; stream-json is Claude-Code-compatible JSONL
      set -- -x --stream-json --no-archive-after-execute
      [ "$danger" = "true" ] && set -- "$@" --dangerously-allow-all
      run_with_timeout "$tmo" amp "$@" < "$prompt_file" > "$so" 2> "$se"
      rc=$?
      ;;
    qwen)
      # non-TTY stdin triggers headless; native turn cap; exit 53=turns 55=budget
      if [ "$ro" = "true" ]; then am="plan"; elif [ "$danger" = "true" ]; then am="yolo"; else am="auto"; fi
      set -- --approval-mode "$am" --output-format json --max-session-turns 50
      [ -n "$model" ] && set -- "$@" -m "$model"
      run_with_timeout "$tmo" qwen "$@" < "$prompt_file" > "$so" 2> "$se"
      rc=$?
      ;;
    goose)
      # approvals via GOOSE_MODE env; native anti-loop caps; -q = response only
      set -- run -i "$prompt_file" --no-session -q --max-turns 40 --max-tool-repetitions 5
      [ -n "$model" ] && set -- "$@" --model "$model"
      GOOSE_MODE=auto run_with_timeout "$tmo" goose "$@" < /dev/null > "$so" 2> "$se"
      rc=$?
      ;;
    kiro-cli)
      set -- chat --no-interactive
      if [ "$ro" = "true" ]; then set -- "$@" --trust-tools=fs_read
      else set -- "$@" --trust-all-tools; fi
      [ -n "$model" ] && set -- "$@" --model "$model"
      [ -n "$effort" ] && set -- "$@" --effort "$effort"
      set -- "$@" "$(cat "$prompt_file")"
      run_with_timeout "$tmo" kiro-cli "$@" < /dev/null > "$so" 2> "$se"
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
    elif b == "droid":
        # single Claude-style result object: {type:result, result, session_id, is_error, num_turns}
        j = json.loads(so)
        n.update(result_text=j.get("result",""), session_id=j.get("session_id"),
                 is_error=bool(j.get("is_error")) or rc != 0)
    elif b == "amp":
        # Claude-Code-compatible stream-JSON (JSONL on stdout)
        for line in so.splitlines():
            line = line.strip()
            if not line.startswith("{"): continue
            try: ev = json.loads(line)
            except ValueError: continue
            t = ev.get("type","")
            if t == "system": n["session_id"] = ev.get("session_id") or n["session_id"]
            elif t == "assistant":
                for blk in (ev.get("message") or {}).get("content",[]) or []:
                    if blk.get("type") == "text": n["result_text"] += blk.get("text","")
            elif t == "result":
                if ev.get("result"): n["result_text"] = ev["result"]
                if ev.get("is_error"): n["is_error"] = True
    elif b == "qwen":
        # buffered JSON array of Claude-style messages; final answer in the result message
        arr = json.loads(so)
        for ev in (arr if isinstance(arr, list) else [arr]):
            t = ev.get("type","")
            if t == "system": n["session_id"] = ev.get("session_id") or n["session_id"]
            elif t == "result":
                n["result_text"] = ev.get("result","")
                u = ev.get("usage") or {}
                n["tokens_in"] = u.get("input_tokens",0) or 0; n["tokens_out"] = u.get("output_tokens",0) or 0
                if ev.get("is_error"): n["is_error"] = True
        if rc in (53, 55): n["is_error"] = True  # 53=turn cap, 55=budget cap
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
    else:  # opencode / aider / copilot / cursor-agent / goose / kiro-cli: best-effort text
        n["result_text"] = so
except (ValueError, KeyError, AttributeError):
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
