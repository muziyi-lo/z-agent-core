# Plan LLM-AUTO-TITLE: LLM 自动标题（子代理调用机制）

## 状态: 计划中

## 背景

会话系统一期/二期（`SESSION-SYSTEM-OPT` + `OPT2`，v0.2.7）完成后，会话命名仍是静态启发式：

| 场景 | 现状 | 问题 |
|------|------|------|
| Web 新建会话（`handlePrompt` is_new） | `s.name = prompt[0..min(30)]`（`handler.zig:958`） | 截断 30 字符，可能断在单词中间、含换行，非自然语言 |
| CLI 新会话 | `Session.init` → `"New Session"`（`session.zig:45`） | 永远不自动命名，`/list` 全是 "New Session" |
| Web 空会话 | UUID 名 + `uuid.isUuid` 显示 "New Session"（`handler.zig:284`） | 用户不重命名就保持通用名 |
| fork 子会话 | `(fork #N)` 自动命名（已实施） | ✅ 已有专用命名，不参与 LLM 标题 |

**目标**：首回合结束后用 LLM 根据第一条真实用户消息生成自然语言标题（对齐 opencode `SessionPrompt.ensureTitle`），替换上述静态启发式。

## 参照：opencode ensureTitle + title agent

opencode 实现（`packages/opencode/src/session/prompt.ts:193-253` + `agent/prompt/title.txt` + `agent/agent.ts:234-249`）：

| 维度 | opencode | 本项目落地 |
|------|----------|------------|
| 专用 agent | `agents.get("title")`：隐藏原生 agent，`temperature: 0.5`，权限全 deny，prompt=`title.txt` | 见下方「子代理调用机制」决策 |
| 模型 | agent.model → `getSmallModel` → 会话模型，`small: true` | **用会话当前模型**（无 small model 概念，见决策 D2） |
| 工具 | `tools: {}`（无工具） | `tools = null` |
| 触发 | step===1（首回合循环内），`Effect.forkIn` 异步，不阻塞主回复 | 回合边界同步触发（同步模型，见决策 D1） |
| 触发条件 | ① 无 parentID ② 标题为默认 ③ 恰 1 条真实用户消息 | 对齐（见下方「触发条件」） |
| 请求消息 | `[{user: "Generate a title for this conversation:\n"}, ...context 转模型消息]` + 专用 system | `[system: TITLE_PROMPT, user: 首条用户消息]` |
| 结果清洗 | 剥 `<think>` 块 → 取首个非空行 → 截断 100 字符 | 对齐（`title.txt` 要求 ≤50 字符，代码实际截断 100） |
| 失败语义 | `Effect.catchCause` 静默，不失败回合 | LLM 失败回退静态截断（见 D4），不失败回合 |
| 写入 | `sessions.setTitle`（改标题不改 id） | `session.rename(title)` + `flush`（`rename` 不改文件名，id 稳定） |

## 子代理调用机制（核心问题）

### 问题

LLM 自动标题需要一次**独立的、轻量的 LLM 调用**，与主 agent 循环（`AgentLoop.runTurn`）有本质区别：

| 需求 | 主循环 runTurn | 标题生成需要 |
|------|---------------|-------------|
| 注入系统提示词 | 每回合 `updateFirstSystem` | ❌ 用专用 title prompt，不碰会话 system 消息 |
| 工具循环 | 有（8 工具 + StormBreaker） | ❌ 无工具 |
| 流式展示 | 有（PhaseWriter/ToolDisplay） | ❌ 静默（`phase_writer = null`） |
| 写消息记录 | 有（append assistant/tool） | ❌ 不写消息，只改 header name |
| 上下文 | 全量会话 + 系统提示词 | ✅ 只需首条用户消息 |

**复用 `runTurn` 不可行**——会触发 system prompt 注入、工具执行、消息追加、前端流式展示，产生副作用且浪费 token。

### 现状：已有的一次性 LLM 调用模式

`core/compact.zig` 的 `compactSession`（`compact.zig:131`）已经证明了一个可行模式：**直接调 `provider.chatCompletionStreaming(arena, io, messages, null, null)`**（`provider.zig:106`，`tools=null`、`phase_writer=null`）——无工具、无展示、带 arena、带 retry（5× backoff）。这就是 z-agent-core 的"子代理调用"最小实现，无需引入 sub-agent 注册表。

