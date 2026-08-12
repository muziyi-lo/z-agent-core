# Plan LOGGING-SYSTEM: 日志系统补完

## 状态: ✅ 已实施（2026-08-12，build + 242 测试 + 冒烟：sse_* 完整序列 + 落盘 + trace 文件验证通过）

## 问题

**现象**：Web `POST /prompt` 崩溃（`unreachable` panic）时，日志只有入口 `request` 行 + panic，关键路径（会话加载、消息追加、模型应用、SSE 建立、abort 注册、压缩、turn 开始）**全程无日志**，无法定位崩溃在哪个阶段。
**根因**：`util/log.zig` 已具备事件化日志（级别/TID/rid/事件名），但**覆盖稀疏**——handleSSE 中间流程 ~6 步无日志；且无运行时级别配置、无落盘、无事件回放、无计时。

## 概览

- 涉及 5 个模块、8 个文件：`util/`（log/trace/timing）、`web/`（handler/server）、`cli/`（main/App）、`core/`（agent/compact）、`io/`（provider）
- 两个参考视角（阶段 1.5 对比）：
  - **opencode**（`packages/opencode/src`）：结构化事件日志（Effect.log 187 处）、span 层级（`Effect.withSpan`）、JSONL 事件 trace（`OPENCODE_DIRECT_TRACE=1`，turn lifecycle markers）、级别 env 控制（`OPENCODE_LOG_LEVEL`）、落盘（`Global.Path.log`）
  - **pi-repos**（`packages/coding-agent/src/core`）：事件总线（`event-bus.ts` 结构化 channel）、计时插桩（`timings.ts`，`PI_TIMING=1`）、会话事件树持久化（entry 带 type+timestamp，天然回放）
- 一句话思路：补**覆盖度**（关键路径日志）→ **可配置**（级别 env + 落盘）→ **可回放**（JSONL trace）→ **可测量**（计时）
- 不做：span 调用树（opencode withSpan，成本高，tid/rid 已够用）、事件总线（pi EventBus，架构级）、UI 日志查看

## 设计要点

### P1: 关键路径日志补全（对齐 opencode 覆盖度）

**参考**：opencode 187 处 `Effect.log` 覆盖每个模块关键决策（llm.ts 的 `stream`/`llm runtime selected`/`stream error`）；`trace.ts` 明确记录 **turn lifecycle markers**（回合生命周期标记）。

**实现**：给 handleSSE 全阶段补事件日志，事件名统一 `sse_*` 前缀形成生命周期序列（对齐 opencode turn markers）：

| 阶段 | 事件名 | 级别 | 字段 |
|------|--------|------|------|
| 会话加载完成 | `sse_load` | dbg | session_id, msgs |
| 用户消息追加 | `sse_append` | dbg | msgs 数 |
| 模型应用 | `sse_apply_model` | dbg | model |
| SSE 响应头 | `sse_header` | dbg | — |
| abort 注册 | `sse_abort_reg` | dbg | session_id |
| session_ready 发送 | `sse_session_ready` | dbg | message_id |
| 自动压缩 | `sse_compact` | info | compacted:0/1 或 skipped |
| runTurn 开始 | `sse_run_turn_start` | info | — |
| runTurn 结束 | `sse_done`（已有） | info | msgs |
| abort 移除 | `sse_abort_remove` | dbg | — |

其他关键路径同步补：
- `core/agent.zig`：tool round 计数、StormBreaker 触发、上下文超阈值警告注入
- `io/provider.zig`：流开始、retry 次数、结束原因（对齐 opencode llm.ts）
- `core/compact.zig`：压缩触发/成功/失败（`compaction_start/end`，对齐 pi 的 `compaction_start` 事件）

用现有 `log.biz_info`/`log.dbg`（tid/rid + 事件名 + 格式化参数），不新造轮子。P1 是本次崩溃的直接解药：崩溃前最后一条 `sse_*` 日志即定位到阶段。

> **覆盖度边界（评论确认，2026-08-12）**：日志粒度是**阶段事件**——`sse_load`/`sse_append` 在 Session 操作**完成后**打。若 Session 内部（load/append/flush 解析、provider 解析循环）发生 panic，只能定位到**阶段边界**（两个事件之间），不能到行。本次崩溃机制（`abort_mutex` lock/unlock）由 `sse_stream_start`→`sse_abort_reg` 界定，可定位到 abort 注册区。若要行级定位需结合 Debug 构建栈；P1 的覆盖度目标 = **可定位到功能阶段**（够用），不追求行级。

