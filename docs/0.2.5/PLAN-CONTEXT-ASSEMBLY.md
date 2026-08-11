# Plan CONTEXT-ASSEMBLY: system prompt 上下文拼装修复与补齐（对齐 opencode V2）

## 状态: 已完成（实施 + 验证通过）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 不做

- **不引入增量上下文更新机制（opencode D1）**：chronogical system 消息 + baseline 持久化是 TS/Effect + SQLite 生态的产物，Zig 项目 JSONL 会话无此基础设施；全量重建 system prompt 在单会话短历史下开销可接受。登记为未来项。
- **不引入系统 prompt 缓存 breakpoint（opencode D5）**：依赖 provider 缓存 hint 协议（anthropic-messages/bedrock），本项目走 OpenAI 隐式前缀缓存，无显式 API。登记为未来项。
- **不引入 reference 索引（opencode D9）**：本项目无 reference 概念，引入是过度设计。
- **不做 skill 权限过滤（opencode D8）**：本项目无 agent 权限体系。
- **不重写 skill 加载协议**：两步机制（索引 + tool call 加载 body）是设计决策（LRN-20260719-009），保留。只修索引生成器的 bug。
- **不动 CLI 层 `App.zig:740 buildPromptString`**：生产零调用（仅测试引用），独立清理项，本方案不动。

## 问题

### 症状

1. **AI 不知道自己用什么模型**：system prompt 的 `<env>` 块只有 root/platform/shell/arch，无 Model。
2. **AI 看不到可用 skill**：system prompt 的 `<available_skills>` 块从不输出——尽管 `.zagent/skills/` 下存在 skill。
3. **AI 不知道当前日期 / 是否 git 项目**：env 块缺这两项（opencode V2 均有）。

### 根因

**根因 1（Bug A — skill 索引生成器坏）**：核心层 `appendSkillsList`（agent.zig:437）遍历 `.zagent/skills/<name>/` 目录后，`openFile(skill_path)` 打开的是**目录本身**而非 `SKILL.md`。`readPositionalAll` 对目录报 `IsDir` → agent.zig:455 `catch { free; continue; }` 静默跳过 → **每个 skill 都失败，`<available_skills>` 块整体不输出**。`.zagent/skills` 目录本身正确（skill tool 同目录），无错位。

**根因 3（env 缺 Model）**：核心层 `buildPromptString`（agent.zig:386）env 块固定 4 项，`provider_ref.config.model` 已持有实际模型 id 但未注入。Web 端 `applySessionModel`（handler.zig:541）在 runTurn 前写入 provider config——时序保证模型已是实际值。

**根因 4（env 缺 date/git）**：opencode V2 builtins.ts 有 `Today's date` 和 git repo 状态，本项目从未加入。

**对照正确实现** `skill.zig:listAvailableSkills`（App.zig 用）：读 `{dir}/SKILL.md`，解析 frontmatter `description:`——核心层应同构。

**参考**：opencode `packages/core/src/skill/guidance.ts`（索引：name+description 按名排序）、`packages/core/src/system-context/builtins.ts`（env 块含 working dir/root/git/platform + date）。本方案对齐其关键字段，不移植其缓存/增量机制。

## 概览

- **改动范围**：5 个源文件 + 1 新增 + 测试 + 计划登记。
  - `src/config.zig` — Config 新增 `skills_dir` 字段（默认 `.zagent/skills`）+ 解析 + 模板。
  - `src/core/agent.zig` — `appendSkillsList` 修复（读 SKILL.md）+ 改配置驱动 + `buildPromptString` env 块补 Model/date/git。
  - `src/types.zig` — `ToolContext` 新增 `skills_dir` 字段。
  - `src/tool/skill.zig` — 改读 `ctx.skills_dir`（替换硬编码 `.zagent/skills`）。
  - `src/tool/bash.zig` — `tool_description` 改写（bash 禁令 + 专用工具映射表）。
  - `src/util/frontmatter.zig` — 新增 frontmatter 解析（统一两处实现）。
  - `src/frontends/cli/App.zig` — initAgent 传 `state.config.skills_dir`。
