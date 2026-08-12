# Remaining Work

## 实施顺序

```
PHASE-5 (webfetch)  ← 当前（计划文档已完善，可随时实施）
    ↓
PHASE-6 (TUI) — 备选方案，待 Zig 生态成熟后再评估
```

## 计划文档状态

| 计划 | 文档 | 状态 |
|------|------|------|
| PHASE-3 | `docs/0.2.2/PLAN-PHASE-3-COMPAT.md` | ✅ 已完成 (v0.2.2) |
| PHASE-4 | `docs/0.2.2/PLAN-PHASE-4-CACHE.md` | ✅ 已完成 (v0.2.2) |
| PHASE-7 | `docs/0.2.3/PLAN-PHASE-7-WEB-FRONTEND.md` | ✅ 已完成 (v0.2.3) — SSE 流式端点 + Web CRUD |
| PHASE-5 | `docs/PLAN-PHASE-5-WEBFETCH.md` | 计划中 |
| PHASE-6 | `docs/PLAN-PHASE-6-TUI.md` | 架构设计 |
| FIX-2 | `docs/0.2.2/PLAN-FIX-2-DECOUPLE-BUILD.md` | ✅ 已完成 (v0.2.2) |
| FIX-DOCS | `docs/0.2.2/PLAN-FIX-DOCS-AND-INFRA.md` | ✅ 已完成 (v0.2.2) |
| FIX-SYSTEM-PROMPT | `docs/0.2.3/PLAN-FIX-SYSTEM-PROMPT-DEFAULT.md` | ✅ 已完成 (v0.2.3) |
| FIX-WEB-SESSION | `docs/0.2.3/PLAN-FIX-WEB-SESSION-ISSUES.md` | ✅ 已完成 (v0.2.3) |
| REF-1 | `docs/0.2.3/PLAN-REF-1-PHASEWRITER-PER-CALL.md` | ✅ 已完成 (v0.2.3) |
| REF-2 | `docs/0.2.3/PLAN-REF-2-INIT-MODULE.md` | ✅ 已完成 (v0.2.3) |
| WEB-CONCURRENT | `docs/0.2.4/PLAN-WEB-CONCURRENT.md` | ✅ 已完成 (v0.2.4) |
| WEB-OPT | `docs/0.2.4/PLAN-WEB-OPT.md` | ✅ 已完成 (v0.2.4) |
| WEB-UI-OPT | `docs/0.2.4/PLAN-WEB-UI-OPT.md` | ✅ 已完成 (v0.2.4) |
| WEB-FIX-STREAMING | `docs/0.2.4/PLAN-WEB-FIX-STREAMING.md` | ✅ 已完成 (v0.2.4) |
| WEB-FIX-SESSION-LIST | `docs/0.2.4/PLAN-WEB-FIX-SESSION-LIST.md` | ✅ 已完成 (v0.2.4) |
| LOGGING-MODULE | `docs/0.2.4/PLAN-LOGGING-MODULE.md` | ✅ 已完成 (v0.2.4) |
| WEB-REMAINING | `docs/0.2.4/PLAN-WEB-REMAINING.md` | ✅ 已完成 (v0.2.4) — G8 全工具视图 / G9 上下文分组 / G11 消息操作 |
| WEB-UI-FIXES | `docs/0.2.5/PLAN-WEB-UI-FIXES.md` | ✅ 已完成 (v0.2.5) — F1-F16 前端修复 |
| FIX-APIKEY-ENV | `docs/0.2.5/PLAN-FIX-APIKEY-ENV.md` | ✅ 已完成 — 空 key 误判 + .env 回退生效 |
| STREAM-ORDER-PARTS | `docs/0.2.5/PLAN-STREAM-ORDER-PARTS.md` | ✅ 已完成 — parts 模型重构（拆分+流式/reload 双轨统一，Node 测试 37 断言） |
| SLASH-COMMANDS | `docs/0.2.5/PLAN-SLASH-COMMANDS.md` | 实施中 — 阶段 1-4 完成（注册表/CLI dispatch/Web 命令 API/popover），阶段 5 prompt 命令待实施 |
| MODEL-RESOLVE | `docs/0.2.5/PLAN-MODEL-RESOLVE.md` | ✅ 已完成 — 模型解析单一化（createSession 工厂 + env 快照 + resolveSessionModel 决策点），LRN-20260811-001 遗留债收尾 |
| CONTEXT-ASSEMBLY | `docs/0.2.5/PLAN-CONTEXT-ASSEMBLY.md` | ✅ 已完成 — 上下文拼装修复（skill 索引 IsDir bug + skills_dir 配置化）+ env 补 Model/Date/Git + frontmatter 统一 + bash 禁令 |

