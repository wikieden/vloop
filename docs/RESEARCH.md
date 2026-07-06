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

---

# 增量调研:2026-07-06 生态与方法演进

## 生态动态
- **总称收敛为 "loop engineering"**(Addy Osmani 2026-06 推广);规模化的命名后继者是 Yegge 的 **Gas Town**("wiggum stack" 无实据)。snarktank/ralph(2月起)与官方 ralph-wiggum 插件(1月起)已停更。
- **umputun/ralphex**(1.3k★,Go)成头部新玩家:4 阶段流水线(任务→5 并行评审→跨模型外审→终审)。
- **Claude Code 官方 `/goal`**(v2.1.139+):完成条件由独立小模型每轮判定 —— evaluator 分离原生化。
- **spec-kit** 转型 workflow DSL:`gate` 步骤带 `on_reject` 处理器、run_id 可恢复、fan-in 拓扑预校验。
- **Oak**(oak.space):为 agent 造的 VCS,per-task lazy mount,快照比 git 快 ~95%,`oak export` 回放为标准 git。

## 值得吸收的机制(按价值排序)
1. **baseline-delta 门**(pickle-rick-claude):门跟踪 `(file, rule, occurrence)` 基线 —— 新失败拦截、存量失败放行。解决"脏仓库上没法开全绿门"。
2. **评审僵局熔断**(ralphex `--review-patience`):judge findings 连续 N 轮不变 → 判死锁终止 —— 现有熔断只监测 executor,不监测 judge/executor 对峙。
3. **held-out 随机验收测试**(arXiv 2606.07379):留一片 executor 从未见过的验收测试,只在 L2 门时揭示 + 每轮重生成 —— 反作弊从"不能改测试"升级到"看不见测试"。
4. **风险分级 L3 自动批准**(Ona 实证):低风险(小 diff/无敏感路径/测试绿)自动过,只有高风险进人类队列 —— 首批时间 2h49m→<5min。评审队列已是 2026 的瓶颈。
5. **claude backend 走 `/goal`**:官方 evaluator 分离 + token 记账白拿;其他 11 backend 保持外循环。
6. **harvester 收割角色**(choo-choo-ralph):里程碑后提炼学习写回 skills/AGENT.md,跨 run 复利 —— 天然的第 9 个可选角色。
7. **可执行 verifier 并联 LLM judge**(vercel-labs/ralph-loop-agent):`verifyCompletion` 脚本回调 + 可组合停机条件数组(iteration/token/cost 先到先停)。
8. **beads 结构化台账**(Gas Town):git 追踪的 JSONL 任务账本(ID/状态/assignee 每行)替代扁平 progress.md;"sessions are cattle, agents are not" 的持久身份;Wasteland 的 validator stamp 硬规则"不能给自己的活盖章"。
9. **活性超时**(ralphex idle-timeout):N 分钟无输出杀会话 —— 迭代级熔断之外的液性层;另:$6k 过夜跑飞案例 → 硬 wall-clock 预算必须有。
10. **对抗性门加固**(arXiv 2606.08960):红队 agent 专职尝试"不解决问题地通过门",任何成功都是门的 bug。
11. **agent 自触发重开**(Neuralyzer)+ L2 门前压缩(~86% 输入 token 降幅)。
12. **窗口预热调度**:早上 6 点发个小请求让 5h 窗口重置落在上午中段(平移不增加配额)。

## 并行 lane 结论
生态仍未解决真正的 integrator:ralphex worktree 模式假设计划互不相交;Composio 的最佳先例是**冲突路由回 owning lane 带上下文重跑**;multi-agent-ralph-loop 靠文件所有权分区回避合并。mutation/property-based 验收门无人做 —— 对 vloop 是差异化机会而非补课。

来源:github.com/umputun/ralphex · github/spec-kit workflows.md · gregorydickson/pickle-rick-claude · vercel-labs/ralph-loop-agent · mj-meyer/choo-choo-ralph · steve-yegge.medium.com (Gas Town / Wasteland) · code.claude.com/docs/en/goal · ona.com/stories/auto-approving-low-risk-prs · oak.space · arXiv 2606.07379 / 2606.26300 / 2606.08960 · github.com/gintasz/neuralyzer
