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
    p0="implement"
    [ -n "$(jq -r '.backends.vetter.backend // empty' "$CONFIG")" ] && p0="vet"
    printf '{"phase":"%s","iteration":0,"round":0,"redesign_rounds":0,"breaker_trips":0,"no_progress":0,"same_error":0,"last_hash":"","last_error_sig":"","cost_usd":0,"base_commit":"%s","worktree":"%s","started_at":"%s","started_epoch":%s,"resume_used":false,"spec_vetted":false,"hunt_done":false,"deslop_done":false,"oracle_task":"","ledger":[]}\n' \
      "$p0" "$base" "$(pwd)" "$now" "$(date +%s)" > "$STATE"
    log "state initialized (base $base, entry phase $p0)"
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
  # optional run summarizer (comprehension-rot guard; cheap model recommended)
  summary_md=""
  if role_on summarizer; then
    sdir="$VLOOP_DIR/runs/summary"; mkdir -p "$sdir"
    git log --oneline "$(sget '.base_commit')..HEAD" > "$sdir/commits.txt" 2>/dev/null
    tail -50 "$VLOOP_DIR/progress.md" > "$sdir/progress.tail" 2>/dev/null || echo "(none)" > "$sdir/progress.tail"
    render "$TPL_DIR/PROMPT-summarize.md" "$sdir/prompt.md" \
      "REASON=$reason" "COMMITS=@$sdir/commits.txt" "PROGRESS=@$sdir/progress.tail"
    log "invoking summarizer for the human handoff"
    if "$ADAPTER" invoke summarizer "$sdir/prompt.md" "$sdir"; then
      ledger_add "$sdir"
      summary_md=$(jq -r '.result_text // ""' "$sdir/out.json" 2>/dev/null)
    fi
  fi
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
    [ -n "$summary_md" ] && { echo "## Run summary"; echo "$summary_md"; echo ""; }
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

KNOWN_BACKENDS="claude codex opencode gemini aider copilot cursor-agent droid amp qwen goose kiro-cli"

