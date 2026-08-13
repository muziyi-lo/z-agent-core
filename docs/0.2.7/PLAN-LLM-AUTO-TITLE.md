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

**目标**：第二轮回合结束后用 LLM 根据前两条真实用户消息生成自然语言标题（对齐 ChatGPT/Claude"新对话"占位 + 延迟命名范式），替换上述静态启发式。

## 参照：opencode ensureTitle + title agent

opencode 实现（`packages/opencode/src/session/prompt.ts:193-253` + `agent/prompt/title.txt` + `agent/agent.ts:234-249`）：

| 维度 | opencode | 本项目落地 |
|------|----------|------------|
| 专用 agent | `agents.get("title")`：隐藏原生 agent，`temperature: 0.5`，权限全 deny，prompt=`title.txt` | 见下方「子代理调用机制」决策 |
| 模型 | agent.model → `getSmallModel` → 会话模型，`small: true` | **用会话当前模型**（无 small model 概念，见决策 D2） |
| 工具 | `tools: {}`（无工具） | `tools = null` |
| 触发 | step===1（首回合循环内），`Effect.forkIn` 异步，不阻塞主回复 | 回合边界同步触发（同步模型，见决策 D1） |
| 触发条件 | ① 无 parentID ② 标题为默认 ③ 恰 1 条真实用户消息 | ① 无 parent_id ② 标题为默认 ③ **恰 2 条**真实用户消息（第二轮延迟，D1）；④ `auto_title` 开关（D5） |
| 请求消息 | `[{user: "Generate a title for this conversation:\n"}, ...context 转模型消息]` + 专用 system | `[system: TITLE_PROMPT, user: 前两条 user 消息拼接]`（D3） |
| 结果清洗 | 剥 `<think>` 块 → 取首个非空行 → 截断 100 字符 | 对齐（`title.txt` 要求 ≤50 字符，代码实际截断 100） |
| 失败语义 | `Effect.catchCause` 静默，不失败回合 | 三层降级 LLM→本地关键词→静态截断（D4），不失败回合 |
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

**D1 — 触发时机：第二轮回合后触发（子代理后台执行）**

| 方案 | 说明 | 决策 |
|------|------|------|
| 回合前（append user 后、runTurn 前） | 标题立即就绪，但阻塞首答（同步模型无 forkIn） | ❌ 首答延迟不可接受 |
| 首回合后（runTurn 完成后） | 首答结束后触发，不阻塞主回复 | ❌ 首条消息意图不可靠（greeting/元操作如"恢复上下文"/试探），标题质量差；且产生一次无效请求 + 错误的持久标题 |
| **第二轮回合后（runTurn 完成后）** | 第二轮用户已表达真实任务，标题命中率高；首轮保持占位；由子代理后台执行（D6） | ✅ **采用**（对齐 ChatGPT/Claude"新对话"占位 + 延迟后台生成范式） |

- CLI：`processLine`/`singleTurn` 在 `runTurn` 返回、usage 显示后**立即返回提示符**（标题由子代理后台执行，D6）；`pipe_mode` 跳过（输出纯净性）。**执行机制见 D6**。
- Web：`handlePrompt` 在 `runTurn` 返回、**`sse_done` 帧写出之后**（`handler.zig:1069`）、`handlePrompt` 返回前 `spawnSubcall`（D6）——客户端已收到 done 并关闭 SSE，**连接线程不等待标题**（D6）。
- 因触发条件含"恰 2 条真实用户消息"，**天然只在第二轮回合后触发一次**——第三回合起消息数 >2，判定返回 false，无需额外去重标志。
- **首轮占位**：Web 保持 `prompt[0..30]` 截断（`handler.zig:958`），CLI 保持 "New Session"——即成熟系统的 "New chat" 占位，零新增成本。

> **为什么不用首轮（区别于 opencode）**：opencode 首轮触发（step===1）是因为其标题 agent 假设首条已是任务（`firstUser`）且对会话性消息给意图标题兜底。本项目的用户场景存在元操作消息（如"恢复上下文"），首轮触发会污染会话元数据。第二轮意图显著清晰后命名，命中率与标题质量都更高。参照：ChatGPT/Claude 均以"新对话"占位、等待 2-3 轮交互后由后台生成器命名。

**D2 — 模型：用会话当前模型（不引入 small model）**

