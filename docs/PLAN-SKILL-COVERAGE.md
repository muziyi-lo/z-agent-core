# Plan SKILL-COVERAGE: cdp + frontend-dev 技能覆盖缺口评估

## 状态: 待办（未开始）

## 背景

2026-08-06 评估 chrome-cdp + frontend-dev 两个技能对本项目（z-agent-core Web 前端，单文件 index.html + vanilla JS + @embedFile 嵌入 Zig exe）开发需求的覆盖情况。核心开发需求已补足（开发/调试/审查三模式 + 浏览器实测 + 用户视觉闭环），但发现三处与项目形态相关的真实缺口，作为待办记录。

## 缺口清单

### GAP-1: SSE 流式帧级调试无专项原语

- **现状**: 项目核心是 SSE（thinking_start / content_delta / tool_start / tool_meta / done），但 chrome-cdp 的 `network --filter` 仅支持 document/script/style/image/font/xhr/fetch/websocket 类型，**不含 eventsource**。
- **影响**: SSE 帧序列无法精确过滤观察，只能靠 `eval` 读 EventSource 状态兜底。
- **建议方案**: 给 chrome-cdp `network` 命令 `--filter` 增加 eventsource 类型（CDP Network 事件对 EventSource 逐帧上报），或文档化 eval 兜底监听器模板。
- **涉及**: `.opencode/skills/chrome-cdp`

### GAP-2: @embedFile 嵌入形态不适配"直接预览"

- **现状**: index.html 含 FONT_MARKER / SCRIPT_MARKER 占位，vendor JS（marked/DOMPurify/highlight）由后端 `serveIndex` 编译期注入。frontend-dev 的 build-and-test 默认"纯 HTML 走 file:// 或 http.server"，但本项目直接开 file:// 会缺 vendor JS 且 marker 残留。
- **影响**: 前端改动无法独立预览，必须 `zig build` + `--web` 起完整服务，两个技能均未显式声明此流程。
- **建议方案**: 在 frontend-dev `references/build-and-test.md` 追加"@embedFile 嵌入项目"适配段（预览 = zig build + --web；或本地临时注入脚本）。
- **涉及**: `.opencode/skills/frontend-dev`

### GAP-3: Web 前端无自动化测试

- **现状**: Web 前端全依赖手动验证，无自动化测试。
- **影响**: 回归风险高（本轮模型下拉 bug 即初始化时序类回归）。
- **建议方案**: 跟随既有 `docs/PLAN-FUTURE-SESSION-IMPROVEMENTS.md` P2 冒烟测试计划（session CRUD roundtrip）；后续可补充前端关键路径断言。
- **涉及**: 项目测试基建（无独立计划编号，挂靠在 FUTURE-SESSION）

## 刻意取舍（非缺口）

- 非多模态模型不依赖截图自检，视觉裁定权在用户（frontend-dev 硬约束），以 `inspect`/`eval` + 用户反馈闭环替代。

## 待办登记

| # | 缺口 | 优先级 | 状态 |
|---|------|--------|------|
| GAP-1 | cdp network 增加 eventsource filter | 中 | 待办 |
| GAP-2 | frontend-dev 补充 @embedFile 预览适配说明 | 低 | 待办 |
| GAP-3 | Web 冒烟测试（并入 FUTURE-SESSION P2） | 低 | 待办 |

## 术语

| 术语 | 含义 |
|------|------|
| SSE | Server-Sent Events，服务端单向推送，前端 EventSource 接收 |
| eventsource | CDP Network 中对 EventSource 请求的资源类型 |
| @embedFile | Zig 编译期把文件内容嵌入二进制的机制，本项目 index.html 由此嵌入 |
