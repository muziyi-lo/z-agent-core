# Plan OPT-3.1: 技术债清还

## 状态: 部分完成

## 已修复 (2026-07-15)

| # | 项 | 文件 |
|---|----|------|
| F1 | bash 标签不显示命令 | `types.zig` + `bash.zig` + `render.zig` |
| B1 | edit diff UTF-8 截断 | `tool/edit.zig` |
| B2 | bash 二进制输出垃圾字节 | `tool/bash.zig` |
| T1-1 | grep path 可选 | `tool/grep.zig` |
| T1-2 | bash 上限 512KB | `tool/bash.zig` |
| T1-3 | bash stdout/stderr 标签 | `tool/bash.zig` |
| T1-4 | render user_output 过滤 | `frontends/cli/render.zig` |
| T1-6 | 路径左截断 | `frontends/cli/render.zig` |
| T2-6 | 轮次 token 用量展示 | `frontends/cli/App.zig` + `frontends/cli/render.zig` |
| F2 | API 错误显示实际原因替代通用标签 | `core/agent.zig` + `frontends/cli/App.zig` |

## 分析：工具卡死的根因

两次卡死（bash 读 .exe 二进制、edit 非 UTF-8 截断）的共性：

| 层 | 问题 | 对照 opencode |
|----|------|-------------|
| 触发 | LLM 在不知道答案时退化为"读原始文件找线索" | opencode 同样无法阻止 LLM 做这个决策 |
| 执行 | bash `std.process.run()` 阻塞，不可中断 | opencode 用 `Effect.raceAll` + `AbortSignal` 可随时杀子进程 |
| 保护 | B2 替换二进制输出为摘要（已修复） | opencode 同样未做二进制检测（有显式 TODO） |

**根因不是缺少二进制检测**——opencode 也没做。根因是**缺用户打断功能**。

| 差距 | 影响 | 对应项 |
|------|------|--------|
| Ctrl+C 在 bash 执行中无响应 | 用户看到卡死无法中止 | T3-2 (`std.process.Child` + poll) |
| 工具执行前无进度提示 | 用户不知道是在运行还是卡死 | T1-5 (`begin_tool` 回调) |
| 长输出直接丢弃无存档 | 截断后数据不可恢复 | 新增 T2-7（参考 opencode 输出到文件） |

## 重排优先级

T3-2（bash 可中断）和 T1-5（工具进度提示）从各自档位提升——它们是解决卡死体验的核心，不是锦上添花。

## 来源

## 🐛 Bug 修复

| # | 项 | 状态 |
|---|----|------|
| B1 | edit diff 含无效 UTF-8 截断 | ✅ |
| B2 | bash 输出二进制文件垃圾字节撑爆终端 | ✅ |
| B3 | 打断后下一轮 API error — session 残留不完整消息 | ⏳ |

B3 根因：`runTurn` 被 abort 时，流式输出已通过 `session_ref.append()` 追加了部分 assistant message（`thinking/content`），但 `App` 看到 `.interrupted` 后不 flush（当前行 242-244 `if (.interrupted) rollback`），却也不回滚 session 中已追加的内容。下一轮 API 请求发送截断的 assistant message → JSON 序列化失败 → API error。

修复方向：abort 时回滚 session 到 `pre_count`（`rollbackTurn` 已有，但当前跳过该路径）；或在 agent 层 abort 时确保 session 无半条消息。

## ⚡ Tier 1: 快赢 + 核心体验

| # | 项 | 状态 | 文件 |
|---|----|------|------|
| T1-1 | grep path 可选 | ✅ | `tool/grep.zig` |
| T1-2 | bash 上限 512KB | ✅ | `tool/bash.zig` |
| T1-3 | bash stdout/stderr 标签 | ✅ | `tool/bash.zig` |
| T1-4 | render user_output 过滤 | ✅ | `frontends/cli/render.zig` |
| T1-5 | tool 执行进度提示 | ⏳ **↑提升** | `core/agent.zig` + `frontends/cli/render.zig` |
| T1-6 | 路径标签左截断 | ✅ | `frontends/cli/render.zig` |

## 🔧 Tier 2: 增强

| # | 项 | 状态 | 文件 |
|---|----|------|------|
| T2-6 | 轮次 token 用量展示 | ✅ | `frontends/cli/App.zig` + `frontends/cli/render.zig` |
| F2 | API 错误显示实际原因替代通用标签 | ✅ | `core/agent.zig` + `frontends/cli/App.zig` |
| T2-7 | bash 长输出保存到文件 | ⏳ 新增 | `tool/bash.zig` - 超限时输出写 `<project>/.zagent/tool-output/` 并在 session_content 中附路径 |
| T2-1 | grep include brace | ⏳ | `tool/grep.zig` |
| T2-2 | bash workdir 参数 | ⏳ | `tool/bash.zig` |
| T2-3 | skill XML 输出 | ⏳ | `tool/skill.zig` |
| T2-4 | skill 附带文件枚举 | ⏳ | `tool/skill.zig` |
| T2-5 | PhaseWriter 工具前结束 content | ⏳ | `frontends/cli/App.zig` |

### 📅 Tier 3: 延后

| # | 项 | 前置工作 |
|---|----|---------|
| T3-1 | grep regex | Zig 版本升级提供 regex |
| T3-2 | bash 可中断（`std.process.Child` + poll） | **↑提升至 Tier 1 优先级** — 卡死根因 |
| T3-3 | write old_lines | 覆盖前读旧文件内容 |
| T3-4 | ToolCard 表解耦 | `toolMetaLabel()` switch 已等效 |
| T3-5 | toTools Schema 缓存 | 开销可忽略 |
| T3-6 | config.zig ToolLimits | 延至 OPT-4 |
| T3-7 | ToolEntry.validate 注册 | 独立 PR |

## 实施顺序

```
已完成: B1 B2 T1-1 T1-2 T1-3 T1-4 T1-6 T2-6
    ↓
优先: B3 (打断后 API error) → T3-2 (bash 可中断)  ← 可用性阻断
    ↓
可选: T2-7 (输出存档) → T2-3/4 (skill) → T2-5 (PhaseWriter) → T2-1/2
```

## 验证

```powershell
zig build
zig build test
```

当前 151/152 pass（1 预存 config 测试失败）。