opencode 用 `getSmallModel`（title agent 默认）。z-agent-core 的 config 无 small model 概念（`config.zig` 只有 `default_model`），引入需配置模型解析、校验、回退多套逻辑。标题请求喂前两条用户消息、token 成本可忽略，**用会话当前模型（`provider` 已配置）**。small model 列入后续可选（`title_model` 配置项，REMAINING Future）。

**D3 — 子代理实现形态：`core/title.zig` + `ensureTitle()`，复用 `chatCompletionStreaming`**

新增 `src/core/title.zig`，与 `compactSession` 同构：

```zig
/// LLM 生成会话标题（子代理调用，在后台线程执行）。仅当标题为默认且会话
/// 恰有 2 条真实用户消息时有效（第二轮后触发，对齐 ChatGPT/Claude 延迟
/// 命名范式）；调用方（frontend）先做守卫判定再调用。
/// 不写消息记录、不注入系统提示词。
/// LLM 成功 → rename 为 LLM 标题；LLM 失败/空结果 → 本地关键词（keywordTitle，
/// L2）→ 空则静态截断最近一条用户消息（fallbackTitle，L3），保证至少有
/// 一个有意义标题。写回持 session_write_mutex 串行化（D6）。
pub fn ensureTitle(
    provider: *provider_mod.Provider,
    session: *session_mod.Session,
    allocator: std.mem.Allocator,
    io: Io,
) bool;
```

- 请求构造：`[system: TITLE_PROMPT, user: 前两条真实用户消息的拼接]`（跳过系统提示词 index 0；`[Compaction]` 是 system 不计入）。两轮 user 消息足以覆盖"元操作 + 真实任务"模式（如"恢复上下文" + "帮我修 X"→ 标题反映 X）。
- 内部 `provider.chatCompletionStreaming(&arena_state, io, msgs, null, null)`（无工具、无 phase_writer → 静默）。
- 清洗结果（对齐 opencode）：剥 `<think>` 块 → 按行 split/trim → 取首个非空行 → `len > TITLE_HARD_CAP` 截断为 `[0..97] + "..."`（`TITLE_HARD_CAP = 100`）。
- 空结果/失败 → **三层降级**（见 D4）：keywordTitle → fallbackTitle，不失败回合。
- 成功 → `session.rename(title)` + `session.flush()`。
- 守卫判定函数独立（`shouldAutoTitle`，供 frontend 在 runTurn 前/后自检，避免无谓请求）。

**D6 — 子代理调用机制：独立生命周期 + 后台线程执行（重写，修正生命周期缺陷）**

> **本质**：标题生成是**子代理调用**——一次独立的一次性 LLM 调用（专用 prompt、无工具、静默），必须作为独立生命周期对象（创建→执行→写回→清理），**不寄生主请求线程**。这是后续子代理功能（F4 分支摘要、未来 tool 内 LLM 调用）的**前置基础设施**。

**原方案缺陷（`sse_done` 帧后同步执行，审查发现）**：

| # | 缺陷 | 后果 |
|---|------|------|
| L1 | **abort_map 竞态窗口**：`abort_map.remove` 在 `handlePrompt` 返回时 defer（`handler.zig:1010-1016`），ensureTitle 若在返回前同步执行 1-5s，abort_map 仍持有该 session | 前端收 done 后立即发第三条消息 → `isSessionStreaming`（`handler.zig:882`）误判 busy → 拒绝 |
| L2 | **并发 flush 丢消息（致命）**：`session.flush` 整文件 `tmp+rename` 原子替换（`session.zig:399-419`）；标题 flush 与第三条消息的 append+flush 并发时，旧线程用旧消息快照**整文件覆盖** | 用户第三条消息丢失 |
| L3 | **请求线程生命周期耦合**：标题 1-5s 阻塞连接线程收尾；若异步则需等待请求线程 arena 释放，存在 UAF 风险 | 阻塞 + 悬垂 |

**正确设计：子代理 = 独立后台线程（fire-and-forget detached），拥有完整生命周期**。

```
创建  spawn(task) —— 独立 arena + 复制 provider 配置（api_key dup）+ dup session_id/sessions_dir
执行  线程内 Session.load 磁盘副本 → shouldAutoTitle 复查（防御）→ Provider 独立副本
      → chatCompletionStreaming(msgs, null, null) → cleanTitle
写回  renameTitle() 原子事务（单层持锁，见下）
清理  arena.deinit + thread.detach；失败路径同样清理
退出  active_threads 计数等待（复用 server.zig:151-163 的 30s 等待先例）
```

