# Step 3: tool/ 全链 — 工具注册表 + 6 工具实现

> 详细实施计划。A~H 维度全部覆盖。

## A. 源码依据

| 源文件 | 用途 |
|--------|------|
| `projects/z-agent/src/tool/registry.zig` | 工具注册表参考 — match/execute/toTools 模式 + buildHandler comptime |
| `projects/z-agent/src/tool/read.zig` | 读文件参考 — UTF-8 校验、二进制检测、目录浏览 |
| `projects/z-agent/src/tool/write.zig` | 写文件参考 — 原子写入 .tmp → rename |
| `projects/z-agent/src/tool/bash.zig` | 子进程参考 — shell spawn、output 截断、超时 |
| `projects/z-agent/src/tool/grep.zig` | 内容搜索参考 — 文件/目录遍历匹配 |
| `projects/z-agent/src/tool/glob.zig` | 文件名查找参考 — glob pattern 解析与递归遍历 |
| `projects/z-agent/src/tool/skill.zig` | 技能加载参考 — SKILL.md 读取 + JSON 包装 |
| `zig/zig/lib/std/process/Child.zig` | `spawn(io, ...)` / `kill(io)` / `wait(io)` API |
| `zig/zig/lib/std/Io/Dir.zig` | `openDir(io, path, .{ .iterate = true })` — ZIG-FS-001 |
| `.opencode/learnings/LEARNINGS.md` | ZIG-FS-001, ZIG-WIN-001, ZIG-016-SLEEP |

## B. 模块设计

### B1. 文件职责

```
src/tool/
├── registry.zig    # 工具注册表 — match + execute
├── read.zig        # 读文件 — UTF-8 校验 + 二进制检测 + 目录浏览
├── write.zig       # 写文件 — 创建/覆写 + 父目录创建
├── bash.zig        # 子进程执行 — shell spawn + 超时 + output 截断
├── grep.zig        # 内容搜索 — 文件/目录正则匹配
├── glob.zig        # 文件名查找 — 模式匹配与递归遍历
└── skill.zig       # 技能加载 — .zagent/skills/*/SKILL.md 读取
```

**不需要独立文件**：`common.zig`（truncate / errors 等 ≤20 行辅助函数内联到各工具）

### B2. 架构简化原则

z-agent 工具层承担了 path resolution（`root_dir.resolvePath`）、结构化输出渲染（`renderResult`）、JSON 工具函数（`json.zig`）、截断模块（`truncate.zig`）等耦合。V1 CLI 版本做以下削减：

| 减法 | z-agent (不迁移) | z-agent-core V1 (替代) |
|------|-----------------|----------------------|
| Path resolution | `root_dir.resolvePath(allocator, path)` — 全局锚定 | `ctx.project_root` — 由 Agent 传入 |
| renderResult | 每工具可选 `renderResult` 回调 | 不实现 — `render/cli.zig` 统一处理输出 |
| JSON helpers | `json.zig` parseJsonStr / parseJsonBool 等 | 直接 `std.json.parseFromSlice` |
| truncate helpers | `truncate.zig` truncateBytes / truncateLines | 各工具内联 ≤10 行截断逻辑 |
| errors helpers | `util/errors.zig` allocFormat / format | 直接 `std.fmt.allocPrint` |
| 安全命令拦截 | `isBlocked()` / `isExpensive()` 模式匹配 | 不拦截 — V2 加入真实安全策略 |
| 原子写入 | `.tmp` 写后 rename | 保留 — write.zig 的唯一"复杂"操作 |
| 图片读取 | base64 编码、image detection | 不实现 — V1 纯文本 |

### B3. 工具接口统一

所有工具签名统一为：

```zig
fn execute(ctx: types.ToolContext, args: []const u8) anyerror![]const u8
```

- `ctx` 提供 `allocator`、`io`、`project_root`、`display_writer`
- `args` 是原始 JSON 字符串（由 registry 解析为 `std.json.Value` 后再传入）
- 返回值由调用方通过 `allocator.free` 释放（属于 `ctx.allocator` 管理）
- **错误策略**：Zig `error` 仅用于系统级失败（`error.OutOfMemory`、`error.AccessDenied`）。工具特定失败（缺参数、文件不存在、无效 UTF-8、超时）通过返回 `"Error: ..."` 字符串表示。这样 Agent 只需 `catch` OOM 等不可恢复错误，工具错误作为正常响应流转
- **错误契约**：工具返回 error 前必须通过 `defer`/`errdefer` 释放所有已分配内存，调用方在错误分支不得 `free` 任何返回值（此时返回值为 undefined，不可访问）
- **显示规则**：`display_writer` **仅用于成功执行的状态确认**（G9 格式）。工具特定错误（缺参数、文件不存在、无效 UTF-8、超时等）**不得**写入 `display_writer`，仅通过返回的 `"Error: ..."` 字符串向上层传递。这样 Agent 获得唯一错误信源，stderr 仅呈现操作进度不混入错误

