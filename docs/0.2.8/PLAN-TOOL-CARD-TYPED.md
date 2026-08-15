# Plan N12: 前端工具渲染类型化（Tool Card Typed Rendering）

> 周期: 0.2.8（工具优化第二项，与 WebFetch 同周期同目录）
> 日期: 2026-08-13
> 参考: ① 前身计划 `docs/0.2.5/PLAN-STREAM-ORDER-PARTS.md`（v0.2.5 parts 模型重构，已完成——本方案是它"后续演进·功能层高价值"清单的落地，其中 **diff/补丁视图位列第 273 行**）；② deepseek-harness `presentCall`/`presentResult` card 理念（纯函数 render intent，无副作用可重放）；③ opencode DiffView/工具审批（PARTS 计划第 272-273 行已扫描）；④ 历史 DOM 双轨教训（LRN-20260806-005/007、LRN-20260807-005）

## 状态: ✅ 已完成（2026-08-13，REMAINING N12 已标记实施）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

> 注：阶段 1（服务端 meta 持久化）内部阻塞阶段 3（reload 挂载）——reload 无 meta 数据源则类型化视图退化通用卡片；此为方案内部依赖，非外部阻塞。

## 与前身计划的关系（沿用其成熟决策，不重复论证）

| PLAN-STREAM-ORDER-PARTS 决策 | 本方案承接 |
|---|---|
| segments 数据模型（消息 = 有序 reasoning/text/tool 数组）+ 统一渲染函数 `renderAssistantMessage` | **已落地**（buildSegment/renderAssistantMessage 双路径共用）——本方案只增强 tool segment 渲染 |
| 段级精确更新（方案 B），全量重渲染仅用于消息终态 | 沿用——applyToolType 只操作单卡片内部，不触及其他段 |
| 不做清单：不引框架、不一次性重写、无兼容性掣肘 | 沿用——本方案仍 vanilla JS 单文件内推进 |
| 后续演进·功能层高价值三件（diff/审批/预览） | 本方案落地第 1 件（diff 视图）；审批/预览另立计划 |
| wrapContextToolGroups 兼容性 4 项核对 | 本方案改动 tool segment 时必须重查（见风险表） |
| 前端测试防护网（N6，PARTS 计划第 286 行"先补测试"） | **已建**（10 测试文件）——本方案在防护网内推进 |

## 问题背景

当前工具卡片渲染停留在"换图标 + meta 行"水平，且**双路径不对称**：

| 路径 | 挂载点 | 现状 |
|---|---|---|
| 流式 done（app.js:1415） | `applyToolType(tc, tc._toolName, tc._toolData)` | ✅ 调用但只换图标/meta |
| reload（`renderMessages` → `addMessage` → `buildSegment`） | **从不调用 applyToolType** | ❌ 工具输出只有裸 renderMd，bash 无 pre/code 包装、diff 无高亮、meta 全部缺失 |

已有 `ToolRegistry`（app.js:1747）含 6 个工具（bash/read/write/edit/grep/glob/skill），但：
- 无 `webfetch`（0.2.8 新增工具，ToolMeta 有 url/byte_count/format/mime）
- `bash` 的 pre/code 包装只在流式生效（reload 缺失）
- 无 diff 视图（edit 有 old/new 行数但无高亮）
- `tool_meta` 事件手写 meta 拼装（app.js:1303-1325）与 `ToolRegistry` 内 setToolMeta 逻辑**重复**——同一工具 meta 有两处定义

## 目标

1. **类型化渲染**：每个工具一种专属视图（纯函数 `(toolDiv, toolData) → void`，只操作传入节点内部，无外部状态依赖——对齐 dsh presentCall/presentResult 可重放理念）
2. **双路径统一**：reload 与流式都走 `applyToolType`（reload 路径补挂载点 + 补 `_toolData` 来源）
3. **meta 单一来源**：删除 `tool_meta` 处理器的手写拼装，改为 `applyToolType` 内统一生成
4. **新工具覆盖**：webfetch 视图（url/format/mime/byte_count）

## 不做

- **不做** N6 渲染契约统一（流式/reload 状态模型单轨）——结构性重构另立计划；本计划只统一"工具卡片类型化渲染"挂载点
- **不做** 工具审批/文件预览（PARTS 高价值三件的其余两件，另立计划）
- **不做** context tool 分组改动（wrapContextToolGroups 已工作；本方案只保持其兼容）
- **不改** SSE 协议（tool_meta 事件已含所需字段）
- **前置核查结论（2026-08-13）**：ToolMeta **未持久化**——`session.zig serializeMessage`（680-754）只写 content/reasoning/tool_calls/tool_call_id/model/timestamp/usage，**无 meta 字段**；`ToolCall` 仅 `id/name/arguments`（types.zig:40）；Web API `serializeMessageForClient`（handler.zig:1270+）同构。→ **reload 路径无 meta 数据源**，类型化视图只能拿到 name+output。本计划含服务端 meta 持久化（阶段 1），否则 reload 端只能显示通用卡片（双轨再次不对称）

