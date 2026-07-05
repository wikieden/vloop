#!/usr/bin/env bash
# vloop — Mode B unattended orchestrator for the 3-layer loop.
# L1 implement -> L2 accept/replan -> L3 awaiting_human (exit 42).
# bash 3.2 compatible. Requires: jq, python3, git. State: .vloop/*.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TPL_DIR="$SCRIPT_DIR/../templates"
VLOOP_DIR="${VLOOP_DIR:-.vloop}"
CONFIG="$VLOOP_DIR/loop.json"
STATE="$VLOOP_DIR/state.json"
ADAPTER="$SCRIPT_DIR/adapter.sh"
EXIT_AWAITING_HUMAN=42

die() { echo "vloop: FATAL: $*" >&2; exit 1; }
log() { echo "[vloop $(date '+%H:%M:%S')] $*"; }
cfg() { jq -r "$1" "$CONFIG"; }
sget() { jq -r "$1" "$STATE"; }

# Atomic state update: sset '.phase="accept" | .iteration=0'
sset() {
  tmp="$STATE.tmp.$$"
  jq "$1" "$STATE" > "$tmp" && mv "$tmp" "$STATE" || die "state write failed: $1"
}

# ------------------------------------------------------------- init & lock
init() {
  command -v jq >/dev/null || die "jq required"
  command -v python3 >/dev/null || die "python3 required"
  [ -f "$CONFIG" ] || die "no $CONFIG — run '/vloop setup' first"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo"
  # every cap must exist — a missing cap is a config error (unbounded loop)
  for c in max_iterations max_redesign_rounds budget_usd iteration_timeout_s; do
    v=$(cfg ".caps.$c // empty"); [ -n "$v" ] || die "cap missing in loop.json: $c"
  done
  mkdir -p "$VLOOP_DIR/runs"
  # .vloop must never be tracked: a committed state.json would be rolled back by
  # clean_tree at the next iteration, corrupting counters (infinite-loop risk)
  grep -qs '^\.vloop/' .gitignore || { echo '.vloop/' >> .gitignore; git add .gitignore; git commit -q -m "vloop: ignore state dir" 2>/dev/null || true; }
  if [ ! -f "$STATE" ]; then
    base=$(git rev-parse HEAD)
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"phase":"implement","iteration":0,"round":0,"redesign_rounds":0,"breaker_trips":0,"no_progress":0,"same_error":0,"last_hash":"","last_error_sig":"","cost_usd":0,"base_commit":"%s","worktree":"%s","started_at":"%s","started_epoch":%s,"resume_used":false,"ledger":[]}\n' \
      "$base" "$(pwd)" "$now" "$(date +%s)" > "$STATE"
    log "state initialized (base $base)"
  fi
  [ "$(sget '.worktree')" = "$(pwd)" ] || die "state belongs to worktree $(sget '.worktree') — two loops in one workspace conflict"
  # lock (mkdir is atomic); stale if owner pid dead
  if mkdir "$VLOOP_DIR/lock.d" 2>/dev/null; then echo $$ > "$VLOOP_DIR/lock.d/pid"
  else
    oldpid=$(cat "$VLOOP_DIR/lock.d/pid" 2>/dev/null || echo 0)
    kill -0 "$oldpid" 2>/dev/null && die "another vloop (pid $oldpid) is running"
    echo $$ > "$VLOOP_DIR/lock.d/pid"; log "stale lock taken over"
  fi
  trap 'rm -rf "$VLOOP_DIR/lock.d"' EXIT
}

# ------------------------------------------------------------- helpers
render() { # render <template> <out> KEY=file-or-literal...  (@file => content, else literal)
  TPL="$1" OUT="$2" python3 - "$@" <<'PY'
import os, sys
tpl = open(os.environ["TPL"]).read()
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    val = open(v[1:], errors="replace").read() if v.startswith("@") and os.path.exists(v[1:]) else (v[1:] if v.startswith("@") else v)
    if v.startswith("@") and not os.path.exists(v[1:]): val = "(none)"
    tpl = tpl.replace("{{%s}}" % k, val)
open(os.environ["OUT"], "w").write(tpl)
PY
}

