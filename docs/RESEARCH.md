# Loop Engineering 调研摘要

> 调研范围：ghuntley 原典、GitHub 6 个开源实现（源码级）、Hacker News 实战讨论、本地已装 3 套 loop 实现（官方 ralph-loop 插件 / oh-my-claudecode / superpowers）、5 个 agent CLI 的 headless 适配（本机实测验证）。
> 日期：2026-07-05

## 1. 核心公理（Ralph 原典，ghuntley.com/ralph）

- **循环本体极简**：`while :; do cat PROMPT.md | agent ; done`。"deterministically bad in an undeterministic world" —— 循环结构是确定的，每轮迭代是随机的。所有复杂度都在循环之外：状态文件 + 验证门 + 提示词调优。
- **每轮只做一件事**（one item per loop）。项目成熟后可放宽到 N 件，跑偏时收回到 1 件。
- **新鲜上下文 + 文件系统即记忆**：每轮全新 context window；持久状态只存在于文件（fix_plan.md / specs/* / AGENT.md）和 git。可用上下文实测 ~147k-152k 就开始劣化（标称 200k），"用得越多，产出越差"。
- **反压（backpressure）**：编译器、测试、静态分析器、安全扫描 —— 任何能拒绝坏生成的机器门槛。"轮子必须转得快"。动态语言必须接静态分析器，否则 "a bonfire of outcomes"。build/test 只允许 1 个 subagent 跑（串行化验证信号），搜索/读写可以 500+ 并行。
- **完成即棘轮（ratchet）**：测试绿 → 更新 plan → commit → push → tag。git tag 是可回退的已知良好状态。
- **给未来迭代留纸条**：测试必须自带 "why" 文档，因为未来的循环没有当前推理的上下文。
- **人类调音**（tuning = erecting signs）：观察行为流，出坏行为就加提示词"路牌"，而不是改代码。计划文件跑偏就整个删掉重新生成（planning loop 与 building loop 是两种提示词模式）。
- **反对过早多 agent**："non-deterministic microservices — a red hot mess"。单进程、单仓库、每轮一个任务，被逼到不得已才拆。

## 2. GitHub 实现的收敛结论（6 个实现源码分析）

两种主流循环架构：

| 架构 | 代表 | 机制 |
|---|---|---|
| **Stop-hook 会话内循环** | 官方 ralph-wiggum 插件、OMC | Stop hook 拦截退出，`{"decision":"block","reason":PROMPT}` 重新投喂同一提示词；状态存 markdown frontmatter |
| **外部进程循环** | ghuntley 正典、snarktank、frankbria、ralph-orchestrator | bash 外循环每轮全新 headless CLI 调用；状态存 `.ralph/` 文件 |

**多 backend 支持的通用解法**：声明式 per-CLI 适配记录（executable、headless flag、prompt 投递方式 arg|stdin、输出格式、自动批准 flag）+ 输出归一化器（把各 CLI stdout 映射到统一分析结构，核心循环零 provider 分支）。frankbria ADR-0002 最严谨：`build_command()` / `normalize_output()` / capabilities 三元组。

**完成检测**（复杂度递增）：魔法字符串（`<promise>COMPLETE</promise>`）→ 哨兵文件（stop.md）→ 双条件门（启发式完成指标 ≥2 且显式 `EXIT_SIGNAL: true`）→ **一律以 max_iterations 硬上限兜底**。

**熔断与成本**（frankbria）：3 轮无文件变化 → 熔断；同一错误签名 5 轮 → 熔断；每小时调用数 + token 双重限速；5 小时限额三层检测（超时码 → 结构化事件 → 文本兜底）+ 自动等待重置。

**任务粒度铁律**：每个 story 必须在一个 context window 内完成。"加一个 DB 列 + 迁移" 对；"做整个 dashboard" 必须拆。

## 3. HN 实战共识

- **实证案例**：15 小时无人值守 118 commits（ticket-burndown loop，systemd 驻留）；GOAL.md 标量指标过夜 47→83；Ralphex 的 plan → 每任务新鲜会话 → 多阶段评审流水线，25 任务过夜出 PR-ready 分支。
- **跨模型验证**：Zenflow 用 Codex 评审 Claude 的代码，评审-修复循环**上限 ~3 轮防发散**。
- **人类检查点收敛于两处**：执行前的 spec/plan 批准门 + 执行后的 PR 级修剪（"早上排任务，下午修剪成功者"）。
- **回滚优于修复**：上下文污染 —— "坏代码和错误假设会污染后续迭代"，checkpoint + 回滚重试快于让 agent 修自己的错。
- **主要怀疑论**（必须在设计中回应）：agent 假装完成（绿检查通过但语义错误）、自建指标被 Goodhart（agent 自己造尺子自己量）、token 成本失控（CURSED 语言 $14k）、约束衰减（AGENTS.md 里的 NEVER 规则任务一难就被无视 —— 需要结构性强制而非提示词级）。

## 4. 本地实现拆解（可直接复用的机制）

**官方 ralph-loop 插件**：状态 = `.claude/ralph-loop.local.md`（YAML frontmatter: active/iteration/max_iterations/completion_promise/session_id + 提示词正文）；Stop hook 从 transcript JSONL 提取最后 assistant 文本，精确匹配 `<promise>` 标签；删文件即取消。
**OMC persistent-mode**：会话隔离状态 `.omc/state/sessions/{id}/<mode>-state.json`；**fail-open 安全阀全家桶**（必须抄）：`stop_hook_active` 重入检查、context-limit stop 永不阻塞（否则死锁压缩）、2h 过期 TTL、session/项目目录匹配、损坏状态删文件放行、整体 try/catch 出错放行。PRD 驱动验证门：prd.json 每 story 带 task-specific acceptanceCriteria，逐条新鲜证据验证 + 评审者签字才能翻 passes:true（"generic criteria = PRD theater"）。
**Superpowers SDD**：无 hook 的控制器循环 —— 每任务 brief 文件 → 新鲜 implementer subagent（四态返回 DONE/DONE_WITH_CONCERNS/NEEDS_CONTEXT/BLOCKED）→ diff 打包文件 → reviewer subagent（spec + quality 双判决）→ 修复循环 → **持久台账** `.superpowers/sdd/progress.md`（压缩后靠台账+git log 恢复，不靠记忆）；**文件交接纪律**：大块产物一律走文件路径，不贴进 dispatch prompt。

## 5. 多 agent CLI 适配矩阵（本机实测 + 官方文档）

| Backend | Headless 调用 | JSON 输出 | Schema 强制 | 只读评审模式 | Resume | 原生预算闸 |
|---|---|---|---|---|---|---|
| claude (2.1.x) | `claude -p "$P" --output-format json` | ✓ (result/session_id/total_cost_usd) | `--json-schema` | `--permission-mode plan` | `-r <session_id>` | `--max-budget-usd`、`--max-turns`(隐藏但可用) |
| codex (0.14x) | `codex exec "$P" --json -s workspace-write` | JSONL(stdout)，日志走 stderr | `--output-schema FILE` | `-s read-only`；内置 `codex exec review --base X` | `codex exec resume <thread>` | 无（外部 timeout） |
| opencode (1.17) | `opencode run "$P" --format json` | ✓ | 无（用 verdict 文件） | `--agent plan` | `-s <id>`、`--fork` | 无 |
| gemini | `gemini -p "$P" --output-format json` | ✓ | 无 | `--approval-mode plan` | `--resume latest` | exit 53 = turn limit |
| aider | `aider --message "$P" --yes-always` | 无 | 无 | 无 | 无 | `--auto-test/--lint-cmd` 自带微循环 |

关键坑：**codex stdout/stderr 绝不能合流**（JSONL 会被日志污染）；flags 版本间漂移快 → 配置时做**能力探测**（`--flag` 缺参报错 vs unknown option 区分隐藏 flag）并缓存 capability manifest；只有 claude 原生报美元 → 编排器要自建 token→美元台账；`claude -p` 会在结果输出 ~5s 后杀掉 agent 启动的后台进程 → **dev server 等长命进程必须编排器持有**，URL 传进提示词。

## 6. Loop Engineering 理论框架（loopengineering.run）

- 四层栈：prompt → context → harness → **loop engineering**；五个动作：Discovery / Handoff / **Verification（"生成变更的 agent 不能给自己的作业打分"）** / Persistence / Scheduling。
- **人类门按动作类别**：merge、deploy、close issue、delete、charge、publish 六类动作没有人类批准不得执行。
- 四大风险命名：verification debt（产出超过人类验证能力）、comprehension rot（代码库甩开心智模型 → 强制运行摘要）、cognitive surrender（人不再有观点 → 保留显式人类决策点）、token blowout（预算/重试/超时上限必须先于生产设定）。

## 7. 配置器先例

- **spec-kit `/clarify`**：≤5 个针对性问题，逐个多选项，答案直接写回 spec 文件。
- **snarktank prd skill**：3-5 个问题，字母选项紧凑作答（"1A 2C 3B"）；验收标准必须可验证（"按钮删除前弹确认框" 对，模糊描述错）；UI story 强制带浏览器验证条目。
- 反模式：无上限的自由文本访谈。

## 主要来源

- https://ghuntley.com/ralph/ · https://ghuntley.com/agent/ · https://ghuntley.com/porting/
- https://simonwillison.net/2025/Sep/30/designing-agentic-loops/
- https://www.anthropic.com/engineering/building-effective-agents
- https://loopengineering.run/
- GitHub: snarktank/ralph · frankbria/ralph-claude-code（ADR-0002）· mikeyobrien/ralph-orchestrator · ComposioHQ/agent-orchestrator · github/spec-kit · anthropics/claude-code (ralph-wiggum plugin) · waynenilsen/ralph-kata-2
- HN threads: 45426680（designing agentic loops）· 48345090（backpressure）· 47390228（GOAL.md）· 46750937（what ralph loops are missing）· 46632445（15h unsupervised）
- 本地：`~/.claude/plugins/cache/claude-plugins-official/ralph-loop/` · `~/.claude/plugins/cache/omc/oh-my-claudecode/4.14.7/scripts/persistent-mode.mjs` · superpowers 6.1.1 SDD skills
