# Plan OPT-4: Agent 初始化与会话管理优化

## 状态: 计划中

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| OPT-3 (ToolMeta) | 未实施 | 本方案依赖稳定的 `ToolDisplayCb` 契约（含 `err_msg` + `meta`） |

依赖链：`OPT-3 → OPT-4 → 新前端 (TUI/Web)`

## 不做

| 项 | 理由 |
|----|------|
| 命令注册表 | ZIG-ENUM-DISPATCH 反模式 |
| 接口抽象层 | 三个前端共享 Zig 源码，直接调函数 |
| `[prompt_env]` TOML 配置 | `<env>` 只陈述运行时环境事实，不承载行为指令 |
| 建 `src/app/` 目录 | 当前共享文件不够多，过度设计 |
| 用户级配置 (`~/.zagent/user.toml`) | TUI/Web 阶段再做 |
| 修改 `session.zig` | API 已正确，分离在调用层完成 |
| 工具 `prompt_hint` 注入 | 工具通过 API schema 暴露，不需要系统提示注入 |
| 技能目录嵌套扫描 | 所有前端共享同一个 `.zagent/skills/` 路径 |

三项独立优化，均围绕 `buildSystemPrompt` 和 `App.zig` session 操作。

---

## 1. Session 操作业务-显示分离

### 问题

`App.zig` 中 session 操作函数（`forkSession`、`renameSession`、`loadSession`）将**业务逻辑和 CLI 显示逻辑混在同一函数内**。以 `forkSession` 为例：

```zig
fn forkSession(self: *App, stdout: *Writer, name: []const u8) !void {
    // 验证 ← 业务逻辑（TUI 需要）
    // 路径构造 ← 业务逻辑（TUI 需要）
    // 文件存在检查 ← 业务逻辑（TUI 需要）
    // writeTo + load ← 业务逻辑（TUI 需要）
    // writeLabeled(.success, ...) ← 显示逻辑（CLI 专属）
    // writeLabeled(.err, ...)     ← 显示逻辑（CLI 专属）
}
```

TUI/Web 无法复用，要么重现实现 fork 逻辑，要么接受 CLI 终端输出污染。

### 设计

分层：

```
命令解析 + 终端渲染（前端专属）
─────────────────────────────
    业务逻辑（多前端共享）
─────────────────────────────
    核心 API（core/session.zig）
```

| 层 | 位置 | 示例 |
|----|------|------|
| 前端 | `frontends/cli/` / `tui/` | `/fork` 命令解析、`writeLabeled`、快捷键绑定 |
| 共享业务 | `src/session_ops.zig` | `fork()` `new()` `loadById()` `rollbackTurn()` |
| 核心 | `core/session.zig` | `load()` `writeTo()` `flush()` `list()` |

`core/session.zig` 不做任何改动。共享层只做编排和校验，零终端输出。

### 提取清单

从 `App.zig` 提取以下纯函数到 `src/session_ops.zig`（与 `types.zig` 同级）：

| 函数 | 来源 | 职责 | 备注 |
|------|------|------|------|
| `fork(allocator, io, source, session_dir) !Session` | `forkSession` | 验证名 → 构造路径 → 碰撞检查 → `writeTo` → `load` | 纯操作 |
| `new(allocator, io, model) !Session` | `resetSession` 步骤 2 | `Session.init` 创建空 session | 仅创建；`buildSystemPrompt` + `initAgent` 留前端 |
| `loadById(allocator, io, session_dir, id) !Session` | `loadSession` | 构造路径 → `Session.load` | 纯操作 |
| `rollbackTurn(session, pre_count) void` | `rollbackTurn` | `session.popLast(pre_count)` | 放共享层避免 TUI 直接调 session |
| `sanitizeForkName(allocator, name) ![]const u8` | `sanitizeForkName` | 输入校验 | 已是自由函数，直接搬 |

### 不提取

| 函数 | 理由 |
|------|------|
| `buildSystemPrompt` | 属 agent 初始化（见下文 2/3），不与 session ops 捆绑 |
| `listSessions` | 纯渲染转发，CLI 专有 |
| `replLoop` `processLine` `singleTurn` `winReadLine` | 纯前端终端 I/O |

### 依赖关系

```
core/session.zig  ←──  src/session_ops.zig  ←──  frontends/cli/App.zig
                                           ←──  frontends/tui/AppTui.zig
                                           ←──  frontends/web/server.zig
```

`App.zig` 保留现有 `@import("../../core/session.zig")`（Agent 交互 API），新增一行 `@import("../../session_ops.zig")`。方向全单向。

### ID 规范化

| 概念 | 存储位置 | 可变 | 唯一性 | 来源 |
|------|----------|------|--------|------|
| **ID** | 文件名 stem | 否 | 需唯一 | 毫秒时间戳自动生成 |
| **name**（显示名） | JSONL header | 是（`/name`） | 可重复 | 默认 "New Session" |

当前 `rename()` 后 name 变成 ID（文件名 stem = sanitized name）。修复：`rename()` 只改 header name，不动 stem。ID 永远不可变。

### `/fork` 无参

| 命令 | ID | name |
|------|----|------|
| `/fork` | 自动生成时间戳 ID | 继承原 session header name |
| `/fork <arg>` | 自动生成时间戳 ID | `rename(arg)` 设置显示名 |

