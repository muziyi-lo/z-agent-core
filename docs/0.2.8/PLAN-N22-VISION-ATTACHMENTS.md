# Plan N22-VISION-ATTACHMENTS: 多模态图片附件（vision）

## 状态: ✅ 已实施（2026-08-16，N22）

## 实施偏差记录

- CLI 附件渲染未实施：方案步骤 5 的 "CLI toolMetaLabel 加附件摘要" 跳过——ToolMeta 无附件字段（附件在 Message 层），为加渲染需跨 ToolMeta/session/SSE 全链路改动；工具文本摘要（"Image file: ... preview it separately"）已覆盖 CLI 可见性，YAGNI
- Web 附件仅 reload 路径内联（流式不传字节走 Preview，与方案一致）；附件 img 追加到 card-body 尾部（非 .output 内，防 typed view 重写覆盖）
- read 尺寸守卫头部缓冲 4096 字节（对齐 opencode SAMPLE_BYTES；JPEG SOF 扫描需要）
- parseInputModality 警告需 io 参数——签名链 parseConfigContent→parseAllModels→parseInputModality 增加 io 透传（测试用 std.testing.io）

## 评论修订记录

- 2026-08-16 审查 5 点边界补充：①MIME 判定加 magic bytes 嗅探（对齐 opencode sniffAttachmentMime，扩展名仅预筛，防伪装）②null 附件序列化省略字段（对齐 reasoning_content 既有模式）③附件 dup 深拷贝契约明确（arena-duped，ToolResult 独立释放）④注入前校验（mime 白名单 + data 非空/字符集 + 跳过非法附件）⑤多附件累计 5MB 守卫（当前单文件，数组为未来预留）
- 2026-08-16 二轮评论 3 点修正：①Base64 校验**容忍 `\r\n\t` 行折叠**（RFC 4648——标准编码器不产生但外部来源可能带换行，误判会丢合法附件）②多附件累计守卫**分层**：工具层生成前拦截为主（未来多文件时避免 provider 层"部分成功"模糊反馈），provider 层仅最终防御 ③非 vision 模型**弃用错误文本替换**（opencode transform.ts 方式会干扰模型推理）→ provider 层保持事实摘要 + agent 层注入 `[Notice: ...]` 系统消息（幂等，对齐 StormBreaker 模式）——记录为对 opencode 的偏离改进
- 2026-08-16 三轮评论：**前置尺寸守卫提前到 N22**（原列 F23 P2）——采纳"至少简单尺寸检查"建议，但用**纯头部解析**（PNG/GIF/JPEG/WEBP 头部宽高，零依赖 ~150 行）替代 stb 绑定（评论者称"集成成本不高"被评估为低估——cImport 桥接+三格式流水线实际 300+ 行）：短边 >2000px（对齐 opencode 默认）拒绝附件化，超限用户走 Preview 兜底；完整 stb 缩放流水线（等比降采样+JPEG 质量候选）保持 F23
- 2026-08-16 四轮评论 4 点实现细节：①非 vision 系统消息**临时注入请求数组、不写 session 历史**（text-only→vision 切换后无残留 Notice；对比 StormBreaker 的持久化——能力边界是模型相关的瞬态事实）②累计守卫单位明确为**原始字节总大小 ≤5MB**（非 base64 长度）③尺寸守卫**以原始像素尺寸为准、不处理 EXIF Orientation 旋转**（模型不自动旋转，保守合理，明示语义）④会话文件膨胀**登记 F24**（外置存储/清理策略），配置模板注释提示用户
- 2026-08-16 五轮（zig-dev 文档审查）4 处严重修订：①**删除 `Attachment.name` 字段**（四轮①后错误文本方案废弃，文件名无消费方——YAGNI，F24 外置存储时再评估对齐 opencode filename）②**实施表/波及表补 `agent.zig`**（四轮①的临时 Notice 注入是核心改动，原表遗漏）③**实施表/波及表补 `handler.zig`**（dupMessage 附件深拷贝，undo 路径）④**步骤 3 的 types.writeJson 引用删除**（writeJson 是 ToolMeta 序列化器，Message 序列化在 session.zig serializeMessage/parseMessage）；另更新"行为与现状一致"措辞（修订后非 vision 有 Notice 注入）、104 行标题区分 opencode 原始做法

## 问题

