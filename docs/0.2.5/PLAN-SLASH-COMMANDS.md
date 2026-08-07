# Plan SLASH-COMMANDS: 斜杠命令体系（对齐 opencode command 模型）

## 状态: 实施中（阶段 1-4 完成：注册表 + CLI dispatch + Web /api/command + slash popover，均已提交；阶段 5 prompt 模板命令待实施）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 不做

- **不引入前端框架/工具链**（沿用 vanilla JS）。
- **不在本期支持用户自定义命令**（配置/markdown 加载，opencode `cfg.command` + `command/*.md`）：注册表结构预留 `source` 字段，扩展属后续。
- **不实现 prompt 模板命令的完整执行链**（如 `init`/`review`）：本期聚焦 action 命令迁移 + Web 通道；prompt 命令模板机制仅定义接口与 1 个示例（见阶段 5）。
- **不改会话存储格式**（JSONL/header 语义不变）。

## 问题

**现象**：
1. CLI 全部斜杠命令（`/exit` `/quit` `/new` `/name` `/list` `/help` `/load` `/fork` `/thinking`）是 `processLine`（`App.zig:364-404`）里硬编码 if-chain，无统一描述清单、无自动补全、无参数提示。
2. **Web 前端零命令能力**——N1 的 fork/reset 端点缺失是表象，本质是 Web 没有"命令"这一层抽象，会话级操作（fork/reset）无法从浏览器触发。

**根因**：命令逻辑散落在 CLI 处理器内，无注册表抽象；Web API 只覆盖会话 CRUD/prompt/abort/rename/delete-message，无通用命令通道。

**历史溯源**：if-chain 分发**是有意的设计决策**——`docs/设计原则整理.md:73` 明确记录"REPL 输入以 `/` 开头，走 processLine 的 if-chain 分发，统一 `render.writeLabeled` 输出"；原始 step-7（0.0.1-alpha）与 V2 收敛文档的 REPL 均为 if-chain。当时单 CLI 前端、命令 5 个，if-chain 合理。技术债在**演进后**累积：①命令增至 8+（/fork//thinking//load）无元数据（描述/参数提示）；②Web 前端出现（v0.2.3）后命令无法跨前端共享，Web 无通道 → fork/reset 悬空成 N1；③`/help` 手写、无补全、无扩展点。

**参考**：opencode `src/command/index.ts`——命令 = `{name, description, template/action, hints[], source}`，内置/配置/MCP/skill 四来源统一注册；执行本质是"模板+参数替换 → prompt"；前端输入 `/` 弹 popover（列表+过滤+键盘导航+参数提示），CLI 与 Web 共享注册表。

## 概览

- **改动范围**：核心 `src/session_ops.zig`（fork/reset 对齐）+ 新增命令注册表 + CLI `App.zig`（dispatch/补全）+ Web `handler.zig`/`app.js`（命令 API + popover），约 6 个文件。
- **核心思路**：建立**命令注册表**（纯数据：`{name, description, args_hint, kind, source}`），CLI 与 Web 共享同一语义；`kind=action` 直接执行（new/name/load/fork/thinking/reset...），`kind=prompt` 模板+参数替换发 LLM（对齐 opencode）。**exec 在前端**——核心注册表是数据，CLI/Web 各自把命令名映射到本地处理器。
- **参考实现**：opencode `command/index.ts` + `prompt-input/slash-popover.tsx`。

## 设计要点

### 1. 命令注册表（核心抽象）

```zig
const Command = struct {
    name: []const u8,
    description: []const u8,
    args_hint: []const u8 = "",     // "name" / "<level>" / "" — 前端参数占位
    kind: enum { action, prompt },
    source: enum { builtin } = .builtin,   // 预留 config/skill
};
```

注册表 = 编译期常量数组。CLI 与 Web 都从它生成清单（`/help` 与 popover 列表同源）。

**`args_hint` 动态生成契约（评审补充）**：hint 是"参数合法值"的提示，若值域可枚举（如 thinking 档位），**从枚举编译期生成**而非手写字符串——`/thinking` 的 hint 由 `@typeInfo(types.ThinkingLevel).@"enum".fields` 遍历拼接（`none|minimal|...`），枚举增删档位自动同步、零漂移。**未来档位可配置化**（运行时值域）时，注册表新增可选 `hint_fn` 动态提供器（运行时生成），本期不预置死代码、记录契约即可。

### 2. 命令分层：核心共享 + 前端自有（评审补充）

命令分两层，尊重单向依赖（核心不感知前端）：

| 层 | 内容 | 存放 |
|----|------|------|
| 核心共享 | fork/name/new/reset/thinking/list/load——跨前端一致的会话操作 | `src/command.zig` 注册表 |
| CLI 自有 | exit/quit/help——REPL 进程控制 + 文本帮助 | `App.zig` 本地命令表 |
| Web 自有 | theme/clear/model——UI 动作（不映射核心操作） | `app.js` 本地命令表 |

前端 popover / `/help` 输出 = **核心注册表 + 本地表合并**。这样 `/theme` 不进核心（核心不关心 CSS），`/exit` 不泄漏到 Web。opencode 同理：核心命令外，前端有自身 palette 项。

