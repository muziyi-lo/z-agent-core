# Plan F7: JSON 序列化统一模块（JsonWriter）

## 状态: 已完成（2026-08-14）

> 实施偏差记录见文末"实施偏差"节。

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| N14（ToolMeta 借用 args Value 悬垂 UB） | ✅ 已实施（2026-08-14，P0-FIXES） | 本计划（依赖链 `N14 → F7`，REMAINING.md:111） |

## 不做

- **不引入 std.json Stringify/静态序列化**：反射式序列化会写全部字段（含 null 可选字段、字段序按 struct 定义），与"每变体自平衡 + 可选字段省略"需求冲突，且控制不了 JSONL 格式细节。仍用手写式轻量写出器（REMAINING F7 方案方向）。
- **不做 pretty 选项（调试可读性）**：本次仅紧凑格式（现状行为，JSONL/API/SSE 均依赖紧凑输出）。未来如需调试可读性，可在 `JsonWriter` 加 `pretty: bool` 选项——`beginObject`/`beginArray` 后写换行、按 `depth` 写缩进、元素间写换行；因所有输出都走 `JsonWriter`，启用点为单一配置，**纯增量不改现有紧凑输出**（默认 `false`）。列入未来扩展，不进本周期。
- **不改 parse 侧**：`parseToolMeta`/`std.json.parseFromSlice` 已工作正常，只重构序列化路径。
- **不动 JSONL 格式**：字段名、字段顺序、可选字段省略规则全部保持现状。
- **不统一 sse 的 numeric-only 字段集**：sse 流式 tool_meta 刻意精简（不暴露 path/command 等），保持精简，只换实现方式。
- **不改前端**：Web 渲染逻辑（app.js）零改动；`tests/frontend/run-tests.mjs` 需回归（37 断言）。

## 问题

**现象**：JSON 序列化逻辑在 4 个文件里各写各的——4 份转义实现（其中 handler/sse 两份缺控制字符转义）、3 处 ToolMeta 序列化器字段集不一致（handler 的 write 缺 `old_lines`）、约 180 处手写 `appendSlice("...")` 拼接。

**根因**：历史上每处输出（JSONL 持久化 / API 请求体 / Web API 响应 / SSE 流式帧）各自手写，从未抽取共用模块。2026-08-13 由 LRN-20260813-019（`appendMetaJson` 函数尾假设"末字段为字符串"→ bash 布尔结尾多输出引号→ Web API 非法 JSON → 前端解析失败，曾被误判 429 限流）重新触发，REMAINING 登记为 F7（P1）。

## 概览

- **改动文件**：新增 `src/util/jsonw.zig`；修改 `src/types.zig`、`src/core/session.zig`、`src/io/provider.zig`、`src/frontends/web/handler.zig`、`src/frontends/web/sse.zig`、`src/test.zig`、`CHANGELOG.md`
- **新增 vs 修改**：新增 1 个模块（纯写出器），其余为"调用点替换 + 删旧实现"
- **一句话方案**：抽一个只依赖 std 的轻量 `JsonWriter`（自动逗号 + 完整转义 + 自平衡容器），统一 4 份转义为单一 `escapeInto`，ToolMeta 全字段序列化收敛为 `types.ToolMeta.writeJson`，各序列化函数改为声明式组装
- **参考实现**：无外部参考；转义逻辑以 session.zig:597 的完整版（含控制字符 + UTF-8 校验）为基准

## 设计要点

### JsonWriter 接口（含自动逗号 + 闭合管理）

写出器持有 `std.Io.Writer.Allocating`（Zig 0.16，已验证）作为缓冲，内部维护一个固定深度栈（上限 16）记录"每层容器类型 + 是否已写元素"。写入字段/元素时自动判断是否需要前置逗号，杜绝手动拼 `,` ——这是 F7 触发 bug（共享尾部假设）的结构性根治：