**现象**：LLM 调用 read 读取图片文件时，只得到"Image file: xxx (N bytes)"摘要——图片的像素内容从未进入模型上下文，模型无法"看到"图片。
**根因**：整条多模态消息链路缺失——工具结果无附件字段（`ToolResult` 无 attachments）、消息模型 `content` 是纯文本字符串、provider 请求构造只发字符串 content（provider.zig:542 `jw.stringField("content", msg.content)`）、会话无附件持久化。`types.InputModality.image` 与 config `input=["text","image"]` 仅是声明，无任何实现消费。

## 概览

- 改动 10 个文件（types/read/session/agent/provider/handler/app.js/render/config/REMAINING），新增 1 个能力（附件链路）
- **参考实现：opencode**（`g:\ProgramLibrary\Repositories\opencode\packages\opencode\src\tool\read.ts:306-324` + `packages\llm\src\protocols\openai-chat.ts:205-228`），五步链路已逐行验证
- 一句话思路：工具结果携带 `attachments`（mime + base64），随消息持久化，provider 按 OpenAI-compat `image_url` 内容块注入请求，**按模型 `input` modality 门控**（非 vision 模型不注入附件、content 保持事实摘要，agent 层临时注入系统 Notice 说明能力边界）

## 设计要点

### 1. 附件数据模型（对齐 opencode attachments/media part）

opencode 在工具输出中返回 `attachments:[{type:"file", mime, url:"data:<mime>;base64,<bytes>"}]`（attachment 含 filename），内部转成消息的 media part（`message-v2.ts:167-190`），最终由 `lowerMedia` 转 OpenAI Chat `{type:"image_url", image_url:{url}}`。

我们的表示（不做 data URL 字符串，拆开存 mime + base64，请求时拼接，序列化更干净）：

```zig
pub const Attachment = struct {
    mime: []const u8,   // 白名单内：image/png|jpeg|gif|webp
    data: []const u8,   // base64 编码的原始字节
};
```

> 审查修订：不引入 `name` 字段（评审发现四轮修订后非 vision 处理已从"错误文本替换"改为"系统 Notice"，文件名无消费方——YAGNI；如需对齐 opencode attachment.filename 在 F24 外置存储时再评估）。

挂载点两个：
- `ToolResult.attachments: []const Attachment`（工具产出，deinit 释放）
- `Message.attachments: ?[]const Attachment`（会话持久化，arena dup）

**选择理由**：与 opencode 的 `{mime, url(data:)}` 等价但避免重复解析 data URL 前缀；`data:image/png;base64,` 前缀在注入点拼装，只出现一处。

### 2. read 工具图片附件（对齐 read.ts:306-324）

opencode 对 SUPPORTED_IMAGE_MIMES（jpeg/png/gif/webp）读取全部字节 → base64 附件，文本输出仅 "Image read successfully"。opencode 的 MIME 判定用 `sniffAttachmentMime(sample, FSUtil.mimeType(filepath))`——**先读 4096 字节样本做 magic bytes 嗅探，扩展名仅作 fallback**。

我们沿用现有图片摘要分支改造（保留友好文本），关键差异点：

```zig
// read.zig 图片分支：
// - 扩展名（isImage 预筛：png/jpg/jpeg/gif/webp，大小写不敏感）→ 进入图片路径
// - magic bytes 确认（读文件头 12 字节）：PNG 89 50 4E 47 0D 0A 1A 0A /
//   JPEG FF D8 FF / GIF 47 49 46 38 / WEBP RIFF..WEBP（偏移 0-3 RIFF + 8-11 WEBP）
// - magic 不匹配（伪装/损坏）→ 不当图片处理，回退既有 binary 拒绝路径（防扩展名欺骗）
// - MIME 以 magic 判定为准（扩展名仅预筛，防 .jpg 实为 png 等错配）
// - 读全量字节（上限 5MB，对齐 preview PREVIEW_MAX_SIZE；超限回退纯摘要，不报错）
// - base64 编码（std.base64.standard.Encoder，handler.zig:214 已有先例）
// - ToolResult.attachments = [{ mime, data }]
// - session_content 保留摘要文本（模型可见；附件随 tool 消息持久化）
```

**大小守卫**：单文件 5MB 上限——对齐 preview 端点守卫，避免超大多模态请求体（base64 膨胀 33%，7MB 体）；超限仍返回摘要（用户可走 Preview 查看）。**多附件累计守卫见要点 4**。

