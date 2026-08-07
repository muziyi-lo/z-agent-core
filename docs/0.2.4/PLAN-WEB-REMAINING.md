# PLAN: Web UI 剩余项 — 工具视图 + 上下文分组 + 消息操作

> **状态**: ✅ G8/G9/G11 已实现 (G8 全部7种工具, G9 两遍扫描, G11 revert+copy)。本文档作为设计参考保留。

## 术语

| 术语 | 含义 |
|------|------|
| ToolRegistry | 按工具名分派渲染函数，bash 已实现 Copy cmd |
| ContextToolGroup | 连续 2+ 个 read/grep/glob 合并为一个折叠组 |
| MessageAction | 每条消息的可操作控件（删除·复制·revert） |

## 现状

| 项目 | 状态 |
|------|------|
| G8 ToolRegistry | 框架已建立，仅 bash 实现 Copy cmd; read/write/edit/grep/glob/skill 为 `function(){}` 空桩 |
| G9 ContextToolGroup | 未实现 |
| G11 MessageAction | P3-3 已加 msg-meta (model+timestamp)，无 revert |
| 工具卡片 session 加载工具名 | P2-1 已通过 tool_call_id 匹配实现 |

## G8: 其余工具类型化视图

### 前端 ToolMeta 接口定义

`tool_meta` SSE 事件的 JSON 结构 (由 `sse.zig serializeMeta` 定义):

```javascript
// 前端消费时的类型约定:
type ToolMeta = {
  bash:   { name: "bash",   exit_code: number, byte_count: number };
  read:   { name: "read",   total_lines: number, byte_count: number, truncated: boolean };
  grep:   { name: "grep",   match_count: number, files_scanned: number };
  glob:   { name: "glob",   file_count: number };
  edit:   { name: "edit",   replacements: number };
  write:  { name: "write",  byte_count: number };
  skill:  { name: "skill",  file_count: number };
};
// 存储在 toolDiv._toolData 上, tool_start 事件填充 id/name, tool_meta 合并
```

### read — 文件内容查看

```
┌─ ▼ ⌂ read: docs/foo.md ──────────────────────┐
│  3,412 lines · 128KB                          │  ← tool-meta
│  ┌ output (markdown) ────────────────────────┐│
│  │ ...文件内容...                              ││
│  └───────────────────────────────────────────┘│
└───────────────────────────────────────────────┘
```

实现: `ToolRegistry.read` 检查 `tool_meta` 数据 → 显示行数/大小；图标 `⌂`

### write — 文件写入

```
┌─ ▼ ✎ write: docs/bar.md ─────────────────────┐
│  existed: true · 1,234B                       │  ← tool-meta
│  ┌ output ──────────────────────────────────┐ │
│  │ Wrote 1,234 bytes to docs/bar.md         │ │
│  └─────────────────────────────────────────┘ │
└───────────────────────────────────────────────┘
```

实现: `ToolRegistry.write` 显示 existed/byte_count；图标 `✎`

### edit — 文件编辑

```
┌─ ▼ ✂ edit: src/main.zig ─────────────────────┐
│  2 replacements                               │  ← tool-meta
│  ┌ output ──────────────────────────────────┐ │
│  │ Replaced 2 occurrences in src/main.zig   │ │
│  └─────────────────────────────────────────┘ │
└───────────────────────────────────────────────┘
```

实现: `ToolRegistry.edit` 显示 replacements 数；图标 `✂`

### grep — 搜索

```
┌─ ▼ ⌕ grep: "function" ───────────────────────┐
│  5 matches in 3 files                         │  ← tool-meta
│  ┌ output ──────────────────────────────────┐ │
│  │ src/a.zig:10: function foo()             │ │
│  │ src/b.zig:25: function bar()             │ │
│  └─────────────────────────────────────────┘ │
└───────────────────────────────────────────────┘
```

实现: `ToolRegistry.grep` 显示 match_count/files_scanned；图标 `⌕`

### glob — 文件匹配

```
┌─ ▼ ∗ glob: "*.zig" ──────────────────────────┐
│  12 files                                      │  ← tool-meta
│  ┌ output ──────────────────────────────────┐ │
│  │ src/main.zig                             │ │
│  │ src/config.zig                           │ │
│  └─────────────────────────────────────────┘ │
└───────────────────────────────────────────────┘
```

实现: `ToolRegistry.glob` 显示 file_count；图标 `∗`

### skill — 技能加载

```
┌─ ▼ ⚡ skill: zig-dev ─────────────────────────┐
│  3 files                                       │  ← tool-meta
│  ┌ output ──────────────────────────────────┐ │
│  │ Loaded skill 'zig-dev' (3 files)         │ │
│  └─────────────────────────────────────────┘ │
└───────────────────────────────────────────────┘
```

实现: `ToolRegistry.skill` 显示 file_count；图标 `⚡`

### 统一入口

所有工具共享 `applyToolType(toolDiv, toolName, toolData)`:
1. tool_start 时存储 `_toolName` + `_toolData`
2. tool_meta 到达时合并数据到 `_toolData`
3. done 时调用 `applyToolType` → 传入完整 `_toolData` (含 meta)

