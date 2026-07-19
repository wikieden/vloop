# Plan — CHANGE_ME (revision R0)
Initial plan. One task = one context window; the loop burns one task per iteration, top to bottom.
`[agent: <backend>]` is optional per task — omit to use the default executor. Example: `[agent: codex]`.
`[type: change|verify|research]` is optional (default change): change/research must land a diff; verify tasks land no diff and are ticked by the orchestrator from gate results.

- [ ] T1: CHANGE_ME imperative task (covers: S1C1) — verify: CHANGE_ME command
