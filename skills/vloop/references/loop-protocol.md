# Loop Protocol — L1/L2/L3 执行手册

Mode A: the Claude Code session follows this protocol as orchestrator, invoking backends via Bash per adapters.md. Mode B: `scripts/vloop.sh` implements the same protocol. State transitions live in `.vloop/state.json` (atomic writes: tmp + mv); phases: `implement | accept | replan | awaiting_human | done | cancelled`.

## Orchestrator context discipline (Mode A)

- Backend outputs go to `.vloop/runs/iter-N/` files; read only tail/summary into context.
- Never paste plan history or prior-iteration transcripts into prompts — templates reference files.
- After each iteration keep only: phase, iteration count, one-line result. Everything else is on disk.
- On compaction/session restart: rebuild from `state.json` + `progress.md` + `git log`, never from memory. Never re-run tasks whose commits exist.

## L1 — implement phase

Per iteration (fresh context, executor backend):

1. **Pre-flight**: `git status --porcelain` must be clean (uncommitted leftovers from a failed iteration → `git checkout . && git clean -fd` within the worktree — the ratchet is commits, rollback beats fix-forward). Check caps: iteration < max_iterations; budget ledger < budget_usd; else → L3 escalation.
2. **Assemble prompt** from `templates/PROMPT-implement.md`, substituting: `{{PLAN}}` (plan.md content), `{{PROGRESS_TAIL}}` (last ~30 lines of progress.md), `{{AGENT_MD}}`, `{{GATE_FEEDBACK}}` (previous iteration's gate failure evidence, truncated to ~200 lines, or "none").
3. **Invoke executor** (adapters.md), timeout `iteration_timeout_s`, output to `runs/iter-N/`.
4. **Validate verdict** `.vloop/verdict.json` against schema `{status: done|continue|blocked, task_id, evidence, notes_for_next_iteration}`. Missing/invalid → record failed iteration, GATE_FEEDBACK = "verdict missing/invalid", next iteration.
5. **Run gates** serially (`gates[]` from loop.json), capturing output to `runs/iter-N/gate-<name>.log`:
   - All pass AND `git diff` non-empty → commit `vloop(T<id>): <title> [iter N]`; tick the task checkbox in plan.md; append one line to progress.md (`iter N: T<id> done, gates green, cost $X`).
   - Any gate fails → NO commit; GATE_FEEDBACK = failing gate tail; next iteration.
6. **Circuit breaker** (update counters in state.json):
   - HEAD + `git status --porcelain | shasum` unchanged 3 consecutive iterations → 1st trip: phase=replan (with "stuck" evidence); 2nd trip: phase=awaiting_human.
   - Same normalized error signature (first failing test name + error class) 5 consecutive → same escalation path.
   - Rate-limit/5h-window detected in backend output → sleep until reset; does NOT consume an iteration.
7. **Transition**: verdict `done` AND all plan boxes ticked → phase=accept. Verdict `blocked` → phase=awaiting_human. Else next iteration.

Verdict is a claim, not proof: `done` with unticked boxes or empty diff = failed iteration.

## L2 — accept phase

1. **Invoke judge**: different backend, physically read-only (adapters.md readonly invocation). Prompt from `templates/PROMPT-judge.md` with `{{PRD}}`, `{{DIFF_STAT}}` (branch diff vs base, stat + capped diff), `{{GATE_LOGS}}` (latest green gate summary). Judge writes `.vloop/acceptance.json`: `{story_id, criteria: [{id, pass, evidence}], overall: pass|fail}` per story.
2. **Ratchet**: for stories where ALL criteria pass → orchestrator (never the agent) sets `passes:true` in prd.json.
3. **All stories pass** → write acceptance report to `runs/acceptance-R.md` → phase=awaiting_human (milestone gate).
4. **Any fail** → `redesign_rounds++`:
   - `redesign_rounds > max_redesign_rounds` (default 3 — cross-model review loops diverge past ~3) → phase=awaiting_human with full failure report.
   - Else, if `resume_strategy: resume_once` and not yet used this round: resume the executor session with judge evidence for one cheap fix attempt, re-run gates, re-judge. Then fall through:
   - phase=replan.

## L2 — replan phase

1. **Invoke planner** (planner backend), prompt from `templates/PROMPT-replan.md` with `{{PRD}}`, `{{JUDGE_FEEDBACK}}` (failed criteria + evidence), `{{OLD_PLAN}}`, `{{PROGRESS_TAIL}}`.
2. Planner rewrites `plan.md`: new/split tasks targeting the failed criteria. **May not touch acceptance criteria** (criteria belong to L3/human). Granularity check: one task = one context window.
3. Reset L1 counters (iteration budget for the round, breaker counters; global budget ledger persists). phase=implement.

## L3 — awaiting_human phase

On entering:
1. Persist state.json.
2. Write `.vloop/AWAITING_HUMAN.md`: trigger reason; acceptance/failure report; **concrete lettered questions** (answerable as "1A 2C"); run summary — iterations used, cost ledger total, commits list, representative diff pointers (comprehension-rot guard).
3. If remote repo exists: push branch, open draft PR (`gh pr create --draft`).
4. Notify per loop.json `notify`. Mode B exits with code 42. Mode A: interactive → present summary + AskUserQuestion (approve / update requirements / roll back); non-interactive → stop turn after reporting.

Action-class gates (merge/deploy/publish/delete/charge/close): whenever ANY layer is about to perform one of these, enter awaiting_human first — no config can disable this.

## Resume (after human decision)

| Decision | Action |
|---|---|
| **Approve** | Merge/tag per human instruction (human performs or explicitly authorizes), append to decisions.md, phase=done (or next milestone: load next PRD stories, reset counters, phase=replan) |
| **Update requirements** | Diff PRD file / prd.json edits; changed/new criteria → planner maps to new tasks; removed stories → drop + `passes` untouched history kept in decisions.md; reset redesign_rounds=0; phase=replan |
| **Roll back** | `git reset --hard <tag/commit>` in worktree (confirm target with human), record in decisions.md, phase=replan with human's steering notes injected as JUDGE_FEEDBACK |

Every decision appends one line to `decisions.md` (timestamp, decision, rationale) — append-only audit trail.
