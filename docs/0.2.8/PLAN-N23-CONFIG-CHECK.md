# Plan N23-CONFIG-CHECK: 配置检查功能补全

## 状态: 已实施（2026-08-16，N23，383 tests）

实施偏差记录：无重大偏差——列号+caret 随 Diag 结构直接落地（原评估 A+ 增量）；`formatAvailableModels` 分隔符 `", "`；错误消息文本按实现为准（计划未定死文本）。

## 前置依赖: 无

（与 F25 共享 toml.zig 但独立演进；REMAINING.md 中 N23 为 P2 独立项）

## 问题

**现象**：配置错误的部分场景静默或难定位——`default_model` 指向不存在的模型（Web 启动正常、首个请求才在连接内静默失败并断开，server.zig:261；CLI 启动即报错但无可用模型建议）、标量字段类型错误（`default_model = 123` 静默回退默认）、TOML 语法错误无行列位置。
**根因**：`validateConfig` 只做结构校验（provider/models 基本字段），值级校验缺失；`getString`/`getInt` 出错静默回退默认值；`toml.zig` 的 `error.InvalidToml` 无位置信息。

## 概览

- 改动 6 个文件（config.zig / toml.zig / frontends/init.zig / cli App.zig / cli main.zig / web server.zig；`src/main.zig` shim 无需），新增 3 项检查 + 退出码配套
- 一句话思路：参考 opencode 的"配置错误可见"呈现，按成本排序补三档：default_model 有效性（error，校验点使用覆盖后值，无新增错误码）→ 标量类型错误（warning）→ TOML 语法行列（error 打印）。与 opencode 实际行为的对齐/超越/宽松差异见各节

## 设计要点

### 1. default_model 有效性校验（error 级）

校验点设在 **init.zig:85 的 resolveModel**（启动必经路径，CLI/web 共享），而非 validateConfig——因为覆盖值（`--model`）需在覆盖应用**之后**校验（review 补充 3）。覆盖应用前移至 init_mod.init opts（Config.load 后），init.zig:85 天然校验覆盖后值。

| 方案 | 优点 | 缺点 |
|------|------|------|
| A 启动即报错（init.zig:85 校验点 + 建议文本） | fail-fast + 覆盖值自然生效（无误报） | 无新增错误码（复用 ModelResolveFailed）；web 无覆盖参数（无覆盖场景） |
| A' 校验放 validateConfig（早前方案） | 更早暴露 | **误报**：静态值无效 + `--model` 有效时仍被前置校验杀死 |
| B 保持现状（init.zig:85 静默无建议） | 无改动 | 错误文本无可用模型建议；web 场景 server.zig:261 静默 catch 不报 |

**选择**：方案 A——校验点=init.zig:85（覆盖后值），错误文本含可用模型建议（formatAvailableModels helper，复用 respondModelUnavailable 的 available_models 思路）。说明：opencode 对 `model` 字段并无启动校验（core/v1/config.ts 为 `Schema.optional(Schema.String)`），模型不存在是运行时 `ProviderModelNotFoundError` + "Did you mean" 建议（provider.ts:1094）；本方案启动 fail-fast 是**超越 opencode 的改进而非对齐**，错误文本借鉴其建议提示思路。

### 2. 标量字段类型错误警告（warning 级）

`getString`/`getInt`/`getBool`（config.zig:566-583）是纯函数（无 io）。不改签名（调用面广），改为**在 parseConfigContent 对关键字段做类型预检**：

```zig
// 值存在但类型不符 → 警告（字段仍按 orelse 默认值走）
fn warnWrongType(io: Io, parsed: *const ConfigToml, key: []const u8, expected: []const u8) void {
    const v = parsed.get(key) orelse return;
    const ok = switch (expected) {
        "string" => v == .string,
        "integer" => v == .integer,
        "boolean" => v == .boolean,
        else => true,
    };
    if (!ok) { /* stderr: warning: config key "default_model" expected <expected>, got <actual> — using default */ }
}
```

