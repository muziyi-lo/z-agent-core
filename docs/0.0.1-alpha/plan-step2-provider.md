# Step 2: io/provider.zig — OpenAI 兼容 API

> 详细实施计划。A~G 维度全部覆盖。

## A. 源码依据

| 源文件 | 行号 | 用途 |
|--------|------|------|
| `projects/z-agent/src/provider/openai_compat.zig` | 125-592 | OpenAICompatClient + chatCompletionStreaming + buildJsonBody + SSE 循环 |
| `projects/z-agent/src/provider/openai_compat.zig` | 1-24, 920-1011 | detectVendor + modelSpec + create + tests |
| `projects/z-agent/src/provider/common.zig` | — | `appendEscapedJsonString`、`parseUsage`（JSON 转义需迁移） |
| `zig/zig/lib/std/process.zig` | — | `spawn(io, .{ .argv, .stdin, .stdout, .stderr })` API 确认 |
| `zig/zig/lib/std/Io/File.zig` | — | `readerStreaming` / `writeStreamingAll` API 确认 |
| `zig/zig/lib/std/process/Child.zig` | 134-150 | `child.kill(io)` / `child.wait(io)` — 0.16.0 均需 Io 参数 |
| `.opencode/learnings/LEARNINGS.md` | CURL-001, CURL-002, ZIG-SSE-001, ZIG-WIN-001, ZIG-016-SLEEP, ZIG-016-ENV, LRN-003 | curl 参数格式、--fail-with-body、SSE 非标准响应、Windows kill 守卫、Sleep API 迁移、Environ API 迁移、Writer print 不自动 flush |
| `zig/zig/lib/std/json/static.zig` | 74-84 | `parseFromSlice(T, allocator, s, options) ParseError(Scanner)!Parsed(T)` — 0.16.0 API 确认 |

## B. 模块设计

### B1. 文件职责

```
src/io/
├── provider.zig       # Provider 客户端 + curl 子进程 + SSE 流式解析
└── (common.zig)       # JSON 转义工具（内联到 provider.zig，≤50 行无需独立文件）
```

### B2. 架构简化原则

z-agent 的 `openai_compat.zig` (1012 行) 承担了 TUI 渲染、多 provider 注册表、proxy、content_part 多模态等 V2 功能。V1 CLI 版本做以下削减：

| 减法 | z-agent (不迁移) | z-agent-core V1 (替代) |
|------|-----------------|----------------------|
| TUI 渲染 | `streamfmt` / `MessageRenderer` / `md2ansi` → out_writer 写入彩色流 | `PhaseWriter` 负责相位标签，provider 通过 `pw.writeRaw` / `pw.beginPhase` 控制流式输出。V1 务实: provider import render/cli.zig |
| 多模态消息 | `ContentPart` union (text/tool_call/tool_result/image_url) | `Message.content` 是 `[]const u8`，V1 纯文本 |
| Proxy 支持 | `ProxyConfig` / `-x` / `--noproxy` 参数 | 暂不需要 |
| 推理阶段 | `reasoning_content` / `\x1F` / `\x1E` thinking 标记 | 暂不需要，DeepSeek reasoning 直接丢弃或合并到 content |
| Provider 注册表 | `registry.Provider` vtable + `modelSpec` + `ProviderEntry` 多 provider | V1 单 provider 直调，无需抽象层 |
| 重试分类 | `retry.zig` 错误分类 + `retry.classify()` | 简化为 3 次指数退避，仅 transient 错误重试 |
| Signal/token 取消 | Ctrl+C 中断标志检查 | 复用 `util/signal.zig` |
| 死代码 | `ansi.zig` (imported unused)、`root_dir` (log path only)、`parseUsage` (V2) | 全部删除 |

### B3. Provider 结构体

```zig
/// OpenAI-compatible API client.
pub const Provider = struct {
    config: Config,

    pub const Config = struct {
        base_url: []const u8,            // "https://api.deepseek.com"
        api_key: []const u8,             // from env
        model: []const u8,               // "deepseek-v4-pro"
        max_tokens: u32,                 // 384000
        connect_timeout_secs: u16 = 15,
        max_timeout_secs: u16 = 300,     // DeepSeek reasoning TTFB may exceed 60s
        vendor: Vendor,
        vendor_override: ?Vendor = null, // optional: skip detectVendor (proxy use case)
        reasoning: bool = false,         // enables "thinking" field in request body
    };

    pub const Vendor = enum { deepseek, standard };

    /// Detect vendor from base_url hostname.
    pub fn detectVendor(base_url: []const u8) Vendor;

    /// Initialize provider. Reads api_key from environment, detects vendor.
    /// vendor_override: if set, skips detectVendor.
    pub fn init(allocator: std.mem.Allocator, entry: types.ProviderEntry, model: *const types.Model, vendor_override: ?Vendor, io: std.Io) !Provider;

    /// Execute chat completion with streaming.
    /// arena: caller creates and owns the ArenaAllocator. All returned slices
    ///        (content, tool_calls) live in this arena and are freed by caller's arena.deinit().
    /// phase_writer: opaque PhaseWriter pointer for streaming phase labels (think/output/tool_calls).
    ///              Cast to *render.PhaseWriter internally. V1 pragmatic: provider imports render for type.
    pub fn chatCompletionStreaming(
        self: *Provider,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        messages: []const types.Message,
        tools: ?[]const types.Tool,
        phase_writer: ?*anyopaque,
    ) !Response;
};
```