### 决策

**D1 — 触发时机：回合边界同步触发（首回合完成后）**

| 方案 | 说明 | 决策 |
|------|------|------|
| 回合前（append user 后、runTurn 前） | 标题立即就绪，但阻塞首答（同步模型无 forkIn） | ❌ 首答延迟不可接受 |
| **回合后（runTurn 完成后）** | 首答结束后触发，不阻塞主回复；标题在列表刷新时可见 | ✅ **采用**（对齐"标题出现在回答之后"的自然体验，opencode 也是回答期间异步生成） |

- CLI：`processLine`/`singleTurn` 在 `runTurn` 返回后、`session.flush()` 前调用（首回合 + 标题为默认 + 恰 1 条 user 时触发）。
- Web：`handleSSE` 在 `runTurn` 返回后、`sse_done` 帧前调用（`handler.zig:1055` 附近）。
- 因触发条件含"恰 1 条真实用户消息"，**天然只在首回合触发一次**——第二回合起消息数 >1，判定返回 false，无需额外去重标志（对齐 opencode step===1）。

**D2 — 模型：用会话当前模型（不引入 small model）**

opencode 用 `getSmallModel`（title agent 默认）。z-agent-core 的 config 无 small model 概念（`config.zig` 只有 `default_model`），引入需配置模型解析、校验、回退多套逻辑。首条用户消息通常很短，标题请求 token 成本可忽略，**用会话当前模型（`provider` 已配置）**。small model 列入后续可选（`title_model` 配置项，REMAINING Future）。

**D3 — 子代理实现形态：`core/title.zig` + `generateTitle()`，复用 `chatCompletionStreaming`**

新增 `src/core/title.zig`，与 `compactSession` 同构：

```zig
/// LLM 生成会话标题（子代理调用）。仅当标题为默认且会话恰有 1 条真实
/// 用户消息时有效；调用方（frontend）先做守卫判定再调用。
/// 不写消息记录、不注入系统提示词。
/// LLM 成功 → rename 为 LLM 标题；LLM 失败/空结果 → 回退到首条用户消息的
/// 30 字符截断（D4），保证至少有一个有意义的标题。都 flush。
pub fn ensureTitle(
    provider: *provider_mod.Provider,
    session: *session_mod.Session,
    allocator: std.mem.Allocator,
    io: Io,
) bool;
```

- 请求构造：`[system: TITLE_PROMPT, user: 首条真实用户消息 content]`。
- 内部 `provider.chatCompletionStreaming(&arena_state, io, msgs, null, null)`（无工具、无 phase_writer → 静默）。
- 清洗结果（对齐 opencode）：剥 `<think>` 块 → 按行 split/trim → 取首个非空行 → `len > 100` 截断为 `[0..97] + "..."`。
- 空结果/失败 → **回退静态截断标题**（见 D4），不失败回合。
- 成功 → `session.rename(title)` + `session.flush()`。
- 守卫判定函数独立（`shouldAutoTitle`，供 frontend 在 runTurn 前/后自检，避免无谓请求）。

**D4 — 失败回退：LLM 失败/空结果 → 静态截断 `prompt[0..30]`（评论者建议采纳）**

LLM 调用可能失败（网络/限流/模型拒绝）。原方案失败后保持 "New Session"/UUID 名——对 Web is_new 是回退（`handler.zig:958` 已设 `prompt[0..30]`），但对 CLI 是保持通用名，会话无有意义标题。

**改为：LLM 失败或空结果时，回退到首条真实用户消息的 30 字符截断**（对齐现有 Web 启发式），保证 CLI 与 Web 一致地至少有一个有意义的标题：

- 回退值 = `prompt[0..min(30)]`（首条真实用户消息），与 Web is_new 现状（`handler.zig:958`）完全一致
- 回退也做基本清洗（trim、剥换行）——对齐 `cleanTitle` 的宽松规则，避免标题夹带首尾空白/换行
- 回退不失败回合、不重试（best-effort）
- CLI 新会话若 LLM 失败 → 标题为截断文本，而非 "New Session"；Web is_new 本就截断 → LLM 成功则覆盖、失败则保留截断（行为不变）
- 空会话（无用户消息）无 prompt 可截断 → 保持 "New Session"/UUID 名（无内容可命名，符合预期）