### 未来 `src/app/` 目录

当前仅一个共享文件，不需要目录。当共享业务逻辑增长到第三个文件时迁入：

```
src/
  app/
    session_ops.zig
    prompt.zig          ← buildSystemPrompt
    context.zig         ← AGENTS.md 加载
  core/
  frontends/
```

---

## 2. 系统提示模板化

### 问题

`buildSystemPrompt` 两端硬编码：`BASE_PROMPT` 是编译期常量无法覆盖，`<env>` 块固定不可扩展。用户无法定制 agent 的基调和行为指令。

### 设计

在 `.zagent/config.toml` 中添加 `base_prompt` 字段，设置后**完全替换**编译期默认值：

```toml
# .zagent/config.toml
# 不设置则使用编译期默认: "You are z-agent-core, an interactive CLI agent..."
base_prompt = """
You are z-agent-core, an interactive CLI agent that helps users
with software engineering tasks.
"""
```

| 字段 | 行为 | 默认值 |
|------|------|--------|
| `base_prompt` | 设置后**完全替换**编译期 `BASE_PROMPT` 常量 | 当前 `BASE_PROMPT` |

`<env>` 块保持自动生成，不开放配置入口 — 它只应包含运行时环境事实（cwd、platform、date），不应成为第二个 base_prompt。

### 提示结构对比

```
当前:
─────
{BASE_PROMPT}

<env>
  Working directory: C:\project
  Workspace root: C:\project
  Platform: windows
  Today's date: 2026-07-14
</env>

<project_context>
{AGENTS.md content}
</project_context>

实施后:
─────
{base_prompt 或 BASE_PROMPT}

<env>
  Working directory: C:\project
  Workspace root: C:\project
  Platform: windows
  Today's date: 2026-07-14
</env>

<available_skills>                          ← 技能列表注入
  zig-dev: Zig 开发统一技能
  ...
</available_skills>

<project_context>
{AGENTS.md content}
</project_context>
```

### 配置结构变更

```zig
// config.zig
pub const Config = struct {
    // ... 现有字段 ...
    base_prompt: ?[]const u8,
};
```

TOML 中 `base_prompt` 可选，不设置则用编译期默认值。

### 用户级配置

用户级（`~/.zagent/user.toml`）等 TUI/Web 阶段再加。届时合并策略：项目级 `base_prompt` 覆盖用户级。

---

## 3. 技能列表注入

### 问题

当前系统提示中**没有技能列表**。LLM 不知道有哪些技能可用，只能从上下文或技能名称猜测来调用 `skill("name")`。

技能与工具不同：工具通过 OpenAI tools API 暴露 `description`，LLM 自然知道何时调用。技能只能按名加载，LLM 无法主动发现有哪些可用技能。

### 设计

`buildSystemPrompt` 遍历 `.zagent/skills/*/SKILL.md`，提取每个技能的 `name` + `description`（来自 SKILL.md frontmatter），注入系统提示：

```
<available_skills>
  zig-dev: Zig 开发统一技能（开发模式 + 调试模式）
  opencode-cdp: 零依赖 CDP 浏览器操控
  ...
</available_skills>
```

实现：`skill.zig` 对外暴露 `listAvailableSkills(allocator, io, project_root) ![]SkillInfo`（返回 name + description）。`buildSystemPrompt` 调用并拼接。

### 与技能工具的协同

`tool/skill.zig` 已有 `execute()` 加载完整 SKILL.md 内容。新增的 `listAvailableSkills()` 只返回摘要（name + description），供系统提示用。同一个技能目录，两个消费者：

| 消费者 | 调用 | 用途 |
|--------|------|------|
| `buildSystemPrompt` | `skill.listAvailableSkills()` | 注入摘要到系统提示 |
| LLM → `skill("name")` | `skill.execute()` | 加载完整 SKILL.md 内容 |

---

## 文件变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/session_ops.zig` | **新增** | 纯业务逻辑，零终端输出 |
| `src/config.zig` | 修改 | Config 新增 `base_prompt: ?[]const u8`；TOML 解析。⚠️ 与 OPT-3 共享（OPT-3 新增 `ToolLimits`，不同字段无冲突） |
| `src/tool/skill.zig` | 修改 | 新增 `listAvailableSkills()`。⚠️ 与 OPT-3 共享（OPT-3 填充 `meta.skill`，不同函数无冲突） |
| `src/frontends/cli/App.zig` | 修改 | 替换 5 个内联函数为 `session_ops`；`buildSystemPrompt` 读 config + 注入技能列表 |
| `src/core/session.zig` | 不变 | API 已满足 |
| `src/test.zig` | 修改 | 添加 `session_ops` import |
| `.zagent/config.toml`（模板） | 修改 | 添加 `base_prompt` 注释示例 |

## 验证

```powershell
zig build
zig build test
node ..\..\.opencode\skills\zig-dev\scripts\check-arch.mjs .
```

## ID 碰撞

毫秒时间戳 ID 在同毫秒两处创建时可碰撞。`flush()` 当前不处理。碰撞概率极低（单机单进程），不改此行为。后续可在 `generateId()` 中加入 `while exists { counter += 1 }` 重试。
