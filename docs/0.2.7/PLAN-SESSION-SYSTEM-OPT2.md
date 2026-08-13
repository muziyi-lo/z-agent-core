# Plan SESSION-SYSTEM-OPT2: 会话系统优化二期（自动压缩 + CLI 会话管理）

## 状态: ✅ 已实施（2026-08-12，P1 自动压缩 + P2 CLI /delete 均完成，git 0b46721）

## 背景

`SESSION-SYSTEM-OPT`（v0.2.7）完成了一期 P1-P5（消息 ID、按 ID 操作、分支树、分页、compact、undo）。本期承接其标注"列入后续"的缺口，以及 `docs/PLAN-FUTURE-SESSION-IMPROVEMENTS.md` P1 未实施项，统一在会话系统主题下分阶段交付：

- **P1: 自动压缩触发**——一期 P4 只实现手动 `POST /compact`，`agent.zig` 的上下文阈值监控只有警告分支（`agent.zig:241-248`），无自动触发路径
- **P2: CLI `/delete` + 会话路径常量化 + 删除保护**——CLI 无删除命令（Web 有 `handler.zig:619-630`）；`".zagent/sessions"` 在 `session.zig:386-387`、`init.zig:100`、`server.zig:132` 三处硬编码；Web 删除不保护运行中会话

两阶段独立可发，但同属会话系统运维能力，共享一套验证与涉及文件，故合并为一份计划，避免碎片化（一期教训：0.2.6/0.2.7 各只容纳一个计划导致版本过碎）。

## 目标

1. 长会话接近上下文窗口时**自动压缩**，无需用户手动 `POST /compact`
2. CLI 具备完整会话生命周期管理（`/list`/`/load`/`/fork`/`/new` 已有，补 `/delete`）
3. 会话目录路径单一来源，删除操作对运行中会话有保护

## P1: 自动压缩触发

> 本期设计与 pi-repos 压缩实现对照（`packages/coding-agent/src/core/compaction/compaction.ts` + `core/agent-session.ts:1786-1864`），修正三处正确性缺陷并吸收其保留/摘要策略。详见各小节"参考"标注。

### 触发位置：回合边界 vs agent 循环内

自动压缩需要在"何时检查、何处执行"上做选择：

| 方案 | 优点 | 缺点 |
|------|------|------|
| A. `agent.runTurn` 循环内触发 | 核心层一处实现 | **破坏回滚**：CLI 在 `pre_count` 后调用 `runTurn`，`api_error` 时 `rollbackTurn(pre_count)`（`App.zig:392`）记录压缩前消息数，压缩后 `truncateTo(N)` 因 `N>len` 失效（`session.zig:279-284`），错误回合残留无法回滚 |
| B. 回合边界触发（runTurn 调用前），核心逻辑函数化 | 压缩发生在回滚语义之外，`pre_count` 前完成，不破坏回滚；CLI/Web 各一行调用 | 调用点两处（但逻辑单一来源） |

**选择**：方案 B（修正）。核心层提供 `maybeAutoCompact()` 纯判定 + 执行函数，CLI 在记录 `pre_count` **之前**、Web `handleSSE` 在加载 session 之后、调用 `runTurn` 之前各调一次。**CLI 必须在 `pre_count` 前压缩**——若在 `pre_count` 后压缩，消息数被改变使 `pre_count` 失效，`api_error` 时 `rollbackTurn` 依旧破坏（与方案 A 同病）。单一实现、双前端共享（保留方案 A 的核心层优势）。参考：pi-repos 在 `agent_end` 后、下次 prompt 提交前检查（`agent-session.ts:1777`）。

### 上下文取数：最后一条 assistant usage，禁止求和

**参考**：pi-repos `calculateContextTokens` 只取**最后一条** assistant 消息的 `usage.totalTokens`（`agent-session.ts:1858`）——`total_tokens` 语义是当次请求的 `prompt+completion`，最近一次请求的 `prompt_tokens` 即当前上下文总量。