**`session_write_mutex` 锁边界（评论者质疑澄清）**：

`session.rename()`（`session.zig:476`）是**纯内存操作**（改 `self.name` + `modified`），**不涉及文件**；文件系统 rename 在 `flush()` 内部（`session.zig:419` `Io.Dir.rename(tmp→path)`），且 **tmp 文件名固定**（`session.zig:399` `{path}.tmp`）——并发 flush 同一 session 会写同一 tmp 文件互相覆盖。因此锁必须覆盖**读-改-写整个事务**，且**单层持锁**：

- 新增**原子事务函数**（`core/subcall.zig` 或 `session.zig` 高层）：

```zig
/// 原子重命名会话标题：锁内 load 最新 → 内存 rename → flush 写盘。
/// 单层持锁——调用方不得在已持锁时再调本函数或底层 flush。
pub fn renameTitle(
    allocator: std.mem.Allocator,
    io: Io,
    session_dir: []const u8,
    id: []const u8,
    new_name: []const u8,
) !void {
    session_write_mutex.lock(io) catch unreachable;
    defer session_write_mutex.unlock(io);
    var sess = try Session.load(allocator, io, join(session_dir, id));  // 锁内读最新
    defer sess.deinit();
    try sess.rename(new_name);        // 内存改名
    try sess.flushLocked();           // 锁内写盘（无锁内部版，不重入）
}
```

- **`Session.flush` 拆双版**：公开 `flush()` 持锁调 `flushLocked()`；`flushLocked()` 为无锁内部版（含 `session.zig:419` 的文件 rename）。主线程既有调用点（`handler.zig`/`App.zig`/`compact.zig`）继续调公开 `flush()` → 自动持锁，与子代理事务互斥。**禁止**在持锁事务内再调公开 `flush()`（死锁）
- **子代理写回** = `renameTitle()`（一次调用，锁覆盖 load→rename→flush 全程）——load 在锁内读到最新（含主线程已 flush 的消息），rename+flush 原子，**杜绝旧快照覆盖新消息**
- `load()` 本身在子代理线程开始时**锁外**调用仅用于守卫复查（只读不写，无竞争）；写回才走锁内 `renameTitle()`
- `writeTo`/`writePrefixTo`/`removeMessage` 同样拆 `XxxLocked` + 公开持锁包装，或改为调用方持锁——统一原则：**写盘代码只在一层持锁，公开入口持锁，内部无锁**

**并发安全矩阵**（G14 生命周期 + F4 跨线程审查）：

| 资源 | 处理 | 说明 |
|------|------|------|
| arena | 每线程独立 | 无 UAF，不依赖请求线程 allocator |
| Provider | 线程内独立副本（config 值拷贝 + api_key dup） | 无共享可变状态，无锁 |
| session 文件 | **进程级 `session_write_mutex`（`Io.Mutex`）** 串行化**原子写事务**（`renameTitle` 与公开 `flush()`） | 防整文件覆盖竞争；`session.rename` 是内存操作，文件 rename 在 flush 内（`session.zig:419`） |
| 写回 | `renameTitle()` 单层持锁：锁内 load 最新 → 内存 rename → `flushLocked` 写盘 | 读-改-写原子，基于最新消息，不丢并发写入 |
| abort_map | 子代理**不碰** abort_map | 不误判 isSessionStreaming，与主线程隔离 |
| 进程退出 | `active_threads` 计数等待 | 复用 server.zig 模式；CLI `deinit` 前等待子代理完成 |

**`session_write_mutex`**（新增，`core/session.zig` 进程级，`Io.Mutex` 对齐 `abort_mutex` 先例）：锁覆盖**所有写盘代码**（`renameTitle` 事务 + 公开 `flush()`/`writeTo`/`writePrefixTo`/`removeMessage`），但**只在一层持锁**——公开入口持锁，内部 `XxxLocked` 无锁。不同 session 文件也被全局串行化，flush 是轻量小文件写，可接受。

**CLI 与 Web 统一走子代理机制**（消除两前端可见阻塞）：
- **Web**：`handlePrompt` `sse_done` 后 `spawnSubcall`（立即返回，不阻塞连接线程收尾）
- **CLI**：`processLine`/`singleTurn` 回合尾 `spawnSubcall`（立即返回，REPL 提示符即时出现）；`deinit` 前等待子代理完成（`active_threads == 0`，有限等待如 30s）
- `pipe_mode` 跳过（不污染 stdout）