- **核心思路**：
  1. `appendSkillsList` 改为读 `{dir}/SKILL.md`（对齐 `skill.zig` 正确实现），修复 Bug A。
  2. skill 目录**配置化**（`Config.skills_dir`），索引与 `skill()` tool 共用配置值（见设计要点 2）。
  3. env 块补 `Model`/`Date`/`Git repo` 三行（数据源 `provider_ref.config.model` + 系统时间 + git 探测）。
- **参考实现**：opencode skill/guidance.ts + builtins.ts；对齐字段不移植架构。

## 设计要点

### 1. `appendSkillsList` 修复：读 SKILL.md 而非目录（Bug A）

```zig
fn appendSkillsList(self: *const AgentLoop, buf: *std.ArrayListAligned(u8, null)) !void {
    // 目录遍历不变, 但:
    const skill_md = std.fs.path.join(self.allocator, &.{ skills_dir, entry.name, "SKILL.md" }) catch continue;
    defer self.allocator.free(skill_md);
    const sk = Io.Dir.cwd().openFile(self.io, skill_md, .{ .mode = .read_only }) catch continue;
    // ... 读取 + extractSkillDescription 不变
}
```

**空态输出（评论者建议，本期采纳）**：当 `skills_dir` 存在但无有效技能（或目录为空）时，输出一行 `No skills are currently available.` 而非完全不输出。对齐 opencode `guidance.ts:20-22`：

```zig
// 排序拼接前判断:
if (list.items.len == 0) {
    try buf.appendSlice(self.allocator, "\n\nNo skills are currently available.\n");
} else {
    try buf.appendSlice(self.allocator, "\n\n<available_skills>\n");
    for (list.items) |s| { /* "  {name}: {desc}\n" */ }
    try buf.appendSlice(self.allocator, "</available_skills>");
}
```

**意义**：让模型**区分「确实没有技能」与「技能未注入」**——空态显式告知，避免模型误以为技能列表缺失是故障。这与计数行（Total: N）相比更有信息量：计数只冗余列表长度，空态消除了语义歧义。

对齐 `skill.zig:listAvailableSkills`（skill.zig:103 `{dir}/SKILL.md`）。读取失败路径静默跳过（现状语义保留，`<available_skills>` 只在有技能时输出）。

**frontmatter 解析统一（评论者建议，本期采纳）**：`extractSkillDescription`（agent.zig:479，全文搜 `description:` 前缀）与 `parseFrontmatterField`（skill.zig:128，严格 frontmatter）两处实现语义不同，统一到新增 `util/frontmatter.zig`：

```zig
/// util/frontmatter.zig — Parse a field from YAML frontmatter.
/// Returns borrowed slice into content; null if no frontmatter or field missing/empty.
pub fn parseField(content: []const u8, comptime field: []const u8) ?[]const u8 {
    if (content.len < 3 or !std.mem.eql(u8, content[0..3], "---")) return null;
    const normalized = content[3..];
    const end = std.mem.indexOfPosLinear(u8, normalized, 0, "---") orelse return null;
    const fm = normalized[0..end];

    const prefix = field ++ ":";
    const pos = std.mem.indexOfPosLinear(u8, fm, 0, prefix) orelse return null;
    const value_start = pos + prefix.len;
    const line_end = std.mem.indexOfScalarPos(u8, fm, value_start, '\n') orelse fm.len;
    var val = fm[value_start..line_end];
    val = std.mem.trim(u8, val, " \t\r");
    if (val.len == 0) return null;
    return val;
}
```