## Done (2026-08-06 — v0.2.5)

| # | Item | Plan doc | Effort |
|---|------|----------|--------|
| D26 | Web 前端 16 项修复 (剪贴板/移动端/停止按钮/空会话落盘/无会话输入/索引/主题/a11y 等) | docs/0.2.5/PLAN-WEB-UI-FIXES.md | High |

## Done (2026-08-06 — v0.2.4)

| # | Item | Plan doc | Effort |
|---|------|----------|--------|
| D21 | Web 并发请求 (线程模型) + POST abort + SSE 断开检测 | docs/0.2.4/PLAN-WEB-CONCURRENT.md | High |
| D22 | Web 前端优化 14 项 (vendor JS 内联/拖拽 resize/消息删除/流式 Markdown/工具卡片等) | docs/0.2.4/PLAN-WEB-OPT.md + WEB-UI-OPT.md | High |
| D23 | 消息删除 + removeMessage + SSE 实时 flush + done 首条消息 + 系统消息声明式渲染 | docs/0.2.4/PLAN-WEB-FIX-STREAMING.md | Medium |
| D24 | 服务器日志模块 util/log.zig (结构化 5 级) | docs/0.2.4/PLAN-LOGGING-MODULE.md | Medium |
| D25 | 渲染数据增强 (G3 thinking/tool 数据恢复 + G8 工具视图 + G9 上下文分组 + G11 消息操作) | docs/0.2.4/PLAN-WEB-REMAINING.md | Medium |

## Done (2026-07-30 — v0.2.3)

| # | Item | Plan doc | Effort |
|---|------|----------|--------|
| D15 | Web 前端 MVP (HTTP Server + SSE + index.html + 9 tests) | docs/0.2.3/PLAN-PHASE-7-WEB-FRONTEND.md | Very High |
| D16 | Web 会话 CRUD 补齐 (PATCH/DELETE端点 + 核心层 deleteFile + 前端重命名/删除/时间分组/去重) | docs/0.2.3/PLAN-FIX-WEB-SESSION-ISSUES.md | High |
| D17 | 错误处理全量加固 (reportInitError统一出口 + 3处unreachable + 8处静默吞错 + 幽灵错误名 + 500修复) | docs/0.2.3/PLAN-FIX-SYSTEM-PROMPT-DEFAULT.md | High |
| D18 | 系统提示词归位核心层 (AgentLoop自动注入 + SystemPromptCb简化 + UUID v4 + 安全校验) | docs/0.2.3/PLAN-FIX-SYSTEM-PROMPT-DEFAULT.md | High |
| D19 | REF-1 PhaseWriterCb per-call 化 | docs/0.2.3/PLAN-REF-1-PHASEWRITER-PER-CALL.md | Medium |
| D20 | REF-2 抽取共享初始化模块 init.zig | docs/0.2.3/PLAN-REF-2-INIT-MODULE.md | Medium |

## Done (2026-07-16)