> 子代理机制抽象在 `core/subcall.zig`（`SubcallRunner`：`spawn(task)` + 计数 + `waitIdle()`），标题与 F4 共用。F4 分支摘要"切回主线即时注入"也走同一 runner（若需注入结果，runner 增加回调或结果队列，本期标题为 fire-and-forget 不等待）。

**D4 — 失败回退：三层降级 LLM → 本地关键词 → 静态截断（评论者建议采纳）**

LLM 调用可能失败（网络/限流/模型拒绝）。原方案失败后保持 "New Session"/UUID 名——对 Web is_new 是回退（`handler.zig:958` 已设 `prompt[0..30]`），但对 CLI 是保持通用名，会话无有意义标题。

**改为三层降级**，每层比上层更廉价、更粗粒度；任何一层产出非空标题即停：

| 层 | 输入 | 方法 | 失败→ |
|----|------|------|-------|
| **L1 LLM** | 前两条真实 user 消息 | `chatCompletionStreaming` 生成（主路径） | 超时/限流/API 错误/空结果 → L2 |
| **L2 本地关键词**（新增） | 最近一条真实 user 消息 | 轻量规则提取 `KEYWORD_MIN..KEYWORD_MAX` 个关键词拼接（见下） | 提取为空（消息全停用词/过短）→ L3 |
| **L3 静态截断** | 最近一条真实 user 消息 | `[0..min(TITLE_PREFIX_LEN)]` + trim/剥换行（对齐 Web 启发式） | 空会话无消息 → 保持 "New Session"/UUID |

**L2 关键词提取规则**（本地零成本、无 LLM）：

- 输入 = 最近一条真实 user 消息（第二轮触发时即第二条 user——比首条更贴近当前意图；首条可能是"恢复上下文"等元操作）
- 按空白/标点切词 → 过滤 `STOPWORDS` 停用词（中英常用，见常量节）→ 保留词干顺序取 **`KEYWORD_MIN..KEYWORD_MAX` 个** → 空格/顿号拼接
- 保持原语言（不做翻译）——与 LLM 层要求一致
- 拼接后长度 > `TITLE_MAX_CHARS` 截断（对齐 `title.txt` ≤50 约束）
- 失败语义：提取结果为空（消息全为停用词或过短）→ 落到 L3，不额外处理

**示例**：`"帮我修 src/app.js 的 500 错误"` → 去停用词 → `src app.js 500 错误` → 标题 `"src app.js 500 错误"`（优于静态截断的 `"帮我修 src/app.js 的 500"`——后者含停用词且断在不自然处）。

**其他语义**：
- 三层均 best-effort、不重试、不失败回合
- 静态截断（L3）保留作为最终兜底——L2 空结果时仍保证 CLI 不再是 "New Session"、Web 更新为最近消息截断
- 空会话（无用户消息）三层皆无输入 → 保持 "New Session"/UUID 名（无内容可命名，符合预期）
- Web is_new 的 `prompt[0..30]`（`handler.zig:958`）仍是首轮占位；LLM 成功则覆盖、LLM 失败则 L2/L3 升级为更贴切的标题

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

> 注：z-agent-core 第二轮回合后触发标题生成，此时 session 里已含前两轮 assistant 回复。取用户消息时**只看 `role == .user` 的前两条**（跳过系统提示词 index 0），不把 assistant 回复喂给 title（避免标题偏向后半段）。子代理线程内从磁盘 `load` 最新 session 副本后取数。

**标题相关常量（评论者建议采纳）**

原 D3/D4 用裸数字（`30`/`50`/`100`/`3-5`），且与现有代码 `handler.zig:958` 的硬编码 `@min(prompt.len, 30)` 值耦合——改一处忘另一处会漂移。**统一提取为 `core/title.zig` 顶层 `pub const`**（对齐项目先例：`compact.zig:10-15` 的 `DEFAULT_KEEP_RECENT_TOKENS`/`MIN_KEEP_MESSAGES`/`COMPACTION_PREFIX`）：