### P2: 级别运行时配置 + 落盘（对齐 opencode）

**参考**：opencode `OPENCODE_LOG_LEVEL` 环境变量控制级别；`Global.Path.log` 目录持久化。

**实现**：
- `log.init` 增加从 `ZAGENT_LOG_LEVEL` env 读取级别（trace/debug/info/warn/error），未设置保持默认 debug
- **统一入口（评论发现，2026-08-12）**：现 `log.init(io, .debug)` **只在 Web 入口 `server.zig:138` 调用，CLI 入口（`cli/main.zig`/`App.init`）从不调用**——`writeLog` 里 `_io orelse return`（log.zig:81）导致 **CLI 模式日志全部静默**。修正：CLI `main.zig` 入口同样调用 `log.init`（与 Web 一致），保证 P1 日志、P2 落盘、P2.5 清理在 CLI/Web 双前端均生效
- **落盘**：`.zagent/log/z-agent-core.log` 追加写，与 stderr 双输出（stderr 保留交互/控制台，文件保留可查证）。写失败静默降级为仅 stderr（不因日志故障影响业务）
- 日志行格式扩展：保持现有 `[HH:MM:SS.mmm] [LEVEL] [TID] ctx:r{rid} event={ev} {fields}`，落盘行加 ANSI 颜色剥离（文件无色）

### P3: JSONL 事件 trace（对齐 opencode trace.ts + pi 会话事件树）

**参考**：opencode `trace.ts`（`OPENCODE_DIRECT_TRACE=1`）把完整闭环（outbound prompts / inbound events / reducer output / turn lifecycle markers）写 `log/direct/<ts>-<pid>.jsonl` + `latest.json` 指针；pi-repos 会话事件树（entry 带 type+timestamp）天然支持事后回放。

**实现**：新增 `util/trace.zig`：
- 开关：`ZAGENT_TRACE=1`（lazy 初始化，与 opencode trace.ts 一致）
- 路径：`.zagent/log/trace/<ts>-<pid>.jsonl` + `latest.json`（`ts` = `yyyymmddTHHMMSS`，同 opencode stamp 格式）
- **latest.json 并发安全（评论确认，2026-08-12）**：覆盖写在 trace 的 `Io.Mutex` 内（与 `trace.write` 同锁，无并发竞态）；用**临时文件 + 原子 rename**（`Io.Dir.rename(cwd, tmp, cwd, dest, io)`，参照 `session.zig:419` 用法——注意 Zig 0.16 **无 `Io.Dir.renameFile`**）写入，避免写中断时 `latest.json` 半写
- 事件类型与 P1 的 `sse_*` 生命周期对齐，另含：`request`（方法/路径）、`provider_stream`（增量 token/工具调用）、`tool_call`/`tool_result`、`compaction_start/end`、`timing`（P4）
- 每行 JSON：`{"ts":<epoch-ms>,"type":"...","tid":N,"rid":N,"data":{...}}`
- 覆盖 CLI 与 Web 双前端（CLI 的 `processLine`/`singleTurn` 埋同类型事件）
- 零成本：默认关闭，`writeLog` 前检查开关，单次布尔判断

### P2.5: 自动存储与清理（轮转 + 保留）

**参考**：opencode `Global.Path.log` 落盘但**无内置轮转/清理**（trace 文件每进程一个、无限累积，靠外部处理）——参考项目也未解决，需自行设计。opencode `tool/truncate.ts` 有 `RETENTION = Duration.days(7)` 的保留期先例。

**实现**（默认值，避免无限制增长）：
- **主日志轮转**（`.zagent/log/z-agent-core.log`）：
  - 进程内字节计数，达到 `MAX_LOG_SIZE`（默认 5MB）→ 轮转：`.log` → `.log.1` → `.log.2`（最多保留 3 份，最旧删除）
  - 检查时机：写入后检查计数，超阈值立即轮转（避免日志增长失控）
  - 多线程写互斥：轮转时短暂持有日志锁（`Io.Mutex`，见生命周期"写入并发"）
