# Plan P0-FIXES: P0 紧急四件套（glob ** / ToolMeta 悬垂 / SSE 恢复 / overflow 恢复）

## 状态: 计划中

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无（四项 P0 均无外部前置依赖，可独立实施） | — | — |
| 本计划 N14 | 实施后解锁 | F7（JSON 统一模块，REMAINING.md:111 依赖链 `N14(UB) → F7`） |
| 本计划 N18 | 共用 | compactSession（`core/compact.zig`）——已有模块，无新增依赖 |

## 不做

- **中部 `**`（如 `a/**/b`）glob 路径感知匹配**——方案 B 只处理 `**/` 前缀；中部 `**` 需路径感知匹配，属 N20 正则演进
- **SSE 服务端心跳 + 断点续传重放**（N19 方案 C）——需并行心跳线程 + 断点续传，超出 P0；当前前端恢复（方案 A）+ 后期心跳为演进路径
- **`provider.zig:157` 之外的其他重试语义调整**——既有 ApiRateLimited 等退避行为保持；仅 overflow 跳过重试
- **魔法值全量清理**——本计划仅提取 P0 涉及文件（handler.zig/app.js）的命中项；全量清理按待办 #5 另立计划
- **抽象通用 StateMachine 工具**——`conn` 状态机单处消费，不满足"≥2 处"抽取判据（LRN-20260814-002）

## 问题

**现象**：P0 梯队四项独立缺陷（REMAINING.md:106 顺序 N13 → N14 → N19 → N18），互无依赖，全部为正确性/稳定性问题。
**根因**：四项各自独立的代码缺陷，非共享根因（不适用多症状因果矩阵，逐项溯源见各节）。

## 概览

- 改动 10 个文件：`src/tool/glob.zig`、`src/types.zig`、`src/tool/registry.zig`、`src/tool/{bash,read,write,grep,skill,edit,webfetch}.zig`（8 工具 testExec）、`src/io/provider.zig`、`src/core/agent.zig`、`src/frontends/web/app.js`、`src/frontends/web/handler.zig`
- 全部为修改既有文件，无新增模块、无新增外部依赖（`sse.zig` 已确认无改动，不列入实际改动文件）
- 思路：N13 去 `**/` 前缀（方案 B，`matchEntry` 统一入口）；N14 把 args JSON 所有权转移进 `ToolResult`（`finishExec` 单点）；N19 前端错误边界 + SSE 断连恢复状态机 + 禁自动重连；N18 provider 识别 context overflow 错误 → agent 自动压缩重试
- 参考实现：pi-repos `agent-session.ts:1812-1835`（overflow 压缩 + 重试，N18）

---

## N13 — glob `**` 递归匹配未实现

### 问题

**现象**：`glob {pattern:"**/*"}` 返回 `No files matched`，即使目录存在多个文件；与工具描述 "Supports recursive search with **" 矛盾。
**根因**：`glob.zig:101` 每层对单个 entry 名调用 `globMatch(entry.name, pattern)`，而 `**/*` 含 `/` 无法匹配单层文件名 → 恒 false。方案已在 `docs/0.2.6/PLAN-GLOB-DOUBLE-STAR.md` 定稿但从未落地（计划搁浅，与 JSON 模块同型的审计教训）。

### 设计要点

#### 方案对比（沿用 0.2.6 计划）

| 方案 | 改动 | 覆盖 `**/*.md` | 测试 |
|------|------|---------------|------|
| A（globMatch 内处理 `**/` 前缀） | 集中修匹配 | 需处理 rest | 加测试 |
| B（walkDir 调用点去前缀） | `pattern[3..]` | 自然 | 加测试 |

**选择**：方案 B。`**/` 前缀在 walkDir 递归遍历下等价"当前深度匹配 rest"，语义清晰、改动最小。

#### 边界确认

`walkDir` 已递归遍历全部层级（glob.zig:107-115），每层 entry.name 均为单层名。`**/rest` 去前缀后，`rest` 对任意深度的 entry.name 做普通 globMatch 即正确。`**` 单独（无 `/`）与 `*` 等价，现有 `pattern == "*"` 分支已覆盖；`**/*` 去前缀得 `*`，同样覆盖。

### 实施

**文件**: `src/tool/glob.zig`
**改动**: 提取 `matchEntry` 统一入口（`**/` 前缀处理内聚于此）→ walkDir 与夹具测试都调用它 + **夹具驱动测试**（参数化替代手写单测）
**关键代码**:

```zig
/// 统一匹配入口：`**/` 前缀在递归遍历下等价"当前深度匹配 rest"。
/// walkDir 与 fixture 测试共用——修复逻辑只存在于这一处。
fn matchEntry(name: []const u8, pattern: []const u8) bool {
    const effective = if (std.mem.startsWith(u8, pattern, "**/")) pattern[3..] else pattern;
    return globMatch(name, effective);
}

// walkDir 内，glob.zig:101 附近
if (matchEntry(entry.name, pattern)) { ... }
```

**注意**：只处理 `**/` 前缀；pattern 中部的 `**`（如 `a/**/b`）不在本次范围（当前工具语义是"递归遍历 + 单层名匹配"，中部 `**` 需路径感知匹配，属 N20 正则演进）。

#### 夹具驱动测试设计（审查补充 ×2）

评论者建议参数化测试夹具，避免 glob 模式扩展时遗漏覆盖。**第一轮验证了前置语法**：评论者假设的"Zig test 块支持 comptime 循环生成独立测试"**不成立**——test 块是顶层声明，comptime 循环内无法发射声明（`.tmp/` 实测 `comptime { for ... }` 只能 `@compileLog` 无法生成 `test`）。

**第二轮（本次）修正了 fixture 与实现不一致**：初版 fixture 直接测裸 `globMatch`，但方案 B 的修复在 walkDir 去前缀——`globMatch("any.txt", "**/*")` 实测返回 **false**（pattern 含 `/`），fixture 却断言 true，两者层错位。修正：**提取 `matchEntry` 作为唯一入口**，walkDir 与 fixture 都调它，实现与测试同步归位。`.tmp/` 实测：`matchEntry("any.txt","**/*")=true`、`matchEntry("doc.md","**/*.md")=true`、`matchEntry("foo","**/foo")=true`、`matchEntry("b","a/**/b")=false`——与 fixture 期望完全一致。

