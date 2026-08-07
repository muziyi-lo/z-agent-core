# Plan WEB-CONCURRENT: Web 并发与连接管理

## 状态: 已完成

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| PLAN-WEB-OPT (14 项) | 已完成 | 无 — 本计划独立实施 |

## 问题

Web 前端 SSE 流式传输已实现（`handlePrompt` 逐 token 推送）。四个可用性缺陷：

1. **单连接阻塞**：`server.zig:67-92` accept 循环是同步的。一个 SSE prompt 请求运行期间（可能数分钟），所有其它连接（health check、session 列表、新 prompt）被阻塞。
2. **无停止机制**：`agent.abort()` 已实现（`agent.zig:100`）且 CLI 通过 Ctrl+C 信号使用，但 Web 前端无 API 端点可触发。
3. **无连接检查**：`PhaseWriterCb.write_raw` 返回 `void`（`provider.zig:12`）。SSE 写入失败（客户端 TCP 断开）时，provider 和 agent loop 不知情，继续向死连接推送 token。
4. **abort 无法中断 LLM API 调用**：`agent.abort()` 仅设置 `_aborted = true`，这个标志只被 agent loop 在 LLM 调用前后检查（`agent.zig:195,271`），从未传入 provider。curl 子进程运行期间，abort 完全无效——需等当前 LLM 调用完整返回后才能生效，可能延迟数十秒。

## 根因

| # | 现象 | 根因 | 位置 |
|---|------|------|------|
| 1 | 单连接阻塞 | accept 循环同步处理请求，未用线程/异步 | `server.zig:67` |
| 2 | 无 abort 端点 | handler 路由表缺 `POST /api/session/:id/abort` | `handler.zig:35-90` |
| 3 | 无连接检查 | `PhaseWriterCb` 四个回调全部返回 `void`，SSE 写入错误被 `catch {}` 静默（7 处：sse.zig:105,108,121,126,138,141,153 为 `catch {}`；sse.zig:174 为 `try` 传播） |
| 4 | abort 不穿透 provider | provider 只检查 `signal.isInterrupted()`（Ctrl+C），不检查 `_aborted`。两套中断机制完全断开。 | `agent.zig:100`（abort 只设 flag）→ `provider.zig:234`（只读 signal，不读 flag） |

## 设计要点

### 1. 单连接阻塞 → 线程模型

**方案**：主线程 accept → spawn 工作线程 → 主线程立即回到 accept。每个工作线程独立持有 buffer、agent、session，处理完即退出。

**为何不clone agent 而是创建独立实例**：`AgentLoop` 持有可变状态（`_aborted`、`session_ref`、`_tool_call_history`、StormBreaker 计数器），多线程共享同一 agent + 互斥锁会引入粒度问题（runTurn 期间持锁 = 等同于串行）。`AgentLoop.init()` 是轻量操作（仅存引用，约 200 字节），每个线程创建独立实例零额外开销。

```zig
// server.zig — 主线程 accept 循环
while (true) {
    if (signal.isInterrupted()) break;
    const stream = tcp_server.accept(io) catch continue;

    const thread = std.Thread.spawn(.{}, handleConnection, .{
        stream,
    }) catch {
        stream.close(io);
        continue;
    };
    thread.detach();
}
```

**工作线程**：独立的 arena、recv/send buffer、agent、handler.Context：

```zig
fn handleConnection(
    parent_alloc: std.mem.Allocator,
    io: std.Io,
    state: *init_mod.FrontendState,
    sessions_dir: []const u8,
    stream: Io.net.Server.Stream,
) void {
    defer stream.close(io);

    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var recv_buf: [4096]u8 = undefined;
    var send_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);

    // 每个线程自己的 agent（共享 provider + registry）
    const model = config_mod.resolveModel(&state.config, state.config.default_model) catch return;
    var agent = agent_mod.AgentLoop.init(a, io, &state.provider, state.registry, &state.session, state.config.max_tool_rounds, state.project_root, model.context_window, .{});

    var ctx = handler.Context{ ... };

    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;
    // ... 路由分发 ...
}
```

**共享状态**：provider（curl 子进程天然并行）、registry（只读）、config（只读）——均无需加锁。

**已分配 session**：`state.session` 是默认 session，只在 `handlePrompt` 中 swap。每个线程处理请求时 `setSession()` 指向自己的 per-request session，处理完恢复默认。无竞争。

**abort_map**：主线程持有 `session_id → *AgentLoop` 映射，用于 abort 端点跨线程通知：

```zig
// server.zig 全局
var abort_map: std.StringHashMap(*agent_mod.AgentLoop) = undefined;
var abort_mutex: std.Io.Mutex = .init;
```