**统一依据**：
1. **严格 frontmatter 为准**（对齐 `parseFrontmatterField` 语义）——避免正文误匹配 `description:`。`extractSkillDescription` 的宽松全文搜可能把正文中碰巧出现的 `description:` 当 frontmatter。
2. **消除每次分配**：`field ++ ":"` 用 comptime 拼接（`field` 为 `comptime` 参数）替代 `parseFrontmatterField` 的 `allocPrint`——零分配，对齐 `extractSkillDescription` 的无分配优点。
3. **字段参数化**：不止 description 可用，未来 skill 其他 frontmatter 字段（version 等）复用。

**兼容性**（已用 `.tmp` 桩验证，4 用例通过）：中文值、无 frontmatter 返回 null、空值返回 null、缺字段返回 null。

**调用方替换**（两函数删除）：
- agent.zig:461 `extractSkillDescription(skill_text)` → `frontmatter.parseField(skill_text, "description")`，删 `extractSkillDescription`（agent.zig:479-488）。
- skill.zig:116 `parseFrontmatterField(content, "description")` → 同，删 `parseFrontmatterField`（skill.zig:128-144）。

**依赖方向**：util 层（最底层），core（agent.zig）与 tool（skill.zig）都可 import，不违反单向依赖。

### 1.5 按名排序（对齐 opencode skill/guidance.ts）

`appendSkillsList` 现为**流式拼接**（边遍历 `dir.iterate()` 边 append），顺序依赖文件系统目录迭代序——Windows NTFS 非字典序，`<available_skills>` 顺序不确定。opencode V2 `skill/guidance.ts:16-32` 按名排序。

**改法**：先收集 `[]SkillInfo{name, desc}`，`std.mem.sort` 按 name 排序后拼接：

```zig
// appendSkillsList 改为两段:
// 1. 收集（对齐 skill.zig:listAvailableSkills 的遍历+frontmatter 解析）
var list = std.ArrayListAligned(skill_tool.SkillInfo, null).empty;
while (iter.next(self.io) catch null) |entry| {
    // ... 读 {dir}/SKILL.md, frontmatter.parseField → append(name, desc)
}
// 2. 排序 + 拼接
std.mem.sort(skill_tool.SkillInfo, list.items, {}, struct {
    fn lt(_: void, a: skill_tool.SkillInfo, b: skill_tool.SkillInfo) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
}.lt);
for (list.items) |s| {
    // "  {name}: {desc}\n"
}
```

**import 声明**：agent.zig 需新增 `const skill_tool = @import("../tool/skill.zig")`——core → tool 依赖已存在（agent.zig:5 已 import `registry_mod`），复用 `skill.zig:87` 的 `SkillInfo` 类型不违反单向依赖。

**意义**：
1. `<available_skills>` 顺序**可预期**（字典序），模型每次看到一致列表，稳定决策。
2. **测试可断言**（固定顺序）。
3. 与 opencode `guidance.ts` 对齐。

**类型复用**：`skill.zig` 已有 `SkillInfo`（skill.zig:87 `{name, description}`）——排序复用它（`skill_tool.SkillInfo`），不新增类型、不移到 types.zig（agent.zig 需新增 import `skill_tool`）。`appendSkillsList` 与 `listAvailableSkills` 的收集逻辑趋同，但本方案**不抽公共函数**（两处上下文不同：核心层 vs tool 层，避免跨层耦合），仅对齐行为。

### 2. skill 目录配置化（`Config.skills_dir`），不硬编码兼容任何工具

**原则**：z-agent 不硬编码兼容 opencode / 其他工具的 skill 目录。正确的做法是**配置项**——用户在 `config.toml` 指定 skill 根目录，索引与 `skill()` tool 共用同一配置值，天然一致。默认 `.zagent/skills`（现状，向后兼容）。

```toml
# config.toml
skills_dir = ".zagent/skills"    # 可选；默认 .zagent/skills。可指向任意目录（如 .opencode/skills）
```

