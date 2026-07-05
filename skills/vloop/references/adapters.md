# Adapters — 多 backend 调用矩阵

Uniform contract per role invocation: build command → run with timeout, stdin from /dev/null unless intentionally piping, **stdout and stderr captured separately** → normalize to `runs/iter-N/out.json` `{result_text, session_id, tokens_in, tokens_out, cost_usd, is_error}` → verdict read from `.vloop/verdict.json` (uniform file protocol; native schema flags are an optimization, not the mechanism).

**Mixed-agent loops** (different tasks routed to different backends): `adapter.sh invoke <role> <prompt_file> <outdir> [agent_tag]` takes an optional 4th arg. `agent_tag` is either a bare backend id (swaps `backend` only, keeps the role's `model`/`readonly`/`danger`) or a name defined in `loop.json` `backends.pool.<name>` (a full standalone `{backend, model, readonly, danger}` record). The orchestrator resolves the tag from the assigned task's `[agent: <tag>]` marker in `plan.md` — see loop-protocol.md's L1 section for how task assignment and backend routing are tied together.

## Invocation matrix (verified 2026-07; probe before trusting — flags drift)

| Backend | Execute (write) | Judge (read-only) | Resume | Notes |
|---|---|---|---|---|
| **claude** | `claude -p --output-format json --permission-mode acceptEdits --max-turns 40 < prompt.md` | `claude -p --output-format json --permission-mode plan < prompt.md` | `claude -p -r <session_id> ...` | prompt via **stdin** (large-prompt `-p` arg stalls). JSON: `.result .session_id .total_cost_usd .is_error .num_turns`. Budget: `--max-budget-usd`. `--max-turns` hidden from --help but real. Optional `--json-schema`, `--bare` for CI. Session resume scoped to same directory/worktree. |
| **codex** | `codex exec "$PROMPT" --json -s workspace-write -o runs/iter-N/last.txt` | `codex exec "$PROMPT" --json -s read-only -o ...`; or `codex exec review --base <branch> "<instructions>"` | `codex exec resume <thread_id> "$PROMPT"` | prompt as **arg**; piped stdin gets APPENDED as `<stdin>` block — keep stdin /dev/null. JSONL on stdout (`thread.started.thread_id`, `turn.completed.usage`), logs on stderr — **never merge streams**. Simplest parse: read the `-o` last-message file. No native budget cap → timeout wrapper. `--output-schema FILE` available. |
| **opencode** | `opencode run "$PROMPT" -m <provider/model> --format json` | `opencode run "$PROMPT" --agent plan --format json` | `-s <session_id>`; `--fork` to branch | No caps → timeout wrapper + orchestrator token estimate. `--attach <url>` reuses a running server for cheap repeat calls. |
| **gemini** | `gemini -p "$PROMPT" --output-format json --approval-mode auto_edit` | `gemini -p "$PROMPT" --output-format json --approval-mode plan` | `--resume latest` | JSON: `.response .stats .error`. Exit codes: 0 ok, 42 invalid input, **53 = turn limit** (only CLI signaling runaway via exit code). Non-TTY stdin auto-triggers headless. |
| **aider** | `aider --message-file prompt.md --yes-always --no-auto-commits [--test-cmd '<gate>' --auto-test] FILES` | — (no read-only mode; don't use as judge) | — | Built-in implement-verify-fix microloop via `--auto-test/--auto-lint` (gates delegated to aider when configured so). No JSON; parse exit code + git diff. Orchestrator owns commits (`--no-auto-commits`). |
| **copilot** (1.0.x) | `copilot -p "$P" -s --no-ask-user --allow-all-tools` | `copilot -p "$P" -s --plan --allow-all-tools` | `--resume=<session_id>` | `--allow-all-tools` REQUIRED for non-interactive; `--no-ask-user` stops mid-run questions; `-s` = response-only stdout. Danger tier: `--allow-all`. `--output-format json` exists (JSONL) but `-s` text is the stable parse. |
| **cursor-agent** | `cursor-agent "$P" -p --output-format text --trust --force` | `cursor-agent "$P" -p --mode plan --trust` | `--resume <chatId>` | `--trust` REQUIRED in headless (skips workspace-trust prompt). `--force` = auto-approve (alias `--yolo`). Native worktrees (`-w`) and sandbox (`--sandbox`) available. |
| **droid** | `droid exec -f prompt.md -o json --auto medium` | `droid exec -f prompt.md -o json` (NO `--auto` = native read-only spec mode) | `droid exec -s <session_id> "$P"`; branch: `--fork <id>` | JSON = single Claude-style object (`.result .session_id .is_error .num_turns`). Autonomy tiers: low=edits, medium=+builds/local git, high=+push/deploy. Danger: `--skip-permissions-unsafe` (excludes `--auto`). Resume flag is `-s/--session-id`, NOT `--session`. Auth: `FACTORY_API_KEY`. |
| **amp** | `amp -x --stream-json --no-archive-after-execute < prompt.md` | — (no read-only mode; don't use as judge) | `amp threads continue <threadId> -x "$P"` | `-x` with no arg reads prompt from stdin. stream-json = Claude-Code-compatible JSONL. `--dangerously-allow-all` hidden-but-real after the 2026 permissions overhaul. No model flag (modes: `-m deep\|rush\|smart`). Execute mode burns paid credits. Threads auto-archive without `--no-archive-after-execute`. |
| **qwen** (0.19+) | `qwen --approval-mode auto --output-format json --max-session-turns 50 < prompt.md` | `qwen --approval-mode plan --output-format json < prompt.md` | `-r <sessionId>` (+`--fork-session`) | gemini-cli fork but DIVERGED: JSON is a Claude-style message ARRAY (`.[] \| select(.type=="result") \| .result`), NOT gemini's shape; approval modes hyphenated (`auto-edit`); native caps `--max-session-turns` (exit 53) / `--max-wall-time` / `--max-tool-calls` (exit 55). `auto` = LLM-classified safe-approve, good unattended default; danger: `--yolo`. |
| **goose** | `GOOSE_MODE=auto goose run -i prompt.md --no-session -q --max-turns 40 --max-tool-repetitions 5` | — (no read-only mode; don't use as judge) | `-r --session-id <id>` (conflicts with `--no-session`) | Approvals via `GOOSE_MODE` env, not a flag. Native anti-loop caps (`--max-turns`, `--max-tool-repetitions`). `-q` = response-only stdout. Provider/model via `--provider/--model` or env. |
| **kiro-cli** | `kiro-cli chat --no-interactive --trust-all-tools "$P"` | `kiro-cli chat --no-interactive --trust-tools=fs_read "$P"` | `--resume-id <session_id>` | `--trust-tools=fs_read` = read-only tool allowlist (judge mode). No JSON output for chat (text parse). Sessions are per-directory. |

Danger flags (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`, `--yolo`, `--auto`): only when loop.json isolation is worktree or docker AND `danger: true` was explicitly configured.

## Capability probing (`adapter.sh probe`)

Per configured backend, record into `.vloop/backends.json`:
```json
{ "claude": { "version": "2.1.197", "json_output": true, "schema_output": true, "budget_cap": true,
  "turn_cap": true, "resume": true, "readonly_mode": true, "danger_flag": "--dangerously-skip-permissions" } }
```
Probe technique: `--version` first; for critical flags run the CLI with the flag and NO argument — "argument missing" error ⇒ flag exists (even if hidden from --help); "unknown option" ⇒ absent. Never hardcode: claude's `--max-turns` is hidden-but-real; codex `--full-auto` is deprecated; gemini JSON output had docs-before-reality gaps.

## Parsing rules

- claude: `jq -r '.result, .session_id, .total_cost_usd, .is_error'` on stdout.
- codex: prefer the `-o` file for the message; `grep '"type":"turn.completed"'` on stdout JSONL for usage tokens; `thread.started` for thread_id. Provider errors can hide behind exit 0 → check for `error` items in JSONL.
- gemini: `jq -r '.response, .stats, .error'`; map exit 53 → iteration failed with "turn limit" signature.
- opencode: consume `--format json` events; fall back to raw text on truncation.
- All: truncated/unparseable JSON → text-mode fallback, mark `is_error` unknown, treat iteration as failed rather than guessing success.

## Cost ledger

Only claude reports USD. Ledger entry per iteration in state.json: `{iter, backend, tokens_in, tokens_out, usd}` — claude: native `total_cost_usd`; codex/gemini: tokens × pricing table (`templates/pricing.json`, user-editable); opencode/aider: estimate by wall-time × configured rate, flag as estimate. Global `budget_usd` compares against the SUM across backends. Rate-limit/5h-window handling: detect (structured event → exit code → text fallback, in that order), sleep until reset, don't consume iterations, don't rotate backends silently (log it).

## Long-lived processes

The orchestrator owns dev servers / preview browsers (start before the loop, pass URLs in prompts, kill after). `claude -p` reaps agent-started background processes ~5s after the result — an agent-started dev server WILL die between iterations.