```zig
pub fn escapeInto(out: *std.Io.Writer, s: []const u8) !void; // 完整转义（JsonWriter 内部用）

/// 统一终态持有者：调用方无论 init/initFixed 模式，一律 `defer out.deinit()`。
/// deinit 根据 allocator 是否非空决定释放——模式判断内化，调用方无需关心借用/拥有。
pub const Result = struct {
    bytes: []u8,
    allocator: ?std.mem.Allocator = null,  // null=借用（fixed 模式/外部缓冲）

    pub fn deinit(self: *Result) void {
        if (self.allocator) |a| a.free(self.bytes);
        self.* = undefined;
    }
};

pub const JsonWriter = struct {
    pub const max_depth: usize = 16;   // 固定栈深度上限
    allocator: std.mem.Allocator,
    writer: std.Io.Writer,             // 统一写目标：alloc=Allocating.writer，fixed=Io.Writer.fixed
    aw: ?std.Io.Writer.Allocating = null,  // 仅 alloc 模式持有（deinit/result 需释放/转移）
    fixed_buf: ?[]u8 = null,           // 非空=initFixed 模式（deinit 不释放）
    depth: usize = 0,
    stack: [max_depth]ContainerState = undefined,

    const ContainerState = struct { is_object: bool, has_elements: bool };

    pub fn init(allocator: std.mem.Allocator) JsonWriter;      // 分配型（默认，aw 非空）
    pub fn initFixed(buf: []u8) JsonWriter;                    // 固定缓冲（sse 流式帧，aw=null）
    /// 错误路径兜底：alloc 模式释放 aw 缓冲；fixed 模式 no-op。
    /// 被 `result()` 消费后（aw 已转移/重置）再调为幂等 no-op。
    pub fn deinit(self: *JsonWriter) void;
    /// 终态取数：alloc 模式转移所有权（内部 toOwnedSlice，可 OOM 返回 error）；
    /// fixed 模式返回借用 view（allocator=null，deinit no-op）。调用方统一
    /// `const out = try jw.result(); defer out.deinit();`
    pub fn result(self: *JsonWriter) !Result;

    pub fn beginObject(self: *JsonWriter, key: ?[]const u8) !void; // null=顶层，key=嵌套 "key":{
    pub fn beginArray(self: *JsonWriter, key: ?[]const u8) !void;  // 同上，"["
    pub fn endValue(self: *JsonWriter) !void;                      // "}" 或 "]"（按栈顶类型）

    pub fn stringField(self: *JsonWriter, key: []const u8, value: []const u8) !void;
    pub fn intField(self: *JsonWriter, key: []const u8, value: anytype) !void;
    pub fn boolField(self: *JsonWriter, key: []const u8, value: bool) !void;
    pub fn rawField(self: *JsonWriter, key: []const u8, raw: []const u8) !void; // params_json 等已成形 JSON

    pub fn stringElem(self: *JsonWriter, value: []const u8) !void;
    pub fn intElem(self: *JsonWriter, value: anytype) !void;
    pub fn boolElem(self: *JsonWriter, value: bool) !void;
    pub fn rawElem(self: *JsonWriter, raw: []const u8) !void;
};
```

**选择理由**：字段/元素方法自动写 key、冒号、转义、逗号，调用方只需声明式描述结构，不再有任何"手动补引号/补逗号"的机会点。`writer` 为统一接口值（审查修复：`Allocating.writer` 与 `Io.Writer.fixed` 均为 `Io.Writer`，消除原 `aw: Allocating` 无法表达 fixed 模式的类型矛盾）；`aw`/`fixed_buf` 分别标记所有权归属。**统一终态 API**：`result()` 返回 `!Result`（可表达 OOM，审查修复），`deinit` 依 `allocator` 是否非空决定释放——调用方零生命周期判断，且 `JsonWriter.deinit` 作错误路径兜底。

### 深度上限与错误契约

**评论者质疑**：固定深度栈 16 上限在超深时行为未明确。核实：当前 JSON 结构（messages/tool_calls/usage 等）嵌套不超过 5-6 层，16 是安全余量；但未来扩展复杂结构（如嵌套工具参数）可能触及上限——超深必须有明确错误，而非静默越界写 `stack[16]`（UB）。