| 方案 | 说明 |
|------|------|
| A. 硬编码 `.zagent/skills`（现状） | 无法用其他工具的技能目录；每个工具都要特判 |
| B. 硬编码兼容 `.opencode/skills` | 开了坏头——兼容 opencode 后，其他流行工具（claude code `.claude/skills` 等）是否也要？无限膨胀 |
| C. **配置项 `skills_dir`** | 用户自行指定；索引与 tool 共用配置值，天然一致；默认值保持向后兼容 |

**选择**：方案 C。理由：
1. **配置优于特判**：不承诺兼容任何特定工具，用户需要时在 config 指一下即可（`skills_dir = ".opencode/skills"`），零代码。
2. **单一数据源**：索引（appendSkillsList）与 `skill()` tool（skill.zig:26）都读 `Config.skills_dir`，从根上消灭索引/加载不一致。
3. **向后兼容**：默认 `.zagent/skills`，现有测试目录（memory-manager/skill-forge）行为不变。

**改动点**（skill 目录的 3 处硬编码全部改配置驱动）：
- `Config` 新增 `skills_dir: []const u8 = ".zagent/skills"`（**struct 默认值**，与 `base_prompt: ?[]const u8 = null` 同模式——既有 4 处 `Config{}` 构造点（config.zig:872 测试、handler.zig:861/883/920 测试）省略该字段不报错，零破坏）。解析：`parseConfigContent` 用 `getString(parsed, "skills_dir") orelse ".zagent/skills"`（对齐 default_model 模式，config.zig:245）。
- `AgentLoop.init` 的 `opts` 结构新增 `skills_dir: []const u8 = ".zagent/skills"`（带默认值，与 tool_hooks/lifecycle 同模式）——2 处调用点（App.zig:173、server.zig:213）不强制改签名，但都传 `state.config.skills_dir` 以使用配置值；`appendSkillsList` 改用 `self.skills_dir`（替换 agent.zig:438 硬拼）。
- `ToolContext` 新增 `skills_dir: []const u8 = ".zagent/skills"`（**struct 默认值**——ToolContext 有 30 个构造点（各 tool 测试 + agent.zig:300），无默认值则全报错；默认值与 Config 同源）。agent.zig:300 注入 `self.skills_dir`；`skill.zig:26/93` 改读 `ctx.skills_dir`。
- `App.zig:initAgent` 传 `state.config.skills_dir`。
- `skill()` tool description（skill.zig:6）更新为「从配置的 skills 目录加载」（不再写死 `.zagent/skills`）。

**原「Bug B 目录错位」澄清**：不是目录错位——`.zagent/skills` 本就是正确默认目录。真实问题是 Bug A（打开目录而非 SKILL.md）。配置化顺带让「用其他工具的技能目录」成为用户可选项，而非本项目承诺。

**多目录支持（评论者建议，本期不做）**：评论者提出 `skills_dir = [".zagent/skills", ".opencode/skills"]` 数组、索引与 tool 按顺序查找同名 skill（前者优先）。经评估**本期不做**：①当前 project_root（Test）下 `.opencode/skills` 不存在，无真实落点；②数组化改动面翻倍（config 类型 `[][]const u8` + appendSkillsList/skill.zig/ToolContext 全改去重+顺序查找），拖延 P0 bug 修复。登记为未来项 F5。若未来需要，数组 + 顺序查找 + 前者优先是正确形态（非逗号分隔字符串——避免转义）。

### 3. env 块补 Model / Date / Git repo

`buildPromptString` 的 env 块完整代码（含三行新增，G7.5 已验证链路）：

