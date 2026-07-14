# Plan OPT-3: 工具输出结构化（ToolResult + ToolMeta）

## 状态: 计划中

## 前置依赖

| 被阻塞 | 状态 | 阻塞 |
|--------|------|------|
| — | — | OPT-4、新前端（TUI/Web） |

OPT-3 是基础契约层改动。OPT-4 依赖稳定的 `ToolDisplayCb` 签名，新前端依赖完整的工具输出数据结构。

## 不做（摘要）

| 项 | 理由 |
|----|------|
| 图片支持 (base64) | 模型能力不一致 |
| realpath 双重解析 | Windows 符号链接少 |
| BOM 保留 | 边界场景 |
| 竞争防护 (writeIfUnchanged) | 需 hash 基础设施 |
| ripgrep 外部二进制 | `std.regex` 满足需求 |
| 外部目录警告 (bash) | 权限范式不同 |
| `user_output` 移除 | bash 输出终端打印专用 |
| `labelFromValue` 完全删除 | meta.none 回退保留 |
| max_rounds LLM 可见性 | 已验证正确 |

→ 详细理由见文档末尾 `## 不做`。

## 根因

当前 `ToolResult` 是单字符串模型 — `session_content` 同时承载 LLM 上下文和（隐式的）前端展示需求。Write 不能报告 diff、read 不能报告行数、bash 不能报告退出码 — 不是因为"没做"，是因为没有结构化通道来传递这些数据。

```
ToolResult {
    session_content: "Wrote src/main.zig: 2450 bytes"   ← LLM 文本
    err_msg: ?[]const u8                                  ← 错误提示
    user_output: ?[]const u8                              ← bash 专有（临时补丁）
}
```

`user_output` 已是第一个"打破单字符串"的补丁 — bash 需要额外的输出通道。继续用补丁（如 `write_diff`、`read_line_count`）会导致每个工具在 `ToolResult` 上堆一个新字段，此即屎山。

## 设计

### ToolMeta — 每个工具一个结构化事实

> **注意**：以下为基线定义。各工具最终 variant 见对应对照章节（grep 补 `files_scanned`/`truncated`、glob 补 `truncated`、bash 补 `timed_out`、skill 补 `file_count`、新增 `edit` variant）。实施时以各章节的追加版为准。

```zig
// types.zig
pub const ToolMeta = union(enum) {
    none: void,

    write: struct {
        path: []const u8,
        existed: bool,
        old_lines: ?usize,     // null if new file
        new_lines: usize,
        byte_count: usize,
    },

    read: struct {
        path: []const u8,
        is_directory: bool,
        total_lines: usize,
        byte_count: usize,
        truncated: bool,
        next_offset: ?u32,      // 分页：下一页起始行号
    },

    grep: struct {
        pattern: []const u8,
        path: ?[]const u8,
        match_count: usize,
        files_scanned: usize,
        truncated: bool,
    },

    bash: struct {
        exit_code: i32,
        byte_count: usize,
        truncated: bool,
    },

    glob: struct {
        pattern: []const u8,
        path: ?[]const u8,
        file_count: usize,
    },

    skill: struct {
        name: []const u8,
    },
};
```

### ToolResult 新增 meta 字段

```zig
pub const ToolResult = struct {
    session_content: []const u8,
    err_msg: ?[]const u8 = null,
    user_output: ?[]const u8 = null,
    meta: ToolMeta = .none,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_content);
        if (self.err_msg) |e| allocator.free(e);
        // user_output: zero-copy borrowed view into session_content — consumed before deinit
        // meta: all fields are zero-copy borrowed views (from session_content or tool args)
        //       — no allocation, no free needed. Consumed during ToolDisplayCb.render callback.
    }
};
```

### ToolDisplayCb 契约变更

```zig
pub const ToolDisplayCb = struct {
    context: ?*anyopaque,
    render: *const fn (
        ctx: ?*anyopaque,
        tool_name: []const u8,
        tool_args: []const u8,
        had_error: bool,
        err_msg: ?[]const u8,
        user_output: ?[]const u8,
        meta: ToolMeta,                    // 新增
    ) anyerror!void,
};
```