**契约**：
- `max_depth = 16` 为公开常量，`stack` 定长数组 `[max_depth]`，编译期即消除越界写可能（Zig 运行时对 `stack[depth]` 有 safety-check，但方法内显式判界更清晰）
- `beginObject`/`beginArray` 在 `depth >= max_depth` 时返回 **`error.JsonOverflow`**，不写任何字节（调用方结构错误，调用链中断）
- `endValue` 在 `depth == 0` 时返回 **`error.JsonUnderflow`**（现有契约保留，防 begin/end 不配对）
- 两个错误均为编程错误（调用方写死结构，不可能在正常运行中触发），不进入用户可见路径

| 方案 | 优点 | 缺点 |
|------|------|------|
| A. 定长 `[16]` + 超深报错 | 零分配、编译期定界、错误显式 | 上限固定，超深需改常量 |
| B. 动态扩容栈（ArrayList） | 无上限 | 每次 begin 可能分配；栈本身成热分配点 |
| C. 运行时 safety-check 兜底 | 代码最少 | 错误信息间接（panic 非返回值），调用方无法处理 |

**选择**：方案 A。深度是结构性问题非数据问题，动态扩容无实际收益；定长 + 显式 `error.JsonOverflow` 满足"错误处理保留"且零分配。

### 生命周期与 deinit 契约

**评论者提醒**：writeHeader 原用 `Managed(u8)`（自持 allocator），换 `JsonWriter.init` 后必须确保释放被调用、且覆盖所有错误路径，否则泄漏。

**核实**：`Io.Writer.Allocating.toOwnedSlice` 转移所有权后重置 `buffer = &.{}`/`end = 0`（Writer.zig:2653），`deinit` 对 `buffer.len == 0` 直接 return（Writer.zig）——因此释放逻辑幂等安全。**注意**：`toOwnedSlice` OOM 时 buffer 未重置、仍持有内存（审查验证），故 `result()` 必须返回 `!Result` 且 JsonWriter 自身保留 `deinit` 作错误路径兜底。

**统一模式**（审查修复后，替代 items/toOwnedSlice 双 API 的心智负担）：

```zig
var jw = jsonw.Writer.init(allocator);      // 或 initFixed(&stack_buf)
errdefer jw.deinit();                       // 错误路径兜底（result 未调用时释放 aw）
// ... 写入（任何 try 失败都走 errdefer，不泄漏）...
const out = try jw.result();                // 终态取数：转移所有权（fixed=借用 view）
defer out.deinit();                         // 唯一释放点：alloc=free，fixed=no-op
try file.writeStreamingAll(io, out.bytes);
```

调用方无需判断借用/拥有：`Result.allocator` 非空（alloc 模式）则 `deinit` 释放，为空（fixed 模式）则 no-op。`result()` 在 alloc 模式下消费 `JsonWriter`（内部 `toOwnedSlice`，此后 `jw.deinit()` 幂等 no-op），调用方不得再复用该 `JsonWriter`。**禁止** `defer jw.result().deinit()` 写法——`result()` 返回 error union 无法在 defer 中 `try`，且 OOM 时会跳过释放。

**实施检查项**：步骤 3~6 每个函数替换后，确认 `errdefer jw.deinit()` 紧跟在 `init` 之后、`result()` 只在所有写入完成后调用一次。发布前跑 `zig test` 的 testing.allocator 泄漏检测（GPA 泄漏栈会触发 AllocatedMemoryLeak 报错，正好当守卫）。

**golden 捕获前置**：进入步骤 3（session.zig 替换）**之前**，先在当前基线 commit 上执行步骤 7 的 golden 捕获（跑测试打印全字段消息集输出 → 回填 golden 字符串 → 提交确认测试通过），**再**开始 JsonWriter 替换。替换后同测试必须零差异——这是"JSONL 字节不变"的可执行证明，也是替换后 diff 的回归锚点。

### 转义统一（4 → 1）