```zig
fn buildPromptString(self: *const AgentLoop) ![]const u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    const a = self.allocator;

    try buf.appendSlice(a, "You are z-agent-core, an interactive CLI agent that helps users with software engineering tasks.\n\n<env>\n  Workspace root: ");
    try buf.appendSlice(a, self.project_root);
    try buf.appendSlice(a, "\n  Platform: ");
    try buf.appendSlice(a, @tagName(builtin.os.tag));
    try buf.appendSlice(a, "\n  Shell: ");
    try buf.appendSlice(a, shellName());
    try buf.appendSlice(a, "\n  Arch: ");
    try buf.appendSlice(a, @tagName(builtin.cpu.arch));
    try buf.appendSlice(a, "\n  Model: ");
    try buf.appendSlice(a, self.provider_ref.config.model);   // 实际模型 id
    try buf.appendSlice(a, "\n  Date: ");
    {
        var date_buf: [16]u8 = undefined;
        try buf.appendSlice(a, try formatUtcDate(self.io, &date_buf));  // YYYY-MM-DD
    }
    try buf.appendSlice(a, "\n  Git repo: ");
    try buf.appendSlice(a, if (isGitRepo(self.io, self.project_root)) "yes" else "no");
    try buf.appendSlice(a, "\n</env>");
    // ... project_context / skills 不变
}
```

**Date 格式化辅助函数**（`std.time.epoch` 链，G7.5 已编译验证输出 `YYYY-MM-DD`）：

```zig
/// Format current UTC date as YYYY-MM-DD. Zig 0.16 无 std 日期格式化公开 API，
/// 用 epoch 链手工转换：Timestamp(ns) → EpochSeconds → EpochDay → YearAndDay → MonthAndDay。
fn formatUtcDate(io: std.Io, buf: []u8) ![]const u8 {
    const ts = Io.Clock.real.now(io);
    const secs: u64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000_000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @as(u8, @intFromEnum(month_day.month)) + 1,
        @as(u8, month_day.day_index) + 1,
    });
}

/// Detect git repo by checking project_root/.git dir existence.
fn isGitRepo(io: std.Io, project_root: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const git_dir = std.fs.path.join(a, &.{ project_root, ".git" }) catch return false;
    var dir = Io.Dir.cwd().openDir(io, git_dir, .{ .iterate = false }) catch return false;
    dir.close(io);
    return true;
}
```

- **Model**：`provider_ref.config.model`（Web/CLI 均已反映实际模型，见「问题-根因 3」）。
- **Date**：`Io.Clock.real.now(io).nanoseconds` 是 Unix 纳秒（Io.zig:906-910 real clock 语义 = POSIX epoch），`@divTrunc(ns, 1e9)` → epoch seconds → `std.time.epoch` 链。`Month` 枚举从 1 起（jan=1），`day_index` 从 0 起——两者都 `+1` 转人类可读。
- **Git repo**：探测 `project_root/.git` 目录存在性（`Io.Dir.cwd().openDir` 失败即非 git）。opencode 语义 `Is directory a git repo: yes/no`。

**空值防御**：`config.model` 恒非空（validateConfig 保证），但 `model.len > 0` 才拼行；date/git 探测失败时拼 `unknown`/`no`——保持 `<env>` 结构完整。

### 4. 展示粒度：Model 用 id 而非 provider/model

env 块用 model id（`deepseek-v4-flash`），完整 spec（`deepseek/deepseek-v4-flash`）由 `/api/model` 下拉与 `session.model` 承载。config 内 id 全局唯一（validateConfig 校验），id 足够辨识。

### 5. 工具描述：bash 禁令 + 专用工具映射表（对齐 opencode shell.txt）

**现状**：`bash.tool_description`（bash.zig:7）纯功能 3 行，无「不要用 shell 做文件操作」引导。AI 倾向用 `bash ls/cat/find` 遍历，而非 `read`/`glob`/`grep`——浪费回合、输出噪音（LLM 把整棵目录树塞进上下文）。

**opencode 参考**（`packages/opencode/src/tool/shell/shell.txt:9` + `prompt.ts:100-106`）：「优先 read」的引导放在 **bash 描述**（被禁止工具侧声明禁令并指向专用工具），而非 read 描述里宣传自己。映射表格式：