### 3. 命令分发：CLI dispatch + Web 通用命令 API

**CLI**：`processLine` 的 if-chain 改为先查 CLI 本地表、再查核心注册表分派。`kind=action` 调对应处理器；未知命令 → 提示 `/help`。

**Web**：新增 **`GET /api/command`**（列表，核心注册表）与 **`POST /api/command`**（执行，body `{name, args}`）。Web 自有的 theme/clear/model 不经过 API（纯前端本地处理）。**N1 的 fork/reset 由此获得 Web 入口**：

| 命令 | 核心操作 | Web 现状 |
|------|----------|----------|
| fork | `session_ops.fork`（已有） | 缺失 → `POST /api/command {name:"fork", args:"..."}` |
| reset | CLI `resetSession`（抽取到 session_ops） | 缺失 → 同上 |

**`POST /api/command` 执行契约（评审补充，action 命令非流式）**：

- **响应为普通 JSON（非 SSE）**，统一信封：`{status:"ok", data?}` / `{status:"error", message?}` / `{status:"busy"}`。fork → `data:{session_id, name}`；new → `data:{session_id, name}`；reset/name/thinking → `data:{}`。
- **与 prompt SSE 互斥**：action 命令是即时操作，与 `/api/session/:id/prompt` 的 SSE 流无关、不并行。
- **会话变更命令**（new/reset/fork/load）响应后，前端须：关闭当前 `evtSrc`（`evtSrc.close()`）、更新 `currentId`/`currentName`、重渲染 messages 与会话列表（复用 `loadSession`/`loadSessions` 既有逻辑）——与现有 `new-session-btn`/`deleteSession` 的后处理一致。
- **流式冲突守卫**：当前会话正在流式（`isStreaming`）时，前端**阻止**会话变更命令（与删除会话守卫一致）；服务端**兜底**返回 `{status:"busy"}`（若该 session 有进行中的 prompt）。两层防护防状态撕裂。

### 4. 命令清单（核心 + 前端自有）

| 命令 | 层 | kind | 描述 | args_hint |
|------|----|------|------|-----------|
| `/new` | 核心 | action | 新建/重置会话 | — |
| `/name` | 核心 | action | 重命名会话 | `name` |
| `/list` | 核心 | action | 列出会话 | — |
| `/load` | 核心 | action | 加载会话 | `name` |
| `/fork` | 核心 | action | 分叉会话 | `name` |
| `/thinking` | 核心 | action | 设置思考档位 | `none\|minimal\|low\|medium\|high\|xhigh\|max`（**从 ThinkingLevel 枚举编译期生成**） |
| `/reset` | 核心 | action | 清空当前会话（对齐 Web N1） | — |
| `/exit` `/quit` | CLI | action | 退出 REPL | — |
| `/help` | CLI | action | 打印命令清单（文本，`writeLabeled`） | — |
| `/theme` | Web | action | 切换浅/深色 | — |
| `/clear` | Web | action | 清空当前消息视图 | — |
| `/model` | Web | action | 切换模型 | `provider/model` |

**`/help` 输出形式按前端**（评审补充）：命令清单的**数据**在核心（`GET /api/command`），但 `/help` 命令是 **CLI 自有**——CLI 打印文本清单；**Web 无独立 `/help`**（聊天 UI 无终端，命令发现即 popover，`/` 即帮助）。前端 `/help`/popover 输出 = 核心注册表 + 前端本地表合并。

### 5. Web slash popover（对齐 opencode）

输入框 `/` 触发 popover：
- **命令清单 = `GET /api/command`（核心） + Web 本地表（theme/clear/model）合并**——不复制内联常量（防漂移）
- 过滤（`/na` → `/name`）、键盘上下+Enter 选择
- 选择后填入 `/name ` 并聚焦，`args_hint` 作 placeholder
- 核心命令提交走 `POST /api/command {name, args}`；Web 本地命令直接执行

复用现有输入框（vanilla JS），不引新框架。

### 5.5 Web 命令 UI 交互设计（评审补充，与 CLI 不同）

Web 无终端，命令交互按聊天/侧边栏范式设计：

**1. 触发与发现**
- 输入 `/` → 输入框上方浮层（popover）列出全部命令：`命令名` + `描述` + `args_hint`（如 `/fork <name>`）。仅有 `/` 时显示全部。
- 侧边栏 `+ New Session` / 主题按钮 / 模型下拉已有等价 UI——命令是**键盘化入口**，不与按钮重复。

**2. 选择与填参**
- 键入过滤（`/na` → `/name`），`↑↓` 导航、`Enter` 选中 → 输入框填入 `/name `，光标置于参数位；继续输入参数后 `Enter` 提交。
- 无参数命令（如 `/reset`）选中后立即提交。

**3. 执行反馈（非流式）**
- 结果经 `POST /api/command` 返回普通 JSON → 复用现有 `status-msg` 临时提示条显示（如 `forked: <name>` / `session reset`），**不写入消息时间线**（会话操作不属于对话内容）。
- 错误 → 红色 status-msg（`{status:"error", message}`）；忙 → `{status:"busy"}` 提示"当前有流式请求，稍后再试"。

