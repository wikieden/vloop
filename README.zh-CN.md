# vloop — 三层闭环 Loop Engineering Skill

[English](README.md) | 中文

让 AI coding agent 跑在**不信任自己**的嵌套闭环里。一个 skill,标准 [Agent Skills](https://agentskills.io) 格式 —— 装一次,**40+ 宿主**通用(Claude Code、Codex、Cursor、OpenCode、Gemini CLI、Copilot、ZCode、Antigravity……)。可编排 **12 个 backend**:claude · codex · opencode · gemini · aider · copilot · cursor-agent · droid · amp · qwen · goose · kiro-cli。

```
L3  人类闭环      review / 改需求(PRD) / 打回 —— 唯一能改需求、批准不可逆动作的层
L2  产品验收环    held-out 隐藏测试 + 可执行检查 + 异构只读 judge;
                 不过 → planner 重设计 → 回灌 L1(≤3 轮)
L1  计划执行环    每轮新鲜上下文做一个任务 → 反压门(build/test/lint) → 绿则 commit 棘轮
```

**每层的"完成"只能由外层确认 —— 模型的意见永远压不过退出码。**

## 五层验证栈

Agent 会假装完成:引用魔法字符串、把红测试标成"应该无关"、用 mock 数据混过绿检查、说服评审者放行。vloop 叠五层独立防线,每层封堵上一层的绕过路径:

| 层 | 机制 | 封堵什么 |
|---|---|---|
| 1 | **反压门**每轮跑(build/test/lint,串行快速);`baseline: true` delta 模式支持脏仓库 —— 只拦新增失败 | "能编译" ≠ 完成 |
| 2 | **schema 校验 verdict 文件** + 编排器指派任务(verdict `task_id` 必须匹配;空 diff 拒收) | 魔法字符串哨兵、干错任务 |
| 3 | **TDD hash 保护**(可选 `tester` 角色):写测试的 ≠ 写代码的;改测试文件 = 结构性拒绝该轮 | 自己给自己打分 |
| 4 | **held-out 隐藏测试**(可选 `holdout` 角色):executor **从未见过**的黑盒测试,每轮重新生成;加 `acceptance_checks[]` 可执行校验 —— 退出码压过 judge | 针对可见测试作弊、忽悠 judge |
| 5 | **异构只读 judge**(不同 backend + 物理只读)+ 人类动作类门(merge/deploy/publish/delete/charge/close,永不可关) | judge 改代码凑通过、不可逆动作漏审 |

跑飞防护:单轮超时、活性看门狗(无输出击杀)、熔断器(3 轮无进展 / 5 轮同错误)、评审僵局检测(judge 判决原地踏步 = 死锁)、硬墙钟 / 美元 / token 预算。**无上限的循环是配置错误** —— 缺任何一个 cap,vloop 拒绝启动。

## 角色

3 个核心角色 + 11 个可选专职角色,`loop.json` 里任意子集启用:

| | 角色 | 职责 |
|---|---|---|
| 核心 | **planner** | 写/重设计 `plan.md`(一任务 = 一个上下文窗口) |
| 核心 | **executor** | 每轮新鲜上下文做一个任务;可按任务覆盖 backend |
| 核心 | **judge** | 只读、异构 backend;`passes: true` 的唯一来源 |
| 可选 | **vetter** | 规划前一次性 PRD 审查(blocking 发现暂停等人) |
| 可选 | **tester** | executor 之前写 RED 测试;hash 保护 |
| 可选 | **qa** | judge 之前跑 e2e/verify-hint,记录证据 |
| 可选 | **oracle** | 卡点先给一次二意见,再打扰人类 |
| 可选 | **hunter** | 验收后占位符/mock 清剿 |
| 可选 | **cleaner** | deslop;回归门失败整体丢弃 |
| 可选 | **harvester** | 学习提炼进 AGENT.md —— 知识跨 run 复利 |
| 可选 | **holdout** | 每轮新生成从未见过的验收测试 |
| 可选 | **redteam** | 对抗性猎门:被利用的绕过 → replan + 修后复查,理论性 → 人类 advisory |
| 可选 | **summarizer** | 人类交接摘要(便宜模型) |
| 可选 | **dispatcher** | replan 后重打任务级 `[agent:]` 路由标签 |

全开流水线:`vet → [tester→executor]×N → qa → holdout/检查 → judge → hunt → redteam → deslop → harvest → summarize → human`。

每个角色的越权都有**结构性**检查而非提示词恳求:tester 文件 hash 比对、dispatcher 改动去标签 diff 校验、qa/harvester 仓库改动回滚、judge 物理写不了。

## 快速开始

```bash
npx vloop-skill install      # 规范副本 -> ~/.agents/skills/vloop(codex/cursor/gemini/copilot/
                             # opencode/goose/crush/amp 原生读取)+ symlink 进检测到的宿主
npx vloop-skill doctor       # 体检:依赖(bash/git/jq/python3)、宿主、backend
```

然后在你的 agent 里:

```
/vloop setup                 # 问答配置器(≤5 选择题 ×2 轮)
/vloop run                   # 模式 A:当前会话当编排器 —— 可观察,首跑推荐
/vloop run --unattended      # 模式 B:外部 bash 循环 —— 过夜;退出码 42 = 等人类
/vloop resume                # 人类 review 后:PRD diff → 重规划 → 重入
/vloop status | cancel
```

备选:`npx skills add wikieden/vloop`(生态安装器,70+ agent)· `npx github:wikieden/vloop install`(GitHub 直装)· `--project` 装到当前仓库。

完全无宿主?模式 B 纯 CLI:`npx vloop-skill init` 生成 `.vloop/` 配置,编辑后 `npx vloop-skill run`。

运行依赖:`bash`、`git`、`jq`、`python3`,以及你配置的 backend CLI —— 每个都要在循环开跑前交互式登录过一次。

## 两种运行形态

**单 agent 内分层(默认)。**整个闭环跑在你所在的宿主上,角色按档位区分 —— 强档规划+只读验收,标准档执行。claude 上 `fable-5` 规划 / `sonnet-5` 执行;codex 上 `xhigh` / `medium` effort。一个 CLI,零跨厂商配置。

**跨 agent 路由(可选)。**编排器(而非 executor)指派每个任务(`plan.md` 首个未勾选行),所以调用之前就知道该拉起哪个 backend。任务打标即可:

```markdown
- [ ] T1: 加 DB 迁移 (covers: S1C1) — verify: npm test -- migrate
- [ ] T2: 全仓 userId -> accountId 重命名 (covers: S1C2) [agent: aider] — verify: npm test
- [ ] T3: 重构 4 万行老模块 (covers: S1C3) [agent: gemini-bulk] — verify: npm test
```

裸 id 沿用默认 executor 配置;`backends.pool.<name>` 预设自带 model/effort/danger。planner 会自己按任务性质打标;未知标签警告后回退,不会搞死循环。commit 带标注(`vloop(T2): iter 4 green via aider`)。

**风险分级自动批准(可选,`l3_gates.auto_approve`)。**确定性脚本分类器(可审计,非 LLM)放行低风险里程碑(小 diff、无敏感路径、运行干净),不阻塞等人;其余带明确原因进人类队列。merge/deploy 永远归人类。

## 各家 agent 用法

所有宿主加载同一份 `SKILL.md`,只有调用语法不同。

| 宿主 | 调用 |
|---|---|
| Claude Code、Cursor、Copilot CLI、Factory droid、Kiro | `/vloop setup`(原生 slash 命令) |
| Codex CLI、ZCode | `$vloop setup`(ZCode 装后设置→Skills→Refresh 一次) |
| OpenCode、Gemini CLI、Antigravity | 提及"vloop" —— skill 工具触发,部分需确认 |
| goose、amp、crush、qwen 等读 `~/.agents/skills` 的宿主 | 指令里提及"vloop" / "loop engineering" |
| Zed | 任意 agent 线程里 `/vloop`(原生支持 `~/.agents/skills`);交互式多任务可配 Parallel Agents |
| 无宿主纯 CLI | `npx vloop-skill init && npx vloop-skill run` |

哪个宿主没显示?`npx vloop-skill doctor` 报告检测与链接状态。

## 目录

| 路径 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 完整架构:分层、协议、配置器、适配层、安全 |
| [docs/RESEARCH.md](docs/RESEARCH.md) | 调研:Ralph 原典、开源实现源码分析、HN 实战、CLI 适配矩阵、2026-07 生态更新 |
| [docs/LOOPS-REFERENCE.md](docs/LOOPS-REFERENCE.md) | LOOPS.md 九法则+二十模式 × vloop 差距审计(署名存疑已如实标注) |
| [skills/vloop/SKILL.md](skills/vloop/SKILL.md) | Skill 入口(setup / run / resume / status / cancel 路由) |
| skills/vloop/references/ | 配置器向导 · 三层协议手册 · 12-backend 适配矩阵 · 护栏检查单 |
| skills/vloop/templates/ | loop.json · prd.json · plan.md · AGENT.md · pricing.json · 13 个角色提示词模板 |
| skills/vloop/scripts/ | vloop.sh(无人值守编排器)· adapter.sh(backend 调用 + 归一化 + 成本台账) |
| bin/vloop-skill.js | npx 安装器:install / uninstall / doctor / init / run |

## 已验证

每个机制都有 shim backend 测试:三层正路(commit 棘轮 → judge → 里程碑,退出码 42)、失败路径(门失败回滚、verdict 非法/错配、熔断→replan→升级)、混合 agent 派发、tester 篡改拒绝、baseline 豁免+新失败拦截+基础设施错误硬失败、评审僵局升级、活性击杀(rc 125)、judge 说过但检查说不过时扣棘轮、holdout 拒收→修复→放行、LOW 自动批准带审计、敏感路径 HIGH 拦人、安装器全生命周期、跨 backend 成本台账、分数门低分重做→提分通过、分歧点摘要送达 harvester、红队被利用绕过→修后复查→理论仅 advisory。bash 3.2(macOS 原生)兼容。

## 出处

设计提炼自 Ralph 技法(ghuntley)、开源 loop 生态的源码级分析(ralphex、ralph-orchestrator、spec-kit、pickle-rick、Gas Town……)、HN 实战共识、本机实测的 headless CLI 机制 —— 并持续吸收生态验证过的新方法。含来源的摘要:[docs/RESEARCH.md](docs/RESEARCH.md)。

## License

[MIT](LICENSE)