```zig
const MatchCase = struct {
    name: []const u8,    // 用例名，失败报告用
    pattern: []const u8, // glob 模式
    file: []const u8,    // 待匹配单层文件名
    want: bool,
};

// 数据驱动：新增模式 = 加一行；覆盖已有的 + 本计划新增的
const match_cases = [_]MatchCase{
    .{ .name = "bare-star",   .pattern = "*",        .file = "any.txt",  .want = true },
    .{ .name = "exact",       .pattern = "a.zig",    .file = "a.zig",    .want = true },
    .{ .name = "ext",         .pattern = "*.zig",    .file = "a.zig",    .want = true },
    .{ .name = "ext-reject",  .pattern = "*.zig",    .file = "b.txt",    .want = false },
    .{ .name = "double-star", .pattern = "**/*",     .file = "any.txt",  .want = true },
    .{ .name = "dstar-ext",   .pattern = "**/*.md",  .file = "doc.md",   .want = true },
    .{ .name = "dstar-reject",.pattern = "**/*.md",  .file = "doc.zig",  .want = false },
    .{ .name = "dstar-name",  .pattern = "**/foo",   .file = "foo",      .want = true },
    .{ .name = "mid-dstar-out-of-scope", .pattern = "a/**/b", .file = "b", .want = false }, // 明确标注中部 ** 当前不支持
};

test "glob: fixture-driven matchEntry" {
    inline for (match_cases) |c| {
        const got = matchEntry(c.file, c.pattern);
        if (got != c.want) {
            std.debug.print("FAIL {s}: pattern={s} file={s} got={} want={}\n", .{ c.name, c.pattern, c.file, got, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

// 集成用例（真实嵌套目录，覆盖 walkDir 递归 + 去前缀联动）：
test "glob: recursive **/* finds files in nested dirs" { ... }  // 嵌套目录 + **/*
test "glob: **/*.md matches md at any depth" { ... }            // 嵌套目录 + **/*.md
```

`match_cases` 表格覆盖三类：既有行为（`*`/精确/扩展名，防回归）、本计划新增（`**/` 前缀族）、**显式负例**（`a/**/b` 标注 out-of-scope 断言 false——防未来误实现后此用例静默通过，给扩展留探针）。

### 验证

1. **夹具单测**：`matchEntry` 数据驱动 9 条（含 1 条 out-of-scope 探针）全绿——测**统一入口**而非裸 `globMatch`，与 walkDir 实现一致
2. **集成测试**：`**/*` 与 `**/*.md` 各 1 条真实嵌套目录用例
3. `zig test src/tool/glob.zig --cache-dir .zig-cache` 全绿
4. `zig test src/test.zig --cache-dir .zig-cache` 回归

---

## N14 — ToolMeta 借用 args Value 悬垂 UB

### 问题

**现象**：meta 字符串字段（bash.command / read.path / glob.pattern 等）可能读取已释放内存，**侥幸运行**（REMAINING.md:130，B4 技术债，0.2.8 meta 落盘后风险升级）。
**根因**（时序链，已逐行走查）：
1. `registry.zig:25` `std.json.parseFromSlice(... args_json ...)` → `parsed` 持有 args Value 树
2. `registry.zig:29` `defer parsed.deinit()` — execute 返回即释放整棵树
3. 工具内 `meta.command = cmd_val.string`（bash.zig:170 等）— **零拷贝借用** args Value 的字符串切片（types.zig:66 注释明确该约定）
4. `registry.execute` 返回 → `parsed.deinit()` 已释放 → meta 字段悬垂
5. `agent.zig:432/434` `cb.render(ok.meta)` + `session.append(.meta = ok.meta)`（→ `dupeToolMeta` 读悬垂内存）→ UB

受影响的借用点（全部工具）：bash.zig:97/170（command）、read.zig:147/181/222/254（path）、grep.zig:61/77（path）、glob.zig:65/80（pattern/path）、write.zig:87（path）、edit.zig:128（path）、webfetch.zig:107（url）。

### 设计要点

#### 方案对比

| 方案 | 做法 | 优点 | 缺点 |
|------|------|------|------|
| A | 每个工具把 meta 字符串字段 `dupe` 到 ctx.allocator，ToolResult.deinit 释放 | 显式 owned | 8 个工具逐个改，deinit 需处理 9 个 variant，改动面大 |
| B | `ToolResult` 新增 `args_owned: ?std.json.Parsed(Value)`，`registry.execute` 把 `parsed` 所有权转移进 result，deinit 释放 | 工具代码零改动；借用约定不变；一处释放 | ToolResult 值语义需确认单次 deinit |

**选择**：方案 B。meta 的零拷贝借用约定（types.zig:66）保持成立——借用对象从"函数内临时 parsed"变为"随 ToolResult 存活的 owned parsed"，生命周期延到 `ToolResult.deinit`，与 `session.append` 的 `dupeToolMeta`（复制进 arena）时序相容。

#### 生命周期确认（运行期，与编译期构造点正交）

评论审查指出：文档混淆了"deinit 单次释放"与"struct 字段变更的编译期影响"两个**正交**问题。以下仅论证运行期生命周期；构造点编译期影响见下一节。

- `agent.zig:424` `var exec_result = ...execute(...)` → `if (exec_result) |*ok|` 取指针，`defer ok.deinit(self.allocator)`（:430）单次释放 ✓
- `ToolHooks.after(result: *ToolResult)`（agent.zig:428）— 指针传递，单实例 ✓
- `ToolResult.deinit`（types.zig:129）释放 `session_content` + `err_msg` + `args_owned`，无拷贝二次释放路径 ✓
- CLI render / handler appendMetaJson 均消费 `meta`（只读），发生在 deinit 前 ✓

#### 按值传递语义 + 不可浅拷贝契约（审查补充）

评论者指出 `finishExec` 按值传 `Parsed` 的生命周期注意点。**已核实 std 源码**（`std/json/static.zig:56-67`）：Zig 0.16 的 `Parsed(T)` 定义为 `{ arena: *ArenaAllocator, value: T }`——arena 是**指针**而非内嵌结构体。因此：

- `finishExec(exec, ctx, parsed.value, owned)` 按值传参拷贝的是 `arena` 指针 + `value` 树引用，**底层 buffer 共享**，不存在两份 arena 结构体副本
- `result.args_owned = owned` 转移后，原局部 `owned` 不再被 deinit（`errdefer` 仅错误路径触发）→ **单次释放，无双重释放** ✓
- registry 的 `defer parsed.deinit()`（registry.zig:29）**必须改为 `errdefer`**——否则 `finishExec` 把指针拷进 result 后，defer 提前释放 arena 使 result 悬垂。文档实施代码已按 errdefer 编写

**契约声明**：`ToolResult` 现含 `args_owned`（指针承载的 owned 资源），**禁止浅拷贝**。当前代码无按值拷贝路径（全部经指针或返回值 move）；若未来出现缓存/复制场景，必须深拷贝 args_owned（重新 parse）或改为 `*ToolResult` 传递。此约束将写入 `ToolResult` 定义处的 `///` 注释（见实施代码），防止未来误用。