## 设计

### 核心：`ToolRegistry` 纯函数化 + `applyToolType` 成为唯一挂载点

```js
// 现状签名（保持）：每个条目是 (toolDiv, toolData) => void
// 约束：只操作 toolDiv 内部 DOM，不得读全局流式状态（curSegments 等）
var ToolRegistry = {
  bash:      function(toolDiv, d) { /* pre/code + copy-cmd + exit meta */ },
  read:      function(toolDiv, d) { /* 行数/B 元数据 */ },
  write:     function(toolDiv, d) { /* B + new/overwrote */ },
  edit:      function(toolDiv, d) { /* replacements + 可选 diff 高亮 */ },
  grep:      function(toolDiv, d) { /* matches + files_scanned */ },
  glob:      function(toolDiv, d) { /* file_count */ },
  skill:     function(toolDiv, d) { /* file_count */ },
  webfetch:  function(toolDiv, d) { /* url + format + mime + B */ },   // 新增
  fallback:  function(toolDiv, d) { /* 未知工具兜底：通用图标 + name + output */ }  // 新增
};
```

**fallback 兜底渲染器**（评论者建议）：
- 当前未知工具走 `if (ToolRegistry[toolName])` 隐式空操作——`buildSegment` 已渲染 name + output，但**无统一图标、无显式兜底契约**
- `applyToolType` 改为 `ToolRegistry[toolName] || ToolRegistry.fallback`——未知工具（含未来 MCP 动态工具，F3）确定性地走通用卡片（`tool-unknown` 类 + 通用图标 + name + output），不抛错、不静默
- 新增工具忘注册时行为可预测（有兜底），且 fallback 本身可被审查

### 关键改动点

**A. 服务端 meta 持久化（前置，阶段 1）**
- **存储位置（设计定稿）**：`Message.meta` 只挂 `role=tool` 消息——agent.zig:430 是唯一数据源（`exec_result.meta`），tool 消息已有 `tool_call_id` 关联键；assistant 消息 tool_calls 无需 meta（前端 reload 按 tool_call_id 回填到对应 tool segment）
- `types.Message` 增加 `meta: ?types.ToolMeta = null`
- **agent.zig:430/442 两处 append tool 消息**：430 传 `ok.meta`；442（执行错误）meta 传 `.none`（无工具结果）
- `session.zig` serializeMessage/parse：tool 消息序列化 meta（ToolMeta 各变体 → 扁平 JSON 对象，含**全部字段含字符串** url/path/pattern/command/name/format/mime）；parse 缺 meta 兼容旧文件（= null）
- **`session.zig append()` 深拷贝（第三处序列化点，审查补充）**：现 append 对 tool_calls 逐字段 dupe（session.zig:269-279 模式），`Message.meta` 加入后必须同步 dupe——meta 内字符串字段全部 arena.dupe，非借用
- **⚠️ 不复用 sse.zig serializeMeta（核查发现字段不全）**：sse 版本只序列化数值字段（url/path/pattern/command/name/format/mime 全部丢弃），仅够流式摘要展示；session 持久化需全字段 → 新增独立序列化函数（与 sse 同构但完整），parse 逆操作。两处漂移风险登记：sse 流式摘要 / session 全量持久化，未来新增 ToolMeta 变体需同步两处 + parse（三处），在类型定义注释标注
- `handler.zig` serializeMessageForClient：透出 meta（与 serializeMessage 同构）
- 注意 ToolMeta 零拷贝借用约束（types.zig:61 注释）——持久化路径必须 dupe
- **旧文件兼容行为链**：旧 JSONL 无 meta → parse 得 `meta = null` → 前端 `seg.data` 空 → `applyToolType` 收到 `{}` → 各工具渲染器字段判断全 false → meta 行不显示，输出仍 renderMd（= 通用卡片），不报错不降级异常

**B. reload 路径补挂载**（app.js `renderMessages` / `addMessage` / `renderAssistantMessage`）
- tool segment 构建时（addMessage 内 tool_calls 分支，app.js:1050-1051）为 segment 注入 `seg.data`（reload 时来自消息 meta）
- `renderMessages` 填充 output 后调用 `applyToolType(ts.el, ts.name, ts.data || {})`
- `buildSegment` 的 tool 分支把 `seg.data` 存到 `el._toolData`

