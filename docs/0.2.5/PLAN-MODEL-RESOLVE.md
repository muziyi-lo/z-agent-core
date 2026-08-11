# Plan MODEL-RESOLVE: 模型解析单一化（对齐 opencode Session Runner Model）

## 状态: 已完成（实施 + 验证通过）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无（本次修复 `applySessionModel` 已合入工作区，本方案在其之上收尾） | — | — |

## 不做

- **不引入事件溯源/投影器**：opencode 的 `V2Session.switchModel` + projector 是 TS/Effect 生态的产物，Zig 项目会话是 JSONL 行内联模型字段，改事件流是过度设计。本期用「会话行唯一权威 + 解析单一决策点」达成同样效果，不动存储格式。
- **不引入 Catalog/Draft transform 插件机制**：`buildRegistry()` 已满足工具注册需求；模型 catalog 就是 `config.providers`，无需复制一份可变的注册表。
- **不做请求级模型热切换 UI**（改下拉→当前会话立刻换模型）：维持既有「模型切换只对新会话生效」语义（前端已有 tip 文案）。本期只保证**切换确实生效**且来源唯一。
- **不缓存 api_key 明文到磁盘**：env 快照只在进程内存，不落盘。
- **不新增 provider 级热重载**（改 config.toml 后重启才有）：维持现状，env 快照进程级一次。
- **不强制前端改造错误提示**：本期后端返回 `available_models` 字段（契约就位）；前端消费（弹可用列表）属可选增强，另行跟进。

## 问题

**背景**：LRN-20260811-001 修复「前端模型切换不生效」后（`applySessionModel` 在 runTurn 前把会话模型写入 provider config），暴露三处既有技术债：

**债 1 — 模型来源逻辑分散**：Web 端建会话有 3 处各自决定模型，取值规则不统一：
| 位置 | 模型来源 | 问题 |
|------|----------|------|
| `handleSessionCreate`（handler.zig:297） | POST body 的 `model`，无则 default | 与提示文案一致，OK |
| `handleCommandNew`（handler.zig:391） | **固定** `ctx.config.default_model` | 与 /new 的 body 无关，`/new` 命令建的新会话无法指定模型 |
| `handlePrompt`（handler.zig:502） | URL `model` 参数，无则 default | 本次修复已加，但三层逻辑重复 |

将来再加一处建会话的入口，模型规则必然再漂移一次。

**债 2 — 每次 prompt 重建 env_map + 重读 .env**：`applySessionModel`（handler.zig:488-492）每次请求 `env.createMap(a)` + `loadDotEnv(...)`。`loadDotEnv` 每次打开并读 `.zagent/.env` 文件、逐行解析。高频请求下纯属浪费——env 与 .env 在进程生命周期内不会变（opencode 用进程级一次快照 + 无限 TTL）。

**债 3 — 双状态模型来源**：`provider.config.model`（连接时固定 default，server.zig:199）与 `session.model`（每会话）并存，靠 `applySessionModel` 手动同步。当前 `provider.config.model` 在连接作用域内被 `buildJsonBody`（provider.zig:499 `self.config.model`，函数在 489）与工具 `api_endpoint`（agent.zig:307）读取——重配前读到的是 default，重配失败时静默（`log.biz_error` 后继续用旧模型）→ 正是「改了不生效」类 bug 的温床。

**参考**：opencode `packages/core/src/session/runner/model.ts` —— `SessionRunnerModel.resolve(session)` 是**唯一**模型决策点：`session.model` 有值就用，无值才查 catalog default，找不到显式 `ModelUnavailableError` 不静默降级。Env 侧 `packages/opencode/src/env/index.ts` 进程级一次快照 + `cachedInvalidateWithTTL(Duration.infinity)`。本方案移植其三个核心决策：**单一解析函数、进程级 env 快照、会话行唯一权威**。

## 概览

- **改动范围**：3 个源文件 + 计划文档登记。
  - `src/frontends/init.zig` — FrontendState 持有 env 快照 + dotenv（进程级一次）。
  - `src/frontends/web/server.zig` — 把 env 快照注入 Context。
  - `src/frontends/web/handler.zig` — 抽 `createSession` 工厂 + `resolveSessionModel` 单一决策点 + `applySessionModel` 复用快照。
- **核心思路**：三条收敛——
  1. **建会话统一走工厂**：`createSession(ctx, a, opt_model_spec)`，模型解析 `resolveModelSpec(config, opt)` 一处定规则。
  2. **env/dotenv 进程级快照**：`FrontendState` 启动时构建一次，请求期只读。
  3. **模型解析单一决策点**：`resolveSessionModel(config, spec)` 返回 `{*const Model, *const ProviderEntry}`；`applySessionModel` 与建会话共用，解析失败**显式报错**（新会话）或回退并告警（旧会话）。
