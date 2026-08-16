# Plan N16-APPROVAL-PREVIEW: 工具审批 + 文件预览

## 状态: ✅ 已实施（2026-08-16，N16）

## 实施偏差记录

- `sse.zig serializeMeta` 的 read/edit 分支补 `path` 字段——实施表未列（Preview 按钮的 path 数据源：tool_meta 事件此前只发数值，方案假设 meta.path 存在但源码验证不成立）
- Web 端 SystemPromptCb 注入点：server.zig `AgentLoop.init` 后置 `agent.system_prompt`（handler.zig `approvalSystemPrompt` 前缀幂等扫描）——实施表 server.zig 行已补
- `approval.zig` 原子状态用 `std.atomic.Value(u8)`（extern struct 不能含 enum 字段，Zig 0.16 限制）
- `mkfs.*` 前缀变体加入存储破坏规则（`mkfs.ext4`/`mkfs.vfat`——封闭清单的 mkfs 前缀扩展，宁误不漏）
- Gate 时钟统一 `.real`（方案原"单调时钟"——项目无 `.mono` 先例，见设计要点惰性清理节）
- CLI REPL 模式同样注入 policyNotice（方案只提 single-shot 的 SystemPromptCb；REPL 复用 spRebuild 前缀幂等）

## 前置依赖

| 阻塞者 | 状态 | 说明 |
|--------|------|------|
| 无 | — | REMAINING N16 自 P1。diff 高亮已由 N12（TOOL-CARD-TYPED）覆盖，本期做剩余两件 |

## 需求

REMAINING.md N16（P1，PARTS"高价值三件"剩余两件）：

1. **工具审批**：危险命令执行前确认（ApprovalModal，opencode 参考）
2. **文件/图片预览**：工具结果内联渲染（读文件/看图）

## 设计要点

### Part A — 工具审批

**拦截点**：`ToolHooks.before`（agent.zig:55-59、374-386）——返回非 null 阻止执行并 append tool 消息。审批 = hook 内阻塞等待用户决策。

**同步原语**：`Gate` 原子状态轮询（100ms），复用 abort 模式（agent.zig:98-113 原子标志 + `signal.setInterrupted()`）。**不用 `Io.Condition`**（依赖 io 事件循环，Web server 请求线程是普通 thread）。sleep 用 subcall.zig:63-65 先例（Win `kernel32.Sleep` / POSIX `std.c.nanosleep`）。

**新模块 `src/approval.zig`**（core 层，不 import frontends）：

```zig
pub const Mode = enum { never, risky, always };   // config approval_mode
pub const GateState = enum { pending, approved, denied, aborted };
pub const Gate = struct {
    state: std.atomic.Value(GateState),
    /// 轮询等待决议。check_abort 置位 → aborted；keepalive 每 ~1s 调用一次
    /// （返回 false = SSE 连接已断）→ aborted；reminder 在 timeout/2 处调用
    /// 一次（发 SSE approval_reminder）；timeout 超时 → denied。
    pub fn wait(self: *Gate, timeout_ms: u32, check_abort: *const fn () bool, keepalive: ?*const fn () bool, reminder: ?*const fn () bool) GateState;
    pub fn resolve(self: *Gate, allow: bool) bool;  // 返回 true=从 pending 转变（真正决议），false=已终态（幂等 no-op）
};
pub fn isRisky(mode: Mode, name: []const u8, args: []const u8) ?[]const u8; // 返回规则说明或 null
    // 审查补充：`mode==.always` 时不做规则匹配，直接返回固定说明文本 `"all tool calls require approval (approval_mode=always)"`——approval_required 的 rule 字段就是该文本，前端 Modal 显示“全部工具审批”；`never` 返回 null；`risky` 按 L0/L1 规则返回具体规则说明
```