**C. 流式 meta 去重 + 幂等化**（app.js `tool_meta` 处理器 1303-1325）
- 保留事件（服务端字段收集），删除手写 parts 拼装（1315-1322），改为：更新 `_toolData` 后调用 `applyToolType`（幂等，见下）
- **幂等契约（评论者补充，三层）**：
  1. **bash pre/code 包装**：判断 `.output` 内是否已有 `pre>code`（如 `querySelector('.output pre')` 存在则跳过）——防重复包裹
  2. **meta 节点复用**：`setToolMeta` 已幂等（存在 `.tool-meta` 则复用节点，不重复创建）
  3. **parts 从累积 `_toolData` 构建（关键）**：现 1315-1322 行 parts 从**单次事件 `d`** 构建——服务端分两次发 tool_meta（先 `exit_code` 后 `byte_count`）时第二次覆盖丢失第一次字段。改为所有工具渲染函数**只读 `toolData` 全量字段**（`setToolMeta` 的调用方传累积数据），保证任意多次调用结果一致（真幂等、可重放——对齐 dsh render intent）
- 测试断言：模拟两次 tool_meta（不同字段）→ 最终 meta 含两次字段合集

**D. webfetch 视图**
```js
webfetch: function(toolDiv, d) {
  setToolIcon(toolDiv, '&#128279;');
  var p = [];
  if (d.url) p.push(d.url);
  if (d.format) p.push(d.format);
  if (d.mime) p.push(d.mime);
  if (d.byte_count) p.push(d.byte_count + 'B');
  if (p.length) setToolMeta(toolDiv, p);
}
```

**E. edit diff 视图（可选增强）**
- 若 `d.old_lines`/`d.new_lines` 存在且 output 为统一 diff 格式 → 加 `tool-diff` 类 + 行号/高亮（简单版：`+`/`-` 行着色，不需要真正的 diff 解析库）

**F. bash reload 补包装**
- bash 条目内已有 pre/code 包装逻辑，reload 路径补挂载后自动生效（A/B 是前置）

### 交互矩阵（G16，多特性交叉边界）

| × | webfetch 视图 | fallback 兜底 | edit diff | meta 幂等 | reload 挂载 |
|---|---|---|---|---|---|
| webfetch 视图 | — | webfetch 已注册 → 不走 fallback，无冲突 | 不同工具卡片，互不干扰 | 幂等 → 多次 tool_meta 不重复渲染 | reload 有 meta → 与流式同视图 |
| fallback 兜底 | — | — | 未知工具无 diff 概念 | 幂等（空数据反复调用无副作用） | 旧文件无 meta → fallback/通用卡片，双轨一致 |
| edit diff | — | — | — | 幂等 → 重复调用不高亮叠加 | reload 有 meta → 高亮与流式一致 |
| meta 幂等 | — | — | — | — | 双路径同函数 → 输出同构（LRN-20260806-007 回归重点） |

### 纯函数约束（对齐 dsh render intent）

- `ToolRegistry` 条目不得引用 `curSegments`/`currentTool`/`isStreaming` 等流式闭包变量
- 同一 `(toolDiv, toolData)` 调用多次结果一致（幂等，可重放）

### G7 说明（Zig stdlib API）

本方案服务端改动**不引入新 `std.*`/`Io.*` API**——serializeMessage/parse/append 全部复用既有模式（`buf.appendSlice`/`std.json` 解析已在 session.zig 使用），无对照表/桩验证需求。新增逻辑为纯 JS（前端）与既有 Zig 模式复用（服务端）。

## 实施步骤