- **参考实现**：opencode `SessionRunnerModel.resolve` + `Env.Service` 快照。

## 设计要点

### 1. env 快照：FrontendState 进程级持有

| 方案 | 优点 | 缺点 |
|------|------|------|
| A. 每次请求重建（现状） | 实现简单 | 每次读 .env 文件 + 构建 map，浪费 |
| B. FrontendState 启动时构建一次，持有到 deinit | opencode 同款；请求期零文件 IO | 进程内改 env 不生效（需重启，可接受） |

**选择**：方案 B。`init.zig` 已构建 `env_map`（78-81 行）与 `dotenv_map`（64-70 行），当前用完即弃——改为**存进 FrontendState 并负责释放**。

```
现状: init 局部 env_map (defer deinit) + dotenv_map (tmp arena) → 丢弃
实施后: FrontendState.env_snapshot (owned) + FrontendState.dotenv (owned) → deinit 释放
```

**内存布局**（遵循 `Environ.Map` 全量持有语义 + Arena 统一内存原则）：
- `env_snapshot: std.process.Environ.Map` —— `createMap(allocator)` 已 dupe 全部键值（`Environ.zig` 内部 `put` 即 dupe），`deinit` 释放。
- `dotenv: std.StringArrayHashMapUnmanaged([]const u8)` —— 从 `ta`（tmp arena，init 返回即销毁）改为 `allocator`（FrontendState 生命周期），`deinit` 遍历释放键值（`loadDotEnv` 的 errdefer 模式已示范）。
- 放入 `FrontendState`，新增 `deinit` 释放两条。

**生命周期安全**（承接 PLAN-FIX-APIKEY-ENV 的借用语义）：`resolveApiKey(&env_snapshot, &dotenv, ...)` 返回借用切片，调用方（`applySessionModel` → `setModel`）立即 `dupe` 进连接 arena。借用源（FrontendState 字段）在进程生命周期内有效，比原来的「请求内局部 map + defer」更安全——无提前释放窗口。

### 2. 模型解析单一决策点：`resolveSessionModel`

opencode 的 `resolve` 决策链移植，收敛为 Web 私有函数：

```zig
const ResolvedModel = struct {
    model: *const types.Model,
    entry: *const types.ProviderEntry,
};

fn resolveSessionModel(config: *const config_mod.Config, spec: []const u8) !ResolvedModel {
    const model = try config_mod.resolveModel(config, spec);   // provider/model → *Model
    for (config.providers) |*entry| {
        if (std.mem.eql(u8, entry.name, model.provider)) return .{ .model = model, .entry = entry };
    }
    return error.ProviderNotFound;
}
```

**决策规则**（对齐 opencode `session.model ?: catalog.default`）：
```
spec 非空 → resolveSessionModel(spec)          // 会话行唯一权威
spec 为空（null 或 ""）→ default_model（配置层 fallback，不改 spec）
解析失败（新会话）→ 400 显式报错 + available_models 清单，不静默建 default 会话
解析失败（已有会话，老数据/配置变更）→ 回退 default + log.biz_error（不阻断历史会话）
```

**`resolveModelSpec` 空串语义**（评审补充）：`opt ?: default_model` 的 `?:` 只兜底 `null`，不兜底空字符串。需显式处理空串——`?[]const u8` 有值但 `len==0` 时同样走 default：

```zig
fn resolveModelSpec(config: *const config_mod.Config, opt: ?[]const u8) []const u8 {
    if (opt) |s| {
        if (s.len > 0) return s;
    }
    return config.default_model;
}
```

这与决策规则「spec 为空（null 或 ""）→ default」一致，避免空串穿透到 `resolveModel` 抛 `InvalidModelSpec`。`handleSessionCreate` 的 body.model 可能是空串（`"model":""`），`handlePrompt` 的 url_model 提取后也可能为空——统一在 `resolveModelSpec` 兜底。

**错误响应附带 available_models（评论者建议）**：新会话模型解析失败时，400 错误体不再只给通用 message，而是附上可用模型清单，让用户/前端直接知道该选什么：

```json
{"error":{
  "code": "bad_request",
  "message": "cannot resolve model 'nope/nope'",
  "available_models": ["deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash"]
}}
```