工作线程开始时将 agent 指针注册到 abort_map，结束时移除。

### 2. 无停止机制 → abort 端点

**API**：`POST /api/session/:id/abort`

**handler.zig** 新增路由：

```zig
"POST", "/api/session/" => |rest| {
    if (std.mem.endsWith(u8, rest, "/abort")) {
        const sid = rest[0 .. rest.len - "/abort".len];
        return handleAbort(ctx, request, sid);
    }
},
```

**实现**：在 mutex 锁内查找并调用 abort（详见 §6 竞态分析）：

```zig
fn handleAbort(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8) !void {
    ctx.abort_mutex.lock(ctx.io);
    defer ctx.abort_mutex.unlock(ctx.io);

    const agent_ptr = ctx.abort_map.get(session_id) orelse
        return err_mod.respondError(request, .not_found, "no active prompt for this session", ctx.allocator);

    agent_ptr.abort();  // 锁内调用，worker 无法同时 remove + deinit
    try respondJson(request, "{\"status\":\"aborted\"}");
}
```

**前端**：发送 prompt 时可选存储当前 fetch 的 AbortController，abort 按钮调用 `POST /api/session/:id/abort` + `fetch.abort()`。

**`_aborted` 跨线程原子性（必须）**：`_aborted: bool` 被一个线程写入（abort 端点）另一个线程读取（agent loop 的 `runTurn`）。非原子读写在不同架构和编译器优化下有不同行为：

| 架构 | 编译器可能行为 | 结果 |
|------|---------------|------|
| x86 | TSO 保证 store 可见，但编译器可能将循环 `while(!_aborted)` 的 load 提升到循环外 | 寄存器缓存 → `while(true)` → **永远读不到** |
| ARM | 弱内存模型，无 barrier 时 store 可能无限延迟可见 | **可能永远读不到** |
| 所有 | Zig 中跨线程无同步的数据竞争 = **未定义行为** | 程序 ill-formed |

**修复**：字段改为 `std.atomic.Value(bool)`（代码库已在 `signal.zig:4` 使用此类型）。类型级安全——不能意外非原子访问。

```zig
// agent.zig:92 — 字段类型变更
_aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

// agent.zig:100 — abort() 写入端
pub fn abort(self: *AgentLoop) void {
    self._aborted.store(true, .release);  // release: 确保之前写入对读取线程可见
    signal.setInterrupted();
}

// agent.zig:195,271 — runTurn 读取端
if (self._aborted.load(.acquire)) {  // acquire: 匹配 release，建立 happens-before
    return finishTurn(self, new_msgs, .interrupted, null);
}

// agent.zig:142 — finishTurn 重置
self._aborted.store(false, .release);
```

`.release`/`.acquire` 配对不仅保证可见性，还建立 happens-before 关系。与 `signal.zig` 的原子操作风格一致（`.acquire` 读、`.release` 写）。`.seq_cst` 同样可用且更省心，但代码库已有 `.acquire`/`.release` 先例，保持一致。

### 3. 连接检查 → SSE 错误传播

**现状**：SSE 回调 `write_frame`/`writeTextDelta` 写入失败时 `catch {}`，provider 和 agent loop 继续运行。

**方案**：SseState 写入失败时直接调用 `agent.abort()`，触发 agent loop 在下次检查点（`agent.zig:195` / `agent.zig:271`）优雅退出。

```zig
// sse.zig — SseState 新增字段
pub const SseState = struct {
    w: SseWriter,
    io: std.Io,
    agent: ?*agent_mod.AgentLoop = null,  // ← 新增
    // ... 其余字段不变
};

// 所有 write 错误处改为：
fn beginPhase(ctx: ?*anyopaque, mtype: PhaseType) void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    // ...
    s.writeFrame("thinking_start", "{}") catch {
        if (s.agent) |ag| ag.abort();
    };
}
```

`handlePrompt` 创建 SSE state 后注入 agent 指针：

```zig
var sse_state = sse.SseState{
    .w = sw.*,
    .io = ctx.io,
    .agent = &agent,  // ← 每个请求的 agent 实例
};
```

**为何不改 `PhaseWriterCb` 签名**：`write_raw` 返回 `void` 是核心层的接口契约，CLI 也依赖此签名（CLI write 到终端不会失败，无需错误处理）。改签名需同时改 CLI/proxy/所有调用方，波及面大。SSE 写入错误时直接触发 abort 是最小改动。

### 4. abort 穿透 → 中断 curl 子进程

**现状**：`agent.abort()` 只设置 `_aborted: bool = true`（`agent.zig:100`）。agent loop 在 LLM 调用前后检查此标志（`agent.zig:195,271`），但 provider 内部从不检查。存在两套独立的中断机制：

