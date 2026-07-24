# Plan FIX-2: build.zig 与 opencode 技能脚本解耦

## 状态: 已完成

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 问题

**现象**：`zig build check` 硬依赖 `.opencode/skills/zig-dev/scripts/check-arch.mjs`——一个 Node.js 脚本，存放在平台私有目录中。不用 opencode 的用户 `zig build check` 直接失败。此外，`zig build check` 自身编译通过但 exit 1（`--fail-on-any` 阻断），模糊了"构建成功"的语义。

**根因**：zig-dev skill 的 `project-layout.md` 和 `setup.md` 提供了错误的模板——教用户把架构 lint 脚本嵌入 Zig 构建系统。三个职责被混入一个命令：

| 职责 | 应由谁做 | 当前在 build.zig 中？ |
|------|---------|---------------------|
| 编译检查 | `zig build` | ✅ 合理 |
| 测试 | `zig test` | ✅ 合理 |
| 架构规范检查（God Object/双向依赖） | 独立 lint 命令 或 skill 工作流 | ❌ 错位 |

zig-dev skill 本身已在工作流阶段 0/4/5 定义了运行架构扫描的时机，`build.zig` 中是多余的副本。

## 概览

- **改动范围**：8 个文件（`build.zig` + 7 个 `.md`）
- **改动性质**：从 `build.zig` 删除 `check` 和 `test` step（两者均为死代码）；清理由此产生的文档引用
- **核心思路**：`zig build` = 编译，`zig build run` = 编译+运行。不再有 `check` 或 `test` step。架构扫描由 skill 工作流或手动执行

## 不做

- 不删除或修改 `check-arch.mjs`、`check-catch-silent.mjs`、`depgraph.mjs` 脚本本身
- 不修改 `.archived/`、`0.0.1-alpha/`、`0.2.0/` 下的历史文档（保留当时的设计记录）
- 不修改 `docs/PLAN-FIX-DOCS-AND-INFRA.md`（上次修复记录）

## 设计要点

### 删除 `check` 和 `test` step 的理据

`zig build` 本身就是"编译不运行"。去掉架构扫描后，`zig build check` 和 `zig build` 做完全相同的事——同义别名，无独立价值，反而造成困惑（"check 是不是比 build 检查更多？"）。

`zig build test` 已被 AGENTS.md 明确禁止使用（GPA 泄漏栈回溯撑爆 64KB stderr 管道）。

两个 step 都是死代码，一并删除。

架构扫描改为独立命令：

```powershell
node ../.opencode/skills/zig-dev/scripts/check-arch.mjs .
```

skill 工作流中的调用不变——AI 在阶段 0/4/5 仍主动运行。

## 实施

### 步骤 1: 精简 `build.zig`——删除 check 和 test step

**文件**: `z-agent-core/build.zig`
**改动**: 删除 `check_arch` 变量、`check_step`、`test_module`、`test_runner`、`test_step`。只保留 `exe` + `run` step。

当前（60 行）:
```zig
// 行 34-43: check_arch + check_step
// 行 45-59: test_module + test_runner + test_step
```

修正后（~30 行）:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version_str = b.option([]const u8, "version", "Override version string") orelse "0.2.1";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_str);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "z-agent-core",
        .root_module = root_module,
        .version = std.SemanticVersion.parse(version_str) catch @panic("bad version"),
    });

    exe.root_module.addWin32ResourceFile(.{ .file = b.path("src/Logo.rc") });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

### 步骤 2: 更新 `README.md`

**文件**: `z-agent-core/README.md`
**改动**: L18 删除 `zig build check` 行；L23-25 测试说明中移除 `zig build test` 提及

```diff
- zig build check                       # compile + architecture scan
+ # (architecture scan: node ../.opencode/skills/zig-dev/scripts/check-arch.mjs .)
```

### 步骤 3: 更新 `AGENTS.md`

**文件**: `AGENTS.md`
**改动**:
- L22-27 Dev commands 节移除 `zig build check` 行
- L44 架构扫描命令独立列为手动命令（移除 `zig build check` 上下文）

### 步骤 4: 更新 skill `project-layout.md`

**文件**: `.opencode/skills/zig-dev/references/project-layout.md`
**改动**: 删除 §"build.zig 集成" 整节（L27-44），替换为一句说明：架构检查通过独立命令运行，不嵌入构建系统

### 步骤 5: 更新 skill `setup.md`

**文件**: `.opencode/skills/zig-dev/setup.md`
**改动**: 删除 §"架构集成" 整节（L52-67）

### 步骤 6: 更新 skill `SKILL.md`

**文件**: `.opencode/skills/zig-dev/SKILL.md`
**改动**: 
- L28 移除 `check-arch.mjs` 集成到 `zig build check` 的描述
- L32-35 删除引用 `zig build check` 的行
- L352 文件表中 `project-layout.md` 的描述移除 "build.zig check step 集成"
- 架构扫描命令保持独立引用（阶段 0/4/5/新项目启动中使用）

### 步骤 7: 更新 skill `references/test-pattern.md`

**文件**: `.opencode/skills/zig-dev/references/test-pattern.md`
**改动**: L95 移除对 `zig build test` 的引用（该 step 已从 build.zig 删除）

## 验证

```powershell
zig build                           # 编译通过
zig build run                       # REPL 正常启动
zig build -Drelease-safe            # release 编译通过

# 架构扫描（独立命令，需 Node.js）
node ../.opencode/skills/zig-dev/scripts/check-arch.mjs .
```

| 测试场景 | 预期结果 |
|----------|----------|
| `zig build` | 编译成功 |
| `zig build run` | REPL 启动正常 |
| `zig build -Drelease-safe` | release 编译成功 |
| 无 Node.js 环境 `zig build` | 编译成功（不再依赖 Node） |
| `zig build check` | 错误：未知 step（该命令已删除） |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `z-agent-core/build.zig` | 删除 check_arch 集成、check step、test step（60 行 → ~30 行） | 是（`zig build check` 和 `zig build test` 不再可用） |
| `z-agent-core/README.md` | 更新 check 命令描述 | 否 |
| `AGENTS.md` | 更新 check 命令描述 | 否 |
| `.opencode/skills/zig-dev/references/project-layout.md` | 删除架构集成节 | 否 |
| `.opencode/skills/zig-dev/setup.md` | 删除架构集成节 | 否 |
| `.opencode/skills/zig-dev/SKILL.md` | 更新 check 描述 + 文件表 | 否 |
| `.opencode/skills/zig-dev/references/test-pattern.md` | 移除 zig build test 引用 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| check step | `zig build` 中的一个命名步骤，可被 `zig build check` 调用 |
| 架构扫描 | 检测 God Object、双向依赖、层违反等反模式的静态分析 |
