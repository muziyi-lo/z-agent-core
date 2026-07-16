# Plan FIX-1: --参数 完善

## 状态: 已完成 (2026-07-16)

## 来源

对比 opencode CLI 实现发现的缺口。

## 缺口清单

| 特性 | opencode | z-agent-core |
|------|----------|-------------|
| `--model` | ✅ 生效 | ❌ 横幅时序 bug |
| `--help` / `-h` | ✅ yargs 内置 | ❌ |
| `--version` / `-v` | ✅ | ❌ |
| `--list-models` | ✅ 子命令 `models` | ❌ |
| 单次模式退出码 | ✅ 错误 → 1 | ❌ 始终 0 |
| 单次模式输出分离 | ✅ AI 文本→stdout，其余→stderr | ❌ 全混入 stdout+ANSI |

## P0: 阻断级

### 1. --model 横幅时序

**根因**：横幅在 `Config.load()` 内部打印，但 `model_override` 在 `App.init()` 中才应用。

**修复**：
- `config.zig`：删除 `Config.load()` 中两处横幅输出；`formatModelDisplay`/`formatProviderDisplay` → `pub`
- `frontends/cli/App.zig`：在 `model_override` 应用之后打印横幅

### 2. 单次模式退出码

**`frontends/cli/App.zig`** — `singleTurn()` 返回 `process.exitCode`：
- API 错误 / 中断 → 设置 `process.setExitCode(io, 1)`
- 正常 → 0（默认）

```zig
if (result.finish == .api_error or result.finish == .interrupted) {
    process.setExitCode(io, 1) catch {};
}
```

## P1: 重要

### 3. --help / -h / --version / -v

**`frontends/cli/main.zig`** — 新增参数解析：

```
--help, -h        显示帮助
--version, -v     显示版本号
```

实现：解析到标志 → 输出文本 → 立即 `return`。

### 4. --list-models

**`frontends/cli/main.zig`** — 新增参数，加载 Config → 遍历 `providers[*].models[*]` → 输出 `provider/id  name` → `return`。无需启动 agent 或连接 API。

```
$ z-agent-core --list-models
deepseek/deepseek-v4-pro    DeepSeek V4 Pro
deepseek/deepseek-v4-flash  DeepSeek V4 Flash
aliyun/qwen3.7-max          Qwen3.7-MAX
```

### 5. 单次模式 stdout/stderr 分离

**目标**：`--prompt` 单次模式支持管道/重定向，AI 文本 → stdout，其余 → stderr。使 `z-agent-core --prompt "fix bug" > result.txt` 可用。

**检测**：`try std.Io.File.isTty(.stdout(), io)` 判断 stdout 是否为终端。

#### 行为矩阵

| 场景 | 行为 |
|------|------|
| stdout 是终端 | 保持当前行为（所有输出到 stdout + ANSI 渲染） |
| stdout 是管道/重定向 | 分离输出 |

#### 管道模式输出路由

| 输出内容 | 目标 |
|----------|------|
| 横幅 `z-agent-core v{s} \| ...` | stderr |
| `用户` 标签 + 用户输入 | stderr |
| `思考` 标签 | stderr |
| 思考文本（raw） | stderr |
| `输出` 标签 | stderr |
| 工具标签/进度/结果 | stderr |
| **AI 响应文本**（无 ANSI） | **stdout** |
| `用量` 行 | stderr |
| 错误/警告 | stderr |

#### 实现方案

**`frontends/cli/App.zig`** — `singleTurn()` 修改：

1. 入参增加 `pipe_mode: bool`
2. `pipe_mode = true` 时：
   - PhaseWriter 输出目标改为 stderr（`pw` 的 inner writer 指向 stderr）
   - 用户输入回显到 stderr
   - AI 文本不通过 PhaseWriter 流式输出到 stdout，改为累积到 `resp.content` 后一次性写 stdout（无 ANSI）
   - 工具标签/结果继续走 PhaseWriter → stderr
3. `pipe_mode = false`（终端模式）：无变化

**`frontends/cli/main.zig`** — 调用方：

```zig
const pipe_mode = !(try std.Io.File.isTty(.stdout(), io));
var app = App.init(allocator, io, single_prompt, model_override, pipe_mode) catch return;
```

**注意**：此方案在管道模式下牺牲了流式 typewriter 效果（文本先累积再输出），换取纯净的 stdout。理由：管道消费方（AI agent / 脚本）不关心流式体验，且累积输出避免 stdout 被 ANSI 污染。

#### 波及

| 文件 | 改动 |
|------|------|
| `src/frontends/cli/App.zig` | 新增 `pipe_mode: bool` 字段；`singleTurn()` 根据 `pipe_mode` 分离输出路由 |
| `src/frontends/cli/main.zig` | 检测 TTY，传入 `App.init(..., pipe_mode)` |

## 实施顺序

```
P0-1 (--model 横幅) → P0-2 (退出码) → P1-3 (--help/-v) → P1-4 (--list-models) → P1-5 (输出分离)
```

## 波及

| 文件 | 改动 |
|------|------|
| `src/config.zig` | 删除横幅输出；`formatModelDisplay`/`formatProviderDisplay` → pub |
| `src/frontends/cli/App.zig` | 新增横幅打印；退出码设置；单次输出分离 |
| `src/frontends/cli/main.zig` | 新增 --help/-h/--version/-v/--list-models |

## 验证

```powershell
zig build
zig build test
```