### B3½. 路径安全

路径规范化与校验属于横切关注点，放在 `src/util/path.zig` 作为底层基础设施（与 `signal.zig`、`text.zig` 同级），所有工具通过 `const path_util = @import("../util/path.zig")` 引用：

```zig
// src/util/path.zig
/// Resolve a user-supplied relative path against project_root.
/// Normalizes "." and ".." segments, rejects paths that escape project_root.
/// Returns allocator-owned absolute path — caller must free.
pub fn resolvePath(allocator: std.mem.Allocator, project_root: []const u8, user_path: []const u8) ![]const u8;
```

### B4. Tool 注册表

```zig
// registry.zig
pub const Registry = struct {
    handlers: []const ToolEntry,

    pub const ToolEntry = struct {
        name: []const u8,
        description: []const u8,
        params: []const u8,   // JSON Schema string, verbatim copy to types.Tool.params
        execute: *const fn (ctx: types.ToolContext, args: []const u8) anyerror![]const u8,
    };

    /// Match tool by name and execute.
    pub fn execute(self: Registry, ctx: types.ToolContext, name: []const u8, args_json: []const u8) anyerror![]const u8;

    /// Convert registry to LLM tool definitions ([]types.Tool).
    pub fn toTools(self: Registry, allocator: std.mem.Allocator) ![]types.Tool;
};

/// Build registry from comptime tool module references.
pub fn buildRegistry() Registry;
```

**param 数据流**：`ToolEntry.params`（各工具模块导出的 `tool_params` 常量）→ `toTools()` 复制到 `types.Tool.params` → LLM tools 数组的 `parameters` 字段。无需格式转换——JSON Schema 字符串从工具定义直达 LLM，工具自身的 `execute()` 负责解析 LLM 据此生成的 args JSON。一致性由开发者确保（params 描述的参数必须与 execute 解析的参数名/类型匹配）。

关键差异 vs z-agent：
- `execute` 参数从 `(allocator, io, args: Value) ToolResult` 改为 `(ctx: ToolContext, args: []const u8) anyerror![]const u8`
- 移除 `renderResult` 回调
- 移除 `buildHandler(comptime tool)` 模板 — V1 直接构建 `ToolEntry` 数组

### B5. tool/read.zig

**参数**：`{"path": "...", "offset": number, "limit": number}`

行为：
1. 解析 args JSON，提取 `path` (required)、`offset` (optional, 1-indexed)、`limit` (optional)
2. `resolvePath(allocator, ctx.project_root, path)` 规范化
3. 先尝试作为目录打开 — 成功则列表目录条目（最多 100 条）
4. 再尝试作为文件打开
5. 空文件 → 返回空内容标记
6. 读取前 4096 字节检查二进制 — 含 null 字节或控制字符 >30% → 拒绝
7. UTF-8 校验
8. offset/limit 控制行范围读取
9. 输出截断至 50KB

**去掉**：图片检测 + base64 编码（V1 纯文本）、`renderResult`

### B6. tool/write.zig

**参数**：`{"path": "...", "content": "..."}`

行为：
1. 解析 args，提取 `path` (required)、`content` (required)
2. content 上限 512KB
3. `resolvePath(allocator, ctx.project_root, path)` 规范化
4. 创建父目录（如不存在）
5. 原子写入：先写 `{path}.tmp`，成功后再 `rename(io, tmp, path)`

### B7. tool/bash.zig

**参数**：`{"command": "...", "timeout": number}`

**实现方式**（修订后 — 实际实现使用 `std.process.run`，非 spawn）：
1. 解析 args，提取 `command` (required)、`timeout` (optional, 当前未实现)
2. 获取 shell：Windows `powershell.exe -Command`，POSIX `sh -c`
3. **`std.process.run(allocator, io, .{ .argv, .stdout_limit, .stderr_limit })`** — 不手动 spawn
   - 原因：Zig 0.16 Windows 上 `spawn` + 手动 pipe 读返回空（`Io.File.readStreaming` / `readerStreaming` + `takeByte` 均无法从子进程 pipe 读数据）
   - `run` 内部使用 `Io.File.MultiReader` 并发读 stdout + stderr，z-agent 已验证此方案可靠
   - `run` 内置输出截断（`stdout_limit` / `stderr_limit`），无需手动处理
