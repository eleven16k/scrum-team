# scrum-team

PM-编排型 Scrum 流水线，Agent IDE 友好：以 [ZCode](https://github.com/zcode-ai/zcode) 为一等公民，但 agent prompt / skill 规约 / 脚本本身与 IDE 无关，可移植到任何支持 markdown agent 的 IDE（Claude Code、Cursor、Aider、Continue 等）。把"拆需求 → 派发实现 → 两段评审 → QA 验收"做成可复用的工作流，跑在 Plane 看板之上。

主会话充当 PM（产品经理），不写业务代码也不直接调 Plane；所有写操作经 `plane-scribe`，所有实现经 `implementer`，所有验收经 `qa-acceptance`。Codex CLI 提供跨厂商评审，避免"自己审自己"。

---

## 架构

```
                        ┌─────────────────────────────┐
                        │   主会话（PM，任意 agent IDE）│
                        │  · 派发                     │
                        │  · 守门禁                   │
                        │  · 不写业务代码             │
                        └──────────────┬──────────────┘
                                       │
       ┌───────────┬───────────┬───────┼────────┬────────────┬─────────────┐
       ▼           ▼           ▼       ▼        ▼            ▼             ▼
 story-slicer  implementer  vision-  spec-    code-       qa-           plane-
 (拆解)        (TDD 实现)   intent-  reviewer quality-     acceptance    scribe
                            reader   (Codex)  reviewer     (QA 双模式)  (Plane 读写)
                                       spec ✅ → quality
```

七个角色各管一段，中间用状态机驱动。状态权威在 Plane，PM 只调度。

---

## 适用场景

- 任意需要结构化迭代的项目（小到一周的 sprint，大到多 cycle）。
- 团队/个人愿意把"做什么"和"做到什么程度算对"先钉死，再让 AI 落地。
- 已经在用 Plane 做看板，或愿意为它建一个。
- 需要两段独立评审（规约合规 + 代码质量）来收敛大模型随机性。

不适合：

- 一次性脚本/原型（拆解成本高于收益）。
- 强人工驱动的设计阶段（先把架构想清楚再用本流水线）。

---

## 前置依赖

| 依赖 | 说明 |
|---|---|
| Agent IDE | 任何支持 markdown agent + skill 描述文件的客户端都可运行；ZCode 提供零配置加载与子智能体管理，其他 IDE 见下方"可移植性"小节 |
| [superpowers](https://github.com/obra/superpowers)（或同等的 TDD + subagent 纪律来源） | 提供 TDD 铁律、subagent-driven-development 等基础规则，MIT 协议 |
| [Plane](https://plane.so) 账号 + Personal Access Token | 看板与状态机后端 |
| [Codex CLI](https://github.com/openai/codex) 0.142+ | 两段评审的执行器；未安装时自动回退到子智能体路径 |
| `curl`、`jq`、`git`、`bash` | `scripts/plane.sh` 和 `scripts/codex-review.sh` 的依赖 |

---

## 安装

### 作为本地源码加载（开发模式）

将本仓库克隆到 `~/.zcode/cli/plugins/sources/` 下，ZCode 会自动发现：

```bash
git clone git@github.com:eleven16k/scrum-team.git \
  ~/.zcode/cli/plugins/sources/scrum-team
```

### 作为本地 marketplace 安装（用户模式）

参考 ZCode 官方文档中"本地 marketplace"一节，将本仓库注册为 marketplace，安装 `scrum-team` 插件包。

---

## 配置

所有 Plane 相关配置走环境变量：

| 变量 | 必填 | 说明 |
|---|---|---|
| `PLANE_API_KEY` | ✅ | Plane → Profile Settings → Personal Access Tokens |
| `PLANE_WORKSPACE` | ✅ | workspace slug |
| `PLANE_PROJECT_ID` | 大多数命令必填 | 项目 ID（`projects` 命令不需要） |
| `PLANE_BASE_URL` | 默认 `https://api.plane.so` | 自部署 Plane 改此项 |

Codex 相关：

| 变量 | 必填 | 说明 |
|---|---|---|
| `CODEX_BIN` | 默认 `codex` | Codex 可执行路径 |
| `CODEX_REVIEW_MODEL` | 可选 | 透传 `--model`，如 `gpt-5` |

建议把 `PLANE_*` 写进 `~/.zcode/.env` 或 shell rc，避免每次会话重复输入。

---

## 快速开始

1. 在 ZCode 中加载 `scrum-team:scrum-loop` 技能。
2. 准备 spec/PRD，把它贴在主会话里，告诉 PM"开始这个 sprint"。
3. PM 会自动派 `story-slicer` 拆需求 → `qa-acceptance` 试读验卡 → 秘书建卡 → 进循环。

主循环不要求你持续在线：你可以在 PM 等评审/QA 的窗口里去干别的，回来再继续。Plane 看板是唯一权威进度，PM 中断后可按"取消与恢复"小节重建现场。

---

## 故事卡的生命周期

```
Backlog
  │ PM: 派 story-slicer → STORIES_READY
  │ PM: 派 qa-acceptance 模式A 试读 → READ_PASS
  │ 秘书: 建卡 + Spec 页 + 排 cycle → Todo
  ▼
Todo ──── 派 implementer（附卡全文 + 分支）
  ▼
In Progress ── implementer 报 DONE → 秘书移 In Review
  ▼
In Review ──── codex-review.sh spec ✅ → codex-review.sh quality ✅ → 秘书移 Testing
  ▼
Testing ────── 派 qa-acceptance 模式B → ACCEPTED → 秘书核 Done 三门禁 → Done
```

**Done 硬门禁**：AC 自动化测试全过 + 两段评审 ✅ + QA ACCEPTED，三者缺一不可。

---

## 并发策略

分两档，**默认 Tier-1**。

### Tier-1 · 流水线重叠（默认）

任意时刻只允许一个 implementer 写代码；当前卡进入只读阶段后即可派下一张卡的 implementer 起跑，无需 git worktree。

- **默认窗口（保守）**：当前卡 spec review ✅ 后启动下一卡 implementer。spec 是打回概率最高的闸，先确保过了再往下推。
- **激进窗口**：在派发 implementer 的 prompt 第 1 段明示"启用激进窗口"后，当前卡 implementer DONE 即刻启动下一卡 implementer，spec / quality / QA 三段只读阶段全部允许重叠。
- 启动前校验三条：契约独立、文件空间不重叠、共享资源（端口/测试 DB/`.env`）不冲突。
- 缺陷修复进队列，一会话一卡红线不变。

详见 `skills/scrum-loop/SKILL.md` 主循环内的"流水线重叠（Tier-1，默认开启）"小节。

### Tier-2 · 多 implementer 真并行（按需升级）

同一时间允许多个 implementer 在不同 worktree 写代码。触发条件：单 implementer 吞吐不够，或《契约总表》明确多卡互不依赖且文件空间不重叠。

硬性要求：每卡独立 worktree（`superpowers:using-git-worktrees`）、卡间只依赖契约、并发上限 2~3、共享资源错开或各卡独立实例、写者切换前确认旧写者已停。

不满足硬性要求时，退回 Tier-1 或纯串行。

---

## 子智能体速查

| 角色 | 文件 | 何时派发 |
|---|---|---|
| `story-slicer` | `agents/story-slicer.md` | 需求 → 故事卡，产出《契约总表》 |
| `vision-intent-reader` | `agents/vision-intent-reader.md` | 卡含图片 → 先转写为文字意图，再交给 implementer |
| `implementer` | `agents/implementer.md` | 卡 → 实现，TDD 七步流程，**编码永不用 flash 模型** |
| `spec-reviewer` | `agents/spec-reviewer.md` | 实现完成后，先审（也由 Codex 执行） |
| `code-quality-reviewer` | `agents/code-quality-reviewer.md` | spec ✅ 后，后审 |
| `qa-acceptance` | `agents/qa-acceptance.md` | 模式 A 拆解试读 / 模式 B 验收 |
| `plane-scribe` | `agents/plane-scribe.md` | 所有 Plane 读写操作 |

派发纪律：每个子 agent 是全新会话，**必须把上下文全文放进派发 prompt**（详见 `skills/scrum-loop/SKILL.md` 中的"派发纪律"和"最小交接模板"）。

---

## 本地开发

```text
scrum-team/
├── .zcode-plugin/
│   └── plugin.json        # 插件清单
├── agents/                # 7 个子智能体定义
├── skills/
│   └── scrum-loop/
│       └── SKILL.md       # PM 编排规约
├── scripts/
│   ├── plane.sh           # Plane REST CLI
│   └── codex-review.sh    # Codex 评审封装
├── commands/              # 可选 slash 命令
└── hooks/                 # 可选 hooks
```

修改 `agents/*.md` 或 `skills/scrum-loop/SKILL.md` 后的生效时机分两条路径：**内联派发**（运行时读文件作为 system prompt）下次派发即生效；**注册型子代理**（Settings → Subagents）的定义在 ZCode 启动时加载，改完需重启 ZCode 才生效。改完定义后注册型派发失败、且本会话刚改过文件——直接走内联回退，不要反复重试注册型。

新增子 agent：在 `agents/` 下放 `<name>.md`（frontmatter 至少含 `name` 和 `description`；ZCode 还会读 `model` / `color`），然后在 `skills/scrum-loop/SKILL.md` 的子智能体速查表里登记。

新增评审 rubric：在 `agents/spec-reviewer.md` 或 `code-quality-reviewer.md` 里追加条目，`scripts/codex-review.sh` 会自动从正文抽取。

---

## 可移植性

本仓库以 ZCode 插件的形式打包，但**核心内容是 IDE 无关的**——任何支持 markdown agent + skill 描述文件的 agent IDE 都能运行。ZCode 与其他 IDE 的差异只在打包方式与加载约定，agent 自身的 prompt、状态机、并发策略都不依赖 ZCode。

### 各部件的可移植性

| 部件 | 可移植 | 说明 |
|---|---|---|
| `agents/*.md` 正文（system prompt） | ✅ | 标准 markdown，IDE 无关 |
| `agents/*.md` frontmatter | ⚠️ | 各 IDE schema 不同；一般保留 `name` / `description` 即可 |
| `skills/scrum-loop/SKILL.md` 正文 | ✅ | 标准 markdown，IDE 无关 |
| `skills/scrum-loop/SKILL.md` frontmatter | ⚠️ | 同上 |
| `scripts/plane.sh` / `scripts/codex-review.sh` | ✅ | 纯 bash，无 IDE 耦合 |
| `.zcode-plugin/plugin.json` | ❌ | ZCode 专属 manifest，其他 IDE 不识别 |
| `commands/` / `hooks/` | ⚠️ | ZCode 约定，其他 IDE 有各自的命令/钩子规范 |

### 在其他 IDE 中的最小迁移路径

1. **复用 7 个 agent 的正文**——按目标 IDE 的 frontmatter 约定（一般保留 `name` 和 `description`）改写 YAML，然后注册为 subagent。
2. **加载 `skills/scrum-loop/SKILL.md` 的正文**——作为主会话的工作流规约，或一个 slash command 的 system prompt，主会话按这份规约派发。
3. **直接调用两个脚本**——`scripts/plane.sh` 和 `scripts/codex-review.sh` 是纯 bash，按 IDE 的 shell 工具调用即可。
4. **集中 Plane 写权限**——本流水线假设 Plane 的所有写操作集中在主会话（"PM 经 plane-scribe"），其他 IDE 同样建议这么做；不要让 subagent 各自持有 `PLANE_API_KEY`。

主循环、状态机、并发策略这些核心规约与 IDE 无关——任何"能在主会话派发 subagent + 调用 shell 脚本"的 agent IDE 都能跑这套流水线。

---

## 协议

MIT — 见 [LICENSE](./LICENSE)。

第三方依赖：

- [superpowers](https://github.com/obra/superpowers) (MIT) — 本流水线依赖的 TDD 与 subagent 红线

---

## 致谢

- Plane 团队做的好看板。
- superpowers 项目对 TDD 铁律和子智能体纪律的整理。
- 跨厂商评审的想法源于 OpenAI Codex CLI。