#### 构造点编译期影响（已实测，不构成破坏性变更）

`ToolResult` 全库 80 个构造点（`rg "ToolResult\\{"` 统计）。审查者假设"向 struct 添加字段 → 所有构造点编译失败"——**实测推翻**：Zig 0.16.0 中**带默认值字段省略时取默认值，不报错**。

`.tmp/` 实测（zig 0.16.0）：

```zig
const Parsed = struct { arena: std.heap.ArenaAllocator, value: u32 };
const ToolResult = struct {
    session_content: []const u8,
    meta: u32 = 0,
    args_owned: ?Parsed = null,   // 带默认值
};
fn make() ToolResult { return ToolResult{ .session_content = "x" }; }  // 省略 args_owned
// 输出: args_owned=null
```

含 `ArenaAllocator` 字段的复杂类型同样省略成功。结论：

- `args_owned` 声明为 `?std.json.Parsed(...) = null` → 80 个构造点**零改动**，全部编译通过
- 运行时语义正确：只有 `registry.execute` 显式赋值 `result.args_owned = parsed`，其余构造点自动为 `null`，`deinit` 的 `if (self.args_owned) |*p| p.deinit()` 分支正确跳过
- 注意：AGENTS.md 陷阱表"struct literal omitting fields with defaults → fields get undefined"与本次实测（默认值生效）**矛盾**，已复核两处 `.tmp/` 编译运行均取默认值。以实测为准；若后续升级 Zig 版本，需重新验证该行为

#### testExec 路径悬垂 + 转移逻辑单点化（审查补充）

评论审查指出 struct 变更风险评估薄弱，且**方案 B 把 `args_owned` 转移分散在 registry + 8 处 testExec 手动管理，正确但易遗忘**。两点合并解决：

**薄弱点审计**：8 个工具 `testExec`（read/write/bash/grep/glob/skill/edit/webfetch）绕过 registry，各自 `parseFromSlice` + `defer parsed.deinit()` + `return execute(...)`（bash.zig:219-226 为例）。meta 借用该局部 `parsed`，`defer parsed.deinit()` 在 `testExec` 返回时释放 → 测试断言 `result.meta.*` 时读取悬垂内存（UB，`testing.allocator` 不检测 use-after-free）。

**单点化设计**：转移逻辑收敛为 `ToolResult` 的**一个方法** `finishExec`，registry 与全部 testExec 均委托——未来新增工具/测试调用同一方法，杜绝遗忘。封装也消除"每个工具手动记着转移"的心智负担。

| 薄弱点 | 位置 | 方案 |
|--------|------|------|
| registry 路径 | `registry.zig:24-39` | 委托 `finishExec` |
| **testExec 路径** | 8 个工具 `testExec` | 委托 `finishExec`（或 `execJson` 全封装） |
| validate 拦截 | `registry.zig:33-38` | `validate` 当前无实现（registry.zig:17 字段全为 null，9 工具均未赋值），errdefer 已覆盖；若未来启用需走同一 `finishExec` |

**为什么不做"每字段 dup"的方案 A**（评论者提出的替代方向）——已用源码验证不可行/更脆：
- webfetch.zig:109 `format = @tagName(format)` 是 **comptime 静态字符串，free 会崩**；方案 A 需对 meta 每个 variant 逐字段 dup 且要区分"静态/借用/owned"三态，deinit 需逐字段判断——比 args_owned 整树一次释放复杂得多
- webfetch.zig:110 `mime = contentMimeSuffix(output, ...)` 已**借用 session_content**（零拷贝约定），方案 A 需额外 dup 破坏既有借用；方案 B 下它随 session_content 存活，天然安全
- 方案 A 需改全部 9 个 ToolMeta variant 构造点 + deinit；方案 B 只动 ToolResult 两个方法

### 实施

**文件**: `src/types.zig`
**改动**: `ToolResult` 新增 `args_owned: ?std.json.Parsed(std.json.Value) = null`；`deinit` 释放该字段；新增**单点方法** `finishExec`——转移逻辑只存在于此，registry 与全部 testExec 委托

```zig
pub const ToolResult = struct {
    session_content: []const u8,
    err_msg: ?[]const u8 = null,
    user_output: ?[]const u8 = null,
    meta: ToolMeta = .none,
    /// Owned parsed args JSON tree; keeps zero-copy meta borrows alive
    /// until deinit (N14 fix: transferred via finishExec — single point).
    /// CONTRACT: ToolResult must NOT be shallow-copied — args_owned carries a
    /// pointer to a shared arena; a copy would double-deinit. Pass by pointer
    /// or move; deep-copy (re-parse) if caching is ever needed.
    args_owned: ?std.json.Parsed(std.json.Value) = null,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_content);
        if (self.err_msg) |e| allocator.free(e);
        if (self.args_owned) |*p| p.deinit();
    }

    /// Single ownership-transfer point: keeps `parsed` alive inside the result
    /// so zero-copy meta borrows stay valid until deinit. All callers
    /// (registry.execute, every tool's testExec) must delegate here — never
    /// assign args_owned by hand.
    pub fn finishExec(
        exec: anytype,
        ctx: ToolContext,
        parsed: std.json.Value,
        owned: std.json.Parsed(std.json.Value),
    ) !ToolResult {
        var result = try exec(ctx, parsed);
        result.args_owned = owned;
        return result;
    }
};
```

**文件**: `src/tool/registry.zig`
**改动**: `execute` 不再 `defer parsed.deinit()`；成功路径调 `ToolResult.finishExec`；失败/validate 拦截路径仍 `errdefer` 释放

```zig
var parsed = std.json.parseFromSlice(...) catch {...};
errdefer parsed.deinit();  // 仅错误路径释放
...
return types.ToolResult.finishExec(h.execute, ctx, parsed.value, parsed);  // 转移所有权，errdefer 不再触发
```

**注意**：`errdefer parsed.deinit()` 只在 `h.execute` 抛错时释放；成功路径 move 后 `parsed` 值不再使用（Zig 无 move 语义，赋值后不再触碰原变量）。validate 拦截分支返回错误时 parsed 仍需释放——用同一 `errdefer` 覆盖。

**文件**: `src/tool/{bash,read,write,grep,glob,skill,edit,webfetch}.zig`（8 个文件）
**改动**: 各工具 `testExec` 去掉 `defer parsed.deinit()`，改为委托 `finishExec`

```zig
fn testExec(ctx: types.ToolContext, args_json: []const u8) !types.ToolResult {
    const parsed = std.json.parseFromSlice(...) catch { ... return ... };
    return types.ToolResult.finishExec(execute, ctx, parsed.value, parsed);
}
```