### B4. 响应类型 (新增到 types.zig)

```zig
/// Returned by Provider.chatCompletionStreaming.
pub const ProviderResponse = struct {
    content: ?[]const u8,          // arena-allocated
    tool_calls: ?[]ToolCall,       // arena-allocated
    finish_reason: FinishReason,
};

/// SSE stream finish reasons.
pub const FinishReason = enum {
    stop,
    tool_calls,
    length,
    content_filter,
    unknown,
};
```

### B5. curl 子进程管道

```
argv:
  curl[.exe] -sN --fail-with-body                // "curl" on POSIX, "curl.exe" on Windows
    --connect-timeout {connect_timeout_secs|15}
    --max-time {max_timeout_secs|300}           // 默认 300s，应对 DeepSeek 推理首 token 延迟
    -X POST {base_url}/chat/completions
    -H "Content-Type: application/json"
    -H "Accept: application/json"
    [-H "Authorization: Bearer {api_key}"]    // only if key non-empty
    -d @-                                      // body via stdin pipe (not temp file)
```

**严格顺序（防止管道死锁）**:
1. `spawn(io, .{ .argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit })`
2. `child.stdin.?.writeStreamingAll(io, json_body)` — 完整写入
3. `child.stdin.?.close(io)` — 发送 EOF，curl 开始处理请求
4. **然后**进入 SSE 读取循环 `sse_reader.takeDelimiter('\n')`

未经步骤 2-3 完成前读 stdout 会导致 stdin/stdout 管道互相阻塞（JSON body > 64KB 管道缓冲区时必死锁）。

**子进程清理 (defer 模板)**:
```zig
var child_finished = false;
defer {
    if (!child_finished) {
        if (builtin.os.tag != .windows) {
            child.kill(io) catch {};   // ZIG-WIN-001: kill on Windows panics if already exited
        }
        _ = child.wait(io) catch {};
    }
}
```
正常路径：读到 `[DONE]` → `child_finished = true` → `_ = child.wait(io)` 确认已退出。
任何错误/中断路径：defer 触发 kill (非 Win) + wait，确保不遗留僵尸进程。

**CURL-001**: `-H "Authorization: Bearer {key}"` 必须完整 HTTP 头格式。
**CURL-002**: `--fail-with-body` 确保 HTTP 4xx/5xx 以非零退出码 + 保留响应体。

### B6. SSE 解析循环

使用 `std.json.Value` + `.ignore_unknown_fields = true` 解析每个 SSE chunk，避免跨 provider 响应格式差异导致 `UnknownField` 错误。Zig 0.16 的 `ignore_unknown_fields` 不向嵌套类型传播，`Value` 方案消除了维护类型化 struct 的成本。

```
while true:
    raw_line = sse_reader.takeDelimiter('\n')
    line = trim(raw_line, "\r")

    if !seen_first_data && !line.startsWith("data: "):
        accumulate into error_buf  // ZIG-SSE-001: non-SSE error response
        continue

    if !line.startsWith("data: "):
        continue  // empty lines, event:, etc.

    seen_first_data = true
    payload = line[6..]
    if payload == "[DONE]": break

    parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), payload,
        .{ .ignore_unknown_fields = true }) orelse continue

    if parsed.object.get("error"): return error.ApiError

    choices = parsed.object.get("choices")?.array.items orelse continue
    if choices.len == 0: continue

    choice = choices[0].object

    if choice.get("finish_reason") as non-null string:
        finish_reason = parseFinishReason(str)

    if choice.get("delta") as non-null object:
        if delta.get("reasoning_content") as non-null string:
            pw.beginPhase(.think)
            pw.writeRaw(r)
            content_buf.appendSlice(r)

        if delta.get("content") as non-null string:
            pw.beginPhase(.output)
            pw.writeRaw(c)
            content_buf.appendSlice(c)

        if delta.get("tool_calls") as array:
            pw.endPhase()
            // ----- Tool call merge state machine -----
            for tool_call in array:
                idx = tool_call.object.get("index").integer
                init buffer slots up to idx
                if id = tool_call.object.get("id") as non-null: assign
                if fn = tool_call.object.get("function") as non-null object:
                    if name = fn.get("name") as non-null: assign
                    if args = fn.get("arguments") as non-null:
                        concatenate to previous arguments fragment
```