覆盖顶层 8 个标量键：`default_model`/`max_tokens`/`max_tool_rounds`/`skills_dir`/`auto_title`/`approval_mode`/`approval_cache`/`base_prompt`。**数组类已有警告**（title_stop_words/approval_allow/input），不重复。

> 取舍说明：opencode 对类型错误是**错误级 fail-fast** 且 `errors: "all"` 一次列出全部问题（parse.ts:55）；本方案选警告+回退默认，是刻意的宽松取舍——本地单用户工具以"能用"为先，模板演进不破坏既有配置，且已有未知键警告同类先例。

### 3. TOML 语法错误位置信息（诊断 out-param + 上层统一渲染）

toml.zig `parse` 是纯解析器（返回 `error.InvalidToml` 无位置）。**review 补充 4 采纳**：改为**诊断 out-param**——`parse` 追加 `diags: *DiagList` 参数（`Diag = struct { line: u32, column: u32, message: []const u8 }`），错误返回点（行循环内 ~10 处 + parseString/parseValue 等 helper 补 line_no 参数）追加诊断后仍 `return error.InvalidToml`；**stderr 打印全部移除**（解析器保持纯净）；config.zig（parseConfigContent）统一渲染所有诊断（行号 + 行内容 + caret），单点输出。这同时兑现了 review 补充 2 的"一次性输出"——同一层内诊断一次渲染，无碎片。

```zig
// toml.zig
pub const Diag = struct { line: u32, column: u32, message: []const u8 };
pub fn parse(allocator: std.mem.Allocator, source: []const u8, diags: *std.ArrayListAligned(Diag, null)) !std.StringArrayHashMapUnmanaged(Value) {
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        // ... 错误返回点：try diags.append(allocator, .{ .line = line_no, .column = <col>, .message = "unclosed table header" }); return error.InvalidToml;
    }
}
```

opencode 对照：parse.ts 输出 `at line N, column M` + `Line N: <内容>` + `^` caret 指向错误列（parse.ts:12-24）——本方案渲染层可直接复刻同款格式。

| 方案 | 优点 | 缺点 |
|------|------|------|
| A parse 内 stderr 打印 | 最小改动 | 解析器不再纯净（副作用）；打印点分散；重复输出协调成本 |
| B 诊断 out-param + 上层渲染（**选择**） | 纯净；位置数据可复用（F25/列号/结构化为零成本）；单点输出 | 签名变更（单一调用方 config.zig + 测试同步适配，~+20 行） |
| A+ 列号+caret | 精确定位到列 | 原评估 +~10 行 offset 跟踪——现 Diag 结构已含 column 字段，增量仅 ~5 行 |

**选择**：方案 B——诊断 out-param，解析器保持纯净；渲染收敛到 parseConfigContent 单点。列号+caret 顺带解锁（Diag 已含 column 字段，实现时直接输出，不再暂缓——opencode 同款格式成本已摊薄）。

### 4. 不做（明确排除）

- **结构化错误消费**（opencode issues code/path/message 供 UI 呈现）：本地单用户工具，纯文本足够；未来 Web 配置页需要时再立项
- **未知键 fail-fast**（opencode 报错而非警告）：警告已足够（静默丢失已消除）；报错会破坏"宽松配置"兼容（模板演进）
- **F25 的嵌套表支持**：独立计划（需 toml.zig 重构）

### 5. 边界与依赖澄清（review 补充，2026-08-16）

评论审查提出的依赖风险，逐条核对代码后确认：