ledger_add() { # ledger_add <outdir>
  o="$1/out.json"; [ -f "$o" ] || return 0
  entry=$(PRICING="$TPL_DIR/pricing.json" python3 - "$o" <<'PY'
import json, os, sys
n = json.load(open(sys.argv[1]))
usd = n.get("cost_usd")
if usd is None:
    try: p = json.load(open(os.environ["PRICING"])).get(n["backend"], {})
    except OSError: p = {}
    d = p.get("default")
    if isinstance(d, list): usd = n["tokens_in"]/1e6*d[0] + n["tokens_out"]/1e6*d[1]
    elif "default_per_minute_estimate_usd" in p: usd = n["duration_s"]/60*p["default_per_minute_estimate_usd"]
    else: usd = 0.0
print(json.dumps({"backend": n["backend"], "usd": round(usd,4), "tok_in": n["tokens_in"], "tok_out": n["tokens_out"]}))
PY
)
  usd=$(printf '%s' "$entry" | jq '.usd // 0')
  sset ".ledger += [$entry] | .cost_usd = ((.cost_usd + $usd) * 10000 | round / 10000)"
}

notify_human() {
  msg="$1"
  t=$(cfg '.notify.type // "none"'); tgt=$(cfg '.notify.target // ""')
  case "$t" in
    ntfy) curl -s -d "$msg" "https://ntfy.sh/$tgt" >/dev/null 2>&1 ;;
    webhook) curl -s -X POST -H 'Content-Type: application/json' -d "{\"text\":$(printf '%s' "$msg" | jq -Rs .)}" "$tgt" >/dev/null 2>&1 ;;
    osascript) osascript -e "display notification \"$msg\" with title \"vloop\"" 2>/dev/null ;;
  esac
}

escalate() { # escalate <reason> [report_file]
  reason="$1"; report="${2:-}"
  log "L3 ESCALATION: $reason"
  {
    echo "# AWAITING HUMAN — vloop paused"
    echo ""
    echo "- **Reason**: $reason"
    echo "- **Phase/iteration**: $(sget '.phase') / iter $(sget '.iteration') / round $(sget '.round') / redesign $(sget '.redesign_rounds')"
    echo "- **Cost so far**: \$$(sget '.cost_usd') (ledger in state.json)"
    echo "- **Commits this run**: "
    git log --oneline "$(sget '.base_commit')..HEAD" 2>/dev/null | sed 's/^/    /'
    echo ""
    [ -n "$report" ] && [ -f "$report" ] && { echo "## Report"; cat "$report"; echo ""; }
    echo "## Questions for you"
    echo "1. Continue? — A. approve & continue  B. update requirements (edit PRD / answer below)  C. roll back to a tag and retry  D. stop here"
    echo ""
    echo "Answer compactly (e.g. '1A'), or edit .vloop/prd.json / your PRD file, then run: /vloop resume"
  } > "$VLOOP_DIR/AWAITING_HUMAN.md"
  sset '.phase="awaiting_human"'
  notify_human "vloop paused: $reason (see .vloop/AWAITING_HUMAN.md)"
}

clean_tree() { git checkout -- . 2>/dev/null; git clean -fd -e .vloop >/dev/null 2>&1; }

progress_hash() { { git rev-parse HEAD; git status --porcelain; } | shasum | cut -d' ' -f1; }

