# Plan WEBFETCH: WebFetch 工具（网页抓取）

## 状态: ✅ 已实施（2026-08-13）

## 问题

**现象**：当前 z-agent-core 的 8 个内置工具全是本地文件操作（read/write/bash/grep/glob/skill/edit/compact），无法获取网络内容。LLM 需要查阅在线文档、API 参考、GitHub issue 时只能靠用户手动粘贴。
**根因**：缺少一个调用 curl 子进程拉取 URL 并转换 HTML→Markdown 的工具，agent 信息获取能力受限。

## 概览

- **改动范围**：1 个新文件 `src/tool/webfetch.zig`（~280 行）+ registry.zig 1 行注册 + types.zig 1 个 ToolMeta 变体
- **参考实现**：opencode `packages/core/src/tool/webfetch.ts`（218 行，effect HttpClient）+ 测试 `tool-webfetch.test.ts`（11 用例）。本文档在 opencode 实现基础上对齐了 MIME 校验 / Accept 协商 / Cloudflare 重试 / stripHtml 质量四个关键缺口
- **方案思路**：复用现有 curl 子进程模式（与 `src/tool/bash.zig` 的 `std.process.run` 完全一致），零外部依赖自实现 HTML→Markdown 转换器
- **周期归属**：0.2.8（工具优化主题第一项）

## 设计要点

### 1. 执行通道：curl 子进程而非 Zig HTTP client

Zig 0.16.0 无内置 HTTP client（AGENTS.md 已列明），且项目已有成熟 curl 子进程模式（`src/io/provider.zig` SSE 流式、`src/tool/bash.zig` 子进程运行）。复用 `std.process.run` 保持一致性，规避实现 HTTP 客户端的大量平台边界（TLS、重定向、gzip）。

| 方案 | 优点 | 缺点 |
|------|------|------|
| curl 子进程 | 与现有代码一致；处理重定向/gzip/TLS | 依赖 curl 在 PATH |
| Zig HTTP client | 无外部依赖 | 0.16 无内置；手写大量边界逻辑 |

**选择**：curl 子进程。curl 是项目已有硬依赖（provider.zig 依赖，AGENTS.md Requirements 已列）。

### 2. 输出格式：markdown 默认 / text / html 三档 + Accept 协商

opencode 参考实现为三档选择，并**按格式发 Accept 头**引导服务器返回合适表示：

| format | Accept 头（q 值降序） |
|--------|----------------------|
| markdown | `text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1` |
| text | `text/plain;q=1.0, text/markdown;q=0.9, text/html;q=0.8, */*;q=0.1` |
| html | `text/html;q=1.0, application/xhtml+xml;q=0.9, text/plain;q=0.8, text/markdown;q=0.7, */*;q=0.1` |

**HTML→Markdown 转换器（手写轻量实现，Zig 0.16 无原生库）**：

| 元素 | 输出 | 支持 |
|------|------|------|
| h1-h6 | `# `..`###### ` + 块后空行 | ✅ |
| p / div / br / hr | 块级换行；hr → `---` | ✅ |
| strong / b | `**text**` | ✅ |
| em / i | `*text*` | ✅ |
| a | `[text](href)` | ✅ |
| ul / ol / li | `- ` + 缩进嵌套 | ✅（支持嵌套深度） |
| pre / code | fenced ```` ``` ```` | ✅（pre 整块；inline code 用 `` ` ``） |
| table | 简化：行内文本逗号拼接 | ⚠️ 不产出 GitHub 表格 |
| script / style / noscript / iframe | **内容剔除**（不输出） | ✅ |
| 嵌套复杂结构 | 简化平铺 | ⚠️ 已知边界 |

**转换器边界**：不处理 JS 渲染页面（curl 限制）；表格/复杂嵌套退化（可接受——文档站/API 参考的标题+段落+链接+代码块是主体）。动态页面留给未来 headless browser 方案。

### 3. MIME 类型校验（opencode 对齐缺口）

opencode 在读取 body 前校验响应 Content-Type（`isTextualMime` + `isImageAttachment`），防止把图片/PDF/二进制当文本返回污染 session。

**body 与响应头分离（审查改进，非原方案）**：原方案用 `-w "\n%{http_code}\n%{content_type}"` 尾注追加 body 后——但 body 接近 1MB 时 stdout_limit 截断会**截掉尾注**，且 body 内容含类似行时**解析歧义**。改为：

