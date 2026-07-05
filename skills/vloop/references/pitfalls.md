# Pitfalls — 启动前检查单与护栏

Run through this before the first L1 iteration. Every item traces to an observed failure in the field (sources in docs/RESEARCH.md).

## Pre-flight checklist

- [ ] Every cap set: max_iterations, max_redesign_rounds, budget_usd, iteration_timeout_s. Missing cap = refuse to start (unbounded ralph-loops run forever on impossible tasks).
- [ ] Judge backend ≠ executor backend, judge invocation is physically read-only. A judge with write access may fix-to-pass.
- [ ] Acceptance criteria pass the PRD-theater check: each one falsifiable, UI stories carry a browser-verification criterion. "Implementation is complete" 类空话 = 重写。
- [ ] Every plan task fits one context window (usable window degrades past ~150k of 200k; oversized tasks produce degraded mid-implementation code).
- [ ] Isolation exists (worktree/branch/docker) BEFORE any danger flag is written into loop.json. Unsandboxed YOLO exposes SSH keys/cookies/tokens; "it's not if it gets popped, it's when".
- [ ] Gates are fast ("the wheel has got to turn fast") and run serially. Dynamic language without a static analyzer in gates → add one (pyright/dialyzer/etc), or expect "a bonfire of outcomes".
- [ ] Human approved the initial plan (first L3 gate). Spec bugs compound silently — a duplicated keyword in a spec wasted a month of loops.
- [ ] Clean `git status` at start; base commit recorded for diff ranges (BASE..HEAD, never HEAD~1 — multi-commit tasks silently lose commits).

## Anti-fake-completion (structural, not prompt-level)

- Verdict `done` requires: all plan boxes ticked + non-empty diff + all gates green + judge sign-off downstream. Green checks are necessary, never sufficient.
- Completion sentinels can be faked or accidentally quoted — that's why vloop uses schema-validated verdict files + independent judge, not magic strings.
- Prompt constraints decay under difficulty ("NEVER MOCK DATA" gets ignored) → enforce structurally: gates that detect mocks/placeholders (grep TODO/unimplemented in diff), auto-revert on metric decrease (GOAL.md mode), periodic re-injection of hard rules in every prompt template.
- Goodhart guard (GOAL.md mode): the metric calculator is a file the executor may not modify (add to a gate: `git diff --name-only | grep -q goal-metric && fail`).

## Loop mechanics traps

- Fix-forward contaminates context: broken code + wrong assumptions poison later iterations. Failed iteration → discard working tree, rollback to last green commit, retry with better feedback.
- Duplicate implementations are Ralph's Achilles' heel (agent greps, concludes "not implemented", re-implements) → prompt rule "search before implementing" + periodic dedup sweep task.
- Placeholder bias: "the reward function is compiling code" → anti-placeholder prompt rules + a dedicated placeholder-hunt task when plan empties.
- State-file pollution: status reports leaking into AGENT.md; plan.md growing stale → prune completed items; when the plan goes off the rails, delete and regenerate it (planning loop), don't patch it.
- Two loops in one workspace conflict on state → `.vloop/state.json` records worktree path; refuse to start if another active state exists for the same worktree.
- Compaction/restart recovery: trust progress.md + git log over memory; never re-dispatch tasks whose commits exist (most expensive observed failure class).
- Questions in unattended mode: prompts must forbid clarifying questions; agent puts questions in verdict.notes → escalates to L3. Interactive tools (AskUserQuestion) don't exist in `-p` mode — deadlock otherwise. Same for Playwright without a TTY: use headless flags.

## Cost traps

- Only claude has a native USD brake. codex/opencode/gemini loops have NO spend cap → timeout wrapper + orchestrator ledger mandatory.
- Rate-limit windows (5h subscription windows, 429s) surface as mid-loop failures → detect and sleep-until-reset; otherwise the loop burns its entire iteration budget on guaranteed failures (observed: session-limit killed 5/6 research agents in one shot).
- Retry storms and fan-out are the blowout vectors; loops economical on API pricing or under monitored subscription caps only. Reference points: overnight runs commonly $10-50; Huntley's 3-month CURSED run ~$14k.
- Cheapest model ≠ cheapest run: weak models cost more via 2-3× turn counts. Strong model for planner/judge, standard for executor.

## Platform gotchas

- bash 3.2 on macOS: no `${var,,}`, no associative arrays; BSD vs GNU `date`/`timeout` (`gtimeout` or perl-alarm fallback). vloop.sh is written to this baseline.
- codex stdout JSONL corrupts if merged with stderr logs (observed live).
- claude `-p` reaps background processes ~5s post-result; piped stdin caps at 10MB; invalid settings files are silently ignored in `-p` mode (use `--bare` for CI-grade determinism).
- `--continue` hijacks whatever session was last active in the directory — always `--resume/-r <explicit id>`, and expire stored ids after 24h.
- Backend output to a TTY changes behavior (some CLIs hang waiting) — always run headless flags even under nohup.