**尺寸守卫（N22 引入，评论建议"至少简单尺寸检查"采纳）**：vision 按图片尺寸/图块计费，仅字节上限不足以省钱——**短边 >2000px 的图片拒绝附件化**（阈值对齐 opencode 默认 max_width/max_height=2000）：
- **纯头部解析零依赖**（不引入 stb 绑定）：PNG（IHDR 偏移 16-23 定宽高）/ GIF（偏移 6-9）/ JPEG（扫描 SOF0-3 段，跳过 APPn）/ WEBP（VP8X 画布尺寸；VP8/VP8L 解析失败 → 保守拒绝附件化）
- **EXIF 声明（评论补充）**：头部解析得到的是**原始像素尺寸，不处理 EXIF Orientation 旋转**——模型通常不会自动旋转 EXIF，以原始尺寸判断短边是保守且合理的（旋转后用户视角的短边只会更小，不会产生越界风险）；文档明示此语义，减少误解
- 超限 → 不附件化，摘要追加 "Image too large (WxH px) — not attached; use Preview to view"（用户仍可 Preview 查看，现有功能兜底）
- 头部解析失败（非标准/损坏）→ 保守拒绝附件化（magic 已确认类型但结构异常）
- 完整缩放（等比降采样 + JPEG 质量候选）保持 **F23**（vendored stb_image/stb_image_resize2/stb_image_write，对齐 photon.ts 策略）——N22 的尺寸拒绝已拦截最大成本来源（超大图），缩放是第二层优化

### 3. 会话持久化（Message.attachments）

消息序列化格式（session.zig serializeMessage/parseMessage 扩展；Message 序列化在 session 层，types.writeJson 是 ToolMeta 序列化器，与本字段无关）：

```json
{"id":4,"role":"tool","content":"Image file: shot.png (…).","tool_call_id":"c1",
 "attachments":[{"mime":"image/png","data":"iVBORw0KGgo…"}],"meta":{…}}
```

- **写入时省略**：`attachments` 为 null 时**序列化省略该字段**（对齐 `reasoning_content`/`meta` 既有 null 省略模式）——旧版本客户端/旧文件读不到该字段，格式向后兼容；解析端缺字段 → null（惰性，无迁移）
- 附件随 tool 消息走既有 `dupMessage`（handler.zig:1463 扩展）与 session append 的 **arena 深拷贝**：`mime`/`data` 均 dupe 到目标 allocator（对齐 meta 的 arena-duped 契约，types.zig:24 "Arena-duped on append/load — never a borrow"）；ToolResult 原附件由 result deinit 释放，session 持独立拷贝（无共享指针）
- 工具消息的 `content` 仍为文本摘要——**模型 transcript 不直接持有 base64**（对齐 opencode：附件是消息 part 而非文本）

**会话文件膨胀（评论提示，登记未来优化）**：多图内联 base64（原始 ≤5MB → base64 ~6.7MB/张）会快速增长会话文件——单次可控，但长会话多图场景需关注。当前设计可接受（对齐 opencode 亦全量落盘），**配置模板注释提示用户**"图片附件以 base64 内联持久化，会增大会话文件"；未来优化登记 F24（附件外置存储/会话级清理策略，需评估与 fork/branch/export 的关系）。

### 4. provider 请求注入 + input modality 门控

opencode 无模型级门控（`validateMedia` 只按 provider IMAGE_MIMES 白名单校验；模型不支持时 API 报错）。**我们加门控**（差异改进）：非 vision 模型收到 `image_url` 会 API 报错，切换模型即坏——按模型声明控制注入：

| 方案 | 优点 | 缺点 |
|------|------|------|
| A 无条件注入 | 实现最简单 | 非 vision 模型（当前 DeepSeek V4 配置）必坏，切换模型即回归 |
| B input modality 门控 | 模型声明驱动，行为稳定 | ProviderConfig 需携带模型 input 信息 |

**选择**：方案 B。`Provider.Config` 加 `input_modality: []const types.InputModality`（init/setModel 从 `*const types.Model` 填充，两处都有模型指针）；`buildJsonBody` 消息含附件且 `input_modality` 含 `.image` 时才构造 content 数组：

```json
{"role":"tool","content":[{"type":"text","text":"Image file: …"},
 {"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0…"}}]}
```

**opencode 的原始做法（已修订，见下）**——opencode 在 provider 请求转换层检查 `model.capabilities.input`：不支持时 media part 替换为 `ERROR: Cannot read "<name>" (this model does not support image input). Inform the user.`。

