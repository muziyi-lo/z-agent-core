# Plan FIX-APIKEY-ENV: API Key 解析修复（空值误判 + .env 死代码）

## 状态: ✅ 已完成（v0.2.5，REMAINING 已标记）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 不做

- **不修改报错文案**：`main.zig:122` / `server.zig:123` 调用 `reportInitError` 时传 `api_key_env = null`，仍显示通用 `API key not set`。已在讨论中确认不需要 `DEEPSEEK_API_KEY environment variable not set` 这类具体提示。
- **不扫描全部 provider 硬报错**：启动只要求默认模型所用 provider 的 key 可用，其他 provider 调用时才报错。不新增"启动时列出缺失 key 的 provider"清单。
- **不清理 `api_key_override` 死字段**：`init.zig:44` 声明但从未使用的 `opts.api_key_override`，以及 `App.zig:99` 传的 `null`，属独立清理项，不在本方案范围。
- **不注入进程环境**：Zig 0.16 `std.process.Environ` 只读，无 `setEnv/putEnv` API；不采用 OS 级 `kernel32.SetEnvironmentVariableA` 注入方案（见设计要点 2）。
- **不把 .env 格式错误升级为硬错误**：`loadDotEnv` 从不返回 `error.ParseError`（该错误仅存在于 `toml.zig:17`）；评审误判为"被 catch 吞掉的 ParseError"，实际是格式错误被静默跳过。本方案改为逐行 warning（见设计要点 5），不返回 `ParseError`——若返回，`init.zig:64` 的 catch 会因一行坏文件丢弃全部 .env 配置。

## 问题

**现象**：
1. 环境变量存在但值为空（如 `DEEPSEEK_API_KEY=`）时，启动不报错，直到 HTTP 401 才失败——报错时机错误。
2. `.zagent/.env` 中设置 key 后，启动仍报 `z-agent-core: Error: API key not set`——.env 配置无效。

**根因**：
1. `provider.zig:65` 用 `map.get(...) orelse` 判缺失，只拦截 null，不拦截空字符串。
2. `init.zig:64` 把 `loadDotEnv` 解析结果用 `_ =` 直接丢弃。`PLAN-REF-2`（0.2.3）第 22 行宣称"修复 .env 值注入进程环境使其生效"，但该附带修复**从未在代码中落地**——`std.process.Environ` 在 Zig 0.16 是只读的，注入本就不可能实现，代码也从未更新。
3. `loadDotEnv`（`config.zig:105-140`）对格式错误行（无 `=`、空 key、未闭合引号）**静默跳过**，零提示——评审补充点，本次一并修复为逐行 warning。

## 概览

- **改动范围**：3 个源文件修改，无新增文件。
  - `src/config.zig` — 新增 `resolveApiKey` + `loadDotEnv` 格式校验告警（配置读取层，`loadDotEnv` 同处）。
  - `src/io/provider.zig` — `Provider.init` 移除内部 env 读取，改为接收已解析的 `api_key`。
  - `src/frontends/init.zig` — 编排：保留 `.env` map + 构建进程 env map → `resolveApiKey` → 传给 `Provider.init`。
- **核心思路**：**配置读取分层**（评审意见）。key 的来源解析（进程环境优先、.env 回退、空值视为未设）全部收敛在配置层 `config.resolveApiKey`；`Provider` 只接收最终解析出的 key 字符串，**完全不知道 `.env` 乃至环境变量的存在**。顺带修复 `loadDotEnv` 对格式错误静默跳过的问题（评审补充）。
- **参考实现**：无外部参考；沿用项目既有 `Environ.Map` 读取模式（`provider.zig:61-67`）与 `loadDotEnv` 解析（`config.zig:88-143`）。

## 设计要点

### 1. 空值语义：空字符串 == 未设

| 方案 | 优点 | 缺点 |
|------|------|------|
| A. 空值视为配置错误，单独报错 | 语义精确 | 无法区分"故意为空"与"遗留空值"；需新增错误类型，扩大改动面 |
| B. 空值视为未设，走同一回退链 | 一行逻辑，统一处理 | 语义上"空"与"缺失"不区分 |