单一函数 `escapeInto(out: *std.Io.Writer, s: []const u8) !void`，以 session.zig:597 的完整实现为基准（含 `\u00XX` 控制字符转义 + UTF-8 长度校验 + 非法字节替换 `\ufffd`）。`JsonWriter.stringField/stringElem` 内部调用它；sse 的文本帧也调用它（替换不完整的 `jsonEscapeBuf`）。**行为变化**：handler/sse 此前对 NUL/ESC 等控制字符原样透出（可能产生非法 JSON），统一后改为 `\u00XX` 转义——这是修复而非回归。

### 流式帧 fixed→alloc 回退（修复既有溢出隐患）

**评论者发现**：`initFixed` 固定 8192 缓冲对超长 delta 文本不足。核实后确认这是**既有隐患**——现状 sse.zig:68 `writeTextDelta` 就是固定 8192 栈缓冲 + `jsonEscapeBuf` 超限返回 `BufferTooSmall`，writeRaw 的 catch 会 `abort()`（sse.zig:139-140），即单 delta 内容转义后超 ~8190 字节即流中断。

**修复方案（评论者提议）**：`writeTextDelta` 先尝试 `initFixed(8192)`，若某次写入返回 `error.WriteFailed`，回退到 `init` 动态分配重建完整帧再发送。热路径（99.99% 场景，短 delta）零分配；罕见超长文本仅一次堆分配，不再中断流。

```zig
/// 封装"fixed 优先 + alloc 回退"的单帧发送。所有 text_delta 调用点（writeRaw/renderTool）
/// 都走此 helper，避免每处重复写回退逻辑。
fn sendTextFrame(self: *SseState, event: []const u8, text: []const u8) !void {
    var stack_buf: [8192]u8 = undefined;
    var jw = jsonw.Writer.initFixed(&stack_buf);
    writeTextFrame(&jw, event, text) catch |err| {
        if (err != error.WriteFailed) return err;
        // 回退：丢弃 fixed（栈内存不释放），改用分配型重建
        var ajw = jsonw.Writer.init(std.heap.page_allocator);
        errdefer ajw.deinit();                       // OOM 或后续失败时释放
        try writeTextFrame(&ajw, event, text);
        const out = try ajw.result();                // 终态取数（可 OOM）
        defer out.deinit();
        try self.w.writeAll(out.bytes);
        try self.w.flush();
        return;
    };
    const out = jw.result() catch unreachable;       // fixed 模式不分配，borrow view 恒成功
    try self.w.writeAll(out.bytes);
    try self.w.flush();
}

fn writeTextDelta(self: *SseState, event: []const u8, text: []const u8) !void {
    try self.sendTextFrame(event, text);
}
```

**注意**：fixed 模式的 `result()` 是纯借用 view（不分配、不可失败），用 `catch unreachable` 安全（审查确认：fixed 分支 allocator=null，无 toOwnedSlice 调用）。alloc 回退分支 `errdefer ajw.deinit()` 覆盖 `writeTextFrame`/`result()` 失败路径，成功时 `result()` 转移所有权使 `deinit` 幂等 no-op。

**评论者建议**：把回退分支封装为 helper，避免手动 `ajw` + `defer deinit` 散落各处。**采纳**：`sendTextFrame` 为 sse 私有 helper，`writeRaw`/`renderTool` 等所有 text_delta 调用点统一走它。**修正**：评论者提到的 `std.io.fixedBufferStream` 在 Zig 0.16 已移除（0.15 起改用 `Io.Writer.fixed`，G7.5 桩已验证），方案用 `initFixed` 即其 0.16 等价物，无需该 API。

**选择理由**：对比三方案——

| 方案 | 热路径 | 超长处理 | 实现成本 |
|------|--------|----------|----------|
| A. fixed 8192 单帧整写（现状） | 零分配 | **流中断**（BufferTooSmall） | 0（现状） |
| B. `escapeChunk` 分块多帧 | 零分配 | 多帧拼接（前端 `+=` 安全） | 高（新增分块原语 + 边界逻辑） |
| C. **fixed→alloc 回退**（评论者） | 零分配 | 一次堆分配重建单帧 | 低（一个 catch 分支） |

