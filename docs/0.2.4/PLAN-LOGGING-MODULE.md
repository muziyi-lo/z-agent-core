# Plan LOGGING-MODULE: 服务器日志模块

## 状态: 已完成

## 问题

当前所有诊断都通过 `var buf: [256]u8; Io.File.Writer.init(.stderr())` 碎片化输出——无时间戳、无级别、无统一格式。多线程下无法追踪时序。

## 概览

- **改动文件**：1 新增 + 所有 consumer 文件（逐步替换）
- **方案思路**：新增 `src/util/log.zig` 作为统一日志基础设施，分层调用

## 设计要点

### 四层架构

```
层 4: DEBUG / TRACE — 变量值、数据包 dump、帧内容
层 3: 业务级 — 会话创建/加载/flush、SSE 流开始/结束、LLM 调用成功/失败
层 2: 请求级 — HTTP 请求入口/出口、状态码、耗时
层 1: 基础设施 — 线程 spawn/exit、内存分配失败、文件 I/O 错误
```

### 输出格式

```
[HH:MM:SS.mmm] [LEVEL] [TID:N] ctx:<id> event=<name> [key=value ...]
```

- `HH:MM:SS.mmm` — 精确到毫秒
- `LEVEL` — 5 种，带 ANSI 颜色：`ERROR`(红) `WARN`(黄) `INFO`(绿) `DEBUG`(青) `TRACE`(灰)
- `TID:N` — 线程序号（主线程=N，worker 递增）
- `ctx:<id>` — 请求标识，`request_id` 或 `session_id`
- `event=<name>` — 固定事件名，便于 grep：`session_flush`、`sse_stream_start`、`llm_error`
- `key=value` — 自由追加字段：`msgs=10`、`latency=2ms`、`err=FileNotFound`

**示例**：

```
[12:00:01.123] [ INFO] [TID:0] ctx:r1 event=server_start port=8090
[12:00:03.456] [ INFO] [TID:1] ctx:r2 event=request_req method=GET path=/api/session
[12:00:03.457] [ INFO] [TID:1] ctx:r2 event=session_list dir=... files=3
[12:00:05.100] [DEBUG] [TID:2] ctx:a1b2c3 event=sse_stream_start
[12:00:05.101] [TRACE] [TID:2] ctx:a1b2c3 event=sse_frame event=thinking_start len=21
[12:00:20.500] [ INFO] [TID:2] ctx:a1b2c3 event=sse_done msgs=3 latency=15.4s
[12:00:20.501] [ERROR] [TID:2] ctx:a1b2c3 event=llm_error err=RateLimitExceeded
```

### API

```zig
const log = @import("util/log.zig");

// 基础设施层 — 无 ctx
log.info("event=server_start port={d}", .{port});
log.error("event=bind_failed err={s}", .{@errorName(err)});

// 请求级 — 含 ctx
log.req_info(tid, rid, "GET /api/session", "");
log.req_warn(tid, rid, "session_list", "err={s}", .{@errorName(err)});
log.req_done(tid, rid, "latency={d}ms status={d}", .{elapsed_ms, status});

// 业务级
log.biz_info(tid, rid, "session_flush", "msgs={d}", .{count});
log.biz_error(tid, rid, "llm_error", "err={s}", .{@errorName(err)});

// 调试级 — 仅 DEBUG/TRACE 下输出
log.dbg(tid, rid, "done_payload", "buf={d}/4096", .{used});
log.trace(tid, rid, "sse_frame", "event={s} len={d}", .{event_name, len});
```

### 等级控制与快速路径

默认级别：`DEBUG`。`TRACE` 需显式启用 `--log-level trace`。

每个日志调用入口先做 `if (current_level < call_level) return;` 整数比较——无字符串格式化、无系统调用、无堆分配。高频路径（writeFrame、loop 迭代内）零开销跳过。

```zig
pub fn trace(tid: u32, rid: u32, event: []const u8, comptime extra: []const u8, args: anytype) void {
    if (@intFromEnum(current_level) < @intFromEnum(Level.trace)) return;
    writeLog(tid, rid, Level.trace, event, extra, args);
}
```