> **渲染错误熔断**：`agent.zig` 调用处 catch 降级——打印错误日志 + 继续执行。工具数据（`session_content`）已正确，渲染失败不应丢失工具结果。代码：
> ```zig
> cb.render(...) catch |err| {
>     // render failed — tool data is valid, continue processing
> };
> try self.session_ref.append(.{ .role = .tool, .content = ok.session_content, ... });
> ```

### 前端消费

前端从 `meta` 提取展示数据，不接触 `session_content`：

```zig
// CLI (render.zig) — 使用 meta 构建标签
fn toolLabel(name: []const u8, meta: ToolMeta) []const u8 {
    return switch (meta) {
        .write => |w| if (w.existed) "Replaced {w.path}" else "Wrote {w.path}",
        .read => |r| "Read {r.path}",
        .grep => |g| "Grep {g.path} → {g.match_count} matches",
        .bash => |b| "$ exit {b.exit_code}",
        .glob => |g| "Glob {g.file_count} files",
        .skill => |s| "Skill {s.name}",
        .none => tool_name,
    };
}

// TUI — 使用 meta 做 diff 视图
fn showDiff(w: ToolMeta.write) void {
    // w.existed, w.old_lines, w.new_lines → diff panel
}

// Web — 使用 meta 构建 JSON response
fn apiToolResult(meta: ToolMeta) Json {
    // serialize meta → structured JSON for frontend SPA
}
```

### 与 labelFromValue 的关系

当前 `labelFromValue` 从 args JSON 解析参数构造标签。`ToolMeta` 替代这个模式 — 工具直接产出结构化数据，前端不再需要重新解析 args JSON。

| 之前 | 之后 |
|------|------|
| `labelFromValue("grep", args_json)` 解析 pattern/path | `meta.grep.pattern`, `meta.grep.match_count` |
| `labelFromValue("glob", args_json)` 解析 pattern/path | `meta.glob.pattern`, `meta.glob.file_count` |
| write 无法报告 diff | `meta.write.existed`, `meta.write.old_lines` |
| bash 用 `user_output` 补丁 | `meta.bash.exit_code` + `user_output`（保留，用于终端打印） |

**`user_output` 保留**：它是渲染数据（bash 输出给终端看），`meta` 是工具事实（退出码、字节数）。两者不重叠。

### 内存契约

`ToolMeta` 所有字段（`path`、`pattern`、`name` 等）为**零拷贝借用视图**。工具实现中，meta 字段应指向已有数据（`session_content` 的切片、args 解析结果、或栈上常量），不额外分配。`ToolResult.deinit` 仅释放 `session_content` + `err_msg`，不触碰 `meta` 和 `user_output`。消费窗口：`meta` 在 `ToolDisplayCb.render` 回调中消费（`defer ok.deinit` 之前），生命周期安全。

### 输入端架构：集中 JSON 解析

opencode 的 `Schema.decode(input)` 由框架自动完成，工具接收类型化参数。z-agent-core 每个工具手动 `parseFromSlice(Value, ...)` + 校验 + `defer deinit` — 平均 ~10 行重复模板。对应出力端的结构化改造，输入端也应集中。

**当前**：`ToolEntry.execute` 接收 `[]const u8`（原始 JSON 字符串），每个工具自行解析。

**改造后**：`registry.zig` 集中解析 `std.json.Value`，工具接收已解析的 `Value` + 可选 `validate` 前置校验。

```zig
// tool/registry.zig
pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    validate: ?*const fn (allocator: std.mem.Allocator, args: std.json.Value) ?[]const u8 = null,
    execute: *const fn (ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult,
};

pub const Registry = struct {
    handlers: []const ToolEntry,

    pub fn execute(self: Registry, ctx: types.ToolContext, name: []const u8, args_json: []const u8) anyerror!types.ToolResult {
        const args = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON", .{});
            return types.ToolResult{ .session_content = msg };
        };
        defer args.deinit();

        for (self.handlers) |h| {
            if (std.mem.eql(u8, h.name, name)) {
                if (h.validate) |v| {
                    if (v(ctx.allocator, args.value)) |err| {
                        const msg = try std.fmt.allocPrint(ctx.allocator, "{s}", .{err});
                        return types.ToolResult{ .session_content = msg, .err_msg = err };
                    }
                }
                return h.execute(ctx, args.value);
            }
        }
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: unknown tool '{s}'", .{name});
        return types.ToolResult{ .session_content = msg };
    }
};
```