4. 输出截断至 25KB per stream (50KB total)，超限追加 `[truncated]`
5. 退出码非零时追加 `[exit code: N]`
6. 未实现超时（`run` 是阻塞调用）

**去掉**：安全命令拦截（`isBlocked` / `isExpensive`）、手动 spawn + pipe 管理、超时轮询

### B8. tool/grep.zig

**参数**：`{"pattern": "...", "path": "...", "include": "..."}`

行为：
1. 解析 args，提取 `pattern` (required, 子字符串匹配)、`path` (required)、`include` (optional, 文件过滤 glob)
2. `resolvePath(allocator, ctx.project_root, path)` 规范化
3. 判断 path 是文件还是目录
4. 文件：逐行搜索，匹配的行记录 file/line/content
5. 目录：递归遍历（`openDir(..., .{ .iterate = true })` — ZIG-FS-001），对每个匹配 `include` 的文件做逐行搜索
6. **提前终止**：累积输出 ≥ 50KB 时立即 `break` 遍历循环，追加 `[truncated: {n} more files not searched]`
7. 最多 500 个匹配
8. 输出截断至 50KB

### B9. tool/glob.zig

**参数**：`{"pattern": "...", "path": "..."}`

行为：
1. 解析 args，提取 `pattern` (required)、`path` (optional, default ".")
2. `resolvePath(allocator, ctx.project_root, path)` 规范化
3. 解析 pattern 为路径段（分割 `/`），区分 `**`（递归）与普通段（精确匹配或通配符 `*` / `?`）
4. 从 root 开始逐段匹配递归遍历
5. **提前终止**：累积输出 ≥ 50KB 时立即 `break` 遍历循环，追加 `[truncated: {n} more files not traversed]`
6. 最多 1000 个匹配
7. 输出截断至 50KB

### B10. tool/skill.zig

**参数**：`{"name": "..."}`

行为：
1. 解析 args，提取 `name` (required)
2. `resolvePath(allocator, ctx.project_root, ".zagent/skills/{name}/SKILL.md")` 规范化
3. 文件不存在 → 错误
4. 返回内容包装为 JSON `{"name":"...","content":"..."}`（前端可用 skill 格式渲染）

**去掉**：`renderResult`、`root_dir.resolveZagentRoot`（用 `ctx.project_root` 替代）

## C. 接口设计

### C1. Registry

```zig
pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    execute: *const fn (ctx: types.ToolContext, args: []const u8) anyerror![]const u8,
};

pub const Registry = struct {
    handlers: []const ToolEntry,

    pub fn execute(self: Registry, ctx: types.ToolContext, name: []const u8, args_json: []const u8) anyerror![]const u8;
    pub fn toTools(self: Registry, allocator: std.mem.Allocator) ![]types.Tool;
};
```

### C2. 每工具导出接口 + ToolContext

`ToolContext` 扩展为：

```zig
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    display_writer: *std.Io.Writer,  // 工具确认消息输出目标
};
```

每个 `tool/{name}.zig` 导出：

```zig
pub const tool_name: []const u8 = "...";
pub const tool_description: []const u8 = "...";
pub const tool_params: []const u8 = "...";
pub fn execute(ctx: types.ToolContext, args: []const u8) anyerror![]const u8;
```

### C3. 依赖方向

```
types.zig               ← ToolContext, Tool 类型定义
       ↑
tool/registry.zig       ← 注册表，import types
       ↑
tool/{read,write,bash,grep,glob,skill}.zig  ← 各工具，不 import registry
```

工具之间互不 import。`registry.zig` import 所有工具模块。

