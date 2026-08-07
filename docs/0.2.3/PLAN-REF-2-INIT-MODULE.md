# Plan REF-2: 抽取共享初始化模块 `frontends/init.zig`

## 状态: 已完成

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| PHASE-7 Web MVP | ✅ 已完成 | 本方案 |
| PLAN-REF-1 (PhaseWriterCb per-call 化) | ✅ 已完成 | ~~本方案~~ (REF-1 同步完成) |

## 问题

**现象**：CLI `App.zig` 和 Web `server.zig` 各自内联 ~60 行近相同的初始化管线（findRoot → loadConfig → resolveModel → findProvider → Provider.init → buildRegistry → Session.init），每次新增前端都会复制并劣化错误提示。

**根因**：无共享初始化模块。`loadDotEnv` 解析 `.zagent/.env` 后丢弃结果，.env 值从未注入进程环境。

## 概览

- **改动范围**：1 个新文件 `src/frontends/init.zig` + 修改 CLI/Web 各约 -40 行
- **核心思路**：将 provider/config/env/session 初始化管线抽入 `FrontendState` struct，两个前端各调用一次 `try init.zig.init()`，接收统一的结构化错误
- **附带修复**：.env 值在 provider init 之前注入 `std.process.Environ`，使 `.zagent/.env` 文件实际生效

## 设计要点

### 1. FrontendState 结构

```zig
pub const FrontendState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config: config_mod.Config,
    provider: provider_mod.Provider,
    registry: registry_mod.Registry,
    session: session_mod.Session,
    session_dir: []const u8,

    pub fn deinit(self: *FrontendState) void { ... }
};
```

`session_list` 不在 struct 中——改为惰性加载（见设计要点 6），避免数据陈旧和额外的 deinit 清理。

**字段引用稳定约束**：`init()` 返回后，所有字段的**指针/引用不重新绑定**（即不执行 `state.provider = newProvider`）。`provider` 内部的 `_stream_options_retried` 和 `session` 的 `_messages` 在运行时自然变更——这些属于引用目标自身的内部状态，不违反 `FrontendState` 字段级的引用稳定性。`deinit()` 是唯一例外，仅在进程退出时调用一次。

**deinit 清理链**：

```zig
pub fn deinit(self: *FrontendState) void {
    self.config.deinit();                              // 内部 arena
    self.session.deinit();                             // 内部 arena + messages
    self.allocator.free(self.session_dir);             // join() 分配的路径字符串
    self.allocator.free(self.project_root);            // init 内 dupe 的副本
}
```

不需要清理的字段（由 `self.allocator` arena 统一回收）：
- `provider` — 仅有 api_key 字符串由 arena 分配，无独立 deinit
- `registry` — handlers 全是编译期常量，无堆分配
- `project_root` — 由 init() 内部 dupe，deinit 中 allocator.free 释放，不依赖调用方生命周期

**project_root 所有权**：`init()` 始终内部 `allocator.dupe(u8, ...)` 一份副本，不直接持有调用方传入的切片。即使调用方传入栈上字符串（如 `--root` CLI 参数、`environ_map.get` 返回值），`FrontendState` 生命周期也不依赖外部。

调用方的 `gpa_alloc.deinit()` 作为最终防线回收剩余内存。

### 2. 初始化入口

```zig
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: struct {
        project_root: ?[]const u8 = null,
        api_key_override: ?[]const u8 = null,   // CLI --api-key
    },
) !FrontendState
```

CLI 和 Web 都调用同一函数。`PhaseWriterCb` 不在此处传入——REF-1 已将其改为 per-turn 参数（`agent.runTurn(tool_cb, phase_cb)`），前端在每次 `runTurn` 调用时自行创建（CLI → `pwBeginPhase` 等，Web → `sse.createPhaseWriter`）。

初始化管线顺序：
1. resolve project_root（`init()` 内部 `dupe` 一份——切断调用方生命周期依赖）
2. `Config.load`
2. `Config.load`
3. `loadDotEnv` → 密钥解析（`api_key_override` > shell env > .env > ApiKeyNotSet）
4. `resolveModel`
5. find provider entry
6. `Provider.init`
7. `buildRegistry`
8. `Session.init`
9. `session_dir = join(project_root, ".zagent", "sessions")`