**工具侧收益**：每个工具删除 ~10 行 JSON parse 模板。`validate` 用于 edit 的 oldString/newString 前置校验（空字符串检查、相同性检查），不必等到 execute 内部才失败。

**出口校验**：`registry.execute()` 返回前自动过一扇门：`session_content` 非空检查、`err_msg` 对应 `had_error` 一致性。不要求 opencode 式的完整 Schema encode — `ToolMeta` union 的类型系统本身已是编译期保证。

**对比 opencode**：

| | opencode | z-agent-core 改造后 |
|------|----------|------|
| 输入解析 | `Schema.decode(input)` 自动 | `registry.execute()` 集中 parse |
| 输入校验 | Schema 类型检查 | `validate` 回调（可选） |
| 输出校验 | `Schema.encode(output)` 自动 | 出口校验（`session_content` 非空、`meta != .none` 基本约束），`ToolMeta` union 类型提供编译期保证 |
| LLM 通道 | `toModelOutput` 自动生成 | `session_content`（工具构建字符串） |
| 结构化通道 | `Output` 类型字段 | `meta`（`ToolMeta` union） |

---

## Read 工具对照 opencode

与 [opencode](https://github.com/anomalyco/opencode) 的 read 实现（`read-filesystem.ts`，363 行）对比：

### opencode 有而我们缺失的

| 特性 | opencode 实现 | z-agent-core 差距 |
|------|-------------|-------------------|
| offset 超界检测 | `OffsetOutOfRangeError` | 返回空字符串 — 静默错误 |
| 分页元数据 | `TextPage{ offset, truncated, next }` | 无 — LLM 不知道读到哪 |
| 单行截断 | 2000 字符/行 | 无 — 长行浪费上下文窗口 |
| 二进制检测 | 扩展名黑名单（`.zip` `.exe` `.dll` 等 33 个）+ 内容分析 | 仅内容分析 — 读 `.zip` 需要读完才报错 |
| UTF-8 校验 | 全文件流式解码 | 仅前 4096 字节 |
| 路径安全 | realpath 双重解析（防符号链接穿越） | 仅 `..` 检测 |
| 图片支持 | JPEG/PNG/GIF/WebP → base64 | 无 — 核心能力缺失 |

### opencode 的关键设计

`TextPage` 结构体让工具返回**带上下文的页面**而非裸文本：

```typescript
class TextPage {
    type: "text-page",
    content: string,       // 当前页文本
    mime: string,          // MIME 类型
    offset: PositiveInt,   // 当前页起始行
    truncated: boolean,    // 是否有更多内容
    next?: PositiveInt,    // 下一页起始行号
}
```

LLM 从 `offset` + `next` 知道读取进度，从 `truncated` 知道文件未完。z-agent-core 返回纯字符串，LLM 完全不知道自己处于文件什么位置。

### 采纳的改进

| 特性 | 采纳 | 理由 |
|------|------|------|
| 分页元数据 (`truncated`, `next_offset`) | ✅ 入 ToolMeta | LLM 上下文管理必需 |
| offset 超界报错 | ✅ 入工具行为 | 静默错误 → 显式报错 |
| 单行截断 (2000 字符) | ✅ 入工具行为 | 防止单行长日志撑爆上下文 |
| 扩展名黑名单 | ✅ 入工具行为（快速路径） | 扩展名命中直接拒绝；未命中时保留现有 `isBinary()` 内容分析兜底 |
| 全文件 UTF-8 校验 | ✅ 入工具行为 | 仅检头部不安全 |
| 图片支持 (base64) | ❌ 暂不 | 模型能力不足时返回空 base64 等于无意义数据 |
| realpath 双重解析 | ❌ 暂不 | Windows 符号链接场景少，`..` 检测已覆盖常见路径穿越 |

### 改进后 read 的 session_content 格式

```
[Read src/main.zig: 350 lines, 12800 bytes]        ← 文件元信息（LLM 知悉规模）
                                                     ← meta.read: { total_lines: 350, byte_count: 12800, truncated: false, next_offset: null }

[Read src/main.zig: lines 200-249, 1800 bytes]       ← 分页读取
[truncated: next offset is 250]                     ← meta.read: { truncated: true, next_offset: 250 }

Error: offset 500 exceeds file src/main.zig (350 lines)  ← offset 超界
```

---

## Write/Edit 工具对照 opencode

opencode 的 write 和 edit 是**两个独立工具**（`write.ts` 93 行 + `edit.ts` 199 行），z-agent-core 合并为一个 `write.zig`。

### opencode 有而我们缺失的

| 特性 | opencode 实现 | z-agent-core 差距 |
|------|-------------|-------------------|
| write/edit 分离 | `write`（创建/覆写）+ `edit`（oldString→newString 替换） | 只有 `write` — 没有编辑语义 |
| edit 替换计数 | `replacements: number` 输出字段 | 无 — LLM 不知道改了多少处 |
| edit diff 预览 | `toModelOutput` 输出 `-`/`+` 行片段（≤6 行，240 字符/行截断） | 无 — LLM 无法验证改动 |
| edit 输入校验 | oldString==newString→error, oldString==""→error | 无 — 常见错误静默吞掉 |
| 多处匹配保护 | >1 处匹配 + replaceAll≠true → 报错"提供更多上下文" | 无 — 可能误改多处 |
| replaceAll 开关 | `replaceAll: boolean`（默认 false） | 无 |
| 换行符规范化 | 自动检测 CRLF/LF 并按文件原有格式转换 | 无 — 编辑 CRLF 文件易失败 |
| 输出结构 | `{ operation, target, resource, existed }` | `"Wrote {path}: {d} bytes"` |
| BOM 保留 | `writeTextPreservingBom` | 无 |
| 竞争防护 | `writeIfUnchanged`（hash 比较后才写入） | 无 |

### opencode edit 的关键设计

`toModelOutput` 直接给 LLM 展示改动片段：

```
Edited file successfully: src/main.zig
Replacements: 2
```diff
-const msg = try allocator.free(data);
+const msg = try allocator.dupe(data);
-    return result;
+    return .{ .session_content = msg };
```
```

LLM 从这个 diff 就能验证自己的修改是否准确。z-agent-core 只返回 `"Wrote main.zig: 2450 bytes"` — LLM 完全不知道改了什么。

### 采纳的改进

| 特性 | 采纳 | 理由 |
|------|------|------|
| **新增 `edit` 工具** | ✅ 单独文件 `tool/edit.zig` | write 和 edit 语义不同，不应合并 |
| edit 替换计数 | ✅ `meta.edit.replacements` | LLM 需要知道改动规模 |
| edit diff 预览 | ✅ `session_content` 包含 `-`/`+` 行 | LLM 验证改动正确性 |
| edit 输入校验 | ✅ oldString==newString/empty→err_msg | 防止无声错误 |
| 多处匹配保护 | ✅ >1 匹配 + replaceAll≠true→err_msg | 防止意外修改 |
| replaceAll 开关 | ✅ `edit` 工具参数 | 显式意图 |
| 换行符规范化 | ✅ 自动检测并匹配原文件 | 跨平台编辑安全 |
| 输出结构 `existed` | ✅ 已在 `meta.write.existed` | 区分创建/覆写 |
| BOM 保留 | ❌ 暂不 | 边缘场景 |
| 竞争防护 `writeIfUnchanged` | ❌ 暂不 | 需文件 hash 基础设施，CLI 单进程无并发 |

### ToolMeta 新增 edit variant

```zig
edit: struct {
    path: []const u8,
    replacements: usize,
    old_lines: usize,       // 受影响的原始行数
    new_lines: usize,       // 替换后的行数
},
```

### 文件变更追加

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/tool/edit.zig` | **新增** | 独立 edit 工具。无匹配时 `err_msg` 附前后 3 行上下文，帮助 LLM 重试定位 |
| `src/tool/registry.zig` | 修改 | 注册 edit 工具 + meta.edit |

---

## Grep 工具对照 opencode

opencode 的 grep 委托给 ripgrep 外部二进制，z-agent-core 自实现行扫描。

### opencode 有而我们缺失的

| 特性 | opencode 实现 | z-agent-core 差距 |
|------|-------------|-------------------|
| 正则引擎 | ripgrep（完整正则） | `std.mem.indexOf`（纯子串） | **不支持正则** — 核心差距 |
| path 参数 | 可选（默认 location） | 必填 | 每次 grep 必须指定路径 |
| 结构化输出 | `FileSystem.Match[]` | 纯文本行 | TUI 无法结构化消费 |
| 输出格式 | `{file}:\n  Line {n}: {text}` | 单文件和目录格式不一致 | LLM 解析困难 |
| `include` glob | ripgrep 原生 `*.{ts,tsx}` | 手动仅 `*.ext` | 复杂 glob 不生效 |

### 核心差距：不支持正则

工具描述写 "Substring or pattern to search for"，但 `std.mem.indexOf` 是纯子串匹配。LLM 写 `fn.*foo` 期望正则语义时得到零匹配 — 无法理解搜索失败原因，浪费回合。

Zig 标准库 `std.regex.Regex` 可提供内嵌正则支持，无需外部二进制。

### 采纳的改进

| 特性 | 采纳 | 理由 |
|------|------|------|
| 正则支持 | ✅ `std.regex.Regex` 替代子串匹配 | 核心能力缺失 |
| path 可选 | ✅ 默认 project_root | 减少 LLM 参数负担 |
| `meta.grep` 补字段 | ✅ `match_count` + `files_scanned` + `truncated` | 前端可展示扫描范围 |
| `include` glob 增强 | ✅ 支持 `*.{ext1,ext2}` brace | 匹配 LLM 常用格式 |
| ripgrep 外部二进制 | ❌ 暂不 | 增加安装复杂度，`std.regex` 满足需求 |

### ToolMeta.grep 更新

```zig
grep: struct {
    pattern: []const u8,
    path: ?[]const u8,
    match_count: usize,
    files_scanned: usize,       // 新增
    truncated: bool,            // 新增
},
```

---

## Glob 工具对照 opencode

opencode 的 glob 委托给 ripgrep，z-agent-core 自实现目录遍历 + 通配符匹配。**四个工具中差距最小的**。

| 特性 | opencode | z-agent-core | 结论 |
|------|----------|-------------|------|
| 通配符 | ripgrep | `globMatch`（`*` `?` + 回溯） | 功能相当 |
| 递归 | ripgrep | `walkDir` 递归 | 功能相当 |
| path 参数 | 可选 | 可选（默认 `.`） | 一致 |
| `limit` 参数 | 有 | 无（仅硬上限） | 缺少 |
| 外部依赖 | ripgrep | 无 | 我们更优 |

### 采纳

仅补 `limit` 参数 + `meta.glob`（已在计划中，增加 `truncated`）：

```zig
glob: struct {
    pattern: []const u8,
    path: ?[]const u8,
    file_count: usize,
    truncated: bool,
},
```

---

## Bash 工具对照 opencode

opencode 通过 Effect 进程管理异步执行，z-agent-core 使用 `std.process.run` 阻塞。

| 特性 | opencode | z-agent-core | 差距 |
|------|----------|-------------|------|
| 输出结构 | `{ exitCode, output, truncated, timedOut }` | 扁平字符串 | 无结构化 |
| 超时处理 | 默认 2min / 最大 10min | 有参数但无实现 | `std.process.run` 阻塞不可中断 |
| workdir | 可选参数 | 无 | 缺少 |
| stdout/stderr | 标签区分 `"stderr:\n..."` | 合并拼接 | LLM 无法区分 |
| 截断粒度 | 分别报告 | 统一 `[truncated]` | 信息丢失 |
| 捕获上限 | 1MB | 50KB | 差距 20x |

### 采纳

| 特性 | 采纳 | 理由 |
|------|------|------|
| workdir 参数 | ✅ 新增可选参数 | 支持项目子目录执行 |
| stdout/stderr 标签 | ✅ 有 stderr 时加前缀 | LLM 识别错误来源 |
| 超时处理 | ✅ 超时返回特殊输出 + `meta.bash.timed_out` | `std.process.run` 阻塞 → 改用 `std.process.Child` + poll |
| 上限提升 | ✅ 50KB → 512KB | 匹配其他工具 |
| `meta.bash.timed_out` | ✅ | 新增字段 |
| 外部目录警告 | ❌ 权限系统范式不同 |

```zig
bash: struct {
    exit_code: i32,
    byte_count: usize,
    truncated: bool,
    timed_out: bool,
},
```

> **超时实现**：放弃 `std.process.run`（阻塞不可中断），改用 `std.process.Child`。Windows: `kernel32.WaitForSingleObject(handle, timeout_ms)`；POSIX: `std.c.nanosleep` 轮询（纯用户态，零信号）。Zig 0.16 中 `std.time.sleep` 已移除（ZIG-016-SLEEP），不可用。

---

## Skill 工具对照 opencode

opencode 有 `SkillV2.Service` 注册表，z-agent-core 直接从文件系统读取。

| 特性 | opencode | z-agent-core | 差距 |
|------|----------|-------------|------|
| 技能注册表 | `skills.list()` | 无 | OPT-4 已规划 |
| 输出格式 | `<skill_content>` XML 含文件列表 | JSON `{"name":"content"}` | 缺目录/文件上下文 |
| 附带文件 | glob 枚举（≤10） | 无 | LLM 不知有哪些脚本 |
| 权限 | 集成 | hooks 可替代 | 范式不同 |

### 核心差距：输出格式

opencode 的 `toModelOutput` 产出结构化 XML 含基目录 + 文件清单：

```xml
<skill_content name="zig-dev">
# Skill: zig-dev
...
Base directory: /path/to/skill
<skill_files>
  <file>scripts/depgraph.mjs</file>
</skill_files>
</skill_content>
```

### 采纳

| 特性 | 采纳 | 理由 |
|------|------|------|
| XML 输出格式 | ✅ `<skill_content>` 替代 JSON | 提供目录 + 文件列表 |
| 附带文件枚举 | ✅ 列出同级文件 ≤10 个 | LLM 知道可引用的资源 |
| `listAvailableSkills()` | ✅ 已在 OPT-4 | 系统提示 + 技能验证 |

```zig
skill: struct {
    name: []const u8,
    file_count: usize,
},
```

---

## DeepSeek-Reasonix 对照：工具管道工程化

[Reasonix](https://github.com/deepseek-ai/DeepSeek-Reasonix)（Go 实现）提供了第三个视角 — 与 opencode 侧重"数据丰富度"不同，Reasonix 侧重**工具管道的运行安全与性能**。

### 采纳的改进

| 特性 | Reasonix 实现 | 采纳 | 理由 |
|------|-------------|------|------|
| 截断元数据 | `toolOutcome{truncated, truncMsg}` → 告知原始大小 | ✅ `meta` 补 `original_size` | 不仅标截断，还告诉 LLM 截断了多少 |
| Schema 规范化缓存 | `CanonicalizeSchema()` 首次排序+缓存，`Schemas()` 零开销 | ✅ `registry.toTools()` 缓存 | 当前每次 turn 全量 `dupe`，无效开销 |
| 工具渲染元数据解耦 | `toolcard.go` 独立映射表（`toolVerb`/`toolArgKey`/`toolCategory`） | ✅ `render.zig` 提 `ToolCard` struct | 当前内联 switch，新工具需改 2 处 |
| 死循环检测 | `StormBreaker`（同 `(name,error)` 连续 3 次 → 追加攻略提示） | ❌ 独立方案 | 非 OPT-3 范围，放入 REMAINING.md |
| 证据回执系统 | `Evidence Ledger` → `complete_step` 交叉验证 | ❌ 独立方案 | 新概念需独立设计 |
| 并行调度分区 | ReadOnly 工具并行（≤8 goroutine） | ❌ 后期性能优化 | CLI 单进程顺序执行已足够 |
| Plan Mode 细粒度分类 | `PlanSafetySafe/Unsafe/Unknown` + 黑/白名单 | ❌ 无 plan mode 基础设施 | 需先有 plan/execution 模式分离 |

### ToolMeta 追加字段

截断元数据从 Reasonix 的 `toolOutcome` 借鉴：

```zig
pub const ToolMeta = union(enum) {
    // ... 每个 variant 已有: truncated: bool, byte_count: usize ...
    // 追加: 无需新字段 — truncated + byte_count 已覆盖"截断了多少"语义。
    // Reasonix 的 truncMsg 等价于我们的 session_content 中的 "[truncated: N more bytes]"
};
```

> `byte_count` + `truncated` 已足够表达"原始 N 字节，返回 M 字节"。不需要额外字段。

### 注册表 Schema 缓存

`toTools()` 首次构建时缓存结果，后续调用直接返回：

```zig
pub const Registry = struct {
    handlers: []const ToolEntry,
    _cached_tools: ?[]types.Tool = null,   // 惰性缓存

    pub fn toTools(self: *Registry, allocator: Allocator) ![]types.Tool {
        if (self._cached_tools) |cached| return cached;
        // 首次构建 + 排序（稳定化，利于 prompt cache）
        var list = std.ArrayListAligned(types.Tool, null).empty;
        for (self.handlers) |h| {
            try list.append(allocator, .{ .name = h.name, ... });
        }
        self._cached_tools = try list.toOwnedSlice(allocator);
        return self._cached_tools.?;
    }
};
```

### 工具渲染元数据解耦

将 `toolVerb`/`toolArgKey`/`toolCategory` 从 switch 语句提取为 `ToolCard` 表：

```zig
// render.zig — 或独立 toolcard.zig
pub const ToolCard = struct {
    verb: []const u8,        // "Read" "Write" "$" "Grep" "Glob" "Skill"
    arg_key: []const u8,     // "path" "path" "command" "pattern" "pattern" "name"
    category: ToolCategory,  // .read .write .exec .search
};

const card_table: std.StaticStringMap(ToolCard) = .{
    .{"read", .{ .verb = "Read", .arg_key = "path", .category = .read }},
    .{"write", .{ .verb = "Write", .arg_key = "path", .category = .write }},
    .{"edit", .{ .verb = "Edit", .arg_key = "path", .category = .write }},
    .{"bash", .{ .verb = "$", .arg_key = "command", .category = .exec }},
    .{"grep", .{ .verb = "Grep", .arg_key = "pattern", .category = .search }},
    .{"glob", .{ .verb = "Glob", .arg_key = "pattern", .category = .search }},
    .{"skill", .{ .verb = "Skill", .arg_key = "name", .category = .skill }},
};
```

新工具加入只需加一行表条目 + 一个 toolcard.zig case（如果使用 `switch` 渲染），而不是在 render.zig 的 labelFromValue 和 writeToolLabel 两处修改。

---

## 分离收录的问题

以下问题因 ToolMeta 引入而自然解决：

### 1. write 不报告变更差异 → 核心行为

`meta.write` 承载 `existed`/`old_lines`/`new_lines`。LLM 通过 `session_content` 获得文本描述，前端通过 `meta` 获得结构化 diff。

```zig
// tool/write.zig
const existed = ...; // 读原文件
const old_lines = if (existed) countLines(old_content) else null;
return .{
    .session_content = "Replaced src/main.zig: {old} → {new} lines (+{diff}), {bytes} bytes",
    .meta = .{ .write = .{
        .path = path_val.string,
        .existed = existed,
        .old_lines = old_lines,
        .new_lines = countLines(content_val.string),
        .byte_count = content_val.string.len,
    }},
};
```

### 2. read 行为增强（对照 opencode）

以下改进基于 opencode 对比分析：

**2a. offset 超界报错**
`meta.read.total_lines` 暴露总行数，offset 超界时返回错误消息告知文件实际行数。

**2b. 分页元数据**
`meta.read.truncated` + `meta.read.next_offset` 让 LLM 知道读到哪、有没有更多。

**2c. 单行截断**
行超过 2000 字符时截断并追加 `... (line truncated)` 后缀，防止长行撑爆上下文。

**2d. 扩展名黑名单（快速路径 + 内容分析兜底）**
读取文件前先检查扩展名（`.zip` `.exe` `.dll` 等 33 个），命中直接拒绝。黑名单未命中时，继续走现有 `isBinary()` 内容分析（`\x00` 检测 + 控制字符比例 > 30%），双重保障。

**2e. 全文件 UTF-8 校验**
流式校验全文件（非仅前 4096 字节），防止尾部非法 UTF-8 字节漏检进入 LLM 上下文。

### 3. read limit=0 返回空 → 核心行为

`limit=0` 时仅返回文件元信息（`total_lines` + `byte_count`），不读内容。LLM 先知道文件规模再决定读多少。

### 4. 错误缺少 err_msg → 渲染契约

`ToolDisplayCb.render` 新增 `err_msg: ?[]const u8`，前端显示具体错误原因（非仅 `(err)` 后缀）。

### 5. bash 非法字节渲染乱码 → 渲染

`user_output` 打印前过滤不可打印字符（render.zig）。

### 6. 工具结果前"输出"标签 → 渲染

PhaseWriter 在工具调用前正确结束 content 阶段。

---

## 文件变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/types.zig` | 修改 | 新增 `ToolMeta` union；`ToolResult` 新增 `meta` 字段 |
| `src/core/agent.zig` | 修改 | `ToolDisplayCb.render` 新增 `meta: ToolMeta` + `err_msg: ?[]const u8` 参数；调用处传递 `ok.meta` + `ok.err_msg`；render 错误 catch 降级（日志 + 继续，不停止回合） |
| `src/frontends/cli/render.zig` | 修改 | `ToolDisplay.render` 更新签名；用 `meta` 替代 `labelFromValue` 中 args JSON 解析；`user_output` 过滤不可打印字符；PhaseWriter 工具前结束 content |
| `src/tool/write.zig` | 修改 | 填充 `meta.write` |
| `src/tool/read.zig` | 修改 | 填充 `meta.read`；offset 超界报错；分页元数据；单行截断（≤2000 char）；扩展名黑名单；全文件 UTF-8 校验；limit=0 仅返元信息 |
| `src/tool/grep.zig` | 修改 | 填充 `meta.grep`；`std.regex.Regex` 替代子串匹配；path 可选；`include` brace 支持 |
| `src/tool/bash.zig` | 修改 | 填充 `meta.bash` |
| `src/tool/glob.zig` | 修改 | 填充 `meta.glob` |
| `src/tool/skill.zig` | 修改 | 填充 `meta.skill`；XML 输出格式替代 JSON；附带文件枚举。⚠️ 与 OPT-4 共享（OPT-4 新增 `listAvailableSkills()`，不同区域无冲突） |
| `src/tool/registry.zig` | 修改 | `execute` 集中 `parseFromSlice` + 出口校验；`ToolEntry` 新增 `validate`；`toTools` Schema 缓存 |
| `src/frontends/cli/render.zig` | 修改 | `ToolCard` 表解耦渲染元数据（`labelFromValue` 改为查表） |
| `src/config.zig` | 修改 | 新增 `ToolLimits` struct。⚠️ 与 OPT-4 共享（OPT-4 新增 `base_prompt`，不同字段无冲突） |
| 全部工具文件 | 修改 | `execute(ctx, args: Value)` 替代 `execute(ctx, args_json: []const u8)`；删除 JSON parse 模板（每工具 -10 行） |

## 不做

| 项 | 理由 |
|----|------|
| max_rounds LLM 可见性 | 已验证正确 |
| `user_output` 移除 | bash 输出是唯一需要"终端直接打印数据"的场景，保留 |
| `meta` 字段放到 `ToolHooks.after` | after hook 接收 `*ToolResult` 已有 full access |
| `labelFromValue` 完全删除 | meta 替代 args JSON 解析，但 JSON parse fallback 保留（meta.none 时的回退） |
| 图片支持（base64） | 模型能力不足时返回空 base64 等于无意义数据，暂不 |
| realpath 双重解析（防符号链接穿越） | Windows 符号链接场景少，`..` 检测已覆盖常见路径穿越 |
| 死循环检测（StormBreaker） | 独立方案，放入 REMAINING.md |
| 证据回执系统（Evidence Ledger） | 新概念需独立设计 |
| 并行调度分区 | CLI 单进程顺序执行已足够 |
| Plan Mode 细粒度分类 | 需先有 plan/execution 模式基础设施 |

## 新工具接入协议

新增一个工具需要改 4 处：

1. `types.zig`：`ToolMeta` union 加 variant
2. `tool/xxx.zig`：填充 meta
3. `render.zig`：加 render case
4. `registry.zig`：注册

耦合点明确，不隐藏。

## 验证

```powershell
zig build
zig build test
node ..\..\.opencode\skills\zig-dev\scripts\check-arch.mjs .
```