```zig
/// Title length cap from the title prompt (title.txt: `<=50 characters`).
pub const TITLE_MAX_CHARS: usize = 50;
/// Hard truncation cap for cleaned LLM titles (opencode truncates >100 → 97+"...").
pub const TITLE_HARD_CAP: usize = 100;
/// Static fallback prefix length (L3). MUST equal Web is_new prompt-prefix
/// (handler.zig:958 `@min(prompt.len, 30)`) — shared via this constant.
pub const TITLE_PREFIX_LEN: usize = 30;
/// Keyword extraction token range (L2): keep the first 3-5 non-stopword tokens.
pub const KEYWORD_MIN: usize = 3;
pub const KEYWORD_MAX: usize = 5;
/// Stopwords filtered by L2 keyword extraction. Chinese + English common words.
pub const STOPWORDS = [_][]const u8{
    "的", "了", "是", "我", "你", "他", "帮", "请", "一个", "在", "用", "修",
    "the", "a", "an", "to", "of", "and", "or", "for", "with", "please",
};
```

- **`TITLE_PREFIX_LEN` 双端共享**：`core/title.zig` 定义；`handler.zig:958` 的 `@min(prompt.len, 30)` 改为 `@min(prompt.len, title_mod.TITLE_PREFIX_LEN)`——Web is_new 占位与 L3 回退同源，改值一处生效（`handler.zig` 已 import core 模块，单向依赖不破坏）
- `STOPWORDS` 独立常量便于后续增删维护（评论者建议）；`keywordTitle` 遍历 `STOPWORDS` 判定
- 上述常量全部在 `core/title.zig` 顶层，与 `TITLE_PROMPT` 同文件（标题逻辑单一来源）

## 触发条件（对齐 opencode ensureTitle）

前端（CLI `App` / Web `handler`）在回合边界调用 `shouldAutoTitle(session, auto_title)` 判定：

0. **开关启用**：`auto_title == true`（D5，`config.zig` 顶层布尔，默认 true）。关闭 → 直接返回，不改名。
1. **无 parent_id**：fork 子会话已有 `(fork #N)` 命名，不触发（对齐 opencode `if (input.session.parentID) return`）。
2. **标题为默认**：`name == "New Session"`（CLI/新会话默认）**或** `uuid.isUuid(name)`（Web 空会话）**或** `name` 等于某条真实用户消息的 30 字符截断（Web is_new 启发式）——判定为"尚未命名"。
3. **恰 2 条真实用户消息**：`msgs` 中 `role == .user` 的数量 == 2（排除 index 0 系统提示词；`[Compaction]` 是 system 不计入）。第二轮后命名（D1，对齐 ChatGPT/Claude 延迟范式）。

四项全满足才调用 `ensureTitle`。任一失败 → 保留现状，静默。

## 实施步骤

