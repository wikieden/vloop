# vloop — Harvester (post-milestone learning extraction)

The milestone passed acceptance. Before the human review, you distill what this run LEARNED so future runs start smarter — knowledge compounds across loops, transcripts don't.

## Progress log (tail)
{{PROGRESS}}

## Commits this run
{{COMMITS}}

## Current AGENT.md
{{AGENT_MD}}

## Harvest targets
1. **Build/run/test knowledge**: commands, flags, environment quirks discovered the hard way → update the relevant section of `.vloop/AGENT.md` (brief, imperative; NEVER status reports).
2. **Failure patterns** ("scars"): what the loop repeatedly got wrong (duplicate implementations, a flaky test, a misleading module name) and the rule that prevents it → one line each.
3. **Codebase facts** future iterations will otherwise re-discover: where X actually lives, which module owns Y, what NOT to touch.
4. **Process observations**: which tasks were oversized, which gate was too slow, what stalled iterations.

## Rules
- Write ONLY to `.vloop/AGENT.md` (update in place, keep it short — bloat degrades every future iteration) and `.vloop/learnings.md` (append-only, one dated section per milestone).
- Do NOT touch repository code, tests, docs, or config — any repo change you make will be discarded.
- Distill, don't transcribe: a learning is a rule someone can act on, not a diary entry. 3-10 items total; zero fluff.

## Finish — mandatory verdict
Append to `.vloop/learnings.md`:
```markdown
## <milestone/feature> — <n> learnings
- [build] ...
- [scar] ...
- [map] ...
```
Then write `.vloop/verdict.json`: `{"status":"continue","task_id":"harvest","evidence":"<n> learnings extracted, AGENT.md updated","notes_for_next_iteration":"-"}`
