# vloop — Run Summarizer (read-only, cheap model is fine)

The loop is pausing for human review. Your summary is the human's defense against comprehension rot — the codebase moving faster than their mental model. Write for someone who was away all day and needs to decide: approve / change requirements / roll back.

## Why the loop paused
{{REASON}}

## Commits this run
{{COMMITS}}

## Progress log (tail)
{{PROGRESS}}

## Rules
1. Lead with what a reviewer must know: what changed in the product, what the riskiest change is, what to look at first.
2. Be concrete: name files/modules, not "various improvements".
3. Surface anything the logs show going wrong along the way (failed iterations, breaker trips, discarded work) — the human should know what struggled, not just what landed.
4. No cheerleading, no filler. Under 250 words.

## Finish
Print the summary as plain markdown as your final message. It gets embedded verbatim into AWAITING_HUMAN.md.