### 3. .env 注入与 API key 加载优先级

`Provider.init` 从 `std.process.Environ` 读取 API key。当前 `loadDotEnv` 只返回 HashMap 不注入。修复方案：

**加载优先级**（高到低）：
1. Shell 环境变量（`$env:DEEPSEEK_API_KEY = "sk-..."` ）— **最高优先级**
2. `.zagent/.env` 文件中的值 — 仅在系统环境不存在时注入
3. 无任何来源 → `error.ApiKeyNotSet`

**实现**：`init()` 在调用 `Provider.init` 之前完成密钥解析，按优先级逐层检查。不走 OS 环境变量注入（Zig 0.16 `std.process` 只有读 API，无跨平台 `setenv`），改为将解析结果作为参数直接传递：

```
1. opts.api_key_override  →  使用该值
2. shell 环境变量已存在     →  从 environ_map 读取
3. .zagent/.env 有值        →  从 loadDotEnv HashMap 读取
4. 全部为空                  →  返回 error.ApiKeyNotSet (附带 env var 名称)
```

**Provider 接口扩展**：新增可选字段 `explicit_key: ?[]const u8`，优先级高于 Environ 读取。

```zig
// Provider.Config 新增
explicit_key: ?[]const u8 = null,

// Provider.init 内部
const key_raw = if (config.explicit_key) |k| k else blk: {
    var env = std.process.Environ{ .block = .{ .use_global = true } };
    var map = try env.createMap(allocator);
    defer map.deinit();
    break :blk map.get(config.api_key_env) orelse return error.ApiKeyNotSet;
};
```

`init.zig.init()` 解析密钥后设置 `Config.explicit_key`，Provider 内部优先使用。**零平台依赖**，Windows/Linux/macOS 行为一致。

### 5. 临时 Arena 隔离

`init()` 内部有两类分配：**持久分配**（`session_dir`，需伴随 `FrontendState` 全生命周期）和**临时分配**（`loadDotEnv` 的 HashMap 键值对、中间路径拼接等）。

如果一律使用调用方传入的 `allocator`（server-lifetime arena），临时数据永不释放。解决方案：`init()` 内创建子 arena 专门处理临时分配：

```zig
pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: ...) !FrontendState {
    var tmp = std.heap.ArenaAllocator.init(allocator);
    defer tmp.deinit();
    const ta = tmp.allocator();

    // 临时分配——使用 ta
    const dotenv_map = config_mod.loadDotEnv(ta, project_root, io) catch ...;
    // loadDotEnv 的 key/value dupe、env_path、content 全部在 ta 上
    // tmp.deinit() 时统一释放

    // 持久分配——使用 allocator
    const session_dir = try std.fs.path.join(allocator, &.{ ... });
    // ...
}
```

**效果**：无论 `init()` 成功还是中途失败，临时分配的内存由 `defer tmp.deinit()` 保证释放。`FrontendState` 只持有持久分配，`deinit()` 无需关心临时数据。

### 6. session_list 惰性加载

不在 `init()` 中加载 session 列表，改为按需调用：

```zig
pub fn loadSessionList(state: *const FrontendState) ![]types.SessionInfo {
    return session_mod.list(state.allocator, state.io, state.session_dir);
}
```

调用方（Web handler 的 `GET /api/session`）每次请求时调用 `loadSessionList`，用完 `freeSessionInfoList` 释放。CLI 的 `/list` 命令同理。

**理由**：
- **数据一致性**：`POST /api/session` 创建新 session 后，下次 list 请求返回最新数据，无需刷新机制
- **启动速度**：init 阶段不扫描 `.zagent/sessions/` 目录
- **简化 deinit**：`session_list` 不在 `FrontendState` 中，少 1 个字段 + 1 行清理

### 4. 错误处理统一

当前每个前端手动 `catch` + `stderr.write`。改为 `init()` 返回结构化 Error：