| 阶段 | 内容 | 验证 |
|---|---|---|
| 1 | 服务端 meta 持久化：types.Message.meta + session serialize/parse/**append 深拷贝** + handler 透出 + dupe 生命周期 | zig build + zig test（session roundtrip 测试扩展） |
| 2 | `ToolRegistry` 补 webfetch（D）+ edit diff 高亮（E）+ bash 幂等化（C-1） | L0 |
| 3 | reload 路径挂载 `applyToolType`（B，含 `seg.data` 传递 + 空 meta 降级链） | L0 + 前端测试 |
| 4 | `tool_meta` 处理器去重（C，改调 applyToolType） | L0 + 前端测试 |
| 5 | 新增/更新前端测试（test-loadsession-segments 断言工具视图、新增 test-tool-registry.mjs） | `node tests/frontend/run-tests.mjs` |
| 6 | 浏览器双路径实测（流式 + reload 各一轮，含 webfetch/bash/edit） | L2 用户视觉确认 |

## 测试策略

- 新增 `tests/frontend/test-tool-registry.mjs`：花括号匹配提取 ToolRegistry + applyToolType，DOM stub 断言：
  - webfetch 视图（url/format/mime/B 出现在 tool-meta）
  - bash 幂等（调用两次不产生双重 pre/code）
  - **meta 幂等**：两次调用（第二次只含新增字段）→ meta 文本为字段合集（验证 parts 从累积数据构建）
  - edit diff 高亮类
  - **fallback 兜底**：未知工具（如 `mcp_connect`）走 `ToolRegistry.fallback`（tool-unknown 类 + name/output 保留），且不抛错
- 更新 `test-loadsession-segments.mjs`：断言 reload 后工具卡片应用了类型化视图（如 bash 有 pre/code）
- **回归重点**：LRN-20260806-007 双轨一致——流式与 reload 必须产出相同工具卡片结构

## 风险与对策

| 风险 | 对策 |
|---|---|
| ToolMeta 零拷贝借用 + 持久化冲突（types.zig:61 零借用注释） | 阶段 1 明确：meta 持久化走 JSON 序列化/反序列化（dupe），不持有借用；parse 缺 meta 兼容旧 JSONL（旧会话降级通用卡片） |
| tool_meta 多次调用导致重复渲染 | 阶段 2 幂等化（bash 判断已包 pre/code；setToolMeta 已幂等） |
| 双轨再次分叉 | 每阶段在流式 + reload 双路径验证（LRN-20260806-007 教训） |
| diff 视图过度设计 | D 标注为可选增强，若输出非标准 diff 格式则跳过，不引入 diff 库 |

## 验收标准

- [x] webfetch 工具卡片显示 url/format/mime/B
- [x] reload 会话后工具卡片与流式会话结构一致（bash pre/code、meta 齐全）
- [x] edit 工具 diff 高亮（若输出为标准 diff）
- [x] `node tests/frontend/run-tests.mjs` 全过（11 文件含新增 test-tool-registry）
- [x] 双路径浏览器实测通过（L2 用户确认 2026-08-13）
- [x] 附带修复：system prompt 重复渲染 + 侧边栏高亮失效（LRN-20260813-018）

## 实施偏差记录

| 偏差 | 说明 |
|---|---|
| 服务端 meta 序列化三处实现 | 计划曾考虑复用 sse.zig serializeMeta——核查发现其仅数值摘要（丢字符串字段），session/handler 各需全字段序列化 → 三处独立实现（session.zig appendToolMetaJson / handler.zig appendMetaJson / sse.zig serializeMeta），已在类型注释标注同步义务 |
| skill 字段键特判 | skill 变体 `name` 字段与顶层标签键 `name` 冲突 → 序列化用 `skill` 键 + parse 特判（session.zig parseToolMetaVariant + handler.zig appendMetaJson） |
| 格式串转义坑 | handler 初版用 allocPrint 大格式串，`}}` 转义反复出错 + 脚本误伤既有代码 → 最终改为分步 appendSlice 拼接（与 session 同模式） |
| 附带修复 2 项 | 用户实测暴露：renderMessages 未滤 system 消息（重复渲染）+ loadSessions 增量 diff 不刷新 active 类（高亮失效）——均非本方案引入但同路径修复 |

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/types.zig` | `Message` 增 `meta` 字段 | 否（parse 缺 meta 兼容旧 JSONL） |
| `src/core/session.zig` | serializeMessage/parse 增 meta | 否（旧文件缺字段降级） |
| `src/frontends/web/handler.zig` | serializeMessageForClient 透出 meta | 否 |
| `src/frontends/web/app.js` | ToolRegistry 增强 + reload 挂载 + tool_meta 去重 | 否（协议不变） |
| `src/frontends/web/app.css` | diff 高亮样式（少量） | 否 |
| `tests/frontend/` | 新增 test-tool-registry.mjs + 更新 test-loadsession-segments.mjs | 否 |
| `docs/REMAINING.md` | N12 标记实施 | 否 |

## 生命周期管理（对齐项目规范）

| 阶段 | 动作 | 门禁 |
|---|---|---|
| 计划（本文档） | docs/0.2.8/ 归档 | 已入周期目录 |
| 实施 | 按阶段 1-6 推进 | 每阶段 L0 + 前端测试 |
| 双路径验证 | 流式 + reload 各一轮 | L2 用户确认（硬约束） |
| 收尾 | REMAINING N12 标记 + CHANGELOG [Unreleased] | check-version 门禁 |
| 发布 | 周期闭合时 bump（本周期还含 WebFetch 等，统一发布） | bump-version 脚本 |

## 后续演进（不在本计划）

- 工具审批（ApprovalModal）、文件/图片预览（PARTS 高价值三件剩余）
- 流式 markdown worker 化（需 renderVersion 竞态防护，PARTS 第 105-121 行前置条件声明）
- 渲染契约统一（N6）
