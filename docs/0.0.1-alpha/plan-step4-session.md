# Step 4: core/session.zig — 线形会话

> 从 z-agent 提取 append/flush 逻辑，去除会话树/记忆系统/压缩。V1 纯线形 JSONL。

## A. 源码依据

| 源文件 | 用途 |
|--------|------|
| `projects/z-agent/src/session.zig` | SessionManager create/append/flush 参考 |
| `projects/z-agent/src/session/serialize.zig` | JSONL 序列化/反序列化参考 |
| `projects/z-agent/src/session/list.zig` | 会话列表 + 按 ID/index 继续参考 |
| `projects/z-agent-core/src/types.zig` | Message 类型定义 |
| `.opencode/learnings/LEARNINGS.md` | 相关踩坑：ZIG-016-MUTEX（V1 无并发，无 mutex） |

## B. 模块设计

### B1. 文件职责

```
src/core/session.zig    # 线形会话——append/flush/load/list/name
```

单个文件，不拆子模块。V1 数据简单（线形数组），不涉及 sequence/tree/serialize/compress 等子模块。

### B2. z-agent 减法

| 减法 | z-agent (不迁移) | z-agent-core V1 (替代) |
|------|-----------------|----------------------|
| 会话树 | `root_children`, `children_index`, `parent_id` 嵌套树结构 | 线形 `[]Message` 数组 |
| 记忆系统 | `compaction` EntryData, BM25 retrieval, LLM 摘要 | 不实现 — 消息数 > 50 仅告警，V2 处理 |
| designer/session 联动 | `session_info` EntryData, `designer.zig` 导入 | 不实现 |
| 多 format version | `CURRENT_VERSION = 2`, v1/v2 兼容解析 | V1 固定格式，无版本号 |
| 并发安全 | `Io.Mutex` + `flushed` 标志 | V1 单线程，无并发 |
| 序列化模块 | `session/serialize.zig`, `session/list.zig` | 内联 JSONL 读写（~50 行） |
| SessionHeader | id/cwd/model/provider/timestamp 元数据 | 首行 JSONL header，仅保留 `timestamp` + `model` |

### B3. 数据结构

```zig
pub const Session = struct {
    _arena: std.heap.ArenaAllocator, // 统一分配器：load 时创建，append dupe 也用此 arena
    io: std.Io,
    path: ?[]const u8,          // 当前会话文件路径（null = 未持久化）
    name: []const u8,            // 会话名称（初始为 "New Session"，/name 修改）
    messages: std.ArrayListAligned(types.Message, null),
    modified: bool,              // 是否有未持久化的改动
    model: []const u8,           // 会话使用的模型

    /// 创建新会话（未持久化，首次 flush 分配文件名）
    pub fn init(allocator: std.mem.Allocator, io: std.Io, model: []const u8) !Session;

    /// 从文件加载会话
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Session;

    /// 追加一条消息到内存（不立即写磁盘）
    pub fn append(self: *Session, msg: types.Message) !void;

    /// 获取所有消息切片（引用，非拷贝）
    pub fn messages(self: *const Session) []const types.Message;

    /// 轮次完成后持久化到磁盘
    pub fn flush(self: *Session) !void;

    /// 重命名当前会话（/name 命令）
    pub fn rename(self: *Session, new_name: []const u8) !void;

    /// 释放所有资源。若 modified=true 则在 Debug 模式断言失败（防止静默丢数据）
    pub fn deinit(self: *Session) void;
};
```

#### B3½. 消息对与轮次

V1 线形数组不存储树结构（无 `parent_id`、无分支）。消息间关系由**数组顺序**隐式表达：

```
messages[0]  system     ← 系统提示词
messages[1]  user       ← 第 1 轮开始
messages[2]  assistant  ← ──┬─ 轮次 1 的 assistant 响应
messages[3]  tool       ←   │  tool 结果（tool_call_id 关联到 messages[2] 的 ToolCall.id）
messages[4]  assistant  ← ──┘  收到 tool 结果后的继续响应
messages[5]  user       ← 第 2 轮开始
...
```

