# Plan F14: 魔法值全量提取（全模块）

## 状态: 已完成（2026-08-15）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 问题

**现象**：全量扫描 `src/`（工具 + 核心 + 前端 + IO）发现 3 类跨模块同值耦合（D-04 判据）与 1 类逻辑重复（D-03）：

1. **64KB 文件大小守卫 4 处**：`agent.zig:561/586`、`App.zig:148`、`skill.zig:111` 都是 `size > 65536` 跳过超大文件——同值同语义跨模块。
2. **20K token 上下文预算 3 处**：`agent.zig:155/313`（`@max(20000, ...)` 裸值）+ `compact.zig:10`（`DEFAULT_KEEP_RECENT_TOKENS = 20000` 常量）——agent 用裸值，compact 已有常量，**已提取但消费方未引用**（漂移）。
3. **工具结果收集上限 50KB 2 处**：`grep.zig:12 MAX_OUTPUT`、`glob.zig:11 MAX_OUTPUT`（同名，收集中止线）。**排除 read**（其 `MAX_BYTES` 是输出截断线，语义不同）。
4. **token 估算逻辑重复**：`agent.zig:138-140/307-309`（`content.len/4 + reasoning.len/4`）与 `compact.zig:19 estimateTokens`（pub）同逻辑——compact 已有共享函数，agent 未引用。

**根因**：历史遗留——各模块独立实现大小/预算/截断常量与估算逻辑，未引用已提取的共享常量。LRN-20260813-001 明确此类跨文件值耦合是真实漂移 bug 源：改一处阈值忘改另一处 → 行为不一致（如 agent 改 64KB→128KB 而 skill 仍 64KB，读同一技能目录但行为分裂）。

## 概览

- **改动文件**：修改 `src/util/text.zig`（新增 isBinary + 工具输出上限）、`src/core/agent.zig`（引用 compact 常量/函数 + 64KB 守卫）、`src/core/compact.zig`（可能新增文件大小守卫常量）、`src/frontends/cli/App.zig`（64KB 守卫）、`src/tool/skill.zig`（64KB 守卫）、`src/tool/bash.zig`（isBinary）、`src/tool/read.zig`（isBinary + 50KB）、`src/tool/grep.zig`（50KB）、`src/tool/glob.zig`（50KB）
- **新增 vs 修改**：无新增文件；共享层 1 个函数 + 若干 pub const，多模块调用点替换
- **一句话方案**：3 类同值耦合收敛为共享常量（64KB 文件守卫 / 20K token 预算 / 50KB 工具收集上限），isBinary 与 token 估算收敛为共享函数；read 的 MAX_BYTES 语义独立保留
- **参考实现**：无外部参考；语义以现有实现为准

## 设计要点

### 64KB 文件大小守卫：统一常量

`agent`/`App`/`skill` 四处的 `size > 65536` 都是"读取文件内容前的体积守卫"。收敛为共享常量：

```zig
/// Max file size read into memory for parsing, in BYTES
/// (state/agent/skill files). Files larger than this are skipped.
pub const FILE_READ_LIMIT: u64 = 64 * 1024;
```

**单位注释规范**（评论者建议）：所有 limit 类常量 doc comment 必须注明单位（字节/token/秒/字符），避免未来维护者误读。本方案涉及常量均遵守——`FILE_READ_LIMIT`（字节）、`TOOL_COLLECT_LIMIT`（字节）、`BINARY_CHECK_SIZE`（字节）、`BINARY_CONTROL_RATIO`（百分比，无单位但注明语义）。既有常量（`DEFAULT_KEEP_RECENT_TOKENS` 已注 "token budget"、`TITLE_MAX_CHARS` 已注 "characters"）已符合，不回溯改动。

**归属**：`util/text.zig`（工具层，无业务依赖）或 `types.zig`（核心常量）。选 `types.zig`——文件读取守卫是全局数据边界，非文本工具专属；且 agent/App/skill 均已 import types。

| 位置 | 现状 | 实施后 |
|------|------|--------|
| agent.zig:561/586 | `s.size > 65536` | `s.size > types.FILE_READ_LIMIT` |
| App.zig:148 | `s.size > 65536` | `> types.FILE_READ_LIMIT` |
| skill.zig:111 | `size > 65536` | `> types.FILE_READ_LIMIT` |

### 20K token 预算：消费方引用已有常量

`compact.zig` 已有 `DEFAULT_KEEP_RECENT_TOKENS = 20000`（pub），agent 用裸 `20000`。agent 引用该常量：