| # | Item | Plan doc | Effort |
|---|------|----------|--------|
| D12 | OPT-5 运行时稳定性 (P0-2 API重试 + P0-1 上下文压缩 + P1-3 死循环 + P1-4 工具上下文 + P1-5 每步重组) | docs/0.2.0/PLAN-OPT-5-STABILITY.md | High |
| D13 | FIX-1 --参数完善 (横幅/退出码/--help/--version/--list-models/管道模式) | docs/0.2.0/PLAN-FIX-1-MODEL-ARG.md | High |
| D14 | OPT-6 用量数据显示增强 (缓存命中/动态单位/上下文占比) | docs/0.2.0/PLAN-OPT-6-USAGE-DISPLAY.md | High |

## Done (2026-07-15)

| # | Item | Plan doc | Effort |
|---|------|----------|--------|
| D5 | Thinking content: skip Markdown, plain dim text | docs/0.2.0/PLAN-OPT-2-DISPLAY-GAPS.md | Low |
| D6 | ToolResult 结构化：ToolMeta union + 全工具填 meta + edit 新工具 | docs/0.2.0/PLAN-OPT-3-RENDER-TOOLS.md | High |
| D7 | OPT-3.1 bug 修复 (B1 UTF-8截断, B2 bash二进制, B3 abort后flush) | docs/0.2.0/PLAN-OPT-3.1-TECHDEBT.md | Medium |
| D8 | OPT-3.1 快赢 (grep可选, bash 512KB/stderr/二进制, user_output过滤, 路径左截断) | docs/0.2.0/PLAN-OPT-3.1-TECHDEBT.md | Medium |
| D9 | OPT-3.1 增强 (token用量展示, 工具进度提示, bash命令标签, API错误展示) | docs/0.2.0/PLAN-OPT-3.1-TECHDEBT.md | Medium |
| D10 | OPT-4 会话管理 (session_ops分层 + base_prompt模板 + skill列表注入) | docs/0.2.0/PLAN-OPT-4-AGENT-SESSION.md | High |
| D11 | OPT-3.2 标签渲染统一化 (writeLabel + labelColor表 + 对比度/空行) | docs/0.2.0/PLAN-OPT-3.2-LABEL-UNIFY.md | Low |

## Done (2026-07-14)

| # | Item | Plan doc | Effort |
|---|------|----------|--------|
| D1 | grep/glob label: show both pattern + path | docs/0.2.0/PLAN-OPT-2-DISPLAY-GAPS.md | Low |
| D2 | Round limit warning: user + LLM notification | docs/0.2.0/PLAN-OPT-2-DISPLAY-GAPS.md | Low |
| D3 | Bash output display: `user_output` field | docs/0.2.0/PLAN-OPT-2-DISPLAY-GAPS.md | Medium |
| D4 | Tool error display: red text + (err) suffix | docs/0.2.0/PLAN-OPT-2-DISPLAY-GAPS.md | Low |

## Done (2026-07-13 — Phase 2)

| # | Item | Plan doc | Effort |
|---|------|----------|--------|
| D0 | PHASE-2 全 9 步 (ToolHooks + abort + LifecycleCb + Ctrl+C + ApiEndpoint + compact + TokenUsage + /fork + tests) | docs/PLAN-PHASE2.md | Very High |

## Next (下版候选)

