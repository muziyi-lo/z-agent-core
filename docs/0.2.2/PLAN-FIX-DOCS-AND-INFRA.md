# Plan FIX-1: 文档一致性与基础设施修复

## 状态: 已完成

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 问题

**现象**：`zig build check` 因路径错误 100% 失败；`REMAINING.md` 标记已完成的 PHASE-3/4 为"计划中"；`test.zig` 未导入 `edit.zig`/`compact.zig` 导致测试未被聚合运行；`AGENTS.md` 多处描述与实际不一致。

**根因**：`build.zig` 中 `check-arch.mjs` 脚本路径 `../../.opencode/...` 多了一层 `..`（相对 `z-agent-core/` 应为 `../.opencode/...`）。文档在多次迭代后未同步更新状态和描述。

## 概览

- **改动范围**：8 个文件（1 个编译关键 + 5 个文档 + 1 个测试 + 1 个清理）
- **改动性质**：全部为修正（无新增功能、无架构变更）
- **核心思路**：修复 `build.zig` 中使 `zig build check` 断裂的路径；同步所有文档描述到实际代码状态
- **无参考实现**——纯修正任务

## 不做

- 不为 `compact.zig` 添加测试（需要理解 compact 逻辑和 mock LLM API，超出本次范围）
- 不拆分 God Object 文件（已在 wishlist W1/W2，非本次范围）
- 不修复 99 个空 catch 块（需逐处评估后果，非本次范围）
- 不处理 `render.zig` 未提交的 ANSI reset 修复（由开发者自行决定）

## 设计要点

### 路径修正：一层 `..` vs 两层 `../../`

`build.zig` 位于 `z-agent-core/build.zig`，`.opencode/` 位于 `z-agent-core/../.opencode/`（即项目根目录下）。`addSystemCommand` 以 build root（`z-agent-core/`）为 CWD 执行命令。

| 路径 | 解析结果 | 正确? |
|------|---------|-------|
| `../../.opencode/skills/...` | `C:\VibeCoding\Projects\.opencode\...` | 错误 |
| `../.opencode/skills/...` | `C:\VibeCoding\Projects\zAgentCore\.opencode\...` | 正确 |

**选择**：改用 `../.opencode/...`。同理 `AGENTS.md` 中独立运行命令也需修正。

### test.zig 导入：只加入有测试的文件

`edit.zig` 有 4 个 test block → 加入 `test.zig`。`compact.zig` 无 test block → 不加入（加入空模块无意义，但保留未来添加可能）。

### REMAINING.md 状态更新依据

CHANGELOG v0.2.2 明确列出 PHASE-3 (compat) 和 PHASE-4 (cache) 已实现。REMAINING.md 应同步标记。

## 实施

### 步骤 1: 修复 `build.zig` check-arch 路径

**文件**: `z-agent-core/build.zig`
**改动**: 修正 `check-arch.mjs` 脚本路径 `../../.opencode/...` → `../.opencode/...`

**关键代码**:
```zig
// build.zig:36 — 修正前:
"node", "../../.opencode/skills/zig-dev/scripts/check-arch.mjs",

// 修正后:
"node", "../.opencode/skills/zig-dev/scripts/check-arch.mjs",
```

### 步骤 2: 修复 `AGENTS.md` 路径和行数描述

**文件**: `z-agent-core/../AGENTS.md`
**改动**:
- L44: 架构扫描路径 `../../.opencode/...` → `../.opencode/...`
- L42: `17-line` → `19-line`（或直接移除行数描述避免未来再次过时）

### 步骤 3: 更新 `REMAINING.md` 状态

**文件**: `z-agent-core/docs/REMAINING.md`
**改动**: 将 PHASE-3 和 PHASE-4 从"计划中"状态改为"已完成"，标注完成日期

### 步骤 4: 更新计划文档状态头

**文件**: `docs/PLAN-PHASE-3-COMPAT.md`, `docs/PLAN-PHASE-4-CACHE.md`
**改动**: 状态头从 `状态: 计划中` 改为 `状态: 已完成`

### 步骤 5: 将 `edit.zig` 加入 `test.zig`

**文件**: `z-agent-core/src/test.zig`
**改动**: 在 tool 导入区域添加 `_ = @import("tool/edit.zig");`

### 步骤 6: 清理空目录 `src/crash-test.zig/`

**文件**: `z-agent-core/src/crash-test.zig/` (空目录)
**改动**: 删除空目录

### 步骤 7: 更新 CHANGELOG.md 版本号与测试计数

**文件**: `z-agent-core/CHANGELOG.md`
**改动**:
- 更新 v0.2.2 测试计数为实际数量（需实际运行后填入）

## 验证

```powershell
zig build                           # 编译通过
zig build check                     # 编译 + 架构扫描通过（修复后应成功执行 check-arch.mjs）
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 测试场景 | 预期结果 |
|----------|----------|
| `zig build` | 编译成功，无错误 |
| `zig build check` | 编译成功 + check-arch.mjs 正常执行 |
| `zig test src/test.zig` | 所有测试通过，edit.zig 的 4 个 test 被包含 |
| `zig test src/tool/edit.zig --cache-dir .zig-cache` | edit 的 4 个测试单独通过 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `z-agent-core/build.zig` | 修正脚本路径 | 否（修复断裂功能） |
| `AGENTS.md` | 修正路径 + 行数描述 | 否 |
| `z-agent-core/docs/REMAINING.md` | 标记 PHASE-3/4 完成 | 否 |
| `z-agent-core/docs/PLAN-PHASE-3-COMPAT.md` | 更新状态头 | 否 |
| `z-agent-core/docs/PLAN-PHASE-4-CACHE.md` | 更新状态头 | 否 |
| `z-agent-core/src/test.zig` | 新增 edit.zig 导入 | 否（仅聚合测试） |
| `z-agent-core/src/crash-test.zig/` | 删除空目录 | 否 |
| `z-agent-core/CHANGELOG.md` | 更新测试计数 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| check-arch | 架构红牌扫描脚本 (God Object/双向 import/层违反检测) |
| test.zig | 测试聚合器——通过 `@import` 将各模块的 test block 纳入统一测试运行 |
