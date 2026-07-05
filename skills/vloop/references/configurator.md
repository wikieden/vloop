# Configurator — 问答式 + 选择题闭环设计

Bounded interview. Precedent: spec-kit `/clarify` (≤5 questions, options, answers persisted into the artifact) and snarktank prd (lettered options, compact answers like "1A 2C"). Free-text-heavy interviews are the anti-pattern.

In interactive Claude Code sessions use **AskUserQuestion** (one call per round, up to 4 questions per call — split round 1 into 2 calls if needed). In headless contexts, write the question list to `.vloop/AWAITING_HUMAN.md` and exit.

## Step 0 — Detect environment (before asking anything)

```bash
for cli in claude codex opencode gemini aider copilot cursor-agent droid amp qwen goose kiro-cli; do command -v $cli >/dev/null && echo "$cli: $($cli --version 2>/dev/null | head -1)"; done
git rev-parse --is-inside-work-tree 2>/dev/null   # not a repo → offer git init (required)
ls package.json Makefile Cargo.toml pyproject.toml 2>/dev/null   # gate auto-detection hints
```

Only offer installed backends as options. If <2 backends installed, warn: judge should differ from executor; same-backend fallback allowed only with a different model (e.g. executor opus / judge haiku is NOT acceptable for judging — prefer strongest model for judge).

**Single-backend tiered preset ("claude-tiered")** — when the user has only claude (or explicitly wants to stay inside one vendor), offer this as option A: strongest model plans and judges, standard model executes. Same backend, but the judge is still a *different, stronger model* in a *physically read-only* invocation, so cross-model verification and the no-self-grading property survive at the model level (weaker isolation than cross-vendor — same provider biases and tooling — say so honestly):

```json
"backends": {
  "planner":  { "backend": "claude", "model": "claude-fable-5" },
  "executor": { "backend": "claude", "model": "claude-sonnet-5" },
  "judge":    { "backend": "claude", "model": "claude-fable-5", "readonly": true },
  "pool": {
    "hard": { "backend": "claude", "model": "claude-fable-5" }
  }
}
```

The `pool.hard` preset lets the planner tag genuinely hard tasks `[agent: hard]` to run on the strong model while routine tasks stay on the cheap executor. Economics note from research: cheapest model ≠ cheapest run (weak models cost more via 2-3× turn counts) — the tiered split pays off when most tasks are routine.

**Codex variant ("codex-tiered")** — same idea, tiered by reasoning effort instead of model (roles support an optional `effort` field; adapter maps it to codex `-c model_reasoning_effort`, copilot `--reasoning-effort`, kiro-cli `--effort`; other backends ignore it):

```json
"backends": {
  "planner":  { "backend": "codex", "model": "gpt-5.5", "effort": "xhigh" },
  "executor": { "backend": "codex", "model": "gpt-5.5", "effort": "medium" },
  "judge":    { "backend": "codex", "model": "gpt-5.5", "effort": "xhigh", "readonly": true },
  "pool": {
    "claude-exec": { "backend": "claude", "model": "claude-sonnet-5" }
  }
}
```

Pool entries may point at a *different backend entirely* — here a codex-planned loop can still route individual tasks to claude via `[agent: claude-exec]`. Mixing vendors inside one loop is first-class, not a hack.

## Round 1 — 闭环形态 (≤5 questions, multiple choice)

1. **验收来源** — A. 已有 PRD/spec 文件（给路径） B. 现场访谈生成 PRD（追加一轮 3-5 问的 PRD 访谈，snarktank 风格） C. GOAL.md 标量指标型（要求用户定义指标计算命令；警告 Goodhart 风险：指标计算器必须是 agent 不可修改的文件，列入 gates）
2. **Executor backend** — 探测到的 CLI 列表 + 模型选择
3. **Judge backend** — 探测到的列表（默认预选 ≠ executor 的最强者）+ D. 厂商评审器（codex exec review）。**只有具备只读模式的 backend 可当 judge**：claude / codex / gemini / qwen / copilot / cursor-agent / droid / kiro-cli / opencode(--agent plan)。amp / goose / aider 无只读模式，不得列为 judge 选项。
4. **反压门 (gates)** — A. 自动探测（package.json scripts.test/lint/build、Makefile、cargo check/test） B. 手填命令数组 C. aider 微循环托管（仅 executor=aider）。探测结果必须回显给用户确认。
5. **运行模式** — A. 会话内 Mode A（可观察、首跑推荐） B. 无人值守 Mode B（过夜/systemd）

**混合 agent（可选，不占正式提问轮次）**：如果用户提到"不同任务想用不同 agent"，直接说明机制而非追加问题——plan.md 每行任务可加 `[agent: <backend>]` 标签，planner 会按任务性质自动打（机械式多文件改名 → aider；大 context 重构 → 通过 `loop.json backends.pool` 定义的大模型）；未打标签的任务用默认 executor。见 [loop-protocol.md](loop-protocol.md) 的"Mixed-agent loops"。若用户想手动指定某类任务用某 backend，在 `backends.pool` 里加命名预设即可，不需要专门的访谈轮次。