### B7. JSON Body 构建

```json
{
  "model": "<model>",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "...", "tool_calls": [...]},
    {"role": "tool", "tool_call_id": "...", "content": "..."}
  ],
  "tools": [{"type": "function", "function": {"name": "...", "description": "...", "parameters": <raw>}}],
  "max_tokens": 384000,
  "stream": true
}                          // V1 不需要 stream_options / include_usage
```

深度差别：DeepSeek 加 `"thinking": {"type": "enabled"}`。

**JSON 转义**: 手动 `appendEscapedJsonString` 避免 `0x80+` UTF-8 字节被误转义为 `\u00XX`（LRN-20260625-024）。

### B8. 错误处理与重试

| 错误 | 行为 | 重试 |
|------|------|------|
| HTTP 4xx/5xx (curl exit ≠ 0) | `error.ApiError` + stderr 输出 response body | 否 |
| SSE payload 含 `"error"` 键 | `error.ApiError` | 否 |
| 非 `data:` 前缀的首批行 | `error.ApiError` + stderr 输出 error_buf | 否 |
| curl spawn/connect 失败 | 原生 `SpawnError` 传播 | 是 |
| TCP 连接超时 (--connect-timeout) | 原生错误传播 | 是 |
| pipe 读取中断/net 断开 | `error.ReadFailed` | 是 |
| Ctrl+C (signal.isInterrupted) | `error.Interrupted` | 否 |

重试策略：最多 3 次，指数退避 `1s / 2s / 4s`。每次重试前向 stderr 输出 `[Retry %d/%d in %ds...]`。Windows 用 `kernel32.Sleep(ms)`（ZIG-016-SLEEP）。仅 `ApiError` 和 `Interrupted` 不重试，其余错误（含原生 spawn/read 错误）均触发重试。

### B9. API Key 读取

`Provider.init()` 从环境变量读取 key，`dupe` 到 Provider 持有：

```zig
var env = std.process.Environ{ .block = .{ .use_global = true } };
var map = try env.createMap(allocator);
defer map.deinit();

const key_raw = map.get(entry.api_key_env) orelse {
    // stderr: "{s} environment variable not set\n"
    return error.ApiKeyNotSet;
};

// key_raw 指向 map 内部内存，map.deinit() 后失效，必须 dupe
const key_owned = try allocator.dupe(u8, key_raw);
self.config.api_key = key_owned;
```

**ZIG-016-ENV**: 用 `Environ.createMap` 替代已移除的 `getEnvMap`。

**所有权**: `api_key` 由 `allocator` 分配，调用方（App.init）确保 allocator（process arena）存活至程序退出。V1 不需要 Provider.deinit()。

**密钥安全**: config.toml 只存变量名 `api_key_env`，不存值。Provider 是唯一读环境变量的模块。

### B10. Windows 适配

| 项目 | 处理 |
|------|------|
| `child.kill(io)` | `if (!child_finished and builtin.os.tag != .windows)` 守卫 (ZIG-WIN-001) |
| `kernel32.Sleep(ms)` | 重试退避用，非 POSIX `nanosleep` |
| SSE `\r\n` | `trimEnd(line, "\r")` 统一处理 |
| curl 可用性 | 假设 PATH 中有 curl，否则 spawn 失败 → `error.CurlNotFound` |

## C. 接口设计

### C1. init

```zig
/// Create Provider from config entry and model.
/// Reads api_key from environment variable entry.api_key_env (dupes with allocator).
/// vendor_override: if non-null, skips detectVendor.
/// Returns error.ApiKeyNotSet if the env var is missing.
pub fn init(allocator: std.mem.Allocator, entry: types.ProviderEntry, model: *const types.Model, vendor_override: ?Vendor, io: std.Io) !Provider;
```

- `entry` 来自 `config.providers[i]`，提供 `base_url` / `api_key_env`
- `model` 来自 `config.resolveModel()`，提供 `id` / `max_tokens` / `reasoning`
- key 一次性读取，存入 `Provider.config.api_key`

### C2. chatCompletionStreaming

```zig
/// Send chat completion request with streaming.
/// arena: caller-owned ArenaAllocator, returned slices live here.
/// tools: optional tool definitions (null = no tools).
/// phase_writer: opaque PhaseWriter pointer — cast to *render.PhaseWriter internally.
pub fn chatCompletionStreaming(
    self: *Provider,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
    phase_writer: ?*anyopaque,
) !ProviderResponse;
```

### C3. 重试封装

```zig
/// Call fn with up to max_retries attempts, exponential backoff.
/// fn is called with a fresh Response buffer each attempt.
fn callWithRetry(
    self: *Provider,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
    pw: *render.PhaseWriter,
) !ProviderResponse;
```