- curl `-o <临时文件>` 写 body（绕过 stdout_limit，天然不截断尾注）
- curl `-w "HTTP_CODE:%{http_code} CONTENT_TYPE:%{content_type}"` 尾注留 stdout（永不截断、无歧义）
- `std.process.run` 的 stdout_limit 作用于尾注（仅几十字节，安全）
- body 从临时文件读回（`defer deleteFile` 清理）

响应头校验逻辑：

- `image/` → 报错 `Unsupported fetched image content type`（`image/svg+xml` / `image/vnd.fastbidsheet` 除外，SVG 是文本可返回）
- 非文本 MIME（不在 text/*、json、xml、javascript 白名单）→ 报错
- `Content-Type` 含 `text/html` 才做格式转换；否则原样返回（防 PDF/zip 被当 HTML 解析）

### 4. Cloudflare 挑战重试（opencode 对齐缺口）

opencode 用浏览器 UA 默认请求，遇 403 + `cf-mitigated: challenge` 换诚实 UA（"opencode"）重试一次——避免被 CF 反爬拦截常见文档站。

**我方简化**：默认 Chrome 浏览器 UA（`Mozilla/5.0 ... Chrome/143.0.0.0 Safari/537.36`），curl `-w` 拿到 `http_code == 403` 即换 `z-agent-core/1.0` UA 重试一次。**不做 `cf-mitigated` 头判断**——原因：

1. `-w` 无法输出任意响应头（`cf-mitigated` 拿不到）
2. `-D -` 会把响应头混入 stdout，与 body 无法在 `std.process.run` 单通道中分离
3. 简化后：普通 403 多一次请求（无副作用）；CF 站 403 换诚实 UA 能成功——工程上可接受

### 5. 超时与大小限制（双层超时）

- **外层：`std.process.run` 的 `.timeout`（进程级兜底）**——覆盖 DNS 解析/进程启动/curl 整体挂起。对齐 bash.zig:76 的 `Io.Timeout` 模式，`catch error.Timeout` 分支报"Request timed out"。**必须加**：curl `--max-time` 无法覆盖 DNS 解析阶段的挂起。
- **内层：curl `--max-time <timeout_secs>`（应用层）**——让 curl 自身按时退出，错误信息更精确（连接超时/读超时区分）。参数化（默认 30s，上限 120s，opencode 对齐）。
- 输出上限 1MB，**单一机制**：`std.process.run` 的 `.stdout_limit = 1MB` 截断 + 追加截断说明。
  **不设 curl `--max-filesize`**（两者并存会冲突：curl 超限先直接失败，截断逻辑永远走不到）。
  opencode 是超限报错，我方选截断——对 LLM 信息获取更友好
- 超时错误信息需区分：进程级 `error.Timeout` → "Request timed out (N s)"（对齐 bash.zig:94 工具诚实原则）

### 6. ToolMeta 扩展

新增 `webfetch` 变体（`{url, byte_count, format, mime}`），字段全部零拷贝借用（与 types.zig:61 约定一致），供前端工具卡片展示。`mime` 字段供前端判断是否显示转换后内容。不引入新前端逻辑（tool-card 已通用渲染 meta）。

## 实施

### 步骤 1: 创建 `src/tool/webfetch.zig`

**文件**: `src/tool/webfetch.zig`（新建）
**改动**: 完整工具实现，含 `execute` + `htmlToMarkdown` + `stripHtml` + `truncateContent` + `isTextualMime` 辅助函数 + 文件末尾 test blocks

**关键签名**（对齐 bash.zig 已验证模式）:

```zig
const std = @import("std");
const types = @import("../types.zig");

pub const tool_name = "webfetch";
pub const tool_params = \\{"type":"object",...} ;

pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    // 1. 校验 url 存在且 http/https scheme
    // 2. 解析 format（默认 markdown）+ timeout（默认 30s，上限 120s）
    // 3. 组装 curl argv（第一次，浏览器 UA + Accept 头）：
    //    curl.exe -sL --compressed --max-time <t>
    //      -o <临时文件>                                    // body 写文件，绕过 stdout_limit
    //      -w "HTTP_CODE:%{http_code} CONTENT_TYPE:%{content_type}"  // 尾注留 stdout，永不截断
    //      -H "User-Agent: Mozilla/5.0 ... Chrome/143.0.0.0 Safari/537.36"
    //      -H "Accept: <按 format 协商>"
    //      <url>
    //    注：不设 --max-filesize，body 超 1MB 在转换时截断（见设计要点 5）
    // 4. std.process.run(ctx.allocator, ctx.io, .{
    //      .argv, .stdout_limit=1KB, .stderr_limit=10KB, .timeout=timeout_opt })
    //    catch error.Timeout → "Request timed out (N s)"（进程级兜底，DNS/启动挂起）
    // 5. 解析 stdout 尾注：HTTP_CODE + CONTENT_TYPE（无 body 干扰）
    // 6. 读取临时文件 body；defer deleteFile 清理
    // 7. 校验 MIME：isTextualMime 失败 → 报错；image/*（非 svg）→ 报错
    // 8. 若 http_code==403 → 换 UA "z-agent-core/1.0" 重试一次（Cloudflare 简化策略，见设计要点 4）
    // 9. format 分派（仅 content-type 含 text/html 时转换，否则原样）：
    //    markdown → htmlToMarkdown；text → stripHtml；html → 截断
    // 10. 返回 ToolResult{ .session_content, .meta = .{ .webfetch = .{url, byte_count, format, mime} } }
}
```

**注意**：
- term 检查用 `switch (proc_result.term)` 匹配 `.exited => |code|`（bash.zig:110-113 模式）
- **body 写临时文件 + `-w` 尾注分离**（设计要点 3 审查改进）：stdout_limit=1KB 仅作用于尾注，body 不受截断影响；尾注用唯一前缀 `HTTP_CODE:` 解析，无歧义
- **双层超时**：`.timeout` 进程级兜底（`catch error.Timeout` → "Request timed out"）+ curl `--max-time` 应用层（bash.zig:94 工具诚实原则对齐）
- **Io.Timeout 构造**（0.16 签名，bash.zig:42-44 模式）：`Io.Timeout{ .duration = .{ .raw = Io.Duration.fromSeconds(secs), .clock = Io.Clock.real } }`，无 `.secs` 字段
- **Cloudflare 重试**：http_code 从尾注解析，==403 换诚实 UA 重试（不做 `-D -` 头分离，见设计要点 4 权衡）
- `htmlToMarkdown` 必须**跳过 script/style/noscript/iframe 内容**（opencode htmlparser2 行为对齐），否则 text 提取会返回脚本代码
- 转换器标签支持规格见设计要点 2 的表（h/段落/加粗/斜体/链接/列表/代码块；表格简化；script 剔除）
- 所有 ToolResult 路径 allocator 正确：`session_content` 由 deinit 释放，`url_owned` errdefer；临时文件 `defer deleteFile`（M-04）

### 步骤 2: ToolMeta 扩展

**文件**: `src/types.zig`
**改动**: 在 `ToolMeta` union（types.zig:62-109）追加变体:

```zig
webfetch: struct {
    url: []const u8,
    byte_count: usize,
    format: []const u8,
    mime: []const u8,
},
```

**注意**：所有 `switch (result.meta)` 消费方需检查是否覆盖新变体（阶段 4 消费方追踪）

### 步骤 3: 注册工具

**文件**: `src/tool/registry.zig`
**改动**: import + 一行注册（registry.zig:8-71 模式）:

```zig
const webfetch_tool = @import("webfetch.zig");
// handlers 数组追加:
.{ .name = webfetch_tool.tool_name, .description = webfetch_tool.tool_description, .params = webfetch_tool.tool_params, .execute = webfetch_tool.execute },
```

**注意**：registry.zig:114 的 `tools.len == 8` 测试需改为 9

### 步骤 4: 测试（webfetch.zig 内部 test blocks）

测试先行，对齐 opencode 测试用例。覆盖：

| 测试名 | 场景 | 说明 |
|--------|------|------|
| `webfetch: missing url` | 空参数 | 错误路径 |
| `webfetch: invalid url scheme` | `ftp://` | 错误路径（opencode assertHttpUrl 对齐） |
| `webfetch: invalid url scheme file` | `file://` | 错误路径（实施补充） |
| `webfetch: html to markdown` | `<h1>Title</h1><p>Hello <b>world</b></p>` | 转换器纯函数 |
| `webfetch: stripHtml` | `<div>hello</div><p>world</p>` | 去标签 + 空白折叠 |
| `webfetch: stripHtml skips script` | `<script>bad()</script>hello` | **opencode 对齐**：script 内容剔除 |
| `webfetch: isTextualMime` | text/html / image/png / application/pdf | MIME 校验纯函数 |
| `webfetch: link conversion` | `<a href="...">text</a>` | 链接转换断言（实施补充） |
| `webfetch: fetch real url` | `https://httpbin.org/robots.txt` | 真实网络（标记 require-network） |

**注意**：
- 真实 URL 测试需要网络，可能不稳定——用 `zig test` 运行时若失败需判断是否为网络环境问题而非代码 bug
- stripHtml 跳过 script 测试是 opencode 对齐缺口验证（LRN-20260813-011 参考）

## 验证

```powershell
zig build
zig test src/tool/webfetch.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 场景 | 预期 |
|------|------|
| 单模块测试 | webfetch 9 个 test 全过（含新增 link conversion / invalid url scheme file） |
| 全量测试 | registry 的 len==9 更新后全过 |
| 消费方追踪 | ToolMeta switch 全部覆盖 webfetch 变体 |
| 架构扫描 | 无新增 God Object / 循环依赖 |
| MIME 校验 | 非文本 content-type 返回错误而非污染 session |

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/tool/webfetch.zig` | 新建 ~280 行 | 否 |
| `src/types.zig` | ToolMeta 新增 `webfetch` 变体 | 否 |
| `src/tool/registry.zig` | 1 import + 1 注册 + 测试 len 8→9 | 否 |
| `src/test.zig` | 聚合加 `_ = @import("tool/webfetch.zig");` | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| ToolMeta | 每个工具返回的结构化元数据（types.zig:62），供前端工具卡片渲染 |
| std.process.run | Zig 0.16 的子进程运行 API，返回 stdout/stderr 分配 + term 状态 |
| HTML→Markdown | 将 HTML 标签结构转换为 Markdown 语法的轻量转换器 |
| MIME | Content-Type 响应头，用于判断返回内容是文本/图片/二进制 |
| Cloudflare challenge | CF 反爬挑战响应（403 + `cf-mitigated: challenge`），换诚实 UA 可绕过 |

## 对齐参考（opencode）

| 参考项 | opencode 位置 | 对齐动作 |
|--------|--------------|----------|
| Accept 头协商 | `webfetch.ts:46-56` | 已并入设计要点 2 |
| MIME 校验 | `webfetch.ts:99-110` | 已并入设计要点 3 |
| Cloudflare 重试 | `webfetch.ts:67-80,149-151` | 已并入设计要点 4 |
| timeout 参数 | `webfetch.ts:25,32-34` | 已并入设计要点 5 |
| script 跳过 | `webfetch.ts:192-205` | 已并入实施步骤 1 + 测试 |

## 实施偏差记录（2026-08-13）

| # | 偏差 | 说明 |
|---|------|------|
| 1 | `parseTagName` 支持数字 | 原实现只取字母，`h1` 解析为 `h` → 标题前缀丢失。加 `0-9` 字符集（评审发现） |
| 2 | `ArrayListAligned.pop()` 返回 `?T` | 0.16 签名，已用 `pop().?`（len>0 前置检查） |
| 3 | `toOwnedSlice` 返回 `![]u8` | 0.16 可失败，需 `try`；stripHtml 返回前重新 dupe 到精确大小（free 尺寸匹配） |
| 4 | mime 借用悬垂 | `mime` 原借用 `proc_result.stdout`（doFetch 尾部 defer free）→ 实机乱码。改 dupe 独立拷贝 + freeFetch 释放 |
| 5 | 临时文件删除 API | `deleteFileAbsolute` 只接受绝对路径，相对路径 `./.tmp/...` 触发 unreachable panic。改用 `Dir.cwd().deleteFile` |
| 6 | curl `-H` 头组装 | 原拆成 `["-H", "User-Agent: ", ua]`（curl 只吃单值），改 `allocPrint("User-Agent: {s}")` 单串 |
| 7 | 403 重试 double-free 风险 | 原 defer+手动 free 双路径，改为 `freeFetch` 单一路径 |
| 8 | `.tmp` 目录未创建（用户实测 code -1） | doFetch 依赖 `.tmp/` 写 body，但从未创建——首次运行 `.tmp` 不存在时 curl `-o` exit 23 → 误报 code -1。修复: doFetch 前 `createDir` 确保存在（PathAlreadyExists 忽略） |
| 9 | 测试清单新增 2 个 | 实施时补充 `webfetch: invalid url scheme file`（file:// 场景）和 `webfetch: link conversion`（链接转换断言）。源码共 9 测试，超计划清单的 7 个 |

**实机验证**（2026-08-13）：`zig build run -- --prompt "抓取 https://example.com"` → LLM 正确返回 "Example Domain" 标题+正文+链接；临时文件 0 残留；ReleaseSafe 编译通过。