# ------------------------------------------------------------- L1 implement
do_implement() {
  it=$(sget '.iteration'); max_it=$(cfg '.caps.max_iterations')
  [ "$it" -ge "$max_it" ] && { escalate "max_iterations ($max_it) reached without completion"; return; }
  cost=$(sget '.cost_usd'); budget=$(cfg '.caps.budget_usd')
  awk "BEGIN{exit !($cost >= $budget)}" && { escalate "budget \$$budget exhausted (spent \$$cost)"; return; }
  tph=$(cfg '.l3_gates.timed_pause_hours // 0')
  if [ "$tph" != "0" ] && [ "$tph" != "null" ]; then
    elapsed=$(( $(date +%s) - $(sget '.started_epoch') ))
    [ "$elapsed" -gt $(( tph * 3600 )) ] && { escalate "timed pause (${tph}h elapsed)"; return; }
  fi

  outdir="$VLOOP_DIR/runs/iter-$it"; mkdir -p "$outdir"
  [ -n "$(git status --porcelain)" ] && { log "dirty tree from failed iteration — rolling back"; clean_tree; }

  tail -30 "$VLOOP_DIR/progress.md" > "$outdir/progress.tail" 2>/dev/null || echo "(none)" > "$outdir/progress.tail"
  render "$TPL_DIR/PROMPT-implement.md" "$outdir/prompt.md" \
    "PLAN=@$VLOOP_DIR/plan.md" "PROGRESS_TAIL=@$outdir/progress.tail" \
    "AGENT_MD=@$VLOOP_DIR/AGENT.md" "GATE_FEEDBACK=@$VLOOP_DIR/runs/gate-feedback.txt"

  log "iter $it: invoking executor"
  rm -f "$VLOOP_DIR/verdict.json"
  "$ADAPTER" invoke executor "$outdir/prompt.md" "$outdir"
  ledger_add "$outdir"

  if jq -e '.rate_limited == true' "$outdir/out.json" >/dev/null 2>&1; then
    log "rate/usage limit detected — sleeping 15m (iteration not consumed)"; sleep 900; return
  fi

  # validate verdict (schema-checked; missing/invalid = failed iteration, not 'continue')
  verdict_status=$(jq -r 'if (.status? | IN("done","continue","blocked")) then .status else "INVALID" end' "$VLOOP_DIR/verdict.json" 2>/dev/null || echo "INVALID")
  task_id=$(jq -r '.task_id // "?"' "$VLOOP_DIR/verdict.json" 2>/dev/null || echo "?")

  gates_green=true
  if [ "$verdict_status" = "INVALID" ]; then
    gates_green=false; echo "verdict.json missing or invalid — you MUST write it as your last action" > "$VLOOP_DIR/runs/gate-feedback.txt"
  else
    : > "$VLOOP_DIR/runs/gate-feedback.txt"
    n_gates=$(cfg '.gates | length'); g=0
    while [ "$g" -lt "$n_gates" ]; do
      gname=$(cfg ".gates[$g].name"); gcmd=$(cfg ".gates[$g].cmd")
      log "gate: $gname"
      if ! sh -c "$gcmd" > "$outdir/gate-$gname.log" 2>&1; then
        gates_green=false
        { echo "GATE FAILED: $gname ($gcmd) — last 200 lines:"; tail -200 "$outdir/gate-$gname.log"; } > "$VLOOP_DIR/runs/gate-feedback.txt"
        break
      fi
      g=$((g+1))
    done
  fi

  if [ "$gates_green" = "true" ] && [ -n "$(git status --porcelain)" ]; then
    git add -A && git commit -q -m "vloop(${task_id}): iter $it green" \
      && log "iter $it: committed (ratchet)"
    # orchestrator (not the agent) ticks the plan checkbox
    [ "$task_id" != "?" ] && sed -i.bak "s/^- \[ \] ${task_id}:/- [x] ${task_id}:/" "$VLOOP_DIR/plan.md" 2>/dev/null && rm -f "$VLOOP_DIR/plan.md.bak"
  elif [ "$gates_green" != "true" ]; then
    log "iter $it: gates failed — rolling back working tree (fix-forward contaminates)"
    clean_tree
  fi

  # circuit breaker
  h=$(progress_hash); last=$(sget '.last_hash')
  if [ "$h" = "$last" ]; then sset '.no_progress += 1'; else sset ".no_progress = 0 | .last_hash = \"$h\""; fi
  esig=$(head -5 "$VLOOP_DIR/runs/gate-feedback.txt" 2>/dev/null | shasum | cut -d' ' -f1)
  if [ "$gates_green" != "true" ] && [ "$esig" = "$(sget '.last_error_sig')" ]; then sset '.same_error += 1'
  else sset ".same_error = 0 | .last_error_sig = \"$esig\""; fi

  if [ "$(sget '.no_progress')" -ge 3 ] || [ "$(sget '.same_error')" -ge 5 ]; then
    trips=$(sget '.breaker_trips'); sset '.breaker_trips += 1 | .no_progress = 0 | .same_error = 0'
    if [ "$trips" -ge 1 ]; then escalate "circuit breaker tripped twice (stuck)"; return
    else
      log "breaker trip #1 -> replan"
      cp "$VLOOP_DIR/runs/gate-feedback.txt" "$VLOOP_DIR/runs/judge-feedback.txt" 2>/dev/null
      echo "LOOP STUCK: no progress / repeated error. Evidence above. Rethink the approach for the current task." >> "$VLOOP_DIR/runs/judge-feedback.txt"
      sset '.phase="replan"'; return
    fi
  fi

  sset '.iteration += 1'

  case "$verdict_status" in
    blocked) escalate "executor blocked: $(jq -r '.notes_for_next_iteration // ""' "$VLOOP_DIR/verdict.json" 2>/dev/null)" ;;
    done)
      if grep -q '^- \[ \]' "$VLOOP_DIR/plan.md"; then
        log "verdict 'done' but unticked tasks remain — claim rejected, continuing"
        echo "You declared done but plan.md still has unchecked tasks. Finish them or split them." > "$VLOOP_DIR/runs/gate-feedback.txt"
      elif [ "$gates_green" = "true" ]; then
        log "plan complete + gates green -> L2 acceptance"; sset '.phase="accept"'
      fi ;;
  esac
}

