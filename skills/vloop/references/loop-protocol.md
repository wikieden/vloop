# Loop Protocol — L1/L2/L3 执行手册

Mode A: the Claude Code session follows this protocol as orchestrator, invoking backends via Bash per adapters.md. Mode B: `scripts/vloop.sh` implements the same protocol. State transitions live in `.vloop/state.json` (atomic writes: tmp + mv); phases: `vet | implement | accept | hunt | deslop | replan | awaiting_human | done | cancelled` (vet/hunt/deslop only exist when their optional roles are configured).

## Optional roles (all opt-in via `loop.json` `backends.<role>`)

| Role | Phase/hook | Access | Contract |
|---|---|---|---|
| **vetter** | `vet` — once, before first planning | read-only | Reviews PRD against security/data/perf/falsifiability checklist. `blocking:true` → escalate to human; else findings append to decisions.md. Anti-pattern it kills: unvetted PRDs silently missing whole quality dimensions. |
| **tester** | inside L1, before each executor call | write | Writes RED tests for the assigned task. Orchestrator hashes the files it touched; if the executor then modifies any of them → failed iteration ("never grade your own homework", enforced structurally, not by prompt). `blocked` verdict escalates. |
| **qa** | start of `accept`, before the judge | write (discarded) | Executes verify_hints/e2e/browser flows, writes `.vloop/runs/qa-evidence.md` for the judge's `{{QA_EVIDENCE}}`. Any code changes it leaves are rolled back — evidence only. Judge stays read-only; qa does the running. |
| **oracle** | on executor `blocked` verdict | read-only | ONE consult per task (state.oracle_task) before human escalation. Advice injected as next iteration's feedback; `ESCALATE:` prefix or empty answer → straight to human. |
| **hunter** | `hunt` — after first acceptance pass, once per milestone | read-only | Sweeps the milestone diff for placeholders/stubs/mocks/assertion-free tests. Findings → judge-feedback → one replan round (counts toward max_redesign_rounds; cap exhaustion escalates instead). Clean → proceed. |
| **cleaner** | `deslop` — after hunt (or acceptance), once per milestone | write | Behavior-neutral slop cleanup, then full gate re-run: green → `vloop(deslop)` commit; regression → entire pass discarded via clean_tree. Never blocks the milestone. |
| **summarizer** | inside every `escalate()` | read-only | Produces the "Run summary" section of AWAITING_HUMAN.md from commits+progress (comprehension-rot guard). Failure degrades silently to the mechanical summary. Cheap model recommended. |
| **dispatcher** | end of `replan`, after the planner | write (plan.md only) | Re-tags `[agent:]` routing. Structurally constrained: orchestrator diffs the plan with tags stripped — any change beyond tags restores the planner's version. |
| **harvester** | `harvest` — after deslop, once per milestone | write (.vloop knowledge files only) | Distills the run's learnings into `.vloop/AGENT.md` (build/run knowledge) and `.vloop/learnings.md` (append-only, dated) — knowledge compounds across runs, transcripts don't. Receives a mechanical **divergence digest** (iterations where the executor claimed success but gates disagreed, from per-iteration `outcome.txt` forensics) and writes one `[divergence]` prevention rule per incident — that rule is the prompt fix the operator should make. Repo changes discarded. |
| **redteam** | `redteam` — after hunt, per milestone | read-only | Adversarial gate review (hacker-fixer pattern): hunts routes to satisfy the acceptance gate WITHOUT solving the problem (shallow checks, criterion gaps, test-shaped evasion, ratchet abuse). A bypass the current code exploits (file:line evidence required) → acceptance failure → replan, and the red team **re-verifies after the fix** (redteam_done only sets on a clean/theoretical outcome; bounded by max_redesign_rounds). Theoretical bypasses → advisory in the milestone report — criteria hardening is the human's call. |
| **holdout** | start of every `accept` round | write (`.vloop/holdout/` quarantine only) | Generates black-box acceptance tests from the PRD that the executor has NEVER seen, fresh each round (randomized). `run.sh` exit ≠ 0 structurally rejects the milestone regardless of judge opinion. Use a backend ≠ executor. |
| **merger** | RESERVED | — | Integrates parallel L1 lanes (Gas Town pattern). The single-lane orchestrator ignores it; defined so configs are forward-compatible if/when parallel lanes land. |