现有监控块（`agent.zig:224-229`）**求和所有消息的 `usage.total`**，只要任一消息有 usage 就启用——每条 `total` 是各自请求时刻的当次值，求和把重复历史上下文叠加，严重高估，会过早触发压缩。**修正**：改为取最后一条 assistant 消息的 `usage.total`；无 usage 时按 `content.len/4 + reasoning.len/4` 估算全部消息（现有兜底保留）。

### 阈值与降级策略

触发条件（修正后）：

- `context_window > 0` 且 `context_tokens > usable`（`usable = context_window - reserved`，`reserved = max(20000, window/10)`，保留现有预留策略）
- `context_tokens` = 最后一条 assistant 的 `usage.total`（或全部估算兜底），非求和
- 未被压缩边界拦截（见下节）
- 回合边界触发天然每回合至多一次（无需 `_auto_compacted` 标志——触发点在 `runTurn` 外，标志的 runTurn 内复位对触发点无效）

降级：摘要 LLM 失败 → **不失败回合**，回落注入现有 `[Notice]` 警告；压缩后重算 → 仍超阈值 → 注入警告兜底；`context_window == 0` → 不触发。自动压缩是"尽力而为"优化，任何失败不得让用户回合失败或丢失消息。

### 压缩边界：防 stale usage 重触发

**参考**：pi-repos 检查最后一条 assistant 时间戳是否晚于最后一次压缩，否则跳过（`agent-session.ts:1805-1810`）。压缩后保留的消息 usage 是压缩前的旧值（stale），若仍超阈值会误触发下一次压缩。

**实现**：`Session` 新增 `last_compact_id: ?u64`（压缩产生的 `[Compaction]` 消息 id）。触发判定取最后一条 assistant 消息，若其 `id <= last_compact_id` → 跳过（该 usage 来自压缩前）。`compactSession` 写回 `[Compaction]` 时记录该 id。

**`last_compact_id` 的 null 处理（评论 + 兼容性决策重审，2026-08-12）**：
- **null 无需特殊处理**：`last_compact_id == null` 视为"无压缩历史"，边界检查跳过，行为与未压缩会话一致，不设任何恢复/兼容路径
- **不做 `Session.load` 扫描恢复**——项目决策为非正式版不做向后兼容（`LRN-20260812-002`）：不为旧会话（一期手动 `[Compaction]` 等）识别历史压缩格式，避免兼容层与扫描复杂度。该字段纯内存派生，仅由 `compactSession` 写回 `[Compaction]` 时设置
- **误触发的代价幂等可控**：旧会话含历史 `[Compaction]` 且最后一条 assistant 为压缩前 stale usage 时，可能多触发一次压缩；但 `compactSession` 幂等（保留 ≤ 最小条数 → `compacted:0`），至多一次无谓摘要调用，且压缩后 `last_compact_id` 即被设置而稳定
- 正确性不受影响：压缩产生的 `[Compaction]` id 由 `allocateMessageId` 分配（大于全部旧消息 id，一期规则 id 不重编号），压缩前 assistant id < 边界 id、压缩后新消息 id > 边界 id，`<=` 判定在字段非 null 时精确拦截 stale 而放过新鲜 usage

### 摘要逻辑抽取：`core/compact.zig`

`handleCompact`（`handler.zig:736-795`）已实现手动压缩流程。抽为可复用函数，并按 pi-repos 升级保留/摘要策略：

```zig
/// LLM 摘要压缩会话。保留尾部（token 预算 + 最小条数双约束，tool 边界安全），
/// 其余压成一条 `[Compaction]` system 消息；若已有上次 `[Compaction]` 消息则
/// 作为 previous_summary 迭代更新。返回 compacted:0/1。
pub fn compactSession(
    provider: *provider.Provider,
    session: *session_mod.Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    keep_recent_tokens: u32,
) !bool;
```