| # | Item | Notes |
|---|------|-------|
| N1 | Web 端 `PATCH /api/session/:id/fork` + `/reset` 端点 | 承自 v0.2.3 Known Gaps |
| N2 | CLI `/delete <id>` 命令 + sessions 路径常量化 + 删除运行中会话保护 | docs/PLAN-FUTURE-SESSION-IMPROVEMENTS.md P1 |
| N3 | 侧边栏 DOM diff / 会话列表分页 / Web CRUD 冒烟测试 | docs/PLAN-FUTURE-SESSION-IMPROVEMENTS.md P2 |
| N4 | `@container` 响应式侧边栏 | docs/DESIGN-WEB-RENDER.md 待实现 高 |
| N5 | 技能覆盖缺口 3 项 (SSE filter / @embedFile 预览适配 / Web 冒烟测试) | docs/PLAN-SKILL-COVERAGE.md GAP-1~3 |
| N6 | DOM 结构契约 + 前端回归验证脚本 (contentDiv 只装 LLM 文本、工具卡片平级挂 asst；chrome-cdp 断言 done 后 tool-card 存在) | 根因已修复 (v0.2.5 parts 重构，PLAN-STREAM-ORDER-PARTS)；剩余：DOM 回归脚本浏览器级落库（Node 测试 37 断言已在 .tmp 提供逻辑级覆盖） |
| N7 | CLI `App.zig buildPromptString` 死代码删除（含 2 条测试） | 生产零调用（CONTEXT-ASSEMBLY F1） |
| N8 | 增量上下文更新（chronogical system 消息 + baseline 持久化） | 对齐 opencode D1，需 DB/会话格式扩展（CONTEXT-ASSEMBLY F3） |
| N9 | 系统 prompt 缓存 breakpoint | 依赖 provider 缓存 hint 协议（CONTEXT-ASSEMBLY F4） |
| N10 | 多 skill 目录数组（`skills_dir = ["...", "..."]`） | 索引与 tool 按顺序查找同名 skill，前者优先（CONTEXT-ASSEMBLY F5） |
| N11 | 会话系统优化（消息 ID 模型 + 按 ID 操作 + 分页/compact/history） | **P1+P2 已实施（2026-08-12）**：消息 id 模型 + 迁移 + 按 id 的 delete/truncate/branch + `(fork #N)` 命名 + 操作栏 4 按钮 + 滚动状态机 + 三层流式防护 + branch 自动重答（方案 B）+ `parent_id` 分支树 + `/active` + `message_not_found`。P3 分页/P4 compact/P5 history 见 `docs/0.2.7/PLAN-SESSION-SYSTEM-OPT.md` |

## Deferred (explicitly skipped)

| # | Item | Reason |
|---|------|--------|
| R2 | DisplayHint (v2 tool metadata) | OPT-3 已覆盖 — ToolMeta 替代 |
| R3 | Tool event streaming (start/update/end) | Requires significant protocol change |
| R4 | Edit 模糊匹配 | 待 opencode 实现后跟进 |
| R5 | read 图片支持 (base64) | 模型视觉能力不一致 |
| R6 | read realpath 双重解析 | Windows 符号链接少，`..` 检测已覆盖 |
| R7 | write BOM 保留 | 边界场景 |
| R8 | write 竞争防护 (writeIfUnchanged) | 需文件 hash 基础设施，单进程无并发 |
| R9 | grep ripgrep 外部二进制 | `std.regex` 满足需求 |
| R10 | bash 外部目录警告 | 权限系统范式不同 |
| R12 | 证据回执系统（Evidence Ledger） | 工具间交叉验证，需独立设计 |
| R13 | 并行调度分区 | 后期性能优化 |

## Future (not started, not researched)

| # | Item | Notes |
|---|------|-------|
| F2 | **LLM 自动标题**（会话命名） | 对齐 opencode `SessionPrompt.ensureTitle`（`prompt.ts:193-255`）：无 parentID + 仅 1 条真实用户消息 + 默认标题 → title agent 生成首行。依赖 P4 compact 的 LLM 基建，P4 落地后评估（SESSION-SYSTEM-OPT P2 延后项） |
| F3 | MCP tool discovery | `mcp_connect` tool — LLM discovers remote tools at runtime |
| F4 | **分支摘要注入**（branch_summary） | 借鉴 pi-repos `branch-summarization.ts`：离开分支/切回主线时 LLM 摘要注入（"用户探索了另一分支..."），告知模型分支探索内容。依赖 P4 LLM 基建（SESSION-SYSTEM-OPT P2 延后项） |

## Architecture wishlist

| # | Item | Notes |
|---|------|-------|
| W1 | Agent file size reduction | agent.zig ~950 lines; extract test helpers, split runTurn |
| W2 | Provider file size reduction | provider.zig ~880 lines; split SSE parsing, JSON building, retry logic |
| W3 | Tool test coverage for error paths | OOM on allocation failure in error paths |