1. **resolveModel 无 I/O**（config.zig:241-254）：纯静态查表——遍历 `config.providers` 数组字符串匹配 provider/model_id，无网络、无密钥、无外部调用。启动校验不会因网络/密钥问题误报，方案 A 依赖安全。
2. **`--model` 覆盖机制**（cli/main.zig:44-46 → App.zig:116-119）：**review 补充 3 已重构**——覆盖应用点从 App.zig（init 之后）**前移至 init_mod.init opts**（Config.load 后、init.zig:85 resolveModel 前），校验点天然使用覆盖后值（即评论者建议的"仅在校验时使用覆盖后的值"）。效果：静态值无效 + `--model` 有效 → 正常启动（**误报消除**，此场景现状会误杀）；静态值无效 + 无覆盖 → init.zig:85 fail-fast 带建议。覆盖值无效兜底不变：App.zig:126 resolveModel → `ModelResolveFailed`。web 前端无 `--model`（server.zig:166 不传 model_override），校验=静态值，无覆盖误报场景。
3. **空字符串**：既有 validateConfig 已拦截 `len == 0 → InvalidConfig_NoDefaultModel`（config.zig:257）；default_model 校验不新增错误码（见第 5 条），空串路径不变；`--model ""` 覆盖后由 init.zig:85 resolveModel → `InvalidModelSpec` → `ModelResolveFailed` 拦截，合理。
4. **重复输出协调（review 补充 4 简化）**：TOML 层改为诊断 out-param 后，parse 内无 stderr——重复输出仅剩 validateConfig 既有模式（具体行 + 上层 init.zig:69 `ConfigLoadFailed` → formatInitError 泛化行 "cannot load config"，`InvalidConfig_BaseUrlEmpty` 等 6 码同款）。协调规则不变：具体行 + 一行泛化，细节不重复；TOML 诊断由 parseConfigContent 渲染一次（行号+列号+caret），无 parse 内打印。
5. **错误码消费（review 补充 3 简化）**：**不新增错误码**——default_model 校验复用既有 `ModelResolveFailed` 路径（init.zig:85），错误文本在 catch 块内打印（具体行含可用模型建议）+ formatInitError 泛化行（init.zig:154-157），与既有模式一致；main.zig 保持零改动，validateConfig 零改动。
6. **退出码核实（评论者命中）**：现有**所有**错误路径均打印后正常 `return`——退出码恒为 0（cli/main.zig:102-107 --list-models、131-134 App.init、server.zig:166-169 init 失败、157-163 非回环门禁）。"fail-fast"对脚本/CI 无信号，属既有缺陷。**N23 配套修复**（新增步骤 4）：配置类错误路径返回非零退出码，fail-fast 语义闭环。实现：catch 块内 `std.process.exit(1)`（避免 main 返回 error 时 runtime 追加第三条输出行，重复输出问题不恶化；0.16 API 以编译为准）。范围：cli/main.zig 两处 + server.zig:166-169 一处；门禁（server.zig:157，N16 范畴）与 --list-models 一并顺带一致化（同模式同成本，避免半套）。
7. **一次性全量输出评估（review 补充 2）**：opencode 全量输出（jsonc-parser 容错收集全部 parse errors + Schema `errors: "all"`）按层对照：

   | 层 | opencode | z-agent-core（N23） | 差距与处理 |
   |----|----------|---------------------|------------|
   | 语法 | 容错解析器收集全部 parse errors | toml.zig 首个语法错误即中止 | 收集全部需 error-tolerant 解析器重构（与 F25 同源），**排除**——语法错误集中在文件首部区域，修正重跑自然暴露下一层 |
   | 类型/未知键 | Schema 全量一次列出 | warnWrongType 8 键循环 + warnUnknownKeys（config.zig:23）循环，均为同层全量 | 已全量；仅格式碎片化 → 步骤 2 聚合为汇总块（"↳" 列表同思路） |
   | 值（default_model） | 运行时 `ProviderModelNotFoundError`（单点） | 启动 fail-fast（CLI=init.zig:85 用覆盖后值；web=新增 listen 前校验点） | 单检查点无"多个错误级"场景，无聚合对象；与 opencode"全列后退出"在单点场景等价 |

   **结论**：全量收集在类型/未知键层已成立（成本仅格式聚合，步骤 2 已并入）；语法层全量收集排除（解析器重构，成本不匹配单用户工具收益，明示范围外）；错误级为单检查点 fail-fast，无碎片问题。