```text
IMPORTANT: This tool is for terminal operations like git, npm, docker, etc.
DO NOT use it for file operations (reading, writing, editing, searching, finding files)
  - use the specialized tools for this instead:
    File search: glob    (NOT find/ls)
    Content search: grep (NOT grep/rg in shell)
    Read files: read     (NOT cat/head/tail)
    Edit files: edit     (NOT sed/awk)
    Write files: write   (NOT echo >/cat <<EOF)
```

**Zig 落地**（bash.zig:7 描述改写）：

```zig
pub const tool_description =
    "Execute a shell command in the specified working directory. Returns stdout, stderr, and exit code. " ++
    "Use for CLI tools, scripts, and system commands. " ++
    "DO NOT use for file operations (reading, writing, editing, searching, finding files) " ++
    "- use the dedicated tools instead: glob for file search, grep for content search, " ++
    "read for reading files, edit for editing, write for writing. " ++
    "Use the workdir parameter instead of 'cd'.";
```

**设计原则**（对齐 opencode）：
1. **禁令在 bash 侧**——被替代工具声明，替代者（read/grep/glob/edit/write）描述保持中性。
2. **专用工具映射表**——清晰对应（`find/ls`→glob，`cat/head/tail`→read，`grep/rg`→grep）。
3. **`workdir` 替代 `cd`**——bash 已有 workdir 参数，引导 AI 使用（对齐 opencode `prompt.ts:20`）。
4. **语气分级**：`DO NOT use for file operations`（文件操作禁令）为最高级，`Use ... instead` 为正面引导。

**不动的工具**：read/grep/glob/write/edit 描述保持功能中性（opencode V2 core 趋势），不在本方案加偏好语言。

**注意**：工具描述经 `tools` 参数传给 LLM API（OpenAI-compatible `description` 字段），非 system prompt——本方案同时改进 tools 参数内容，与 env 块（system prompt）是两个改动面，但同属「AI 行为引导」，并入本计划。

## 实施

### 步骤 1: 配置化 skill 目录

**文件**: `src/config.zig` + `src/types.zig` + `src/core/agent.zig` + `src/tool/skill.zig` + `src/frontends/cli/App.zig`
**改动**:
- `Config` 新增 `skills_dir: []const u8`（解析 `skills_dir`，默认 `.zagent/skills`；模板补注释示例）。
- `ToolContext` 新增 `skills_dir: []const u8`。
- `AgentLoop.init` 新增 `skills_dir` 参数；`appendSkillsList`（agent.zig:438）改用 `self.skills_dir`。
- `skill.zig:26/93` 改用 `ctx.skills_dir`；`skill.zig:6` tool description 更新（不再写死 `.zagent/skills`）。
- `App.zig:initAgent` 传 `state.config.skills_dir`。
- Web 端 `server.zig:213` AgentLoop.init 传 `state.config.skills_dir`。

### 步骤 2: 新增 `util/frontmatter.zig` 并替换两处解析

**文件**: 新增 `src/util/frontmatter.zig` + `src/core/agent.zig` + `src/tool/skill.zig`
**改动**:
- 新增 `util/frontmatter.zig` 的 `parseField`（设计要点 1 统一段代码）。
- agent.zig 删 `extractSkillDescription`，改调 `frontmatter.parseField`。
- skill.zig 删 `parseFrontmatterField`，改调 `frontmatter.parseField`。
- util/frontmatter.zig 自带 4 条单测（中文/无 frontmatter/空值/缺字段）。

### 步骤 3: `agent.zig` — appendSkillsList 修复 + 排序 + 空态

**文件**: `src/core/agent.zig`
**改动**: `appendSkillsList`（437-477）改为读 `{dir}/SKILL.md`（设计要点 1），并改为「收集 → 按名排序 → 拼接」两段式（设计要点 1.5，`std.mem.sort` + `std.mem.lessThan`），空态输出 `No skills are currently available.`（设计要点 1 空态段）。