**选择**：方案 B。`DEEPSEEK_API_KEY=`（空值）几乎必然是遗留或笔误，视为未设并回退 .env 是最大宽容路径；若进程环境与 .env 都为空，则返回 `error.ApiKeyNotSet`，与现有报错行为完全一致。

**行为对比**：

```
当前: DEEPSEEK_API_KEY=（空） → 启动通过 → 请求时 HTTP 401
实施后: DEEPSEEK_API_KEY=（空） → 启动报 error.ApiKeyNotSet（.env 有值则回退成功）
```

### 2. .env 生效方式：配置层解析，Provider 只接收结果

| 方案 | 优点 | 缺点 |
|------|------|------|
| A. 把 .env map 作为回退源传入 `Provider.init`（原方案） | 改动集中在 provider | Provider 知晓 `.env` 概念，io 层耦合配置文件机制；评审否决 |
| B. `config.resolveApiKey` 统一解析（进程 env → .env 回退），`Provider.init` 只接收 key | 分层清晰：配置层管来源，Provider 只管使用 | 改动跨 3 文件；`Provider.init` 签名变化 |

**行为对比**：

```
当前: .env 有 DEEPSEEK_API_KEY → 解析后丢弃 → 启动报 API key not set
实施后: .env 有 DEEPSEEK_API_KEY → 配置层回退命中 → Provider 拿到 key → 正常启动
```

**选择**：方案 B。关键事实支撑：API key 是直接拼进 `Authorization: Bearer <key>` HTTP 头（`provider.zig:169`）传给 curl 的，**不依赖 curl 子进程环境**，因此解析只需进程内完成。方案 B 同时满足评审要求——`Provider` 的职责收敛为"用 key 发请求"，不再涉足任何环境/文件来源。

### 3. 解析优先级与大小写语义

解析规则（`config.zig` 新增 `resolveApiKey`，与 `loadDotEnv` 同居配置读取层）：

```
key = 进程环境.get(env_name)
      若缺失或空 → .env 回退源.get(env_name)
      若仍缺失或空 → error.ApiKeyNotSet
```

**大小写差异接受**：进程环境 `Environ.Map` 在 Windows 用不区分大小写的哈希（`Environ.zig:107-128`）；`.env` 的 `StringArrayHashMapUnmanaged` 用默认区分大小写哈希。即 Windows 下进程环境 `deepseek_api_key` 可匹配 `api_key_env = "DEEPSEEK_API_KEY"`，但 `.env` 必须精确同名。这是平台语义的正常差异，接受并在测试中固定大写规范。

### 4. 生命周期与所有权

- `resolveApiKey` 返回**借用切片**（指向 `env_map` 内部副本或 `.env` arena 值）；`Provider.init` 立即 `allocator.dupe` 拷贝持有，provider 拥有自己的副本。全链路**仅一次分配**（Provider 侧 dupe），resolveApiKey 无分配。
- **`Environ.Map` 拥有全部键值副本**（`put` 执行 `gpa.dupe`：`Environ.zig:259,268`；`deinit` 释放全部：`Environ.zig:168-174`），`get` 返回 map 内部副本、`deinit` 后失效（`Environ.zig:281-283`）。
- `dotenv_map` 用 `ta`（arena）分配，`deinit` 在 `init()` 返回时执行（`init.zig:48`）。
- `env_map` 由 `init.zig` 构建，`defer` 在函数末尾 `deinit`。**安全窗口**：`resolveApiKey` 与 `Provider.init`（dupe）都在 `deinit` 之前执行——借用切片在 `deinit` 前完成拷贝，顺序保证正确。

### 5. .env 格式校验：逐行 warning，不抛 ParseError

评审补充点核实：`loadDotEnv` **从不返回** `error.ParseError`（该错误仅在 `toml.zig:17`），而是对格式错误行静默跳过。本次顺势改为逐行告警：