```zig
pub const InitError = error{
    NoProjectRoot,
    ConfigLoadFailed,
    ModelResolveFailed,
    ProviderNotFound,
    ApiKeyNotSet,
};

pub fn formatInitError(
    buf: []u8,
    err: InitError,
    ctx: struct { api_key_env: ?[]const u8, model_spec: ?[]const u8 },
) ![]const u8 {
    return switch (err) {
        error.NoProjectRoot => std.fmt.bufPrint(buf, "z-agent-core: error: cannot resolve project root", .{}),
        error.ConfigLoadFailed => std.fmt.bufPrint(buf, "z-agent-core: error: cannot load config", .{}),
        error.ModelResolveFailed => if (ctx.model_spec) |s|
            std.fmt.bufPrint(buf, "z-agent-core: error: cannot resolve model '{s}'", .{s})
        else
            std.fmt.bufPrint(buf, "z-agent-core: error: cannot resolve default model", .{}),
        error.ProviderNotFound => if (ctx.model_spec) |s|
            std.fmt.bufPrint(buf, "z-agent-core: error: provider for '{s}' not found", .{s})
        else
            std.fmt.bufPrint(buf, "z-agent-core: error: provider not found", .{}),
        error.ApiKeyNotSet => if (ctx.api_key_env) |env|
            std.fmt.bufPrint(buf, "z-agent-core: Error: {s} environment variable not set", .{env})
        else
            std.fmt.bufPrint(buf, "z-agent-core: Error: API key not set", .{}),
    };
}
```

**缓冲区大小**：定义常量 `pub const init_error_max_len = 256;`，确保最坏情况（`ModelResolveFailed` + 长模型名 `provider/long-model-id`）可容纳。`bufPrint` 返回 `error.NoSpaceLeft` 时调用方应增大缓冲区。

```zig
pub const init_error_max_len = 256;

pub fn formatInitError(
    buf: []u8,
    err: InitError,
    ctx: struct { api_key_env: ?[]const u8, model_spec: ?[]const u8 },
) ![]const u8 {
```

**内存所有权**：调用方提供栈缓冲区（`[init_error_max_len]u8`），`formatInitError` 将格式化结果写入 `buf`。返回的切片指向调用方缓冲区，不涉及堆分配。调用方用完即丢弃。

调用侧的典型用法：
```zig
var buf: [init.init_error_max_len]u8 = undefined;
const msg = try init.formatInitError(&buf, err, .{ .api_key_env = entry.api_key_env, .model_spec = cfg.default_model });
printStderr(io, msg);
```

### 5. CLI App 精简

当前 `App.init()` 约 90 行 (95-184)，包含 AGENTS.md 读取 + init 管线。改造后 `App.init()` 只保留 AGENTS.md 读取 + `try init.zig.init()` + 版本横幅打印。~90 行 → ~30 行。

Web `server.zig.main()` 同样精简，`main()` 总长从 ~115 行 → ~60 行。

## 不做

- 不改 `session.zig` / `config.zig` 核心模块
- 不引入 DI 容器或接口抽象（过度设计）
- 不修改 `main.zig`（4 行 shim 不变）
- 不移除 `loadDotEnv` 函数（保持向后兼容，后续清理）
- 不走 OS 级环境变量注入（Zig 0.16 无跨平台 setenv，方案改为参数直传）

## API Key 加载架构决策

参见 `docs/api-key-loading-comparison.md` 对 5 个 agent 项目的横向对比。以下逐项说明本方案吸收和放弃的原因，均以 zAgentCore 的定位（单二进制、单用户、零运行时依赖、127.0.0.1 本地）为基础。

### 吸收

| 项目 | 特性 | 采纳理由 | 对应设计 |
|------|------|---------|---------|
| **pi-repos** | 3 层优先级：CLI flag > auth 文件 > env var | 清晰可预测，CI/CD 友好。shell env 覆盖 `.env` 文件是行业标准（Docker、dotenv） | 优先级链：shell env > `.zagent/.env` > error |
| **DeepSeek-Reasonix** | Config 仅引用 env var 名（`api_key_env`），不存 key 值 | TOML 配置可安全共享/提交。我们已有 `api_key_env = "DEEPSEEK_API_KEY"` 实现 | 已具备，无需改动 |
| **pi-repos** | CLI `--api-key` 运行时覆盖 | 临时测试、CI/CD 管道一次性注入，不污染 env | 本方案新增（`opts.api_key_override: ?[]const u8`） |
| **opencode** | 启动时校验 `MissingCredentialError`，清晰提示缺失哪个 env var | 用户启动后立即知道缺什么，而非请求时才报错 | `formatInitError` 返回具体 env var 名 |
| **pi-repos** | `auth.json` 作为本地凭据存储 | 单文件、JSON 格式、用户主目录隔离。`.zagent/.env` 等价于此角色 | 保留 `.env` 格式（更简单，无 JSON 解析成本） |