| 机制 | 设置 | 检查 | 能否杀 curl |
|------|------|------|-------------|
| `_aborted` (agent) | `agent.abort()` | agent loop 前后 | **否** — provider 不感知 |
| `signal.isInterrupted()` (系统) | Ctrl+C 信号处理器 | provider SSE 循环 (`provider.zig:234`) | 是 (`child.kill()`) |

**时序**（当前 abort 的延迟）：

```
agent.abort() → _aborted = true
  ...
  agent loop: 检查 _aborted ❌（已过 LLM 调用入口）
  → chatCompletionStreaming()          ← 阻塞中，curl 仍在运行
     → provider SSE 循环                ← 只检查 signal.isInterrupted()
     → curl 继续下载 token（可能数十秒）
  → 返回
  agent loop: 检查 _aborted ✅（终于生效）
```

**方案**：`agent.abort()` 顺便调用 `signal.setInterrupted()`，桥接两套机制。provider SSE 循环在下一个迭代（毫秒级）检测到中断，执行 `child.kill()` + `child.wait()`，返回 `error.Interrupted`。

```zig
// agent.zig:100 — 修改前
pub fn abort(self: *AgentLoop) void {
    self._aborted = true;
}

// agent.zig:100 — 修改后
pub fn abort(self: *AgentLoop) void {
    self._aborted = true;
    signal.setInterrupted();    // ← 桥接：触发 provider SSE 循环的中断检查
}
```

**完整中断链路**（abort → curl kill < 1 秒）：

```
POST /api/session/:id/abort
  → handleAbort()
    → agent.abort()
      → _aborted = true
      → signal.setInterrupted()              ← 关键：设置全局中断标志
    → 返回 HTTP 200

curl 子进程（provider SSE 循环）:
  while (true) {
      → signal.isInterrupted()                ← 下一个迭代检测到
      → child.kill(io)                        ← 终止 curl 进程
      → child.wait(io)
      → return error.Interrupted              ← 向上传播
  }

agent loop:
  → catch error.Interrupted
  → finishTurn(.interrupted)                  ← agent.zig:141 重置 _aborted
  → 返回 RoundResult{ .finish = .interrupted }
```

**abort 后的状态恢复**：`finishTurn()`（`agent.zig:140-143`）在 `finish == .interrupted` 时重置 `_aborted`。但 `signal.isInterrupted()` 是全局标志，不会自动复位。需在 agent loop 收到 `.interrupted` 后清除——`signal.zig` 已有 `reset()` 函数：

```zig
// agent.zig:249-252 — 新增 signal 清除
error.Interrupted => {
    signal.reset();                              // ← 复用已有函数，重置全局中断标志
    return finishTurn(self, new_msgs, .interrupted, err_name);
},
```

**Windows `child.kill()` 守卫**：provider.zig 两处 `child.kill(io)` 被 `builtin.os.tag != .windows` 守卫跳过（`provider.zig:202,235`），意味着即使中断触发，Windows 上也只会 `wait()` 不 `kill()`。`std.process.Child.kill()` 在 Windows 上调用 `TerminateProcess`，功能正常。去掉守卫使 Windows 也能强制终止 curl。

```zig
// provider.zig:199-207 — 删除 Windows 守卫
defer {
    if (!child_finished) {
        child.kill(io) catch {};     // ← 之前: if (builtin.os.tag != .windows)
        _ = child.wait(io) catch {};
    }
}

// provider.zig:234-241 — 删除 Windows 守卫
if (signal.isInterrupted()) {
    child.kill(io) catch {};         // ← 之前: if (builtin.os.tag != .windows)
    _ = child.wait(io) catch {};
    child_finished = true;
    return error.Interrupted;
}
```

### 5. 主线程退出安全 → use-after-free 防护

**问题**：工作线程持有以下指向 `FrontendState` 的引用，一旦 `state.deinit()` 运行即悬垂：

| 工作线程持有的引用 | 类型 | `state.deinit()` 行为 | UAF 风险 |
|---|---|---|---|
| `&state.provider` → `config.base_url` | 切片指向 `config._arena` | `config.deinit()` → `_arena.deinit()` 释放 | **是** |
| `&state.provider` → `config.model` | 切片指向 `config._arena` | 同上 | **是** |
| `&state.provider` → `config.model_params` | 切片指向 `config._arena` | 同上 | **是** |
| `state.project_root` | 切片指向 `allocator` 分配的内存 | `allocator.free(project_root)` | **是** |
| `&state.session` → `_arena` | arena 内部所有数据 | `session.deinit()` → `_arena.deinit()` | **是** |
| `state.registry` | 值拷贝（comptime 静态数据） | 不释放 | 否 |
| `state.config.max_tool_rounds` | 值拷贝（u32） | 不释放 | 否 |