### 步骤 4: `agent.zig` — env 块补 Model/Date/Git

**文件**: `src/core/agent.zig`
**改动**: `buildPromptString`（386-410）env 块 Arch 后补 `Model`/`Date`/`Git repo` 三行 + 私有 `isGitRepo` 辅助 + 日期格式化（G7 验证 API，见设计要点 3 完整代码）。

### 步骤 5: `bash.zig` — 工具描述加文件操作禁令 + 映射表

**文件**: `src/tool/bash.zig`
**改动**: `tool_description`（bash.zig:7）改写为含 `DO NOT use for file operations` 禁令 + 专用工具映射表 + `workdir` 引导（设计要点 5 完整文案）。

### 步骤 6: 测试

**文件**: `src/core/agent.zig` + `src/config.zig` + `src/util/frontmatter.zig`
**改动**:
- 新增 `buildPromptString includes model/date/git`——构造 AgentLoop fixture（复用 runTurn 测试 886 行 Provider 构造），断言含 `Model: test-model`。
- 新增 `appendSkillsList reads SKILL.md`——临时目录建 `{root}/{skills_dir}/{name}/SKILL.md`，断言输出 `<available_skills>` 含技能名与 description。
- 新增 `config: skills_dir defaults to .zagent/skills`——Config 解析默认值断言。
- util/frontmatter.zig 自带 4 条单测（中文/无 frontmatter/空值/缺字段）。
- 回归既有 agent runTurn / config / skill / bash 系列（bash description 改动不影响既有 bash 测试逻辑）。

### 步骤 7: 文档登记

**文件**: `docs/REMAINING.md`
**改动**: 登记 `App.zig buildPromptString 死代码`、`增量上下文更新`、`系统 prompt 缓存` 未来项。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
zig test src/core/agent.zig --cache-dir .zig-cache
node tests/frontend/run-tests.mjs
node scripts/check-catch-silent.mjs . --audit
```

| 测试场景 | 预期结果 |
|----------|----------|
| 单测：`buildPromptString includes model/date/git` | 输出含 `Model: test-model`、`Date: \d{4}-\d{2}-\d{2}`（格式断言，非具体值）、`Git repo: no/yes` |
| 单测：`appendSkillsList reads SKILL.md` | 临时目录技能名 + description 出现在 `<available_skills>` |
| 单测：`appendSkillsList sorts by name` | 临时目录建 `z-skill`/`a-skill`（乱序创建），断言 `<available_skills>` 按字典序（a-skill 在前） |
| 单测：`appendSkillsList empty dir` | 空 skills_dir（或无有效 SKILL.md）输出 `No skills are currently available.` |
| 单测回归：agent runTurn 系列 | 不受影响，全绿 |
| `zig test src/test.zig` | 除既有 `tool.bash echo hello` 基线失败外全通过 |
| 手工（CLI）：`z-agent-core --prompt "你用什么模型?有哪些技能?"` | 答模型名与 config default_model 一致；列出测试目录 memory-manager/skill-forge |
| 手工（Web）：会话 A 用 v4-pro、会话 B 用 v4-flash，各问「你用什么模型」 | A 答 v4-pro、B 答 v4-flash（验证 applySessionModel 时序 + env 块跟随） |
| 手工：非 git 目录（无 .git） | `Git repo: no` |
| 手工：测试目录（.git 存在） | `Git repo: yes` |
| 手工：config.toml 设 `skills_dir = ".opencode/skills"` | system prompt 列出该目录下的技能；`skill()` tool 能加载同一目录的 SKILL.md（索引/加载一致） |
| 手工：`--list-models` / 会话中观察工具 schema | bash 工具 description 含 `DO NOT use for file operations` 与专用工具映射表（glob/grep/read/edit/write） |

> **G7.5 门禁已过**：方案涉及 `Io.Clock.real.now` / `std.time.epoch.EpochSeconds.getEpochDay().calculateYearDay().calculateMonthDay()` / `Io.Dir.cwd().openDir` / `std.mem.sort` + `std.mem.lessThan` / `parseField` 的 `field ++ ":"` comptime 拼接（≥5 个 API），已用 `.tmp` 桩 + `zig test` 验证——日期链路输出 `2026-09-11`（正确格式）、git 探测 `true`、frontmatter parseField 4 用例（中文/无 frontmatter/空值/缺字段）全过，桩已清理。排序 API `std.mem.sort`（mem.zig:612）与 `std.mem.lessThan`（mem.zig:704）已对照 stdlib 源码确认签名。

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/util/frontmatter.zig` | **新增**：`parseField` + 4 单测 | 否（新文件） |
| `src/config.zig` | Config +`skills_dir` 字段 + 解析 + 模板 + 1 测试 | 否（默认值向后兼容） |
| `src/types.zig` | ToolContext +`skills_dir` 字段 | 否（默认值向后兼容） |
| `src/core/agent.zig` | AgentLoop.opts +`skills_dir` 默认值 + appendSkillsList 修复/排序/空态 + env 块补 3 行 + 删 extractSkillDescription + 测试 | 否（opts 带默认值，调用点可选传） |
| `src/tool/skill.zig` | 改读 `ctx.skills_dir` + 删 parseFrontmatterField + description 文案 | 是——ToolContext 新增字段，编译期强制同步 |
| `src/tool/bash.zig` | `tool_description` 改写（禁令 + 映射表 + workdir） | 否（描述文本，无逻辑变更） |
| `src/frontends/cli/App.zig` | initAgent 传 skills_dir | 否 |
| `src/frontends/web/server.zig` | AgentLoop.init 传 skills_dir | 否 |
| `docs/REMAINING.md` | 登记未来项 | 否 |

