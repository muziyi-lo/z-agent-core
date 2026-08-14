# Remaining Work

## 实施顺序

```
PHASE-6 (TUI) — 备选方案，待 Zig 生态成熟后再评估
```

## 计划文档状态

| 计划 | 文档 | 状态 |
|------|------|------|
| PHASE-3 | `docs/0.2.2/PLAN-PHASE-3-COMPAT.md` | ✅ 已完成 (v0.2.2) |
| PHASE-4 | `docs/0.2.2/PLAN-PHASE-4-CACHE.md` | ✅ 已完成 (v0.2.2) |
| PHASE-7 | `docs/0.2.3/PLAN-PHASE-7-WEB-FRONTEND.md` | ✅ 已完成 (v0.2.3) — SSE 流式端点 + Web CRUD |
| PHASE-5 | `docs/0.2.8/PLAN-WEBFETCH.md` | ✅ 已完成 (2026-08-13) — webfetch 工具（curl + HTML→MD，9 测试，opencode 对齐） |
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

### 实施顺序（2026-08-13 按重要性与依赖排序）

| 梯队 | 项 | 理由 |
|------|----|------|
| **P0 紧急**（正确性/稳定性，无依赖） | N13 → N14 → N19 → N18 | **✅ 全部已实施（2026-08-14，P0-FIXES）**：glob `**` bug；meta 悬垂 UB（先于一切 meta 相关改动）；SSE 断连无法恢复；压缩后无法继续 |
| **P1 技术债/高价值** | ~~F7~~ → N16 | JSON 模块重构 **✅ 已实施（2026-08-14，JSON-WRITER）**；工具审批+预览（审批依赖权限基建可拆，预览独立） |
| **P2 功能增强** | N17（依赖 N6）→ N15 → F8 → N4/N10 | 虚拟滚动先统一渲染契约；Web 待实现 5 件；title_model（subcall 基建已就绪）；响应式/skill 数组小改 |
| **P3 长期/依赖未就绪** | N8/N9 → N6 → F3/F4/F9/F10/F11/F12 | 增量上下文（格式扩展）；契约统一（结构性）；MCP/记忆/事件总线等 |

**依赖链（必须遵守）**：`N14(UB) → F7(JsonWriter,✅)` · `N6(契约统一) → N17(虚拟滚动)` · `F2(subcall 基建,已完) → F8` · `N8 → N9(同 provider 缓存域)` · `F6 长期项 → N16 审批部分`

### 待办