- `isRisky` 规则集——**两级分级**（审查修订：原"宁可漏报不可误报"一刀切与"默认开启、用户可关"定位冲突——误报是用户关掉审批（never）的主因，漏报反而不流失用户；改为按后果分级 + 摩擦自愈，见下）。**匹配算法定稿**（审查补充：变体覆盖需可测，如 `rm -fr`/`rm --recursive --force`/PS 前缀简写 `-Fo`）：
  - **分词**：`args.command` 按空白 split 成 token 数组（去首尾引号；不处理嵌套引号——命令内的引号串整体成一个 token，匹配目标不在引号内，无歧义）
  - **标志匹配 helper**（大小写不敏感，token 级前缀/包含判定）：
    - `isShortFlagGroup(tok)`: tok 以 `-` 开头且不以 `--` 开头且长度 >1（`-rf`/`-R`/`-Fo`）
    - `hasRecursive(tok)`: isShortFlagGroup 且组内含 `r`；或 **精确等于** `--recursive`/`-recursive`（PS 长名）——审查修订：长选项禁前缀匹配（`--recursive-submodules` 等是不同语义）；或 tok ∈ {`/s`,`/S`}（cmd）
    - `hasForce(tok)`: isShortFlagGroup 且组内含 `f`；或 **精确等于** `--force`/`-force`（PS）——审查修订：`git push --force-with-lease`/`--force-if-includes` 是更安全/不同语义选项，禁前缀误命中；或 tok ∈ {`/q`,`/Q`}（cmd）
  - **规则**（token 数组上判定）：
    - **L0 可疑语法（动态执行信号，审查补充）**：`args.command` 含 `$(`、反号、`${` 任一，或 **分号/`&&`/`||` 后命令位置 token 以 `$` 开头**（审查修订：`cmd=rm; $cmd -rf /tmp/x` 直接变量间接执行——首 token 是赋值不是命令，三信号不命中；“分号后 `$` 开头 token” = 变量当命令执行，极罕但危险；`x=1; echo $x` 分号后是字面命令不命中）——模式“补强边界”：词法扫描无法覆盖变量间接执行/命令替换/反号，对“无法确认安全”的语法改用 **fail-closed 措施：risky/以上下遇 L0 信号即审批（升级为 always 语义），不依赖 L1 具体规则命中——`rm -rf $(pwd)/x`/`eval $(cat x)`/`git clean -fdx $(list)`/`dd if=`which dd` of=/dev/sdb` 全审批。摩擦说明：含变量插值的常见命令（`ls ${DIR}`）也会走审批——用户可通过 `approval_allow` 精确免费（白名单优先级最高）；shell 解析器（tree-sitter-bash 类）在 Zig 单二进制约束下不可行，这是可接受的边界补强。
    - **首命令归一化 `firstCommand(tokens)`（审查修订：原“首 token 命中”被 `sudo rm -rf /`/`/bin/rm -rf /` 等前缀绕过——高风险假阴性）：跳过 0-N 个包装词（`sudo`/`env`/`nice`/`exec`/`command`，包装词自身支持绝对路径 `/usr/bin/env`）+ sudo 变体（`sudo -u <user>` 跳过选项及参数值）+ env 变量赋值（`VAR=value` 跳过）+ 命令名去绝对路径前缀（`/bin/rm`→`rm`、`/usr/bin/git`→`git`）→ 返回规范化后的命令名。“首 token 命中”规则（rm 族/存储破坏/系统破坏/git 族）全部改用 firstCommand。
    - **rm 族**（L1）：firstCommand ∈ {`rm`,`del`,`rmdir`,`erase`,`remove-item`}（去引号）AND ∃ recursive 标志 token——`rm -rf`/`rm -fr`/`rm -r -f`/`rm --recursive --force`/`rm -rF`/PS `Remove-Item -Recurse -Force`/`-R -Fo`/cmd `rmdir /s /q`/`del /s /q` 全命中；**`rm <file>`（无 recursive）不命中**
    - **git 族**（L1）：firstCommand==`git` + `push` 且 ∃ force 标志（`--force`/`-f`——`git push -f` 即 force）；`git`+`reset` 且 ∃ `--hard` 前缀；`git`+`clean` 且 ∃ **force 标志**（审查修订：原规则仅 `-fdx`/`--force` 漏掉 `-f`/`-fd`/`-fx`/`-dfx` 变体——`git clean` 无 force 时是 dry-run 仅显示，**任何 force 标志（hasForce helper：短组含 f 或 **精确等于** `--force`，审查修订：原“前缀”与 hasForce 定义不一致，按精确等于实现）都会实际删除未跟踪文件**，`-d`/`-x` 只是范围扩展非破坏点）——`git clean -f`/`-fd`/`-fx`/`-fdx`/`-dfx`/`--force` 全命中；`git clean -n`/`-d`（无 force，dry-run）不命中；`git push`（无 force）不命中
    - **管道执行**（L1）：**引号感知字节扫描**（审查修订：原 `tokens[i]=="|"` 空白分词可被 `curl url|sh` 绕过——shell 语法 `|` 两侧无需空格，`|` 不会成为独立 token）：扫描原始 `args.command` 字节，跳过 `'...'`/`"..."` 引号段（防 `echo "a|sh"` 误报），遇 `|` 后跳过空白，**尝试解析后续命令 token 序列**：允许 0-N 个包装词（`sudo`/`env`/`nice`/`exec`/`command`，包装词支持绝对路径 `usr/bin/env`）——sudo 后跳过选项及参数值（`sudo -u user`）、env 后跳过变量赋值（`VAR=1`）——目标命令去路径前缀（`/bin/`）且边界后跟符合（空白/`;`/`&`/`|`/行尾）且 ∈ {`sh`,`bash`,`dash`}——`curl x | sudo sh`/`curl x | /bin/sh`/`curl x | env bash` 全命中（审查修订：原规则漏包装词与绝对路径变体）（后随空白/`;`/`&`/`|`/行尾，防 `|shell` 前缀误报）——`curl https://x|sh`/`curl "url"|bash`/`curl x | sh -c '...'`/`wget x|sh`/`ls | sh`/`cat file | bash` 全命中（审查补充：管道规则实际扫描任意命令而非仅 curl，这是有意扩大——任意命令管道到 sh/bash 都执行脚本，属“宁误不漏”范畴）；`curl https://x`（无管道）/`echo "a|sh"`（引号内）/`ls | grep sh`（非 sh 命令）/`echo | shell`（前缀误报防护）不命中
    - **设备/存储破坏**（L1，审查修订：原清单仅 format/diskpart/fdisk/mkfs/dd/chkdsk——遗漏 shred/wipefs/LVM/cryptsetup/parted 等常见破坏命令，默认 risky 下用户会产生错误安全感；**扩充为封闭成员清单**）：firstCommand ∈ {`format`,`diskpart`,`fdisk`,`sfdisk`,`gdisk`,`parted`,`mkfs`,`mkswap`,`swapoff`,`shred`,`wipefs`,`pvcreate`,`pvremove`,`vgremove`,`lvremove`,`lvreduce`）；**`dd` 且 ∃ `of=` 参数指向 `/dev/` 路径（审查修订：`dd if=x of=backup.img` 备份不应触发审批，写设备才是破坏性操作）；`cryptsetup` 且 tokens[1] ∈ {`luksFormat`,`luksErase`,`erase`}；`chkdsk` 且 ∃ `/f`；**系统破坏子命令定稿**（审查修订：原正文未定义）：firstCommand ∈ {`reg`,`sc`,`net`} 且 tokens[1] ∈ 子命令集（`reg`：{`delete`,`del`}；`sc`：{`delete`,`config`}；`net`：{`user`,`localgroup`}），详见下文：`reg` 且 tokens[1] ∈ {`delete`,`del`}（`reg delete HKLM\...` 命中）；`sc` 且 tokens[1] ∈ {`delete`,`config`}（`sc delete` 命中）；`net` 且 tokens[1] ∈ {`user`,`localgroup`}（`net user` 命中）
  - **L1 覆盖类别 → 成员清单（封闭枚举，可审计）**（审查补充）：
    | 类别 | 成员（firstCommand 命中，大小写不敏感） |
    |------|------------------------------------|
    | 递归删除 | `rm`(+recursive)、`del`(+/s)、`rmdir`(+/s)、`erase`(+recursive)、`remove-item`(+Recurse) |
    | 存储/设备破坏 | `format`、`diskpart`、`fdisk`、`sfdisk`、`gdisk`、`parted`、`mkfs`、`mkswap`、`swapoff`、`shred`、`wipefs`、`pvcreate`、`pvremove`、`vgremove`、`lvremove`、`lvreduce`、`dd`、`cryptsetup`(luksFormat/luksErase/erase) |
    | 系统破坏 | `chkdsk`(+/f)、`reg`(+delete)、`sc`(+delete)、`net`(+user) |
    | Git 破坏 | `git push`(+force)、`git reset`(+--hard)、`git clean`(+force) |
    | 管道执行 | `|`+`sh`/`bash`（**任意命令**，引号感知字节扫描 + 包装词/absolute 路径） |
    - **成员清单更新机制**（审查补充）：新命令加入 = `isRisky` 集中函数加条目 + 测试矩阵补命中用例——**规则集是活清单，随版本扩充**；REMAINING 登记"L1 规则集审计"随版本周期评估（对齐 F14 魔法值审查模式）；配置模板注释注明"覆盖清单见 `docs/0.2.8/PLAN-N16-APPROVAL-PREVIEW.md` 类别表，版本更新会扩展"——防用户错误安全感
  - **L1 覆盖优先（宁误不漏）**，用户对"删除/格式化被拦"接受度高；**L2 歧义类不审**（`rm <file>` 无 `-r`、`git push` 无 force、`Remove-Item` 无 `-Recurse`）——漏报可接受，误报高摩擦
- **摩擦自愈机制**（审查修订）：分级之外，双机制降低重复摩擦：
  - **回合内允许缓存**：`ApprovalCtx` 持 `allowed: StringHashMap(void)`，key = **name + 完整 args 字节串的 Wyhash（64-bit）**——**必须哈希完整参数字符串，禁止模板化/参数剥离**（审查补充：`rm -rf dir_A` 与 `rm -rf dir_B` 的 args 不同 → hash 必不同 → **各自独立弹窗**，不存在"命令模板命中导致过度放行"；仅当完全相同的 name+args 重复时才免弹，语义 = "同一精确命令已获用户认可，不重复打扰"）。碰撞风险：单回合调用数 ≤ 数十个，64-bit Wyhash 碰撞可忽略；若需绝对严谨可存 args 字节串做二次比较（不采纳，YAGNI）
  - **每次确认开关**（审查补充）：`approval_cache = true`（默认开，配置项）——关闭后**同一命令每次执行都弹窗**，满足"每次递归删除都要确认"的严格用户；默认开保持低摩擦
    - **配置白名单**（审查修订：原“字符串含匹配”过宽——`-extra` 尾缀/`&&` 尾追加均能绕过，改为**归一化整命令精确匹配**）：`approval_allow = ["rm -rf .zig-cache", "git push --force origin dev"]`——`args.command` 归一化后（**trim + 内部空白折叠为单空格 + 大小写敏感**，引号不做等价归并）与条目**完全相等**才豁免。命中：`rm -rf .zig-cache`/`rm -rf  .zig-cache`（空白折叠）；**不命中**：`RM -RF .ZIG-CACHE`（大小写敏感——POSIX 路径/命令区分大小写，折叠会过度放行 `.cache`≠`.CACHE`）/`rm -rf .zig-cache-extra`/`rm -rf .zig-cache && rm -rf /`/`rm -rf ./.zig-cache`/`rm -rf .zig-cache/`（**无路径规范化：`./` 前缀与尾斜杠不折叠**——不匹配=弹窗（安全方向），用户可配多条覆盖）
  - **模板匹配评估登记**（审查回应）：当前精确匹配比“词边界”更严格（`-extra` 尾缀/`&&` 尾追加均不免费）；`rm -rf {path}` 模板匹配是**放松方向**（一条模板免费一类命令），引入新风险——`{path}` 模板会免费 `rm -rf /`/`rm -rf .` 等任意路径，与“信任这条精确命令”语义冲突。**本期不做，登记 future**：用户强需求时评估，需配套模板校验（路径占位符禁 `/`/`.`/`..`、命令名白名单等）
- `Mode` 语义：`never`=不审批；`risky`=仅 L1 破坏性命令；`always`=全部 9 工具。**默认 `risky`**（功能定位；用户可配 `never` 关闭）
- **risky 覆盖边界声明**（审查补充：默认开启的模式必须让用户知道保护范围）：
  - **封闭规则集**：risky 模式只对 L1 枚举规则命中时审批，**且仅作用于 bash 工具**——其余 8 工具（write/edit/read/grep/glob/skill/compact/webfetch）在 risky 模式**永不审批**（覆盖文件/批量编辑等留待后续评估，future）
  - **L1 覆盖类别**（完整成员见下方"类别→成员清单"表）：递归删除、存储/设备破坏（含 LVM/擦除/分区/加密卷，审查扩充）、系统破坏、Git 破坏、管道执行
  - **不覆盖类别**（明确排除，未来扩展）：网络攻击类（nmap/masscan）、容器清理类（docker system prune -a）、密钥/数据导出类（gpg --export、mysqldump 全库）、数据外传类（curl -T/rsync 到远程）等——新增规则 = 在 `isRisky` 集中函数加匹配条件（单一入口，扩展成本低）
  - 用户应知悉：risky 是"枚举类别护栏"而非"全量危险拦截"；`always` 模式覆盖所有工具执行
- `wait` 超时：**分级 120s/240s**（审查修订：单阈值 120s 直接拒绝会误伤走神用户——长对话中用户可能暂离/分心，先提醒后拒绝体验更好；可行性高已采纳）：
  - `0–120s`：正常等待
  - `120s`：触发一次 `reminder` 回调（发 SSE `approval_reminder` `{"id"}`，前端 Modal 提示"仍在等待审批"；写失败 = 断连 → 同 keepalive 语义返回 false → aborted）
  - `240s`：仍未决议 → denied（超时自动拒绝，非用户决策，措辞见三态表）
  - `Gate.wait` 签名：`wait(timeout_ms, check_abort, keepalive, reminder)`——reminder 在 timeout/2 处调用一次（timeout_ms=240_000 时即 120s），可空
- **SSE 断连生命周期**（审查补充）：审批等待期间连接无写入，断连（关页面/网络中断）无法被写失败路径感知 → 会挂到超时。修复：`wait` 的 `keepalive` 回调每 ~1s 写一次 SSE 注释帧（`: keepalive\r\n\r\n`，复用 SseWriter 函数指针包装），**写失败 = 连接不可写**（审查修订：TCP 半开时写可能短暂成功——缓冲区接受后才报错，因此“写失败 = TCP 已断”过于绝对；keepalive 是**最快失败检测**，TCP 半开/中间缓冲场景由 240s 超时兜底） → 回调返回 false → `wait` 立即返回 aborted。hook 收到 aborted 后调 `agent.abort()`（同 sse.zig 现有"写失败→abort"语义，agent.zig:109）终止整个回合（SSE 已断，结果无法送达，继续无意义）→ runTurn 走 interrupted 收尾。副作用：心跳同时防止代理超时关闭空闲 SSE 连接。**为何不监听连接关闭事件**（审查追问）：单请求线程模型下连接线程被 `wait` 阻塞，无法 select 读端检测 EOF；写探测（keepalive）是该模型下唯一可靠且非侵入的断连检测，且复用现有 SseWriter 无新机制
- **approval_map 惰性清理**（审查补充）：gate 记录 `registered_at`（**实时钟 `.real`**——源码验证：项目时钟统一 `Io.Clock.Timestamp.now(io, .real)`（subcall.zig:56/session.zig:269/agent.zig:517），`.mono` 无先例；惰性清理比较同为 `.real` 相同时钟域，墙钟跳变仅影响清理时机不影响正确性，偏差记录）。正常路径 `wait` 返回后立即移除；异常路径可能残留——**每次插入新 gate 前扫描 map 中 `registered_at` 已超时（≥240s+10s 缓冲）的条目，主动 `resolve(denied)` + 移除**（幂等，残留 wait 线程唤醒后发现状态非 pending 即返回）。**map 规模 = 并发活跃 SSE 流数（每连接至多一个 pending，多连接并存）**（审查修订：原"常驻 0-1 个条目"是单 agent 视角、与并发模型节矛盾——进程级实际为活跃流数量，扫描 O(活跃流数) 仍可忽略，不引入后台线程）
  - **残留窗口评估**（审查补充，低优先级）（审查追问：残留 gate 对功能无影响——不可寻址（无人能 POST 其 id）、无人决议；wait 线程仍存活时 240s 超时自清，仅线程死亡才真残留，下一次插入时被惰性清理）：Zig 默认 panic handler = 打印 + abort 整个进程——"wait 线程 panic 后进程存活且 gate 残留"实际不会发生（进程已退出）；残留仅可能出现在极端退出路径（如连接线程被强制终止）。若进程无新审批插入，残留条目永不被惰性清理——**登记为低优先改进**：未来可在 server accept 循环加周期扫描（如每 1024 次 accept 清一次超时条目），本期不做（残留概率极低 + per-gate 内存 ~100B）

**并发模型与串行契约**（审查修订+安全补充）：agent 的 tool_calls 执行是**单 agent 内严格串行**——`agent.zig:369 for (tcs) |tc|` 顺序循环，每个工具（含 hook before 审批阻塞）完成才执行下一个，单回合内无并行执行路径（无 Thread/spawn）。server.zig 的线程是**连接级**并发（不同 HTTP 连接），**多个连接可同时运行多个 agent → 同一时刻进程内可能有多个 pending gate（每连接至多一个）**——原"同一时刻至多一个 pending gate"声明仅对单 agent 成立，已修正。前端侧：app.js 的 `evtSrc` 是**页面级单例**（切换会话时关闭旧流），一个页面同时只有一个 SSE 流 → 单 Modal 在**页面级**成立（不同标签页各自一个页面实例）。
- **安全模型（审查补充，安全关键）**：
  - gate id 用 **UUID v4**（`uuid_mod.v4`，项目已有）替代 `approval_{自增}`——**不可预测**，杜绝遍历猜测
  - **session 绑定**：gate 注册时记录 `session_id`；`POST /api/approval/:id` 请求体携带 `{allow, session_id}`，**session_id 不匹配 → 404**（与未知 id 同响应，不泄漏 gate 存在性）。**map 隔离等价性**（审查追问）：approval_map 保持全局平铺 + 每 gate 记录 session_id + POST 校验——校验失败 404 即隔离，安全性与"按 session 分桶"等价（分桶仅省一次无谓查找，复杂度更高无收益），保持平铺
  - 威胁模型：同源页面 CSRF 到 `127.0.0.1` 仍可**发送**请求（CORS 只禁读不禁发），但 id 为不可猜测 UUID → 无法定向到具体审批；完整 CSRF token 机制超出本期范围（本地单用户工具），登记为未来安全加固项
  - **Web 服务器无鉴权（登记，暂缓）**：默认绑定回环，但 `--address 0.0.0.0` 暴露局域网后**无任何认证**——同网段可读会话/**`/api/preview` 读 project_root 内文件（图片 ≤5MB/文本 ≤64KB）**/耗 API 额度/bash 工具读 `.zagent/.env` 拿 API key/删会话（对比 opencode `--auth` token 有差距）。方向（未来立项）：preview 与全部 API 同受 Web 认证保护（认证缺失时 preview 暴露范围 = project_root 内可读文件，与 read 工具权限等价）：opencode 式启动打印随机 token URL。**本期安全门禁（审查修订：非回环绑定无鉴权是重大安全差距，不等待完整认证实现）：server 启动时检查 `--address`：非回环地址（非 127.0.0.1/::1/localhost）且无鉴权配置（目前恒无）→ **拒绝启动**，错误提示“binding to a non-loopback address requires authentication — use --address 127.0.0.1, or wait for the auth feature”。效果：`--address 0.0.0.0` 时本期直接禁用（fail-closed），preview/会话/API 暴露面不存在；待认证实现后解禁并解除此门禁） + 登录端点换 httpOnly cookie + 全端点校验 + **非回环绑定无 token 拒绝启动**（防裸奔）；约束：`EventSource` 不能自定义 Authorization header，token 需走 URL 参数/cookie 通道
  - 防御纵深：即使 id+session 均泄漏，allow:true 也仅放行**本次待审批工具**（规则判定在 core，风险面有限）
- `approval_map` 用 StringHashMap 是 **id 寻址 + 重复 POST 幂等**的便利（`resolve` 幂等），并发多 gate 由多连接自然产生、各自独立
- 串行契约是前端单 Modal（页面级）的**依赖**：若未来 agent 并行化工具执行（e.g. 多工具同轮并行），必须同步引入 Modal 队列（按 id 排队，一次展示一个）或按工具分组合并展示——方案文档在此登记该演进约束

**职责边界**（审查补充：明确审批能力分层，防实施时判定逻辑误入 handler）：
- **core 层（src/approval.zig）**：危险判定（isRisky）+ 状态机（Gate）+ 决议语义——**决策逻辑全在 core，任何前端共享**
- **frontend 层（handler.zig + app.js）**：仅交互呈现——SSE 事件收发、Modal、POST 端点；经 `ToolHooks.before`（core 定义的回调契约，与 PhaseWriterCb/ToolDisplayCb 同模式）注入
- CLI 未来审批（审查补充：接口预留，避免未来重构核心逻辑）：预留的部分本期就定义：① **`approval.messageFor(decision, rule)` pub 函数**（三态措辞统一出口，从 web hook 内联文字提取）——CLI 拒绝后 append 的 tool 消息与 Web 字节一致；② **决策采集是可替换的交互层**：Web = SSE 事件 + gate.wait（keepalive/reminder 可传 null）；CLI = **同步模型，不走 Gate 轮询**——hook 内 stdout 提示（含 rule + messageFor 措辞）→ readLine y/n → 直接返回 null/拒绝消息（终端会话本身即生命周期，Ctrl+C 即中断，无 SSE 超时/断连语义）；③ `isRisky`/`Mode`/措辞常量均已 pub，CLI 直接用——core 零改动

**SSE 写帧接口契约**（审查补充：SseWriter 注释帧能力未定义——确认现有接口已支持，无需新增能力）：
- `SseWriter`（sse.zig:12-23）暴露 `writeAll`（任意原始字节）+ `flush` 函数指针——**writeAll 是原始字节通道，可写任意帧**（注释帧 `: keepalive\r\n\r\n`、事件帧 `event: x\ndata: {...}\n\n` 均直接 writeAll 字节序列）
- keepalive/approval_reminder 实现 = `sw.writeAll(": keepalive\r\n\r\n")` + `sw.flush()`（或对应注释帧），**无需新增包装方法**；写失败即错误返回（keepalive 回调语义）
- 契约：SseWriter 不改动；`writeFrame`（sse.zig:62-67）仍用于结构化事件，原始帧能力直接复用 writeAll

**拒绝消息契约**（审查补充：hook 返回值格式未明确——定义与现有 tool 消息/错误格式对齐规则）：
- `approvalBeforeHook` 返回 `?[]const u8` = **tool 消息 content（纯文本）**，非错误格式：agent 收到非 null 后 append `role=tool, content=<消息>`（agent.zig:377-381，与既有 before-block 路径完全一致），**不设 err_msg、不发 tool_error 事件、不发 tool_delta/render 回调**——拒绝不是执行错误（工具未执行），无工具卡片痕迹
- 前端反馈：Modal 关闭即用户已知晓；拒绝消息随 session 持久化，**reload 后按普通 tool 消息显示**（与 block 行为一致）
- 模型解析：下一轮 LLM 在 tool 消息中读到拒绝文本（三态措辞见上），据此调整策略——无特殊结构，自然语言

**日志与审计**（审查补充：审批是安全关键操作——危险命令的执行决策必须可回溯，对齐 F6 ①"请求级审计"理念；review checklist G15 空操作无日志 = 无法事后定位）：

| 事件 | 层级 | 级别 | 字段 |
|------|------|------|------|
| `approval_required` | handler（req_biz，带 tid/rid） | info | id、tool、rule、args 截断（前 200 字符） |
| `approval_resolved` | approval.zig（biz） | info | id、allow |
| `approval_timeout` | handler（req_biz） | warn | id、rule（240s 自动拒绝） |
| `approval_aborted` | handler（req_biz） | warn | id、reason（disconnect/abort/interrupt） |

- `Gate.resolve` 内部记 `approval_resolved`（Gate 持 id 字段，**allow=true 同样落盘**）——用户决策不可丢失；hook 侧 required/timeout/aborted 记带 session 上下文的日志
- **审计链分工（审查补充：批准也落盘，对齐 dsh approval/asked+decided 对）**：批准决议记录在 `.zagent/log/`（approval_resolved allow=true）——不将批准写入会话（否则污染模型 transcript，对齐 dsh “audit pair 是 log-only，不进模型 transcript”）；会话只保留**拒绝消息**（模型需要知道）——审计链 = 日志（全部决议含批准）+ 会话（拒绝，模型可见）
- 落盘走现有 log 系统（`.zagent/log/`，util/log.zig），CLI 与 Web 通用；不做单独审计文件（日志轮转已有）

**Web 集成**（handler.zig + server.zig）：

- 进程级 `approval_map: *StringHashMap(*approval.Gate)` + mutex（server.zig 定义，与 abort_map 同模式）
- `handlePrompt`（SSE）：组装 `ApprovalCtx`（sse_state/agent/approval_map/mode 指针）→ `agent.tool_hooks.before = approvalBeforeHook`
- `approvalBeforeHook(ctx, name, args)`：
  1. **主流程定稿（审查修订：补 approval_cache 进主流程）**：`mode==never` → 放行；`approval_allow` 归一化精确匹配命中 → 放行（用户显式信任声明最高优先）；**`approval_cache=true` 且 round cache 命中（name+args hash）→ 放行（审查修订：原流程漏掉此步，按此实现会丢失 cache 功能）；`approval.isRisky(mode, name, args)` 返回 null → 放行；否则进入审批（步骤2）——**写入时机：approved 决议后 `allowed.put(hash)`，存在 ApprovalCtx（per-连接），`approval_cache=false` 不查不写；**清理时机（审查修订）：cache 生命周期 = SSE 连接（回合）——ApprovalCtx 分配在 handlePrompt 的 request arena，连接结束 arena 释放，cache 随之自然清除，无需显式清理；跨回合不延续（每回合新 ApprovalCtx）****
  2. 需要审批：id=`uuid_mod.v4`（**不可预测 UUID，非自增**——安全审查）→ **先发 SSE `approval_required`（`{"id","name","args","rule","deadline_ms"}`，用 sse.writer 直写 frame（**帧构造用 jsonw.escapeAlloc 组装而非 writeFrame 的 4096 栈缓冲**——源码验证：sse.zig:63 用 4096 bufPrint，长 args 会 `catch "{}"` 丢帧；`event: approval_required\ndata: {...}\n\n` 由 writeAll 直写，writeFrame 只适用于短 payload），deadline = 注册时刻 + 240_000），写失败 = 连接已断 → 不注册 gate、不进入 wait，直接返回 **messageFor(aborted, rule) 措辞**（审查修订：必须用 aborted 而非 denied——连接断开是系统中断不是用户拒绝，用 denied 会误导模型“用户拒绝”）并调 `agent.abort()`**（前端收不到审批请求，gate 只会挂到超时——发送失败必须在源头短路）→ 写成功后才注册 gate 到 map（**携带 session_id**）→ `gate.wait(240_000, &checkAbort, &keepaliveAlive, &reminderPing)` → 从 map 移除 → 按决议三态返回**区分措辞**（审查补充：denied/aborted 语义合并会让模型误把系统中断当用户拒绝，错误调整策略）：
     - `approved` → 返回 null（放行执行）
     - `denied`（用户主动拒绝）→ `"User denied this tool call ({rule}). This rejection is final for this command — do NOT retry it or work around it by rephrasing flags; adjust your approach."`（审查扩展：明确“对该命令最终拒绝 + 禁止换参数绕过”，对齐 dsh “rejected escalation is final for that command, never work around it”）
     - `timeout`（超时无响应 = 自动拒绝，非用户决策）→ `"Tool call auto-denied: approval timed out ({rule}). It was not explicitly rejected by the user — you may retry this exact command later or ask the user."`（审查扩展：明确“可安全重试同一命令”，与 denied 的“最终拒绝”区分——超时是系统状态不是用户意志）
     - `aborted`（abort/SSE 断连，非用户决策）→ `"Tool call aborted: the connection was interrupted while awaiting approval ({rule}). It was NOT denied by the user."`，并调 `agent.abort()` 终止回合（SSE 已断，继续无意义）
- `POST /api/approval/:id` `{"allow":true|false, "session_id":...}` → map 找 gate，**session_id 与 gate 记录不匹配 → 404**（与未知 id 同响应）→ 匹配则 `resolve` → 200（响应体 `{"status":"ok"|"stale"}`，审查修订：resolve 返回 false = gate 已非 pending（超时/断连先展开）→ stale——防前端“2xx 但实际未变更”的状态不一致）。**无需通知机制**（agent 线程轮询 gate）。**session 隔离模式与 abort 一致**（审查追问）：abort 端点是 `POST /api/session/:id/abort`——session_id 在 URL 天然绑定（handler.zig:116）；审批端点 id 为随机 UUID 且 body 强制校验 session_id——两者同属"session 维度隔离"，审批因 UUID 不可猜测而更强（abort 的 URL 可枚举但无鉴权也仅止于中止本会话，风险面不同，已在威胁模型节说明）
- 事件时序：`approval_required` 先于 `tool_start`（hook 在 beginTool 之前，agent.zig:374→403）；审批通过后工具卡片正常流式
- **SSE 写失败矩阵**（审查补充：直写 frame 依赖连接活跃，全部写点失败行为必须显式）：
  | 写点 | 写失败行为 |
  |------|-----------|
  | `approval_required`（hook 内） | 短路：不注册 gate、不 wait，返回拒绝消息 + `agent.abort()` |
  | `keepalive` 注释帧（gate.wait 内） | 返回 false → wait 立即 aborted → hook 拒绝 + `agent.abort()` |
  | `approval_reminder`（gate.wait 内，120s 时） | 同 keepalive：返回 false → aborted |
  | `tool_start`/`tool_delta`/`tool_meta`（审批通过后，beginTool/renderTool） | 既有 sse.zig 机制（SseState.agent 字段"写失败→abort"，sse.zig:57/196-254）——非审批新增路径 |
  | 审批拒绝/超时后的 LLM 续跑（thinking/content 帧） | 同上，既有 sse 写失败→abort 覆盖 |
  **原则**：hook 内任何 SSE 写失败都不得静默吞掉继续 wait——要么短路拒绝（发送前），要么 aborted 返回（等待中）

**前端**（app.js + index.html）：

- `#approval-modal`（modal-overlay 模式，confirmModal 先例）：消息区（工具名 + 危险规则）+ 参数 `<pre>` + Cancel/Allow 按钮
- `approvalModal(detail)` Promise：Allow → `POST /api/approval/:id {allow:true, session_id: currentId}`；Cancel/Escape/遮罩 → `{allow:false, session_id: currentId}`
- **竞态处理（审查补充）**：Gate 超时/断连被清理后用户才点 Allow → POST 404。Allow 分支捕获**非 2xx**（404/500）或 **2xx 但 body.status==="stale"**（审查修订：超时/断连先展开后 POST 仍可 200，必须看体位——否则前端误以为“已允许”而实际已拒绝）→ 视为"审批已超时/已失效"：提示（`showStatus` 或 Modal 内换文案"This approval expired — the tool call was auto-denied"）并关闭 Modal，**不 resolve 为 allow**。已超时的 tool 消息后续会以 denied 形式出现在会话中，前端无需重发
- **断连联动**：SSE `evtSrc.onerror`（app.js:1592 现有路径）→ 关闭当前审批 Modal（若有）+ 清 pending 状态——服务端已因 keepalive 写失败 abort，Modal 残留会误导用户
- SSE listener `approval_required`：解析 detail → **先比较 deadline_ms 与当前时刻**：已过期→ 不弹窗、直接提示 “expired”（审查修订：队列后次弹出时 gate 可能已超时）；未过期→ 弹 Modal。同一时刻仅一个审批（**依据 agent 串行契约，见"并发模型"节**）；防御性兜底（审查修订：原"先拒绝旧再弹新"会打断用户审阅）：**新请求入队 `approvalQueue`，当前 Modal resolve 完成后弹下一个**——不打断审阅，队列深度上限 2（契约下正常为 0，排队即契约破坏信号）；注意排队请求的服务端 gate 在等待中消耗超时预算（240s），契约破坏时以超时兜底；**排队中间态体验（审查修订：用户处理第一个超 120s 时，第二个可能已触发 reminder 甚至超时——弹出时面对即将过期的请求）**：Modal 弹出时根据 `deadline_ms` 显示剩余时间（“auto-denies in ~N min”，对齐 reminder 措辞）；剩余 <30s → 红色紧迫提示（“expires in <30s”）但仍允许操作（用户可能秒点 Allow）；剩余 <0 → 不弹窗按 expired 处理（与既有 deadline 检查合并）——无裂裂体验。正常串行契约下排队不发生，此为防御路径的体验缝补
- SSE listener `approval_reminder`（分级超时新增）：当前审批 Modal 文案追加提示（如 "**Still waiting for your decision** — auto-denies in ~2 minutes"）+ 轻微视觉强调（标题色/边框），不打断、不重复弹窗
- 工具卡片流式期出现 pending 态（`tool_start` 到达后正常，审批在 tool_start 前——卡片此时尚未创建，无特殊渲染需求）

**策略模型可见性**（审查补充：模型必须知道审批策略边界，否则被拒后会反复尝试危险命令）：frontend 在 SystemPromptCb（agent.zig:71）里拼装审批策略段（非审批时不注入）：`never` → “approval prompts are disabled; destructive commands will be silently blocked only by their own guards, do not attempt recursive deletes/force ops”；`risky` → “destructive commands (recursive delete / device wipe / force git / pipe-exec / system mutation) require user approval once per exact command; a denial is final for that command”；`always` → “all tool calls require approval”。完整边界说明在“覆盖边界声明”節（封闭集、仅 bash、不覆盖类别清单）——模型得知保护范围。另作局限声明：“guards are lexical — shell variable indirection / command substitution / backticks can bypass them; do not rely on them as a security boundary”（审查修订：动态执行绕过（`cmd=rm; $cmd -rf`/命令替换/反号）无法被 token 扫描识别——引言式声明保护不越过词法层，“枚举护栏”不是“安全边界”；**L0 可疑语法已将最常见绕过信号（命令替换/反号/变量插值）从“漏过”改为“升级审批”（fail-closed）；剩余绕过（多行续行/转义 token/嵌套引号里的命令替换等）由 shell 解析级检测带来，登记 future。**CLI 端——fail-closed 语义**（审查补充：原计划“CLI 不做”未定义行为——CLI 无 hook 则 `risky` 下 `rm -rf` 静默放行，与“诚实执行”定位冲突；对齐 dsh “无 answerer = 拒绝”）：CLI（REPL + `--prompt` 单发——不存在交互答复者）在 `risky`/`always` 下遇危险命令：**确定性拒绝**——`tool_hooks.before = approvalCliHook`：`isRisky(mode) → 返回 messageFor(denied, reason=no-interactive-answerer)`措辞的 tool 消息 + 日志 `approval_denied reason=no_interactive`。REPL 的同步 readLine 确认留后续（接口已预留，“决策采集可替换交互层”）。语义是全模式一致：无交互答复者时威胁命令永不无声执行；`--approval never` 可显式放行。

### Part B — 文件/图片预览

**后端** `GET /api/preview?path=<相对 project_root>`：

- 路径解析：复用 `util/path.resolvePath`（防穿越，与 read 工具同源）——**symlink 边界（审查补充）：resolvePath 是字符串级规范化（`..` 折叠），不做 realpath/canonicalization——project_root 内 symlink 指向外部文件时 preview 可读外部内容，与 read/grep/glob 工具同等暴露（已在威胁模型声明“与 read 权限等价”）；Windows symlink 需管理员特权风险低，realpath 式检测与 R6（read realpath 双重解析）同源登记 future）
- **双表示设计（审查修订：base64 data URL 对 5MB 图膨胀至 ~6.7MB + JSON 转义，性能/内存不优——行业惯例是原始资源端点由 `<img src>` 直连）**：
  - **`GET /api/preview?path=`（JSON 表示，默认）**：判定顺序（四态）——
    1. 大小守卫（≤5MB，超限 → `kind:"too_large"`）
    2. **图片（png/jpg/jpeg/gif/webp/svg）→ `kind:"image"`，无内容，仅 `{name, kind:"image", path}`**——前端 `<img src="/api/preview?path=...&raw=1">` 直连原始端点渲染（**零 base64 膨胀**）
    3. 其余文件 `isBinary` → `kind:"binary"`（拒渲染，`{name, mime_hint}`，防乱码与内容注入）
    4. 文本 → `kind:"text"`（≤`types.FILE_READ_LIMIT` 64KB 守卫 + 超限截断 `truncated:true`，jsonw.escapeAlloc 转义）
  - **`GET /api/preview?path=&raw=1`（原始字节表示）**：仅图片扩展名白名单放行（png/jpg/jpeg/gif/webp/svg），**不做 isBinary**——审查修订：SVG 是文本格式 isBinary 会误拒，且 `<img>` 上下文禁脚本 + CSP `img-src 'self'` 已覆盖脚本风险，isBinary 仅用于 JSON 表示的文本/二进制分支→ **原始字节直出**，`Content-Type: image/<mime>`（映射表：`png→image/png`、`jpg/jpeg→image/jpeg`、`gif→image/gif`、`webp→image/webp`、`svg→image/svg+xml`——**禁止裸拼 `image/<ext>`**）+ `Cache-Control: private, max-age=60`；**JSON 表示缓存策略（审查补充）：`Cache-Control: no-store`——内容含可能敏感的文件文本，防止浏览器/代理缓存跨会话泄露）**；白名单外（非图片文件，含文本与非白名单二进制）→ 404；大小守卫同 JSON 表示（超限→ **413 Payload Too Large**，审查修订：原始端点非 JSON 不能返回 kind:too_large，413 是语义正确的 HTTP 错误码）（超限→ **413 Payload Too Large**，审查修订：原始端点非 JSON，不能返回 kind:too_large，413 是语义正确的 HTTP 错误码）
- **CSP（审查修订配套）**：`serveIndex` 响应加 CSP header——`default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:`（内联 script/style 是注入架构必须放行；`img-src 'self'` 使图片直连端点成为唯一图片来源，配合 SVG 渲染策略）
- **SVG 渲染安全策略**（审查修订：已有 CSP 环境下 `img-src 'self' data:` 允许 SVG data URL 渲染——既保留预览又不执行脚本）：**svg 允许走原始表示渲染**（raw=1，`Content-Type: image/svg+xml`），前端 `<img src>` 直连。安全前提（缺一不可）：① `<img>` 元素 + `src` 属性赋值（**禁止** innerHTML 注入 SVG 源码）——img 上下文的 SVG 是禁脚本 + 禁外部资源引用的（规范保证：`<script>`/事件处理器不执行、`<image href>` 外部引用被忽略）；② CSP `img-src 'self' data:`（已计划）收敛图片来源；③ 原始表示仅放行图片白名单（含 svg）。禁止路径：任何将 SVG 作为 HTML 渲染的路径（innerHTML/DOMPurify 展示）不受此豁免，仍须保持降级
- 错误：参数缺失/路径越界 → 400；文件不存在/目录 → 404

**前端**：

- `#preview-modal`（modal-overlay）：标题（文件名）+ 正文（文本 `<pre>` textContent / 图片 `<img>`）+ Close
- `previewModal(path)`：`fetch(/api/preview?path=...)` → `kind:"image"` 时正文直接 `<img src="/api/preview?path=<encodeURIComponent(path)>&raw=1">`（浏览器直连原始端点，零膨胀）；`kind:"text"` 渲染 `<pre>`；`binary`/`too_large` 提示文案
- 挂载点：read 卡（meta.path）、edit 卡（meta.path）→ ToolRegistry 类型化视图加 Preview 按钮（card-head 或 tool-meta 区，`data-path`）
- webfetch/grep 卡不挂（无本地路径语义）

## 实施

| 文件 | 改动 |
|------|------|
| `src/approval.zig`（新增） | Mode/GateState/Gate（wait/resolve）+ isRisky 规则集（L1/L2 分级）+ **messageFor 三态措辞统一出口（CLI/Web 共用）**+ 单测 |
| `src/config.zig` | `approval_mode` 字段（默认 risky）+ `approval_allow` 白名单数组 + `approval_cache` 开关（默认 true）+ TOML 解析 + 模板注释 |
| `src/frontends/web/server.zig` | 进程级 approval_map + mutex（abort_map 同模式）+ **非回环绑定无鉴权拒绝启动门禁** + AgentLoop.init 注入 `system_prompt` 回调（Web 端此前未注册 SystemPromptCb——策略可见性节依赖它，实施时新增） |
| `src/frontends/web/handler.zig` | approvalBeforeHook + ApprovalCtx + `POST /api/approval/:id` + `GET /api/preview`（JSON 四态）+ `GET /api/preview?raw=1`（原始字节）+ 路由 + serveIndex CSP header |
| `src/frontends/web/error.zig` | ErrorCode 新增 `payload_too_large` 变体（→ `std.http.Status.payload_too_large` 413）——raw 端点超限错误码（源码验证：现有 ErrorCode 无 413，方案原文"413 Payload Too Large"需此变体） |
| `src/frontends/web/app.js` | `approval_required` listener + approvalModal + previewModal + Preview 按钮（ToolRegistry read/edit 分支） |
| `src/frontends/cli/App.zig` | `approvalCliHook`（isRisky → 拒绝措辞，reason=no_interactive）+ SystemPromptCb 策略段 |
| `src/frontends/web/index.html` | `#approval-modal` + `#preview-modal` 结构 |
| `src/frontends/web/app.css` | 复用 modal-overlay；approval 详情 pre / preview 正文样式 |

测试（Zig：新增 approval 单测；前端：15 文件不变，modal 为 DOM 交互走浏览器实测）：

- `isRisky`：**变体命中矩阵**（L1 全命中）——`rm -rf`/`rm -fr`/`rm -r -f`/`rm --recursive --force`/`rm -rF`/`rm -R -f`/PS `Remove-Item -Recurse -Force`/`Remove-Item -R -Fo`（PS 前缀简写）/cmd `rmdir /s /q`/`del /s /q`/`git push --force`/`git push -f`/`git reset --hard`/`git clean -fdx`/**`git clean -f`/`-fd`/`-fx`/`-dfx`/`--force`（force 变体全命中）**/`curl "https://x" | sh`/`curl x | bash`/**`curl https://x|sh`/`curl "url"|bash`/`wget x|sh`（管道符紧贴，空白分词绕过修复）**/`format c:`/`diskpart`/`chkdsk /f`/`reg delete HKLM\...`/`net user`；**L1 语义说明**：`rm -r dir`（递归删除，含 recursive）**命中**——递归删除本身即破坏性，force 非必需；**L2 不命中**——`rm file.txt`/`Remove-Item file`/`git push`/`git clean`（无 force，dry-run）/**`git clean -n`/`-d`（dry-run，不实际删除）**/`curl https://x`（无管道）/**`echo "a|sh"`（引号内）/`ls | grep sh`（非 sh 命令）/`echo | shell`（前缀边界）**/`chkdsk`（无 /f）；**L0 可疑语法命中**——`rm -rf $(pwd)/x`/`eval $(cat x)`/`git clean -fdx $(list)`/`dd if=反号命令号 of=/dev/sdb`/`ls ${DIR} && rm -rf /tmp/x`（含 `$(`/反号/`${` 任一即审批）；**不升级**——`echo $HOME`（直接变量，非三信号）；**存储破坏新成员命中**——`shred secret.txt`/`wipefs /dev/sdb`/`vgremove data`/`lvremove /dev/vg/lv`/`parted /dev/sda mklabel`/`cryptsetup luksFormat /dev/sdb`/`mkswap /dev/sdb1`/`swapoff /dev/sdb1`；**cryptsetup 安全用法不命中**——`cryptsetup open /dev/sdb luksvol`/`cryptsetup luksAddKey /dev/sdb`；大小写变体 `RM -RF`/`Remove-Item -recurse -force` 命中 + **封闭集语义：非枚举危险命令（`shred`/`docker system prune -a`/`nmap`）不命中** + 非 bash 工具在 risky 模式不审（write/edit 等 8 工具全豁免）+ always 模式全审 + never 全不审 + **`approval_allow` 归一化精确匹配：条目命令命中（空白折叠）、`RM -RF .ZIG-CACHE` 不命中（大小写敏感）、`-extra` 尾缀不命中、`&& rm -rf /` 尾追加不命中、`./` 前缀与尾斜杠不折叠（不命中）** + **回合内缓存：同 name+args 命中跳过、args 不同（dir_A/dir_B）不命中各自弹窗、approval_cache=false 时完全禁用缓存**
- 预览四态：png/jpg/jpeg/gif/webp 走映射表（jpg/jpeg→image/jpeg），**JSON 端点返回 kind:"image" 无内容、原始表示（raw=1）`Content-Type` 与映射一致（含大小写扩展名 `.JPG`）+ 字节直出 + Cache-Control**；**svg 断言 `kind:"image"`（JSON 端点）且原始表示放行渲染（`Content-Type: image/svg+xml`）且 `<img>` 渲染无脚本执行**；`.exe`/`.zip`/`.pdf` 断言 `kind:"binary"`；超大文件 `kind:"too_large"`；CSP header 含 `img-src 'self'`
- `messageFor`：三态措辞分别生成（denied 含“User denied + final for this command + do NOT work around”/timeout 含“auto-denied + may retry”/aborted 含“NOT denied”）+ rule 嵌入
- 策略可见性：三模式 SystemPromptCb 输出分别含对应措辞；CLI hook：`risky` 下 `rm -rf` 返回拒绝消息（含 no_interactive 日志）、`never` 下放行
- `Gate`：初始 pending、resolve(true/false) 后状态、重复 resolve 幂等、wait 分级超时（**120s 触发 reminder 一次、240s 返回 denied**）、check_abort 置位返回 aborted、**keepalive 返回 false 立即 aborted（断连语义）、keepalive 周期性调用次数正确、reminder 写失败返回 false→aborted**；惰性清理：注册超时条目在下次插入时被 resolve+移除
- 前端竞态（浏览器实测）：审批 Modal 打开 → 等待超时 → 点 Allow → 提示 "expired" 且无二次请求副作用；断连 → Modal 自动关闭；**连续两个 approval_required（契约破坏模拟）→ 第二个入队，第一个完成后续弹**；**安全：错误 session_id POST → 404、未知 id → 404、两会话（双标签页）各自审批互不影响**

## 验证

- `zig test src/test.zig --cache-dir .zig-cache` → All 325+N tests passed
- `zig build` + `zig build -Doptimize=ReleaseSafe`（含函数指针改动，强制）
- `node tests/frontend/run-tests.mjs` → All 15 file(s) passed
- 实机（Web）：`approval_mode=risky` → 诱导 bash `rm -rf` → ApprovalModal 弹出 → Allow 执行正常流式 / Deny 出现拒绝 tool 消息且模型继续；`never` 模式无弹窗；预览：read 卡 Preview 打开文本文件、图片文件以 `<img>` 渲染、越界路径 400
