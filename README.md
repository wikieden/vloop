# vloop — Three-Layer Closed-Loop Engineering for AI Coding Agents

English | [中文](README.zh-CN.md)

A loop-engineering skill that runs AI coding agents in nested closed loops. 12 supported backends: **claude · codex · opencode · gemini · aider · copilot · cursor-agent · droid (Factory) · amp · qwen (Qwen Code) · goose · kiro-cli** — every adapter verified against the live CLI or current official docs, with capability probing at setup time (flags drift fast).

```
L3 Human loop        review branch / update requirements (PRD) / roll back
                     ← the only layer that may change requirements or approve irreversible actions
L2 Acceptance loop   independent READ-ONLY judge (different backend) verifies every acceptance
                     criterion; on failure a planner redesigns the plan and feeds L1 (≤3 rounds)
L1 Execute loop      one task per fresh-context iteration → backpressure gates (build/test/lint)
                     → green ⇒ commit (ratchet)
```

**Core principle: every layer's "done" is only a claim until the layer outside confirms it.**

- Verdicts are schema-validated files, not magic strings (sentinels get faked; agents lie to exit loops).
- The judge runs on a *different* backend in a *physically read-only* mode — an implementer must never grade its own homework, and a judge with write access may fix-to-pass.
- Every layer is hard-capped: max iterations, max redesign rounds (≤3 — cross-model review loops diverge past that), budget USD, per-iteration timeout, plus a circuit breaker (3 no-progress / 5 same-error iterations).
- Human action-class gates (merge / deploy / publish / delete / charge / close) can never be disabled by config.
- Rollback beats fix-forward: failed iterations are discarded; broken code contaminates later iterations.

Design distilled from the Ralph technique (ghuntley), six open-source loop implementations analyzed at source level, HN practitioner consensus, and locally verified headless-CLI adapter mechanics. Full research digest in [docs/RESEARCH.md](docs/RESEARCH.md) (Chinese; sources are English).

## Layout

| Path | Contents |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Full architecture: layers, protocols, configurator, adapter layer, safety (Chinese) |
| [docs/RESEARCH.md](docs/RESEARCH.md) | Research digest: Ralph canon, GitHub implementations, HN field reports, CLI adapter matrix |
| [skills/vloop/SKILL.md](skills/vloop/SKILL.md) | Skill entry point (setup / run / resume / status / cancel routing) |
| skills/vloop/references/ | configurator (bounded Q&A wizard) · loop-protocol (L1/L2/L3 playbook) · adapters (multi-backend matrix) · pitfalls (guardrail checklist) |
| skills/vloop/templates/ | loop.json · prd.json · plan.md · AGENT.md · pricing.json · role prompt templates |
| skills/vloop/scripts/ | vloop.sh (unattended orchestrator) · adapter.sh (backend invocation + normalization + cost ledger) |

## Install

vloop is a standard [Agent Skill](https://agentskills.io) (SKILL.md) — it installs once and works in **any of the 40+ hosts** that read the format: Claude Code, Codex, OpenCode, Cursor, Gemini CLI, GitHub Copilot, droid, goose, crush, amp, Kiro, ZCode, Antigravity, Trae, Windsurf, …

```bash
# recommended: one command, all detected hosts
npx vloop-skill install

# what it does:
#   canonical copy -> ~/.agents/skills/vloop   (codex/cursor/gemini/copilot/opencode/
#                                               goose/crush/amp read this natively)
#   + symlinks     -> ~/.claude/skills, ~/.zcode/skills, ~/.kiro/skills,
#                     ~/.factory/skills, ~/.gemini/antigravity/skills, ~/.qwen/skills, …
#                     (only for hosts detected on your machine)

npx vloop-skill doctor       # verify deps (jq/python3/git), hosts, loop backends
npx vloop-skill uninstall    # clean removal (tracked by its own manifest)
```

Alternatives:
```bash
npx skills add wikieden/vloop        # the ecosystem installer (vercel-labs/skills, 70+ agents)
npx github:wikieden/vloop install    # run the installer straight from GitHub, no npm needed
```

Runtime deps for the loop orchestrator: `bash`, `git`, `jq`, `python3`, plus whichever backend CLIs you configure.

### Use without any host (pure CLI)

Mode B needs no agent host at all:
```bash
npx vloop-skill init   # scaffold .vloop/loop.json + prd.json templates
# edit them, then:
npx vloop-skill run    # unattended 3-layer loop; exit 42 = awaiting human review
```

## Usage

```
/vloop setup            # bounded Q&A configurator (≤5 multiple-choice questions × 2 rounds)
                        #   → .vloop/loop.json + .vloop/prd.json (falsifiable acceptance criteria)
/vloop run              # Mode A: current session orchestrates (observable; recommended first run)
/vloop run --unattended # Mode B: vloop.sh external loop (overnight; exit code 42 = awaiting human)
/vloop resume           # after human review: PRD diff → regenerate plan → re-enter L2/L1
/vloop status | cancel
```

The configurator interviews you with lettered options (answer compactly: "1A 2C"), detects installed backends and gates, and refuses to start without every cap set — an unbounded loop is a config error, not a preference.

## Verified

- End-to-end mock test (shim backends): L1 commit ratchet + task ticking → L2 read-only judge verdict extraction + `passes` ratchet → L3 pause artifact (`AWAITING_HUMAN.md` with cost ledger, commits, lettered questions) + exit 42 ✓
- Failure paths: gate-failure rollback, invalid verdict counted as failed iteration, breaker trip 1 → replan, trip 2 → L3 escalation ✓
- Cross-backend cost ledger (claude native USD + token-priced backends) ✓
- bash 3.2 compatible (macOS default shell) ✓

## License

[MIT](LICENSE)
