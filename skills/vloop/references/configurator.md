# Configurator — 问答式 + 选择题闭环设计

Bounded interview. Precedent: spec-kit `/clarify` (≤5 questions, options, answers persisted into the artifact) and snarktank prd (lettered options, compact answers like "1A 2C"). Free-text-heavy interviews are the anti-pattern.

In interactive Claude Code sessions use **AskUserQuestion** (one call per round, up to 4 questions per call — split round 1 into 2 calls if needed). In headless contexts, write the question list to `.vloop/AWAITING_HUMAN.md` and exit.

## Step 0 — Detect environment (before asking anything)

```bash
for cli in claude codex opencode gemini aider; do command -v $cli >/dev/null && echo "$cli: $($cli --version 2>/dev/null | head -1)"; done
git rev-parse --is-inside-work-tree 2>/dev/null   # not a repo → offer git init (required)
ls package.json Makefile Cargo.toml pyproject.toml 2>/dev/null   # gate auto-detection hints
```

Only offer installed backends as options. If <2 backends installed, warn: judge should differ from executor; same-backend fallback allowed only with a different model (e.g. executor opus / judge haiku is NOT acceptable for judging — prefer strongest model for judge).

## Round 1 — 闭环形态 (≤5 questions, multiple choice)

1. **验收来源** — A. 已有 PRD/spec 文件（给路径） B. 现场访谈生成 PRD（追加一轮 3-5 问的 PRD 访谈，snarktank 风格） C. GOAL.md 标量指标型（要求用户定义指标计算命令；警告 Goodhart 风险：指标计算器必须是 agent 不可修改的文件，列入 gates）
2. **Executor backend** — 探测到的 CLI 列表 + 模型选择
3. **Judge backend** — 探测到的列表（默认预选 ≠ executor 的最强者）+ D. 厂商评审器（codex exec review）
4. **反压门 (gates)** — A. 自动探测（package.json scripts.test/lint/build、Makefile、cargo check/test） B. 手填命令数组 C. aider 微循环托管（仅 executor=aider）。探测结果必须回显给用户确认。
5. **运行模式** — A. 会话内 Mode A（可观察、首跑推荐） B. 无人值守 Mode B（过夜/systemd）

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