| # | Item | Notes |
|---|------|-------|
| N1 | Web 会话操作 UI（more-menu Fork/Reset）+ 独立 REST 端点 | **✅ 已实施（2026-08-13，SESSION-UI-FINAL）**：`PATCH /session/:id/fork`/`/reset` 端点（共享 `handleFork`/`handleReset`，command 通道转发，空名自动 `forkTitle`）+ more-menu Fork（输入框）/Reset（confirmModal）按钮 |
| N2 | CLI `/delete <id>` 命令 + sessions 路径常量化 + 删除运行中会话保护 | **✅ 已实施（2026-08-12，OPT2 P2）**：`/delete`（y/N 二次确认 + `resolve` 规范化当前会话保护）、`sessions_subdir` 常量（替换 3 处硬编码）、`session_ops.deleteById`、删除后 `undo_map` 级联清理。见 `docs/0.2.7/PLAN-SESSION-SYSTEM-OPT2.md` P2 |
| N3 | 侧边栏 DOM diff + 会话列表分页 + 分支树收起 + Web CRUD 冒烟测试 | **✅ 已实施（2026-08-13，SESSION-UI-FINAL）**：`loadSessions` 增量 patch（分组层 `data-group` + 组内 id 级 diff）+ 分支收起（localStorage 持久化 + 孤儿 ID 清理）+ `listPage` 分页（`?limit&after` → `{sessions, has_more}`）+ 滚动增量加载。见 `docs/0.2.7/PLAN-SESSION-UI-FINAL.md` |
| N4 | `@container` 响应式侧边栏 | docs/DESIGN-WEB-RENDER.md 待实现 高 — **P2** |
| N5 | 技能覆盖缺口 3 项 (SSE filter / @embedFile 预览适配 / Web 冒烟测试) | docs/PLAN-SKILL-COVERAGE.md GAP-1~3 |
| N6 | DOM 结构契约 + 前端回归验证脚本 (contentDiv 只装 LLM 文本、工具卡片平级挂 asst；chrome-cdp 断言 done 后 tool-card 存在) | 根因已修复 (v0.2.5 parts 重构，PLAN-STREAM-ORDER-PARTS)；剩余：DOM 回归脚本浏览器级落库（Node 测试 37 断言已在 .tmp 提供逻辑级覆盖）— **P3，N17 前置** |
| N7 | CLI `App.zig buildPromptString` 死代码删除（含 2 条测试） | 生产零调用（CONTEXT-ASSEMBLY F1）— 低价值可随时做 |
| N8 | 增量上下文更新（chronogical system 消息 + baseline 持久化） | 对齐 opencode D1，需 DB/会话格式扩展（CONTEXT-ASSEMBLY F3）— **P3** |
| N9 | 系统 prompt 缓存 breakpoint | 依赖 provider 缓存 hint 协议（CONTEXT-ASSEMBLY F4）— **P3，依赖 N8** |
| N10 | 多 skill 目录数组（`skills_dir = ["...", "..."]`） | 索引与 tool 按顺序查找同名 skill，前者优先（CONTEXT-ASSEMBLY F5）— **P2 小改** |
| N11 | 会话系统优化（消息 ID 模型 + 按 ID 操作 + 分页/compact/history） | **一期 P1-P5 + 二期 OPT2 已实施（2026-08-12）**：一期=消息 id + 按 id 操作 + `(fork #N)` 分支（自动重答 + parent_id 分支树）+ 滚动状态机 + 三层流式防护 + `/active` + 游标分页 + `POST /compact` + undo 栈；二期=自动压缩触发（token 预算/迭代摘要/`last_compact_id`）+ CLI `/delete` + `sessions_subdir` + 删除保护/级联。见 `docs/0.2.7/PLAN-SESSION-SYSTEM-OPT.md` + `PLAN-SESSION-SYSTEM-OPT2.md` |
| N12 | 前端工具渲染优化（0.2.8 周期第二项） | **✅ 已实施（2026-08-13）**：工具卡片类型化渲染（ToolRegistry 纯函数化：webfetch url/format/mime 视图 + edit diff 高亮 + bash pre/code 幂等 + fallback 兜底）+ 服务端 ToolMeta 全字段持久化（Message.meta 挂 role=tool 消息，session serialize/parse/append + handler 透出）+ reload 路径挂载 applyToolType（meta 从 API 传入）。附带修复：system prompt 重复渲染（renderMessages 滤 system）+ 侧边栏高亮失效（增量 diff 刷 active 类）。见 `docs/0.2.8/PLAN-TOOL-CARD-TYPED.md` |
| N13 | **glob `**` 递归匹配未实现**（0.2.6 计划搁浅，2026-08-13 审计发现） | **✅ 已实施（2026-08-14，P0-FIXES）**：提取 `matchEntry` 统一入口（`**/` 前缀去前缀 + globMatch），walkDir 与 fixture 测试共用；fixture 驱动 9 条单测（含 `a/**/b` out-of-scope 探针）+ 2 集成测试。见 `docs/0.2.8/PLAN-P0-FIXES.md` |
| N14 | **ToolMeta 借用 args Value 悬垂 UB**（0.2.0 标注延后，2026-08-13 审计升级） | **✅ 已实施（2026-08-14，P0-FIXES）**：`ToolResult.args_owned` 持有 parsed 所有权（不可浅拷贝契约）+ `finishExec` 单点转移方法；registry/8 工具 testExec 委托；修复 defer→errdefer 泄漏（unknown/validate 路径手动 deinit）。**F7 前置已解除**。见 `docs/0.2.8/PLAN-P0-FIXES.md` |
| N15 | Web 待实现 5 件（DESIGN-WEB-RENDER §待实现表，2026-08-13 审计发现）— **P2** | 全部未登记：**输入历史**（上下箭头，app.js 无 inputHistory）、**导出对话**（`GET /api/session/:id/export`，handler 无端点）、**多会话标签页**、**消息编辑**（双击 inline + PATCH /message/:index）、**输入框响应式高度**（lh/vh） |
| N16 | 工具审批 + 文件/图片预览（PARTS"高价值三件"剩余，2026-08-13 审计发现）— **P1** | PLAN-STREAM-ORDER-PARTS.md:272-275 明确"另立计划"但从未立。审批=ApprovalModal（危险命令确认，opencode 参考，依赖权限基建可拆独立做）；预览=file.tsx/file-media 内联渲染（读文件/看图，独立） |
| N17 | 虚拟滚动（长会话卡顿）— **P2** | PLAN-STREAM-ORDER-PARTS.md:266——全量渲染，tanstack-virtual 类方案（对齐 opencode）。**依赖 N6 渲染契约统一** |
| N18 | context overflow 自动恢复 | **✅ 已实施（2026-08-14，P0-FIXES）**：provider 新增 `error.ContextOverflow`（SSE error 帧 + error_body 双识别），重试循环跳过 overflow（零退避）；agent runTurn catch → compactSession 重试一次（`overflow_retried` 防循环），三条文案区分失败形态，Web error 帧透传。见 `docs/0.2.8/PLAN-P0-FIXES.md` |
| N19 | 错误边界 + SSE 断连恢复 | **✅ 已实施（2026-08-14，P0-FIXES）**：全局错误边界（error/unhandledrejection → 横幅非白屏）+ `conn` 状态机（idle/streaming/recovering/degraded，单点分发，含 recovering--send 兜底 + 横幅闭环）+ api_error error 帧透传 + 恢复失败降级（1.5s 重试一次）。心跳留待后续。见 `docs/0.2.8/PLAN-P0-FIXES.md` |
| N20 | **grep 正则支持**（OPT-3 采纳项未落地，2026-08-13 审计发现）— **P2** | `docs/0.2.0/PLAN-OPT-3-RENDER-TOOLS.md:415` 明确"采纳 `std.regex.Regex` 替代子串匹配"（✅ 标记）但**从未落地**——grep.zig:134/208 仍是 `std.mem.indexOf`（纯子串），LLM 写 `fn.*foo` 期望正则语义得到零匹配（OPT-3:405-409 已记录该痛点）。**根因**：计划基于旧 Zig 假设 `std.regex` 可用，**0.16 已移除该模块**（AGENTS.md 陷阱表确认）→ 替代方案未定 → 计划搁浅。**方案方向**：自实现轻量正则（项目已有 htmlToMarkdown 等手写解析先例）或评估子串+通配符增强（glob 模式复用）满足 LLM 常见需求 |
| N21 | **可折叠卡片模板基座**（CARD-UNIFY 产出，2026-08-14 实施）— **P3** | `makeCard`/`setCardOpen`/`handleCardClick` 统一 thinking/tool/system prompt 三卡片折叠骨架（.card-head/.card-body + .open 契约 + 事件委托 + aria-expanded）。后续候选：①a11y 键盘操作（tabindex+空格/回车，`<details>` 迁移时原生获得）②`<details>/<summary>` 迁移评估（未来新卡片组件优先）③新卡片（MCP/预览）复用模板。见 `docs/0.2.8/PLAN-CARD-UNIFY.md` |

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
| R9 | grep ripgrep 外部二进制 | 增加安装复杂度（注：0.16 无 std.regex，正则方案见 N20） |
| R10 | bash 外部目录警告 | 权限系统范式不同 |
| R12 | 证据回执系统（Evidence Ledger） | 工具间交叉验证，需独立设计 |
| R13 | 并行调度分区 | 后期性能优化 |
| R14 | Web 输入框响应式高度（lh/vh）+ 多会话标签页 | DESIGN-WEB-RENDER §待实现表 |
| R15 | bash 长输出存档（超限写 `.zagent/tool-output/`） | OPT-3.1 T2-7 |
| R16 | 回收站/软删除（`.zagent/trash`） | SESSION-SYSTEM-OPT2"列入后续评估" |
| R17 | 输入准入 steer/queue + RunCoordinator | SESSION-SYSTEM-OPT"后续架构演进" |
| R18 | OPT-3 延后债 6 项（ToolCard 表解耦/toTools schema 缓存/ToolLimits/write old_lines 真实值/ToolEntry.validate 注册/render error 日志） | PLAN-OPT-3-RENDER-TOOLS.md:9-16 顶部延后表，实查均未落地 |
| R19 | S12 跟随系统（prefers-color-scheme 三态） | PLAN-DEEPSEEK-STYLE.md:342"本期不做（后续）" |
| R20 | MG5 分享/批量/移动分组（导出部分=N15） | PLAN-DEEPSEEK-STYLE.md |
| R21 | R4 Prism 替换 hljs | PLAN-DEEPSEEK-STYLE.md |
| R22 | 用户自定义命令（source 字段已预留）+ 完整 init/review/skill 命令 | PLAN-SLASH-COMMANDS.md:14,141 |
| R23 | headless browser 方案（动态页面渲染） | PLAN-WEBFETCH.md:55"动态页面留给未来" |
| R24 | 自动根据缓存命中率调整策略 | OPT-6"高级功能，延后" |
| R25 | generateId 毫秒碰撞重试 | OPT-4"后续可在 generateId 加 while exists" |
| R26 | 流式 markdown worker 化（需 renderVersion 竞态防护） | PLAN-TOOL-CARD-TYPED.md:220 后续演进 |
| R27 | 类型契约（前后端共享 schema） | PARTS:257"裸 JSON 无校验" |
| R28 | per-session/`/title off` 粒度开关 + handler 魔法值清理（catch 50 等） | PLAN-LLM-AUTO-TITLE.md:375,384"另行评估" |