| 方案 | 优点 | 缺点 |
|------|------|------|
| A. 返回 `error.ParseError` 整体失败 | 严格 | 一行坏文件丢弃全部有效项；`init.zig:64` 的 catch 会吞掉并置空 map |
| B. 逐行 warning + 跳过坏行，继续解析 | 宽容 + 可见 | 无整体失败语义 |

**选择**：方案 B。.env 本就是 best-effort 配置，逐行告警让用户看到问题、又不失其余配置。

**行为对比**：

```
当前: 坏行（无 = / 空 key / 未闭合引号）静默跳过，零提示
实施后: 坏行输出 warning 后跳过，有效行正常解析
```

**注意**：config.zig 在 `log.init` 之前执行（`init.zig` 先于 `App.init`），`util/log.zig` 的全局 `_io` 尚未设置，不可用——沿用 `validateConfig` 的内联 `Io.File.Writer` 模式（`config.zig:168-184`）。新增 3 处告警满足"相同模式 ≥3 次抽函数"（D4），抽私有 `warnEnv` 帮助函数。

`warnEnv` 的 `fmt` 参数为 `comptime []const u8`，前缀 `"z-agent-core: warning: .env: "` 通过 `++` 在编译期拼入格式串，运行时零拼接开销。坏行告警附带**行号**（评审补充）：`splitScalar` 循环内维护 `line_no` 计数器；告警格式为 `line {d}: <原因>`，无 `=` 行附原始行、未闭合引号附 key 名（见步骤 1 代码）。

## 实施

### 步骤 1: `config.zig` 新增 `resolveApiKey` + `loadDotEnv` 格式校验

**文件**: `src/config.zig`
**改动**: 新增 `resolveApiKey`（纯逻辑，可单测）+ `loadDotEnv` 行循环加格式告警 + 私有 `warnEnv` 帮助函数。

**关键代码**（`loadDotEnv` 行循环内，加 `line_no` 计数器）:

```zig
var line_no: usize = 0;
while (lines.next()) |raw| {
    line_no += 1;
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') continue;

    const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
        warnEnv(io, "line {d}: missing '=' ignored: '{s}'", .{ line_no, line });
        continue;
    };
    const key = std.mem.trim(u8, line[0..eq], " \t");
    if (key.len == 0) {
        warnEnv(io, "line {d}: empty key ignored", .{line_no});
        continue;
    }
    // ... 值扫描后，新增:
    if (in_quotes) {
        warnEnv(io, "line {d}: unclosed quote for key '{s}'", .{ line_no, key });
        continue;
    }
```

`warnEnv` 帮助函数（D4 抽取，`comptime fmt` 使前缀在编译期折叠）:

```zig
fn warnEnv(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    w.interface.print("z-agent-core: warning: .env: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}
```

**resolveApiKey**（借用返回，无分配）:

```zig
/// Resolve API key: process env first, .env fallback. Empty = unset.
/// Returns a borrowed slice (env_map's owned copy or dotenv arena value);
/// caller must copy before env_map.deinit / arena teardown.
/// error.ApiKeyNotSet if neither source has a value.
pub fn resolveApiKey(
    env_map: *const std.process.Environ.Map,
    dotenv: ?*const std.StringArrayHashMapUnmanaged([]const u8),
    env_name: []const u8,
) ![]const u8 {
    var raw = env_map.get(env_name);
    if (raw == null or raw.?.len == 0) {
        if (dotenv) |fb| raw = fb.get(env_name);
    }
    if (raw == null or raw.?.len == 0) return error.ApiKeyNotSet;
    return raw.?;
}
```

**注意**: `resolveApiKey` 无分配，`error.ApiKeyNotSet` 在此层产生，`init.zig` 的 `InitError` 错误集已含该项。`warnEnv` 的 warning 不改变既有解析结果，仅格式错误行行为从"静默跳过"变为"告警跳过"。

### 步骤 2: `provider.zig` 改造 `Provider.init`

