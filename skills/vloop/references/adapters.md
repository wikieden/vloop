# Adapters — 多 backend 调用矩阵

Uniform contract per role invocation: build command → run with timeout, stdin from /dev/null unless intentionally piping, **stdout and stderr captured separately** → normalize to `runs/iter-N/out.json` `{result_text, session_id, tokens_in, tokens_out, cost_usd, is_error}` → verdict read from `.vloop/verdict.json` (uniform file protocol; native schema flags are an optimization, not the mechanism).

## Invocation matrix (verified 2026-07; probe before trusting — flags drift)

| Backend | Execute (write) | Judge (read-only) | Resume | Notes |
|---|---|---|---|---|
| **claude** | `claude -p --output-format json --permission-mode acceptEdits --max-turns 40 < prompt.md` | `claude -p --output-format json --permission-mode plan < prompt.md` | `claude -p -r <session_id> ...` | prompt via **stdin** (large-prompt `-p` arg stalls). JSON: `.result .session_id .total_cost_usd .is_error .num_turns`. Budget: `--max-budget-usd`. `--max-turns` hidden from --help but real. Optional `--json-schema`, `--bare` for CI. Session resume scoped to same directory/worktree. |
| **codex** | `codex exec "$PROMPT" --json -s workspace-write -o runs/iter-N/last.txt` | `codex exec "$PROMPT" --json -s read-only -o ...`; or `codex exec review --base <branch> "<instructions>"` | `codex exec resume <thread_id> "$PROMPT"` | prompt as **arg**; piped stdin gets APPENDED as `<stdin>` block — keep stdin /dev/null. JSONL on stdout (`thread.started.thread_id`, `turn.completed.usage`), logs on stderr — **never merge streams**. Simplest parse: read the `-o` last-message file. No native budget cap → timeout wrapper. `--output-schema FILE` available. |
| **opencode** | `opencode run "$PROMPT" -m <provider/model> --format json` | `opencode run "$PROMPT" --agent plan --format json` | `-s <session_id>`; `--fork` to branch | No caps → timeout wrapper + orchestrator token estimate. `--attach <url>` reuses a running server for cheap repeat calls. |
| **gemini** | `gemini -p "$PROMPT" --output-format json --approval-mode auto_edit` | `gemini -p "$PROMPT" --output-format json --approval-mode plan` | `--resume latest` | JSON: `.response .stats .error`. Exit codes: 0 ok, 42 invalid input, **53 = turn limit** (only CLI signaling runaway via exit code). Non-TTY stdin auto-triggers headless. |
| **aider** | `aider --message-file prompt.md --yes-always --auto-commits [--test-cmd '<gate>' --auto-test] FILES` | — (no read-only mode; don't use as judge) | — | Built-in implement-verify-fix microloop via `--auto-test/--auto-lint` (gates delegated to aider when configured so). No JSON; parse exit code + git diff. |

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
