# vloop — Three-Layer Closed-Loop Engineering for AI Coding Agents

English | [中文](README.zh-CN.md)

Run AI coding agents in nested closed loops that don't trust themselves. One skill, standard [Agent Skills](https://agentskills.io) format — install once, works in **40+ hosts** (Claude Code, Codex, Cursor, OpenCode, Gemini CLI, Copilot, ZCode, Antigravity, …). Orchestrates **12 backends**: claude · codex · opencode · gemini · aider · copilot · cursor-agent · droid · amp · qwen · goose · kiro-cli.

```
L3  Human loop        review / update requirements (PRD) / roll back — the only layer
                      that may change requirements or approve irreversible actions
L2  Acceptance loop   held-out tests + executable checks + independent READ-ONLY judge
                      (different backend); failure → planner redesigns → back to L1 (≤3 rounds)
L1  Execute loop      one task per fresh-context iteration → backpressure gates
                      (build/test/lint) → green ⇒ commit (ratchet)
```

**Every layer's "done" is only a claim until the layer outside confirms it** — and a model's opinion never outranks an exit code.

## The verification stack

Agents fake completion: they quote magic strings, mark failing tests "probably unrelated", mock data past green checks, and talk reviewers into passing them. vloop stacks five independent defenses, each closing the previous one's bypass:

| Layer | Mechanism | Closes |
|---|---|---|
| 1 | **Backpressure gates** per iteration (build/test/lint; serial, fast); `baseline: true` delta mode for dirty repos — only NEW failure signatures block | "it compiles" ≠ done |
| 2 | **Schema-validated verdict files** + orchestrator-owned task assignment (verdict `task_id` must match; empty diff rejected) | magic-string sentinels, wrong-task drift |
| 3 | **TDD hash protection** (opt-in `tester` role): test author ≠ implementer; modifying the tests fails the iteration structurally | self-graded homework |
| 4 | **Held-out tests** (opt-in `holdout` role): black-box tests the executor has *never seen*, regenerated fresh every round; plus `acceptance_checks[]` executable verifiers — exit codes overrule the judge | gaming visible tests, sweet-talking the judge |
| 5 | **Independent judge** on a *different backend* in a *physically read-only* mode + human action-class gates (merge/deploy/publish/delete/charge/close — never disableable) | fix-to-pass judges, unreviewed irreversible actions |

Runaway protection: per-iteration timeout, liveness watchdog (no-output kill), circuit breakers (3 no-progress / 5 same-error), review-stalemate detection (identical judge findings = deadlock), hard wall-clock / USD / token budgets. An unbounded loop is a config error — vloop refuses to start without every cap set.

## Roles

Three core roles, ten opt-in specialists — enable any subset in `loop.json`:

| | Role | Does |
|---|---|---|
| core | **planner** | writes/redesigns `plan.md` (one task = one context window) |
| core | **executor** | one task per fresh-context iteration; per-task backend override |
| core | **judge** | read-only, different backend; sole source of `passes: true` |
| opt-in | **vetter** | one-shot PRD review before planning (blocking findings pause for the human) |
| opt-in | **tester** | writes RED tests before the executor; hash-protected |
| opt-in | **qa** | runs e2e/verify-hints before the judge, records evidence |
| opt-in | **oracle** | one second-opinion per blocked task before bothering the human |
| opt-in | **hunter** | post-acceptance placeholder/mock sweep |
| opt-in | **cleaner** | deslop pass; discarded if regression gates fail |
| opt-in | **harvester** | distills run learnings into AGENT.md — knowledge compounds across runs |
| opt-in | **holdout** | generates never-seen acceptance tests, fresh each round |
| opt-in | **summarizer** | run digest for the human handoff (cheap model) |
| opt-in | **dispatcher** | re-tags per-task `[agent:]` routing after replans |

Full pipeline when everything is on: `vet → [tester→executor]×N → qa → holdout/checks → judge → hunt → deslop → harvest → summarize → human`.

Every role's overreach has a **structural** check, not a prompt-level plea: tester files are hash-compared, dispatcher edits are tag-stripped-diff-verified, qa/harvester repo changes are rolled back, the judge physically cannot write.

## Quick start

```bash
npx vloop-skill install      # canonical copy -> ~/.agents/skills/vloop (codex/cursor/gemini/
                             # copilot/opencode/goose/crush/amp read natively) + symlinks into
                             # detected hosts (~/.claude, ~/.zcode, ~/.kiro, ~/.factory, …)
npx vloop-skill doctor       # check deps (bash/git/jq/python3), hosts, backends
```

Then, inside your agent:

```
/vloop setup                 # bounded Q&A configurator (≤5 multiple-choice questions × 2 rounds)
/vloop run                   # Mode A: your session orchestrates — observable, first-run friendly
/vloop run --unattended      # Mode B: external bash loop — overnight; exit 42 = awaiting human
/vloop resume                # after human review: PRD diff → replan → re-enter
/vloop status | cancel
```