- **格式**：`available_models` 为 `"provider/model_id"` 字符串数组，与 `/api/model` 各元素的 `id` 字段同构（`provider/model_id`），前端可直接比对 `models.some(m => m.id === ...)`。
- **来源**：从 `ctx.config.providers` 遍历生成。**抽取粒度**：`handleModelList`（handler.zig:194-209）输出完整对象数组（含 name/provider/context_window），`available_models` 只需 id 字符串——两者输出格式不同，故抽取的是**共用的 id 拼接子逻辑**（`"{p.name}/{m.id}"`），而非整个序列化函数。抽私有 `writeModelIds(a, config, buf)`（遍历 provider×model，向 buf 追加 `"provider/model_id"` 逗号分隔项），`handleModelList` 与 `respondModelUnavailable` 各自用同一 id 拼装、外层格式（对象 vs 字符串）各自组装。避免「两处手写 `{p.name}/{m.id}` 拼装漂移」，同时不强求输出格式相同。
- **实现**：error.zig 不感知 config（分层原则），故在 handler.zig 新增 `respondModelUnavailable(request, config, spec, a)`——构建含 `available_models` 的错误体，`err_mod.respondError` 之外的自定义响应。
- **前端配合**（可选，本期做后端即可）：app.js 的 prompt/新会话错误处理若收到 `available_models`，可在 400 时提示「模型不可用，可用: …」，前端已有 `/api/model` 数据源，本期仅记录契约不强制前端改动。

### 3. 建会话统一工厂：`createSession`

`handleSessionCreate` / `handleCommandNew` / `handlePrompt` 三处「uuid + Session.init + createDirPath + flush」重复，且模型来源不一致。抽工厂收敛：

```zig
const CreatedSession = struct {
    id: []const u8,          // 请求 arena 分配
    session: session_mod.Session,  // ctx.allocator 分配，调用方负责 deinit
};

fn createSession(ctx: *Context, a: std.mem.Allocator, opt_model: ?[]const u8, id_override: ?[]const u8) !CreatedSession {
    const spec = resolveModelSpec(ctx.config, opt_model);   // opt ?: default_model
    const id = if (id_override) |oid| oid else try uuid_mod.v4(a);
    var s = try session_mod.Session.init(ctx.allocator, ctx.io, spec);
    try Io.Dir.cwd().createDirPath(ctx.io, ctx.sessions_dir);
    const filename = try std.fmt.allocPrint(a, "{s}.jsonl", .{id});
    const path = try std.fs.path.join(a, &.{ ctx.sessions_dir, filename });
    s.path = path;
    try s.flush();
    return .{ .id = id, .session = s };
}
```

**调用方消费**（`id_override` 供 handlePrompt 钉住前端生成的 session id，避免孤儿文件）：
- `handleSessionCreate`：`var created = try createSession(ctx, a, body_model, null); defer created.session.deinit();` → 用 `created.id`/`created.session.model` 拼响应。
- `handleCommandNew`：同上，`opt_model = null, id_override = null`。
- `handlePrompt`（is_new）：`const created = try createSession(ctx, ctx.allocator, url_model, session_id);` → **先 `defer s.deinit()` 接管并释放 `created.session`**（避免 arena 泄漏），随后 append 首条 user 消息 + 命名 + flush，最后重新 `Session.load`（沿用既有 reload 路径，外层 session 持有新 arena）。注意 handlePrompt 的 `s` 必须 `defer deinit`——值拷贝的 `_arena` 与 `created.session` 同源，仅 `s` deinit 一次，无 double-free。

**三处调用点模型来源对齐**：

| 位置 | 现状 | 实施后 |
|------|------|--------|
| `handleSessionCreate` | body.model ?: default | `createSession(ctx, a, body_model)` |
| `handleCommandNew` | 固定 default | `createSession(ctx, a, null)`（`/new` 命令无参数，默认模型合理；若未来 `new` 支持模型参数，加一行即可） |
| `handlePrompt`（is_new 分支） | url_model ?: default + append + rename | `createSession(ctx, a, url_model)` + 追加首条 user 消息（工厂只建空会话落盘，不掺消息逻辑） |

**所有权契约**（评审补充——避免工厂返回值悬垂）：
- 工厂**返回** `CreatedSession { id, session }`（`session` 值语义，内部 arena 托管消息），调用方负责 `deinit`；`id_override` 支持 handlePrompt 复用前端 session id 作文件名。
- 混合分配对齐现状：Session 本体用 `ctx.allocator`（连接 arena），id/filename/path 用 `a`（请求 arena）——与 `handleSessionCreate`/`handleCommandNew` 现有代码一致（handler.zig:313-318）。
- `handlePrompt` 的 is_new 分支**接管并释放**工厂返回的 Session：`var s = created.session; defer s.deinit();` 后 append/命名/flush，再 `Session.load` 重载——避免双份持有；`created.session` 不再单独 deinit（值拷贝同源，仅 `s` 释放一次）。
- `respondModelUnavailable` 的 message 中 spec 用 `escapeJsonDynamic` 转义 + 显式引号包裹，防 JSON 注入。

