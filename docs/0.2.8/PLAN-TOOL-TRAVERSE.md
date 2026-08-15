# Plan TOOL-TRAVERSE: glob 路径前缀 + grep 目录递归

## 状态: 已完成（2026-08-15）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |
| N20（grep 正则引擎） | 已完成 | grep.zig 重构复用 `util/regex.zig` Pattern |

## 问题

用户实测两份缺陷报告（`Test/Documents/issues/`，2026-09-15 标注）——两个独立缺陷，均为工具结果误导/漏报：

### Bug A — glob 返回路径带 `.` 前缀

**现象**：`glob("**/*")` 在默认 `path` 下返回 `.Documents/test/demo-app.py`、`.AGENTS.md` 等，真实路径无 `.` 前缀；返回路径交给 read/grep 直接 FileNotFound。

**根因**：`glob.zig` `walkDir` 拼接逻辑：`path="."`（默认值）时 `prefix="."`，命中 `eql(prefix, ".")` 分支走 `{s}{s}` 直拼 → `"." + "Documents" = ".Documents"`。递归层叠后全链路带 `.` 前缀。不是隐藏文件误报（`Get-ChildItem -Force` 已排除）。

### Bug B — grep 目录搜索不递归

**现象**：`grep` 对目录执行搜索只扫描顶层文件，`Documents/test/demo-app.py`（子目录）漏报 → "No matches" 误导 Agent 判断。

**根因**：`grep.zig` `searchDir` 循环体 `if (entry.kind != .file) continue;`——目录条目直接跳过，无递归逻辑。工具描述 "Supports file and directory search" 隐含递归预期。

## 设计要点

### Bug A（glob 前缀）

顶层拼接规则改为：
- `prefix` 为 `""` 或 `"."` → 直接输出 `entry.name`（无前缀）
- `prefix` 以 `/` 或 `\` 结尾（`src/`）→ 直拼
- 其他 → `{prefix}/{name}`

递归子层 prefix 恒为 full_path（非空、非 `.`），只影响顶层。

### Bug B（grep 递归）

- `searchDir` 编译一次 Pattern，`walkDir` 递归共享状态（buf/matches/truncated/files_scanned/steps）
- `rel_prefix` 跟踪相对路径（顶层 `""`），子目录输出 `sub/nested.txt` 而非裸文件名——保证结果可被 read/edit 直接用
- `*truncated` 兼作停止标志：limit/max-matches/complexity 任一置位后全树 bail out（原单层 `break :outer` 语义升级为跨层停止）
- include 过滤按 `entry.name`（glob 文件名匹配），子目录同样生效
- 目录 openDir 失败（权限等）静默跳过，与 glob.walkDir 一致

## 实施

| 文件 | 改动 |
|------|------|
| `src/tool/glob.zig` | walkDir 拼接首层判定 `eql(prefix, ".")` → 无前缀输出 |
| `src/tool/grep.zig` | searchDir 拆分：外层编译 Pattern + 收尾统计；新增 `walkDir` 递归函数（rel_prefix 相对路径 + truncated 跨层停止） |

测试（+2 条，All 325 tests passed）：
- `glob: dot path yields unprefixed top-level names`：`**/*.zig` path="." 断言无 `.a.zig`/`.sub/b.zig`/`./sub/b.zig`，含 `a.zig`/`sub/b.zig`
- `grep: directory search recurses into subdirs`：`sub/nested.txt`、`sub/deep/leaf.md` 命中且输出相对路径，无匹配顶层文件不误报

## 验证

- `zig test src/test.zig --cache-dir .zig-cache` → All 325 tests passed
- 缺陷报告 7 个 grep 用例语义覆盖：子目录命中（有/无 include）、顶层命中、直接子目录搜索等