Web 端点 `handleCompact` 改为薄封装（`agent_busy` 守卫、`applySessionModel`、JSON 响应保留在端点层）。

### 保留策略：token 预算而非固定条数

**参考**：pi-repos `findCutPoint`（`compaction.ts:386-448`）从后往前累计 `estimateTokens`，达到 `keepRecentTokens`（默认 20000）时取最近的合法 cut 点；cut 只在 user/assistant 消息处，**绝不切在 tool 消息**（tool 必须紧跟其 tool call）。

**实现**：保留尾部直到累计估算 token ≥ `keep_recent_tokens`（默认 20000），并设最小保留条数下限（20 条）与 tool 边界回溯（现有逻辑），二者取较大保留范围。大消息场景下按 token 自适应，避免固定 20 条时单条大消息撑爆窗口。

### 摘要质量：结构化 + 迭代更新

**参考**：pi-repos 用结构化格式（`SUMMARIZATION_PROMPT`：Goal/Constraints/Progress/Key Decisions/Next Steps/Critical Context，`compaction.ts:454-485`），且存在上次摘要时用 `UPDATE_SUMMARIZATION_PROMPT` 合并迭代（`compaction.ts:487-524`），另附 readFiles/modifiedFiles 清单。

**实现**：
- 摘要 prompt 改为结构化格式（目标 / 约束 / 进度 / 关键决策 / 下一步 / 关键上下文），要求保留精确路径、函数名、错误消息
- 若会话已有 `[Compaction]` system 消息，将其作为 `previous_summary` 放入 `<previous-summary>` 标签，用迭代更新提示词合并（避免连续压缩丢失早期历史）
- 文件操作清单（readFiles/modifiedFiles）列为后续可选项，不在本期强制

### 幂等与交互

- 回合边界触发（CLI 每回合、Web 每 SSE 请求一次 `maybeAutoCompact`）天然每回合至多一次；无需 `_auto_compacted` 标志
- 压缩的摘要请求使用 `phase_writer = null`（与 `handleCompact` 一致），不向 CLI/Web 流式输出
- 不新增配置项——沿用模型 `context_window` 作为开关（`=0` 即关闭）；`keep_recent_tokens` 用常量 20000
- 现有 `agent.zig:241-248` 警告块保留原逻辑作兜底：`maybeAutoCompact` 摘要失败时仍能注入 `[Notice]` 警告（其旧求和取数只影响警告触发时机，不影响正确性）
- **压缩后清空该会话 undo 栈（生命周期审查补充，2026-08-12）**：undo 的 `.delete`/`.truncate` 按**消息数组 index** 恢复（`insertMessageAt(index)`），compact 替换消息列表后旧 index 错位/插错位置。方案：`compactSession` 成功（`compacted:1`）后调用方清理该会话 `undo_map` 条目（`undo_map.remove(session_id)`）——compact 是结构性变更，依赖 index 的 undo 全部失效，清空最安全。不做按消息 id 的 undo 改造（成本高）。

### P1 实施步骤

**步骤 1**: 新增 `src/core/compact.zig`，实现 `compactSession`（token 预算保留 + tool 边界回溯 + 结构化摘要 + 上次 `[Compaction]` 迭代更新 + 写回时记录 `last_compact_id`）；`handleCompact` 改为薄封装。
**步骤 2**: `core/session.zig` 新增 `last_compact_id: ?u64` 字段（默认 null，仅 `compactSession` 写 `[Compaction]` 时设置，不做 load 恢复）；`agent.zig` 新增 `maybeAutoCompact()`——取最后一条 assistant usage（修正求和）→ 压缩边界拦截（null 跳过）→ 阈值判定 → `compactSession`，失败回落警告。
**步骤 3**: `cli/App.zig` REPL `processLine`（`App.zig:373`）与 single-turn 路径（`App.zig:222`）两处在 `pre_count` 记录**之前**调用 `maybeAutoCompact`；`web/handler.zig` `handleSSE` 在加载 session、`setSession` 后、`runTurn` 前调用。
**步骤 4**: 测试——`compactSession` 单测（token 预算/tool 边界/`compacted:0` 幂等/迭代更新）；`maybeAutoCompact` 测试（取数修正后超阈值才触发、stale usage 被压缩边界拦截、stub 抛错回落警告不失败回合、回滚语义保持——压缩后 `api_error` 仍能正确回滚）。