```zig
const reserved: u32 = @max(compact_mod.DEFAULT_KEEP_RECENT_TOKENS, self.context_window / 10);
```

agent 需 import compact（检查依赖方向：agent → compact 是否已存在）。

### 工具输出上限：区分"收集中止"与"输出截断"

**评论者提示（采纳）**：read.zig 的 `MAX_BYTES` 语义需确认。核实后确认**语义不同**，不可并入同一常量：

| 位置 | 语义 | 行为 |
|------|------|------|
| grep.zig:220 / glob.zig:90 `MAX_OUTPUT` | **收集中止线** | `buf.items.len >= 50KB` 时中断扫描（增量累积上限） |
| read.zig:243 `MAX_BYTES` | **输出截断线** | `session_content.len > 50KB` 时裁掉尾部加截断说明（对已解析内容裁切） |

两者值相同（50KB）但行为语义不同：一个"停止收集"，一个"裁剪返回"。合并到 `TOOL_OUTPUT_LIMIT` 会让未来调整相互污染（改收集上限误伤输出裁剪）。**因此**：
- grep/glob 的 `MAX_OUTPUT` 收敛为 `util/text.TOOL_COLLECT_LIMIT`（同语义"收集中止"）
- read 的 `MAX_BYTES` **保留独立**（语义"输出截断"），仅确保其值通过命名体现语义（可保留原名或改 `OUTPUT_TRUNCATE_LIMIT`）

```zig
/// Max bytes a tool accumulates before stopping collection (collection cutoff).
/// Unit: BYTES. Matches the legacy 50*1024 limit in grep/glob.
pub const TOOL_COLLECT_LIMIT: usize = 50 * 1024;
```

| 位置 | 现状 | 实施后 |
|------|------|--------|
| grep.zig:12 | `const MAX_OUTPUT: usize = 50 * 1024;` | 删，引 `text_util.TOOL_COLLECT_LIMIT` |
| glob.zig:11 | `const MAX_OUTPUT: usize = 50 * 1024;` | 删，引 `text_util.TOOL_COLLECT_LIMIT` |
| read.zig:11 | `const MAX_BYTES: usize = 50 * 1024;` | **保留独立**（评论者：语义不同，不合并） |

**排除**（弱耦合）：`512KB` 三处（bash 输出/ edit 文件大小/ write 输入）值同语义异；webfetch 1MB、bash 256KB 单处。

### 常量归属：维持归属模块（constants.zig 评估后排除）

**评论者建议**：新建 `src/constants.zig` 统一收纳所有跨模块常量，强制全模块引用。

**评估后不采纳**，理由：
- **types.zig 已是事实上的全局层**：20 个模块（全部工具+核心+前端）均已 import types——新常量放 types 零新增依赖；新建 constants.zig 需给所有引用模块加 import，改动面大且无收益
- **项目惯例是"常量放归属模块"**：`DEFAULT_KEEP_RECENT_TOKENS`→compact、`TITLE_*`→title、`DEFAULT_TIMEOUT_SECS`→webfetch——跨模块共享的进 types，领域专属的留归属模块，符合内聚
- **constants.zig 会把无关常量杂烩**：title 的 `STOPWORDS`、webfetch 的 `tool_description` 等领域专属值全塞入会破坏内聚

**决策**：新常量按归属分布——`FILE_READ_LIMIT`→`types.zig`（全局数据边界，types 已被全模块 import）、`TOOL_COLLECT_LIMIT`/`BINARY_*`→`util/text.zig`（文本工具共享）、已有 `DEFAULT_KEEP_RECENT_TOKENS` 留在 compact（agent 引用它）。若未来跨模块常量超过 ~10 个再评估独立 constants.zig。

| 常量 | 归属 | 引用方 |
|------|------|--------|
| FILE_READ_LIMIT | types.zig | agent/App/skill |
| TOOL_COLLECT_LIMIT / BINARY_* | util/text.zig | grep/glob / bash/read |
| DEFAULT_KEEP_RECENT_TOKENS | compact.zig（已有） | agent |

### token 估算复用 compact.estimateTokens

agent `estimateContextTokens` 的 L138-140 与 `compact.estimateTokens` 同逻辑，agent 改为复用：

```zig
// agent.zig estimateContextTokens 内
for (msgs) |m| total += compact_mod.estimateTokens(m);
```

**注意**：agent 的 estimateContextTokens 还有 L130-134 的 usage 短路（若最后 assistant 有 usage 用真实值）——该逻辑保留，仅替换 L138-140 的估算为复用函数。

### isBinary 收敛共享函数

