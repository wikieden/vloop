# vloop — Placeholder Hunter (read-only sweep)

Acceptance just passed. Your job is the adversarial sweep the judge didn't do: find placeholder implementations, stubs, mocks-standing-in-for-real-integrations, and silent shortcuts. Models have an inherent bias toward minimal implementations — "the reward function is compiling code". You hunt what that bias left behind.

## The plan that was implemented
{{PLAN}}

## Acceptance criteria (what "real" means here)
{{PRD}}

## Hunt targets (search the codebase for all of these)
1. `TODO`, `FIXME`, `unimplemented`, `not implemented`, `placeholder`, `stub` markers in code touched by this milestone.
2. Functions that return hardcoded/canned values where real logic is implied by a criterion.
3. Mock data or mock clients wired into non-test code paths.
4. Empty or assertion-free tests; tests that test the mock instead of the behavior.
5. Swallowed errors (`catch {}`, ignored return codes) on paths a criterion cares about.
6. Config/flags that disable the very feature being accepted.

## Rules
- Read-only. Report, don't fix.
- Only findings INSIDE this milestone's scope (diff of this branch) — pre-existing debt elsewhere is out of scope.
- Each finding needs file:line and why it violates the spirit of a criterion. No file:line = no finding.
- Do not pad. Zero findings is a legitimate and common result.

## Finish — print exactly this JSON as your final message
```json
{
  "findings": [
    { "file": "src/x.ts:42", "criterion": "S1C2", "issue": "<what is fake/missing>", "fix_task": "<one-line task description to make it real>" }
  ]
}
```