## P2: CLI `/delete` + 会话路径常量化 + 删除保护

> 本期与 pi-repos 删除实现对照（`packages/coding-agent/src/modes/interactive/components/session-selector.ts:380-396, 522-535, 631-666`）：当前会话保护方向一致；补两处缺失（路径规范化比较、CLI 二次确认），软删除列为选项待定。详见各小节"参考"标注。

### 路径常量化：单一来源

`".zagent/sessions"` 目前散落三处生产路径：

| 位置 | 用途 |
|------|------|
| `session.zig:386-387` | `flush()` 首次创建目录 + 拼接文件路径 |
| `frontends/init.zig:100` | 构造 `FrontendState.session_dir`（CLI 与 Web 共用） |
| `web/server.zig:132` | 构造 `Context.sessions_dir` |

在 `core/session.zig` 顶层定义常量并在全部生产点引用，保证 `Session.flush` 内部写盘与前端会话列表读取的目录永远一致：

```zig
pub const sessions_subdir = ".zagent/sessions";
```

测试中的硬编码（`session.zig` 测试 936/950/972/983/1011/1043/1099 行附近的 `"/.zagent/sessions"` 字符串与 join）一并替换为常量拼接，防止常量改名后测试静默沿用旧路径。

### 删除逻辑核心化：`session_ops.deleteById`

CLI `/delete` 与 Web 保护需要共享同一套"校验 → 定位 → 删除"逻辑。仿照 `session_ops.forkAt` 的模式，在核心层提供可单测函数：

```zig
/// 按会话 id 删除会话文件。校验 id 合法（拒绝路径穿越），
/// 返回被删文件路径（调用方用于运行中会话比较）。FileNotFound 上抛。
pub fn deleteById(
    allocator: std.mem.Allocator,
    io: Io,
    session_dir: []const u8,
    id: []const u8,
) ![]const u8;
```

