# Plan GLOB-DOUBLE-STAR: glob 工具 `**` 递归匹配修复

## 状态: ✅ 已完成（2026-08-14，由 PLAN-P0-FIXES 的 N13 实施，方案细节并入该计划）

## 问题

**现象**：模型发起 `glob` 调用（如 `pattern: "**/*", path: "C:\VibeCoding\Projects\Test"`）时返回 `No files matched`，即使目录下存在多个文件。

**根因**（已通过代码走查确认）：
1. `src/tool/glob.zig` `walkDir` 正确递归遍历所有层级目录（行 107-115）
2. 但每层对单个 entry 名（如 `AGENTS.md`）调用 `globMatch(entry.name, pattern)`（行 101）
3. `globMatch` 对 `**/*` 模式的匹配逻辑有缺陷：pattern 含 `/`（`**/` 部分），而单层文件名（`AGENTS.md`）无 `/` → 匹配永远返回 false（已手工推演验证）
4. 现有测试只覆盖"按扩展名"（`*.md`）和"无匹配"两种情况，**未覆盖 `**/*`**，故 bug 未被发现

## 概览

- 改动文件：`src/tool/glob.zig`（globMatch 或 walkDir 匹配逻辑）+ `src/tool/glob.zig` 测试
- 核心层改动（tool/），与前端改造（PLAN-DEEPSEEK-STYLE）独立
- 思路：`**/*` 应匹配递归遍历中的任意条目。修复 globMatch 的 `**` 语义或调整 walkDir 匹配条件
- 优先级：高（工具结果错误，影响 agent 对文件系统的认知）

## 设计要点

### 方案 A：修 globMatch 支持 `**` 前缀（推荐）

在 `globMatch` 开头识别 `**/` 模式：

```zig
fn globMatch(name: []const u8, pattern: []const u8) bool {
    // **/ prefix: match at any depth (walkDir already recurses, so any name matches)
    if (std.mem.startsWith(u8, pattern, "**/")) {
        // If pattern is exactly "**/*" or "**/" + rest, match any name (walkDir recursion handles depth)
        return true;
    }
    // ... 现有逻辑
}
```

**注意**：`**/*` 在 walkDir 递归下，每个 entry 都已位于任意深度，所以 `**/` 前缀匹配 = 所有 entry 都匹配。但需考虑：
- `**/*.md`（递归所有 .md）应匹配 `rest = "*.md"`，不能简单 return true
- 正确逻辑：`**/` 之后的 pattern 部分对 entry.name 做普通 globMatch

### 方案 B：改 walkDir 匹配条件

walkDir 层面处理：当 pattern 含 `**/` 时，`globMatch` 改为匹配 `pattern[3..]`（去 `**/` 前缀）：

```zig
if (globMatch(entry.name, if (std.mem.startsWith(u8, pattern, "**/")) pattern[3..] else pattern)) {
```

### 方案对比

| 方案 | 改动 | 覆盖 `**/*.md` | 测试 |
|------|------|---------------|------|
| A（globMatch 内） | 集中修匹配 | ✅ 需处理 rest | 加测试 |
| B（walkDir 处） | 调用点修 | ✅ 自然 | 加测试 |

推荐 **方案 B**（改动最小，语义清晰：`**/` 前缀在递归遍历下等价于"当前深度匹配 rest"）。

### 测试

新增测试：
- `glob: recursive **/* finds files in nested dirs`：创建嵌套目录结构，验证 `**/*` 递归列出
- `glob: **/*.md matches md at any depth`：验证递归扩展名匹配
- 现有测试保持通过

## 涉及文件

| 文件 | 改动 |
|------|------|
| `src/tool/glob.zig` | walkDir 匹配条件支持 `**/` 前缀（方案 B）+ 新增测试 |

核心层改动，不影响前端。

## 验证

1. **L0 静态**：`zig test src/tool/glob.zig --cache-dir .zig-cache` 全绿（含新增测试）
2. **L1 回归**：`zig test src/test.zig --cache-dir .zig-cache` 全绿
3. **L2 功能**：真实调用 glob `**/*` 验证 Test 目录文件被列出

## 风险

| 风险 | 缓解 |
|------|------|
| `**/` 其他组合语义（如 `**/foo`） | 方案 B 只处理前缀，rest 走普通匹配，语义正确 |
| walkDir 递归 + 前缀匹配的边界 | 新增嵌套目录测试覆盖 |