- **trace 目录清理**（`.zagent/log/trace/`）：
  - 文件名含可解析时间戳 `<ts>-<pid>.jsonl` → 按时间判断
  - **双策略保留（评论建议采纳，2026-08-12）**：时间 + 数量双上限，**任一超限即清理**：
    - `ZAGENT_TRACE_RETENTION_DAYS`（默认 7 天）——超过天数的文件删除
    - `ZAGENT_TRACE_MAX_FILES`（默认 100 个）——保留最新 N 个，超过后删最旧
  - 理由：单时间策略在低频场景（偶尔启动、文件少）可能过早删除用户想保留的历史；高频场景（频繁启动）7 天内可能积累数百文件失控。双策略下：低频 → 时间主导（文件少全保留到天数）；高频 → 数量封顶（最新 100 个）
  - `latest.json` 保留（单文件指针）
- **清理触发与入口一致性（评论确认，2026-08-12）**：清理（trace 扫描 + 主日志轮转初始化）统一挂在 `log.init` 内；因 CLI/Web 均调用 `log.init`（P2 修正），两入口行为一致，不存在"Web 清理了 CLI 没清理"的分叉
- **清理触发**：trace 在启动时；主日志在写入时（字节计数）。运行时无后台定时器（避免额外线程）
- **可选 env**：`ZAGENT_LOG_MAX_BYTES`、`ZAGENT_TRACE_RETENTION_DAYS`、`ZAGENT_TRACE_MAX_FILES` 覆盖默认

### 生命周期完整性（成对方向补齐，2026-08-12 评论补充）

**根因反思**：初版计划按"参考对齐"的功能清单（P1-P4）推进，缺少**生命周期闭环审查**——成对操作（创建↔关闭、写入↔失败、增长↔清理）只建了入口漏了出口（陷阱 `LRN-20260719-004`，日志系统复发）。

**全生命周期枚举**（对齐成对方向，补齐遗漏）：

| 阶段 | 设计 | 状态 |
|------|------|------|
| **创建** | `log.init` 时 `createDirPath(project_root/.zagent/log)` + `trace/` 子目录 | 补 |
| **路径基准** | 统一 `project_root`（非 cwd）——服务器 `--web` cwd 可能与项目根不同 | 补 |
| 初始化 | `ZAGENT_LOG_LEVEL` 读取 + 主日志句柄打开 | ✓ P2 |
| 写入 | 级别过滤 / 格式化 / ANSI 剥离（落盘） | ✓ P2 |
| **写入并发** | 主日志与 trace 写加进程级 `Io.Mutex`——多请求线程（handleSSE 多线程）同时写文件需互斥，防行交错 | 补 |
| **写入失败** | 磁盘满/权限 → 置一次降级标志后仅写 stderr（避免每行重试开销）；恢复尝试（下次写成功清除标志） | 补 |
| 存储 | `.zagent/log/` 位置 / 格式 / 大小限制 | ✓ P2.5 |
| 轮转 / 清理 | 大小轮转 + trace 保留期 | ✓ P2.5 |
| 读取 | trace `latest.json` ✓；主日志无需内置查看（外部 tail） | ✓ |
| **崩溃落盘** | `writeLog` 直接 `writeAll` + `flush`（无缓冲积压），panic 前日志已落盘——无需额外设计，确认即可 | ✓ 确认 |
| **结束** | Zig **无 atexit 钩子**（`std.process.exit` 仅 `std.c.exit`）。主日志句柄关闭：CLI `main.zig` / Web `server.zig` 正常退出路径用 `defer log.deinit()`（显式 close）；写路径每次 `writeAll`+`flush` 无缓冲积压，进程非正常退出（panic）时 **OS 自动回收句柄**兜底 | 补 |

**实施落点**：
- `log.init`：创建目录 + 打开句柄 + 存 `project_root` + 提供 `log.deinit()`（CLI/Web 入口退出路径调用）
- `writeLog`/`trace.write`：加 `Io.Mutex` 保护（日志锁，与 `abort_mutex` 独立）
- 写入失败降级标志：`_io_broken: bool`，失败置位，成功复位

### P4: 计时插桩（对齐 pi-repos timings.ts，并入 trace）

