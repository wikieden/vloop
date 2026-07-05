# vloop — 三层闭环 Loop Engineering Skill 设计

> 支持 12 种 agent CLI（claude / codex / opencode / gemini / aider / copilot / cursor-agent / droid / amp / qwen / goose / kiro-cli）的循环工程 skill。
> 三层闭环：L1 计划执行 → L2 产品验收重设计 → L3 人类 review 与需求更新。
> 设计依据见 [RESEARCH.md](RESEARCH.md)。

## 0. 设计原则（从调研提炼）

1. **循环外壳极简，复杂度在状态文件与验证门**（Ralph 公理）。
2. **新鲜上下文 + 文件系统即记忆**：每轮迭代全新 context，状态只活在 `.vloop/` 文件和 git 里。
3. **实现者不给自己打分**：验收 judge 用不同 backend + 物理只读模式（loopengineering.run 五动作之 Verification）。
4. **一切提示词级约束都要有结构性兜底**：魔法字符串会被伪造，NEVER 规则会衰减 —— 完成判定用 schema 校验的 verdict 文件 + 独立 judge + git 证据，不信 agent 自述。
5. **每层闭环有硬上限**：迭代上限、重设计轮次上限（≤3 防发散）、预算上限、熔断器。无上限 = 事故。
6. **人类门按动作类别**：merge / deploy / publish / delete / charge / close 六类动作 + 预算越界 + 里程碑完成，必须过人。
7. **回滚优于修复**：坏迭代污染上下文，reset 到上一个绿色 ratchet 点重试，胜过让 agent 修自己的错。

## 1. 三层闭环总览

