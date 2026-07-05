# vloop — 三层闭环 Loop Engineering Skill

[English](README.md) | 中文

支持 12 种 agent CLI 的循环工程 skill：**claude · codex · opencode · gemini · aider · copilot · cursor-agent · droid (Factory) · amp · qwen (通义千问 Code) · goose · kiro-cli** —— 每个适配都经本机实测或官方文档核实，配置时做能力探测（flags 漂移快）。三层闭环：

```
L3 人类闭环      review 分支 / 改需求(PRD) / 打回     ← 唯一能改需求、批准不可逆动作的层
L2 产品验收环    异构只读 judge 逐条判验收标准；不过则重设计计划回灌 L1（≤3 轮）
L1 计划执行环    每轮新鲜上下文做一个任务 → 反压门(build/test/lint) → 绿则 commit 棘轮
```

核心机制：**每层的"完成"只能由外层确认**。verdict 是 schema 校验的文件而非魔法字符串；judge 与 executor 不同 backend 且物理只读；每层有硬上限（迭代/重设计轮次/预算/超时）+ 熔断器；人类门按动作类别（merge/deploy/publish/delete/charge/close）不可关闭。

## 目录

| 路径 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 三层闭环完整设计（架构、协议、配置器、适配层、安全） |
| [docs/RESEARCH.md](docs/RESEARCH.md) | 调研摘要：Ralph 原典 / GitHub 6 实现 / HN 实战 / 本地实现拆解 / CLI 适配矩阵 |
| [skills/vloop/SKILL.md](skills/vloop/SKILL.md) | Skill 入口（setup / run / resume / status / cancel 路由） |
| skills/vloop/references/ | configurator（问答式配置器）· loop-protocol（三层执行手册）· adapters（多 backend 矩阵）· pitfalls（护栏检查单） |
| skills/vloop/templates/ | loop.json · prd.json · plan.md · AGENT.md · pricing.json · 三个角色提示词模板 |
| skills/vloop/scripts/ | vloop.sh（无人值守编排器）· adapter.sh（backend 调用 + 归一化 + 记账） |

## 安装

vloop 是标准 [Agent Skill](https://agentskills.io)（SKILL.md 开放规范）—— 装一次，**40+ 宿主通用**：Claude Code、Codex、OpenCode、Cursor、Gemini CLI、GitHub Copilot、droid、goose、crush、amp、Kiro、ZCode、Antigravity、Trae、Windsurf……

```bash
# 推荐：一条命令，装进所有检测到的宿主
npx vloop-skill install

# 原理：
#   规范副本 -> ~/.agents/skills/vloop（codex/cursor/gemini/copilot/opencode/goose/crush/amp 原生读取）
#   + symlink -> ~/.claude/skills、~/.zcode/skills、~/.kiro/skills、~/.factory/skills、
#               ~/.gemini/antigravity/skills、~/.qwen/skills 等（只装检测到的宿主）

npx vloop-skill doctor       # 体检：依赖(jq/python3/git)、宿主、loop backend
npx vloop-skill uninstall    # 干净卸载（自带 manifest 追踪）
```

备选方式：
```bash
npx skills add wikieden/vloop        # 生态安装器（vercel-labs/skills，70+ agent）
npx github:wikieden/vloop install    # 直接从 GitHub 跑安装器，不依赖 npm 发布
```

### 无宿主纯 CLI 使用

模式 B 不需要任何 agent 宿主：
```bash
npx vloop-skill init   # 生成 .vloop/loop.json + prd.json 模板
# 编辑后：
npx vloop-skill run    # 无人值守三层循环；退出码 42 = 等人类 review
```

## 使用

```
/vloop setup            # 问答+选择题配置闭环（≤5 问/轮 ×2 轮）→ .vloop/loop.json + prd.json
/vloop run              # 模式 A：当前会话当编排器（可观察，首跑推荐）
/vloop run --unattended # 模式 B：vloop.sh 外部循环（过夜；退出码 42 = 等人类）
/vloop resume           # 人类 review 后恢复（PRD diff → 重生成计划）
/vloop status | cancel
```

依赖：`jq`、`python3`、`git`，以及所选的 agent CLI。

## 已验证

- 端到端 mock 测试（shim backend）：L1 commit 棘轮/勾任务 → L2 只读 judge 判决提取 + passes 棘轮 → L3 暂停产物 + 退出码 42 ✓
- 失败路径：gate 失败回滚、verdict 非法计失败迭代、熔断 trip1→replan、trip2→升级 L3 ✓
- 跨 backend 成本台账（claude 原生 USD + gemini token 换算）✓
- bash 3.2（macOS 默认）兼容 ✓

## License

[MIT](LICENSE)