### 4. `applySessionModel` 复用快照 + 显式失败

```zig
fn applySessionModel(ctx: *Context, agent: *agent_mod.AgentLoop, spec: []const u8, a: std.mem.Allocator) !void {
    const resolved = try resolveSessionModel(ctx.config, spec);
    // ctx.env_snapshot / ctx.dotenv 已是 *const 引用，直接传入（不取 &，避免双重指针）
    const api_key = try config_mod.resolveApiKey(ctx.env_snapshot, ctx.dotenv, resolved.entry.api_key_env);
    try agent.provider_ref.setModel(a, resolved.entry.*, resolved.model, api_key);
    agent.context_window = resolved.model.context_window;
}
```

> **类型核对**（评审补充）：`resolveApiKey` 签名是 `env_map: *const std.process.Environ.Map, dotenv: ?*const StringArrayHashMapUnmanaged([]const u8)`（config.zig:172-176）——与 Context 新字段类型完全匹配，`ctx.env_snapshot`/`ctx.dotenv` 直接传即可，无需 `&`。若字段声明为 `*const Map`，写 `&ctx.env_snapshot` 会得到 `*const *const Map` 导致编译错误——文档代码已按正确形式给出。

- **删除**每次请求的 `env.createMap(a)` + `loadDotEnv(a, ...)`（handler.zig:488-492）——债 2 清零。
- **解析失败传播**：`handlePrompt` 的 `catch` 从「静默 log 继续」收紧为——新会话场景由 `createSession` 上游显式 400；已有会话场景保留回退 default + `log.biz_error`（历史会话不能被无效模型卡死）。

### 5. Context 增加 env 快照引用

```zig
pub const Context = struct {
    ...
    env_snapshot: *const std.process.Environ.Map,          // 新增
    dotenv: *const std.StringArrayHashMapUnmanaged([]const u8),  // 新增
};
```

`server.zig` 构造 Context 时从 `&state.env_snapshot` / `&state.dotenv` 取引用。请求只读，无并发写——多线程读同一快照安全（`Environ.Map.get` 只读）。

## 实施

### 步骤 1: `init.zig` — env/dotenv 进 FrontendState

**文件**: `src/frontends/init.zig`
**改动**: `FrontendState` 新增 `env_snapshot` + `dotenv` 字段；`init` 把局部 env_map / dotenv_map 改为持有进 state；`deinit` 释放。

**关键点**：
- `dotenv_map` 的分配器从 `ta` 改为 `allocator`（state 生命周期），否则 tmp arena 在 init 返回时销毁、字段悬垂。
- `env_map` 从 `defer env_map.deinit()` 改为移入 state；`Provider.init` 调用处仍可借用（dupe 在 deinit 前）。
- 保留「.env 加载失败 → 空 map + warning」行为不变。

### 步骤 2: `handler.zig` — 三合一

**文件**: `src/frontends/web/handler.zig`
**改动**:
1. 新增 `ResolvedModel` + `resolveSessionModel` + `resolveModelSpec` + `createSession`（含 `id_override` 参数，见设计要点 3）。
2. `handleSessionCreate` / `handleCommandNew` / `handlePrompt` 三处改用工厂，模型来源对齐。
3. `applySessionModel` 改读 `ctx.env_snapshot`/`ctx.dotenv`，删除 createMap/loadDotEnv。
4. Context 增加 `env_snapshot` / `dotenv` 引用字段。
5. `handlePrompt` 新会话解析失败显式 400（**附 `available_models` 清单**），已有会话保留回退+告警。
6. 抽 `writeModelIds`（id 拼接子逻辑，`handleModelList` 与 `respondModelUnavailable` 共用）+ 新增 `respondModelUnavailable`（错误体含 `available_models`，message 内 spec 用 `escapeJsonDynamic` 转义 + 显式引号包裹防注入）。
7. `handlePrompt` is_new 分支 `defer s.deinit()` 释放工厂返回的 Session（值拷贝同源，单次释放防泄漏）。

### 步骤 3: `server.zig` — Context 注入快照

**文件**: `src/frontends/web/server.zig`
**改动**: 构造 Context 时填 `env_snapshot = &state.env_snapshot`、`dotenv = &state.dotenv`。

### 步骤 4: 测试

