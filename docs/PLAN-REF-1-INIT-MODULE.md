# Plan REF-1: 抽取共享初始化模块 `frontends/init.zig`

## 状态: 计划中

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| PHASE-7 Web MVP | ✅ 已完成 | 本方案 |

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
    session_list: []const types.SessionInfo,

    pub fn deinit(self: *FrontendState) void { ... }
};
```

所有初始化产物打包为一个 struct，调用方 `defer state.deinit()` 统一清理。

**deinit 清理链**——逐字段清单，确保无遗漏：

```zig
pub fn deinit(self: *FrontendState) void {
    self.config.deinit();                              // 内部 arena
    self.session.deinit();                             // 内部 arena + messages
    self.allocator.free(self.session_dir);             // join() 分配的路径字符串
    session_mod.freeSessionInfoList(self.allocator, self.session_list); // list 结果
}
```

不需要清理的字段（由 `self.allocator` arena 统一回收）：
- `provider` — 仅有 api_key 字符串由 arena 分配，无独立 deinit
- `registry` — handlers 全是编译期常量，无堆分配
- `project_root` — 由调用方 allocator 分配，与 FrontendState 共享生命周期

调用方的 `gpa_alloc.deinit()` 作为最终防线回收剩余内存。

### 2. 初始化入口

```zig
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: struct {
        project_root: ?[]const u8 = null,
        api_key_override: ?[]const u8 = null,   // CLI --api-key
        phase_writer_cb: ?provider_mod.PhaseWriterCb = null,
    },
) !FrontendState
```

CLI 和 Web 都调用同一函数，区别仅在 `phase_writer_cb` 不同（CLI → ANSI 渲染，Web → SSE 映射），CLI 额外传入 `api_key_override`（来自 `--api-key` 参数）。

初始化管线顺序：
1. resolve project_root
2. `Config.load`
3. `loadDotEnv` → 按优先级注入 API key：`api_key_override` > shell env > `.zagent/.env` > error
4. `resolveModel`
5. find provider entry
6. `Provider.init`
7. `buildRegistry`
8. `Session.init`
9. `session_dir` + `session_mod.list`

### 3. .env 注入与 API key 加载优先级

`Provider.init` 从 `std.process.Environ` 读取 API key。当前 `loadDotEnv` 只返回 HashMap 不注入。修复方案：

**加载优先级**（高到低）：
1. Shell 环境变量（`$env:DEEPSEEK_API_KEY = "sk-..."` ）— **最高优先级**
2. `.zagent/.env` 文件中的值 — 仅在系统环境不存在时注入
3. 无任何来源 → `error.ApiKeyNotSet`

**实现**：`init()` 在调用 `Provider.init` 之前完成密钥解析，按优先级逐层检查：

```
1. opts.api_key_override  →  注入 env（Provider.init 通过 Environ 可见）
2. shell 环境变量已存在     →  跳过（不覆盖）
3. .zagent/.env 有值        →  注入 env
4. 全部为空                  →  返回 error.ApiKeyNotSet
```

关键：解析逻辑放在 `init()` 中（而非 Provider 内部），保证 CLI `--api-key` 和 `.env` 文件在 Provider 读取环境变量之前已被注入。Provider.init 签名不变（仍从 Environ 读取），`init()` 负责确保 Environ 中存在所需值。

| 方案 | 优点 | 缺点 |
|------|------|------|
| A: `init()` 内遍历 HashMap → `std.process.setEnv()` | 简单 | Windows 0.16 无 setEnv |
| B: `init()` 内构建合并 `Environ`，传给 `Provider.init` 新参数 | 平台无关 | 需改 Provider 接口 |
| C: 遍历 HashMap，系统环境已存在则跳过，否则注入 | 不覆盖已有值 | 需验证 0.16 环境写入 API |

**选择**：方案 C，降级路径为方案 B。

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

pub fn formatInitError(err: InitError, ctx: struct { api_key_env: ?[]const u8, model_spec: ?[]const u8 }) []const u8 {
    return switch (err) {
        error.NoProjectRoot => "cannot resolve project root",
        error.ConfigLoadFailed => "cannot load config",
        error.ApiKeyNotSet => if (ctx.api_key_env) |env| ... else "API key not set",
        ...
    };
}
```

调用方只负责打印，不再各自实现错误文案。

### 5. CLI App 精简

当前 `App.init()` 约 90 行 (95-184)，包含 AGENTS.md 读取 + init 管线。改造后 `App.init()` 只保留 AGENTS.md 读取 + `try init.zig.init()` + 版本横幅打印。~90 行 → ~30 行。

Web `server.zig.main()` 同样精简，`main()` 总长从 ~115 行 → ~60 行。

## 不做

- 不改 `provider.zig` / `session.zig` / `config.zig` 核心模块
- 不引入 DI 容器或接口抽象（过度设计）
- 不修改 `main.zig`（4 行 shim 不变）
- 不移除 `loadDotEnv` 函数（保持向后兼容，后续清理）

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

管线顺序（从 CLI App.zig:97-175 提取）：
1. resolve project_root (参数 → ZAGENT_ROOT env → findZagentRoot → CWD)
2. `Config.load`
3. `loadDotEnv` → 解析 .env 到 HashMap
4. **密钥解析**（新增核心逻辑）：`api_key_override` → shell env → .env → `ApiKeyNotSet`
5. `resolveModel`
6. find provider entry
7. `Provider.init`（此时 Environ 中已有 key，步骤 4 保证）
8. `buildRegistry`
9. `Session.init`
10. `session_dir = join(project_root, ".zagent", "sessions")`
11. `session_mod.list` (失败返回空列表)

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
| 0.16 `std.process.Environ` 不支持写入 | 中 | 降级：Provider.init 新增可选参数 `explicit_key: ?[]const u8`，`init()` 直接传入解析后的 key，绕过 Environ |
| `session_mod.list` 调用 allocator 与 `gpa` arena 冲突 | 低 | list 使用调用方传入的 allocator |
| CLI AGENTS.md 读取逻辑耦合进 init.zig | 无 | 保留在 App.zig，init.zig 不含前端特有逻辑 |
| `--api-key` 传入了但 init() 在 Provider.init 前过早报错 | 已修复 | 密钥解析在步骤 4（Provider.init 之前），四个来源依次检查后注入 Environ |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/init.zig` | 新建 | 否 |
| `src/frontends/cli/App.zig` | `init()` 精简 ~60 行，调用 init.zig | 否 |
| `src/frontends/web/server.zig` | `main()` 精简 ~40 行，调用 init.zig | 否 |
| `src/test.zig` | 新增 `_ = @import("frontends/init.zig");` | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| FrontendState | 前端初始化产物打包结构，含 config/provider/registry/session |
| .env 注入 | 将 `.zagent/.env` 文件的键值对写入 OS 进程环境，使 `Provider.init` 透过 `std.process.Environ` 可见 |
| init 管线 | findRoot → config.load → resolveModel → findProvider → Provider.init → buildRegistry → Session.init 的 8 步顺序链 |