**注意**：8 处 `testExec` 模式完全一致，机械替换。此改动使测试路径（`result.meta.*` 断言）不再读取悬垂内存——`testing.allocator` 虽不检测 use-after-free，但语义上修复了 UB。**单点化收益**：`finishExec` 是唯一出现 `result.args_owned = ...` 的地方，未来新增工具/测试复制 testExec 模式即自动正确，无记忆负担。

### 验证

1. 新增测试：构造工具结果后断言 `args_owned` 非空、meta 字符串可读（在 deinit 前）——**必须走 `testExec` 或 `registry.execute` 而非裸构造**，以覆盖 `finishExec` 转移路径
2. **转移点唯一性检查**：`grep "args_owned" src --type zig` 应只见 types.zig（声明 + finishExec + deinit）+ registry/testExec 的 `finishExec` 委托，无手工 `result.args_owned =` 直赋值
3. **不可浅拷贝契约检查**：`grep -n "var.*: types.ToolResult = " src --type zig`（或 `= result` / 数组存储）确认无 ToolResult 按值拷贝路径；未来实现命中此模式的代码必须深拷贝 args_owned
4. **构造点编译验证**：`zig build` 编译通过即证明 80 个构造点（默认值省略）全部兼容；编译期失败则逐点补 `args_owned = .none`
5. 现有 registry / bash / read / glob 测试全绿（`testing.allocator` 会捕获泄漏/双重释放）
6. 全量 `zig test src/test.zig --cache-dir .zig-cache`
7. `zig build -Doptimize=ReleaseSafe`（含 @ptrCast/@intCast 语义校验，N14 属指针生命周期改动）

---

## N19 — Web 错误边界 + SSE 断连恢复

### 问题

**现象**：一个 JS 报错整页白屏；SSE 断开只能手动刷新（REMAINING.md:135，PLAN-STREAM-ORDER-PARTS.md:278-280）。
**根因**：
1. app.js 无全局错误边界——事件 handler 抛出的未捕获异常中断后续渲染，可致页面状态损坏（白屏）。
2. `evtSrc.onerror`（app.js:1346）直接 `abortPrompt()` + 移除 spinner，**无重连、无恢复提示**，断开后用户只能刷新。
3. 服务端在断连时通过 `abort_map` 中止 agent 线程（handler.zig:1108-1120），会话已 flush 到磁盘——**数据在，只是前端不回显**。

### 设计要点

#### 方案对比（断连恢复路径）

| 方案 | 做法 | 优点 | 缺点 |
|------|------|------|------|
| A | 断连后前端自动重新 loadSession 恢复已持久化消息 + 显示"连接中断"横幅 | 零后端改动；数据完整（服务端已 flush） | 正在流式的部分丢失（可接受，服务端 abort 后本来就不完整） |
| B | 依赖 EventSource 自动重连 | 浏览器原生 | 重连会重发 prompt 请求 → **重复 append 用户消息**，不可用 |
| C | 服务端 SSE 心跳 + 重放 | 最完整 | 需要并行心跳线程 + 断点续传，工程量大，超出 P0 |

**选择**：方案 A。核心洞察：SSE 流式是同步阻塞的（handler.zig:1140 `runTurn` 直到 done 才返回），断连时服务端已 abort 且会话已持久化，前端恢复 = 重新拉取会话。**必须禁用 EventSource 自动重连**（否则重发 prompt 重复消息）。

#### 恢复失败降级 + 状态机收敛（审查补充）

评论审查指出两点：`loadSession`（app.js:769）失败时仅 `console.error` + `return`（:772），若断连瞬间服务端仍不可用，前端会**永久停留在"连接中断"横幅**；且初步方案 `onerror → recoverSession → loadSession.catch → setTimeout → loadSession.catch` 是**三层回调嵌套**，后续加心跳/手动重试会恶化为回调地狱。

**决策 1（重试策略）**：单次延迟重试 + 降级横幅，限断连场景，不改动 `loadSession` 本身（它是侧边栏/初始加载/断连恢复三处复用，内建重试会引入不希望的阻塞语义）。

| 重试选项 | 做法 | 权衡 |
|---------|------|------|
| 无限重试 | 指数退避持续拉取 | 服务端长宕机时前端反复请求，噪音 |
| **单次重试 + 降级**（选） | 等 1.5s 重试一次，仍失败显示"请刷新页面"横幅 | 覆盖瞬时故障，失败有明确出口 |
| 零重试直接降级 | 立即显示刷新提示 | 瞬时抖动也逼用户手动刷新 |

**决策 2（状态机）**：SSE 连接生命周期收敛为简单有限状态机 `conn`，**所有异步回调只调 `conn.go(event)` 单一分发点**，回调嵌套被状态转移表取代。未来加心跳/手动重试只需新增 (phase, event) 转移，不再加深回调。

状态转移表：

| 当前状态 | 事件 | 动作 | 下一状态 |
|----------|------|------|----------|
| idle | `send` | 建立 EventSource | streaming |
| streaming | `done` | close evtSrc | idle |
| streaming | `disconnect` | close + abortPrompt + 横幅 + 首轮恢复 | recovering |
| recovering | `recover_success` | 清横幅、回填消息 | idle |
| recovering | `recover_fail`（retry < 上限） | 1.5s 定时器后重试 | recovering |
| recovering | `recover_fail`（retry 达上限） | 横幅降级 error | degraded |
| recovering | `send`（用户恢复中发新消息） | 清恢复定时器、重置计数、正常发流 | streaming |
| degraded | `send`（用户重试） | 重置计数、正常发流 | streaming |

**注意**：
- `done` 与 `disconnect` 是两个不同事件（浏览器对 `evtSrc.close()` 不触发 `onerror`），状态机天然区分正常结束与断连，避免恢复流程误触发
- **`recovering --send--> streaming` 是缺省兜底**：输入框 UI 在 `isStreaming` 为 true 时禁用发送（`send-btn` onclink 判断），恢复期间 `isStreaming` 通常为 false，用户可能发送——此时必须**取消 pending 恢复定时器并重置计数**，否则 1.5s 后旧定时器触发 `conn.recover()` 在新流中抢跑，污染流式状态。此转移保证任何状态下用户主动发起都以 `send` 为准，恢复流程让位

#### 交互矩阵：N19 状态机 × N18 overflow（G16 门禁）

两特性交叉边界逐格确认（评审审查补充）：

| × | 状态机（N19） | overflow 压缩重试（N18） |
|---|--------------|------------------------|
| 状态机（N19） | — | **无关**：overflow 恢复是后端 agent 内部逻辑，SSE 流式在 runTurn 成功返回后走正常 `done` 转移（`streaming --done--> idle`），前端不感知压缩发生 |
| overflow（N18） | **无关** | — |