## D. 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `src/types.zig` | 修改 | `ToolContext` 新增 `display_writer: *std.Io.Writer` 字段 |
| `src/util/path.zig` | 新建 | `resolvePath()` 路径规范化 + 防穿越校验 (~50 行) |
| `src/tool/registry.zig` | 实现 | Registry + ToolEntry + match/execute/toTools (~80 行) |
| `src/tool/read.zig` | 实现 | 文件读取 + UTF-8 校验 + 二进制检测 + 目录浏览 (~200 行) |
| `src/tool/write.zig` | 实现 | 文件写入 + 父目录创建 + 原子写入 (~100 行) |
| `src/tool/bash.zig` | 实现 | 子进程执行 + 超时 + output 截断 (~200 行) |
| `src/tool/grep.zig` | 实现 | 文件/目录内容搜索 (~150 行) |
| `src/tool/glob.zig` | 实现 | 文件名模式匹配 + 递归遍历 (~150 行) |
| `src/tool/skill.zig` | 实现 | SKILL.md 加载 (~80 行) |
| `src/test.zig` | 修改 | 移除 tool stub import，替换为真实模块 |

## E. 测试计划

| 测试 | 文件 | 覆盖 |
|------|------|------|
| `registry: match and execute` | registry.zig | Registry.execute 按名称分派 |
| `registry: unknown tool error` | registry.zig | 未知工具名返回错误 |
| `registry: toTools generates array` | registry.zig | toTools 正确生成 Tool 数组 |
| `read: reads text file` | read.zig | 读取文本内容 + 正确返回 |
| `read: detects binary` | read.zig | 二进制文件返回错误 |
| `read: UTF-8 validation` | read.zig | 无效 UTF-8 返回错误 |
| `read: directory listing` | read.zig | 目录内容列表 |
| `read: offset/limit range` | read.zig | 行范围读取 |
| `read: missing path` | read.zig | 缺 path 返回错误 |
| `write: creates file` | write.zig | 写入新文件 + 内容验证 |
| `write: parent dirs auto-created` | write.zig | 父目录自动创建 |
| `write: content too large` | write.zig | 超 512KB 返回错误 |
| `bash: executes command` | bash.zig | 执行 echo 命令验证输出 |
| `bash: timeout` | bash.zig | 超时命令返回超时错误 |
| `bash: output truncation` | bash.zig | 超 50KB 输出截断 + 标记 |
| `grep: finds matches in file` | grep.zig | 单文件内容匹配 |
| `grep: directory search` | grep.zig | 目录遍历搜索 |
| `grep: file filter` | grep.zig | include 参数过滤 |
| `glob: pattern matching` | glob.zig | 通配符匹配文件 |
| `glob: ** recursive` | glob.zig | `**` 递归目录 |
| `skill: loads skill file` | skill.zig | 读取 SKILL.md 内容 |
| `skill: missing skill error` | skill.zig | 不存在的 skill 返回错误 |

> 注：工具测试用 `testing.allocator` + `testing.io`。read/write/grep/glob 需要临时文件/目录，用 `testing.tmpDir()` 创建隔离测试环境。

## F. 失败路径

| 场景 | 行为 |
|------|------|
| 工具 args JSON 解析失败 | 返回 `"Error: invalid arguments JSON: {err}"` |
| 缺少必需参数 | 返回 `"Error: missing 'xxx' argument"` |
| 路径穿越 `../` | `resolvePath()` 返回 `error.PathEscape` → registry 转换为 `"Error: path escapes project root"` |
| 文件不存在 | 返回 `"Error: cannot open '{path}': FileNotFound"` |
| 权限不足 | 返回 `"Error: cannot open '{path}': AccessDenied"` |
| UTF-8 无效 | 返回 `"Error: file is not valid UTF-8 at '{path}'"` |
| 二进制文件 | 返回 `"Error: cannot read binary file '{path}'"` |
| 内容过大 | 返回 `"Error: content too large: {n} bytes (max 512KB)"` |
| 子进程超时 | 返回 `"Error: command timed out after {n}s"` + kill child |
| 子进程非零退出 | 正常输出 + 尾部追加 `"[exit code: {n}]"` |
| 目录不存在 | read/grep/glob 返回 `"Error: directory not found: '{path}'"` |
| skill 文件不存在 | 返回 `"Error: skill '{name}' not found"` |

## G. 方案完整性

