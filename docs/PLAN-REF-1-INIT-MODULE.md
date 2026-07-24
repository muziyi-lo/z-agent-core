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

### 2. 初始化入口

```zig
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: struct {
        project_root: ?[]const u8 = null,    // 显式指定 / env ZAGENT_ROOT / CWD 查找
        model_override: ?[]const u8 = null,
        phase_writer_cb: ?provider_mod.PhaseWriterCb = null,
    },
) !FrontendState
```

CLI 和 Web 都调用同一函数，区别仅在 `phase_writer_cb` 不同（CLI → ANSI 渲染，Web → SSE 映射）。

### 3. .env 注入

`Provider.init` 从 `std.process.Environ` 读取 API key。当前 `loadDotEnv` 只返回 HashMap 不注入。修复方案：

| 方案 | 优点 | 缺点 |
|------|------|------|
| A: `init()` 内遍历 HashMap → `std.process.setEnv()` | 简单，不改 provider | Windows setEnv 不支持（0.16 无此 API） |
| B: `init()` 内构建 `Environ.map` 传给 `Provider.init` 新参数 | 平台无关 | 需改 Provider 接口 |
| C: `init()` 遍历 HashMap → 写入 `std.process.Environ.initFrom` | 符合 0.16 API | 需验证签名 |

**选择**：方案 C。在 `init()` 中创建一个包含系统环境和 .env 合并值的 `Environ`，`Provider.init` 不变（仍读 Environ）。若 0.16 不支持 environ 合并，降级为方案 B（给 Provider 加可选 `env: ?[]const u8` 参数）。

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

## 实施

### 步骤 1: 创建 `src/frontends/init.zig`

**新建**，包含 `FrontendState` struct + `init()` 函数 + `InitError` 枚举 + `formatInitError()`。

管线顺序（从 CLI App.zig:97-175 提取）：
1. resolve project_root (参数 → ZAGENT_ROOT env → findZagentRoot → CWD)
2. `Config.load`
3. `loadDotEnv` → 注入 env（新增）
4. `resolveModel`
5. find provider entry
6. `Provider.init`
7. `buildRegistry`
8. `Session.init`
9. `session_dir = join(project_root, ".zagent", "sessions")`
10. `session_mod.list` (失败返回空列表)

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
| `zig build run` (CLI, 无 API key) | `Error: DEEPSEEK_API_KEY environment variable not set`，无栈回溯 |
| `zig build run -- --web` (无 API key) | 同上消息，无栈回溯 |
| `zig build run` (CLI, API key 已设) | 正常启动 REPL |
| `zig build run -- --web` (API key 已设) | 正常启动 HTTP 服务 |
| `.zagent/.env` 含 `DEEPSEEK_API_KEY=sk-xxx` | Provider.init 能读到 key（无需 shell export） |
| `init.zig test` | 4 个 test blocks 全部 pass |

## 风险

| 风险 | 概率 | 缓解 |
|------|------|------|
| 0.16 `std.process.Environ` 不支持写入 | 中 | 降级为方案 B：给 Provider.init 加可选 `env_values: ?std.StringArrayHashMapUnmanaged([]const u8)` 参数 |
| `session_mod.list` 调用 allocator 与 `gpa` arena 冲突 | 低 | list 使用调用方传入的 allocator，验证一致 |
| CLI AGENTS.md 读取逻辑耦合进 init.zig | 无 | 保留在 App.zig，init.zig 不含前端特有逻辑 |

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