关键点：N18 压缩重试发生在 `runTurn` 内部（handler.zig:1140 同步调用），SSE 连接持续存活，前端状态机仅收到正常流式事件；仅当压缩后仍失败时 `finish .api_error` → handler 写 error 帧 → 前端 `error` 事件处理（app.js:1336 既有）显示文案，不触发状态机 `disconnect`。两特性互不干扰。

#### 错误边界（白屏修复）

全局 `window.addEventListener('error')` + `'unhandledrejection'` → 在消息区顶部显示可恢复错误横幅（含错误信息），而非让异常静默中断渲染。初始加载阶段错误则显示启动错误页。

### 实施

**文件**: `src/frontends/web/app.js`
**改动**:
1. 全局错误边界：`window` 上注册 error/unhandledrejection 监听，错误横幅（`#messages` 顶部插入 `.status-msg.error`），不抛给默认处理
2. 新增 SSE 连接状态机 `conn`（phase: idle/streaming/recovering/degraded）+ 单一分发 `go(event)`；`recover()` 内建单次延迟重试 + 失败降级
3. `evtSrc.onerror`（:1346）：改为 → `conn.go('disconnect')`（状态机内统一处理 close + abort + 恢复）
4. `done` 正常路径（:1352）→ `conn.go('done')`；`sendPrompt` 起点 → `conn.go('send')`
5. 移除 spinner（现有逻辑保留）

**关键代码**:

```js
// SSE 连接状态机（单一分发点，消除回调嵌套）
var conn = {
  phase: 'idle',          // idle | streaming | recovering | degraded
  retry: 0,
  timer: null,
  RETRY_DELAY_MS: 1500,
  MAX_RETRY: 1,
  go: function(event) {
    switch (this.phase) {
      case 'idle':
        if (event === 'send') this.phase = 'streaming';
        break;
      case 'streaming':
        if (event === 'done') { this.phase = 'idle'; }
        else if (event === 'disconnect') { this.retry = 0; this.phase = 'recovering'; this.recover(); }
        break;
      case 'recovering':
        if (event === 'recover_success') { this.cancelRetry(); this.phase = 'idle'; }
        else if (event === 'recover_fail') {
          if (this.retry < this.MAX_RETRY) {
            this.retry++;
            this.timer = setTimeout(function() { conn.recover(); }, conn.RETRY_DELAY_MS);
          } else {
            this.phase = 'degraded';
            showStatusBanner('连接中断，请刷新页面恢复', 'error');
          }
        }
        else if (event === 'send') { this.cancelRetry(); this.retry = 0; this.phase = 'streaming'; }
        break;
      case 'degraded':
        if (event === 'send') { this.retry = 0; this.phase = 'streaming'; }
        break;
    }
  },
  cancelRetry: function() {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
  },
  recover: function() {
    if (!currentId) return;
    showStatusBanner('连接中断，正在恢复会话…', 'warn');
    loadSession(currentId).then(
      function() { conn.go('recover_success'); },
      function() { conn.go('recover_fail'); }
    );
  }
};

// onerror 替代实现（app.js:1346）
evtSrc.onerror = function() {
  if (evtSrc) { evtSrc.close(); evtSrc = null; }
  abortPrompt();
  conn.go('disconnect');
};
```

**注意**：`abortPrompt` 内部已 `evtSrc.close()`，先 close 再调是幂等保护；`loadSession` 成功（含重试后成功）时自动清除流式状态（`:776 setStreaming(false)`）并回填已持久化消息，横幅由 `recover_success` 转移清；`conn.recover()` 的 `.then/.catch` 把同步异常与 Promise 拒绝都收敛到 `conn.go`，不再手工嵌套；`done` 路径显式 `conn.go('done')` 而非依赖 onerror（`evtSrc.close()` 不触发 onerror，状态机据此区分正常结束与断连）。**`cancelRetry` 是 `recover_success` 与 `recovering--send` 共用的清定时器辅助**——没有它，`recovering` 状态下用户发新消息后，旧定时器仍会在新流中触发 `recover()`。

### 验证

1. 浏览器实测（chrome-cdp skill）：断开 SSE（如 kill 服务端进程）→ 前端显示横幅 + 自动恢复已发送消息
2. **恢复失败降级**：断连后服务端保持不可用 → 1.5s 重试一次 → 横幅降级为"连接中断，请刷新页面恢复"，前端不无限请求
3. **瞬时故障恢复**：断连瞬间服务端短暂不可用后恢复 → 1.5s 重试成功回填消息
4. **状态机转移单测**（前端 Node 测试，走 run-tests.mjs 提取 `conn.go`）：idle→send→streaming、streaming→done→idle、streaming→disconnect→recovering→recover_success→idle、recovering 二次 recover_fail→degraded、**recovering→send→streaming（断言清定时器 + retry 归零，旧定时器不再触发 recover）**、degraded→send→streaming——断言 phase 沿转移表精确
5. 正常完成流：done 后无横幅、无重连请求
6. 注入 JS 异常 → 显示错误横幅而非白屏
7. Node 前端渲染测试：`node tests/frontend/run-tests.mjs`（37 断言）保持通过

---

## N18 — context overflow 自动恢复

### 问题

**现象**：上下文溢出错误（API 返回 `context_length_exceeded` / `maximum context length`）后回合直接失败，会话无法继续（REMAINING.md:134，OPT2.md:231"列入后续"）。
**根因**：
1. `provider.zig` 错误分类只有 `ApiRateLimited` / `ApiKeyNotSet` / `ApiError`（:425-474），无 context overflow 类别。
2. `isRetryableBody`（:773-779）关键词不含 context/token——溢出错误走 `ApiError`，不重试、不压缩。
3. `agent.zig:331-340` `raw_resp catch` 将一切非 Interrupted 错误归为 `api_error` finish，会话卡死。
4. 阈值压缩（`maybeAutoCompact`）仅覆盖"预估超阈值"，无法覆盖"API 实际拒绝但预估未触发"（usage 缺失/估计偏差）。

### 设计要点

#### 方案对比

| 方案 | 做法 | 优点 | 缺点 |
|------|------|------|------|
| A | provider 识别 overflow 错误返回 `error.ContextOverflow`；agent 捕获后强制 compact 并重试一次 | 定向解决；复用现有 compactSession | 需防重试死循环；摘要调用自身可能溢出（消息更短，风险低） |
| B | 扩大阈值压缩触发面（更低阈值） | 简单 | 不解决"API 实际拒绝"场景，误压缩频繁 |
| C | 不做（维持 api_error） | 零改动 | 会话卡死，P0 目标未达成 |