8. **formatAvailableModels 动态分配（review 补充 5）**：建议文本 helper 弃用固定栈缓冲（1024B 长列表截断风险），改 `std.ArrayListAligned(u8, null).empty` 动态拼接 + 返回分配串，调用方 `defer allocator.free`（~5 行，见步骤 1 关键代码）。对外接口仅新增，无影响。

## 实施

### 步骤 1: default_model 有效性校验（校验点使用覆盖后值）

**文件**: `src/frontends/init.zig`、`src/frontends/cli/App.zig`、`src/frontends/web/server.zig`、`src/config.zig`（建议文本 helper）
**改动**（review 补充 3 重构，替代原 validateConfig 方案）:
1. `init_mod.init` opts 加 `model_override: ?[]const u8 = null`；Config.load（init.zig:69）后、resolveModel（init.zig:85）前应用（`allocator.dupe` 覆盖 `cfg.default_model`）——校验点天然使用覆盖后值
2. App.zig:116-119 删除（逻辑移入 init）；App.init 调 init_mod.init 传 `.model_override = model_override`（App.zig:107-109 处）
3. init.zig:85 失败路径增强：catch 块打印具体错误（含可用模型建议）再 `return error.ModelResolveFailed`（复用既有错误码，无新增）
4. **web 启动校验点**：server.zig:166 init 成功后、listen（server.zig:174）前补 `resolveModel(&state.config, state.config.default_model)` 校验——消除"启动正常、首请求静默断开"现状（server.zig:261 连接级 catch 保留为防御）；失败打印（同 init.zig:85 文案）+ 非零退出（步骤 4 机制）。web 无 `--model`，校验值=静态值，无覆盖场景

**关键代码**:

```zig
// init.zig:85 失败路径增强（校验点；cfg.default_model 已被覆盖值替换）
const model = config_mod.resolveModel(&cfg, cfg.default_model) catch |err| {
    var sbuf: [512]u8 = undefined;
    var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
    sw.interface.print("error: default_model \"{s}\" cannot be resolved ({s})\n", .{ cfg.default_model, @errorName(err) }) catch {};
    sw.interface.flush() catch {};
    // review 补充 5：formatAvailableModels 动态分配，无固定缓冲截断风险
    const models_text = config_mod.formatAvailableModels(allocator, &cfg) catch "?";
    defer allocator.free(models_text);
    sw.interface.print("       available models: {s}\n", .{models_text}) catch {};
    sw.interface.flush() catch {};
    return error.ModelResolveFailed;
};
```

> **formatAvailableModels 签名**（review 补充 5）：`formatAvailableModels(allocator, *const Config) ![]const u8`——`std.ArrayListAligned(u8, null).empty` 动态拼接 + 返回，调用方 `defer allocator.free`。不用栈缓冲（1024B 在模型列表长时截断）；对外接口仅新增，无影响。

**场景矩阵**（静态 X / 覆盖 Y）:

| 静态 X | 覆盖 Y | 结果 |
|--------|--------|------|
| 有效 | 无 | 启动，用 X |
| 无效 | 无 | init.zig:85 fail-fast + 建议列表 |
| 无效 | 有效 | 覆盖先应用 → 校验用 Y → **正常启动**（误报消除） |
| 有效/无效 | 无效 | App.zig:126 兜底 fail-fast（既有） |

**测试**: 无效 + 无覆盖 → 报错含建议；无效 + `--model` 有效 → 正常启动（cli 集成验证）；config.zig 既有 8 条 validate 测试零改动

### 步骤 2: 标量类型警告

**文件**: `src/config.zig`
**改动**: warnWrongType helper + parseConfigContent 对 8 个标量键调用
**格式**: 8 键类型警告**聚合输出为汇总块**（对齐 opencode issues 列表呈现）：首行 `z-agent-core: warning: N config key(s) have wrong type:` + 逐条缩进行（键名/期望/实际/回退值）。第一遍循环收集、第二遍打印（~5 行成本）；与既有 warnUnknownKeys（config.zig:23-40 循环全量逐条）同层共存，两者均为"同层全量收集"，不互斥
**测试**: `default_model = 123` → 警告输出 + 回退默认（行为不变）；类型正确无噪音