上述 UAF 引用在 `agent.runTurn()` 的以下位置被解引用：
- `project_root`：构建 ToolContext（`agent.zig:292`）、system prompt（`:380`）、读取 AGENTS.md（`:398`）、发现 skills 目录（`:414`）
- `provider.base_url/model`：每次 LLM 调用构造 curl URL
- `session._messages`：每轮 LLM 响应后 append assistant/tool 消息

**方案**：两步保证

**5a. 工作线程复制关键数据**：`handleConnection` 在进入请求处理前，将可能被主线程释放的字符串复制到自己的 arena 中，断开对 `FrontendState` 的依赖：

```zig
fn handleConnection(
    parent_alloc: std.mem.Allocator,
    io: std.Io,
    state: *init_mod.FrontendState,
    sessions_dir: []const u8,
    stream: Io.net.Server.Stream,
) void {
    defer threadFinished();               // (4) 最后：原子计数器递减
    defer stream.close(io);               // (3) 关闭连接

    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();                 // (2) 释放 arena
    const a = arena.allocator();

    // 复制所有可能被 state.deinit() 释放的字符串
    const project_root = a.dupe(u8, state.project_root) catch return;
    const base_url = a.dupe(u8, state.provider.config.base_url) catch return;
    const model = a.dupe(u8, state.provider.config.model) catch return;
    const api_key = a.dupe(u8, state.provider.config.api_key) catch return;
    const model_params: ?[]const u8 = if (state.provider.config.model_params) |mp|
        a.dupe(u8, mp) catch return
    else
        null;

    // 构建独立的 provider（仅 config 字符串独立，其余复用）
    var provider = state.provider;
    provider.config.base_url = base_url;
    provider.config.model = model;
    provider.config.api_key = api_key;
    provider.config.model_params = model_params;

    // 独立的 agent 实例（指向 worker 本地 provider + session）
    const model_info = config_mod.resolveModel(&state.config, state.config.default_model) catch return;
    var agent = agent_mod.AgentLoop.init(a, io,
        &provider,
        state.registry,
        &state.session,   // ← 仍指向 state.session，见 5b
        state.config.max_tool_rounds,
        project_root,
        model_info.context_window,
        .{},
    );

    // (1) 兜底清理 + 设置 Context → handleRequest
    // ... 后续请求处理全部使用本地 arena 中的字符串 ...
}
```

**5b. 主线程等待所有工作线程退出后再 deinit**：`state.session` 的 `_arena` 无法在 worker 中复制（session 是可变状态、runTurn 期间会 append 消息）。保留此引用，但通过原子计数器确保主线程在 deinit 前等待所有 worker 完成：

```zig
// server.zig — 主线程
var active_threads: u32 = 0;

fn threadStarted() void {
    _ = @atomicRmw(u32, &active_threads, .Add, 1, .seq_cst);
}
fn threadFinished() void {
    _ = @atomicRmw(u32, &active_threads, .Sub, 1, .seq_cst);
}

pub fn main(process: std.process.Init) !void {
    // ... 初始化 state ...
    defer {
        // 等待所有工作线程退出
        while (@atomicLoad(u32, &active_threads, .seq_cst) > 0) {
            kernel32.Sleep(50);  // 50ms 轮询
        }
        state.deinit();
    }
    defer gpa_alloc.deinit();

    while (true) {
        if (signal.isInterrupted()) break;
        const stream = tcp_server.accept(io) catch continue;

        threadStarted();
    const thread = std.Thread.spawn(.{}, handleConnection, .{
        gpa, io, &state, sessions_dir, stream,
    }) catch {
            threadFinished();
            stream.close(io);
            continue;
        };
        thread.detach();
    }
    // 退出时：defer 块等待 active_threads → 0 → state.deinit()
}
```

**退出时序**（Ctrl+C）：

```
1. 用户按 Ctrl+C
2. signal.setInterrupted() → isInterrupted() = true
3. 主线程 accept 循环检测到 → break
4a. 活跃 worker 若在 SSE 循环迭代中 → 检测到 isInterrupted() → child.kill() → error.Interrupted
4b. 活跃 worker 若阻塞在 child.stdout.read() → 无法检测（见风险表）→ 等 curl 超时或 read 返回
5. 大部分 worker 在 <100ms 内退出 → threadFinished()
6. 阻塞 worker 最多等 30s（main 超时）→ 主线程 break 等待 → state.deinit() → 退出
7. OS 回收仍阻塞的 worker 栈/arena、curl 子进程
```