**模块定位**（评论者建议）：`util/text.zig` 定位为**文本/字节内容处理工具库**——`isBinary` 是首个内容检测函数。未来若需检测其他内容类型（如 UTF-8 合法性 `isValidUtf8`、文本语言探测、CRLF/LF 规范化），均在此模块扩展，保持文本处理逻辑内聚。本方案只新增 `isBinary`，不超前实现其他检测。

bash/read 的二进制嗅探 → `util/text.isBinary`。统一实现（窗口 4096 + 控制字符 >30%）：

```zig
/// Binary-sniff check window, in BYTES (first bytes only).
pub const BINARY_CHECK_SIZE: usize = 4096;
/// Control-char ratio threshold, in percent (control*100/len > 30 means binary).
pub const BINARY_CONTROL_RATIO: usize = 30;

pub fn isBinary(data: []const u8) bool {
    if (data.len == 0) return false;
    const check_len = @min(data.len, BINARY_CHECK_SIZE);
    var control: usize = 0;
    for (data[0..check_len]) |b| {
        if (b == 0) return true;
        if (b < 0x20 and b != '\n' and b != '\r' and b != '\t') control += 1;
    }
    return control * 100 / check_len > BINARY_CONTROL_RATIO;
}
```

**行为兼容性分析**（评论者提示）：

统一后**严格等价**（逐字节相同）——两实现核心逻辑一致（NUL 早退 + 控制字符判定 + `*100/len > 30`），唯一差异是窗口位置，而窗口在两个场景下行为相同：

| 输入场景 | bash 现状 | read 现状 | 统一后 |
|----------|-----------|-----------|--------|
| len=0 | false | false | false（early return） |
| len ≤ 4096 | 全量遍历 | 全量遍历 | 全量遍历（`@min` 幂等） |
| len > 4096 | 前 4096 窗口 | 不可能（read 调用方 L191 已 `@min`） | 前 4096 窗口 |
| 前 4096 含 NUL | true | true | true |

**边界等值证明**：
- read 调用方 L191 传入的 `head_buf` 长度 = `@min(file_size, BINARY_CHECK_SIZE)` ≤ 4096 → 函数内 `@min(head_buf.len, BINARY_CHECK_SIZE)` = `head_buf.len` → 全量遍历，与现状 read 一致。
- bash 的 `out_clean`/`err_clean` 可 >4096 → 函数内 `@min` 截前 4096，与现状 bash 一致。
- NUL 早退、`>30` 严格大于（非 ≥）、整数除法 `control*100/check_len` 全部保持——无 off-by-one。

**边界等价测试**（防回归）：isBinary 测试块覆盖 len=0 / len 恰 4096 / len 4097（窗口截断）/ NUL 早退 / 控制字符占比恰 30%（false，严格大于）/ 30%+1（true）——每例与旧实现逐字节对照断言。

### 魔法值扫描脚本（防回归）

**评论者建议**：新增脚本扫描常见数字字面量重复出现位置，防止 F14 成果回归。

**设计**：在 zig-dev 技能 `scripts/` 下新增 `check-magic.mjs`（与 check-arch/check-catch-silent 同类代码检查，由 zig-dev 技能统一管理）。功能：

- **扫描目标**：`src/**/*.zig` 中跨模块重复的业务语义数字字面量（如 `65536`、`20000`、`50 * 1024`、`4096`、`30`）
- **判定**：同一数值在 ≥2 个**不同文件**出现 → 报告（对齐 D-04"跨模块"判据）
- **配置白名单**：测试数据（`1000` 等 max_tokens 测试值）、栈缓冲（`[4096]u8` 无语义）、日期/时间戳——通过命令行 `--ignore <值>` 排除，避免噪音
- **输出**：`MAGIC <value>: <file>:<line>, <file>:<line>` 逐处列出；非零退出码当检测到未白名单的重复
- **与既有检查的关系**：D-04 仍是审查清单的**人工判据**（判断"是否同语义"）；脚本是**自动化前置过滤**（先报重复位置，人工再判断语义真伪）——不替代 D-04，只是提高发现效率

**边界**：脚本只报告"重复出现位置"供人工判断语义，**不做自动提取**（语义判定需人——如 512KB 三处值同但语义异，脚本只报告，人工排除）。这与 check-catch-silent（自动报 catch 位置）一致。

**归属**：zig-dev 技能 scripts（与 check-arch 同类）。**不进 build.zig 自动门禁**（与既有检查一致，都是手动/CI 手动触发），未来如需 CI 集成由用户决定。