- id 校验复用 `session_mod.Session.isValidId`（`session.zig:49-55`，拒绝 `.`、`/`、`\`），非法返回 `error.InvalidSessionId`
- 拼接 `{session_dir}/{id}.jsonl` → `Session.deleteFile` → `FileNotFound` 上抛供调用方区分
- 返回 `file_path`（分配器所有权转移给调用方），供运行中会话比较；调用方比较前需 `std.fs.path.resolve`（含 cwd）规范化

### 运行中会话保护：CLI 与 Web 分别落地

删除正在运行/加载的会话会导致：内存 Session 引用已释放的文件，下次 `flush` 重建空文件，id 映射错乱（教训 `LRN-20260806-002`）。保护方式按前端各自实现：

- **CLI**：`deleteSession` 在删除前**规范化比较**目标路径与 `self.session.path`。相等 → 拒绝"cannot delete the active session"，提示用 `/new` 开始新会话。当前 CLI 会话路径在首次 flush 前为 `null`，`null` 时不比较（无文件可删冲突）。
- **Web**：`handleSessionDelete` 增加检查，`ctx.default_session`（`*anyopaque` 指向 `state.session`，`server.zig:235`）的 path 与目标路径相等 → 拒绝 `.bad_request`。`default_session.path` 可能为 `null`（未持久化），仅在非 `null` 时比较。

> **路径比较必须规范化（参考 pi-repos `canonicalizePath`，`session-selector.ts:393-396`）**：禁止直接用 `std.mem.eql(u8, a, b)` 比较两个路径字符串。Windows 路径大小写不敏感、分隔符混用（`/` vs `\`）、`..` 与 `.\.` 前缀都会导致误判——该拦的没拦住或误拦。CLI 与 Web 两侧统一 `std.fs.path.resolve(allocator, &.{cwd, path})` 后比较。

### 删除级联清理（生命周期审查补充，2026-08-12）

**参考**：`LRN-20260719-013`（删除需级联清理关联数据）+ pi-repos 单文件树无孤儿。本地 `undo_map` 是 per-session 的 undo 条目表，删除会话后条目**永不清理**（`undo_map.remove` 全项目不存在）——`GET /history` 对已删会话残留、条目指针滞留。

**实现**：`handleSessionDelete`（Web）与 `deleteSession`（CLI，CLI 无 undo_map 则跳过）在删除文件成功后 `undo_map.remove(session_id)`。undo 条目深拷贝的消息存于进程级 arena（`undo_allocator`），不单独回收——清理目标是 `undo_map` 数据结构（防 history 残留/逻辑错误），内存按 arena 模型整体释放，文档注明即可。

### 命令注册与分派

- `command.zig builtin` 新增 `.{ .name = "delete", .description = "Delete a saved session", .args_hint = "id", .kind = .action }`——`dispatchCommand` 先走 `command_mod.find` 校验（`App.zig:468`），不注册会被判为 unknown command，注册后自动出现在 `/help`
- `App.zig dispatchCommand` 新增 `if (std.mem.eql(u8, name, "delete")) return self.deleteSession(stdout, args);`
- `deleteSession` 流程：空参 → usage 提示；**显示目标会话 id + 询问 `Delete session <id>? (y/N)` 二次确认**（参考 pi-repos 确认状态机，`session-selector.ts:522-535`）；`deleteById` catch（`InvalidSessionId` / `FileNotFound` / 其他）→ 对应错误提示；规范化路径匹配当前会话 → 拒绝；成功 → 提示已删除

### P2 实施步骤

**步骤 1**: `session.zig` 加 `sessions_subdir` 常量；替换 `session.zig:386-387`、`init.zig:100`、`server.zig:132` 的字面量（**server.zig 需补 `const session_mod = @import("../../core/session.zig");`**）；测试内 `"/.zagent/sessions"` 与 join 引用改用常量。
**步骤 2**: `session_ops.zig` 新增 `deleteById` + 测试（正常删除、`FileNotFound`、非法 id、返回路径正确）。
**步骤 3**: `command.zig` `builtin` 加 delete + 测试（`find("delete")` 命中、`args_hint == "id"`）；`App.zig` 加 `deleteSession`（含 Y/n 二次确认与规范化比较）与 `dispatchCommand` 分支。
**步骤 4**: `handler.zig` `handleSessionDelete` 删除前用 `std.fs.path.resolve` 规范化后比较 `ctx.default_session` path，相等 → `respondError(.bad_request, "cannot delete the active session")`；删除成功后 `undo_map.remove(session_id)`（级联清理）。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs
```