**选择**：方案 C。现状本就是单帧语义（前端对单帧 JSON.parse），回退后仍单帧，行为一致零回归；分块方案 B 需新增原语且改变帧语义。失败分支仅在超长时执行一次，成本可忽略。

### ToolMeta 序列化收敛（3 → 2）

| 位置 | 现状 | 实施后 |
|------|------|--------|
| session.zig | `appendToolMetaJson` 全字段 | 删，改调 `types.ToolMeta.writeJson` |
| handler.zig | `appendMetaJson` 全字段（write 缺 `old_lines`） | 删，改调 `types.ToolMeta.writeJson`（字段集自动对齐 session） |
| sse.zig | `serializeMeta` numeric-only | 保留精简字段集，改用 `JsonWriter` 实现 |

全字段序列化以 session 为准（JSONL 是主数据源），handler 的 Web API 输出会**新增 `old_lines`/`next_offset` 等此前缺失的字段**——向前兼容（前端忽略未知字段），同时消除"三处各写各的"的漂移隐患。

**归属位置**：`types.ToolMeta.writeJson(w: *JsonWriter) !void`。types 被 session/handler/sse 三方共同 import，是天然共享点；types 新增 `@import("util/jsonw.zig")`（单向依赖 `./ → util/`，util 只依赖 std，无环）。

## 实施

### 步骤 1: 新建 `src/util/jsonw.zig`

**文件**: `src/util/jsonw.zig`（新增，只依赖 std）
**改动**: 实现 `JsonWriter` + `escapeInto` + `initFixed` + `Result` + `deinit`（错误路径兜底），含 7 个测试块（转义完整控制字符 / 非法 UTF-8 替换 / 对象+数组自平衡 / 空对象 / `initFixed` 溢出返回 `error.WriteFailed` 且 `result()` 借用 view 的 `deinit` 为 no-op / `result()` 未调用时 `deinit` 释放无泄漏（错误路径兜底）/ 深度越界——17 层 beginObject 返回 `error.JsonOverflow`、0 层 endValue 返回 `error.JsonUnderflow`）。
**关键代码**:

```zig
pub fn escapeInto(out: *std.Io.Writer, s: []const u8) !void {
    // 以 session.zig appendEscapedJsonString 完整实现为基准逐字移植
}
```

**注意**: `Io.Writer.fixed` 写满返回 `error.WriteFailed`（G7.5 桩验证：Writer.zig:125 注释明确）；`result()` 返回 `!Result`（alloc 模式内部 `toOwnedSlice` 可 OOM，fixed 模式纯借用恒成功）；`deinit` 在 alloc 模式释放 aw、fixed 模式 no-op、被 `result()` 消费后幂等；`endValue` 依据栈顶 `is_object` 决定写 `}` 还是 `]`，深度为 0 时返回 `error.JsonUnderflow`。

### 步骤 2: `types.ToolMeta.writeJson` 全字段序列化

**文件**: `src/types.zig`
**改动**: 新增 `pub fn writeJson(self: ToolMeta, w: *jsonw.JsonWriter) !void`，按 session.zig `appendToolMetaJson` 的字段集逐变体组装（write 含 `old_lines`；skill 变体顶层 name 字段用 `"skill"` 键）。
**注意**: 保持与 session 现状字节一致的字段顺序，避免 JSONL 文件内容变化（即使 parse 兼容，也应逐字节相同）。

### 步骤 3: session.zig 改用 JsonWriter