# ------------------------------------------------------------- L2 accept
do_accept() {
  r=$(sget '.round'); outdir="$VLOOP_DIR/runs/accept-$r"; mkdir -p "$outdir"
  base=$(sget '.base_commit')
  { git diff --stat "$base..HEAD"; echo; git diff "$base..HEAD" | head -c 120000; } > "$outdir/diff.txt" 2>/dev/null
  ls "$VLOOP_DIR"/runs/iter-*/gate-*.log 2>/dev/null | tail -5 | while read -r f; do echo "== $f =="; tail -20 "$f"; done > "$outdir/gates.txt"
  render "$TPL_DIR/PROMPT-judge.md" "$outdir/prompt.md" \
    "PRD=@$VLOOP_DIR/prd.json" "DIFF_STAT=@$outdir/diff.txt" "GATE_LOGS=@$outdir/gates.txt"

  log "L2: invoking judge (read-only, independent backend)"
  rm -f "$VLOOP_DIR/acceptance.json"
  "$ADAPTER" invoke judge "$outdir/prompt.md" "$outdir"
  ledger_add "$outdir"

  # judge is read-only => may be unable to write files; extract verdict JSON from its final message
  ACC="$VLOOP_DIR/acceptance.json" OUT="$outdir/out.json" python3 - <<'PY'
import json, os, re
acc = os.environ["ACC"]
if not os.path.exists(acc):
    try: text = json.load(open(os.environ["OUT"])).get("result_text","")
    except Exception: text = ""
    m = re.search(r"\{[\s\S]*\}", re.sub(r"```(json)?", "", text))
    if m:
        try: json.dump(json.loads(m.group(0)), open(acc,"w"), indent=1)
        except ValueError: pass
PY
  [ -f "$VLOOP_DIR/acceptance.json" ] || { log "no parseable judge verdict — counting as failed round"; echo '{"stories":[],"summary":"judge produced no verdict"}' > "$VLOOP_DIR/acceptance.json"; }

  # ratchet: ONLY here does passes flip to true, only on judge sign-off
  PRD="$VLOOP_DIR/prd.json" ACC="$VLOOP_DIR/acceptance.json" python3 - <<'PY'
import json, os
prd_p = os.environ["PRD"]
prd, acc = json.load(open(prd_p)), json.load(open(os.environ["ACC"]))
ok = {s["story_id"] for s in acc.get("stories",[]) if s.get("overall")=="pass" and all(c.get("pass") for c in s.get("criteria",[]))}
for s in prd["stories"]:
    if s["id"] in ok: s["passes"] = True
tmp = prd_p + ".tmp"
json.dump(prd, open(tmp,"w"), indent=1); os.replace(tmp, prd_p)
failed = [s["id"] for s in prd["stories"] if not s["passes"]]
print("PASSED" if not failed else "FAILED:" + ",".join(failed))
PY

  if ! jq -e '.stories[] | select(.passes==false)' "$VLOOP_DIR/prd.json" >/dev/null 2>&1; then
    { echo "## Acceptance report (round $r) — ALL STORIES PASS"; jq -r '.summary' "$VLOOP_DIR/acceptance.json"; } > "$outdir/report.md"
    escalate "milestone complete — all stories accepted; review the branch" "$outdir/report.md"
    return
  fi

  rr=$(sget '.redesign_rounds'); maxrr=$(cfg '.caps.max_redesign_rounds')
  sset '.redesign_rounds += 1'
  if [ "$rr" -ge "$maxrr" ]; then
    { echo "## Acceptance FAILURE after $maxrr redesign rounds"; cat "$VLOOP_DIR/acceptance.json"; } > "$outdir/report.md"
    escalate "max_redesign_rounds ($maxrr) exhausted — review loops diverge past this point" "$outdir/report.md"
    return
  fi
  # failed criteria + evidence become planner input
  jq '{summary, failed: [.stories[] | select(.overall != "pass")]}' "$VLOOP_DIR/acceptance.json" > "$VLOOP_DIR/runs/judge-feedback.txt"
  log "L2: acceptance failed -> replan (redesign round $((rr+1))/$maxrr)"
  sset '.phase="replan"'
}