**4. 会话变更后处理**
- new/reset/fork/load 成功后：关闭当前 `evtSrc`、`currentId` 指向新会话、重渲染 messages + 会话列表（复用 `loadSession`/`loadSessions`）——与现有 `new-session-btn` 一致。
- fork 成功后自动切换到分叉会话。

**5. 流式冲突**
- `isStreaming` 时：会话变更命令在 popover 中**灰显**且提示；服务端 `busy` 兜底。

**6. 视觉**
- 复用现有 CSS token（`--overlay-*`/`--elevation-*`），浮层贴输入框上缘（对齐 opencode `slash-popover` 布局），无新框架/新主题。

### 6. prompt 模板命令（opencode 语义，本期仅接口+示例）

命令模板含 `$1`/`$2`/`$ARGUMENTS` 占位，执行时替换为参数 → 作为用户消息发 LLM。本期实现接口（`kind=prompt` 走 LLM）与 1 个内置示例（如 `/suggest`：请模型给出当前任务建议），验证链路；完整 `init`/`review`/skill 命令属后续。

## 实施（分阶段，每步编译+验证）

### 阶段 1: 核心命令注册表 + CLI dispatch

**文件**: `src/command.zig`（新）+ `src/frontends/cli/App.zig`
**改动**: 新建 `command.zig` 定义 `Command` 结构与核心注册表（迁移现有会话命令 `new/name/list/load/fork/thinking` + 新增 `reset`）；CLI 本地表（`exit/quit/help`）留在 `App.zig`；`processLine` 改为先查 CLI 本地表、再查核心注册表分派，`/help` 从合并清单生成。

**验证**: `zig build`；CLI 跑 `/help`、`/name`、`/fork` 行为不变（回归）。

### 阶段 2: reset 抽入核心 + fork/reset 对齐

**文件**: `src/session_ops.zig` + `src/frontends/cli/App.zig`
**改动**: CLI `resetSession` 的"清空/新建"逻辑抽入 `session_ops.reset`；`fork` 已存在。确保 CLI 与 Web 可复用。

**验证**: `zig build`；CLI `/new`/`/reset` 回归。

### 阶段 3: Web 通用命令 API + fork/reset 端点

**文件**: `src/frontends/web/handler.zig`
**改动**: 新增 `GET /api/command`（列表，核心注册表——阶段 4 popover 依赖）与 `POST /api/command`（执行，body `{name, args}`），按注册表分发到核心操作；响应 `{status, ...}`。fork/reset 由此可用。

**验证**: `zig build`；`curl POST /api/command {"name":"fork","args":"..."}` 创建分叉会话；`curl GET /api/command` 返回核心命令清单。

### 阶段 4: Web slash popover

**文件**: `src/frontends/web/app.js` + `app.css`
**改动**: 输入框 `/` 检测 → popover（命令列表/过滤/键盘导航/参数 placeholder）；选择后填入输入框。**命令清单从 `GET /api/command` 拉取**（服务端核心注册表驱动，不内联复制）。

**验证**: 浏览器 `/` 弹列表、`/fork name` 提交后侧边栏出现新会话。

### 阶段 5: prompt 模板命令接口 + 示例

**文件**: `src/command.zig` + `app.js`/CLI
**改动**: `kind=prompt` 命令执行 → 模板 `$1`/`$ARGUMENTS` 替换 → 作为用户消息发 LLM；内置 1 示例（如 `/suggest`）。

**验证**: `/suggest 优化X` → 模型收到模板化 prompt。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs
node ..\.opencode\skills\zig-dev\scripts\check-catch-silent.mjs . --audit
```

| 场景 | 预期 |
|------|------|
| CLI `/help` | 从注册表列出全部命令（含描述） |
| CLI 现有命令回归 | `/new`/`/name`/`/fork`/`/thinking` 行为不变 |
| `POST /api/command {name:"fork",args:"x"}` | 创建分叉会话（N1 解决） |
| Web 输入 `/` | popover 列表+过滤+参数提示，选择后提交 |
| `/suggest`（prompt 命令） | 模板+参数 → LLM |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/command.zig`（新） | 命令注册表 + 分发 | 否 |
| `src/session_ops.zig` | 抽取 `reset`，对齐 `fork` | 否 |
| `src/frontends/cli/App.zig` | processLine → 注册表分派；`/help` 注册表驱动 | 是——命令逻辑迁移，需回归 |
| `src/frontends/web/handler.zig` | `GET`/`POST /api/command` | 否 |
| `src/frontends/web/app.js` + `app.css` | slash popover | 否 |
| `docs/REMAINING.md` | 登记本方案（N1 承接） | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| 命令注册表 | `{name, description, args_hint, kind, source}` 编译期常量表，CLI/Web 共享语义 |
| action 命令 | 直接执行会话/配置操作（new/name/fork/reset...） |
| prompt 命令 | 模板+`$1`/`$ARGUMENTS` 替换 → 作为 prompt 发 LLM（opencode 语义） |
| slash popover | 输入 `/` 弹出的命令列表（过滤/键盘导航/参数提示） |