**非 vision 模型：系统层拦截（改进 opencode 的错误文本替换）**——opencode 在 provider 转换层把 media part 替换为 `ERROR: Cannot read...` 错误文本。**评论修订**：错误文本混入工具内容会干扰模型推理（模型可能试图"修复"）。改进方案：
- **provider 层**：门控失败（附件 + 非 vision）→ 不注入 image_url，content **保持 read 摘要文本**（文件名/大小是事实信息，非错误）
- **agent 层**（runTurn 组装请求数组处——agent.zig:319 `const msgs = self.session_ref.messages()` 与 chat 调用之间）：扫描到"带附件但当前模型非 vision"的消息 → **临时注入请求消息数组**（在数组前插入系统消息，arena 分配）`[Notice: This model does not support image input — image attachments were read but not sent. Switch to a vision-capable model to read images.]`（幂等：本 turn 数组注入一次）
- **持久化策略（评论修订）：临时注入，不写 session 历史**——text-only → vision 切换后历史中不留残留 Notice，避免模型误以为当前仍不支持图片（对比 StormBreaker 的 session 持久化——能力边界是模型相关的瞬态事实，随模型切换失效，必须临时）
- 效果：模型看到事实摘要 + 系统级能力边界说明（不污染工具内容、不需要"修复"），行为优于 opencode 的文本替换（记录为偏离改进）

**附件注入前校验（防御非法请求）**：
- `mime` 不在图片白名单（image/png|jpeg|gif|webp）→ 跳过该附件
- `data` 校验：**忽略空白字符（`\r\n\t` 与空格——RFC 4648 允许行折叠，标准编码器不产生但手工/外部来源可能有），其余字符必须 ∈ base64 alphabet（`[A-Za-z0-9+/=]`）**；空 data（去空白后长度为 0）→ 跳过该附件（注：我们不在注入点解码 base64——解码由 API 端执行，故"解码失败"降级为"字符集校验失败跳过"）
- **多附件累计守卫（分层，单位明确）**：**工具层为主**——read 单文件 5MB 上限已保证单附件合规；未来支持"一次 read 多文件"时，**累计校验在工具层生成 ToolResult 前执行**（超限附件不产出，避免 provider 层"部分成功"的模糊反馈）；provider 层保留累计校验作为**最终防御**（针对持久化/手工数据），正常路径不触发。**累计单位：原始字节总大小 ≤ 5MB**（非 base64 长度——base64 膨胀 33% 不参与守卫，守卫的是解码后实际数据量）

非 vision 模型 → content 保持摘要文本（不注入附件），agent 层注入系统 Notice（见上）。**边界声明**：当前默认配置（DeepSeek V4 input=["text"]）下 read 图片返回摘要 + Notice（无附件注入），配置 vision 模型（`input=["text","image"]`）后激活视觉。

**配置错误边界**（对齐 opencode：能力声明是信任边界，无运行时探测）：
- 声明 `image` 但模型实际不支持 → image_url 注入 → API 400 报错透出（与 opencode 行为一致，错误提示用户改配置）
- 漏声明 `image`（模型支持但未配）→ 附件不注入（保守方向，无 API 错误）
- 未知枚举值（如 `input=["text","video"]`）→ `parseInputModality` 静默跳过——**本期补未知值警告**（对齐 title_stop_words/approval_allow 既有警告模式：stderr 打印 `warning: input modality "video" ignored (expected text|image)`），防用户误以为已声明

### 5. 渲染

- **Web（reload 路径）**：tool 卡渲染时若有附件（session GET 已序列化消息），卡内显示 `<img src="data:<mime>;base64,<data>">`（对齐 opencode file-media 内联渲染）。**流式路径不传字节**：tool_meta 事件保持数值摘要（base64 走 SSE 膨胀浪费），实时流的 read 卡图片靠用户点 Preview（raw 端点）查看，reload 后内联显示
- **CLI**：tool 卡附件显示 `[image: image/png, N bytes]`（render.zig toolMetaLabel 扩展），不打印 base64

### 6. 门控落点与配置文档

config 模板 `input` 注释补充 vision 模型示例（`input = ["text", "image"]`，标注"多模态模型必须声明 image 才会注入图片附件；DeepSeek V4 当前为 text-only"）。REMAINING 登记 N22。

### 7. 图片缩放（未来扩展，对齐 opencode photon.ts）