**文件**: `src/core/session.zig`
**改动**:
- 删 `appendEscapedJsonString`（L597-645），`serializeMessage`（L906）改用 `JsonWriter`
- `writeHeader`（L665）改用 `JsonWriter`：`Managed(u8)` 换 `init(allocator)` + `errdefer jw.deinit()` + `const out = try jw.result(); defer out.deinit();` + `file.writeStreamingAll(io, out.bytes)`（统一模式）
- `appendToolMetaJson`（L748）删，改调 `meta.writeJson`
**注意**: `serializeMessage` 的 tool_calls 数组（L923-935）、usage 对象（L956）用 `beginArray/beginObject` 嵌套；空可选字段（如 `timestamp==0`）不写——语义与现状一致。每函数替换后跑 testing.allocator 泄漏检测（见"生命周期与 deinit 契约"）。

### 步骤 4: provider.zig 改用 JsonWriter

**文件**: `src/io/provider.zig`
**改动**:
- 删 `appendEscapedJsonString`（L698-731）
- `buildJsonBody`（L502）改用 `JsonWriter`——**工具调用全覆盖**：`messages[].tool_calls[]` 嵌套数组（id/name/arguments，L540-546）、`tools[]` schema（L563-569，params 走 `rawField` 原样拼入）、compat 驱动字段
- `buildThinkingJson`（L619）改用 `rawField` 写已成形 thinking 片段
**注意**: `model_params`/`params_json` 是 raw JSON 片段，必须走 `rawField`（盲拼不转义，契约与现状一致）。**边界**：SSE 流式 tool_delta 累积（L372-411）与工具 args 校验（registry.zig）是 parse 侧，F7 明确不改——本步骤只覆盖序列化方向。

### 步骤 5: handler.zig 改用 JsonWriter

**文件**: `src/frontends/web/handler.zig`
**改动**:
- 删 `appendMetaJson`（L1356）与 `escapeJsonDynamic`（L1515）
- 21 处 `escapeJsonDynamic` 调用点逐一替换：构造完整 JSON 的用 `JsonWriter` 方法，纯转义用途的改 `jsonw.escapeInto`——含 Web API `tool_calls` 序列化（L1302 `c.arguments`）
**注意**: 字段集自动对齐 session（新增 `old_lines` 等）——handler.zig:1650 的回归测试需补充断言。

### 步骤 6: sse.zig 改用 JsonWriter

**文件**: `src/frontends/web/sse.zig`
**改动**:
- `jsonEscapeBuf`（L79）删
- 新增私有 helper `sendTextFrame`（fixed→alloc 回退封装），`writeTextDelta`（L68）改为调它；`writeRaw`/`renderTool` 等全部 text_delta 调用点统一走 helper（评论者建议：回退分支不散落各处）
- `serializeMeta`（L236）保持 numeric-only 字段集，改用 `JsonWriter`（短帧，fixed 或 alloc 均可）
**注意**: 热路径 `writeTextDelta` 99.99% 走 fixed 零分配；回退分支仅超长时执行一次，且用 `page_allocator`（与 SSE 生命周期匹配，不用 arena 避免随连接堆积）。回退时先丢弃 fixed 实例（栈内存不释放）再重建。

### 步骤 7: JSONL golden 字节测试 + 全变体 roundtrip 测试

