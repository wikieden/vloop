# LOOPS.md 九法则 + 二十模式 × vloop 对照

> 参考基准:流传署名 Karpathy 的《LOOPS.md》(2026 年中开始传播;各方均为"attributed to",原始出处链不完全可考,社区整理稿众多 —— 按内容价值收录,署名存疑照实标注)。
> 核心论断:"Prompt 的杠杆效应已见顶。大多数 Agent 系统的失败不在模型能力,在循环设计。极简的循环、简单的状态、清晰的合同,除此以外都是点缀。"
> 用途:vloop 的差距审计清单。每条标注 ✓ 已实现 / ◐ 部分 / ✗ 未做 / — 有意不做。

## 九条法则对照

| # | 法则 | vloop | 对应机制 |
|---|---|---|---|
| 1 | 写循环不写 Prompt(Gather→Reason→Act→Verify→Repeat) | ✓ | 三层闭环本体;每轮 读状态→选任务→执行→门+judge→棘轮 |
| 2 | 彻底分离角色(Planner/Generator/Evaluator 混用必出问题) | ✓ | planner/executor/judge 分离且**结构性**隔离(judge 物理只读、tester hash 保护、"不给自己作业打分") |
| 3 | 先协商合同(写码前在磁盘上辩论出可测试断言清单) | ✓ | prd.json `acceptanceCriteria`(可证伪性检查,"PRD theater" 拒收)+ vetter 角色审合同 + 首个 L3 门 = 人批计划 |
| 4 | 状态写磁盘(feature_list/progress/contract/log 四文件,崩溃可续) | ✓ | prd.json(合同)/ plan.md(任务)/ progress.md+state.json(进度)/ runs/(日志)+ learnings.md;压缩/重启后靠台账+git log 恢复 |
| 5 | 允许推倒重来(第 9 次删项目,第 11 次交付) | ✓ | 回滚优于修复(失败迭代整树丢弃);plan 跑偏整个重生成;L3 打回可 reset 到任意 tag |
| 6 | 给审美打分(设计/原创性/工艺/功能性,输出 0-1) | ✓ | judge verdict 带 `scores`(correctness/craft/design/functionality 0-1)+ `caps.score_thresholds` 门槛:全过但低分 → 重做提分(缺分仅 advisory,向后兼容) |
| 7 | 像读 stack trace 读日志(grep 分歧点,改那段 Prompt) | ✓ | 每轮落 outcome.txt 取证;harvest 机械提取"声明成功但门不同意"的分歧点摘要,harvester 每例产出一条 [divergence] 预防规则 = 该改的那段 Prompt |
| 8 | 随时删除 Harness(模型升级后旧控制代码是累赘) | ✓(哲学) | bash 外壳极简可弃;loop-tool 商品化风险已写进 pitfalls;/goal 等官方原语一成熟就替换自建件 |
| 9 | 瓶颈永远在移动(代码→规划→验证) | ✓(实证) | vloop 自身演进即证明:v0.1 循环骨架 → 验证栈五层 → 评审队列成瓶颈 → 风险分级自动批准 |

## 二十模式对照

### 质量提升
| 模式 | vloop | 说明 |
|---|---|---|
| ① 生成→批判→重写 | ✓ | L2 主环:executor 出 → judge 挑刺 → planner 重设计 → 回灌 |
| ② 打分-重试(低于阈值重来,超上限返最优) | ✓ | score_thresholds 低于阈值 → 重做(计入 redesign 上限);棘轮 commit 保底最优版本 |
| ③ 多重批判者(正确性/风格/安全/行为并行) | ◐ | 串行多批判:gates(行为)+ holdout(正确性)+ hunter(工艺)+ judge(全维);未并行分 lens。**候选**:judge 拆多 lens 并行 |
| ④ 对抗审查(专门推翻你的结论) | ✓ | redteam 角色:验收后猎门绕过;被当前代码利用 → replan 且修后复查;理论性 → 人类 advisory(hacker-fixer,arXiv 2606.08960) |