**参考**：pi-repos `timings.ts`（`PI_TIMING=1`）记录 `{label, ms}` 序列，`printTimings()` 输出各阶段耗时。

**实现**（评论建议采纳，2026-08-12）：timing 作为 `type:"timing"` 事件**写入 trace JSONL**，一份 JSONL 同时含行为序列与各阶段耗时：
- `timing.mark(label)` 记录阶段耗时
- **TRACE 开启时**：`trace.write("timing", {label, ms})` 写入 JSONL——回放时行为与耗时天然对齐（如 `sse_run_turn_start` 前后 timing 即该阶段耗时）
- **TIMING 开启时**（`ZAGENT_TIMING=1`）：额外输出 `--- Timings ---` 段到 stderr（保留独立诊断能力）
- **开关正交**：`ZAGENT_TRACE` 控制 JSONL 写入，`ZAGENT_TIMING` 控制 stderr 输出，互不影响
- 请求级阶段：`sse_load`→`run_turn`→`flush`→`done` 各阶段耗时（含 LLM 等待、压缩耗时）

## 实施

### 步骤 1: 关键路径日志补全（P1）

**文件**: `src/frontends/web/handler.zig`、`src/core/agent.zig`、`src/io/provider.zig`、`src/core/compact.zig`
**改动**: 按上表补 `log.biz_info`/`log.dbg` 事件；事件名统一 `sse_*`/`compaction_*`/`tool_*` 前缀。
**注意**: 日志本身不得抛错/阻塞（现有 `writeLog` 已 `catch` 静默）；避免在每 token 增量路径打日志（只在阶段边界）。

### 步骤 2: 级别配置 + 落盘 + 轮转 + 生命周期（P2 + P2.5）

**文件**: `src/util/log.zig`、`src/frontends/web/server.zig`（已有 138 调用）、`src/frontends/cli/main.zig`（补调用）
**改动**: `init` 读 `ZAGENT_LOG_LEVEL`；**CLI `main.zig` 补 `log.init` 调用（对齐 Web `server.zig:138`）**；创建 `.zagent/log` + `trace/` 目录（基于 `project_root`）；打开主日志句柄（入口 `defer log.deinit()` 关闭）；文件双写（ANSI 剥离）；字节计数达 `MAX_LOG_SIZE` 轮转（`.log.1`/`.log.2`，保留 3 份）；写加 `Io.Mutex`；磁盘满置降级标志（降级 stderr，成功复位）；trace 保留期扫描在 `init` 内执行。
**注意**: 日志锁与 `abort_mutex` 独立；句柄进程级单例；轮转持锁执行；CLI/Web 入口一致调用 `init` 保证清理与落盘双前端生效。

### 步骤 3: JSONL trace + 清理（P3 + P2.5）

**文件**: `src/util/trace.zig`（新增）、`src/util/log.zig`（或独立埋点）、`handler.zig`/`App.zig`（调用）
**改动**: `trace.write(type, tid, rid, data)`；`ZAGENT_TRACE=1` lazy 初始化；路径 `.zagent/log/trace/`；启动时按双策略清理（超过 `TRACE_RETENTION_DAYS` 或超过最新 `TRACE_MAX_FILES` 的文件删除）。
**注意**: `latest.json` 每次写覆盖（mutex 内 + tmp+rename 原子）；文件名含 pid 防并发覆盖；清理只在启动时执行。

### 步骤 4: 计时插桩（P4）