**步骤 1**: 新增 `src/core/title.zig`——常量（`TITLE_MAX_CHARS`/`TITLE_HARD_CAP`/`TITLE_PREFIX_LEN`/`KEYWORD_MIN`/`KEYWORD_MAX`/`STOPWORDS`，见常量节）+ `TITLE_PROMPT` 常量、`shouldAutoTitle(session, auto_title) bool`、`cleanTitle(raw) !?[]const u8`（剥 think/首行/`TITLE_HARD_CAP` 截断）、`keywordTitle(user_msg) !?[]const u8`（L2 本地关键词：切词→滤 `STOPWORDS`→取 `KEYWORD_MIN..KEYWORD_MAX` 个→拼接）、`fallbackTitle(user_msg) ![]const u8`（L3 静态截断 `TITLE_PREFIX_LEN` + trim/剥换行）、`ensureTitle(provider, session, allocator, io) bool`（LLM 成功 → LLM 标题取前两条 user；失败/空 → `keywordTitle` → 空则 `fallbackTitle`；写回持锁）。
**步骤 2**: 新增 `src/core/subcall.zig`——`SubcallRunner`（`spawn(task)` fire-and-forget detached 线程 + `active_threads` 计数 + `waitIdle()`）；task 携带 provider 配置副本（api_key dup）+ session_id + sessions_dir + auto_title；线程内独立 arena → `Session.load` 磁盘副本 → 复查 `shouldAutoTitle` → `ensureTitle` → arena 释放。
**步骤 3**: `core/session.zig`——进程级 `session_write_mutex: Io.Mutex`；`flush`/`writeTo`/`writePrefixTo`/`removeMessage` 拆双版（公开持锁调 `XxxLocked` 无锁内部版，含 `session.zig:419` 文件 rename）；新增 `renameTitle` 原子事务（单层持锁：锁内 `Session.load` 最新 → `rename` → `flushLocked`）。主线程既有 `flush()` 调用点自动持锁，无侵入。
**步骤 4**: `config.zig`——`Config` 增 `auto_title: bool = true`，`parseConfigContent` 读 `getBool("auto_title") orelse true`，`DEFAULT_TEMPLATE` 加注释行。
**步骤 5**: `cli/App.zig`——`processLine`（`App.zig:399` runTurn 后）与 `singleTurn`（`App.zig:240`）传 `self.cfg.auto_title` 调 `shouldAutoTitle`；满足则 `subcall_runner.spawn(title_task)`（立即返回）；`pipe_mode` 跳过；`deinit` 前 `waitIdle()`（有限等待）。
**步骤 6**: `web/handler.zig`——`handlePrompt` 在 `runTurn` 返回、`session.flush()`、**`sse_done` 帧写出之后**（`handler.zig:1069` 之后）、函数返回前，传 `ctx.config.auto_title` 调 `shouldAutoTitle`；满足则 `subcall_runner.spawn(title_task)`（复用 `agent.provider_ref` 的 config 副本 + session_id）。
**步骤 7**: 测试——`title.zig` 单测（开关关闭直接 false / shouldAutoTitle 四条件 / cleanTitle think 剥离与 `TITLE_HARD_CAP` 截断 / **keywordTitle 滤 `STOPWORDS` 与 `KEYWORD_MIN..MAX` 上限、全停用词返回 null** / ensureTitle LLM 失败回退链 L1→L2→L3）；`subcall.zig` 单测（spawn 生命周期、waitIdle 返回）；`session.zig` 写锁单测（并发 flush 串行化）；`config.zig` 测试（`auto_title` 默认 true、`auto_title = false` 解析）；**`handler.zig:958` 改用 `title_mod.TITLE_PREFIX_LEN` 后编译 + Web is_new 截断行为不变**；`node tests/frontend/run-tests.mjs` 回归。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs
```

| 测试场景 | 预期结果 |
|----------|----------|
| `auto_title = true`（默认） | 第二轮回合后 spawn 子代理，后台生成 LLM 标题 |
| `auto_title = false` | 不触发、不改名；Web 保持 `prompt[0..30]` 截断，CLI 保持 "New Session" |
| CLI 首回合（`--prompt "恢复上下文"`） | 不触发，标题保持 "New Session"（占位） |
| CLI 第二回合（`--prompt "帮我修 src/app.js 的 500 错误"`） | 回合后提示符**立即返回**（不等待标题），后台生成，`/list` 显示自然语言标题（如 "App.js 500 错误排查"）——覆盖首轮元操作 |
| CLI 第三回合 | 不再触发（消息数 >2），标题保持第二轮生成值 |
| Web 新会话前两条消息 | 首条不命名（保持截断）；第二条后 `sse_done` 即时返回 + spawn 子代理（连接线程不阻塞）→ `loadSessions` 显示 LLM 标题 |
| **Web 第三条消息竞态（关键）** | done 后立即发第三条 → `isSessionStreaming` **不误判**（子代理不碰 abort_map）；第三条消息 flush 与标题写回由 `session_write_mutex` 串行化，**消息不丢失** |
| **写回原子性** | 子代理 `renameTitle` 单层持锁，锁内 load 最新 + rename + flushLocked——并发主线程 flush 不插入、不产生旧快照覆盖；无嵌套死锁 |
| **子代理生命周期** | spawn 的线程完成（含失败/LLM 错误路径）后 arena 释放、计数归零，无泄漏/无悬垂 |
| **进程退出** | CLI `deinit` / Web 退出等待子代理完成（active_threads==0，30s 上限），标题写盘完成才退出 |
| CLI 管道模式（`--prompt "..." \| ...`） | 跳过标题生成，stdout 纯净无污染 |
| 第二轮为元操作（如 "继续"） | 标题基于前两条生成（元操作+首条任务 → 反映任务主题） |
| fork 子会话 | 不触发（有 parent_id，保持 `(fork #N)`） |
| 已重命名会话（非默认标题） | 不触发 |
| title LLM 调用失败 / 空结果 | 回合正常完成，标题走 L2 本地关键词（如 `"src app.js 500 错误"`）；若 L2 空则 L3 静态截断（`TITLE_PREFIX_LEN`）；CLI 不再是 "New Session"，无报错 |
| **常量共享** | `handler.zig:958` 与 L3 `fallbackTitle` 均引用 `TITLE_PREFIX_LEN`——改值一处生效，Web is_new 占位与回退截断不漂移 |
| L2 全停用词消息（如 "嗯 啊 帮我"） | keywordTitle 返回 null → 落 L3 静态截断 |
| title 输出含 `<think>` 块 / 多行 | 剥 think、取首非空行、超 100 截断 |
| 会话重载后标题 | `rename` 不改文件名，id/路径稳定，重载后 header name 为生成标题或回退截断 |
| 空会话（无用户消息） | 无 prompt 可截断 → 保持 "New Session"/UUID 名，不触发 title |

## 涉及文件

| 文件 | 改动 |
|------|------|
| `src/core/title.zig` | 新增：常量（TITLE_MAX_CHARS/HARD_CAP/PREFIX_LEN/KEYWORD_MIN/KEYWORD_MAX/STOPWORDS）+ TITLE_PROMPT / shouldAutoTitle / cleanTitle / keywordTitle（L2）/ fallbackTitle（L3）/ ensureTitle |
| `src/core/subcall.zig` | 新增：SubcallRunner（spawn / active_threads / waitIdle），子代理后台执行基础设施 |
| `src/core/session.zig` | `session_write_mutex`（Io.Mutex）+ `flush`/`writeTo`/`writePrefixTo`/`removeMessage` 双版（公开持锁 + `XxxLocked` 无锁）+ `renameTitle` 原子事务 |
| `src/config.zig` | `Config.auto_title: bool` 字段 + 解析 + DEFAULT_TEMPLATE 注释 |
| `src/frontends/cli/App.zig` | `processLine` + `singleTurn` 回合边界 spawn（传 `cfg.auto_title`）；deinit 前 waitIdle |
| `src/frontends/web/handler.zig` | `handlePrompt` sse_done 后 spawn（传 `ctx.config.auto_title`）；`handler.zig:958` 改用 `title_mod.TITLE_PREFIX_LEN`（常量共享）；server.zig 挂载 runner |
| `src/frontends/web/server.zig` | `SubcallRunner` 实例（进程级）+ 退出等待 |
| `docs/REMAINING.md` | F2 标记实施（发布时） |

## 明确不做

- **small model（`title_model` 配置）**：本期用会话当前模型；小模型节省的 token 在首条消息场景可忽略，后续需要再加
- **按会话/按命令粒度开关**：本期只做全局 `auto_title` 顶层开关；per-session 或 `/title off` 命令粒度后续按需评估
- **结果队列/回调**：本期标题是 fire-and-forget（spawn 不等待、不回调）；F4 分支摘要若需"切回主线即时注入"，runner 增加结果队列或回调（D6 预留）
- **CLI 实时标题刷新**：CLI 无 TUI，标题在 `/list` 可见即可（对齐现有会话管理交互）
- **sub-agent 注册表 / 通用子代理抽象**：只有一个消费者（title），`SubcallRunner` 提供后台执行 + 生命周期，但 title 逻辑仍直接复用 `chatCompletionStreaming`；出现第二个子代理（如 F4 分支摘要）时再评估更重抽象
- **改 Web 空会话 UUID 命名逻辑**：`handleSessionCreate` 空会话仍保持 UUID 名 + 前端显示 "New Session"，由 title 生成后自然替换
- **失败时保持 "New Session"**：已否决——LLM 失败走本地关键词/静态截断（D4 三层），保证任何有内容会话都有有意义标题
- **复杂 NLP 关键词提取**：L2 只用轻量规则（切词 + 固定停用词表 + 前 N 词拼接），不做词性标注/语义排序/多语言形态还原——标题是秒级低价值元数据，规则越简单越稳
- **全项目魔法值清理**：本计划只提取标题相关常量（`TITLE_*`/`KEYWORD_*`/`STOPWORDS`）+ `handler.zig:958` 双端共享；`handler.zig:333/421` 的 `catch 50` 分页默认值等**既有**魔法值不属于标题主题，另行评估

## 备注

- 创建：2026-08-13
- 承接：`SESSION-SYSTEM-OPT`（一期 P1-P5）+ `SESSION-SYSTEM-OPT2`（二期），会话系统主题延续；归入 v0.2.7 周期目录（用户决策）
- REMAINING.md 索引：F2（"无 parentID + 仅 1 条真实用户消息 + 默认标题 → LLM 生成首行"，本计划将其落地——**触发条件修订为"恰 2 条真实用户消息"（第二轮后延迟命名）**）