**D5 — 配置开关：`auto_title`（默认开启，可关闭）**

对齐 opencode 的 `agent.title.disable`（`agent.ts:268` `if (value.disable) delete agents[key]`）。z-agent-core 无 agent registry，采用**顶层 TOML 布尔开关**（对齐现有 `max_tool_rounds`/`skills_dir` 配置风格）：

```toml
# .zagent/config.toml
# Auto-generate a conversational title with the LLM after the first turn.
# Set false to keep static naming (Web prompt-prefix, CLI "New Session").
auto_title = true
```

- `config.zig` `Config` 增 `auto_title: bool = true`；`parseConfigContent` 用 `getBool(parsed, "auto_title") orelse true`（`config.zig:460`）；`DEFAULT_TEMPLATE` 加注释行（`config.zig:526`）
- `shouldAutoTitle` 签名增 `enabled: bool` 参数（或在调用方检查 `cfg.auto_title`）：`false` → 直接返回，不生成、不改名——CLI/Web 行为回退到现状（Web 保留 `prompt[0..30]` 截断启发式，CLI 保持 "New Session"）
- 开关只影响 LLM 标题；**不影响 Web is_new 的 `prompt[0..30]` 静态截断**（那是既有行为，非本计划引入）
- 实现上 CLI `App` 持有 `cfg`（`App.zig:67`）、Web `ctx.config`（`handler.zig`）均可直接读取，无侵入

**TITLE_PROMPT**（对齐 opencode `title.txt` 精编版）：

```text
You are a title generator. You output ONLY a thread title. Nothing else.
Generate a brief title that would help the user find this conversation later.
- A single line, <=50 characters, no explanations
- Use the same language as the user message
- Never include tool names
- Focus on the main topic or question the user needs to retrieve
- Keep exact: technical terms, numbers, filenames, HTTP codes
- If the message is short or conversational (e.g. "hello"), reflect its tone
  (such as Greeting, Quick check-in, Light chat)
- NEVER respond to questions, just generate a title
```

> 注：z-agent-core 首回合标题生成在 runTurn **之后**，此时 session 里已含首条 assistant 回复。取用户消息时**只看首条 `role == .user` 消息**（跳过系统提示词 index 0），不把 assistant 回复喂给 title（避免标题偏向后半段）。

## 触发条件（对齐 opencode ensureTitle）

前端（CLI `App` / Web `handler`）在回合边界调用 `shouldAutoTitle(session, auto_title)` 判定：

0. **开关启用**：`auto_title == true`（D5，`config.zig` 顶层布尔，默认 true）。关闭 → 直接返回，不改名。
1. **无 parent_id**：fork 子会话已有 `(fork #N)` 命名，不触发（对齐 opencode `if (input.session.parentID) return`）。
2. **标题为默认**：`name == "New Session"`（CLI/新会话默认）**或** `uuid.isUuid(name)`（Web 空会话）**或** `name` 等于首条用户消息的 30 字符截断（Web is_new 启发式）——判定为"尚未命名"。
3. **恰 1 条真实用户消息**：`msgs` 中 `role == .user` 的数量 == 1（排除 index 0 系统提示词；`[Compaction]` 是 system 不计入）。

四项全满足才调用 `ensureTitle`。任一失败 → 保留现状，静默。

## 实施步骤