| 测试场景 | 预期结果 |
|----------|----------|
| 长会话超阈值（chat_fn stub） | 自动出现 `[Compaction]` 摘要消息，回合正常完成 |
| 上下文取数修正 | 求和旧逻辑 vs 最后一条 usage：仅最后一条超阈值才触发，不因历史消息叠加误触发 |
| stale usage 拦截 | 压缩后下一回合（最后一条 assistant 来自压缩前）不重复压缩 |
| `last_compact_id` null | 旧会话加载后为 null → 检查跳过，不拦截；触发一次压缩后字段设置即稳定 |
| 无压缩历史会话 | 边界检查跳过，行为不变 |
| 摘要失败 | 不失败回合，注入原警告 |
| 消息 ≤ 最小保留（20 条） | `compacted:0`，无压缩 |
| 压缩后 `api_error` 回滚 | CLI `rollbackTurn` 仍按 `pre_count` 正确回滚（`maybeAutoCompact` 在 pre_count 记录前触发，压缩后 pre_count 重新记录） |
| 压缩后 undo 清理 | `compacted:1` 后该会话 `undo_map` 条目清空，`GET /history` 为空 |
| 删除会话级联清理 | 删除后 `undo_map` 无该会话条目，`GET /history` 404 不残留 |
| 手动 `POST /compact` 回归 | 行为与一期 P4 一致（Web 端点复用后无回归） |
| `session_ops.deleteById` 正常删除 | 文件消失，返回正确路径 |
| 删除不存在的会话 | 上抛 `FileNotFound`，CLI 提示 not found |
| 非法 id（含 `/`、`.`、`\`） | `InvalidSessionId`，拒绝删除 |
| CLI `/delete <当前会话 id>` | 拒绝 "cannot delete the active session" |
| 路径规范化比较 | 目标路径含 `..`/大小写/分隔符差异时仍能正确识别当前会话（`resolve` 后比较） |
| CLI `/delete` 确认 | 未输入 `y` 不删除，输入 `y` 才执行 |
| CLI `/delete` 后 `/list` | 会话从列表消失 |
| Web 删除 `default_session` | 拒绝 `.bad_request` |

## 涉及文件（跨阶段累计）

| 文件 | 阶段 | 改动 |
|------|------|------|
| `src/core/compact.zig` | P1 | 新增摘要压缩共享逻辑 `compactSession`（token 预算 + 结构化 + 迭代更新） |
| `src/core/agent.zig` | P1 | 新增 `maybeAutoCompact`（取数修正 + 压缩边界 + 阈值判定） |
| `src/core/session.zig` | P1/P2 | `last_compact_id` 字段（P1）；`sessions_subdir` 常量 + 路径替换（P2） |
| `src/frontends/cli/App.zig` | P1/P2 | `processLine` 回合边界调 `maybeAutoCompact`（P1）；`/delete` 分派 + `deleteSession`（P2） |
| `src/frontends/web/handler.zig` | P1/P2 | `handleSSE` 回合边界调用 + `handleCompact` 改调 `compactSession`（P1）；`handleSessionDelete` 加保护（P2） |
| `src/frontends/init.zig` | P2 | 路径改用常量 |
| `src/frontends/web/server.zig` | P2 | 路径改用常量 |
| `src/session_ops.zig` | P2 | 新增 `deleteById` |
| `src/command.zig` | P2 | `builtin` 加 delete |

## 明确不做

- 本期不做 undo 栈持久化（一期 P5 内存栈已落，JSONL 事件持久化后续评估）
- 不做 LLM 自动标题（Future F2）与分支摘要注入（Future F4）——均依赖一期 compact LLM 基建，本期 P1 落地后再评估
- 不做会话列表分页与侧边栏 DOM diff（FUTURE-SESSION P2）
- 不做 context overflow 自动恢复（pi-repos 的 overflow 压缩 + 重试，`agent-session.ts:1812-1835`）——依赖 provider 层错误分类识别"上下文溢出"错误，成本高；本期阈值压缩已覆盖主要场景，overflow 恢复列入后续
- **不做回收站/软删除（选项待定）**：pi-repos 先 `trash` CLI 失败回落 `unlink`（`session-selector.ts:631-666`）；Windows 无 `trash` CLI（回收站需 Shell API，成本高）。可选替代：删除前移动到 `.zagent/trash/<timestamp>-<id>.jsonl` 软删除保留。本期保持永久删除 + 二次确认，软删除列入后续评估

## 备注

- 创建：2026-08-12
- 承接：`docs/0.2.7/PLAN-SESSION-SYSTEM-OPT.md`（一期）+ `docs/PLAN-FUTURE-SESSION-IMPROVEMENTS.md` P1
- 目标落地版本：**0.2.7**——会话系统为同一系统问题、同日迭代，不应按阶段切分版本。本期与一期 `SESSION-SYSTEM-OPT` 同目录、同版本周期，会话系统整体在 0.2.7 一次发布