**选择**：方案 A。provider 层新增 `error.ContextOverflow` 分类（在 SSE error 帧解析 :289-292 与 error_body 检查 :450 两处加判断）；agent `runTurn` 捕获该错误 → `compactSession` → 用 `overflow_retried` 标志限制**最多重试一次**防死循环；摘要调用所用消息为压缩前子集（`compactSession` 内部 sum_msgs，:161-167），长度必然小于当前上下文，溢出风险可忽略。

#### 压缩重试失败的明确提示（审查补充）

评论审查指出：**`compactSession` 自身的 LLM 摘要调用也可能再次抛 `error.ContextOverflow`**——虽理论上摘要消息更短，但极端情况（模型窗口极小 / 保留尾部超大）下仍可能溢出。此时需保证两点：

1. **不吞错误、不冒泡成裸 `ContextOverflow`**：`compactSession` 调用必须显式 catch（:324 现状是裸调用，抛错会冒泡出 catch 块 → `runTurn` 抛错 → 调用方 handler.zig:1140 的 catch 分支收到 `error.ContextOverflow`，Web 端显示裸错误名）。改为 catch 后统一转为 `finishTurn(.api_error, error_msg)`，由上层既有 api_error 通道展示。
2. **区分"未压缩重试"与"压缩后仍失败"**：`error_msg` 用不同文案，用户在 CLI/Web 看到明确语义，而非笼统 "api_error"。

CLI 侧 `error_msg` 已透传（App.zig:450-451 `writeLabeled(.err, msg)`）；Web 侧当前正常返回路径**只写 done 帧、不透传 error_msg**（handler.zig:1169-1173），需在 `finish == .api_error` 时补写一条 `error` 帧（前端 app.js:1336 已有 `error` 事件处理），否则 Web 用户只见"流结束"无错误信息。

#### 错误特征识别

OpenAI 兼容接口的溢出错误形态：error 帧 `{"error":{"type":"context_length_exceeded","message":"This model's maximum context length is ... tokens."}}`，或非 SSE error body 含 `"maximum context length"` / `"context length"` / `"token limit"`。新增 `isContextOverflowError(body)` / `isContextOverflowBody(body)` 关键词匹配（大小写不敏感，复用 `containsIgnoreCase`）。

#### switch 枚举风险排查（审查补充）

评论审查要求列出 `error.ContextOverflow` 引入后需要复查的 switch 位置。已全量排查 provider 错误传播链：

| 位置 | 形态 | 影响 | 处理 |
|------|------|------|------|
| `provider.zig:157` | 重试 `switch (err)`，`error.Interrupted, error.ApiError => return err, else => 重试` | 新错误落入 `else` → **5 次退避后上抛**（延迟 = 500+1000+2000+4000+8000 = **15.5 秒**，加每次 curl 连接/网络开销，用户等待 30 秒+，且 5 次请求注定失败） | **P0 必改**：加 `error.ContextOverflow => return err`（见实施第 4 步） |
| `agent.zig:333` | `runTurn` catch `switch (err)`，`error.Interrupted => ..., else => api_error` | **本计划新增显式 `error.ContextOverflow` 分支**（见实施代码） | 必改 |
| `compact.zig:169` | `try provider.chatCompletionStreaming(...)` | `ContextOverflow` 直接上抛给调用方（handler.zig:888 / agent.zig:174 / tool/compact.zig:103） | 无 switch，不改 |
| `title.zig:263` | `... catch null` | 溢出时标题静默失败，可接受 | 不改 |
| `tool/compact.zig:103` | `try` → 上抛给 `generateSummary` catch | `@errorName(err)` 拼消息，非 switch | 不改 |
| `handler.zig:888` | 手动 compact 端点 `catch \|err\|` → `respondError("summarization failed")` | 显示笼统失败文案，可接受 | 不改 |
| `App.zig:245/404` | CLI `runTurn catch \|err\| return err` | `ContextOverflow` 返回给上层（REPL 顶层），由顶层显示 | 不改 |
| `agent.zig:174` | `maybeAutoCompact` `catch {}` | 吞错，压缩失败降级为警告 | 不改 |

**结论**：`error.ContextOverflow` 是显式错误名（非 enum 穷举），所有 `switch (err)` 均有 `else` 兜底或为 `try`/`catch null`——**无编译期穷举失败风险**。需要加显式分支的共两处：`agent.zig:333`（压缩重试入口）与 `provider.zig:157`（跳过 provider 层退避）。后者原标 F7，评论审查后纳入 P0——理由：5 次注定失败的请求叠加 15.5 秒退避 + curl 网络开销，严重削弱"快速自动恢复"目标，且改动仅一行。

#### 错误集映射表（G10d 门禁）

`error.ContextOverflow` 跨模块传播的完整错误 → 处理映射（评审审查补充）：

| 发送方模块 | 返回的错误 | 接收方模块 | 匹配方式 | 处理行为 |
|------------|-----------|-----------|----------|----------|
| `provider.chatCompletionStreaming` | `error.ContextOverflow` | `agent.zig:333` runTurn catch | `error.ContextOverflow =>` | compact + 重试一次；失败转 `finishTurn(.api_error, error_msg)` |
| `provider.chatCompletionStreaming` | `error.ContextOverflow` | `compact.zig:169`（摘要调用） | `try` 直接传播 | 上抛给 compactSession 调用方 |
| `core/compact.zig compactSession` | `error.ContextOverflow`（摘要二次溢出） | `agent.zig:174` maybeAutoCompact | `catch {}` | 吞错，压缩失败降级为警告（既有行为） |
| `core/compact.zig compactSession` | `error.ContextOverflow` | `agent.zig:310` 本计划新增 catch | `catch` → 转文案 | `api_error` + "auto-compaction failed"（不冒泡） |
| `core/compact.zig compactSession` | `error.ContextOverflow` | `handler.zig:888` 手动 compact | `catch \|err\|` | `respondError("summarization failed")`（既有行为） |
| `tool/compact.zig generateSummary` | `error.ContextOverflow` | `tool/compact.zig:43` | `catch` → `@errorName` | 工具结果报错文案（既有行为） |
| `title.zig` 标题 subcall | `error.ContextOverflow` | `title.zig:263` | `catch null` | 标题静默失败（既有行为） |
| `agent.runTurn` | `error.ContextOverflow`（本轮未处理冒泡） | `App.zig:245/404` CLI | `catch return err` | REPL 顶层显示错误名（既有行为） |

所有既有接收方的处理行为不变；本计划仅新增 `agent.zig:333`（压缩重试）与 `agent.zig:310`（压缩自身失败转文案）两个新消费点，均显式 `catch` 不冒泡。

#### 日志覆盖规划（G15 门禁）

评审审查要求补状态变更/边界操作日志。本计划新增两个跨组件边界操作，规划如下（对齐既有 `sse_*`/`provider_*` 前缀约定）：