内部调用 `chatCompletionStreamingOnce`（单次执行的实现），分类错误后决定是否重试。

### C4. 依赖方向

```
types.zig   util/signal.zig   ← 基础模块
       ↑
io/provider.zig               ← import types + signal，不 import core/tool/render
```

## D. 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `src/io/provider.zig` | 实现 | Provider + curl 子进程 + SSE + 重试 + JSON 构建 (~500 行) |
| `src/types.zig` | 修改 | 新增 `ProviderResponse` + `FinishReason` enum |

## E. 测试计划

| 测试 | 类型 | 覆盖 |
|------|------|------|
| `provider "detectVendor deepseek"` | 新增 | `detectVendor("https://api.deepseek.com")` → `.deepseek` |
| `provider "detectVendor standard"` | 新增 | `detectVendor("https://api.openai.com")` → `.standard` |
| `provider "buildJsonBody basic"` | 新增 | 2 条消息 → 验证 model/messages/max_tokens/stream 字段存在 |
| `provider "buildJsonBody with tools"` | 新增 | 传入 Tool 数组 → 验证 tools 字段 |
| `provider "buildJsonBody deepseek thinking"` | 新增 | vendor=deepseek → 验证 thinking 字段 |
| `provider "appendEscapedJsonString"` | 新增 | 特殊字符 \n \" \\ → 正确转义，UTF-8 字节不过度转义 |
| `provider "init missing key"` | 新增 | 环境变量不存在 → `error.ApiKeyNotSet` |
| `provider "SSE parse data:DONE"` | 新增 | `data: [DONE]` → 正常退出 |
| `provider "SSE parse content delta"` | 新增 | `data: {"choices":[{"delta":{"content":"hi"}}]}` → PhaseWriter writeRaw |
| `provider "SSE parse tool_call delta"` | 新增 | tool_calls 增量积累 → 最终 ToolCall 数组正确 |
| `provider "SSE non-SSE error response"` | 新增 | 首行非 `data:` → 累积为 error → `error.ApiError` |
| `provider "retry backoff timing"` | 新增 | 确认 1s/2s/4s 延迟逻辑 |

> 注：curl 子进程 + 真实网络调用测试留到 Step 5 端到端验证 (`zig build run -- --prompt "hello"`)。本步骤只测试纯逻辑（JSON 构建 + SSE 解析 + 重试逻辑）。

## F. 失败路径

| 场景 | 行为 |
|------|------|
| API key 环境变量未设置 | `error.ApiKeyNotSet` |
| curl 不在 PATH | spawn 失败 → 原生错误传播 → 重试耗尽后向上抛 |
| curl TCP 连接超时 | 原生错误传播 → 重试 (1s/2s/4s) |
| HTTP 4xx (鉴权/参数错误) | `error.ApiError` + stderr 输出 error_buf → 不重试 |
| HTTP 5xx (服务端错误) | `error.ApiError` → 不重试（V1 简单策略，V2 对 429/502/503 重试） |
| SSE 流中断 | 已接收 token 保留，追加 `[stream interrupted]` |
| SSE payload 解析失败 | `catch continue`（跳过不规范 delta），依赖后续 data: 事件 |
| Ctrl+C 中断 | `error.Interrupted` → kill child (non-Windows) → wait → 返回已累积 partial tokens |
| stdin pipe 写入失败 | 原生错误传播 → 不重试 |

## G. 方案完整性

- [x] G1 字段追实际定义：`ProviderResponse` 已在 types.zig 声明计划，`Provider.Config` 自包含
- [x] G2 调用签名一致：从 z-agent `chatCompletionStreaming:891` 确认参数模式，V1 简化参数
- [x] G3 数据流贯通：messages → buildJsonBody → curl stdin → stdout → SSE parse → phase_writer (PhaseWriter) + ProviderResponse
- [x] G4 现有设施复用：`util/signal.zig` 已有 Ctrl+C 原子标志，`config.zig` 已有 Model.resolve
- [x] G5 交互边界：API key 缺失、curl 不可用、空响应、非 SSE 响应、中断全量覆盖
- [x] G6 接口类型：C 节已声明 `init` / `chatCompletionStreaming` / `detectVendor` 签名
- [x] G7 假设点：`chatCompletionStreaming` 接受 `*ArenaAllocator`（调用者管理生命周期），phase_writer 为 `?*anyopaque`（实际为 `*render.PhaseWriter`，provider import render 获取类型做相位切换）。`vendor_override` 留空时自动检测 vendor

## H. 预估行数

| 文件 | 行数 |
|------|------|
| `src/io/provider.zig` | ~745 (含 ~260 行测试) |
| `src/types.zig` | +12 (ProviderResponse + FinishReason) |
| **合计** | ~757 |