### 放弃

| 项目 | 特性 | 放弃理由 |
|------|------|---------|
| **nullclaw** | ChaCha20-Poly1305 加密存储 | 单用户本地 dev tool，无共享密钥场景。加密 key 与数据同目录时安全收益为零（调研文档已指出此缺陷） |
| **nullclaw** | Key 轮换 (`reliability.api_keys[]`) | 单 API 调用序列，rate limit 由 provider 5× 指数退避已覆盖。多 key 轮换增加配置复杂度 |
| **nullclaw** | 6 层 fallback 链 | 过设计——我们只有 1 个 provider (DeepSeek)，45+ env var 映射表无意义 |
| **pi-repos** | `!command` shell 插值 | 安全风险。允许配置触发任意命令执行，单用户场景也用不到密码管理器集成 |
| **opencode** | 8 层配置发现 (remote→global→project→MDM) | 我们无远程配置、无 MDM 管理、无工作区层级。3 层已够（CLI arg > env > file） |
| **opencode** | OAuth 浏览器流 | 无 provider 支持 OAuth。当前仅 API key 模式 |
| **oh-my-openagent** | 全委托模式（零 key 管理） | 我们是 standalone 二进制，无上层 harness 可委托 |
| **pi-repos** | `proper-lockfile` 文件锁 | 单进程运行，`.env` 只读一次，无并发写入竞争 |

### 延后

| 特性 | 理由 |
|------|------|
| `{env:}` / `{file:}` 配置值内联插值 | 需扩展 TOML 解析器。当前 `api_key_env` 间接引用已满足需求 |
| Provider 级 env var 映射表（多 provider 场景） | 当前仅 DeepSeek。多 provider 时基于 `api_key_env` 字段自动映射即可 |

## 实施

### 步骤 1: 创建 `src/frontends/init.zig`

**新建**，包含 `FrontendState` struct + `init()` 函数 + `InitError` 枚举 + `formatInitError()`。

管线顺序（从 CLI App.zig:97-175 提取，移除 session_mod.list）：
1. resolve project_root (参数 → ZAGENT_ROOT env → findZagentRoot → CWD)
2. `Config.load`
3. `loadDotEnv` → 解析 .env 到 HashMap（临时 arena）
4. **密钥解析**（新增核心逻辑）：`api_key_override` → shell env → .env → `ApiKeyNotSet`
5. `resolveModel`
6. find provider entry
7. `Provider.init`（`explicit_key` 设值后 Environmental 回退）
8. `buildRegistry`
9. `Session.init`
10. `session_dir = join(project_root, ".zagent", "sessions")`

### 步骤 2: 修改 `src/frontends/cli/App.zig`

- `App.init()` 调用 `init.zig.init()`
- 保留 AGENTS.md 读取（CLI 特有）
- 保留版本横幅（CLI 特有）
- 移除内联的 findRoot/config/provider/registry/session 初始化

### 步骤 3: 修改 `src/frontends/web/server.zig`

- `server.main()` 调用 `init.zig.init()`
- 移除内联的初始化管线
- 使用 `init.zig.formatInitError()` 格式化错误消息
- 保留 `--root` CLI 参数解析（Web 特有）

### 步骤 4: 添加测试

