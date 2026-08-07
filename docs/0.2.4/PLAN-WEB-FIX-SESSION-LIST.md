# Plan WEB-FIX-SESSION-LIST: 新会话侧边栏不更新

## 状态: 已修复

## 问题

三个症状共享同一根因：

| 症状 | 原因 |
|------|------|
| 流式输出不渲染 markdown | `done` 帧发送失败 → HTTP 500 覆盖 SSE 流 |
| 侧边栏不更新 | 同上 → `loadSessions()` 不调 |
| 系统消息不出现 | 同上 → `renderSystemPrompt` 不调 |

## 根因

`sse.zig` `writeFrame` 栈缓冲区仅 512 字节。`buildDonePayload` 的 done 帧 JSON 含 `first_message`（完整系统提示，2000+ 字节），加上 SSE 帧格式头（`event: done\ndata: ` + `\n\n` ≈ 21 字节），总长远超 512 → `bufPrint` 返回 `NoSpaceLeft` → 错误传播到 `handleConnection` catch → `request.respond(500)` 覆盖在 SSE 流上 → 浏览器 received 500 → `done` 事件永不触发。

## 修复

`sse.zig:writeFrame` 栈缓冲 `[512]u8` → `[4096]u8`。

## 诊断日志（保留）

- `handler.zig`: `sse_stream_start` / `sse_pre_done` / `sse_done` / `sse_runTurn_error` / `session_new` / `session_list`
- `server.zig`: `request_error`（handleRequest catch 路径）