**步骤 1**: 新增 `src/core/title.zig`——`TITLE_PROMPT` 常量、`shouldAutoTitle(session, auto_title) bool`、`cleanTitle(raw) !?[]const u8`（剥 think/首行/截断）、`fallbackTitle(user_msg) ![]const u8`（30 字符截断 + trim/剥换行）、`ensureTitle(provider, session, allocator, io) bool`（LLM 成功 → LLM 标题；失败/空 → `fallbackTitle`；均 rename + flush）。
**步骤 2**: `config.zig`——`Config` 增 `auto_title: bool = true`，`parseConfigContent` 读 `getBool("auto_title") orelse true`，`DEFAULT_TEMPLATE` 加注释行。
**步骤 3**: `cli/App.zig`——`processLine`（`App.zig:399` runTurn 后）与 `singleTurn`（`App.zig:240` runTurn 后）传 `self.cfg.auto_title` 调 `shouldAutoTitle` + `ensureTitle`（在 `session.flush()` 前）。
**步骤 4**: `web/handler.zig`——`handleSSE` 在 `runTurn` 返回后（`handler.zig:1055` `session.flush()` 前）传 `ctx.config.auto_title` 调 `shouldAutoTitle` + `ensureTitle`（复用 `agent.provider_ref` 与当前 `session`）。
**步骤 5**: 测试——`title.zig` 单测（开关关闭直接 false / shouldAutoTitle 四条件 / cleanTitle think 剥离与截断 / ensureTitle 空 LLM 结果回退截断）；`config.zig` 测试（`auto_title` 默认 true、`auto_title = false` 解析）；`node tests/frontend/run-tests.mjs` 回归。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs
```

| 测试场景 | 预期结果 |
|----------|----------|
| `auto_title = true`（默认） | 首回合后生成 LLM 标题 |
| `auto_title = false` | 首回合不触发、不改名；Web 保持 `prompt[0..30]` 截断，CLI 保持 "New Session" |
| CLI 首回合（`--prompt "帮我修 src/app.js 的 500 错误"`） | 回合结束后面板无新输出（静默），`/list` 显示自然语言标题（如 "App.js 500 错误排查"） |
| CLI 第二回合 | 不再触发（消息数 >1），标题保持首回合生成值 |
| Web 新会话首条消息 | `sse_done` 后 `loadSessions` 列表显示 LLM 标题，替换 30 字符截断 |
| fork 子会话 | 不触发（有 parent_id，保持 `(fork #N)`） |
| 已重命名会话（非默认标题） | 不触发 |
| title LLM 调用失败 / 空结果 | 回合正常完成，标题回退为首条用户消息 30 字符截断（CLI 不再是 "New Session"，Web 保持截断），无报错 |
| title 输出含 `<think>` 块 / 多行 | 剥 think、取首非空行、超 100 截断 |
| 会话重载后标题 | `rename` 不改文件名，id/路径稳定，重载后 header name 为生成标题或回退截断 |
| 空会话（无用户消息） | 无 prompt 可截断 → 保持 "New Session"/UUID 名，不触发 title |

## 涉及文件

| 文件 | 改动 |
|------|------|
| `src/core/title.zig` | 新增：TITLE_PROMPT / shouldAutoTitle / cleanTitle / fallbackTitle / ensureTitle |
| `src/config.zig` | `Config.auto_title: bool` 字段 + 解析 + DEFAULT_TEMPLATE 注释 |
| `src/frontends/cli/App.zig` | `processLine` + `singleTurn` 回合边界调用（传 `cfg.auto_title`） |
| `src/frontends/web/handler.zig` | `handleSSE` runTurn 后调用（传 `ctx.config.auto_title`） |
| `docs/REMAINING.md` | F2 标记实施（发布时） |

## 明确不做

- **small model（`title_model` 配置）**：本期用会话当前模型；小模型节省的 token 在首条消息场景可忽略，后续需要再加
- **按会话/按命令粒度开关**：本期只做全局 `auto_title` 顶层开关；per-session 或 `/title off` 命令粒度后续按需评估
- **异步/fire-and-forget**：同步模型下回合后触发已不阻塞主回复，无线程需求
- **CLI 实时标题刷新**：CLI 无 TUI，标题在 `/list` 可见即可（对齐现有会话管理交互）
- **sub-agent 注册表 / 通用子代理抽象**：只有一个消费者（title），`compactSession` 已证明直接 provider 调用足够；出现第二个子代理（如 F4 分支摘要）时再评估抽象
- **改 Web 空会话 UUID 命名逻辑**：`handleSessionCreate` 空会话仍保持 UUID 名 + 前端显示 "New Session"，由 title 生成后自然替换
- **失败时保持 "New Session"**：已否决——LLM 失败回退静态截断（D4），保证任何有内容会话都有有意义标题

## 备注

- 创建：2026-08-13
- 承接：`SESSION-SYSTEM-OPT`（一期 P1-P5）+ `SESSION-SYSTEM-OPT2`（二期），会话系统主题延续；归入 v0.2.7 周期目录（用户决策）
- REMAINING.md 索引：F2（"无 parentID + 仅 1 条真实用户消息 + 默认标题 → LLM 生成首行"，本计划将其落地）
