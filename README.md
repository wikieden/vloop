# vloop — Three-Layer Closed-Loop Engineering for AI Coding Agents

English | [中文](README.zh-CN.md)

A loop-engineering skill that runs AI coding agents in nested closed loops. Ships as a standard [Agent Skill](https://agentskills.io) (SKILL.md) — install once, works across **40+ hosts**. 12 supported loop backends: **claude · codex · opencode · gemini · aider · copilot · cursor-agent · droid (Factory) · amp · qwen (Qwen Code) · goose · kiro-cli**.

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

## Install

```bash
# recommended: one command, installs into every host detected on your machine
npx vloop-skill install

# what it does:
#   canonical copy -> ~/.agents/skills/vloop   (codex/cursor/gemini/copilot/opencode/
#                                               goose/crush/amp read this natively)
#   + symlinks     -> ~/.claude/skills, ~/.zcode/skills, ~/.kiro/skills,
#                     ~/.factory/skills, ~/.gemini/antigravity/skills, ~/.qwen/skills, …
#                     (only for hosts actually detected)

npx vloop-skill doctor       # verify deps (jq/python3/git), hosts, loop backends
npx vloop-skill uninstall    # clean removal (tracked by its own manifest)
```

Alternatives:
```bash
npx skills add wikieden/vloop        # the ecosystem installer (vercel-labs/skills, 70+ agents)
npx github:wikieden/vloop install    # run the installer straight from GitHub, no npm publish needed
```

Project-scoped instead of global: add `--project` (writes to `.agents/skills/` and `.claude/skills/` in the current repo instead of your home dir).

Runtime deps for the loop orchestrator itself: `bash`, `git`, `jq`, `python3`, plus whichever backend CLIs you configure in `loop.json`.

### Use without any agent host (pure CLI)

Mode B needs no host at all — just the npm package and your chosen backend CLIs:
```bash
npx vloop-skill init   # scaffold .vloop/loop.json + prd.json templates in the current repo
# edit them (or copy from skills/vloop/templates/), then:
npx vloop-skill run    # unattended 3-layer loop; exit code 42 = awaiting human review
```

## Usage by agent

Once installed, every host loads the same `SKILL.md`; only the *invocation syntax* differs. Core commands regardless of host: `setup` (bounded Q&A configurator) · `run` (Mode A, observable) · `run --unattended` (Mode B, background) · `resume` (after human review) · `status` · `cancel`.

| Host | Invoke | Notes |
|---|---|---|
| **Claude Code** | `/vloop setup`, `/vloop run`, … | Native slash-command skill invocation. |
| **Codex CLI** | `$vloop setup` (or let it auto-trigger on mention) | Reads `~/.agents/skills` natively; skill picker via `/skills`. |
| **OpenCode** | mention "vloop" / "loop engineering" in a message | Skills are tool-invoked (`skill({name:"vloop"})`), not slash commands — the agent calls it when relevant; you can also say "use the vloop skill". |
| **Cursor (CLI/IDE)** | `/vloop setup` | Native slash-command; also auto-triggers on description match. |
| **Gemini CLI** | mention "vloop" or run `/skills list` then reference it | Activated via the `activate_skill` tool with per-activation consent, not a slash command. |
| **GitHub Copilot CLI** | `/vloop setup` | Slash-command style, same as Claude Code. |
| **Factory droid** | `/vloop setup` | Skills merged with custom commands — same `/name` UX. |
| **goose** | mention "vloop" in your instruction, or `goose run -t "use vloop to ..."` | No slash command; the built-in `skills` extension surfaces it by description. Check with `goose skills list`. |
| **Kiro / kiro-cli** | `/vloop setup` or `$vloop` | Auto-activates by description too; `/context show` lists loaded skills. |
| **ZCode** (Z.ai desktop ADE) | type `$vloop setup` in chat, or open the `/` Commands+Skills panel | One-time: Settings → Skills → Refresh after install. |
| **Antigravity** | mention "vloop" or pick it from the Agent Manager | Consent-gated auto-activation, like Gemini CLI. |
| **amp, crush, qwen, aider, opencode-derivatives, …** | mention "vloop" / "loop engineering" | Any host that reads `~/.agents/skills` picks it up by description match; there is no separate per-host doc to maintain. |
| **No host — pure CLI** | `npx vloop-skill init && npx vloop-skill run` | See above. |

If a host doesn't show the skill after install, run `npx vloop-skill doctor` — it reports which hosts were detected and whether their link exists.

## Layout

| Path | Contents |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Full architecture: layers, protocols, configurator, adapter layer, safety (Chinese) |
| [docs/RESEARCH.md](docs/RESEARCH.md) | Research digest: Ralph canon, GitHub implementations, HN field reports, CLI adapter matrix |
| [skills/vloop/SKILL.md](skills/vloop/SKILL.md) | Skill entry point (setup / run / resume / status / cancel routing) |
| skills/vloop/references/ | configurator (bounded Q&A wizard) · loop-protocol (L1/L2/L3 playbook) · adapters (multi-backend matrix) · pitfalls (guardrail checklist) |
| skills/vloop/templates/ | loop.json · prd.json · plan.md · AGENT.md · pricing.json · role prompt templates |
| skills/vloop/scripts/ | vloop.sh (unattended orchestrator) · adapter.sh (backend invocation + normalization + cost ledger) |
| bin/vloop-skill.js | npx installer: install / uninstall / doctor / init / run |

## Command reference

```
/vloop setup            # bounded Q&A configurator (≤5 multiple-choice questions × 2 rounds)
                        #   → .vloop/loop.json + .vloop/prd.json (falsifiable acceptance criteria)
/vloop run              # Mode A: current session orchestrates (observable; recommended first run)
/vloop run --unattended # Mode B: vloop.sh external loop (overnight; exit code 42 = awaiting human)
/vloop resume           # after human review: PRD diff → regenerate plan → re-enter L2/L1
/vloop status | cancel
```

Replace `/vloop` with your host's invocation style from the table above — the underlying protocol is identical everywhere.

The configurator interviews you with lettered options (answer compactly: "1A 2C"), detects installed backends and gates, and refuses to start without every cap set — an unbounded loop is a config error, not a preference.

## Verified

- End-to-end mock test (shim backends): L1 commit ratchet + task ticking → L2 read-only judge verdict extraction + `passes` ratchet → L3 pause artifact (`AWAITING_HUMAN.md` with cost ledger, commits, lettered questions) + exit 42 ✓
- Failure paths: gate-failure rollback, invalid verdict counted as failed iteration, breaker trip 1 → replan, trip 2 → L3 escalation ✓
- Cross-backend cost ledger (claude native USD + token-priced backends) ✓
- Installer lifecycle (fake-HOME install/link/doctor/uninstall), `npm pack` contents, `npx github:wikieden/vloop` direct-from-GitHub install ✓
- bash 3.2 compatible (macOS default shell) ✓

## License

[MIT](LICENSE)
