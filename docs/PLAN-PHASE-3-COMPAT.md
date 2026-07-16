# Plan PHASE-3: 协议适配层

## 状态: 计划中

## 问题

**现象**：当前只支持 DeepSeek 一种模型协议。添加 Qwen 时出现 SSE 流式闪烁（每个 token 都在"思考"和"输出"之间跳变），添加 `deepseek-v4-pro` 时报 JSON 解析错误。

**根因**：缺少协议适配层（compat layer）。每个模型提供商在 API 格式上有细微差异——thinking 模式的 JSON 字段名不同、最大 token 的字段名不同、是否支持流式 usage 返回不同。当前用 `params_json` 盲拼来硬编码 DeepSeek 的格式，其他模型靠运气。

## 概览

- **参考**：对比 Pi 项目的 `detectCompat()` 系统，确认了 7 项缺口。对比 nullclaw（同语言 Zig）的 `CompatProvider` 编译期表 + vtable 架构，确认了表驱动优于 URL 启发式的设计方向。对比 Reasonix（专为 DeepSeek 设计的 Go 代理），发现了 cache-first 循环、reasoning_content 选择性回传等 DeepSeek 专属优化。
- **改动范围**：3 个文件（types.zig、config.zig、provider.zig），不触及 render 层、不改变前后端分离架构
- **方案思路**：在 `types.zig` 中定义一个协议适配结构体（compat），`provider.zig` 在构建 JSON 请求体时根据 compat 的字段值选择正确的格式，`config.zig` 允许用户在 TOML 中覆盖推断结果

## 设计要点

### 1. URL 启发式推断 vs 全手动配置

当用户添加一个新模型时，两种策略：

| 方案 | 优点 | 缺点 |
|------|------|------|
| 全部手动在 TOML 中配置 | 精确、可控 | 用户需要了解每种 provider 的协议差异 |
| URL 模式自动推断 + 手动可覆盖 | 零配置即可用、专家可调优 | 推断规则可能不覆盖所有 provider |

**选择**：URL 推断 + 覆盖。Pi 的实践证明 URL 域名模式（`api.deepseek.com`、`aliyun`、`api.openai.com`）足以覆盖绝大多数 provider。用户在 TOML 中可通过 `compat` 字段覆盖任意推断结果。

**与 nullclaw 的差异**：nullclaw 用编译期的 `compat_providers` 表（70+ provider），每个条目是预配置的 bool 标志。我们选择 URL 启发式而非预编表，因为我们的用户模型不同——z-agent-core 面向用户自配置少量模型（5-10 个），编译期表维护成本 > 收益。但标志化字段的设计（`thinking_param: bool` 而非 `params_json: string`）可直接借鉴。

### 2. thinking 格式的七种变体

不同 provider 的"思考模式"在 API 请求体中表示方式不同。DeepSeek 用 `"thinking":{"type":"enabled"}`，OpenAI 用 `"reasoning_effort":"high"`，Qwen 用 `"enable_thinking":true`。

用枚举 `ThinkingFormat` 统一表达这 7 种变体。`buildJsonBody` 根据枚举值生成对应的 JSON 片段，而不是拼接用户手写的 `params_json` 字符串——这同时解决了 `deepseek-v4-pro` 的 JSON 转义 Bug（之前 `params_json` 中的引号在拼接时丢失）。

### 3. thinking 强度等级

仅是"开/关"不够。DeepSeek V4 Pro 支持高/超高两档（通过 `thinking.level` 或 `reasoning_effort` 传递），用户应能选择"日常用 fast 模式省 token，复杂问题用 max 模式深推理"。

等级定义采用通用语义，由 compat 层映射到各 provider 的具体值：

| 通用等级 | 含义 | DeepSeek 映射 | OpenAI 映射 | 默认 |
|----------|------|--------------|-------------|------|
| `low` | 快速响应 | `reasoning_effort: low` | `reasoning_effort: low` | |
| `medium` | 平衡 | `thinking: {level: medium}` | `reasoning_effort: medium` | |
| `high` | 深度推理 | `thinking: {level: high}` | `reasoning_effort: high` | ✅ |
| `max` | 最大深度 | `thinking: {level: max}` | 不支持 | |

实现上只需要两个字段：支持的等级列表 + 当前选择的等级。当前等级通过 `--thinking` 参数设置初始值，对话中通过 `/thinking` REPL 命令随时切换。

**切换入口**：

| 入口 | 格式 | 示例 |
|------|------|------|
| 启动参数 | `--thinking <level>` | `z-agent-core --thinking max --prompt "..."` |
| REPL 命令 | `/thinking <level>` | 对话中输入 `/thinking max` 立即切换后续回合的强度 |

`/thinking` 命令行为：修改 Provider 的当前等级 → 输出确认行 → 下一回合起 `buildJsonBody` 使用新等级。用户无需退出或重连。

### 4. 流式相位独立块化

当前 PhaseWriter 是一个单状态机——同一时刻只能是"思考"或"输出"。Qwen 的 SSE delta 同时携带两个字段，导致每 chunk 切换一次状态（闪烁）。

Pi 的做法是将 thinking 和 text 作为两个独立块并行累积，各自跟踪是否已开始。修改后 `provider.zig` 用两个布尔标志代替单一的 `in_content_phase` 锁：

- `thinking_started`：思考块是否已开始显示
- `text_started`：文本块是否已开始显示