# Optional roles activate only when configured in loop.json .backends.<role>
role_on() { [ -n "$(cfg ".backends.$1.backend // empty")" ]; }

# Pull a JSON object out of a read-only role's final message (they can't write files)
extract_json() { # extract_json <out.json> <dest>
  OUTJ="$1" DEST="$2" python3 - <<'PY'
import json, os, re
try: text = json.load(open(os.environ["OUTJ"])).get("result_text","")
except Exception: text = ""
m = re.search(r"\{[\s\S]*\}", re.sub(r"```(json)?", "", text))
if m:
    try: json.dump(json.loads(m.group(0)), open(os.environ["DEST"],"w"), indent=1)
    except ValueError: pass
PY
}

# Shared backpressure gate runner; writes logs + gate-feedback on failure
run_gates() { # run_gates <outdir> ; returns 0 green / 1 fail
  n_gates=$(cfg '.gates | length'); g=0
  while [ "$g" -lt "$n_gates" ]; do
    gname=$(cfg ".gates[$g].name"); gcmd=$(cfg ".gates[$g].cmd")
    log "gate: $gname"
    if ! sh -c "$gcmd" > "$1/gate-$gname.log" 2>&1; then
      { echo "GATE FAILED: $gname ($gcmd) — last 200 lines:"; tail -200 "$1/gate-$gname.log"; } > "$VLOOP_DIR/runs/gate-feedback.txt"
      return 1
    fi
    g=$((g+1))
  done
  return 0
}

# After acceptance passes: optional hunt -> optional deslop -> milestone escalation
milestone_gate() {
  r=$(sget '.round')
  if role_on hunter && [ "$(sget '.hunt_done // false')" != "true" ]; then sset '.phase="hunt"'; return; fi
  if role_on cleaner && [ "$(sget '.deslop_done // false')" != "true" ]; then sset '.phase="deslop"'; return; fi
  escalate "milestone complete — all stories accepted; review the branch" "$VLOOP_DIR/runs/accept-$r/report.md"
}

# Orchestrator (not the agent) deterministically picks the next task — top to
# bottom, first unchecked line — so a per-task [agent: <backend>] tag can be
# honored: the agent never gets to choose work, so we always know in advance
# which backend must run it. Prints one JSON object: {id, line, agent}.
pick_task() {
  python3 - "$VLOOP_DIR/plan.md" <<'PY'
import json, re, sys
try:
    lines = open(sys.argv[1]).readlines()
except OSError:
    lines = []
for line in lines:
    m = re.match(r'^- \[ \] (T\S+?):', line)
    if m:
        am = re.search(r'\[agent:\s*([a-zA-Z0-9_-]+)\]', line)
        print(json.dumps({"id": m.group(1), "line": line.strip(), "agent": am.group(1) if am else None}))
        break
else:
    print(json.dumps({}))
PY
}

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

  task_json=$(pick_task)
  task_id=$(printf '%s' "$task_json" | jq -r '.id // empty')
  task_line=$(printf '%s' "$task_json" | jq -r '.line // empty')
  task_agent=$(printf '%s' "$task_json" | jq -r '.agent // empty')
  if [ -z "$task_id" ]; then
    if grep -q '^- \[x\]' "$VLOOP_DIR/plan.md" 2>/dev/null; then
      log "plan.md fully complete -> L2 acceptance"; sset '.phase="accept"'; return
    fi
    escalate "plan.md has no tasks at all — planner produced an empty/malformed plan"; return
  fi
  if [ -n "$task_agent" ]; then
    pool_names=$(jq -r '.backends.pool // {} | keys[]?' "$CONFIG")
    if ! printf '%s\n%s\n' "$KNOWN_BACKENDS" "$pool_names" | tr ' ' '\n' | grep -qx "$task_agent"; then
      log "WARNING: $task_id has unknown agent tag '$task_agent' — falling back to default executor"
      task_agent=""
    else
      log "iter $it: $task_id assigned to agent tag '$task_agent'"
    fi
  fi

  # optional TDD split: a separate test engineer writes RED tests the executor
  # must then make green — and may not modify (structural anti-self-grading)
  tester_files=""
  if role_on tester; then
    tdir="$outdir/tester"; mkdir -p "$tdir"
    render "$TPL_DIR/PROMPT-testeng.md" "$tdir/prompt.md" \
      "TASK_ID=$task_id" "TASK_LINE=$task_line" "PRD=@$VLOOP_DIR/prd.json" "AGENT_MD=@$VLOOP_DIR/AGENT.md"
    log "iter $it: invoking test engineer on $task_id"
    rm -f "$VLOOP_DIR/verdict.json"
    "$ADAPTER" invoke tester "$tdir/prompt.md" "$tdir"
    ledger_add "$tdir"
    t_status=$(jq -r '.status // "INVALID"' "$VLOOP_DIR/verdict.json" 2>/dev/null || echo INVALID)
    if [ "$t_status" = "blocked" ]; then
      escalate "test engineer blocked on $task_id: $(jq -r '.notes_for_next_iteration // ""' "$VLOOP_DIR/verdict.json" 2>/dev/null)"; return
    fi
    git diff --name-only > "$tdir/files.txt" 2>/dev/null
    git ls-files --others --exclude-standard >> "$tdir/files.txt" 2>/dev/null
    grep -v '^\.vloop' "$tdir/files.txt" > "$tdir/files.clean" 2>/dev/null || true
    tester_files="$tdir/files.clean"
    if [ -s "$tester_files" ]; then
      while read -r f; do [ -f "$f" ] && shasum "$f"; done < "$tester_files" > "$tdir/files.sha"
      log "iter $it: tester wrote $(wc -l < "$tester_files" | tr -d ' ') file(s) — protected from executor edits"
    fi
  fi

  tail -30 "$VLOOP_DIR/progress.md" > "$outdir/progress.tail" 2>/dev/null || echo "(none)" > "$outdir/progress.tail"
  render "$TPL_DIR/PROMPT-implement.md" "$outdir/prompt.md" \
    "PLAN=@$VLOOP_DIR/plan.md" "PROGRESS_TAIL=@$outdir/progress.tail" \
    "AGENT_MD=@$VLOOP_DIR/AGENT.md" "GATE_FEEDBACK=@$VLOOP_DIR/runs/gate-feedback.txt" \
    "TASK_ID=$task_id" "TASK_LINE=$task_line"
  if [ -n "$tester_files" ] && [ -s "$tester_files" ]; then
    { echo ""; echo "## Tests already written for this task (make them pass; you may NOT modify these files)"; sed 's/^/- /' "$tester_files"; } >> "$outdir/prompt.md"
  fi

  log "iter $it: invoking executor on $task_id"
  rm -f "$VLOOP_DIR/verdict.json"
  "$ADAPTER" invoke executor "$outdir/prompt.md" "$outdir" "$task_agent"
  ledger_add "$outdir"

  if jq -e '.rate_limited == true' "$outdir/out.json" >/dev/null 2>&1; then
    log "rate/usage limit detected — sleeping 15m (iteration not consumed)"; sleep 900; return
  fi

  # validate verdict (schema-checked; missing/invalid = failed iteration, not 'continue')
  verdict_status=$(jq -r 'if (.status? | IN("done","continue","blocked")) then .status else "INVALID" end' "$VLOOP_DIR/verdict.json" 2>/dev/null || echo "INVALID")
  reported_id=$(jq -r '.task_id // "?"' "$VLOOP_DIR/verdict.json" 2>/dev/null || echo "?")

  gates_green=true
  if [ "$verdict_status" = "INVALID" ]; then
    gates_green=false; echo "verdict.json missing or invalid — you MUST write it as your last action" > "$VLOOP_DIR/runs/gate-feedback.txt"
  elif [ "$reported_id" != "$task_id" ]; then
    gates_green=false
    echo "you were assigned $task_id but verdict.task_id was '$reported_id' — work ONLY on the assigned task" > "$VLOOP_DIR/runs/gate-feedback.txt"
  elif [ -n "$tester_files" ] && [ -s "$outdir/tester/files.sha" ] && ! shasum -c "$outdir/tester/files.sha" >/dev/null 2>&1; then
    # structural anti-Goodhart: implementer modified the test engineer's tests
    gates_green=false
    echo "you modified test files written by the test engineer this iteration — implement to make them pass, never edit them. Files: $(tr '\n' ' ' < "$tester_files")" > "$VLOOP_DIR/runs/gate-feedback.txt"
  else
    : > "$VLOOP_DIR/runs/gate-feedback.txt"
    run_gates "$outdir" || gates_green=false
  fi

  if [ "$gates_green" = "true" ] && [ -n "$(git status --porcelain)" ]; then
    agent_note=""; [ -n "$task_agent" ] && agent_note=" via $task_agent"
    git add -A && git commit -q -m "vloop(${task_id}): iter $it green${agent_note}" \
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

  if [ "$verdict_status" = "blocked" ]; then
    blocker=$(jq -r '.notes_for_next_iteration // ""' "$VLOOP_DIR/verdict.json" 2>/dev/null)
    # one oracle consult per task before interrupting the human
    if role_on oracle && [ "$(sget '.oracle_task')" != "$task_id" ]; then
      odir="$VLOOP_DIR/runs/oracle-$it"; mkdir -p "$odir"
      printf '%s\n' "$blocker" > "$odir/question.txt"
      render "$TPL_DIR/PROMPT-oracle.md" "$odir/prompt.md" \
        "TASK_LINE=$task_line" "QUESTION=@$odir/question.txt" "PLAN=@$VLOOP_DIR/plan.md" "AGENT_MD=@$VLOOP_DIR/AGENT.md"
      log "iter $it: executor blocked — consulting oracle before escalating"
      "$ADAPTER" invoke oracle "$odir/prompt.md" "$odir"
      ledger_add "$odir"
      advice=$(jq -r '.result_text // ""' "$odir/out.json" 2>/dev/null | head -c 4000)
      sset ".oracle_task = \"$task_id\""
      case "$advice" in
        ESCALATE:*|"") escalate "executor blocked on $task_id (oracle: ${advice:-no answer}): $blocker" ;;
        *)
          { echo "ORACLE ADVICE for the blocker you reported on $task_id:"; echo "$advice"; } > "$VLOOP_DIR/runs/gate-feedback.txt"
          log "oracle answered — retrying $task_id with advice" ;;
      esac
      return
    fi
    escalate "executor blocked: $blocker"; return
  fi

  # transition on plan completion regardless of what the verdict claimed — an
  # executor that keeps saying "continue" after the last task must not stall
  # the loop waiting for a "done" that may never come
  if [ "$gates_green" = "true" ] && ! grep -q '^- \[ \]' "$VLOOP_DIR/plan.md" 2>/dev/null; then
    log "plan complete -> L2 acceptance"; sset '.phase="accept"'
  elif [ "$verdict_status" = "done" ] && grep -q '^- \[ \]' "$VLOOP_DIR/plan.md" 2>/dev/null; then
    log "verdict 'done' but unticked tasks remain — claim rejected, continuing"
    echo "You declared done but plan.md still has unchecked tasks. Finish them or split them." > "$VLOOP_DIR/runs/gate-feedback.txt"
  fi
}