# ------------------------------------------------------------- L2 replan
do_replan() {
  r=$(sget '.round'); outdir="$VLOOP_DIR/runs/replan-$r"; mkdir -p "$outdir"
  cp "$VLOOP_DIR/plan.md" "$outdir/old-plan.md" 2>/dev/null || echo "(no previous plan)" > "$outdir/old-plan.md"
  tail -30 "$VLOOP_DIR/progress.md" > "$outdir/progress.tail" 2>/dev/null || echo "(none)" > "$outdir/progress.tail"
  render "$TPL_DIR/PROMPT-replan.md" "$outdir/prompt.md" \
    "PRD=@$VLOOP_DIR/prd.json" "JUDGE_FEEDBACK=@$VLOOP_DIR/runs/judge-feedback.txt" \
    "OLD_PLAN=@$outdir/old-plan.md" "PROGRESS_TAIL=@$outdir/progress.tail" "ROUND=$(sget '.redesign_rounds')"

  log "L2: invoking planner (replan)"
  "$ADAPTER" invoke planner "$outdir/prompt.md" "$outdir"
  ledger_add "$outdir"

  grep -q '^- \[ \]' "$VLOOP_DIR/plan.md" 2>/dev/null || { escalate "replan produced no actionable tasks"; return; }
  # planner must not have touched code — discard any stray writes outside .vloop
  [ -n "$(git status --porcelain)" ] && { log "replan left code changes — discarding (planner is plan-only)"; clean_tree; }
  sset '.phase="implement" | .iteration=0 | .round += 1 | .no_progress=0 | .same_error=0 | .last_hash="" | .resume_used=false'
}

# ------------------------------------------------------------- main
init
log "start: phase=$(sget '.phase') project=$(cfg '.project') executor=$(cfg '.backends.executor.backend') judge=$(cfg '.backends.judge.backend')"
[ "$(cfg '.backends.executor.backend')" = "$(cfg '.backends.judge.backend')" ] && log "WARNING: judge == executor backend — independent verification is degraded"

while :; do
  case "$(sget '.phase')" in
    implement) do_implement ;;
    accept)    do_accept ;;
    replan)    do_replan ;;
    awaiting_human)
      log "AWAITING HUMAN — see $VLOOP_DIR/AWAITING_HUMAN.md"
      exit "$EXIT_AWAITING_HUMAN" ;;
    done)      log "done."; exit 0 ;;
    cancelled) log "cancelled."; exit 0 ;;
    *) die "unknown phase: $(sget '.phase')" ;;
  esac
done