**`state.session` 引用的边界说明**：worker 持有 `&state.session` 指针，但在 `handlePrompt` 中会用 `agent.setSession()` swap 到 per-request session（堆分配），runTurn 期间不操作 `state.session`。仅当 worker 处理非-prompt 请求（如 session list、health check）且这些请求在 Ctrl+C 期间正在运行时，才可能短暂访问 `state.session._arena`。此窗口极短（非流式请求在毫秒级内完成），且主线程在 deinit 前已等待所有 worker 退出。

### 6. abort_map 清理与 arena 释放顺序

**问题 1：注册点不明确**。当前设计步骤 8（handlePrompt）和步骤 9（handleConnection）都操作 abort_map。但 `handleConnection` 是通用连接入口，session_id 仅在 URL 解析后（handlePrompt 内）已知。注册和清理应在 handlePrompt 中完成。

**问题 2：abort 调用竞态**。当前 `handleAbort` 设计在 mutex 外调用 `agent.abort()`：

```zig
// 当前设计（❌ 有竞态）
fn handleAbort(...) !void {
    ctx.abort_mutex.lock(ctx.io);
    const agent_ptr = ctx.abort_map.get(session_id) orelse { ... };
    ctx.abort_mutex.unlock(ctx.io);
    agent_ptr.abort();  // ← worker 可能在这之前释放了 arena + 栈帧
}
```

竞态时序：

```
T_a (abort 线程)              T_w (worker 线程)
─────────────────────        ─────────────────────
lock mutex
agent = map.get("X")        
unlock mutex
                              lock mutex
                              map.remove("X")
                              unlock mutex
                              arena.deinit()  ← 释放 agent 的 provider 字符串
                              函数返回          ← agent 栈帧消失
agent.abort()               
  → _aborted = true          ← UAF: agent 内存已被释放/复用
```

**修复**：在锁内调用 `agent.abort()`，确保 agent 指针在调用期间不被释放：

```zig
// 修复后（✅ 安全）
fn handleAbort(...) !void {
    ctx.abort_mutex.lock(ctx.io);
    defer ctx.abort_mutex.unlock(ctx.io);

    const agent_ptr = ctx.abort_map.get(session_id) orelse
        return err_mod.respondError(request, .not_found, "...", ctx.allocator);

    agent_ptr.abort();  // ← 锁内调用，worker 无法同时 remove + deinit
    try respondJson(request, "{\"status\":\"aborted\"}");
}
```

时序（修复后）：

```
T_a (abort 线程)              T_w (worker 线程)
─────────────────────        ─────────────────────
lock mutex
agent = map.get("X")        
agent.abort()                （阻塞在 lock mutex）
unlock mutex
                              lock mutex
                              map.remove("X")     ← 但 agent 已 abort，安全
                              unlock mutex
                              arena.deinit()        ← 合法释放
                              函数返回
```

**问题 3：清理顺序依赖 defer LIFO**。`handleConnection` 的结构保证了正确顺序：

```zig
fn handleConnection(...) void {
    defer stream.close(io);          // (3) 最后：关闭连接

    var arena = arena.init(...);
    defer arena.deinit();            // (2) 其次：释放 arena

    // ... dupe strings, create agent ...

    handler.handleRequest(&ctx, ...) // → handlePrompt
    //   handlePrompt 内部:
    //     register abort_map          ← 注册
    //     agent.runTurn(...)
    //     remove abort_map            ← 清理 (1) 先于 arena.deinit()
    
    // defer arena.deinit() 在此运行 ← 此时 abort_map 已无此 entry
    // defer stream.close(io) 在此运行
}
```

关键不变量：**abort_map 清理永远在 arena.deinit() 之前完成**。这由 handlePrompt（调用栈上层）在返回前执行清理，而 arena.deinit 由 handleConnection 的 defer 延迟到返回时执行来保证。

**问题 4：panic 路径上 abort_map 泄漏**。当前清理在 `handlePrompt` 的 error 路径 `defer` 块中执行。但如果 `handlePrompt` 发生 panic（非 error return，如 OOB 索引、unreachable），abort_map 条目不会清理 → 指针在 `arena.deinit()` 后悬垂 → 任何后续 abort_map 遍历（如退出扫描、新请求误查）读到死指针。

**修复**：在 `handleConnection` 加兜底 defer——注册在所有 defer 之前（最后执行），确保即使 `handlePrompt` panic，abort_map 也会在 arena 释放前清理：