## Future (not started, not researched)

| # | Item | Notes |
|---|------|-------|
| F2 | **LLM 自动标题**（会话命名） | **✅ 已实施（2026-08-13）**：触发时机"恰 2 条真实用户消息后"（第二轮延迟命名，对齐 ChatGPT/Claude "新对话"占位 + 后台生成范式，规避首条元操作消息如"恢复上下文"）。`core/title.zig`（TITLE_PROMPT/STOPWORDS/KEYWORD_* 常量 + shouldAutoTitle/cleanTitle/keywordTitle/fallbackTitle/ensureTitle）+ `core/subcall.zig`（SubcallRunner 后台线程 + active/waitIdle）+ `session_write_mutex` + `renameTitle` 原子事务 + `Config.auto_title`/`title_stop_words` + CLI/Web 回合边界 spawn。LLM 失败三层降级（本地关键词/静态截断）。见 `docs/0.2.7/PLAN-LLM-AUTO-TITLE.md` |
| F3 | MCP tool discovery — **P3** | `mcp_connect` tool — LLM discovers remote tools at runtime。无基础设施，需外部协议研究 |
| F4 | **分支摘要注入**（branch_summary）— **P3** | 借鉴 pi-repos `branch-summarization.ts`：离开分支/切回主线时 LLM 摘要注入（"用户探索了另一分支..."），告知模型分支探索内容。依赖 P4 LLM 基建（SESSION-SYSTEM-OPT P2 延后项，subcall 已就绪可评估） |
| F5 | **会话崩溃恢复（消息层容错）** | **调研决策（2026-08-13）：不做 undo 持久化**——undo 是短暂撤销窗口（cap 20），持久化收益小、成本高（事件文件 + 重放 + compact 一致性）。崩溃恢复聚焦消息层：会话消息已 JSONL 原子落盘（`session.flush` tmp+rename），崩溃最多丢当前回合尾部；**tmp 残留清理已实施（SESSION-UI-FINAL D4，`init.zig` 启动删 `*.jsonl.tmp`）**；文件损坏容错（`load` 已跳坏行）。撤销窗口重启丢失可接受（对齐 opencode 内存 undo） |
| F6 | **dsh 架构借鉴候选**（DeepSeek Harness 对比调研 2026-08-13，非 0.2.8 主题）— **P3 长期** | 因 dsh 突然发布而做的对比研究（文档：`C:\VibeCoding\Projects\zAgentCore\docs\deepseek-harness-vs-zagent-core.md`，仓库外不占发布周期）。低成本可采纳（按成本/收益排序）：① **request/header 请求快照**——每次请求把"系统提示词+工具 schema+请求配置"落盘为只读记录，获请求级审计/调试（无需完整事件溯源）；② **chunk 级持久化**——SSE 原始 chunk 追加进会话（trace 级即可），崩溃后 UI 可重放；③ **compaction 影子记录**——压缩时记录 shadowedRange/shadowedSeqs（哪怕仅日志），保留可审计性。长期：fail-closed 审批（unavailable=拒绝）、单调守卫（只能拒绝不能放行）、per-call 沙箱策略。详见对比文档第 10 节 |
| F7 | **JSON 序列化统一模块**（手写拼接重构，2026-08-13 触发） | **✅ 已实施（2026-08-14，JSON-WRITER）**：新增 `src/util/jsonw.zig`（JsonWriter：自动逗号 + 完整转义 + 容器自平衡 + `Result` 终态持有者 + fixed→alloc 回退）；统一 4 份转义为 `escapeInto`/`escapeAlloc`（handler/sse 修复缺控制字符的既有 bug）；ToolMeta 全字段序列化收敛为 `types.writeJson`（session/handler 共用，字段集对齐）；session/provider/handler/sse 全部改用 JsonWriter（约 180 处手写拼接 → 声明式）；JSONL golden 基线测试（字节零差异）+ 8 变体 roundtrip（双遍）。**净删 167 行**。见 `docs/0.2.8/PLAN-JSON-WRITER.md` |
| F8 | **small model（`title_model` 配置）**（登记声明落空，2026-08-13 审计发现）— **P2** | PLAN-LLM-AUTO-TITLE.md:86 自称"列入 REMAINING Future"但实际无条目。LLM 自动标题/压缩用低成本小模型（对齐 opencode），避免大模型开销。subcall 基建已就绪 |
| F9 | **ToolEntry `prompt_hint` 愿景**（行为指导注入系统提示词）— **P3** | CORE-FRONTEND.md:550-569——validate 有字段但 9 工具零注册，架构愿景未实现未登记 |
| F10 | **记忆系统 remember.zig/recall.zig 工具** — **P3** | CORE-FRONTEND.md:540-541 planned 工具——src/tool/ 无此二文件，REMAINING 无条目。注意：已有外部 memory-manager 技能（.opencode/skills），本项目内建 vs 外部技能需评估 |
| F11 | **事件总线 EventBus** — **P3** | PLAN-LOGGING-SYSTEM.md:194"后续 UI/日志订阅扩展时再评估"+ OPT-5 流式事件系统同源未闭合 |
| F12 | **千问自定义分组**（SB5，登记声明落空）— **P3** | PLAN-DEEPSEEK-STYLE.md:141 自称"记 REMAINING"实际未记。模型分组/说明（M5）同源 |
| F13 | **JsonWriter pretty 输出选项**（调试可读性）— **未来** | F7 评审提出：当前紧凑格式（JSONL/API/SSE 依赖），未来调试可读性可在 `JsonWriter` 加 `pretty: bool`（begin 后写换行 + 按 depth 缩进 + 元素间换行）。因所有输出已收敛走 JsonWriter，启用点为单一配置，纯增量不改默认紧凑输出。见 `docs/0.2.8/PLAN-JSON-WRITER.md` |
| F14 | **魔法值全量审查与提取**（调研完成 2026-08-14，实施待排期） | 按 D-04 判据（同值≥2处/跨模块/有业务语义）全量扫描 `src/`。**已提取**：`SESSION_PAGE_LIMIT`/`UNDO_CAP`(handler)、`TITLE_MAX_CHARS`/`TITLE_PREFIX_LEN`(title，handler:1068 已引用)、`DEFAULT_TIMEOUT_SECS`/`MAX_TIMEOUT_SECS`(webfetch)、`DEFAULT_KEEP_RECENT_TOKENS`/`MIN_KEEP_MESSAGES`(compact)。**待提取候选**：①**`isBinary` 30% 控制字符阈值 + 4096 检查窗口——bash.zig:197 与 read.zig:273 同逻辑复制（跨模块同值同语义，D-03 逻辑重复）**，建议提取 `util/text.isBinary`（read 已有 `BINARY_CHECK_SIZE`=4096 常量可并入）；②render.zig 显示截断 30/50（`truncatePath`/`shorten` 多处裸值，显示语义，建议命名）。**判定维持现状**（无同值耦合，提取反而制造假耦合）：session.zig:449 消息数警告 `>50`（≠handler 分页 50）；session.zig:860 字节估算 `size/150`（单处）；sse.zig:236 分块 7000（单处）；栈缓冲 4096/8192 大量出现但无业务语义。触发：提取 `isBinary` 时顺手清 title/render 显示截断域 |

## Architecture wishlist

| # | Item | Notes |
|---|------|-------|
| W1 | Agent file size reduction | agent.zig ~950 lines; extract test helpers, split runTurn |
| W2 | Provider file size reduction | provider.zig ~880 lines; split SSE parsing, JSON building, retry logic |
| W3 | Tool test coverage for error paths | OOM on allocation failure in error paths |
