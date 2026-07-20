# Plan PHASE-6: TUI 前端

## 状态: 计划中（架构设计阶段）

## 问题

当前 z-agent-core 仅有 CLI 前端（`src/frontends/cli/`），缺少可视化终端界面。用户在使用多文件编辑、长时间运行的任务时，看不到工具执行状态、会话历史和 LLM 思考过程的分离视图。

## 概览

- **参考**：opencode 的 TUI（基于 Ink/React 的终端 UI），vaxis（Zig 原生 TUI 框架）
- **改动范围**：新建 `src/frontends/tui/` 目录，通过前端的 `PhaseWriterCb`/`ToolDisplayCb`/`SystemPromptCb` 三个回调合约接入
- **核心约束**：core/ 永不知道前端存在。TUI 前端仅实现三个回调合约 + REPL 循环。与 CLI 前端可并存，通过 `--tui` 参数切换。

## 设计要点

### 1. 布局设计

```
┌─────────────────────────────────────────────────────────┐
│  z-agent-core v0.2.0 | DeepSeek-V4-Flash | Session: xxx  │  ← 状态栏
├─────────────────────────────────────────────────────────┤
│                                                         │
│  [对话历史区域]                                          │  ← 可滚动
│   User: 帮我写一个 Zig 的 HTTP 客户端                    │
│   ──────────────────────────────────────────             │
│   Assistant (thinking):                                  │
│   用户想要一个 HTTP 客户端，我需要...                      │
│   ──────────────────────────────────────────             │
│   Assistant:                                             │
│   我来帮你实现。首先创建文件结构...                        │
│   ──────────────────────────────────────────             │
│   Tool: write { path: "http.zig", ... }                 │
│   文件已创建，15 行                                      │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  [工具执行状态] (bash/write/read 等工具运行时显示)       │  ← 可选详情区
│  > bash: zig build                                      │
│  ✓ 编译成功                                              │
├─────────────────────────────────────────────────────────┤
│  > 你的下一个问题...                                     │  ← 输入行
└─────────────────────────────────────────────────────────┘
```

### 2. 与现有架构的集成

现有三个回调合约已足够 TUI 前端使用：

| 回调 | 当前 CLI 用法 | TUI 用法 |
|------|-------------|----------|
| `PhaseWriterCb` | ANSI 块渲染（thinking→dim，content→normal） | 将 thinking 写入独立面板 |
| `ToolDisplayCb` | 标签 + 摘要行 | 写入工具面板，显示进度 |
| `SystemPromptCb` | 重建 system message | 同样逻辑，UI 无感知 |

TUI 前端不需要修改任何 core/ 代码。只需实现这三个回调的 TUI 版本。

### 3. 框架选型

| 框架 | 语言 | 优点 | 缺点 |
|------|------|------|------|
| **vaxis** | Zig | 原生、零依赖、与项目语言一致 | 年轻项目，文档少 |
| ratatui | Rust | 成熟、功能丰富 | 需要 FFI 或 Rust 子进程 |
| bubbletea | Go | 简单、ELM 架构 | 需要 Go 子进程 |
| blessed | JS (Node) | 简单快速 | 需要 Node.js |

**推荐**: vaxis，因为项目要求单一二进制，Zig 原生 TUI 避免 FFI/子进程跨语言通信的复杂性。如果 vaxis 在 Zig 0.16 上不稳定，备选方案是用 Go + bubbletea 作为独立进程通过 JSONL 管道通信。

### 4. vaxis 集成要点 (Zig 0.16)

```zig
// build.zig.zon 添加依赖:
// .vaxis = .{
//     .url = "https://github.com/rockorager/vaxis/archive/refs/tags/v0.2.0.tar.gz",
//     .hash = "...",
// },

// src/frontends/tui/main.zig (示意):
const vaxis = @import("vaxis");
const App = @import("App.zig");

pub fn main(process: std.process.Init) !void {
    // vaxis 初始化
    var vx = try vaxis.init(process.allocator, .{});
    defer vx.deinit();

    // 创建 TUI App (复用现有 App.zig 的核心逻辑)
    var tui_app = try TuiApp.init(process.allocator, process.io, vx);

    // 事件循环
    try tui_app.run();
}
```

### 5. 管线模式兼容

`--prompt` 单次模式 + `--tui` 的组合：TUI 模式下也接受单次 prompt，完成后不退出——保持在 TUI 中显示结果，等待用户下一个输入。这比 CLI 的 prompt 模式更自然（结果展示更好）。

---

## 实施步骤

由于 vaxis API 在 Zig 0.16 下可能不稳定，分两个阶段：

### 阶段 A: 环境验证 (1-2 天)

1. 添加 vaxis 到 `build.zig.zon`
2. 创建最小 vaxis 示例程序验证能否在 Zig 0.16 上编译
3. 测试基本的输入/输出/滚动日志区域

### 阶段 B: 完整实现 (3-5 天)

1. **创建 `src/frontends/tui/` 目录结构**:
   ```
   src/frontends/tui/
       main.zig       ← 入口: vaxis 初始化 + 事件循环
       App.zig        ← TUI 业务逻辑 (复用 CLI App 的核心代码)
       layout.zig     ← 面板布局管理
       styles.zig     ← 颜色/主题
   ```

2. **实现三个回调**:
   - `PhaseWriterCb`: thinking 文本输出到独立面板，使用 dim/italic 样式
   - `ToolDisplayCb`: 工具执行状态输出到工具面板
   - `SystemPromptCb`: 同 CLI 实现（无 UI 变化）

3. **REPL 输入**: vaxis 的字节流输入 + 历史记录

4. **状态栏**: 显示模型名、会话名、token 用量、时间

5. **快捷键**:
   - `Ctrl+C`: 中断当前 LLM 请求
   - `Ctrl+L`: 清屏
   - `/new`, `/load`, `/fork`, `/list`, `/thinking`: 同 CLI 命令

### 阶段 C: 构建集成 (1 天)

1. `zig build` 同时生成 `z-agent-core` (CLI) 和 `z-agent-core-tui` (TUI)
2. 或通过 `zig build -Dtui` 生成带 TUI 的版本

---

## 验证

```powershell
# 环境验证
zig build -Dtui

# 功能测试
.\zig-out\bin\z-agent-core-tui
# 在 TUI 中输入 "hello world" 测试基本对话
# Ctrl+C 测试中断
```

---

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `build.zig` | 新增 TUI 构建目标 | 否（条件编译） |
| `build.zig.zon` | 新增 vaxis 依赖 | 否 |
| `src/frontends/tui/*` | 新建目录，~500-800 行 | 否 |
| `src/frontends/cli/*` | 无改动 | — |
| `src/core/*` | 无改动 | — |

## 备选方案: Web 前端

如果 TUI 开发遇到 vaxis 兼容性问题，备选是 Web 前端（`src/frontends/web/`）：

- 单 HTML 文件内嵌在二进制中
- 通过 SSE (Server-Sent Events) 推送 LLM 流式输出到浏览器
- 通过 WebSocket 或 HTTP POST 发送用户输入
- 使用 Zig 的 HTTP server 监听 localhost
- 优势：UI 框架成熟（纯 HTML/CSS/JS）、可跨平台访问
- 劣势：需要浏览器，失去纯终端体验

目前不展开 TUI 和 Web 前端的详细实现计划——当 PHASE-3 和 PHASE-4 完成后再根据 vaxis 0.16 的实际兼容性做最终决策。