```zig
fn handleConnection(...) void {
    defer stream.close(io);              // (4) 最后：关闭连接

    var arena = arena.init(...);
    defer arena.deinit();                // (3) 其次：释放 arena

    // (1) 兜底清理 — 注册最早，执行最晚，在 arena.deinit 之前
    // 如果 handlePrompt 正常清理了（ctx.current_abort_session = null），此 defer 是 no-op
    defer {
        ctx.abort_mutex.lock(ctx.io);
        defer ctx.abort_mutex.unlock(ctx.io);
        if (ctx.current_abort_session) |sid| {
            _ = ctx.abort_map.remove(sid);
            ctx.current_abort_session = null;
        }
    }

    // ... dupe strings, create agent, set ctx ...

    // (2) handleRequest → handlePrompt
    //   handlePrompt 内部:
    //     ctx.current_abort_session = session_id;
    //     register abort_map                           ← 注册
    //     defer { remove abort_map; ctx.current_abort_session = null; }  ← 正常路径清理
    //     agent.runTurn(...)
    //     → 返回时 defer 清理 → ctx.current_abort_session = null
    
    // 兜底 defer 执行:
    //   如果 ctx.current_abort_session != null → abort_map 泄漏 → 从 map 移除
    //   如果 ctx.current_abort_session == null → handlePrompt 已清理 → no-op

    // defer arena.deinit() 执行 ← 此时 abort_map 已确定无此 entry
    // defer stream.close(io) 执行
}
```

**defer 执行顺序（LIFO）**：

| 注册顺序 | defer 内容 | 执行时机 |
|----------|-----------|----------|
| 1（最早注册） | abort_map 兜底清理 | **最后执行**（4th） → 在 arena.deinit 之前 |
| 2 | `arena.deinit()` | 第 3 个 |
| 3 | 处理请求（handlePrompt 的 defer 等） | 按调用栈自然返回 |
| 4（最晚注册） | `stream.close(io)` | **最先执行**（1st）|

**`ctx.current_abort_session`**：新增字段，handlePrompt 设置、兜底 defer 读取。正常路径上 handlePrompt 的 defer 置 null → 兜底 defer 跳过。panic 路径上仍为 session_id → 兜底 defer 执行 remove。

### 7. 全局中断的 session 误杀

**现状**：`abort()` 调用 `signal.setInterrupted()`（步骤 10），但 `signal.isInterrupted()` 是进程级全局标志。abort 一个 session 时，所有活跃 session 的 provider SSE 循环都会检测到中断 → 误杀未请求 abort 的 curl。

**时序**：

```
T_a (session X 被 abort)              T_b (session Y 运行中，未被请求 abort)
──────────────────────                ──────────────────────────
agent_X.abort()
  _aborted_X.store(true, .release)
  signal.setInterrupted()             
                                       // SSE 循环下一轮
                                       signal.isInterrupted() → true ← 误命中
                                       child.kill()           ← curl_Y 被误杀
                                       return error.Interrupted
agent_X provider:
  signal.isInterrupted() → true
  child.kill()           ← curl_X 被正常终止
  error.Interrupted → signal.reset()   ← 全局标志复位
```

**误杀窗口**：`setInterrupted()` 到 `signal.reset()` 之间，约 100ms（一次 SSE 网络往返 + 错误传播）。T_b 只有恰好在此窗口内检测才被命中。

**影响**：session Y 返回 `finish = .interrupted`，前端显示中断。session 消息已 flush 到磁盘，数据不丢。用户重试即可恢复。

**接受理由**（当前阶段不修）：
- 单用户 dev 工具 — 同时有 2+ 活跃 prompt 的概率低
- 窗口窄（~100ms）— 误杀概率极低
- 数据安全 — session 已 flush，无损
- 重试成本低 — 重新发送一次 prompt

**如果需要修**（未来多用户场景）：不改全局标志，改为 provider 接收 `?*const fn () bool` 回调，避免全局信号通道：

```zig
// provider.zig — chatCompletionStreaming 新增参数
pub fn chatCompletionStreaming(
    self: *Provider,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
    phase_writer: ?PhaseWriterCb,
    should_abort: ?*const fn () bool,   // ← 新增：per-agent 中断检查
) !ChatResponse { ... }

// provider SSE 循环中：
while (true) {
    const global_abort = signal.isInterrupted();
    const local_abort = if (should_abort) |check| check() else false;
    if (global_abort or local_abort) {
        child.kill(io) catch {};
        _ = child.wait(io) catch {};
        child_finished = true;
        return error.Interrupted;
    }
    // ...
}
```

agent loop 传入检查自身 `_aborted` 的闭包：
```zig
const check_abort = struct {
    fn should_abort() bool {
        return agent._aborted.load(.acquire);
    }
}.should_abort;

const result = provider.chatCompletionStreaming(..., &check_abort);
```

