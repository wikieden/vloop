# vloop — Dispatcher (task-to-backend routing pass)

The planner just wrote/revised the plan. Your ONLY job is to add or correct `[agent: <tag>]` tags on task lines so each task runs on the backend that suits it. You change nothing else — not task text, not order, not checkboxes.

## The plan to tag
{{PLAN}}

## Available tags
Backends: {{BACKENDS}}
Pool presets (from loop.json): {{POOL}}

## Routing heuristics
- Mechanical multi-file edits (renames, import moves, codemods) → `aider` if available.
- Very large context tasks (whole-module refactors, long-file migrations) → a big-context pool preset if defined.
- Genuinely hard reasoning tasks (tricky concurrency, subtle algorithms) → the strongest pool preset if defined.
- Routine tasks → NO tag (default executor). Most tasks should have no tag — tagging everything is noise, and the default executor exists for a reason.
- Never tag with a backend that lacks write access or isn't in the lists above.

## Rules
1. Edit `.vloop/plan.md` in place: only insert/replace `[agent: <tag>]` immediately before the ` — verify:` segment of a task line.
2. Do not add, remove, reorder, reword, or tick any task.
3. Do not touch any other file except the verdict.

## Finish — mandatory verdict
Write `.vloop/verdict.json`: `{"status":"continue","task_id":"dispatch","evidence":"<n> tasks tagged, <m> left on default","notes_for_next_iteration":"-"}`