**opencode 存在完整缩放模块**（源码验证）：
- `packages/core/src/image/photon.ts`：解码 → 尺寸/字节超限检查 → 超限时生成 **32 档递减尺寸**（步进 ×0.75，Lanczos3 采样）→ 每档尝试 **PNG 原始 + JPEG 质量 [80,85,70,55,40] 候选编码** → 首个 ≤`max_base64_bytes` 的候选返回（PNG 保透明度，JPEG 降质量压缩）；全失败 → 类型化 SizeError
- 配置（`v1/config/attachment.ts`）：`attachments.image = { auto_resize(默认 true), max_width(默认 2000), max_height(默认 2000), max_base64_bytes(默认 5242880) }`；`auto_resize=false` 时超限直接拒绝
- 测试：tool-read.test.ts（缩放至配置尺寸）、image.test.ts（5MB fixture → ≤2000×2000；无候选适配报错）

**动机**：vision 模型按图片尺寸/图块计费，原样发送大图烧 token——缩放是成本控制核心环节。

**本期不做**（完整缩放），登记 future（P2 独立计划）：**F23** vendored 纯 C 库（stb_image 解码 + stb_image_resize2 缩放 + stb_image_write 编码 PNG/JPEG）实现对齐 photon.ts 的"尺寸档 × 编码质量候选"策略 + `attachments.image` 配置节；依赖：N22 附件链路 + N22 尺寸守卫（N22 已用纯头部解析拦截短边 >2000px，缩放是第二层优化——超大图已拒绝，剩余是 1000-2000px 中等图的降本）。

## 实施

### 步骤 1: 附件类型 + ToolResult/Message 挂载

**文件**: `src/types.zig`
**改动**: 新增 `Attachment`；`ToolResult.attachments`（deinit 释放）；`Message.attachments`（默认 null）；`writeJson` 不涉及（附件在 session 层序列化）

**注意**: ToolResult 不可浅拷贝契约（args_owned）延续——attachments 由 tool 用 arena 分配，随 result deinit 释放，agent append 时 dup 进 session arena

### 步骤 2: read 图片附件

**文件**: `src/tool/read.zig`
**改动**: 图片分支 magic bytes 确认 → **头部尺寸解析（PNG/GIF/JPEG/WEBP 纯头部，零依赖）→ 短边 >2000px 拒绝附件化（摘要注明）** → 读全量（≤5MB）→ base64 → `ToolResult.attachments`；超限回退纯摘要；magic 不匹配回退 binary 拒绝路径
**关键代码**:

```zig
const MAX_IMAGE_BYTES: usize = 5 * 1024 * 1024;
const MAX_IMAGE_SIDE: u32 = 2000; // 对齐 opencode max_width/max_height 默认
// sniffImageMime(header): PNG/JPEG/GIF/WEBP magic → ?[]const u8
// imageDimensions(header): 头部解析宽高 → ?{w, h}（JPEG 扫 SOF 段）
```

**测试**: png 附件 base64 可解码回原字节；.jpg 伪装为 .png 时 MIME 以 magic 为准（image/jpeg）；纯文本改名 .png → 拒绝路径（magic 不匹配）；>5MB 回退摘要无附件；**短边 >2000px 拒绝附件化（摘要含 "too large"）；长图（4000×400）不误伤（短边 400 ≤2000）；四格式头部解析正确；损坏头部（magic 对但结构坏）保守拒绝**；.JPG 大小写

### 步骤 3: 会话持久化

**文件**: `src/core/session.zig` + `src/frontends/web/handler.zig`
**改动**: session.zig **serializeMessage/parseMessage 扩展附件字段**（Message 完整序列化在 session 层，与 ToolMeta 的 types.writeJson 无关——审查修订）；**null 时序列化省略字段**；旧文件缺字段 → null；消息 arena dup 扩展附件（mime/data 均 dupe，对齐 meta 契约）；handler.zig `dupMessage`（1463）扩展附件深拷贝（undo 栈路径）
**测试**: roundtrip 保留附件；**null 附件序列化省略（字节比对无 "attachments" 键）**；旧格式兼容；undo delete 带附件消息恢复后附件完整

### 步骤 4: provider 注入 + 门控

**文件**: `src/io/provider.zig`
**改动**: `Config.input_modality` + init/setModel 填充 + buildJsonBody 附件分支（content 数组 + `data:` URL 拼装）
**关键代码**:

```zig
if (msg.attachments) |atts| {
    // input_modality 含 .image 时构造 [{type:text},{type:image_url,…}] 数组
}
```

**测试**: vision 模型 body 含 image_url 结构合法；text-only 模型 content 纯文本（门控，无 image_url）；**agent 层 Notice 幂等注入（本 turn 数组一次、不写 session、下回合无残留）**；多附件数组；空/损坏 data 跳过；累计超限跳过

### 步骤 4.5: agent 层临时 Notice 注入（非 vision 门控配套）

