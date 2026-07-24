# Remaining Work

## 实施顺序

```
PHASE-7 (Web 前端)  ← 当前（计划文档已创建）
    ↓
PHASE-5 (webfetch) — 独立于架构，可随时实施（计划文档已完善）
    ↓
PHASE-6 (TUI) — 备选方案，待 Zig 生态成熟后再评估
```

## 计划文档状态

| 计划 | 文档 | 状态 |
|------|------|------|
| PHASE-3 | `docs/0.2.2/PLAN-PHASE-3-COMPAT.md` | ✅ 已完成 (v0.2.2) |
| PHASE-4 | `docs/0.2.2/PLAN-PHASE-4-CACHE.md` | ✅ 已完成 (v0.2.2) |
| PHASE-7 | `docs/PLAN-PHASE-7-WEB-FRONTEND.md` | 实施中 (MVP — `zig build -- --web` 可用，SSE 流式待实现) |
| PHASE-5 | `docs/PLAN-PHASE-5-WEBFETCH.md` | 计划中 |
| PHASE-6 | `docs/PLAN-PHASE-6-TUI.md` | 架构设计 |
| MCP | 无文档 | 未计划 |

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

## Deferred (explicitly skipped)

| # | Item | Reason |
|---|------|--------|
| R1 | compact.zig (Phase 2F) | → OPT-5 P0-1 — compact 工具 + session 压缩 |
| R2 | DisplayHint (v2 tool metadata) | OPT-3 已覆盖 — ToolMeta 替代 |
| R3 | Tool event streaming (start/update/end) | Requires significant protocol change |
| R4 | Edit 模糊匹配 | 待 opencode 实现后跟进 |
| R5 | read 图片支持 (base64) | 模型视觉能力不一致 |
| R6 | read realpath 双重解析 | Windows 符号链接少，`..` 检测已覆盖 |
| R7 | write BOM 保留 | 边界场景 |
| R8 | write 竞争防护 (writeIfUnchanged) | 需文件 hash 基础设施，单进程无并发 |
| R9 | grep ripgrep 外部二进制 | `std.regex` 满足需求 |
| R10 | bash 外部目录警告 | 权限系统范式不同 |
| R11 | 死循环检测（StormBreaker） | → OPT-5 P1-3 — 连续 3 次相同 (name, args_hash) → 追加系统消息提示 |
| R12 | 证据回执系统（Evidence Ledger） | 工具间交叉验证，需独立设计 |
| R13 | 并行调度分区 | 后期性能优化 |

## Future (not started, not researched)

| # | Item | Notes |
|---|------|-------|
| F3 | MCP tool discovery | `mcp_connect` tool — LLM discovers remote tools at runtime |

## Architecture wishlist

| # | Item | Notes |
|---|------|-------|
| W1 | Agent file size reduction | agent.zig ~950 lines; extract test helpers, split runTurn |
| W2 | Provider file size reduction | provider.zig ~880 lines; split SSE parsing, JSON building, retry logic |
| W3 | Tool test coverage for error paths | OOM on allocation failure in error paths |