### 记忆与历史
| 模式 | vloop | 说明 |
|---|---|---|
| ⑤ 记忆更新(定期压缩写外部记忆) | ✓ | harvester → AGENT.md(精简自更新,禁状态报告混入) |
| ⑥ 经验回放(失败提取踩坑清单) | ✓ | learnings.md 的 [scar] 条目;pitfalls.md 本身就是全生态踩坑库 |
| ⑦ 一致性校验(输出与决策逐条比对) | ✓ | verdict.task_id 必须匹配指派、勾选需 diff+门佐证、judge 逐条 criterion 判 |
| ⑧ 长期摘要(阶段摘要替换膨胀上下文) | ✓ | 新鲜上下文本来不膨胀;progress tail 注入 + summarizer 摘要;L2 门前压缩在候选列表 |

### 动态规划
| 模式 | vloop | 说明 |
|---|---|---|
| ⑨ 目标拆解(大任务→子任务队列) | ✓ | planner:PRD→plan.md,一任务一上下文窗口铁律 |
| ⑩ 中途重规划(条件变了暂停重计划) | ✓ | 熔断 trip→replan;验收失败→replan;人改 PRD→resume 重生成队列 |
| ⑪ 渐进式拆解(一步深一层,走不通就退) | ◐ | 粒度铁律+"太大就拆"规则近似;无显式递归下钻/回退栈 |
| ⑫ 任务队列管理(排序/依赖/重试/超时) | ◐ | 排序 ✓(优先级)、超时 ✓、重试 ✓(失败迭代重来);显式依赖图 ✗(靠 planner 排序隐式表达) |

### 多路径探索 —— 整类有意不做(单线)
| 模式 | vloop | 说明 |
|---|---|---|
| ⑬ 并行探索 / ⑭ 投票聚合 / ⑮ MCTS / ⑯ Beam Search | — | Ralph 公理"过早多 agent = a red hot mess" + 2026-07 调研确认生态并行 integrator 仍无解。留了口子:opencode `--fork`、merger 预留角色、oracle 是最小形态的二路径。等并行 lane 落地再启用此类 |

### 系统自进化
| 模式 | vloop | 说明 |
|---|---|---|
| ⑰ 自我重构(反复失败自动调架构) | ✗ | 反复失败走 L3 升级人类 —— **有意保守**:自动改架构与"人类是唯一改需求者"公理冲突 |
| ⑱ 工具演进(自主发现注册新工具) | ✗ | 未做;能力探测(backends.json)是静态版 |
| ⑲ 工作流优化(历史数据优化路径) | ◐ | ledger/runs/learnings 数据都在,分析未自动化。**候选**:harvester 输出"流程观察"已是第一步 |
| ⑳ 元学习循环(归纳通用框架复用) | ◐ | learnings.md 跨 run 复利是最小实现;跨项目归纳未做 |

## 差距结论(按行动价值)

1. ~~**⑥ 审美/多维打分**~~ **已实现**(v0.7.0):judge scores + score_thresholds 门。
2. ~~**法则 7 分歧点定位**~~ **已实现**(v0.7.0):outcome.txt 取证 + harvest 分歧摘要 + [divergence] 规则。
3. ~~**④ 对抗审查**~~ **已实现**(v0.7.0):redteam 角色,exploited→replan+复查 / theoretical→advisory。
4. **多路径整类**:维持不做,理由充分(生态未解 + Ralph 公理);merger/fork 口子已留。
5. **⑰ 自我重构**:明确永不做 —— 与 L3 公理冲突,写入本文档作为设计决策。

## 来源

- 社区流传稿(署名存疑):[gist — Karpathy-Michaels CLAUDE.md + LOOPS.md](https://gist.github.com/sanchez314c/a767997b030d2904c0d0f08fabae2d42) · [TechTimes 报道("document attributed to Karpathy")](https://www.techtimes.com/articles/319214/20260628/karpathy-claudemd-grows-ten-rules-new-self-check-protocol-ai-coding-loops.htm)
- 同源思想(可靠出处):Anthropic《Building Effective Agents》(evaluator-optimizer/orchestrator 模式) · loopengineering.run(五动作/四风险) · ReAct(Yao et al. 2022,所有现代 agent 循环的原型)
- vloop 自有调研:[RESEARCH.md](RESEARCH.md)