**文件**: `src/core/agent.zig`
**改动**: runTurn 组装请求数组处（agent.zig:319 `const msgs = self.session_ref.messages()` 与 chat 调用之间）——扫描请求消息含附件且 `provider_ref.config.input_modality` 不含 `.image` → 构造 `[Notice: This model does not support image input — image attachments were read but not sent. Switch to a vision-capable model to read images.]` 系统消息**临时插入请求数组**（arena 分配，不写 session 历史——模型切换后无残留）
**关键代码**:

```zig
// msgs → request_msgs：检测附件 + 非 vision → 数组前插 Notice（arena）
```

**测试**: 非 vision + 带附件消息 → 请求数组含 Notice（session 消息数不变）；vision → 无 Notice；幂等（同 turn 一次）

### 步骤 5: Web 渲染 + CLI 摘要

**文件**: `src/frontends/web/app.js`（tool 卡 reload 附件渲染）、`src/frontends/cli/render.zig`（附件摘要行）
**改动**: session GET 已透出消息（含附件）→ app.js 渲染 `<img data:>`；CLI toolMetaLabel 加附件摘要
**测试**: 前端 tool 卡附件渲染断言（Node 测试）

### 步骤 6: 文档与登记

**文件**: `src/config.zig` 模板注释、`src/config.zig` parseInputModality（未知枚举值警告）、`docs/REMAINING.md`（N22 登记）、`docs/0.2.8/PLAN-N22-VISION-ATTACHMENTS.md`（本文档状态更新）
**改动**: input 注释补 vision 示例 + 配置错误边界说明；parseInputModality 未知值 stderr 警告（对齐既有警告模式）；REMAINING N22 登记

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache
node tests/frontend/run-tests.mjs
```

| 测试场景 | 预期结果 |
|----------|----------|
| read png/jpg（vision 模型） | provider body content 数组含 image_url + data URL，base64 可解码回原字节 |
| read 图（text-only 模型，当前默认配置） | content 保持摘要；**不注入 image_url**；agent 层注入一次 `[Notice: ... does not support image input ...]` 系统消息（幂等） |
| >5MB 图片 | 回退摘要，无附件，不报错 |
| **扩展名伪装（.txt→.png / .png 实为 jpg）** | magic 判定真实 MIME；伪装文本文件走拒绝路径（不附件化） |
| **空/损坏 data（空串、含非法字符）** | provider 跳过该附件，无 image_url；**含 `\r\n\t` 空白的合法 base64 不误判（容忍行折叠）** |
| **短边 >2000px 大图** | 不附件化，摘要含 "too large ... use Preview to view"；**长图（4000×400）正常附件化（短边 400）** |
| **头部损坏（magic 对但结构异常）** | 保守拒绝附件化（不产生坏请求） |
| **多附件累计超 5MB（构造数组）** | 超限附件跳过，不生成非法请求 |
| 会话 roundtrip | 附件随 tool 消息持久化/加载一致；**null 附件序列化省略该键**；旧会话文件无附件字段不崩 |
| Web reload | tool 卡内联显示图片；流式期间 read 卡正常文本+Preview 按钮 |
| CLI | 附件行 `[image: image/png, N bytes]` |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/types.zig` | Attachment + ToolResult/Message 挂载 | 否（默认值兼容） |
| `src/tool/read.zig` | 图片分支附件化 + magic/尺寸守卫 | 否（文本行为增强） |
| `src/core/session.zig` | 附件序列化/parse/dup | 否（缺字段兼容） |
| `src/core/agent.zig` | 非 vision 临时 Notice 注入 | 否（仅请求数组构造） |
| `src/io/provider.zig` | Config 字段 + body 分支 | 否 |
| `src/frontends/web/handler.zig` | dupMessage 附件深拷贝 | 否 |
| `src/frontends/web/app.js` | tool 卡渲染 | 否 |
| `src/frontends/cli/render.zig` | 附件摘要 | 否 |
| `src/config.zig` | 模板注释 + parseInputModality 警告 | 否 |
| `docs/REMAINING.md` | N22 登记 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| 附件（attachment） | 工具结果/消息携带的媒体数据（mime + base64），注入模型请求的图片内容块 |
| media part | opencode 消息中的媒体内容块（`{type:"media", mediaType, data}`），对应 OpenAI `image_url` |
| input modality | 模型输入模态声明（text/image），config `input` 字段，本方案作为附件注入门控 |
| 门控（gating） | 按模型声明过滤附件注入——非 vision 模型不发送 image_url |
