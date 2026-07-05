---
name: vloop
description: Three-layer closed-loop engineering for AI coding agents — L1 plan-execute loop, L2 product-acceptance/redesign loop, L3 human review/requirement-update loop, with 12 backends (claude/codex/opencode/gemini/aider/copilot/cursor-agent/droid/amp/qwen/goose/kiro-cli). Use when the user wants to set up, run, resume, or cancel an autonomous coding loop, mentions "vloop", "loop engineering", "ralph", overnight agent runs, or wants an agent to work through a PRD/plan with acceptance gates.
license: MIT
metadata:
  author: wikieden
  source: https://github.com/wikieden/vloop
---

# vloop — 三层闭环 Loop Engineering

Every "done" is only a claim until the layer outside confirms it:
L1 executes one task per fresh-context iteration → L2 judges against acceptance criteria with a DIFFERENT read-only backend and redesigns on failure (≤3 rounds) → L3 pauses for the human to approve, update requirements, or roll back.

## Commands

| Invocation | Action |
|---|---|
| `/vloop setup` | Run the bounded Q&A configurator → generates `.vloop/loop.json` + `.vloop/prd.json` |
| `/vloop run` | Mode A: this session orchestrates the loop (follow references/loop-protocol.md) |
| `/vloop run --unattended` | Mode B: launch `scripts/vloop.sh` in background (nohup), report how to monitor |
| `/vloop resume` | After human review: diff PRD changes → regenerate plan → re-enter L2/L1 |
| `/vloop status` | Read `.vloop/state.json` + `progress.md`, summarize phase/iteration/cost |
| `/vloop cancel` | Set `state.json` phase to `cancelled` (atomic write), report final state |

## Routing

1. **No `.vloop/loop.json`** → always run setup first. Read [references/configurator.md](references/configurator.md) and follow it exactly: two rounds, ≤5 multiple-choice questions each (AskUserQuestion in interactive sessions), answers persisted to files, never left in conversation.
2. **`run` (Mode A)** → read [references/loop-protocol.md](references/loop-protocol.md) and execute it as orchestrator. Invoke backends per [references/adapters.md](references/adapters.md). Before the first iteration, check every item in [references/pitfalls.md](references/pitfalls.md).
3. **`run --unattended` (Mode B)** → verify `loop.json` exists, verify backend capability manifest (`.vloop/backends.json`, regenerate via `scripts/adapter.sh probe` if stale), then:
   ```bash
   nohup skills/vloop/scripts/vloop.sh > .vloop/runs/vloop.out 2>&1 &
   ```
   Exit code 42 = AWAITING_HUMAN (L3 gate). Tell the user where `AWAITING_HUMAN.md` will appear and which notification channel is configured.
4. **`resume`** → read `.vloop/AWAITING_HUMAN.md` answers + PRD diff (`git diff` on prd.json / PRD file). Map changes: new/changed criteria → new plan tasks; removed stories → drop tasks; then reset `redesign_rounds` to 0, set phase per loop-protocol.md §Resume, and re-enter.

## Hard rules (structural, not stylistic)

- **Ratchets are one-way and owned**: only the orchestrator flips `prd.json` `passes:true`, and only on a judge verdict. The executor never edits prd.json. No commit unless all gates pass.
- **Judge ≠ executor**: different backend, physically read-only mode. Never let the implementer grade its own work.
- **Every layer capped**: max_iterations, max_redesign_rounds (default 3), budget_usd, iteration timeout. A missing cap is a config error — refuse to start.
- **Verdict protocol**: agent writes `.vloop/verdict.json` each iteration; missing/invalid verdict = failed iteration, not "continue".
- **State writes are atomic** (tmp file + mv). All state in `.vloop/`, session-independent.
- **File handoffs**: pass artifacts as file paths, never paste bulk output into prompts or keep it in orchestrator context.
- **L3 action classes always gate**: merge, deploy, publish, delete, charge, close — no exceptions, regardless of config.

## State files

`loop.json` (config) · `prd.json` (stories + acceptance ratchet) · `plan.md` (task checkboxes) · `progress.md` (append-only ledger) · `AGENT.md` (build/run knowledge, no status reports) · `state.json` (phase/counters/cost) · `verdict.json` (per-iteration) · `AWAITING_HUMAN.md` (L3 pause artifact) · `decisions.md` (append-only audit) · `runs/iter-N/` (raw outputs).

Full architecture and rationale: https://github.com/wikieden/vloop/blob/main/docs/DESIGN.md · research basis: https://github.com/wikieden/vloop/blob/main/docs/RESEARCH.md