Alternatives: `npx skills add wikieden/vloop` (ecosystem installer, 70+ agents) · `npx github:wikieden/vloop install` (straight from GitHub) · `--project` for repo-local install.

No agent host at all? Mode B is pure CLI: `npx vloop-skill init` (scaffold `.vloop/` config), edit, `npx vloop-skill run`.

Runtime deps: `bash`, `git`, `jq`, `python3`, plus the backend CLIs you configure — each must be interactively logged in once before the loop runs.

## Two run shapes

**Single-agent tiered (default).** The whole loop runs on the host you're already in; roles split by tier — strong model/effort plans and judges (read-only), standard tier executes. `fable-5` plans / `sonnet-5` executes on claude; `xhigh` / `medium` effort on codex. One CLI, zero cross-vendor setup.

**Mixed-agent routing (opt-in).** The orchestrator — not the executor — picks each task (first unchecked line in `plan.md`), so it knows which backend to launch before invoking anything. Tag any task:

```markdown
- [ ] T1: add DB migration (covers: S1C1) — verify: npm test -- migrate
- [ ] T2: rename userId -> accountId repo-wide (covers: S1C2) [agent: aider] — verify: npm test
- [ ] T3: refactor the 40k-line legacy module (covers: S1C3) [agent: gemini-bulk] — verify: npm test
```

Bare ids reuse the default executor's settings; `backends.pool.<name>` presets carry their own model/effort/danger. The planner tags tasks itself when a backend genuinely fits better; unknown tags warn and fall back instead of failing. Commits are labeled (`vloop(T2): iter 4 green via aider`).

**Risk-classed auto-approval (opt-in, `l3_gates.auto_approve`).** A deterministic script classifier (auditable — no LLM) passes LOW-risk milestones (small diff, no sensitive paths, clean run) without blocking on human review. Anything else queues for the human with explicit reasons. Merge and deploy remain human, always.

## Usage by agent

Every host loads the same `SKILL.md`; only invocation syntax differs.

| Host | Invoke |
|---|---|
| Claude Code, Cursor, Copilot CLI, Factory droid, Kiro | `/vloop setup` (native slash command) |
| Codex CLI, ZCode | `$vloop setup` (ZCode: Settings → Skills → Refresh once after install) |
| OpenCode, Gemini CLI, Antigravity | mention "vloop" — skill-tool activation, consent-gated where applicable |
| goose, amp, crush, qwen, other `~/.agents/skills` readers | mention "vloop" / "loop engineering" in the instruction |
| Zed | `/vloop` in any agent thread (native `~/.agents/skills` support); pairs well with Parallel Agents for interactive work |
| No host — pure CLI | `npx vloop-skill init && npx vloop-skill run` |

Skill missing somewhere? `npx vloop-skill doctor` reports detected hosts and link state.

## Layout

| Path | Contents |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Full architecture: layers, protocols, configurator, adapters, safety (Chinese) |
| [docs/RESEARCH.md](docs/RESEARCH.md) | Research digest: Ralph canon, open-source loop implementations, HN field reports, CLI adapter matrix, 2026-07 ecosystem update |
| [skills/vloop/SKILL.md](skills/vloop/SKILL.md) | Skill entry point (setup / run / resume / status / cancel routing) |
| skills/vloop/references/ | configurator wizard · L1/L2/L3 protocol playbook · 12-backend adapter matrix · pitfalls checklist |
| skills/vloop/templates/ | loop.json · prd.json · plan.md · AGENT.md · pricing.json · 13 role prompt templates |
| skills/vloop/scripts/ | vloop.sh (unattended orchestrator) · adapter.sh (backend invocation + normalization + cost ledger) |
| bin/vloop-skill.js | npx installer: install / uninstall / doctor / init / run |

## Verified

Every mechanism ships with a shim-backend test: the three-layer happy path (commit ratchet → judge → milestone, exit 42), failure paths (gate rollback, invalid/mismatched verdicts, breaker → replan → escalation), mixed-agent dispatch, tester-modification rejection, baseline-delta waiver + new-failure block + infra-error hard fail, review-stalemate escalation, liveness kill (rc 125), judge-pass-but-checks-fail ratchet withholding, holdout reject→fix→pass, LOW auto-approve with audit line, sensitive-path HIGH classification, installer lifecycle, cross-backend cost ledger. bash 3.2 (stock macOS) compatible.

## Provenance

Design distilled from the Ralph technique (ghuntley), source-level analysis of the open-source loop ecosystem (ralphex, ralph-orchestrator, spec-kit, pickle-rick, Gas Town, …), HN practitioner consensus, and locally verified headless-CLI mechanics — with ongoing adoption of what the ecosystem proves out. Digest with sources: [docs/RESEARCH.md](docs/RESEARCH.md).

## License

[MIT](LICENSE)