# ------------------------------------------------------------- L2 accept
do_accept() {
  r=$(sget '.round'); outdir="$VLOOP_DIR/runs/accept-$r"; mkdir -p "$outdir"

  # optional QA runner: exercises verify_hints/e2e and records evidence for the judge
  rm -f "$VLOOP_DIR/runs/qa-evidence.md"
  if role_on qa; then
    qadir="$VLOOP_DIR/runs/qa-$r"; mkdir -p "$qadir"
    render "$TPL_DIR/PROMPT-qa.md" "$qadir/prompt.md" \
      "PRD=@$VLOOP_DIR/prd.json" "AGENT_MD=@$VLOOP_DIR/AGENT.md" "ROUND=$r"
    log "L2: invoking QA runner (evidence collection)"
    rm -f "$VLOOP_DIR/verdict.json"
    "$ADAPTER" invoke qa "$qadir/prompt.md" "$qadir"
    ledger_add "$qadir"
    [ -f "$VLOOP_DIR/runs/qa-evidence.md" ] || jq -r '.result_text // "(qa runner produced no evidence)"' "$qadir/out.json" > "$VLOOP_DIR/runs/qa-evidence.md" 2>/dev/null
    # qa must not leave the tree dirty — evidence lives in .vloop, code changes get discarded
    [ -n "$(git status --porcelain)" ] && { log "qa runner left code changes — discarding (qa is evidence-only)"; clean_tree; }
  fi

  base=$(sget '.base_commit')
  { git diff --stat "$base..HEAD"; echo; git diff "$base..HEAD" | head -c 120000; } > "$outdir/diff.txt" 2>/dev/null
  ls "$VLOOP_DIR"/runs/iter-*/gate-*.log 2>/dev/null | tail -5 | while read -r f; do echo "== $f =="; tail -20 "$f"; done > "$outdir/gates.txt"
  render "$TPL_DIR/PROMPT-judge.md" "$outdir/prompt.md" \
    "PRD=@$VLOOP_DIR/prd.json" "DIFF_STAT=@$outdir/diff.txt" "GATE_LOGS=@$outdir/gates.txt" \
    "QA_EVIDENCE=@$VLOOP_DIR/runs/qa-evidence.md"

  log "L2: invoking judge (read-only, independent backend)"
  rm -f "$VLOOP_DIR/acceptance.json"
  "$ADAPTER" invoke judge "$outdir/prompt.md" "$outdir"
  ledger_add "$outdir"

  # judge is read-only => may be unable to write files; extract verdict JSON from its final message
  [ -f "$VLOOP_DIR/acceptance.json" ] || extract_json "$outdir/out.json" "$VLOOP_DIR/acceptance.json"
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
    milestone_gate
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

  # optional dispatcher: re-tags [agent:] routing on the fresh plan, nothing else
  if role_on dispatcher; then
    ddir="$VLOOP_DIR/runs/dispatch-$r"; mkdir -p "$ddir"
    cp "$VLOOP_DIR/plan.md" "$ddir/plan.before"
    pool_list=$(jq -r '.backends.pool // {} | keys | join(", ")' "$CONFIG")
    render "$TPL_DIR/PROMPT-dispatch.md" "$ddir/prompt.md" \
      "PLAN=@$VLOOP_DIR/plan.md" "BACKENDS=$KNOWN_BACKENDS" "POOL=${pool_list:-"(none defined)"}"
    log "invoking dispatcher (task-to-backend tagging)"
    rm -f "$VLOOP_DIR/verdict.json"
    "$ADAPTER" invoke dispatcher "$ddir/prompt.md" "$ddir"
    ledger_add "$ddir"
    # dispatcher may ONLY change [agent:] tags — task set must be identical
    before=$(grep -c '^- \[' "$ddir/plan.before" 2>/dev/null || echo 0)
    after=$(grep -c '^- \[' "$VLOOP_DIR/plan.md" 2>/dev/null || echo 0)
    stripped_same=$(python3 -c "
import re, sys
strip = lambda p: [re.sub(r'\s*\[agent:[^]]*\]', '', l) for l in open(p) if l.startswith('- [')]
print('yes' if strip('$ddir/plan.before') == strip('$VLOOP_DIR/plan.md') else 'no')")
    if [ "$before" != "$after" ] || [ "$stripped_same" != "yes" ]; then
      log "dispatcher changed more than [agent:] tags — restoring planner's plan"
      cp "$ddir/plan.before" "$VLOOP_DIR/plan.md"
    fi
    [ -n "$(git status --porcelain)" ] && clean_tree
  fi

  sset '.phase="implement" | .iteration=0 | .round += 1 | .no_progress=0 | .same_error=0 | .last_hash="" | .resume_used=false'
}

# ------------------------------------------------------------- L2 vet (one-shot PRD review)
do_vet() {
  outdir="$VLOOP_DIR/runs/vet"; mkdir -p "$outdir"
  render "$TPL_DIR/PROMPT-vet.md" "$outdir/prompt.md" "PRD=@$VLOOP_DIR/prd.json"
  log "vet: invoking spec-vetter (read-only PRD review)"
  "$ADAPTER" invoke vetter "$outdir/prompt.md" "$outdir"
  ledger_add "$outdir"
  rm -f "$VLOOP_DIR/vet.json"
  extract_json "$outdir/out.json" "$VLOOP_DIR/vet.json"
  if [ -f "$VLOOP_DIR/vet.json" ] && jq -e '.blocking == true' "$VLOOP_DIR/vet.json" >/dev/null 2>&1; then
    escalate "spec-vetter found BLOCKING PRD issues — fix the PRD before any implementation" "$VLOOP_DIR/vet.json"
    return
  fi
  if [ -f "$VLOOP_DIR/vet.json" ]; then
    n=$(jq '.findings | length' "$VLOOP_DIR/vet.json" 2>/dev/null || echo 0)
    jq -r '.findings[]? | "- [vet:\(.severity)/\(.area)] \(.issue) -> \(.suggestion)"' "$VLOOP_DIR/vet.json" >> "$VLOOP_DIR/decisions.md" 2>/dev/null
    log "vet: $n non-blocking finding(s) logged to decisions.md"
  else
    log "vet: no parseable verdict — proceeding (vet is advisory unless blocking)"
  fi
  if grep -q '^- \[ \]' "$VLOOP_DIR/plan.md" 2>/dev/null; then
    sset '.spec_vetted = true | .phase = "implement"'
  else
    sset '.spec_vetted = true | .phase = "replan"'   # no plan yet -> initial planning
  fi
}

# ------------------------------------------------------------- L2 hunt (post-acceptance placeholder sweep)
do_hunt() {
  r=$(sget '.round'); outdir="$VLOOP_DIR/runs/hunt-$r"; mkdir -p "$outdir"
  render "$TPL_DIR/PROMPT-hunt.md" "$outdir/prompt.md" \
    "PLAN=@$VLOOP_DIR/plan.md" "PRD=@$VLOOP_DIR/prd.json"
  log "hunt: invoking placeholder hunter (read-only sweep)"
  "$ADAPTER" invoke hunter "$outdir/prompt.md" "$outdir"
  ledger_add "$outdir"
  rm -f "$VLOOP_DIR/hunt.json"
  extract_json "$outdir/out.json" "$VLOOP_DIR/hunt.json"
  sset '.hunt_done = true'
  count=$(jq '.findings | length' "$VLOOP_DIR/hunt.json" 2>/dev/null || echo 0)
  if [ "$count" -gt 0 ] 2>/dev/null; then
    rr=$(sget '.redesign_rounds'); maxrr=$(cfg '.caps.max_redesign_rounds')
    if [ "$rr" -ge "$maxrr" ]; then
      escalate "placeholder hunter found $count issue(s) but max_redesign_rounds is exhausted" "$VLOOP_DIR/hunt.json"
      return
    fi
    jq '{summary: "placeholder hunt found fake/stub implementations behind passing acceptance", failed: .findings}' \
      "$VLOOP_DIR/hunt.json" > "$VLOOP_DIR/runs/judge-feedback.txt"
    sset '.redesign_rounds += 1 | .phase="replan"'
    log "hunt: $count finding(s) -> replan (counts as a redesign round)"
  else
    log "hunt: clean"
    milestone_gate
  fi
}

# ------------------------------------------------------------- L2 deslop (post-acceptance cleanup, best-effort)
do_deslop() {
  r=$(sget '.round'); outdir="$VLOOP_DIR/runs/deslop-$r"; mkdir -p "$outdir"
  render "$TPL_DIR/PROMPT-deslop.md" "$outdir/prompt.md" \
    "PLAN=@$VLOOP_DIR/plan.md" "AGENT_MD=@$VLOOP_DIR/AGENT.md"
  log "deslop: invoking cleaner"
  rm -f "$VLOOP_DIR/verdict.json"
  "$ADAPTER" invoke cleaner "$outdir/prompt.md" "$outdir"
  ledger_add "$outdir"
  sset '.deslop_done = true'
  if [ -n "$(git status --porcelain)" ]; then
    if run_gates "$outdir"; then
      git add -A && git commit -q -m "vloop(deslop): post-acceptance cleanup" && log "deslop: committed (regression green)"
    else
      log "deslop: regression failed — cleanup discarded (best-effort, never blocks the milestone)"
      clean_tree
    fi
  else
    log "deslop: nothing to clean"
  fi
  milestone_gate
}

# ------------------------------------------------------------- main
init
log "start: phase=$(sget '.phase') project=$(cfg '.project') executor=$(cfg '.backends.executor.backend') judge=$(cfg '.backends.judge.backend')"
[ "$(cfg '.backends.executor.backend')" = "$(cfg '.backends.judge.backend')" ] && log "WARNING: judge == executor backend — independent verification is degraded"

while :; do
  case "$(sget '.phase')" in
    vet)       do_vet ;;
    implement) do_implement ;;
    accept)    do_accept ;;
    hunt)      do_hunt ;;
    deslop)    do_deslop ;;
    replan)    do_replan ;;
    awaiting_human)
      log "AWAITING HUMAN — see $VLOOP_DIR/AWAITING_HUMAN.md"
      exit "$EXIT_AWAITING_HUMAN" ;;
    done)      log "done."; exit 0 ;;
    cancelled) log "cancelled."; exit 0 ;;
    *) die "unknown phase: $(sget '.phase')" ;;
  esac
done