## G9: ContextToolGroup

### 触发条件

连续 ≥2 个工具且名称均为 `read`/`grep`/`glob` 之一。

### 渲染

```
┌─ Gathering context ───────────────────────────┐
│  read: 2 files · grep: 3 matches · glob: 5 files│  ← 摘要行
│  ┌ ▼ ⌂ read: docs/foo.md ───────────────────┐ │
│  │  3,412 lines · 128KB                      │ │
│  │  ┌ output ──────────────────────────────┐ │ │
│  │  │ ...文件内容...                        │ │ │
│  │  └─────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────┘ │
│  ┌ ▼ ⌕ grep: "function" ────────────────────┐ │
│  │  ...                                     │ │
│  └──────────────────────────────────────────┘ │
└───────────────────────────────────────────────┘
```

### 实现

**索引安全**: DOM 移动后 NodeList 错位 → 两遍扫描:

```
Pass 1 — 标记边界 (不修改 DOM):
  const cards = [...asst.querySelectorAll('.tool-card')];  // snapshot
  const groups = [];
  let start = null, groupEnd = null;
  for (card of cards) {
    if (card._toolName === 'read' || card._toolName === 'grep' || card._toolName === 'glob') {
      if (!start) start = card;
      groupEnd = card;
    } else {
      if (start) { groups.push({from: start, to: groupEnd}); start = groupEnd = null; }
    }
  }
  if (start) groups.push({from: start, to: groupEnd});

`loadSession()` 中同理 — `addMessage` 返回的 tool div 也会被后续检测分组。

**CSS**:
```css
.context-tool-group{border:0.5px solid var(--border-base);border-radius:var(--radius-md);margin:4px 0;padding:4px}
.context-tool-group .group-summary{padding:4px 8px;font-size:var(--text-xs);color:var(--text-muted);border-bottom:0.5px solid var(--border-muted);cursor:pointer}
.context-tool-group .group-summary:hover{color:var(--text-strong)}
```

### sse.zig tool_meta 序列化位置

`renderTool()` 中 `tool_meta` 事件发送顺序:

`serializeMeta` 补全字段 (P2-3 已有 bash/read/grep/glob/edit/write/skill 骨架，需补齐 read 的 `truncated`、grep 的 `files_scanned`):

```
read:   total_lines, byte_count, truncated
grep:   match_count, files_scanned
glob:   file_count
edit:   replacements
write:  byte_count
skill:  file_count
bash:   exit_code, byte_count  (已实现)
```

```
renderTool 执行流程:
  if (had_error) → tool_error event → return
  else:
    1. tool_args header (如果非空且非 {}) → tool_delta
    2. user_output chunks → tool_delta (分块 7000 字节)
    3. serializeMeta → tool_meta event   ← 始终在输出之后
    4. return
```

理由: 输出内容先到前端 (流式可见)，元数据后到 (done 前汇总)。前端 `tool_meta` handler 将数据合并到 `currentTool._toolData`，done 事件的 `applyToolType` 使用完整数据。

## G11: MessageAction 增强

### revert — 回退消息

仅 user 消息支持: 点击 revert → 恢复 prompt 到输入框，不删除消息。

```
消息右侧 hover 显操作栏:
  [revert] [copy] [×]

revert 点击 → prompt-input.value = content → focus
copy 点击 → navigator.clipboard.writeText(content) → "Copied!" 1.5s
```

**revert 时输入框已有内容的处理**: 用户已输入但未发送的草稿会被覆盖。

| 场景 | 行为 |
|------|------|
| 输入框为空 | 直接填入 content |
| 输入框有草稿 (非空白) | 填入 content，草稿丢失 (不弹 confirm — revert 是主动操作，用户意图明确) |
| 用户可 undo | 浏览器原生 Ctrl+Z 恢复 (textarea 的 `value = content` 进入 undo 栈) |

**CSS**:
```css
.msg-actions{position:absolute;top:4px;right:8px;display:flex;gap:4px;opacity:0;transition:opacity var(--transition-fast)}
.msg:hover .msg-actions{opacity:1}
.msg-action{padding:1px 6px;background:var(--bg-layer-02);border:0.5px solid var(--border-base);border-radius:var(--radius-sm);color:var(--text-muted);font-size:10px;cursor:pointer;font-family:var(--font-ui)}
.msg-action:hover{color:var(--text-strong);border-color:var(--border-focus)}
.msg-action.danger{color:var(--accent-error)}
```

### meta 增强

assistant 消息 meta 行增加:
```
model · timestamp · 1234↑ 567↓ tokens · interrupted (若中断)
```

数据源: P0 后 API 已返回 `usage` + `model` + `timestamp`。

## 影响范围

| 文件 | 改动 |
|------|------|
| `index.html` | ToolRegistry 6 个空桩 → 实现；done/loadSession 加 ContextToolGroup 包装；消息操作栏 |
| `sse.zig` | `serializeMeta` 补全 read/write/edit/grep/glob/skill 字段 |
| `types.zig` | 无需改动 |

## 验证

- `zig build` 编译
- `--web` 测试各工具类型卡片 + 连续上下文工具分组 + 消息操作