## Round 2.5 — 扩展角色（1 问，multiSelect，可全不选）

问一次:"要启用哪些扩展角色?(核心三角色外全部可选,默认只推荐前两项)" 选项按价值排序,多选:
- A. **vetter + summarizer**(推荐——各一次调用,PRD 审查 + 人类交接摘要,成本最低杠杆最高)
- B. **hunter + cleaner**(验收后占位符清剿 + deslop,OMC ralph 实战验证的组合)
- C. **tester**(TDD 分离:写测试的 ≠ 写代码的,hash 强制不可改;改变 L1 结构,首跑建议先不开)
- D. **qa + oracle + dispatcher**(e2e 证据采集 / 卡点二意见 / 任务路由,按需)

选中的角色写入 `backends.<role>`,backend 默认沿用 judge 的异构选择(vetter/hunter/oracle 用非 executor 的 backend;summarizer 配便宜模型)。全不选 = 纯核心三角色循环,完全合法。

## Round 2 — 护栏 (≤5 questions)

6. **隔离** — A. git worktree + 分支（默认） B. 仅分支 C. Docker 沙箱。若任何 backend 需要 danger flag（--dangerously-*/--yolo/--auto），只允许 A 或 C。
7. **上限档位** — A. 保守（15 迭代 / 2 重设计轮 / $5 / 900s 单轮） B. 标准（30 / 3 / $20 / 1800s） C. 过夜（60 / 3 / $50 / 1800s） D. 自定义
8. **L3 gate** — A. 全开（默认：动作类 + 里程碑 + 定时每 2h） B. 过夜模式（关定时暂停，保留动作类 + 里程碑 + 异常升级）。动作类 gate（merge/deploy/publish/delete/charge/close）不可关闭，不作为选项提供。
9. **通知** — A. ntfy topic B. webhook URL C. macOS osascript 通知 D. 无（仅退出码 + AWAITING_HUMAN.md）
10. **Resume 策略** — A. 每轮全新上下文（Ralph 正统，默认） B. L2 失败后先 resume 实现者会话廉价修一次，再回全新迭代

## Outputs

### 1. `.vloop/loop.json`

```json
{
  "version": 1,
  "project": "<repo name>",
  "mode": "A|B",
  "isolation": { "type": "worktree|branch|docker", "branch": "vloop/<feature>" },
  "backends": {
    "executor": { "backend": "claude", "model": "...", "danger": false },
    "judge":    { "backend": "codex", "readonly": true },
    "planner":  { "backend": "claude" }
  },
  "gates": [ { "name": "test", "cmd": "npm test" }, { "name": "lint", "cmd": "npm run lint" } ],
  "caps": { "max_iterations": 30, "max_redesign_rounds": 3, "budget_usd": 20, "iteration_timeout_s": 1800 },
  "l3_gates": { "action_classes": true, "milestone": true, "timed_pause_hours": 2, "on_escalation": true },
  "resume_strategy": "fresh|resume_once",
  "notify": { "type": "ntfy|webhook|osascript|none", "target": "..." }
}
```

### 2. `.vloop/prd.json`

Convert the PRD source into stories. Every story:

```json
{ "id": "S1", "title": "...", "priority": 1, "passes": false,
  "acceptanceCriteria": [ { "id": "S1C1", "text": "<verifiable statement>", "verify_hint": "<command or manual step>" } ] }
```

**Criteria quality gate (PRD-theater check)** — reject and rewrite any criterion that is not falsifiable:
- Good: "删除按钮点击后先弹确认框，取消则不删除"（可验证）
- Bad: "删除功能实现完整"（PRD theater）
- UI stories MUST include a browser-verification criterion (screenshot/playwright/dev-browser step).
- Read the criteria back to the user for confirmation before writing `passes:false` on all.

### 3. Post-config steps (mandatory, same turn)

1. Run capability probe: `skills/vloop/scripts/adapter.sh probe` → `.vloop/backends.json`. Refuse to finish setup if a chosen backend fails the probe.
2. Create isolation: worktree/branch per config. Add `.vloop/` to `.gitignore` and commit the .gitignore — state files must NEVER be tracked (a committed state.json gets rolled back by iteration cleanup, corrupting counters).
3. Seed `plan.md` via one planner invocation (planner backend, prompt template PROMPT-replan.md with empty judge-feedback section), then show the plan to the user — **spec/plan approval is the first L3 gate; do not start L1 without explicit approval.**
4. Task granularity check on the generated plan: every task must fit one context window ("add DB column + migration" right; "build the dashboard" must split). Split oversized tasks before approval.