### 5. reasoning_content 选择性回传

Reasonix 做了一种精细控制：reasoning_content 仅在 tool-call 回合回传给 API，在普通 assistant 回合丢弃以节省 token 和保持缓存前缀稳定。这是一个跨层改动（SSE 解析→存储→序列化→上下文组装），已独立为 `PLAN-PHASE-4-CACHE.md`。

## 实施

实施分四步。前三步建立 compat 数据流（从 TOML → Config → Provider → JSON body），第四步解决流式相位的架构问题。thinking 强度的 CLI 参数和 REPL 命令在步骤 3 中一并处理。

### 步骤 1: 定义 compat 数据结构

**文件**: `src/types.zig`
**改动**: 新增五个类型——compat 结构体、thinking 格式枚举、thinking 强度枚举、thinking 强度映射表、max_tokens 字段名枚举

compat 结构体包含所有可适配的协议参数。每个字段有默认值（标准 OpenAI 行为），非标准 provider 通过 `detectCompat` 或 TOML 覆盖。

thinking 强度等级用枚举表达四个通用等级（低/中/高/最大），由 compat 层映射到各 provider 的具体参数值。默认等级为 `high`。

### 步骤 2: JSON 构建改为 compat 驱动

**文件**: `src/io/provider.zig`
**改动**: `buildJsonBody` 函数根据 compat 值选择 JSON 格式

不再使用 `params_json` 盲拼。thinking JSON 由代码生成（格式由 `thinking_format` 枚举控制，强度由 `thinking_level` 映射）、max_tokens 字段名由枚举选择、stream_options 按需加入。此步骤同时消化了之前的 `params_json` 拼接 Bug。

### 步骤 3: TOML + CLI + REPL 支持 compat 和 thinking 强度

**文件**: `src/config.zig`、`src/frontends/cli/main.zig`、`src/frontends/cli/App.zig`
**改动**: TOML 解析新增 `compat` 和 `thinking_level` 字段；DEFAULT_TEMPLATE 加入注释；`main.zig` 新增 `--thinking low|medium|high|max` 参数；`App.zig` 的 `processLine` 新增 `/thinking <level>` 命令

用户可在 TOML 中覆盖 compat 的任意字段。未设置时回退到 URL 推断的默认值。thinking 强度通过 `--thinking` 设置初始值，通过 `/thinking` 在对话中实时切换——修改 Provider 的当前等级后直接继续 REPL，无需重连。

### 步骤 4: 流式相位独立块化

**文件**: `src/io/provider.zig`
**改动**: 将单相位切换改为双独立块跟踪

用 `thinking_started` 和 `text_started` 两个独立布尔标志替代 `in_content_phase` 锁。数据捕获（`content_buf.appendSlice`）不受任何锁影响。

## 验证

```powershell
zig build
zig build test
```

| 测试场景 | 预期结果 |
|----------|----------|
| `--model deepseek/deepseek-v4-flash` | thinking 正常显示，不闪烁 |
| `--model deepseek/deepseek-v4-pro` | thinking 正常显示，无 JSON 解析错误 |
| `--model aliyun/qwen3.7-max` | 不闪烁，思考文本保留 |
| `--thinking max` 切换 | PRO 请求体包含 `thinking.level: max` |
| `/thinking low` REPL 切换 | 下一回合使用低强度 |
| 未知 provider（无 TOML compat） | 默认 OpenAI 标准行为，不报错 |

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/types.zig` | 新增 `ModelCompat`、`ThinkingFormat`、`MaxTokensField`、`detectCompat()` | 否 |
| `src/config.zig` | TOML 解析 compat 字段；DEFAULT_TEMPLATE 更新 | 否（新字段可选） |
| `src/io/provider.zig` | `buildJsonBody` 改为 compat 驱动；流式相位改为独立块 | 否 |
| `src/frontends/cli/App.zig` | 无结构性改动 | — |
| `src/frontends/cli/main.zig` | 新增 `--thinking` 参数解析 | 否 |
| `src/frontends/cli/App.zig` | 新增 `/thinking` REPL 命令 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| 协议适配层（compat layer） | 根据模型 URL 自动推断 API 参数格式的中间层 |
| thinking 格式 | 模型思考模式在 JSON 请求体中的字段名和值格式 |
| 流式相位（streaming phase） | 终端显示时的"思考"/"输出"标签状态 |
| 独立块（independent blocks） | Pi 的做法：thinking 和 text 作为两个并行累积的内容块，不互斥 |
| 盲拼（blind concatenation） | v0.1-0.2 的做法：把 TOML 中的 JSON 字符串直接拼接到请求体 |
| thinking 强度（thinking level） | 思考模式的深度等级（低/中/高/最大），由通用语义映射到各 provider 的具体参数 |
| cache-first 循环 | Reasonix 的核心设计：append-only 消息历史，保持 prompt 前缀字节不变以命中 DeepSeek 自动缓存 |
| reasoning_content 回传 | DeepSeek 要求 tool-call 消息必须携带 reasoning_content，但普通 assistant 消息可省略以节省 token |
| stall 检测 | nullclaw 独有功能：curl `--speed-limit 1 --speed-time 60`，60 秒无数据自动断开 |
| stream_options | OpenAI 标准参数：`{"include_usage": true}` 让 provider 在每个 chunk 返回 token 用量 |