**文件**: `src/frontends/web/handler.zig`
**改动**:
- `resolveModelSpec` 纯函数单测（`null` / `""` / 非空三分支）——handler.zig 已有 `src/test.zig:25` 引用，可直接加 test 块。
- `resolveSessionModel` 单测：合法 spec、未知 provider、未知模型、无斜杠。**构造法**：测试块内手工构造最小 `config_mod.Config` 字面量（`providers` 用静态 `ProviderEntry` 数组、`_arena = undefined`，只读字段不 deinit），零文件 IO。
- `writeModelIds` 单测：给定 providers 切片，输出 `"provider/model_id"` 逗号分隔项。
- 现有 `resolveModel` 测试（config.zig）已覆盖 spec→model；新增覆盖 entry 查找层。
- 前端 Node 测试：`app.js` 无渲染逻辑改动，预期不受影响；跑一遍确认。

**注意**：handler.zig 依赖 `@embedFile` 资源（index.html/app.js/css），`zig test src/test.zig` 已含该模块（test.zig:25）——新增 test 块只测纯函数，不触 `handleRequest`/HTTP 路径。

**不新增集成测试**：工厂/快照的完整链路（POST /session → prompt → SSE）用手工验证节覆盖。

## 验证

```powershell
zig build
zig build --release=safe
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs
```

| 测试场景 | 预期结果 |
|----------|----------|
| 单测：`resolveModelSpec` / `resolveSessionModel` | 全绿；空 spec（null 与 ""）、未知 provider/model、无斜杠全覆盖 |
| 单测：`writeModelIds` | 输出为 `["provider/model_id", ...]`，与 `handleModelList` 各元素 `id` 同构，源不漂移 |
| 单测回归：config resolveModel 系列 | 不受影响，全绿 |
| `zig test src/test.zig` | 除既有 `tool.bash echo hello`（testing.io 不支持 subprocess，基线失败）外全通过 |
| 手工：POST /api/session `{model:"deepseek/deepseek-v4-pro"}` → 发消息 | SSE 请求模型为 deepseek-v4-pro（mock 抓包确认） |
| 手工：/new 命令建会话 | 使用 default_model |
| 手工：改 `.zagent/.env` 后**不重启**发消息 | 用旧快照（预期行为：重启生效），无崩溃 |
| 手工：prompt 带非法 `model=nope/nope` 建新会话 | 400 + `available_models` 数组列出全部 `provider/model_id`，不静默建 default 会话 |
| 性能：连续 100 次 prompt | 无 .env 文件 IO（对比修复前每次读文件） |

每步验证回答「能捕获什么」：单测捕获解析规则与 entry 查找回归；手工模型用例捕获「切换仍生效」；非法模型用例捕获「不再静默降级」；改 .env 用例确认快照语义边界。

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/init.zig` | FrontendState +2 字段 + init/deinit 持有 env/dotenv | 否（CLI 也经 init_mod，编译期全量检查） |
| `src/frontends/web/handler.zig` | 工厂 + 单一解析点 + applySessionModel 改快照 + Context +2 字段 | 否 |
| `src/frontends/web/server.zig` | Context 初始化 +2 引用 | 否 |
| `src/frontends/cli/App.zig` | 无改动（不直接碰 FrontendState 新字段） | 否 |
| `src/config.zig` | 无改动（`resolveModel`/`resolveApiKey`/`loadDotEnv` 均已存在） | 否 |
| `docs/REMAINING.md` | 登记本方案 + 移除 LRN-20260811-001 遗留债 | 否 |

**调用点追踪**：`createSession` 全项目 3 处调用（Web handler 内）；`resolveSessionModel` 2 处（applySessionModel + handlePrompt 新会话校验）；`env.createMap`/`loadDotEnv` 在 Web 请求路径的调用从「每次」降为「进程一次」；CLI 路径（`init.zig`）本就一次，行为不变。

## 术语

| 术语 | 含义 |
|------|------|
| 单一决策点 | 模型解析只经 `resolveSessionModel` 一个函数，UI/命令/请求不得各自决定模型（opencode SessionRunnerModel.resolve 的移植） |
| env 快照 | 进程启动时 `std.process.Environ` 全量拷贝进 FrontendState，请求期只读引用，不重建不重读 |
| dotenv 快照 | `.zagent/.env` 启动时解析一次进 FrontendState（改分配器为 state 生命周期），请求期只读 |
| 会话行唯一权威 | session 文件内联的 model 字段是会话模型唯一事实源，全局 default 只在会话无模型时兜底 |
| 显式失败不降级 | 新会话模型解析失败返回 400，不静默回退 default（修正「改了不生效」类静默 bug 的温床） |
