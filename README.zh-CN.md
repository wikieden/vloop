# vloop — 三层闭环 Loop Engineering Skill

[English](README.md) | 中文

支持多种 agent CLI 的循环工程 skill。以标准 [Agent Skill](https://agentskills.io)（SKILL.md）形式发布 —— 装一次，**40+ 宿主通用**。12 个支持的循环 backend：**claude · codex · opencode · gemini · aider · copilot · cursor-agent · droid (Factory) · amp · qwen (通义千问 Code) · goose · kiro-cli**。

```
L3 人类闭环      review 分支 / 改需求(PRD) / 打回     ← 唯一能改需求、批准不可逆动作的层
L2 产品验收环    异构只读 judge 逐条判验收标准；不过则重设计计划回灌 L1（≤3 轮）
L1 计划执行环    每轮新鲜上下文做一个任务 → 反压门(build/test/lint) → 绿则 commit 棘轮
```

核心机制：**每层的"完成"只能由外层确认**。verdict 是 schema 校验的文件而非魔法字符串；judge 与 executor 不同 backend 且物理只读；每层有硬上限（迭代/重设计轮次/预算/超时）+ 熔断器；人类门按动作类别（merge/deploy/publish/delete/charge/close）不可关闭。

## 安装

```bash
# 推荐：一条命令，装进本机检测到的所有宿主
npx vloop-skill install

# 原理：
#   规范副本 -> ~/.agents/skills/vloop（codex/cursor/gemini/copilot/opencode/goose/crush/amp 原生读取）
#   + symlink -> ~/.claude/skills、~/.zcode/skills、~/.kiro/skills、~/.factory/skills、
#               ~/.gemini/antigravity/skills、~/.qwen/skills 等（只装实际检测到的宿主）

npx vloop-skill doctor       # 体检：依赖(jq/python3/git)、宿主、loop backend
npx vloop-skill uninstall    # 干净卸载（自带 manifest 追踪）
```

备选方式：
```bash
npx skills add wikieden/vloop        # 生态安装器（vercel-labs/skills，70+ agent）
npx github:wikieden/vloop install    # 直接从 GitHub 跑安装器，不依赖 npm 发布
```

只想装到当前项目：加 `--project`（写入当前仓库的 `.agents/skills/` 和 `.claude/skills/`，不动全局）。

编排器本身运行时依赖：`bash`、`git`、`jq`、`python3`，以及你在 `loop.json` 里配的 backend CLI。

### 无宿主纯 CLI 使用

模式 B 不需要任何 agent 宿主，只要 npm 包和你选的 backend CLI：
```bash
npx vloop-skill init   # 在当前仓库生成 .vloop/loop.json + prd.json 模板
# 编辑（或从 skills/vloop/templates/ 复制参考），然后：
npx vloop-skill run    # 无人值守三层循环；退出码 42 = 等人类 review
```

## 各家 agent 使用说明

安装后所有宿主加载的是同一份 `SKILL.md`，区别只在**调用方式**。核心命令不分宿主都一样：`setup`（有界问答配置器）· `run`（模式 A，可观察）· `run --unattended`（模式 B，后台）· `resume`（人类 review 后）· `status` · `cancel`。

| 宿主 | 调用方式 | 说明 |
|---|---|---|
| **Claude Code** | `/vloop setup`、`/vloop run` … | 原生 slash 命令。 |
| **Codex CLI** | `$vloop setup`（或提及"vloop"让其自动触发） | 原生扫 `~/.agents/skills`；`/skills` 可看列表。 |
| **OpenCode** | 对话里提到"vloop"/"loop engineering" | skill 是工具调用（`skill({name:"vloop"})`）不是 slash 命令，agent 按描述自动判断是否用；也可直说"用 vloop skill"。 |
| **Cursor**（CLI/IDE） | `/vloop setup` | 原生 slash 命令；描述匹配也会自动触发。 |
| **Gemini CLI** | 提及"vloop"，或先 `/skills list` 再引用 | 通过 `activate_skill` 工具触发，每次激活需确认，非 slash 命令。 |
| **GitHub Copilot CLI** | `/vloop setup` | 同 Claude Code 的 slash 风格。 |
| **Factory droid** | `/vloop setup` | skill 与自定义命令合并，同样 `/name` 体验。 |
| **goose** | 指令里提到"vloop"，或 `goose run -t "用 vloop 来..."` | 无 slash 命令，内置 `skills` 扩展按描述自动浮现；`goose skills list` 可查。 |
| **Kiro / kiro-cli** | `/vloop setup` 或 `$vloop` | 也支持按描述自动激活；`/context show` 查看已加载 skill。 |
| **ZCode**（Z.ai 桌面 ADE） | 对话框输入 `$vloop setup`，或打开 `/` 命令+技能面板 | 安装后需在 设置→Skills→Refresh 点一次。 |
| **Antigravity** | 提及"vloop"或从 Agent Manager 选取 | 同 Gemini CLI，激活需确认。 |
| **amp、crush、qwen、aider、opencode 系** | 提及"vloop"/"loop engineering" | 任何读 `~/.agents/skills` 的宿主都按描述匹配自动识别，无需单独文档。 |
| **无宿主 · 纯 CLI** | `npx vloop-skill init && npx vloop-skill run` | 见上文。 |

装完某宿主没显示 skill？跑 `npx vloop-skill doctor`，会报告该宿主是否被检测到、链接是否存在。

## 目录

| 路径 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 三层闭环完整设计（架构、协议、配置器、适配层、安全） |
| [docs/RESEARCH.md](docs/RESEARCH.md) | 调研摘要：Ralph 原典 / GitHub 6 实现 / HN 实战 / 本地实现拆解 / CLI 适配矩阵 |
| [skills/vloop/SKILL.md](skills/vloop/SKILL.md) | Skill 入口（setup / run / resume / status / cancel 路由） |
| skills/vloop/references/ | configurator（问答式配置器）· loop-protocol（三层执行手册）· adapters（多 backend 矩阵）· pitfalls（护栏检查单） |
| skills/vloop/templates/ | loop.json · prd.json · plan.md · AGENT.md · pricing.json · 三个角色提示词模板 |
| skills/vloop/scripts/ | vloop.sh（无人值守编排器）· adapter.sh（backend 调用 + 归一化 + 记账） |
| bin/vloop-skill.js | npx 安装器：install / uninstall / doctor / init / run |

## 命令参考

```
/vloop setup            # 问答+选择题配置闭环（≤5 问/轮 ×2 轮）→ .vloop/loop.json + prd.json
/vloop run              # 模式 A：当前会话当编排器（可观察，首跑推荐）
/vloop run --unattended # 模式 B：vloop.sh 外部循环（过夜；退出码 42 = 等人类）
/vloop resume           # 人类 review 后恢复（PRD diff → 重生成计划）
/vloop status | cancel
```

把 `/vloop` 换成上表你所用宿主的调用方式即可 —— 底层协议处处一致。

## 已验证

- 端到端 mock 测试（shim backend）：L1 commit 棘轮/勾任务 → L2 只读 judge 判决提取 + passes 棘轮 → L3 暂停产物 + 退出码 42 ✓
- 失败路径：gate 失败回滚、verdict 非法计失败迭代、熔断 trip1→replan、trip2→升级 L3 ✓
- 跨 backend 成本台账（claude 原生 USD + token 换算）✓
- 安装器全生命周期（假 HOME 装/链/体检/卸载）、`npm pack` 内容核实、`npx github:wikieden/vloop` 直装实测 ✓
- bash 3.2（macOS 默认）兼容 ✓

## License

[MIT](LICENSE)