- [x] G1 字段追实际定义：`ToolContext` 已在 types.zig 定义（allocator/io/project_root）。`Tool` execute 签名为 `fn(ctx: ToolContext, args: []const u8) anyerror![]const u8`。
- [x] G2 调用签名一致：registry.execute 签名与 agent.runTurn 后续调用点对齐（D5 节：agent 调用 registry.execute 后获取 ToolResult 追加到 session）。
- [x] G3 数据流贯通：agent → registry.match(name) → tool.execute(ctx, args_json) → allocPrint 输出 → 返回 []const u8
- [x] G4 现有设施复用：`types.ToolContext`（已有）、`types.Tool`（已有）、`util/signal.zig`（bash 超时检查用）
- [x] G5 交互边界：JSON 解析失败、缺参数、文件不存在、权限不足、超时、输出过大、二进制、无效 UTF-8 全量覆盖
- [x] G6 接口类型：C1 Registry + ToolEntry 签名已声明
- [x] G7 假设点：工具不 import config/tool 之外的业务模块。`ctx.project_root` 由上层（App/Agent）在初始化 ToolContext 时传入。路径解析通过 `util/path.zig` 的 `resolvePath(allocator, project_root, user_path)` 规范化 `..`/`.` 并校验不逃逸 `project_root`。`display_writer` 由 App 初始化为 stderr Writer。`ToolEntry.params` 为 JSON Schema 字符串，`toTools()` 原样复制到 `types.Tool.params` 传递至 LLM。
- [x] G8 独立可实施：仅依赖 types.zig（已完成），不依赖 core/io/render。可按 read → write → bash → grep → glob → skill → registry 顺序逐个实现验证。
- [x] G9 显示规范：`ToolContext` 新增 `display_writer: *std.Io.Writer`，每个工具执行后必须写一行友好确认消息。格式如下：

| 工具 | 显示格式 |
|------|---------|
| read | 全文读取：`Read {path}`；限制读取：`Read {path} [limit={n}, offset={m}]` |
| write | 新建：`Created {path} ({n} bytes)`；覆写：`Updated {path} ({n} bytes)` |
| bash | `> {command}` 换行后接输出内容（>50 行则省略中间行，首尾各保留 20 行），尾部追加 `[exit code: {n}]` |
| grep | `grep "{pattern}" in {path} → {n} matches` |
| glob | `glob "{pattern}" → {n} matches` |
| skill | `Loaded skill: {name}` |

## H. V2 优化方向（记录不实施）

| 方向 | 说明 |
|------|------|
| 结构化 ToolResult | 返回 `{ content, metadata, display_hint }` 替代 `[]const u8` + `display_writer`，消除显示/数据耦合 |
| Comptime 工具注册 | 用 `@typeInfo` 自动提取工具元数据，消除 `ToolEntry` 硬编码（6 个工具不值得） |
| read/grep/glob 超时 | 大目录阻塞时增加超时中断 |
| 安全命令拦截 | bash 的 `isBlocked()` / `isExpensive()` 模式匹配 |

## I. 预估行数

| 文件 | 行数 |
|------|------|
| `src/util/path.zig` | ~50 |
| `src/tool/registry.zig` | ~80 |
| `src/tool/read.zig` | ~220 |
| `src/tool/write.zig` | ~120 |
| `src/tool/bash.zig` | ~220 |
| `src/tool/grep.zig` | ~170 |
| `src/tool/glob.zig` | ~170 |
| `src/tool/skill.zig` | ~90 |
| `src/types.zig` | +3 (ToolContext.display_writer) |
| **合计** | ~1120 |

## J. 实施状态

> 完成时间: 2026-07-09. 94/94 tests pass, 0 leaks.

| 文件 | 行数 | 状态 |
|------|------|------|
| `src/util/path.zig` | 163 | ✅ |
| `src/tool/registry.zig` | 95 | ✅ |
| `src/tool/read.zig` | 389 | ✅ |
| `src/tool/write.zig` | 164 | ✅ |
| `src/tool/bash.zig` | 166 | ✅ |
| `src/tool/grep.zig` | 241 | ✅ |
| `src/tool/glob.zig` | 179 | ✅ |
| `src/tool/skill.zig` | 126 | ✅ |
| `src/types.zig` | +1 | ✅ |

### 已知差距

| 差距 | 归属 | 说明 |
|------|------|------|
| write 原子写入 (.tmp→rename) | **Step 7** | 简化为 deleteFile+createFile，待 App 连线后验证 `Io.Dir.rename` |
| grep 目录递归遍历 | **V2** | 实现为单层遍历，非递归 |
| glob `**` 递归模式 | **V2** | 简化通配符匹配，无 `**` 解析 |
| bash 超时轮询 | **V2** | `std.process.run` 是阻塞调用，不支持超时 kill |
| bash/grep/glob 缺失测试 | **V2** | 已有 `bash: echo hello` 测试（使用 `std.process.run`，兼容 `testing.io`）。grep/glob 目录搜索测试复杂 |