| 文件 | 改动 |
|------|------|
| `.opencode/skills/zig-dev/scripts/check-magic.mjs` | 新增扫描脚本 |
| `.opencode/skills/zig-dev/references/code-review-checklist.md` | D-04 行补"可用 check-magic.mjs 自动化过滤" |

### render 显示截断 / 其他：维持现状

### render 显示截断 / 其他：维持现状（全量数字审查确认）

**全量扫描**（`\b\d{2,6}\b` 全部数字字面量）后，除本方案提取的 3 类耦合外，其余**全部判定维持现状**：

| 类别 | 示例 | 判定理由 |
|------|------|----------|
| 栈缓冲大小 | `[256]`/`[512]`/`[4096]`/`[8192]` 等大量 | 无语义，非业务决策 |
| 时间单位常数 | `3600`（秒/时）、`86400`（秒/天） | 恒常事实，非业务决策；提取引入无意义依赖 |
| 日历算法常数 | `146097`/`365`/`153`（epoch→日期） | 恒常事实，同文件内 |
| 测试/示例数据 | `100000`/`128000`（context_window）、`1000`（max_tokens 测试） | 非耦合 |
| 模型规格 | `128000`（deepseek/gpt-4o context_window） | 模型定义，非魔法值 |
| 显示截断 | render.zig `30/40/45/50/60/80` | 各语义不同 |
| 语义不同的同值 | `512KB`（bash 输出/edit 文件/write 输入）、`500`（provider 退避 ms vs grep 匹配数） | 值同语义异，提取制造假耦合 |

**结论**：全量审查确认本方案 3 类提取（64KB 守卫 / 20K token 预算 / 50KB 收集上限）+ isBinary/token 估算收敛是**全部**真实跨模块耦合，无遗漏。

## 实施偏差记录

1. **弱耦合清单漏列 grep 两处**：计划"排除（弱耦合）"节称"512KB 三处"与"webfetch 1MB 单处"——实际 `grep.zig:197`（目录搜索跳过 >512KB 文件）为 512KB 第 4 处、`grep.zig:113`（单文件 >1MB 拒绝）为 1MB 第 2 处。均值同语义异，维持现状（check-magic 报告后人工排除）。
2. **验证条款"`50 * 1024` 无跨文件重复"未达成（设计使然）**：read.zig `MAX_BYTES` 按设计保留独立（截断语义 ≠ 收集语义），故 `50*1024` 仍跨文件（read.zig:12 + text.zig:10 `TOOL_COLLECT_LIMIT`）。check-magic 报告后人工排除，防回归目标（65536/20000 零报告）达成。
3. **check-magic.mjs 超出计划的功能**：
   - 乘法表达式归一化 token（`50 * 1024`/`50*1024` → `50*1024`），否则 `50`/`1024` 各自是纯噪音无法区分
   - 内置忽略 ASCII 控制字符字节值 `0x00`-`0x1f`（恒常事实，无漂移风险，计划未提）
   - 剥离字符串字面量（URL/日期/事件名内数字不参与扫描）与整行注释
4. **实施细节**：agent.zig `estimateTokens` 替换后 L138-140/L307-309 两处均用 `compact_mod.estimateTokens`（计划强调勿漏，已双处落地）；`types.FILE_READ_LIMIT` 类型 u64（与 `File.size` 对齐），`s.size` 为 u64 比较无需 cast。

## 实施

### 步骤 1: 共享常量/函数定义

**文件**: `src/types.zig`、`src/util/text.zig`
**改动**:
- types.zig 新增 `pub const FILE_READ_LIMIT: u64 = 64 * 1024;`
- util/text.zig 新增 `TOOL_COLLECT_LIMIT`/`BINARY_CHECK_SIZE`/`BINARY_CONTROL_RATIO` + `isBinary`（含边界等价测试：len=0 / 恰 4096 / 4097 窗口截断 / NUL 早退 / 占比恰 30% false / 30%+1 true）

### 步骤 2: agent.zig 引用共享预算 + 守卫 + estimateTokens

**文件**: `src/core/agent.zig`
**改动**:
- L155/313 `@max(20000, ...)` → `@max(compact_mod.DEFAULT_KEEP_RECENT_TOKENS, ...)`
- L561/586 `s.size > 65536` → `> types.FILE_READ_LIMIT`
- **两处 token 估算都替换**（评论者强调，勿漏）：
  - L138-140（`estimateContextTokens` 内）→ `total += compact_mod.estimateTokens(m);`
  - L307-309（`maybeAutoCompact` 的 `total_used` 无 usage 估算分支）→ `total_used += compact_mod.estimateTokens(msg);`
