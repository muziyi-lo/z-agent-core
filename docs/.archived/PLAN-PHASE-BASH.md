# Plan PHASE-BASH: Bash 工具增强

## 状态: 计划中

## 问题

bash 工具实现过于简陋——对比 OpenCode V2/V1，缺少超时保护、中止机制、输出管理、错误格式化等关键功能。

### 当前状态（bash.zig:174 行）

```
execute(command)
  └─ std.process.run(pwsh | sh)
       ├─ stdout → 512KB 硬截断
       ├─ stderr → [stderr]\n 文本标记
       ├─ exit code → [exit code: N]
       └─ ANSI strip ✓ (PHASE-4)
```

### 缺口（对比 OpenCode bash.ts / shell.ts）

| 功能 | OpenCode | z-agent-core |
|------|----------|------------|
| 超时 | 默认 2min，可配置 | ❌ |
| 中止 | 信号 + kill 子进程 | ❌ |
| 截断 + 存储 | 预览 + 完整输出保存文件 | ❌ 硬截断 |
| workdir | 可选参数 | ❌ |
| shell 类型 | 自动检测 | ❌ |
| 空输出 | `"(no output)"` | 空字符串 |
| exit code 格式 | `"Command exited with code {N}."` | `[exit code: N]` |
| stderr 格式 | 合并 `stderr:\n{content}` | `[stderr]\n` |

## 延期项

### 流式输出

需要改动 tool 契约（`execute() → 注册回调 → 异步推送`）+ agent loop + ToolDisplay 三层。单独延期。

## 方案

### 1. 超时 + 中止

Zig 0.16 `std.process.run` 不支持超时。改用 `std.process.spawn` + 轮询循环（避免线程同步）：

```zig
var child = try std.process.spawn(io, .{
    .argv = &args,
    .stdin = .inherit,
    .stdout = .pipe,
    .stderr = .pipe,
});
defer { if (!finished) { child.kill(io) catch {}; _ = child.wait(io) catch {}; } }
var finished = false;

const deadline = now + timeout;
var out_buf = std.ArrayListAligned(u8, null).empty;
var err_buf = std.ArrayListAligned(u8, null).empty;

while (true) {
    // 1. 信号中断
    if (signal.isInterrupted()) {
        child.kill(io) catch {};
        finished = true;
        _ = child.wait(io) catch {};
        return abort;
    }
    // 2. 超时
    if (now > deadline) {
        child.kill(io) catch {};
        finished = true;
        _ = child.wait(io) catch {};
        return timeout;
    }
    // 3. 读取输出（非阻塞，每次 4096 字节）
    if (try readPipe(stdout_pipe, &out_buf, alloc)) |_| {}
    if (try readPipe(stderr_pipe, &err_buf, alloc)) |_| {}
    // 4. OOM 保护 — 读满即停
    if (out_buf.items.len >= MAX_OUTPUT_BYTES) {
        child.kill(io) catch {};
        finished = true;
        _ = child.wait(io) catch {};
        truncated = true;
        break;
    }
    // 5. 进程已退出
    if (try childHasExited(child)) {
        finished = true;
        break;
    }
    // 100ms 轮询间隔
    kernel32.Sleep(100);  // Windows
    // std.c.nanosleep(...) // POSIX
}
const term = child.wait(io); // 获取退出码
```

**关键约束**：
- `child.kill(io)` 在 Windows 上对已退出子进程 → `INVALID_HANDLE` panic。`finished` 标志 + `catch {}` 守卫，且 kill 后立即 `break` 不再调。
- 两处 `catch {}` 理由：kill/wait 失败意味着子进程已退出（竞态），忽略即可。

默认超时：2 分钟。通过 `timeout` 参数可配置（最大 10 分钟）。

### 2. 截断 + 文件存储

参考 OpenCode truncate.ts 模式：

| 参数 | 默认值 |
|------|--------|
| `MAX_OUTPUT_BYTES` | 512KB（与当前一致） |
| `MAX_LINES` | 2000 |
| `USER_OUTPUT_BYTES` | 4096（会话回传） |

```
execute()
  ├─ stdout 累积到内存 (≤MAX_OUTPUT_BYTES)
  ├─ 超限时:
  │   ├─ 完整输出写入 .zagent/tmp/bash-{timestamp}.txt
  │   ├─ 截断预览: 头 1000 行 + "... output truncated ..." + 尾 1000 行
  │   └─ 提示: "Full output saved to: {path}"
  └─ 输出传递给 user_output（截断至 USER_OUTPUT_BYTES）
```

### 3. 错误格式化

```zig
// 空输出
if (total == 0) return "(no output)"

// stderr 合并
"stderr:\n{content}\n"  // ← 注意：换行分隔，不是裸 [stderr]

// exit code
"Command exited with code {N}."      // exit 0 → 不显示
"Command timed out after {N}s."      // 超时
"Command aborted by user."           // Ctrl+C
```

### 4. workdir 参数

```json
{"command": "ls", "workdir": "/path/to/dir", "timeout": 30}
```

`workdir` 为可选字段。未提供时使用当前 CWD。

### 5. shell 自动检测

```zig
fn detectShell(os: std.Target.Os.Tag) Shell {
    return switch (os) {
        .windows => {
            // 检查 pwsh.exe 是否可用
            if (canExecute("pwsh.exe")) return .pwsh;
            if (canExecute("powershell.exe")) return .powershell;
            return .cmd;
        },
        else => .bash,
    };
}
```

每种 shell 使用对应参数：
- pwsh: `-NoProfile -Command`
- powershell: `-NoLogo -NoProfile -Command`
- cmd: `/C`
- bash: `-c`

---

## 改动文件

| 文件 | 改动 |
|------|------|
| `src/tool/bash.zig` | execute() 重写：spawn + 超时 + 文件存储 + 格式化 |
| `src/util/shell.zig` | 新增：shell 检测、ANSI strip |
| `src/tool/registry.zig` | tool_params 更新：新增 workdir/timeout |

## 验证

```powershell
zig build -Drelease-safe
zig test src/tool/bash.zig --cache-dir .zig-cache
```

| 场景 | 预期 |
|------|------|
| `echo hello` | stdout: "hello\n", exit 0 |
| 空命令 | stdout: "(no output)" |
| 不存在的命令 | stderr + `Command exited with code 1.` |
| `sleep 300` (超时) | `Command timed out after 120s.` |
| Ctrl+C 中断 | `Command aborted by user.` |
| 大文件 `type big.log` (>512KB) | 预览 + `Full output saved to: .zagent/tmp/...` |
| `--workdir /tmp ls` | 在指定目录执行 |

## 术语

| 术语 | 含义 |
|------|------|
| watchdog | 超时监控线程，超时后 kill 子进程 |
| managed storage | 截断后的完整输出保存到 .zagent/tmp/ |
| user_output | 截断至 4KB 的预览，回传给 LLM 上下文 |

## 实施顺序

```
步骤 1 (util/shell.zig):  新建 — shell 检测 + ANSI strip 迁移
步骤 2 (tool/bash.zig):   execute() 重写 — spawn + 超时 + 文件存储 + 格式化
步骤 3 (tool/registry.zig): tool_params 更新
```