| 关系类型 | V1 如何表达 |
|----------|-----------|
| user → assistant | 数组相邻。assistant 紧接 user 后，含 `tool_calls` 或 `content` |
| assistant → tool（调用） | assistant 消息的 `tool_calls` 字段含 `[{id, name, arguments}]` |
| tool → assistant（结果） | tool 消息的 `tool_call_id` 匹配 assistant 的 `ToolCall.id` |
| 轮次边界 | `agent.zig`（Step 5）负责追踪。session 不感知轮次，仅提供 `append` + `flush` 原语 |

每完成一个完整轮次后，由 App 层调用 `session.flush()` 持久化。Agent 仅操作 session 内存（append/truncateTo），不负责持久化。轮次追踪是 App 的职责。

消息数告警在 `flush()` 时检查全部 `messages.len`（不区分轮次），因为 LLM API 需要完整历史。
```

### B4. JSONL 格式

```jsonl
{"type":"header","timestamp":"2026-07-09T12:00:00Z","model":"deepseek/deepseek-v4-pro","name":"New Session"}
{"role":"system","content":"You are a helpful assistant.","timestamp":1752062400}
{"role":"user","content":"hello","timestamp":1752062401}
{"role":"assistant","content":"Hi!","model":"deepseek/deepseek-v4-pro","timestamp":1752062402}
{"role":"assistant","content":"","tool_calls":[{"id":"c1","name":"read","arguments":"{}"}],"model":"deepseek/deepseek-v4-pro","timestamp":1752062403}
{"role":"tool","content":"file content","tool_call_id":"c1","timestamp":1752062404}
{"role":"assistant","content":"done","model":"deepseek/deepseek-v4-pro","timestamp":1752062405}
```

- 首行 header，含 `timestamp`、`model`、`name`
- 每条消息有 `timestamp`（Unix 秒）
- assistant 消息额外有 `model` 字段（`"provider/model_id"` 格式）
- `null` 字段省略输出（`model` 为 null 的 user/system/tool 消息不输出 `"model"` 键）

### B5. 关键行为

#### B5½. 持久化栅栏
- `append()` 只写内存，不碰磁盘
- `flush()` 由上层（App.zig / agent.zig）在**每个完整轮次结束后**调用
  - 一轮 = assistant 响应 + 所有 tool_results 追加完毕
- flush 时同步检查消息数，> 50 条 → stderr 告警 `"session: {n} messages, context may overflow"`
- 程序退出前调用 `flush()`（Ctrl+C 路径在 signal handler 中由 App 保证）

#### B5¾. 文件名与命名
- 新会话首次 flush：`.zagent/sessions/{timestamp}.jsonl`
  - `timestamp` = Unix 毫秒数（与 z-agent 格式兼容）
  - `name` 初始为 `"New Session"`
- `/name <name>` 命令：`rename(new_base)` → `.zagent/sessions/{name}.jsonl`
  - 更新 `self.name` 为新名称
  - 使用 `Io.Dir.rename` 重命名文件（若失败则保留原名 + stderr 告警，不修改 name）
  - 若目标文件名已存在，追加 `-{n}` 后缀直到唯一

#### B5⅞. 加载/列表/损坏处理

**load(allocator, io, path)**:
1. 打开文件，读取全部内容到临时 `[]u8`
2. 创建内部 `_arena`（parent = `allocator`）
3. 将 `path` dupe 到 `_arena` 中 → `self.path`（防止调用方 path 为临时变量导致悬挂指针）
4. 将文件内容 dupe 到 arena 中——`parseFromSliceLeaky` 引用此副本，arena 保证源内存存活
5. 逐行解析 JSONL：
   - 首行 header → 提取 `model`、`name`。**若 header 缺失或格式损坏→ load 失败**（返回 error.InvalidSession），保护原文件不被后续 flush 覆盖
   - 消息行 → 解析为 `types.Message`，追加到 `messages`。保留文件中已有 `timestamp`（非 0 不覆盖）和 `model`（非 null 不覆盖）。无效行跳过，输出 stderr 警告
6. 设置 `modified = false`

**rename(name)**:
- 将用户输入的 `name` 分为两个概念：
  - `self.name`：用户可见的显示名称（保留原始输入，可含任意字符）
  - `file_name`：文件名（经 `sanitizeFileName(name)` 清理后，仅保留 `[a-zA-Z0-9_.-]`，其余替换为 `_`；若结果为空则用 `"session"`）
- 若 `path == null`（从未 flush）：仅更新 `self.name`，下次 flush 时用 `file_name` 创建文件
- 若 `path != null`：用 `file_name` 重命名文件。若目标已存在，追加 `-{n}` 后缀。rename 成功后更新 `self.path`。失败 → stderr 告警，name/path 不变

**sanitizeFileName(name)**:
```zig
fn sanitizeFileName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;
    defer buf.deinit(allocator);
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '_');
        }
    }
    if (buf.items.len == 0) return allocator.dupe(u8, "session");
    return buf.toOwnedSlice(allocator);
}
```

**list(session_dir, allocator, io)**:
- 签名：`pub fn list(allocator: std.mem.Allocator, io: std.Io, session_dir: []const u8) ![]SessionInfo`
- 扫描 `.zagent/sessions/*.jsonl`，读取每文件首行 header（model、name、timestamp）。**不读取消息行内容**
- `msg_count` = `(stat.size / 150)` 粗估，UI 显示为近似值（标注 `~`）。假设平均每条 JSON 消息 ~150 字节
- 返回 `[]SessionInfo`，按 timestamp 降序排列
- **内存所有权**：所有字符串字段（`id`、`name`、`file_path`、`model`）通过 `allocator` dupe，调用方负责调用 `freeSessionInfoList(allocator, list)` 释放
- `id` 为**当前文件名**（不含 .jsonl），随 rename 更新。V1 线形会话无分支/回退需求，不需要稳定的创建 ID

**freeSessionInfoList(allocator, list)**:
```zig
pub fn freeSessionInfoList(allocator: std.mem.Allocator, list: []SessionInfo) void {
    for (list) |info| {
        allocator.free(info.id);
        allocator.free(info.name);
        allocator.free(info.file_path);
        allocator.free(info.model);
    }
    allocator.free(list);
}
```

### B6. types.zig 修改

```zig
// types.zig 修改 — Message 新增两个字段
pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    timestamp: i64 = 0,         // Unix 秒（append 时由 session 填入）
    model: ?[]const u8 = null,  // 生成此消息的模型 ID（assistant 消息非空）
};
```

- `timestamp`：由 `Session.append()` 自动填入 `self.clockNowSec()`（内部通过 `std.Io.Clock.Timestamp.now(self.io, .real).toSeconds()` 获取 Unix 秒），调用方无需设置
- `model`：assistant 消息由 `agent.zig` 在创建时填入当前模型 ID（`provider/model_id` 格式）；user/system/tool 消息为 null
- 向后兼容：两个字段都有默认值（`= 0`, `= null`），不影响已有 types.zig 测试

```zig
// types.zig 新增
pub const SessionInfo = struct {
    id: []const u8,         // 当前文件名（不含 .jsonl），随 rename 更新
    name: []const u8,       // 当前会话名称（显示用）
    file_path: []const u8,  // 当前文件路径（随 rename 变化）
    timestamp: i64,         // Unix 秒
    model: []const u8,
    msg_count: usize,       // 消息数估算值（stat.size / 150）
};
```

## C. 接口设计

### C1. Session.init()

```zig
pub fn init(allocator: std.mem.Allocator, io: std.Io, model: []const u8) !Session
```
- 初始化空会话，`path = null`，`name = "New Session"`，`modified = false`
- model 参数来自 config.resolveModel 后的 model.id

### C2. Session.load()

```zig
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Session
```
- 读取指定 JSONL 文件，重建 Session
- 设置 `path` 为传入路径，`modified = false`

### C3. Session.append()

```zig
pub fn append(self: *Session, msg: types.Message) !void
```
- **自动时间戳**：若 `msg.timestamp == 0`，自动填入 `clockNowSec()`（内部调用 `std.Io.Clock.Timestamp.now(self.io, .real).toSeconds()` 返回 Unix 秒）。调用方可预先设置（如从 JSONL 加载时恢复历史时间戳）
- **自动 model**：若 `msg.role == .assistant` 且 `msg.model == null`，自动填入 `self.model`。调用方可覆盖（如 /model 切换后）
- **内存所有权**：所有切片字段（content、model、tool_calls 中的 id/name/arguments）通过 `self._arena.allocator()` dupe，由 arena 统一管理生命周期。`deinit()` 时一次释放
- 设置 `modified = true`

### C4. Session.flush()

```zig
pub fn flush(self: *Session) !void
```
- 若 `path == null`：
  - 生成 `file_name = sanitizeFileName(self.name)`
  - 若 self.name == "New Session"（默认名）：用 `file_name = "{timestamp}"`（Unix 毫秒）
  - 若用户已 rename：用 `file_name` + `.jsonl`
  - 创建父目录 `.zagent/sessions/`（若不存在）
- 以 `createFile` 打开文件（覆盖模式）
- 写 header 行 + 全部 `messages`。null 字段不输出（手动构造 JSON）
- 写完后 `modified = false`
- 若 `messages.len > 50`：stderr 告警
- 返回前 `stderr.flush()`

### C5. 依赖方向

```
types.zig           ← Message, SessionInfo 类型
      ↑
core/session.zig    ← 不依赖 config/provider/tool/render
```

## D. 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `src/types.zig` | 修改 | Message 新增 `timestamp` + `model` 字段；新增 `SessionInfo`（含 `id`/`name`/`file_path`） |
| `src/core/session.zig` | 实现 | Session + init/load/append/flush/rename/list/deinit (~280 行) |
| `src/test.zig` | 无需修改 | 已有 `core/session.zig` import |

## E. 测试计划

| 测试 | 覆盖 |
|------|------|
| `session: init creates empty` | init 后 messages 为空，name = "New Session" |
| `session: append and retrieve` | append 后 messages() 返回正确内容 |
| `session: message pairs by adjacency` | user→assistant→tool→assistant 序列按数组顺序存储，`tool_call_id` 可关联到对应 assistant 消息的 `ToolCall.id` |
| `session: flush writes JSONL` | flush 后文件存在，内容为合法 JSONL，含 header name |
| `session: load reads JSONL` | load 后 messages 恢复，name 恢复，消息对关系保持 |
| `session: flush then load roundtrip` | 完整 roundtrip：append → flush → load → 内容一致 |
| `session: rename file` | rename 后旧文件消失，新文件存在，name 同步更新 |
| `session: messages count warning` | >50 条消息时 flush 输出 stderr 告警 |
| `session: sanitize file name` | `sanitizeFileName` 替换非法字符为 `_`，全非法→`"session"` |
| `session: rename sanitizes filename` | rename 后文件名仅含 `[a-zA-Z0-9_.-]`，self.name 保留原始值 |
| `session: list sessions` | list 返回目录下所有会话文件，msg_count 为估算值 |
| `session: empty list` | 空目录 list 返回空数组 |

> 注：flush/load/rename 测试用 `testing.tmpDir()` 创建隔离目录。

## F. 失败路径

| 场景 | 行为 |
|------|------|
| session 目录不存在 | `flush()` 时自动 `createDirPath` |
| JSONL header 行损坏或缺失 | `load()` 返回 `error.InvalidSession`，不设置 path（防止后续 flush 覆盖原文件） |
| 消息行格式损坏（load 时） | 跳过该行 + stderr 警告，继续解析后续行 |
| 消息字段缺失（load 时） | `role` 缺失 → 跳过；`content` 缺失 → 空字符串 |
| rename 目标已存在 | 追加 `-1`/`-2` 后缀直到唯一 |
| rename name 含非法字符 | `sanitizeFileName` 替换为 `_`；全非法→回退为 `"session"` |
| rename 时 path == null | 仅更新 self.name，下次 flush 用新名称创建文件 |
| rename 源不存在 | 返回 `error.FileNotFound` |
| deinit 时 modified=true | Debug 模式 `std.debug.assert(!self.modified)` 捕获 |
| flush 时磁盘满 | 返回 `error.NoSpaceLeft` |
| list() 目录不存在 | 返回空数组（非错误） |
| 消息数 > 50 | stderr 告警，不阻断 |

## G. 方案完整性

- [x] G1 字段追实际定义：`types.Message` 已在 types.zig 定义（role/content/tool_calls/tool_call_id）
- [x] G2 调用签名一致：Session API 签名与调用点对齐（App.zig 调用 session.append/session.flush/session.truncateTo；agent.zig 调用 session.append/session.messages/session.popLast）
- [x] G3 数据流贯通：App 驱动 → agent.runTurn → session.append(message) → App 检查结果 → session.flush() 或 session.truncateTo() → JSONL 文件
- [x] G4 现有设施复用：`types.Message`（已有）、`testing.allocator`（测试）
- [x] G5 交互边界：空会话、损坏文件、磁盘满、重名处理均已覆盖
- [x] G6 接口类型：B3 节 Session API 已声明
- [x] G7 假设点：`timestamp` 使用 `Io.Clock.Timestamp.now(self.io, .real)` 获取 `Io.Timestamp`，再调 `Io.Timestamp.toSeconds(raw)`（Zig 0.16 无 `Clock.Timestamp.toSeconds()` 方法）；文件名用 `Io.Timestamp.toMilliseconds(raw)`；JSON 解析使用 `parseFromSlice` + `parsed.deinit()`（非 Leaky 变体）
- [x] G8 独立可实施：仅依赖 types.zig（已完成），不依赖 config/provider/tool/render

## H. V2 优化方向（记录不实施）

| 方向 | 说明 |
|------|------|
| 精确 token 计数 | V1 用消息数估算（>50 告警），V2 用 tiktoken 或 API 返回的 usage |
| 会话搜索 | BM25/语义搜索历史会话 |
| 压缩/摘要 | 消息数超限时自动压缩旧消息 |
| 增量 flush | 追加式 JSONL 写入（非全量覆写） |
| SessionHeader 扩展 | 加 `cwd`、`provider`、`version` 字段 |

## I. 预估行数

| 文件 | 计划 | 实际 | 差异原因 |
|------|------|------|---------|
| `src/core/session.zig` | ~300 | ~848 | 含 15 个 test block（~400 行测试）、JSON 序列化/转义/ISO8601 工具函数 |
| `src/types.zig` | +20 | +16 | Message 2 字段 + SessionInfo struct |

## J. 实施偏差（记录，不复议）

| 偏差 | 计划 | 实际 | 原因 |
|------|------|------|------|
| 字段命名 | `messages` | `_messages` | Zig 不允许 struct 字段与同名方法共存 |
| deinit 断言 | `assert(!modified)` | 已移除 | 对 V1 测试过于严格，等 V2 恢复 |
| JSON 解析 | `parseFromSliceLeaky` | `parseFromSlice` + `deinit` | Zig 0.16 中 Leaky 变体行为：`Parsed.deinit()` 不释放内部 arena，改用标准变体显式释放 |
| writeHeader | 无 allocator 参数 | 添加 allocator 参数 | 原设计使用 `std.testing.allocator` 写 header（生产环境不可用），改为由调用方传递 |
| 目录切换 | `std.Io.Threaded.chdir` | `std.process.setCurrentPath` | Threaded.chdir 需 libc 链接，改用纯 Zig 实现 |
| 文件重命名 | `Io.Dir.renameAbsolute` | `Io.Dir.rename` | 路径为相对路径（`.zagent/sessions/`），renameAbsolute 要求绝对路径会 assert 失败 |
| errdefer 泄漏保护 | 无 | `init()`/`load()` 均加 `errdefer arena.deinit()` | zig-reviewer C-01/C-02 审查发现 |
| 测试 number | 计划 12 | 实际 15 | 新增：append auto-fills timestamp/model、load invalid file、load skips bad lines |