不修改 `PhaseWriterCb` 签名。每个 session 独立判断，`signal.isInterrupted()` 仅处理全局 Ctrl+C。此方案列为"不做"，但完整设计已在此记录，未来多用户场景可直接实施。

## 实施

| 步骤 | 文件 | 内容 |
|------|------|------|
| 1 | `server.zig` | 主循环改为 `accept → std.Thread.spawn`；抽取 `handleConnection` 工作线程函数；初始化 abort_map + mutex；新增 `active_threads` 原子计数器 + `threadStarted/threadFinished`；主线程 defer 块等待计数器归零（最大 30s 超时）后 deinit |
| 2 | `server.zig` handleConnection | 在函数入口用 worker arena dupe `project_root`、provider config 字符串（base_url/model/api_key/model_params），构建独立 provider；其余值类型（registry/max_tool_rounds）直接拷贝 |
| 3 | `handler.zig` Context | 新增 `abort_map: *std.StringHashMap(*agent_mod.AgentLoop)` + `abort_mutex: *std.Io.Mutex` + `current_abort_session: ?[]const u8`（兜底清理用） |
| 4 | `handler.zig` 路由 | 新增 `POST /api/session/:id/abort` → `handleAbort` |
| 5 | `handler.zig` handleAbort | 在 mutex 锁内查找 agent + 调用 `abort()`，确保 worker 不会在 abort 调用期间释放 arena |
| 6 | `sse.zig` SseState | 新增 `agent: ?*agent_mod.AgentLoop` 字段 |
| 7 | `sse.zig` callbacks | 所有 SSE write 失败处 `catch { if (s.agent) \|ag\| ag.abort(); }`（6 处 `catch {}` + 1 处 `try` → 统一改为 `agent.abort()`） |
| 8 | `handler.zig` handlePrompt | 创建 SseState 时传入 `agent` 指针；runTurn 前在 mutex 内注册 abort_map + 设置 `ctx.current_abort_session`；正常路径 defer 清理 abort_map + 置 null |
| 9 | `server.zig` handleConnection | 注册最早的 defer：兜底清理 abort_map（检查 `ctx.current_abort_session`，非 null 则 remove）— 在 `arena.deinit()` 之前执行 |
| 10 | `agent.zig` | `_aborted` 从 `bool` 改为 `std.atomic.Value(bool)`；`abort()` 用 `.store(true, .release)` 替代 plain store + 新增 `signal.setInterrupted()`；`runTurn` 两处检查用 `.load(.acquire)`；`finishTurn` 重置用 `.store(false, .release)`；`error.Interrupted` 分支新增 `signal.reset()`（复用已有函数清除全局中断标志） |
| 11 | `io/provider.zig` | 删除两处 `child.kill()` 的 Windows 守卫（`provider.zig:202,235`），使 Windows 也能强制终止 curl |

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `server.zig` | ~70 行新增（线程 spawn + handleConnection + arena dupe + 原子计数器 + 兜底 defer）+ ~20 行调整主循环 + defer 等待逻辑 | 否 |
| `handler.zig` | Context 新增 3 字段（abort_map + abort_mutex + current_abort_session）；路由新增 abort 端点；handlePrompt 注册/清理 abort_map 逻辑；handleAbort 新增 | 否 |
| `sse.zig` | SseState 新增 1 字段；6 处 `catch {}` + 1 处 `try` 改为 `catch { agent.abort() }` | 否 |
| `core/agent.zig` | `_aborted: bool` → `std.atomic.Value(bool)`；4 处读写改为 `.store`/`.load`；`abort()` 新增 `signal.setInterrupted()`；`error.Interrupted` 分支新增 `signal.reset()` | 否 — 行为增强 |
| `io/provider.zig` | 删除两处 `child.kill()` 的 `builtin.os.tag != .windows` 守卫（4 行删除） | 否 — Windows 行为增强 |

## 验证

```powershell
zig build
zig build run -- --web
```

| 测试场景 | 预期 |
|----------|------|
| 两个浏览器标签同时发送 prompt | 两个请求并行流式返回，互不阻塞 |
| 长 prompt 运行期间访问 `/api/health` | 立即返回 `{"status":"ok"}`（不被阻塞） |
| 长 prompt 运行期间访问 `/api/session` | 立即返回 session 列表 |
| 长 prompt 运行期间 `POST /api/session/:id/abort` | SSE 流在 ~1 秒内终止（curl 被 kill），返回 `done` 事件 + `interrupted` 状态 |
| abort 后立即发新 prompt | 新 prompt 正常流式返回（abort 状态已清除） |
| 浏览器关闭标签（TCP 断开） | SSE write 失败 → 触发 agent.abort() → curl kill → agent loop 退出 |
| 无活跃 prompt 的 session 调用 abort | 返回 404 `{"error":{"code":"not_found","message":"no active prompt for this session"}}` |