**文件**: `src/util/timing.zig`（新增）、`handler.zig`
**改动**: `timing.mark(label)` 记录阶段耗时；TRACE 开启时 `trace.write("timing", {label, ms})` 写入 JSONL；`ZAGENT_TIMING=1` 时额外 stderr 输出；请求级各阶段标记。
**注意**: 开关正交（TRACE 控制 JSONL、TIMING 控制 stderr）；timing 事件插入行为序列中，回放可对齐。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 测试场景 | 预期结果 |
|----------|----------|
| 请求一个 prompt | 日志序列完整：`sse_load→sse_append→sse_apply_model→sse_header→sse_abort_reg→sse_session_ready→sse_compact→sse_run_turn_start→sse_done→sse_abort_remove` |
| `ZAGENT_LOG_LEVEL=error` | 仅 error 日志输出 |
| CLI 模式日志 | `z-agent-core --prompt "x"`（或 REPL）有结构化日志输出（`_io` 非 null） |
| CLI/Web 清理一致 | 两个入口启动均执行 trace 保留期扫描（`log.init` 统一挂载） |
| `ZAGENT_TRACE=1` 请求 | `.zagent/log/trace/<ts>-<pid>.jsonl` 生成，含 `latest.json`，事件可回放 |
| `ZAGENT_TRACE=1` 含耗时 | JSONL 中行为事件间穿插 `type:"timing"` 事件（label+ms），一份文件同时回放行为与耗时 |
| `ZAGENT_TIMING=1` 请求 | stderr 输出各阶段耗时（独立于 trace） |
| 日志落盘 | `.zagent/log/z-agent-core.log` 追加，无 ANSI 色码，目录自动创建 |
| 日志轮转 | 达到 `MAX_LOG_SIZE` 后 `.log`→`.log.1`→`.log.2`，最旧删除，保留 3 份 |
| trace 清理 | 启动时删除超过 7 天**或**超过最新 100 个的 `trace/*.jsonl`，`latest.json` 保留 |
| 并发写 | 多请求线程并发写日志不交错（行完整） |
| 正常请求回归 | 功能不变，新增日志不改变行为 |

## 涉及文件

| 文件 | 阶段 | 改动 |
|------|------|------|
| `src/util/log.zig` | P2/P2.5 | env 级别读取 + 文件双写 + ANSI 剥离 + 大小轮转 + `deinit()` |
| `src/util/trace.zig` | P3/P2.5 | 新增 JSONL 事件回放 + 保留期清理 |
| `src/util/timing.zig` | P4 | 新增计时插桩（TRACE 时写 `type:"timing"` 事件，TIMING 时 stderr 输出） |
| `src/frontends/web/handler.zig` | P1/P3/P4 | handleSSE 生命周期日志 + trace/timing 埋点 |
| `src/frontends/web/server.zig` | P2 | 已有 `log.init` 调用（138） |
| `src/frontends/cli/main.zig` | P2 | 补 `log.init` 调用 + `defer log.deinit()` |
| `src/core/agent.zig` | P1 | tool round/StormBreaker/阈值日志 |
| `src/io/provider.zig` | P1 | 流开始/retry/结束日志 |
| `src/core/compact.zig` | P1 | 压缩 start/end 日志 |
| `src/frontends/cli/App.zig` | P1/P3 | CLI 侧生命周期日志 + trace 埋点 |

## 明确不做

- **span 调用树**（opencode `withSpan`）：成本高，现有 tid/rid 已能关联单请求
- **事件总线**（pi-repos `EventBus`）：架构级解耦，后续 UI/日志订阅扩展时再评估
- **性能埋点**（每 token 增量日志）：只在阶段边界打点，避免热路径开销
- **后台清理定时器**：轮转/清理在写入时与启动时触发，不引入额外线程

## 备注

- 创建：2026-08-12
- 触发：`handleSSE` 崩溃（`std.Io.Mutex.unlock` 的 `unreachable`）无法从日志定位——暴露日志覆盖不足
- 参考：opencode（`packages/opencode/src`，Effect 日志/withSpan/trace.ts/OPENCODE_LOG_LEVEL）+ pi-repos（`packages/coding-agent/src/core/`，event-bus.ts/timings.ts/会话事件树）
- 目标落地版本：**0.2.7**（当前周期未发布，日志系统补完并入本批；日志系统为独立主题，若用户希望独立发布周期再调整目录）

## 实施差异记录

- trace 文件名时间戳单位**秒**（`<secs>-<pid>.jsonl`），cleanup 按秒解析（初稿毫秒 → 与 cleanup 不一致，实施时统一）
- 修复既有 bug：`server_start` 日志 event 参数带 `"event="` 前缀导致输出 `event=event=server_start`（event 参数改为不带前缀）
- `trace.writeLatest` 失败时删除 tmp 残留（M-04）；`rotateLocked` 静默 catch 注明 E-05 理由
- 日志句柄关闭：`log.deinit()` 由 CLI `App.deinit` 与 Web 正常退出路径调用；trace 文件句柄进程退出由 OS 回收（无 deinit）