**文件**: `src/io/provider.zig`
**改动**: `Provider.init` 签名加 `api_key: []const u8` 参数，删除内部 env 读取（现 61-67 行；69 行的 `allocator.dupe` 保留，参数来源从 `key_raw` 改为 `api_key`）。

**关键代码**:

```zig
pub fn init(
    allocator: std.mem.Allocator,
    entry: types.ProviderEntry,
    model: *const types.Model,
    api_key: []const u8,
    vendor_override: ?Vendor,
    io: std.Io,
) !Provider {
    _ = io;
    const vendor = if (vendor_override) |v| v else detectVendor(entry.base_url);
    const key_owned = try allocator.dupe(u8, api_key);
    // ... resolved_compat / Provider{ .config = .{ .api_key = key_owned, ... } } 不变
}
```

**注意**: 移除 `std.process.Environ` 读取后，provider 不再引用 `.env`/环境变量——`api_key_env` 字段改为由配置层消费。`!Provider` 保留（`allocator.dupe` 仍可能 OOM）。

### 步骤 3: `init.zig` 编排解析并传参

**文件**: `src/frontends/init.zig`
**改动**: 第 64 行绑定 `.env` map；找到 entry 后构建进程 env map → `resolveApiKey` → `Provider.init`。

**关键代码**:

```zig
var dotenv_map = config_mod.loadDotEnv(ta, project_root, io) catch |err| blk: {
    // 原有 warning 输出保留
    break :blk .{};
};
// ... 定位 entry 后:
var env = std.process.Environ{ .block = .{ .use_global = true } };
var env_map = try env.createMap(allocator);
defer env_map.deinit();

const api_key = try config_mod.resolveApiKey(&env_map, &dotenv_map, entry.api_key_env);
const provider = try provider_mod.Provider.init(allocator, entry, model, api_key, null, io);
```

**注意**: `catch` 块返回 `{}`（空 map）维持"加载失败不阻断启动"的既有行为；`error.ApiKeyNotSet` 由 `try` 直接上抛，删除原 77-80 行的 catch 重映射。

### 步骤 4: 测试

**文件**: `src/config.zig` + `src/io/provider.zig`
**改动**: `resolveApiKey` 单测落在 config.zig；provider.zig 删除不再成立的 `init missing key` 测试，补存储断言。

**新增**（config.zig，覆盖 B 维度空值、E 维度错误路径；构造独立 `Environ.Map`，不依赖全局环境——`Map.init`（`Environ.zig:162`）+ `put`（`Environ.zig:256`））：

| 测试名 | 场景 | 预期 |
|--------|------|------|
| `resolveApiKey: empty env var treated as unset` | 构造 `Environ.Map`，`put("KEY", "")`，无回退源 | `error.ApiKeyNotSet` |
| `resolveApiKey: falls back to dotenv` | `Environ.Map` 无此键，回退源 `put("KEY", "sk-x")` | 返回 `"sk-x"` |
| `resolveApiKey: env wins over dotenv` | 进程环境 `"sk-env"`，回退源 `"sk-dotenv"` | 返回 `"sk-env"` |
| `resolveApiKey: empty env falls back to dotenv` | 进程环境 `put("KEY", "")`，回退源有值 | 返回回退源值 |
| `resolveApiKey: both empty returns ApiKeyNotSet` | 进程环境空值 + 回退源空值 | `error.ApiKeyNotSet` |
| `loadDotEnv: malformed lines skipped, valid kept`（实现名 `config: loadDotEnv skips malformed lines`） | 文件含无 `=` 行、空 key 行、未闭合引号行 + 两条有效行 | 有效行全部解析，坏行不在 map |

**删除**（provider.zig:1159-1177）：`init missing key returns ApiKeyNotSet`——`Provider.init` 不再产生该错误。

**新增**（provider.zig）：`Provider.init stores resolved key`——传 `"sk-test"` 断言 `provider.config.api_key == "sk-test"`，验证接收路径。