## 不做

- 不引入线程池/异步 I/O 框架 — `std.Thread.spawn` + detach 满足 dev 工具场景
- 不修改 `PhaseWriterCb` 接口签名 — 保持核心层稳定
- 不修改 CLI 前端 — 本计划仅限 Web 前端（`signal.setInterrupted()` 在 CLI 中已是标准行为，不受影响）
- 不加 session 并发限制 — 单用户 dev 工具，信任用户
- 不在 provider 中注入 `_aborted` 检查 — 复用已有 `signal.isInterrupted()` 机制，仅需桥接
- 不原地修改 `FrontendState.deinit()` — 通过 defer 等待 + worker arena dupe 保证安全

## 风险

| 风险 | 概率 | 缓解 |
|------|------|------|
| worker arena 字符串 dupe 遗漏 | 低 | 仅 provider config 的 4 个字符串 + project_root 需要 dupe。`handleConnection` 入口集中处理，代码审查一目了然 |
| handlePrompt panic 导致 abort_map 泄漏 | 中 | 兜底 defer（handleConnection 最外层）检查 `ctx.current_abort_session`，非 null 则 remove。即使 handlePrompt 正常路径和 error defer 路径都跳过（panic），兜底 defer 仍会执行 |
| `signal.isInterrupted()` 全局标志被多个线程共享 | 中 | abort 调用 `setInterrupted()` 后，所有活跃 agent 线程在 provider SSE 循环中检测到中断 → 可能误杀未请求 abort 的 session。详见 §7 "全局中断的 session 误杀" |
| worker 线程在 `handleConnection` 入口（arena 分配阶段）被 Ctrl+C 中断 | 极低 | `handleConnection` 入口在 `threadStarted()` 之后，`state.deinit()` 在 `active_threads > 0` 之前不会触发。入口阶段的 arena 分配是纯内存操作（毫秒级），不会被 defer 等待跳过。 |
| 大量并发连接耗尽内存 | 低 | 每个线程 ~8KB buffer + agent 栈 + arena，100 线程 ≈ 1MB。接受 dev 工具假设 |
| provider（curl 子进程）线程安全 | 无 | `Provider` 只有 Config 字段（只读），`chatCompletionStreaming` 每次 spawn 独立 curl 进程，无共享状态 |
| Ctrl+C 后 worker 阻塞在 `child.stdout.read()` 无法检测 `isInterrupted()` | 中 — curl 超时设为 300s 时，主线程可能等 300s | 见下方"主线程退出超时兜底" |
| Windows 去掉 `child.kill()` 守卫后 `TerminateProcess` 行为异常 | 低 | `TerminateProcess` 是标准 Win32 API，curl 是无 GUI 的控制台程序，强制终止安全。若出现问题可加回守卫但改为 `kernel32.GenerateConsoleCtrlEvent` 发送 Ctrl+C 给 curl |

### 主线程退出超时兜底

`isInterrupted()` 检查在 SSE 循环顶部（`provider.zig:234`），但 `child.stdout.read()` 是阻塞调用——读不返回就不会迭代检查。直连 API 且网络稳定时延迟 <100ms，但海外 API 或 slow response 场景下可能等完整 curl timeout（默认 300s）。**必须加主线程 defer 超时兜底**。

```zig
// server.zig — 替换简单的 while 轮询
defer {
    const deadline_ms = Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(io, .monotonic).raw) + 30_000;
    while (@atomicLoad(u32, &active_threads, .seq_cst) > 0) {
        if (Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(io, .monotonic).raw) > deadline_ms) {
            printStderr(io, "z-agent-core: shutdown timeout, forcing exit\n");
            break;
        }
        kernel32.Sleep(100);
    }
    state.deinit();
}
```

**超时选择 30s**：curl 的 `--max-time`（API 超时）默认 300s，但 `child.kill()` 触发后 stdout pipe 破裂→read 立即返回→通常 <5s。30s 覆盖网络抖动 + 异常慢的 API 响应。超时后主线程直接 `state.deinit()` + 退出（OS 回收 worker 栈/arena 内存，curl 子进程被 OS 清理）。
| Windows 去掉 `child.kill()` 守卫后 `TerminateProcess` 行为异常 | 低 | `TerminateProcess` 是标准 Win32 API，curl 是无 GUI 的控制台程序，强制终止安全。若出现问题可加回守卫但改为 `kernel32.GenerateConsoleCtrlEvent` 发送 Ctrl+C 给 curl |