**调用点追踪**：`AgentLoop.init` 调用点 2 处（App.zig:173、server.zig:213）——opts 带默认值不强制改，但都传 `state.config.skills_dir`；`appendSkillsList` 调用点 1 处（agent.zig:407）；`buildPromptString` 调用点 1 处（agent.zig:177）。`provider.config.model` 读点现有 2 处（agent.zig:307 工具 endpoint、provider.zig:499 buildJsonBody），新增 env 块后 3 处，语义一致。`skill()` tool（skill.zig:26/93）与索引同读 `Config.skills_dir`，索引/加载一致。ToolContext 构造点 30 处（各 tool 测试 + agent.zig:300），`skills_dir` 带默认值零破坏。

## 遗留（未来项登记）

| # | 项 | 说明 |
|---|----|------|
| F1 | `App.zig:740 buildPromptString` 死代码删除（含 2 条测试） | 生产零调用 |
| F3 | 增量上下文更新（opencode D1） | chronogical system 消息 + baseline 持久化，需 DB/会话格式扩展 |
| F4 | 系统 prompt 缓存 breakpoint（opencode D5） | 依赖 provider 缓存 hint 协议 |
| F5 | 多 skill 目录数组（`skills_dir = ["...", "..."]`） | 索引与 tool 按顺序查找同名 skill（前者优先）；本期单目录够用，需多套时启用 |

## 术语

| 术语 | 含义 |
|------|------|
| 索引 + 按需加载 | system prompt 只放 skill 名字+描述，完整 body 由 `skill()` tool 加载（LRN-20260719-009） |
| IsDir 错误 | Windows 下对目录句柄调用 readPositionalAll 报 `error.IsDir`——appendSkillsList 打开目录而非 SKILL.md 的根因 |
| chronogical system 消息 | opencode 上下文变化时追加的增量 system 消息，不重建 baseline（本方案不引入） |
| env 块 | `<env>...</env>` 片段，向模型描述运行环境（root/platform/shell/arch/model/date/git） |
| 模型自我认知 | 模型能准确说出自己当前运行的模型 id |