Full pipeline order when everything is on: `vet → [tester → executor]×N → qa → judge → hunt → redteam → deslop → harvest → summarizer → human`. Every role is independent — enable any subset.

## Orchestrator context discipline (Mode A)

- Backend outputs go to `.vloop/runs/iter-N/` files; read only tail/summary into context.
- Never paste plan history or prior-iteration transcripts into prompts — templates reference files.
- After each iteration keep only: phase, iteration count, one-line result. Everything else is on disk.
- On compaction/session restart: rebuild from `state.json` + `progress.md` + `git log`, never from memory. Never re-run tasks whose commits exist.

## L1 — implement phase

**Task assignment is deterministic, not agent-chosen.** The orchestrator — not the executor — picks the next task: the first unchecked `- [ ]` line in `plan.md`, top to bottom (planner already orders by priority). This is what makes per-task backend routing possible: since the orchestrator knows which task is about to run *before* invoking anything, it can read that task's optional `[agent: <backend>]` tag and launch the matching CLI. An executor that chose its own work could never be pinned to a specific backend per task.

**Mixed-agent loops**: tag any task line with `[agent: <backend>]` — a bare backend id (`claude`, `codex`, `opencode`, `gemini`, `aider`, `copilot`, `cursor-agent`, `droid`, `amp`, `qwen`, `goose`, `kiro-cli`; reuses the default executor's model/danger/readonly settings) or a name defined in `loop.json` `backends.pool.<name>` (own model/danger/readonly, e.g. `[agent: gemini-bulk]` for a large-context migration on gemini-3-pro while everything else runs on claude). Untagged tasks use `backends.executor`. An unrecognized tag logs a warning and falls back to the default executor rather than failing the loop — a planner typo should never brick a run. The planner (PROMPT-replan.md) is instructed to tag tasks only when a backend genuinely suits the work better (e.g. a mechanical multi-file rename → `aider`, a large-context refactor → a big-context model via the pool).

Per iteration (fresh context, executor backend — possibly overridden per task):

1. **Pre-flight**: `git status --porcelain` must be clean (uncommitted leftovers from a failed iteration → `git checkout . && git clean -fd` within the worktree — the ratchet is commits, rollback beats fix-forward). Check caps: iteration < max_iterations; budget ledger < budget_usd; else → L3 escalation.
2. **Pick task**: parse `plan.md` for the first unchecked task; if none remain but phase is still `implement`, that means all tasks were ticked without the last verdict saying `done` — treat it as a completed plan (not an error) and proceed to L2 acceptance directly.
3. **Assemble prompt** from `templates/PROMPT-implement.md`, substituting: `{{TASK_ID}}` / `{{TASK_LINE}}` (the assigned task only — the executor is told not to pick different work), `{{PLAN}}` (full plan.md, for context only), `{{PROGRESS_TAIL}}` (last ~30 lines of progress.md), `{{AGENT_MD}}`, `{{GATE_FEEDBACK}}` (previous iteration's gate failure evidence, truncated to ~200 lines, or "none").
4. **Invoke executor** (adapters.md) with the resolved backend for this task, timeout `iteration_timeout_s`, output to `runs/iter-N/`.
5. **Validate verdict** `.vloop/verdict.json` against schema `{status: done|continue|blocked, task_id, evidence, notes_for_next_iteration}`. Missing/invalid → failed iteration. **`verdict.task_id` must equal the assigned task id** — a mismatch (executor worked on the wrong task) is also a failed iteration, not silently accepted; GATE_FEEDBACK explains the mismatch.
6. **Run gates** serially (`gates[]` from loop.json), capturing output to `runs/iter-N/gate-<name>.log`:
   - All pass AND `git diff` non-empty → commit `vloop(T<id>): <title> [iter N]<via backend if tagged>`; tick the task checkbox in plan.md; append one line to progress.md (`iter N: T<id> done, gates green, cost $X`).
   - Any gate fails → NO commit; GATE_FEEDBACK = failing gate tail; next iteration.
   - **Immediately after ticking**, if no `- [ ]` lines remain in plan.md → phase=accept right away (don't wait for a `done` verdict that may never come if the executor keeps reporting `continue`).
7. **Circuit breakers** (update counters in state.json):
   - HEAD + `git status --porcelain | shasum` unchanged 3 consecutive iterations → 1st trip: phase=replan (with "stuck" evidence); 2nd trip: phase=awaiting_human.
   - Same normalized error signature (first failing test name + error class) 5 consecutive → same escalation path.
   - **Liveness** (adapter-level): a backend producing NO output for `caps.idle_timeout_s` (default 600) is killed (exit 125) — hung browser waits/tty prompts/network stalls that iteration counters can't see. Wall-clock per invocation stays `iteration_timeout_s` (exit 124).
   - **Run wall-clock budget**: `caps.max_wall_hours` (default 12) since started_epoch → escalate. The $6k-overnight-runaway guard; independent of iteration caps.
   - **Review stalemate** (L2-level, see accept phase): judge findings identical for `caps.review_patience` (default 2) consecutive redesign rounds → escalate as judge/executor deadlock. Executor-side breakers can't detect this.
   - Rate-limit/5h-window detected in backend output → sleep until reset; does NOT consume an iteration.

**Baseline-delta gates** (dirty-repo support): a gate with `"baseline": true` captures pre-existing failure signatures ONCE at loop start (`.vloop/baseline/gate-<name>.sig`, lines matching `fail_pattern`, normalized+sorted). On failure, only NEW signatures vs baseline block; pre-existing ones are waived with a log line. A red gate with ZERO matchable failure lines is an infrastructure error (command missing/crashed) and always blocks — an empty signature must never read as "no new failures".
8. **Transition**: plan fully ticked (previous step) or verdict `done` → phase=accept. Verdict `blocked` → phase=awaiting_human. Else next iteration.

Verdict is a claim, not proof: `done` with unticked boxes or empty diff = failed iteration.

## L2 — accept phase

0. **Structural evidence first** (both optional, both outrank the judge):
   - **holdout** role configured → invoke the generator (different backend) to write fresh, never-seen-by-the-executor tests into `.vloop/holdout/round-R/` with a `run.sh` entry; orchestrator runs it — non-zero exit structurally rejects the round. Regenerated every round, so peeking at a stale round buys nothing.
   - `acceptance_checks[]` in loop.json → run each command; any non-zero exit structurally rejects the round. These are milestone-level (once per acceptance, may be slow: e2e/smoke), unlike per-iteration gates.
   - On structural failure: the passes ratchet is WITHHELD even if the judge says pass, and judge-feedback leads with the executable evidence. A model's opinion never outranks an exit code.
1. **Invoke judge**: different backend, physically read-only (adapters.md readonly invocation). Prompt from `templates/PROMPT-judge.md` with `{{PRD}}`, `{{DIFF_STAT}}` (branch diff vs base, stat + capped diff), `{{GATE_LOGS}}` (latest green gate summary), `{{QA_EVIDENCE}}` (qa + holdout + check results). Judge writes `.vloop/acceptance.json`: `{story_id, criteria: [{id, pass, evidence}], overall: pass|fail}` per story.
2. **Ratchet**: for stories where ALL criteria pass AND structural evidence is green → orchestrator (never the agent) sets `passes:true` in prd.json.
2b. **Score gate**: the judge also emits `scores` (correctness/craft/design/functionality, 0–1, rubric in PROMPT-judge.md). If `caps.score_thresholds` is set and any dimension falls below it, an otherwise-passing milestone goes back to replan with "raise the low dimensions WITHOUT breaking passing criteria" (counts as a redesign round; cap exhaustion escalates). Missing scores = advisory only — an old prompt or weak judge never hard-fails a passing milestone here. Turns craft/design into a gate instead of a vibe (LOOPS.md rule 6 / patterns 2–3).
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

**Risk-classed auto-approval** (opt-in, `l3_gates.auto_approve.enabled`): at milestone completion a DETERMINISTIC classifier (script, not LLM — auditable) computes risk from the branch diff: changed lines ≤ `max_diff_lines`, files ≤ `max_files`, zero `sensitive_paths` matches, zero breaker trips → LOW → the milestone completes without blocking on human review (decision logged to decisions.md + notification sent; **merge/deploy remain human action-class gates regardless**). Anything else → HIGH with explicit reasons, normal human queue. Rationale: the review queue is the bottleneck — spend human attention on high-risk changes only. The risk line is appended to the acceptance report either way.

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