| 事件名 | 级别 | 触发点 | 字段 |
|--------|------|--------|------|
| `agent_overflow_retry` | `biz_info` | runTurn catch `error.ContextOverflow` 且首次重试 | `retry=1` |
| `agent_overflow_retry_fail` | `biz_info` | 压缩后重试仍 overflow（`compaction insufficient`） | `retry=2` |
| `agent_compact_failed` | `biz_error` | compactSession 抛错（`auto-compaction failed`） | `err=@errorName` |
| `provider_overflow_skip_retry` | `log.dbg` | callWithRetry `error.ContextOverflow => return err` | `attempt={d}` |
| `sse_conn_phase` | `log.dbg`（前端 console，非后端） | app.js 状态机 `conn.go` 转移 | `phase→next`, `event` |

前端日志用 `console.debug` 落 `conn.go` 转移点（仅 recovering/degraded 关键转移用 `console.warn`），不污染热路径。后端 4 条事件对齐 `log.*` 既有调用形态（`log.dbg(0,0,name,msg,args)` / `log.biz_info(0,0,name,msg,args)`）。

### 实施

**文件**: `src/io/provider.zig`
**改动**:
1. 新增 `error.ContextOverflow`
2. `isRetryableError`（:733）前先查 overflow：error JSON `type`/`message` 含 overflow 关键词 → `return error.ContextOverflow`（:289-292 分支内）
3. `chatCompletionStreamingOnce` error_body 路径（:450 之前）加 `if (isContextOverflowBody(error_body_buf.items)) return error.ContextOverflow`
4. **重试循环（:157）加 `error.ContextOverflow => return err`**：overflow 是确定性失败（上下文已超限），重试必然再失败，跳过 5 次退避（15.5s+）直接上抛给 agent 做压缩重试

```zig
const overflow_kw = [_][]const u8{ "context_length_exceeded", "maximum context length", "context length", "token limit", "too long for the requested model" };
fn isContextOverflowBody(body: []const u8) bool {
    for (overflow_kw) |kw| if (containsIgnoreCase(body, kw)) return true;
    return false;
}

// callWithRetry 内 switch（provider.zig:157 附近）
switch (err) {
    error.Interrupted, error.ApiError, error.ContextOverflow => return err,
    else => { log.dbg(...); continue; },
}
```

**文件**: `src/core/agent.zig`
**改动**: `runTurn` 内 `raw_resp catch`（:331-340）增加 `error.ContextOverflow` 分支 → compact + 重试一次

```zig
var overflow_retried = false;
...
const resp = raw_resp catch |err| {
    return switch (err) {
        error.Interrupted => { signal.reset(); return finishTurn(self, new_msgs, .interrupted, @errorName(err)); },
        error.ContextOverflow => {
            if (!overflow_retried) {
                overflow_retried = true;
                const compacted = compact_mod.compactSession(self.provider_ref, self.session_ref, self.allocator, self.io, compact_mod.DEFAULT_KEEP_RECENT_TOKENS) catch {
                    // 摘要调用自身失败（含二次 overflow）：不冒泡裸错误，统一转 api_error + 明确文案
                    return finishTurn(self, new_msgs, .api_error, "context overflow: auto-compaction failed");
                };
                if (compacted) {
                    continue;  // 重试（循环顶重新评估中断/轮次上限）
                }
            }
            // 首次 overflow 但无可压缩，或压缩后重试仍 overflow
            return finishTurn(self, new_msgs, .api_error, "context overflow: compaction insufficient");
        },
        else => finishTurn(self, new_msgs, .api_error, @errorName(err)),
    };
};
```

**文件**: `src/frontends/web/handler.zig`
**改动**: 正常返回路径（:1169-1173 写 done 帧前）补 api_error 的 error 帧透传

```zig
if (result.finish == .api_error) {
    var ebuf: [256]u8 = undefined;
    const emsg = result.error_msg orelse "api_error";
    const epayload = std.fmt.bufPrint(&ebuf, "{{\"code\":\"api_error\",\"message\":\"{s}\"}}", .{emsg}) catch "{}";
    sse_state.writeFrame("error", epayload) catch {};
}
```

**注意**：
- `overflow_retried` 声明位置在 `while (true)` 循环外，跨轮保持——一轮最多一次 overflow 压缩重试
- `continue` 后循环顶会检查 `_aborted` 与 `tool_rounds`，`tool_rounds` 未递增（本轮 LLM 请求未成功），不触发 max_rounds 误判
- `compactSession` 返回 `false`（无可压缩）→ `api_error` + "compaction insufficient"；抛错（含摘要二次 overflow）→ `api_error` + "auto-compaction failed"——两条文案区分两种失败形态，且都不再冒泡裸错误
- 三条 error_msg 文案均从 catch 块内稳定返回，不依赖 `@errorName`，用户可见语义明确
- CLI `rollbackTurn` 语义：overflow 发生在 runTurn 内部且压缩后重试成功 → `new_msgs` 已含本轮消息，`pre_count` 记录于调用方（App.zig），与既有 api_error 回滚逻辑兼容（OPT2.md:199 已确认压缩后回滚语义）；失败路径 finish `.api_error` 走既有 rollback + flush，行为不变

### 验证

1. 新增 `isContextOverflowBody` 单测（true：`maximum context length`、`context_length_exceeded`；false：`rate limit`、空串）
2. **provider 不重试 overflow**：新增 callWithRetry 单测——mock `chatCompletionStreamingOnce` 返回 `error.ContextOverflow`，断言 `chatCompletionStreaming` **立即上抛、零次退避**（不进入重试循环）
3. 新增 agent 测试：mock chat 首次返回 `error.ContextOverflow`、compact 成功、二次成功 → finish `.stop`，`overflow_retried` 生效
4. mock 首次 overflow + compact 返回 false → finish `.api_error` 且 `error_msg == "context overflow: compaction insufficient"`
5. mock 首次 overflow + compact 抛 `error.ContextOverflow`（摘要二次溢出）→ finish `.api_error` 且 `error_msg == "context overflow: auto-compaction failed"`（不冒泡裸错误）
6. Web 端 `api_error` finish → 透传 error 帧（前端显示明确文案，非仅流结束）
7. 全量回归 + `zig build -Doptimize=ReleaseSafe`

---

## 附带清理 — P0 涉及文件的魔法值提取（待办 #5 局部触达）

### 问题

待决事项 #5（魔法值全量审查）按 D-04 判据（同值 ≥2 处 / 跨模块 / 有业务语义）扫描。本计划不改动的文件不在此范围（全量清理另立计划）；**仅提取本次 P0 动到的文件内、D-04 命中且顺手的魔法值**，避免漂移与本次改动耦合。

**已核查的 P0 涉及文件魔法值**（源码逐处验证）：