**不新增 init.zig 集成测试**：完整 .env 链路（config.toml + .env 文件）用验证节的手工步骤覆盖；若开发机全局已设 `DEEPSEEK_API_KEY`，单测会读到真实值，故测试全部用独立 map 构造。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
zig test src/config.zig --cache-dir .zig-cache
zig test src/io/provider.zig --cache-dir .zig-cache
node scripts/check-catch-silent.mjs . --audit
```

> **G7.5 门禁已过**：方案涉及 `std.process.Environ.Map.init/put/get/deinit`、`createMap`、`StringArrayHashMapUnmanaged.get`（≥5 个 stdlib API），已用 `.tmp/api-stub.zig` + `zig build-obj` 编译器桩验证，返回 0（全部签名在 Zig 0.16 实际存在），桩已清理。

| 测试场景 | 预期结果 |
|----------|----------|
| 单元测试（config.zig 新增 6 条 + provider.zig 新增 1 条/删除 1 条） | 全部通过；空值/回退/优先级/错误路径/坏行容错/接收路径全绿 |
| 手工：临时目录写 `.zagent/config.toml` + `.zagent/.env`（`DEEPSEEK_API_KEY=sk-test`），不设进程环境变量，运行 `--web` | 正常启动，不再报 `API key not set` |
| 手工：进程环境设 `DEEPSEEK_API_KEY=`（空） | 启动报 `API key not set`，不再拖到 HTTP 401 |
| 手工：进程环境设有效 key | 行为不变，正常启动 |
| 手工：.env 与进程环境都缺失 | 行为不变，启动报 `API key not set` |
| 手工：.env 含坏行（如 `NOKEY`）+ 有效 key 行 | stderr 显示 `.env: line 3: missing '=' ignored: 'NOKEY'`（含行号），有效 key 生效正常启动 |

每步验证回答"能捕获什么"：单测捕获解析逻辑与接收路径回归；手工 .env 用例捕获"丢弃 map"接线错误；空值手工用例捕获"空串穿透"；ReleaseSafe 在 `zig build -Doptimize=ReleaseSafe` 下确认无 `@ptrCast`/`@intCast` 变更（本次改动无指针转换）。

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/config.zig` | 新增 `resolveApiKey` + `warnEnv` + `loadDotEnv` 格式告警 + 6 条单测 | 否 |
| `src/io/provider.zig` | `Provider.init` 签名改（去 env 读取，加 `api_key` 参数）+ 测试删 1 增 1 | 是——签名变更，调用点需同步 |
| `src/frontends/init.zig` | 绑定 .env map + 构建 env map + 解析传参 | 否 |
| `src/frontends/cli/App.zig` | 无改动（不调用 `Provider.init`） | 否 |
| `src/frontends/web/server.zig` | 无改动（经 `init_mod.init` 间接受益） | 否 |
| `docs/REMAINING.md` | 已登记本方案 | 否 |

**调用点追踪**：`Provider.init` 全项目仅 2 处调用——`init.zig:77`（改）与 `provider.zig:1176` 测试（删除）；`resolveApiKey` 调用点仅 `init.zig`。`api_key_env` 字段消费方从 provider 移至配置层，字段本身仍被读取。

## 术语

| 术语 | 含义 |
|------|------|
| 配置读取分层 | key 来源解析收敛在配置层（`config.zig`），Provider 只接收最终 key，不感知 `.env`/环境变量 |
| .env 回退源（dotenv） | `loadDotEnv` 解析出的 `KEY=VALUE` map，作为进程环境缺失时的 API key 备选来源 |
| 空值穿透 | 环境变量存在但值为空字符串时，旧的 `orelse` 判断无法拦截，key 以空串继续流程 |
| 借用切片 | `resolveApiKey` 返回值不拷贝，指向 `env_map` 内部副本或 dotenv arena 值；`Provider.init` 须在 `env_map.deinit` 前完成 dupe（顺序由 init.zig 保证） |
| 宽容解析 | `loadDotEnv` 对格式错误行逐行 warning + 跳过，不整体失败，有效行照常解析 |
| warnEnv | config.zig 私有 stderr 告警帮助函数，复用 `validateConfig` 的内联 `Io.File.Writer` 模式 |