- 确认 import compact（检查现有依赖）
**注意**: 步骤 4 验证时用 `zig test src/core/agent.zig` 单独确认两处估算替换后 `estimateContextTokens` 与 `maybeAutoCompact` 相关测试均通过（防止只改一处、另一处仍裸算）。

### 步骤 3: App.zig / skill.zig 引用 FILE_READ_LIMIT

**文件**: `src/frontends/cli/App.zig`、`src/tool/skill.zig`
**改动**: `65536` → `types.FILE_READ_LIMIT`（App:148、skill:111）

### 步骤 4: 工具收集中止上限 + isBinary

**文件**: `src/tool/grep.zig`、`src/tool/glob.zig`、`src/tool/bash.zig`、`src/tool/read.zig`
**改动**:
- grep/glob：删 `MAX_OUTPUT`，改引 `text_util.TOOL_COLLECT_LIMIT`
- bash：删 `isBinaryContent`，改调 `text_util.isBinary`
- read：删 `isBinary`（L264-274）与 `BINARY_CHECK_SIZE`（L13），改调 `text_util.isBinary`；**`MAX_BYTES` 语义独立保留不改**

### 步骤 5: 魔法值扫描脚本

**文件**: `.opencode/skills/zig-dev/scripts/check-magic.mjs`、`.opencode/skills/zig-dev/references/code-review-checklist.md`
**改动**:
- 新增 `check-magic.mjs`（Node，零依赖，对齐 check-arch 风格）：扫描 `src/**/*.zig` 跨文件重复数字字面量，`--ignore` 白名单排除测试/缓冲值，非零退出码当检测到未白名单重复
- code-review-checklist.md D-04 行补："可用 `check-magic.mjs` 自动化过滤重复位置，再人工判定语义"
**注意**: 脚本验证用本方案涉及常量做回归——实施后 `65536`/`20000`/`50 * 1024` 应不再跨文件重复（已收敛为常量），脚本跑出 0 新报告即防回归目标达成。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 测试场景 | 预期结果 |
|----------|----------|
| isBinary 单测 + TOOL_COLLECT_LIMIT/FILE_READ_LIMIT 断言 | 全过 |
| agent estimateContextTokens（既有测试回归） | 行为不变（L138-140 已替换） |
| agent maybeAutoCompact 无 usage 估算（既有测试回归） | 行为不变（L307-309 已替换） |
| 64KB 守卫（agent/App/skill 既有测试） | 行为不变 |
| grep/glob 收集中止 + read 二进制拒绝 + bash 二进制（既有测试） | 行为不变 |
| check-magic.mjs 回归 | 实施后 `65536`/`20000`/`50 * 1024` 无跨文件重复（已收敛为常量）；脚本 0 新报告 |
| 全量测试 | All 通过，无泄漏 |
| ReleaseSafe | 无 UB |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/types.zig` | 新增 FILE_READ_LIMIT | 否 |
| `src/util/text.zig` | 新增 isBinary + TOOL_COLLECT_LIMIT/BINARY_* | 否 |
| `src/core/agent.zig` | 引用 compact 常量/函数 + 守卫 | 否（行为一致） |
| `src/frontends/cli/App.zig` | 引用 FILE_READ_LIMIT | 否 |
| `src/tool/skill.zig` | 引用 FILE_READ_LIMIT | 否 |
| `src/tool/grep.zig`/`glob.zig` | 删 MAX_OUTPUT，引 TOOL_COLLECT_LIMIT | 否 |
| `src/tool/bash.zig`/`read.zig` | 删 isBinary，改调共享 | 否（read 的 MAX_BYTES 保留） |

**G10(d) 错误集映射**：isBinary/estimateTokens 返回 bool/u32（无错误）——不涉及跨模块 `!T`。

**G15 日志**：不适用——纯常量/函数收敛。

**G16 交互矩阵**：单特性（魔法值收敛），无多特性交叉。

## 术语

| 术语 | 含义 |
|------|------|
| FILE_READ_LIMIT | 读入内存解析的文件体积上限（64KB，state/agent/skill 文件） |
| DEFAULT_KEEP_RECENT_TOKENS | 压缩后保留的最近上下文 token 预算（20K，compact 定义） |
| TOOL_COLLECT_LIMIT | 工具收集结果的中止上限（50KB，grep/glob 达到即停） |
| 弱耦合 | 值相同但语义/用途不同，提取会制造假耦合（如 read 的 MAX_BYTES 输出截断 vs grep 的收集中止） |