`current_level` 是全局 `std.atomic.Value(Level)`。运行时通过 CLI 参数 `--log-level debug|trace` 修改。

### 线程 ID

Zig 0.16 无 `threadlocal` 关键字。方案：主线程 `@atomicRmw` 分配 ID，通过 `handleConnection` 参数传入，存入 `Context` 的 `thread_id: u32` 字段。日志函数从 Context 读取，无需寄存器/thread-local 查询。

```zig
// server.zig — 主循环
var next_thread_id: u32 = 0;
while (true) {
    const tid = @atomicRmw(u32, &next_thread_id, .Add, 1, .seq_cst);
    const thread = std.Thread.spawn(.{}, handleConnection, .{
        gpa, io, &state, sessions_dir, stream, tid,
    }) catch ...;
}

// handleConnection
fn handleConnection(..., tid: u32) void {
    var ctx = handler.Context{
        .thread_id = tid,
        ...
    };
}
```

日志调用方直接传 `ctx.thread_id` 和 `ctx.request_id`，不经过 struct。

### 上下文传递

`log.zig` 不依赖 `handler.Context`（util/ 层不能 import frontends/）。方案：Context 字段直接内联到 `handler.Context`，日志函数接收简单参数。

`handler.Context` 新增两个字段：

```zig
pub const Context = struct {
    // ... 现有字段 ...
    thread_id: u32,                // 线程序号，由 server.zig 分配
    request_id: u32,               // 请求序号，原子递增
};
```

日志函数签名接受 `thread_id` + `request_id`（代码中简称为 `tid`/`rid`），不要求 struct 类型：

```zig
// 无 ctx（基础设施）
pub fn info(comptime fmt: []const u8, args: anytype) void { ... }

// 含 ctx（请求/业务/调试级）
pub fn req_info(tid: u32, rid: u32, event: []const u8, comptime extra: []const u8, args: anytype) void { ... }
pub fn biz_info(tid: u32, rid: u32, event: []const u8, comptime extra: []const u8, args: anytype) void { ... }
pub fn dbg(tid: u32, rid: u32, event: []const u8, comptime extra: []const u8, args: anytype) void { ... }
```

调用方直接传值：`log.req_info(ctx.thread_id, ctx.request_id, "request", "method=GET path=/api/session", .{})`。

无 struct 耦合、零指针追逐、`log.zig` 纯 util 层级。

## 实施

### 步骤 1: 创建 `src/util/log.zig`

基础结构：`Level` enum、全局 `current_level: std.atomic.Value(Level)`、格式化输出函数（时间戳 + ANSI 颜色）。

### 步骤 2: server.zig 新增线程/请求 ID 分配

`next_thread_id: u32` 原子递增分配 `tid`。
`next_request_id: u32` 原子递增分配 `request_id`，在 `handleConnection` 入口获取。

### 步骤 3: 替换现有诊断日志

将 handler.zig 中所有 `fprintf(stderr)` 调用替换为 `log.*()` 调用。

### 步骤 4: 追加业务级日志

在关键路径追加：`handlePrompt` SSE 流生命周期、`handleSessionList` 扫描结果、`handleSessionCreate` 等。

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/util/log.zig` | 新建 | 否 |
| `src/frontends/web/handler.zig` | 替换 ad-hoc 日志 | 否 |
| `src/frontends/web/server.zig` | 线程 ID 注册 + 请求日志 | 否 |

## 后续

| 待办 | 状态 |
|------|------|
| 写缓冲 — 批量 flush stderr，减少系统调用 | 未排期 — dev 工具下单条 write 可接受 |

## 不做

- 不写文件 — Dev 阶段只输出 stderr
- 不支持 JSON 格式 — 先做人类可读
- 不做日志轮转/压缩 — Dev 工具
- 不替换 `provider.zig`/`session.zig` 内部日志 — 逐步迁移