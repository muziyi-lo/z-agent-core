# Plan OPT-3.1: 技术债清还

## 状态: 部分完成

## 已修复 (2026-07-15)

| # | 项 | 文件 | 改动 |
|---|----|------|------|
| F1 | bash 标签不显示命令 | `types.zig` + `bash.zig` + `render.zig` | meta.bash 新增 `command` 字段；label 改为 `$ {s} (exit {d})` |

## 来源

OPT-3 实施对照检查发现的 13 项偏差 + 实际使用中暴露的 1 个 bug。

## 🐛 Bug 修复

| # | 项 | 根因 | 文件 | 改动 |
|---|----|------|------|------|
| B1 | edit diff 含无效 UTF-8 截断 | `buildDiff()` 字节截断 `trimmed[0..240]` 可能切在多字节字符中间 | `tool/edit.zig` | 截断后用 `std.unicode.utf8ValidateSlice` 回退到最后一个完整码点边界 |

## 分档

### ⚡ Tier 1: 快赢（单文件 ≤5 行改）

| # | 项 | 文件 | 改动 |
|---|----|------|------|
| T1-1 | grep path 可选 | `tool/grep.zig` | params JSON 移 path 出 required；execute 中 path 缺失时默认 project_root |
| T1-2 | bash 上限 512KB | `tool/bash.zig` | `MAX_OUTPUT: usize = 50 * 1024` → `512 * 1024` |
| T1-3 | bash stdout/stderr 标签 | `tool/bash.zig` | result_buf 拼接时 err_len > 0 → 加 `[stderr]\n` 前缀 |
| T1-4 | render user_output 过滤 | `frontends/cli/render.zig` | 打印 user_output 前过滤 `\x00-\x08`/`\x0B`/`\x0C`/`\x0E-\x1F` |
| T1-5 | tool 执行进度提示 | `core/agent.zig` + `frontends/cli/render.zig` | ToolDisplayCb 新增 `begin_tool` 回调（工具执行前触发）；render 实现等待状态 ` 工具 {name} ..` |
| T1-6 | 路径标签截断改为左截断 | `frontends/cli/render.zig` | 当前字节截断 `s[0..50]` 在中间切断路径并可能切碎 UTF-8；改为 `"...{尾部}"` 左截断 + UTF-8 码点回退 |

### 🔧 Tier 2: 中等（单文件 10-30 行）

| # | 项 | 文件 | 改动 |
|---|----|------|------|
| T2-1 | grep include brace | `tool/grep.zig` | `globMatch()` 支持 `*.{ext1,ext2}` brace 展开 |
| T2-2 | bash workdir 参数 | `tool/bash.zig` | params 新增可选 workdir；execute 中 openDir 切换 workdir |
| T2-3 | skill XML 输出 | `tool/skill.zig` | 输出改为 `<skill_content name="...">` XML + `<skill_files>` |
| T2-4 | skill 附带文件枚举 | `tool/skill.zig` | 列出 skill 目录下 ≤10 非 SKILL.md 文件 |
| T2-5 | PhaseWriter 工具前结束 content | `frontends/cli/App.zig` | tool 回调前 `pw.endPhase()` 关闭流式阶段 |
| T2-6 | 轮次 token 用量展示 | `frontends/cli/App.zig` + `frontends/cli/render.zig` | MessageType 加 `usage`；回合后读取 assistant message `.usage` + 遍历求累计 + context_window 上限；`writeLabeled(.usage)` 输出 ` 用量  输入 N | 输出 M | 累计 X/Y` |

### 📅 Tier 3: 延后（基础设施就绪，数据/逻辑待写）

| # | 项 | 前置工作 | 计划 |
|---|----|---------|------|
| T3-1 | grep regex | Zig 版本升级提供 regex | 等待 Zig 0.17+ |
| T3-2 | bash timed_out | `std.process.Child` + poll 替代 `run` | 独立 PR |
| T3-3 | write old_lines | 覆盖前读旧文件内容 + `countLines` | 独立 PR |
| T3-4 | ToolCard 表解耦 | `toolMetaLabel()` switch 已等效 | 可选，不阻塞 |
| T3-5 | toTools Schema 缓存 | `_cached_tools` field | 可选，开销可忽略 |
| T3-6 | config.zig ToolLimits | 与 OPT-4 共享字段 | 延至 OPT-4 |
| T3-7 | ToolEntry.validate 注册 | 各工具拆分 validate 逻辑 | 独立 PR |

## 实施顺序

```
B1 → T1-1 → T1-2 → T1-3 → T1-4 → T1-5  (Bug 优先)
    ↓
T2-1 → T2-2 → T2-3 → T2-4 → T2-5 → T2-6  (独立，可并行)
    ↓
T3 延后（不阻塞 OPT-4）
```

## 验证

```powershell
zig build
zig build test
```

Tier 1+2 完成后测试数从 152 不减少，新增 skill 测试覆盖 XML 输出。