**文件**: `src/core/session.zig` 测试区 + `src/frontends/web/handler.zig` 测试区（或 jsonw.zig）
**改动**:
- **golden 基线测试**（评论者建议）：构造覆盖全字段的代表性消息集（含 tool_calls / tool_call_id / reasoning_content / usage 全字段 / 8 种 ToolMeta 变体 / 空可选字段省略），用 `writeHeader` + `serializeMessage` 序列化，与**硬编码 golden 字符串** `expectEqualStrings` 逐字节断言
- **golden 捕获顺序**：实施改动前的基线 commit 上先跑一次，把当前实现的精确输出固化进测试（`zig test src/core/session.zig` 打印 → 回填），再进入 JsonWriter 替换——替换后测试必须零差异，防止未来任何序列化回归
- **roundtrip 测试**：对全部 8 个 ToolMeta 变体执行 `parse → serialize → parse`：构造变体 → `writeJson` 序列化 → `std.json.parseFromSlice` → 断言关键字段 → 再次 `writeJson` → 再次 parse → 断言字段一致（REMAINING F7 强制要求）
**注意**: golden 字符串的 timestamp 用固定值（如 `1752062401`）避免时间漂移；msg_count 等动态字段用固定消息集固化；header 的 `epochToISO8601` 输出对同一 epoch 确定。handler.zig:1650 已有单遍 parse 断言，扩展为双遍 roundtrip。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs        # 前端渲染逻辑回归（37 断言）
node scripts/check-arch.mjs .            # 架构红牌（对比基线）
node scripts/check-catch-silent.mjs . --audit
```

| 测试场景 | 预期结果 |
|----------|----------|
| jsonw 转义单测（控制字符/非法 UTF-8） | `\u00XX`/`\ufffd` 正确输出 |
| jsonw `initFixed` 模式 | 溢出返回 `error.WriteFailed`；`result()` 借用 view 且 `deinit` 为 no-op（不释放栈内存） |
| jsonw 泄漏检测（deinit + Result.deinit） | testing.allocator 无 Leak；`result()` 未调用时 `deinit` 释放（错误路径兜底）；alloc 模式 `result()` 后 `deinit` 幂等不 double-free |
| jsonw 容器自平衡（对象+数组嵌套/空对象/深度>16） | 输出可 parse；空容器合法；超深返回 `error.JsonOverflow`；欠深返回 `error.JsonUnderflow` |
| sse `writeTextDelta` 超长 delta（>8192 转义后） | 回退 `init` 重建单帧发送成功，无流中断；短 delta 走 fixed 零分配 |
| ToolMeta 8 变体 roundtrip（双遍） | parse→serialize→parse 字段一致 |
| session serializeMessage roundtrip | JSONL 字节与改动前一致 |
| **JSONL golden 基线** | 全字段消息集序列化输出与实施前捕获的 golden 字符串**逐字节零差异**（`expectEqualStrings`），防未来回归 |
| buildJsonBody | API 请求体可被 mock server parse |
| handler 各端点响应 | 全部可 parse（回归测试 + 浏览器实测） |
| sse 流式帧 | tool_meta/text_delta 零分配输出合法 JSON |
| ReleaseSafe | `@intCast`/函数指针无 UB（本次含 `endValue` 栈操作） |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/util/jsonw.zig` | 新增 | 否 |
| `src/types.zig` | 新增 `ToolMeta.writeJson` + import jsonw | 否（单向依赖） |
| `src/core/session.zig` | 删 3 个私有函数，改 JsonWriter | 否（JSONL 字节不变） |
| `src/io/provider.zig` | 删转义，改 JsonWriter | 否（请求体字节不变） |
| `src/frontends/web/handler.zig` | 删 appendMetaJson/escapeJsonDynamic，21 处替换 | 低（Web 响应新增 old_lines 等字段，向前兼容） |
| `src/frontends/web/sse.zig` | 删 jsonEscapeBuf/serializeMeta 手写，改 JsonWriter + fixed→alloc 回退 | 否（修复既有超长 delta 中断） |
| `src/test.zig` | 加 `_ = @import("util/jsonw.zig");` | 否 |
| `CHANGELOG.md` | Refactored 条目 | 否 |

**G10(d) 错误集映射**：

| 发送方模块 | 返回的错误 | 接收方模块 | 匹配方式 | 处理行为 |
|------------|-----------|------------|----------|----------|
| jsonw.escapeInto / JsonWriter 方法 | `error.OutOfMemory` / `error.WriteFailed`（fixed 缓冲写满） | session/provider/handler/sse 序列化函数 | `try` 向上传播 | 保持现状错误语义（写入/响应失败） |
| JsonWriter.result（alloc 模式） | `error.OutOfMemory`（内部 toOwnedSlice） | 调用方 | `try` | 错误路径，errdefer jw.deinit() 兜底释放 |
| sse.writeTextDelta | `error.WriteFailed`（fixed 8192 写满） | sse.writeTextDelta 自身 | `err == error.WriteFailed` | **回退 `init` 重建单帧发送**（超长 delta 不中断流） |
| JsonWriter.beginObject/beginArray（depth≥max_depth） | `error.JsonOverflow` | 调用方 | `try` | 编程错误，测试覆盖断言 |
| JsonWriter.endValue（depth==0） | `error.JsonUnderflow` | 调用方 | `try` | 编程错误，测试覆盖断言 |