### 步骤 3: TOML 语法错误位置信息（诊断 out-param）

**文件**: `src/toml.zig`、`src/config.zig`
**改动**（review 补充 4 重构，替代原 parse 内打印方案）:
1. toml.zig：新增 `Diag` 结构 + `parse` 追加 `diags: *std.ArrayListAligned(Diag, null)` out-param；行循环加 `line_no` 跟踪；错误返回点改为"追加 Diag + return error.InvalidToml"（主循环 8 处 + parseString/parseValue 等 helper 6 处，共 14 处；helper 补 line_no 参数）；**stderr 打印零残留**
2. config.zig：parseConfigContent 建 DiagList 传入（`defer diags.deinit(a)`，G14 生命周期闭环）；parse 失败 → 渲染函数单点输出（`line N, column M` + `Line N: <内容>` + `^` caret，opencode 同款）→ `return error.InvalidToml`
**测试**: 非法 TOML（未闭合字符串/坏表头）→ 输出含行列 + caret；既有 toml 错误测试适配（错误码不变，签名同步）；"解析器无副作用"验证：parse 失败路径无 stderr 写入（测试断言可省，代码审查可见）

### 步骤 4: 配置错误非零退出码（评论者第 3 点配套）

**文件**: `src/frontends/cli/main.zig`、`src/frontends/web/server.zig`
**改动**: 配置/init 错误路径 catch 块 `return;` → `std.process.exit(1)`（cli/main.zig:102-107、131-134；server.zig:166-169；门禁 server.zig:157-163 与 --list-models 同模式顺带一致化）
**测试**: 人为制造配置错误 → 退出码 1（PowerShell 断言 `$LASTEXITCODE`）；正常启动退出码 0 不变

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache
```

| 测试场景 | 预期结果 |
|----------|----------|
| default_model 指向不存在模型（无覆盖） | 启动报错 `default_model "x/y" cannot be resolved` + available models 列表 + 退出码 1 |
| default_model 指向不存在模型 + `--model` 有效 | 正常启动（用覆盖值），退出码 0 |
| default_model 合法 | 正常启动，退出码 0 |
| `default_model = 123` | stderr 警告汇总块（计数+逐条）+ 回退默认 |
| 非法 TOML（未闭合字符串） | 报错含行列号 + 行内容 + caret + 退出码 1（单点渲染，无 parse 内打印） |
| 配置错误 + `--list-models` / `--web` | 报错 + 退出码 1（非 0）；`--web` 启动时即报（非首请求） |
| 既有配置（z-agent-core/.zagent） | 零警告零报错 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/init.zig` | init opts 加 model_override（覆盖前移）+ init.zig:85 失败路径建议文本 | 否（opts 默认 null，CLI/web 行为显式化） |
| `src/frontends/cli/App.zig` | 覆盖逻辑删除（移入 init）+ 传参 | 否（行为等价，覆盖场景语义修复） |
| `src/config.zig` | formatAvailableModels helper + warnWrongType + TOML 诊断渲染（单点输出） | 否（新增函数） |
| `src/toml.zig` | parse 加 Diag out-param（无 stderr，保持纯净）；错误返回点追加诊断 | 否（单一调用方 config.zig + 测试同步适配，错误码不变） |
| `src/frontends/cli/main.zig` | 错误路径退出码 0→1 | 是（语义修复：错误可被脚本识别） |
| `src/frontends/web/server.zig` | 启动校验点（listen 前）+ init 失败/门禁退出码 0→1 | 是（启动失败改为显式退出） |
| 测试 | +2 条新测试 + 退出码断言，既有适配 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| fail-fast | 配置错误在启动时暴露而非首次使用时报错 |
| 值级校验 | 结构校验（字段存在性）之外的语义校验（字段值有效性） |