| 位置 | 值 | 判据 | 结论 |
|------|-----|------|------|
| `handler.zig:282` `/session` 分页默认 limit | `50` | 同值多处 + 业务语义 | **提取** |
| `handler.zig:385` `/session/:id/messages` 分页默认 limit | `50` | 同值多处 + 业务语义 | **提取**（与上行共享同一常量） |
| `handler.zig:473` `/session/:id/message` 分页默认 limit | `50` | 同值多处 + 业务语义 | **提取**（同一常量） |
| `handler.zig:1022` undo 栈 cap | `20` | 与 :35 注释"cap 20"值耦合（注释契约 + 实现漂移风险） | **提取** |
| `app.js:340` `SESSIONS_PAGE` | `50` | **已存在命名常量但 :771/:853 硬编码 `limit=50` 未复用**（值已漂移风险最高） | **提取**：:771/:853 改用 `SESSIONS_PAGE` |
| `app.js:771/853` 硬编码 `?limit=50` | `50` | 见上行 | 复用常量 |
| N18 overflow 关键词 | `context_length_exceeded` 等 5 项 | 数组字面量（单处，无跨模块复用） | 不提取（符合 D-04"无耦合裸值不强制"） |
| N18/N19 新增超时 | 1.5s 重试延迟 / error 帧 buf 等 | 单处或局部语义 | 不提取 |

**不做**：`handler.zig:1094` SSE 头部、`:1022` 之外的其他单处数字、glob.zig 已有 `MAX_OUTPUT`/`MAX_ENTRIES` 常量（已合规）——均不满足 D-04 判据。

### 实施

**文件**: `src/frontends/web/handler.zig`
**改动**:

```zig
const SESSION_PAGE_LIMIT: usize = 50;   // 分页默认页大小（3 处共享）
const UNDO_CAP: usize = 20;             // 每会话 undo 栈上限（:35 注释契约 + :1022 实现）
```

- :282/:385/:473 的 `catch 50` / `else 50` → `catch SESSION_PAGE_LIMIT` / `else SESSION_PAGE_LIMIT`
- :1022 `if (list.?.items.len > 20)` → `> UNDO_CAP`
- :35 注释同步为"cap `UNDO_CAP`"

**文件**: `src/frontends/web/app.js`
**改动**: :771 `?limit=50` → `?limit=' + SESSIONS_PAGE`；:853 同理（模板串拼接，与现有 `?limit=50` 字面量格式一致）

**注意**：handler.zig 的 3 处 limit 语义一致（都是分页默认页大小），合并为一个常量不产生歧义；app.js 侧服务端与前端必须同值，提取后值漂移风险从"跨文件手工同步"降为"同一常量引用"。

### 验证

1. `zig build` 编译通过（handler.zig 常量替换）
2. `node tests/frontend/run-tests.mjs` 通过（app.js `SESSIONS_PAGE` 复用不改渲染逻辑）
3. 浏览器实测分页：会话列表 / 消息加载正常，`?limit=50` 请求与常量一致
4. `grep "50" handler.zig` 不再出现分页默认值裸字面量（仅常量声明处）

---

## 验证（整体）

```powershell
zig build
zig test src/tool/glob.zig --cache-dir .zig-cache
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
zig build -Doptimize=ReleaseSafe
node tests/frontend/run-tests.mjs
node scripts/check-catch-silent.mjs . --audit
node scripts/check-arch.mjs .
```

| 测试场景 | 预期结果 |
|----------|----------|
| glob `**/*` 真实目录调用 | 递归列出全部文件 |
| glob `**/*.md` | 任意深度 .md 匹配 |
| globMatch 夹具 9 条（测 `matchEntry`） | 全部按预期（含 `a/**/b` out-of-scope 探针 false） |
| ToolResult deinit 后 meta 可读（测试） | 无 UB、无泄漏 |
| 全量测试 | All N tests passed |
| 前端 SSE 断连 | 横幅 + 自动恢复已持久化消息，无重复消息 |
| 前端 JS 异常 | 错误横幅，非白屏 |
| overflow 错误（可压缩） | 自动压缩 + 重试一次，会话继续，`agent_overflow_retry` 日志落 |
| overflow 错误（压缩不足/摘要二次溢出） | api_error + 明确文案（compaction insufficient / auto-compaction failed），Web 端 error 帧透传，`agent_overflow_retry_fail`/`agent_compact_failed` 日志落 |
| provider overflow 零退避 | callWithRetry 立即上抛（mock 单测），`provider_overflow_skip_retry` dbg 日志 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/tool/glob.zig` | 提取 `matchEntry` 统一入口（walkDir + fixture 共用）+ fixture 驱动测试（9 条单测 + 2 集成） | 否 |
| `src/types.zig` | ToolResult 新增 `args_owned` 字段（带 `= null` 默认值）+ deinit 释放 + **`finishExec` 单点转移方法** + **不可浅拷贝契约注释** | 否（实测：默认值生效，80 个构造点零改动；转移逻辑收敛于 finishExec 单点） |
| `src/tool/registry.zig` | execute 委托 `finishExec`（errdefer） | 否 |
| `src/tool/{bash,read,write,grep,skill,edit,webfetch}.zig` | testExec 委托 `finishExec`（8 处同构） | 否 |
| `src/io/provider.zig` | 新增 `error.ContextOverflow` + 识别函数 + 重试循环跳过 overflow + `provider_overflow_skip_retry` 日志 | 否（switch 全枚举已逐处排查，见 N18"switch 枚举风险排查"表） |
| `src/core/agent.zig` | runTurn catch ContextOverflow → compact 重试 + 显式 catch 压缩错误（不冒泡）+ `agent_overflow_retry*`/`agent_compact_failed` 日志 | 否 |
| `src/frontends/web/app.js` | 全局错误边界 + SSE onerror 恢复 + `?limit=50` 复用 `SESSIONS_PAGE`（2 处） | 否 |
| `src/frontends/web/sse.zig` | 无改动（心跳 C 方案未采纳，留待后续） | — |
| `src/frontends/web/handler.zig` | api_error finish 补 error 帧透传 error_msg + 魔法值提取（`SESSION_PAGE_LIMIT`/`UNDO_CAP`） | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| 零拷贝借用约定 | ToolMeta 字符串字段不复制、直接指向 source（session_content 或 tool args），由 source 生命周期保证有效性（types.zig:66） |
| args_owned | ToolResult 持有 args JSON 解析树的所有权，保障 meta 借用在其 deinit 前有效 |
| context overflow | API 返回上下文超限错误（context_length_exceeded），请求体 token 超出模型窗口 |
| EventSource 自动重连 | 浏览器 SSE 规范行为：连接断开后按 retry 间隔自动重发同一 URL；本项目必须主动 close 禁用 |