> **WriteFailed 与回退的关系**：`writeTextDelta` 热路径先走 fixed 零分配；仅当 `error.WriteFailed`（超长）时触发回退分支——一次堆分配重建完整单帧，之后正常发送。`WriteFailed` 不再向上传播为流中断，成为内部控制流信号。其他调用方（tool_meta 等短帧）的 `WriteFailed` 仍是编程错误，测试断言覆盖。

**G15 日志**：不适用——纯输出格式重构，无状态变更/边界操作（对齐 G15 判据：非创建/跨组件边界/生命周期切换）。

**G16 交互矩阵**：单特性（序列化统一），无多特性交叉。

## 术语

| 术语 | 含义 |
|------|------|
| JsonWriter | 轻量 JSON 写出器：自动逗号 + 完整转义 + 容器自平衡（begin/end 配对） |
| 闭合管理 | writer 内维护容器栈，字段/元素写入自动加逗号，杜绝手动拼 `,`/`"` |
| initFixed | 固定缓冲模式：包装外部栈缓冲，热路径零分配；`result()` 返回借用 view |
| Result | 统一终态持有者：`deinit` 依 `allocator` 是否非空决定释放；`JsonWriter.deinit` 作错误路径兜底，调用方零生命周期判断 |
| fixed→alloc 回退 | writeTextDelta 先走 fixed，`error.WriteFailed` 时回退分配型重建单帧，避免超长 delta 中断流 |
| pretty 选项 | 未来可选的调试可读性配置：`pretty: bool` 控制缩进/换行；默认紧凑输出不变（F13，REMAINING 登记） |
| numeric-only | sse 流式 tool_meta 的精简字段集（不暴露 path/command 等，只发数字摘要） |
| roundtrip 测试 | parse→serialize→parse 双遍往返，验证序列化稳定且可被标准解析器回读 |
| 自平衡序列化器 | 每个 ToolMeta 变体自身 begin→end 完整闭合，不共享"尾部假设" |

## 实施偏差

| 设计 | 实际 | 说明 |
|------|------|------|
| `ToolMeta.writeJson` 为方法 `meta.writeJson(&jw)` | 自由函数 `writeJson(meta, &jw)` | Zig 顶层 `pub fn` 对 union 非方法（审查发现），需类型声明体内才能方法调用 |
| `serializeMessage` 接收 `buf: *Managed` | 返回 `![]u8`（所有权转移给调用方） | JsonWriter 生成完整行；调用方（flush/golden 测试）改用 `const line = try serializeMessage(arena, msg)` |
| `writeTextDelta` 内联 fixed→alloc | 拆出 `sendTextFrame` + `writeTextPayload`（sse 私有） | `writeTextPayload` 为顶层函数（非 SseState 方法，避免 self 注入）；`writeTextDelta` 薄封装 |
| `result()` 后 `defer out.deinit()` | serializeMessage/buildJsonBody 用 `return (try jw.result()).bytes`（不 deinit，bytes 逃逸） | 所有权转移语义：逃逸 bytes 由调用方释放；函数内使用（writeHeader）仍 `defer out.deinit()` |
| handler 21 处 escapeJsonDynamic | 8 处调用点改 `jsonw.escapeAlloc`；appendMetaJson 改 `types.writeJson` + allocPrint 前缀 | 调用点实际 8 处（其余为函数内部）；统一为完整转义 |
| provider 4 个转义测试 | 删除 | 由 jsonw.zig 等价测试覆盖（`escapeInto escapes special chars` / `invalid UTF-8 replaced`） |
| `JsonWriter` 增 `rawBytes`/`rawInt` | 新增 | JSONL 换行、thinking/max_tokens 预成形片段需要裸写入（方案未预先列出，实施需求） |