```
┌─────────────────────────────────────────────────────────────────┐
│  L3 人类闭环（节奏：小时~天）                                       │
│  review 分支/报告 → 批准 | 改需求(PRD) | 打回                       │
│  ▲ AWAITING_HUMAN.md + 验收报告 + 通知      ▼ PRD diff → 重生成队列  │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │  L2 产品验收重设计闭环（节奏：每里程碑；重设计 ≤3 轮）              │ │
│ │  judge(异构 backend, 只读) 逐条判验收标准 → pass 翻棘轮           │ │
│ │  ▲ L1 完成声明 + verdict     ▼ fail: 判决证据 → replan → 新计划   │ │
│ │ ┌─────────────────────────────────────────────────────────┐ │ │
│ │ │  L1 计划执行闭环（节奏：每任务一轮，新鲜上下文）                │ │ │
│ │ │  读 plan → 取一个任务 → 实现 → 反压门(build/test/lint)      │ │ │
│ │ │  → verdict.json → 绿则 commit（棘轮）→ 下一轮               │ │ │
│ │ │  熔断：3 轮无 diff / 5 轮同错误签名 / 预算线                  │ │ │
│ │ └─────────────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

数据流（单向棘轮）：
- 向内：需求(PRD) → 计划(plan) → 任务（一轮一个）
- 向外：git commit（L1 棘轮）→ judge 签字翻 `passes:true`（L2 棘轮）→ 人类批准合并（L3 棘轮）
- **每一层的"完成"只能由外层确认，本层只能声明。**

## 2. L1 — 计划执行闭环

**目标**：把 `plan.md` 的任务清单逐条变成绿色提交。

每轮迭代协议（新鲜上下文，executor backend）：

1. 编排器组装提示词（模板 `PROMPT-implement.md`，注入 plan / progress 摘要 / AGENT.md / 上轮门失败证据）。
2. Agent：读 plan → **选最重要的一个未完成任务**（搜索先于实现，禁止占位实现）→ 实现 → 跑该单元测试 → 写 `.vloop/verdict.json`。
3. 编排器：校验 verdict schema → 跑反压门（`gates`: build/test/lint 命令数组，串行）→
   - 全绿：commit（消息含任务 ID）， plan 勾选，progress 追加学习记录 → 下一轮。
   - 门失败：**不 commit**，失败输出截断后作为证据注入下一轮提示词。
4. 熔断检查（见 §2.2）。

**verdict 协议**（统一机制，全 backend 可用；claude `--json-schema` / codex `--output-schema` 是加速可选项）：

```json
{
  "status": "done | continue | blocked",
  "task_id": "T3",
  "evidence": "npm test: 42 passed; 文件 src/auth.ts:120-180",
  "notes_for_next_iteration": "…"
}
```

- verdict 缺失/非法 = **失败迭代**（不是 continue）。
- `status: done` 指整个 plan 完成 → 触发 L2。`blocked` → 直接升级 L3。
- 防伪造：verdict 只是声明；勾选任务前编排器核对 git diff 非空 + 门全绿。

**停机条件**：plan 全勾（→L2）| `max_iterations`（默认 30/里程碑）| 熔断 | 预算线 | blocked。

### 2.2 熔断器（circuit breaker）

| 信号 | 阈值 | 动作 |
|---|---|---|
| `git rev-parse HEAD` + 工作区 diff 哈希连续不变 | 3 轮 | 第 1 次熔断 → 强制进 L2 replan；第 2 次 → 升级 L3 |
| 归一化错误签名（首个失败测试名+错误类）重复 | 5 轮 | 同上 |
| provider 限流/5h 窗口（限流事件/429/文本兜底三层检测） | 即时 | sleep 到重置点，**不消耗迭代数** |
| 单轮超时 | `iteration_timeout`（默认 1800s） | 计一次失败迭代 |
| 预算 | `budget_usd` 全局台账 | 升级 L3 |

## 3. L2 — 产品验收重设计闭环

**目标**：L1 说"做完了"之后，从产品视角逐条验收；不过就重设计计划，闭环回 L1。

**验收（judge）**：
- **异构 + 只读**：judge 用与 executor 不同的 backend，且物理只读（`codex exec -s read-only` / `gemini --approval-mode plan` / `claude --permission-mode plan`）—— judge 改不了代码，不可能"修到自己通过"。也可直接用厂商评审器（`codex exec review --base <branch>`）。
- 输入：`prd.json` 的验收标准（每 story 的 `acceptanceCriteria`，配置器保证其**可验证**；UI story 强制含浏览器验证条目）+ 分支 diff + 门运行记录。
- 输出：逐条 `{criterion_id, pass, evidence}` 判决 JSON。
- **棘轮规则：只有 judge 判 pass，编排器才翻 `passes:true`；executor 无权改 prd.json。**

**重设计（replan）**：
- 判决失败 → planner 角色（可再换 backend）拿判决证据修订 `plan.md`：新增/拆分任务、修正方向，**不改验收标准**（标准归 L3 人类管）。
- 回灌 L1 重新执行。`redesign_rounds++`。
- **`max_redesign_rounds`（默认 3）用尽 → 停止内耗，带完整失败报告强制升级 L3**（跨模型评审循环 >3 轮会发散，Zenflow 实证）。

全部 story `passes:true` → 生成验收报告 → 升级 L3。

## 4. L3 — 人类 Review 与需求更新闭环

**目标**：人类是唯一能改需求、批准不可逆动作的角色。防四风险：verification debt / comprehension rot / cognitive surrender / token blowout。

**触发（gate 点）**：
1. **动作类**（不可配置豁免）：merge、deploy、publish、delete、对外收费、关 issue。
2. **里程碑**：L2 全部通过（验收报告就绪）。
3. **异常升级**：blocked / 重设计轮次用尽 / 二次熔断 / 预算越界。
4. **可选定时**：每 N 轮或每 X 小时强制暂停（配置器可选"过夜模式"关闭）。

**暂停协议**（headless 下无法交互提问，一律异步产物）：
1. 状态持久化到 `.vloop/state.json`。
2. 写 `.vloop/AWAITING_HUMAN.md`：触发原因、验收报告/失败报告、**具体问题清单（带字母选项，人类可紧凑作答 "1A 2C"）**、运行摘要（迭代数、成本台账、代表性 diff 索引 —— 防 comprehension rot）。
3. 有远端仓库则开 draft PR；通知（`notify` 命令：ntfy / webhook / osascript，可配）。
4. 循环退出，独立退出码（`42 = AWAITING_HUMAN`）。

**恢复协议**：
1. 人类三选一：**批准**（合并，里程碑闭环）/ **改需求**（编辑 PRD 或在 AWAITING_HUMAN.md 作答）/ **打回**（reset 到指定 tag 重跑）。
2. `vloop resume`：diff PRD 变更 → 变更映射为新任务/作废任务 → 重新生成 plan 队列 → 回 L2 或 L1。
3. 决策追加到 `decisions.md`（append-only 审计流）。

## 5. 配置器 —— 问答式 + 选择题设计自己的闭环

先例：spec-kit `/clarify`（≤5 问，多选项，答案写回产物）+ snarktank prd（字母选项紧凑作答）。反模式：无上限自由文本访谈。

**两轮有界访谈**（交互会话用 AskUserQuestion；答案落盘，不留在对话里）：

第 1 轮 —— 闭环形态（≤5 问，全选择题+可自填）：
1. 目标与验收来源：A. 已有 PRD 文件 B. 现场访谈生成 PRD C. GOAL.md 标量指标型
2. executor backend：A. claude B. codex C. opencode D. gemini/aider（探测到已安装的才列出）
3. judge backend（**默认强制 ≠ executor**）：选项同上 + "厂商评审器"
4. 反压门：A. 自动探测（package.json scripts / Makefile / cargo）B. 手填命令 C. aider 微循环托管
5. 运行模式：A. 会话内（Claude Code 当编排器，可实时观察）B. 无人值守（`vloop.sh` 外部循环，可过夜/systemd）

第 2 轮 —— 护栏（≤5 问）：
6. 隔离：A. git worktree + 分支（默认）B. 仅分支 C. Docker 沙箱（选 danger flags 时强制 A 或 C）
7. 上限：迭代数（30）/ 重设计轮次（3）/ 预算 USD / 单轮超时 —— 预设 保守|标准|过夜 三档
8. L3 gate 点：默认全开，可关"定时暂停"（过夜模式）
9. 通知渠道：A. ntfy B. webhook C. macOS 通知 D. 无
10. resume 策略：A. 每轮全新（Ralph 正统，默认）B. L2 失败后先廉价 resume 修一次再全新

**产物**：`.vloop/loop.json`（机器读的闭环配置）+ `.vloop/prd.json`（story + 可验证验收标准 + `passes:false`）。配置完成即做**能力探测**（§6）。

## 6. 多 agent 适配层

**适配记录**（每 backend 一条，存 `loop.json`）：

```json
{
  "executor": {
    "backend": "claude",
    "cmd_template": "claude -p {PROMPT_STDIN} --output-format json --permission-mode acceptEdits --max-turns 40",
    "prompt_mode": "stdin",
    "parse": "claude_json",
    "danger": false
  },
  "judge": {
    "backend": "codex",
    "cmd_template": "codex exec {PROMPT_ARG} --json -s read-only -o {LAST_MSG_FILE}",
    "prompt_mode": "arg",
    "parse": "codex_jsonl"
  }
}
```

规则（全部来自实测坑）：
- **stdout/stderr 永不合流**（codex JSONL 在 stdout，日志在 stderr）。
- 非有意管道时 stdin 重定向自 `/dev/null`（codex 会把管道内容附成 `<stdin>` 块；gemini 非 TTY 自动切 headless）。
- **能力探测**取代硬编码：配置时记录 `--version`、试探关键 flag（缺参报错 = 隐藏但存在；unknown option = 不存在），缓存 manifest `{json_output, schema_output, budget_cap, turn_cap, resume, readonly_mode, danger_flag}` 到 `.vloop/backends.json`。
- **成本台账编排器自建**：只有 claude 原生报 USD；codex/gemini 报 token，按价格表换算；opencode/aider 无 → 计时+轮数估算。全局预算跨 backend 累计。
- 无原生上限的 backend（codex/opencode/aider）一律套 `timeout` 包装。
- **长命进程编排器持有**：dev server / 浏览器由编排器启动，URL 注入提示词（`claude -p` 结果后 ~5s 会杀 agent 后台进程）。

## 7. 状态文件清单（`.vloop/`）

| 文件 | 写者 | 说明 |
|---|---|---|
| `loop.json` | 配置器 | 闭环配置（backend/门/上限/gate/通知） |
| `prd.json` | 配置器写入；**judge 签字后仅编排器翻 passes** | story + 验收标准 + passes 棘轮 |
| `plan.md` | planner（L2 replan 可重写） | 勾选框任务清单，一任务一 context window 粒度 |
| `progress.md` | executor 每轮追加 | append-only 学习/进度台账（压缩恢复靠它+git log，不靠记忆） |
| `AGENT.md` | executor 自更新 | 构建/运行方法，保持简短，**禁止状态报告混入** |
| `state.json` | 编排器 | phase/iteration/redesign_rounds/熔断计数/成本台账（原子写：tmp+mv） |
| `verdict.json` | agent 每轮写 | 本轮判决（schema 校验） |
| `AWAITING_HUMAN.md` | 编排器 | L3 暂停产物：报告+问题清单 |
| `decisions.md` | 人类/编排器 | append-only 决策审计 |
| `runs/iter-N/` | 编排器 | 每轮原始输出、门日志、成本（事后审计） |

## 8. 运行模式

**模式 A · 会话内**：Claude Code 会话当编排器，skill 指导其按协议逐轮 Bash 调 backend CLI、跑门、更新状态。适合首次运行、需要观察调音。上下文纪律：大块产物走文件交接，会话只保留状态摘要（superpowers 教训：42k 字符历史粘贴事故）。
**模式 B · 无人值守**：`scripts/vloop.sh` 纯 bash 外循环，读同一套 `.vloop/` 状态，可 nohup/systemd/过夜。L3 gate 到达即退出（码 42）+ 通知。
两种模式共用状态文件与适配层，可随时互切（状态在文件里，不在进程里）。

## 9. 安全与护栏

- danger flags（`--dangerously-*` / `--yolo` / `--auto`）：配置器仅在声明了 worktree/Docker 隔离后才写入 loop.json；默认从只读/受限起步。
- 凭据：建议限额沙箱账号；loop.json 不存密钥。
- 提示词硬规则（模板内置）：禁止占位实现；实现前先搜索（防重复实现 —— Ralph 的阿喀琉斯之踵）；无关测试挂了也要修（属于本增量）；禁止在无人值守下提问（问题写进 verdict.notes 升级 L3）；测试自带 why 注释（给未来迭代留纸条）。
- 每轮开始 `git status` 校验干净工作区；门失败禁止 commit。

## 10. Skill 交付形态

```
skills/vloop/
├── SKILL.md                    # 入口：路由 setup/run/resume/status/cancel
├── references/
│   ├── configurator.md         # 两轮访谈协议 + loop.json/prd.json 生成规则
│   ├── loop-protocol.md        # L1/L2/L3 逐步协议（模式 A 执行手册）
│   ├── adapters.md             # 适配矩阵 + 能力探测 + 解析规则
│   └── pitfalls.md             # 护栏检查单(熔断/防伪造/成本/安全)
├── templates/
│   ├── loop.json  · prd.json  · plan.md  · AGENT.md
│   └── PROMPT-implement.md · PROMPT-judge.md · PROMPT-replan.md
└── scripts/
    ├── vloop.sh                # 模式 B 编排器（bash 3.2 兼容）
    └── adapter.sh              # backend 调用 + 输出归一化 + 成本记账
```