在 `init.zig` 末尾添加 test blocks：
- `init without API key returns ApiKeyNotSet`
- `init with env var succeeds`
- `init with explicit root`
- `deinit cleans up`

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache
```

| 测试场景 | 预期结果 |
|----------|----------|
| `zig build run` (CLI, 无任何 key 来源) | `Error: DEEPSEEK_API_KEY environment variable not set`，无栈回溯 |
| `zig build run -- --api-key sk-test` (shell 无 key) | **正常启动**（CLI 参数注入 env，Provider 能读到） |
| `zig build run -- --web` (无 key) | `Error: DEEPSEEK_API_KEY environment variable not set`，服务不启动 |
| `zig build run -- --web --api-key sk-test` (shell 无 key) | **正常启动** HTTP 服务 |
| shell 有 `DEEPSEEK_API_KEY=sk-shell`，`--api-key sk-cli` | **CLI 参数值生效**（最高优先级） |
| `.zagent/.env` 含 `DEEPSEEK_API_KEY=sk-dotenv`，shell 无 key | **.env 值生效**（注入 env 后 Provider 读取） |
| shell 有 key + .env 也有 key | **shell 值生效**（已存在不覆盖） |

## 风险

| 风险 | 概率 | 缓解 |
|------|------|------|
| `session_mod.list` 调用 allocator 与 `gpa` arena 冲突 | 低 | list 使用调用方传入的 allocator |
| CLI AGENTS.md 读取逻辑耦合进 init.zig | 无 | 保留在 App.zig，init.zig 不含前端特有逻辑 |
| `--api-key` 传入了但 init() 在 Provider.init 前过早报错 | 已修复 | 密钥解析在步骤 4（Provider.init 之前），四个来源依次检查 |
| `explicit_key` 与 Provider 内部 Environ 读取冲突 | 低 | `explicit_key` 优先级最高，非 null 时跳过 Environ 读取，逻辑互斥 |
| `--api-key` CLI 参数同时有不同前端使用方式 | 无 | CLI 通过 `opts.api_key_override` 传入，Web 通过同字段传入，`init()` 不区分来源 |
| Provider.Config 新增 `explicit_key` 字段后所有构造点需同步 | 低 | 当前仅 `init.zig` 和 provider 测试构造 Config，两处同步更新 |
| 调用方传入栈上 `project_root` 导致悬垂指针 | 已修复 | `init()` 内部 `dupe` 一份副本，切断对调用方生命周期的依赖 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/init.zig` | 新建 | 否 |
| `src/io/provider.zig` | Provider.Config 新增 `explicit_key: ?[]const u8` 字段 | 否（新增可选字段，默认 null） |
| `src/frontends/cli/App.zig` | `init()` 精简 ~60 行，调用 init.zig | 否 |
| `src/frontends/web/server.zig` | `main()` 精简 ~40 行，调用 init.zig | 否 |
| `src/test.zig` | 新增 `_ = @import("frontends/init.zig");` | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| FrontendState | 前端初始化产物打包结构，含 config/provider/registry/session |
| .env 注入 | 将 `.zagent/.env` 文件的键值对写入 OS 进程环境，使 `Provider.init` 透过 `std.process.Environ` 可见 |
| init 管线 | findRoot → config.load → resolveModel → findProvider → Provider.init → buildRegistry → Session.init 的 8 步顺序链 |

## 偏差（实施 vs 计划）

| # | 计划 | 实施 | 原因 |
|---|------|------|------|
| 1 | `err: InitError` (类型化错误) | `err: anyerror` (通过 `@errorName` 字符串匹配) | Zig 0.16 catch 捕获的错误集不能缩窄到 InitError |
| 2 | `ctx: struct { api_key_env, model_spec }` 单参数 | `api_key_env, model_spec` 两个平参数 | 简化调用侧 |
| 3 | `Provider.Config.explicit_key` 字段 | 未实现 — Provider 仍从 Environ 读 key | 未实现，延后 |
| 4 | `.env` 注入 + 4 层 key 解析链 | `loadDotEnv` 结果被 `_ =` 丢弃 | 未实现，延后 |
| 5 | `api_key_override` 由 CLI `--api-key` 传入 | 始终传 null | CLI `--api-key` 参数未实现 |
| 6 | CLI App.init() 90→30 行 | 当前 79 行 (保留了 AGENTS.md/版本横幅/工具分配) | 后续精简 |

## 设计前瞻（延后至 Web 会话管理重构）

当前 `FrontendState` 包含 `session`，隐含"服务生命周期单默认会话"假定。Web 多会话场景下，更优拆分：

```zig
FrontendConfig { config, provider, registry }  // 全局只读，纤程安全
FrontendState  { config: *FrontendConfig, session }  // 每请求创建，消息隔离
```

此拆分超出 REF-2"抽取初始化"范围（REF-2 不改 session 管理模型），但为后续 Web 会话重构预留了清晰的分界点。
