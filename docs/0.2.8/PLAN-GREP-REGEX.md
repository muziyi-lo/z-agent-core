# Plan GREP-REGEX: grep 正则支持（N20）

## 状态: ✅ 已完成（2026-08-15，REMAINING N20 已标记实施）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 问题

**现象**：grep 工具描述写 "Substring or pattern to search for"，但 `grep.zig:134/208` 是 `std.mem.indexOf` 纯子串匹配——LLM 写 `fn.*foo` 期望正则语义时得到零匹配（OPT-3-RENDER-TOOLS.md:405-409 已记录该痛点），浪费回合。

**根因**：OPT-3 曾采纳 `std.regex.Regex` 替代子串（PLAN-OPT-3-RENDER-TOOLS.md:415），但 **Zig 0.16 已移除 `std.regex`**（AGENTS.md 陷阱表确认），替代方案未定 → 计划搁浅。REMAINING N20 登记：自实现轻量正则（项目有 htmlToMarkdown 等手写解析先例）或子串+通配符增强。

## 概览

- **改动文件**：新增 `src/util/regex.zig`（轻量正则引擎 + 单测），修改 `src/tool/grep.zig`（两处匹配 + 工具描述）
- **新增 vs 修改**：1 新增 + 1 修改
- **一句话方案**：手写正则引擎（显式语法子集 + 非锚定搜索 + 字面量前缀加速 + 失败记忆化 + 按输入规模缩放的步数预算），grep 编译一次逐行复用；不支持语法编译期报错（结构化 code+pos + 修复指引）
- **参考实现**：opencode grep（ripgrep 正则语义）；语法子集对齐 POSIX ERE 常用子集

## 不做

- **反向引用**（`\1`）、**前瞻/后顾**（`(?=)`/`(?<=)`）、**模式标志**（`(?i)`）、**`\p{...}`**、**原子组/占有量词**——编译期明确报错而非静默
- **外部二进制**（ripgrep/PCRE）——安装复杂度，R9 已否决
- **`\A`/`\z`/`\B`**（词边界只做 `\b`）
- **大小写不敏感选项**（`(?i)` 之外无开关）——grep 参数面不扩展
- **工具参数扩展**（不加 `regex: bool` 开关）——对齐 ripgrep：pattern 恒为正则
- **错误自动补全 / 内容级 Did-you-mean**（评论者讨论后排除）：不做静默补全（如 `(foo` → `(foo)`）——补全猜测可能错误，静默修正后 LLM 基于错误模式继续行动，比显式报错更糟；内容级建议（推断意图）成本高且有误报风险（错误建议比无建议更误导）。**替代方案已采纳**：errorDetail 静态修复指引（按错误类型模板化建议，零推断、零误报——见错误处理节）

## 设计要点

### 引擎选型：递归回溯 vs Thompson NFA

| 方案 | 优点 | 缺点 |
|------|------|------|
| A 递归回溯 | 实现简单（~300 行）、行为直观（贪婪语义与主流引擎一致） | 最坏 O(2^n) 灾难性回溯 |
| B Thompson NFA | 线性时间无回溯风险 | 实现复杂（~500+ 行）、贪婪/回溯语义实现繁琐、量词扩展成本高 |
| C 子串+通配符增强 | 最简 | 与正则预期差距大（`fn.*foo` 语义仍不满足） |

**选择**：方案 A 递归回溯（组/交替嵌套递归）+ **失败记忆化（memoized failure）** + 按输入规模缩放的步数预算双防线；顺行链与量词重复**迭代实现**（零递归，见递归深度节）。依据：grep 按行匹配（行长通常 <4KB），`(node, pos)` 状态空间有限，同一状态被重复计算是 O(2^n) 的根源——只缓存失败结果（成功不缓存：贪婪回溯需尝试不同消费长度，失败则确定性可复用）即可把指数降为多项式，而**记忆化惰性启用**（步骤超 `MEMO_THRESHOLD` 才创建哈希集）保证正常模式零分配零开销。预算（`MATCH_STEP_BASE` + `RATIO × 输入字节`）退化为兜底而非唯一防线。方案 B 留作未来若需完整 ECMA 语法再评估。

### 递归深度限制（评论者采纳）

`matchNode` 在组/交替**嵌套**处递归（嵌套组 `((((a))))` 使递归深度随嵌套增长）——恶意/极端模式可能栈溢出。顺行链与量词重复均迭代实现（见 AST 节），递归深度仅来自嵌套。双防线：

| 防线 | 机制 | 效果 |
|------|------|------|
| 编译期（主） | parse 递归带 `depth` 参数，组嵌套 > `MAX_NEST_DEPTH`（64）→ 编译错误 `nesting_too_deep` | 恶意模式编译期拒绝；匹配期嵌套递归深度 ≤ 组深度（顺行链/重复已迭代化，不产生递归） |
| 运行时（副） | `matchNode` 嵌套递归传 `depth` 参数，> `MAX_MATCH_DEPTH`（128 = 64×2 余量）→ `error.MatchLimitExceeded`（复用现有熔断语义，无需新错误码） | 防御编译期限制遗漏的路径；栈帧 ≤128 × ~200B ≈ 25KB，安全 |

**为什么组深度限制即全覆盖（修订：评论者指出论证缺口后补全）**：匹配递归来源三类的实现契约——① 组/交替**嵌套**（递归，深度 ≤ 组深度，受 MAX_NEST_DEPTH/MAX_MATCH_DEPTH 守卫）；② **顺行链**（matchSeq 沿 next 链，**迭代**实现，零递归——1 万字面量模式不再产生万层栈帧）；③ **量词重复**（repeat **迭代**回溯栈，零递归——`a*` 对长行无界重复安全）。①②③ 合并：递归深度上界 = 组嵌套深度，原论证在实现契约约束下成立。

**与既有先例一致**：对齐 `jsonw.zig` 的 `max_depth = 16`（容器嵌套深度编译期/构造期检查防栈溢出）——同思路（构造期检查嵌套深度），不同值（jsonw 16 = 序列化容器；本方案 64 = 正则组嵌套，均远低于栈安全线）。

### 字面量前缀快速失败（Literal Prefix，评论者采纳）

grep 场景绝大多数行**不**匹配——每行完整回溯匹配（即使最终失败）成本远高于一次 `indexOf`。编译期提取**确定性必含字面量前缀**，匹配前预检：

**提取规则**（compile 时，从 root 沿 next 链）：

| 节点类型 | 是否纳入前缀 | 理由 |
|----------|-------------|------|
| `literal`（含转义字面量） | ✅ 追加（code point 编码回 UTF-8 字节） | 任何匹配必须包含此序列 |
| `any`/`class`/`group`/`alt`/`repeat`/`anchor_start`/`anchor_end`/`word_boundary` | ❌ 停止提取 | 不保证具体字面量（`a|b` 的 a 可被 b 替代；`a*` 可消费 0 个；`^` 限定位置） |

**预检执行**（match 入口）：**非锚定扫描天然复用前缀**——`match` 顶层按"前缀命中位置"驱动：`i = indexOf(text, prefix)`，从每个 `i` 执行 `matchSeq(root, i)`，失败则 `i = indexOf(text, prefix, i+1)` 继续（正确性：任何匹配必含前缀 → 前缀零命中 ⇒ 行不匹配）。**无前缀时**退化为逐 pos 扫描（见 AST 节 match 顶层语义）。**预检失败即行不匹配**；命中位置仍需 `matchSeq` 完整验证（含锚点/交替约束）。

**完备性论证（评论者核心关切——加速成功路径且不遗漏）**：匹配成功的**起点必然在前缀命中位置**——模式开头是纯字面量序列（提取在非 literal 节点停止），任何匹配都必须从该序列第一个字节开始消费 → 匹配起点 ∈ 前缀命中位置集合。因此"只在前缀命中位置尝试"是**完备的**（无遗漏），且成功路径同样加速（尝试点从 O(n) 降为前缀命中数），非仅失败排除。命中位置是假起点（该处完整匹配失败）→ 跳过继续下一个命中位置——无回溯跨前缀遗漏。

**收益**：不匹配行从"完整回溯"降为"一次 `indexOf`"（O(n) 极快路径）；`fn.*foo` 提取前缀 `fn`、纯字面量模式 `foobar` 前缀即全文（命中位置处 matchSeq 仍完整验证但几乎必然通过）。**提取为空（`^` 锚点开头、`a|b` 顶层交替、`a*` 量词开头、`(foo)` 组开头、空模式）→ 退回逐 pos 全位置扫描**——正确性不受影响，仅无加速（如 `(foo)` 保守不提取，性能次优但正确）。

**存储**：`Pattern.prefix: []const u8`（arena 分配，deinit 随 arena 释放）。

### 失败记忆化（评论者采纳）

**正确性依据**：`matchNode(node_idx, pos)` 的输出只依赖这两个参数（`steps` 计数不影响结果语义）——同一 `(node, pos)` 失败后，任何再次调用必然失败，可安全缓存剪枝：

- **缓存内容**：仅失败状态（`(node_idx, pos)` → failed）。成功不缓存——同一状态可能产生多个成功结果（不同消费长度，贪婪回溯按长度递减尝试），缓存成功需记录长度集，收益低复杂度高
- **数据结构**：`std.AutoHashMapUnmanaged(MemoKey, void)`，`MemoKey = struct { node_idx: u32, pos: u32 }`（评论者修订：结构体 key 替代 u64 拼接——语义直接表达 `(node, pos)` 两维，不依赖"拼接不溢出"论证；哈希表内部碰撞由 `getAutoHashFn` 逐字段哈希解决，表内探测正确性不受影响）。**边界假设**：`pos < 2^32`（行长度上限 = 文件大小上限 1MB/512KB，远小于 4GB），`node_idx < 2^32`（节点数 ≤ 数千）——`@intCast` 安全，文档明示
- **惰性创建**：`MEMO_THRESHOLD = 2_000` 步内不分配（零分配契约保持——99.99% 行在阈值内完成匹配）；超阈值才 `allocator.alloc` 创建，`deinit` 于同次 match 返回前（**memo 生命周期 per-line，预算 per-call 并存**：每行 key 空间含该行 text_len，重建正确；恶意模式下每行重建 memo 有分配成本，但比例预算会很快熔断，重建次数有限可接受）。`allocator` 参数为 `?std.mem.Allocator`，null = 禁用记忆化（纯回溯路径，供测试验证行为等价）
- **效果推演**：`(a+)+b` 对 `a^n`——原 O(2^n)；记忆化后每个 `(a+, pos_k)` 失败只计算一次 → O(n²)；实测长输入快速返回 false，步数预算不再触发

```zig
// match 内部（伪代码）：
const MemoKey = struct { node_idx: u32, pos: u32 };
var memo: ?std.AutoHashMapUnmanaged(MemoKey, void) = null;
defer if (memo) |*m| m.deinit(allocator);
// matchNode 入口：memo 存在且 contains(key) → return null（已失败）
// matchNode 全路径失败后：memo 存在 → put(key)（分配失败静默忽略，退回纯回溯）
```

### 语法子集（第一版）

| 类别 | 语法 | 语义 |
|------|------|------|
| 字面量 | `a` `1` 等非特殊字符 | 匹配自身 |
| 任意字符 | `.` | 匹配任意单字符（**code point**，中文 3 字节 = 一个字符；Unicode 策略见下节） |
| 锚点 | `^` `$` | 行首/行尾（grep 按行匹配，`$` 即行尾） |
| 字符类 | `[abc]` `[^abc]` `[a-z]` `[0-9_]` | 成员/取反/范围；边界语义见下节 |
| 分组 | `(...)` | 仅分组（捕获内容不使用），嵌套支持 |
| 交替 | `a\|b` | 左分支优先，顶层与组内均支持 |
| 量词 | `*` `+` `?` `{n}` `{n,}` `{n,m}` | 贪婪（回溯递减）；`*`/`+`/`?` 前项必须可重复（否则编译错误）；**`{n,m}` 数值 ≤ `MAX_QUANTIFIER_LIMIT`（1000）**——`a{1,1000000}` 编译期报错而非运行时熔断（评论者采纳：错误更早暴露、反馈更明确；贪婪大数值会单行消耗海量步数，步数上限虽兜底但报错语义模糊） |
| 类转义 | `\d` `\D` `\w` `\W` `\s` `\S` | 数字/词字符/空白及其取反 |
| 词边界 | `\b` | 零宽断言：pos 处前后字符词属性变化 |
| 字面转义 | `\.` `\*` `\\` `\|` `\(` `\)` `\[` `\]` `\{` `\}` `\^` `\$` `\+` `\?` `\-` `/` | 特殊字符转义为字面量 |

### 行输入契约（评论者问询）

`.` 与 `$` 的语义依赖"行内无换行符"——核实 grep 既有逐行迭代（grep.zig:130-133）：

```zig
var lines = std.mem.splitScalar(u8, file_content[0..n], '\n');  // 按 \n 分割
const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;  // 剥尾部 \r
```

| 假设 | 保障机制 | 结论 |
|------|----------|------|
| 行内无 `\n` | `splitScalar('\n')` 分割段不含分隔符（std 语义保证） | `.` 匹配任意 code point ✓（见 Unicode 策略节）；`$` = `pos == line.len` ✓ |
| 行内无尾部 `\r` | L133 显式剥除（CRLF 文件） | `$` 不被 `\r` 干扰 ✓ |
| 行中间 `\r` | 未剥除（仅尾部处理） | `.` 可匹配中间 `\r`——与既有子串匹配行为一致，不特殊处理 |

**结论**：`match` 的 `text` 参数契约 = "单行、不含 `\n`、无尾部 `\r`"（由 grep 行循环保证，regex 库不自行剥除）；`^` 匹配 pos 0、`$` 匹配 pos == text.len。regex.zig 单测直接用无换行文本，grep 集成测试用 CRLF 文件验证 `$` 行为。

### Unicode 策略（code-point 匹配 + ASCII 类转义）

`. ` 与字符类的 Unicode 行为必须显式（此前文档"任意单字符…等价任意字节"模棱两可）：

| 规则 | 语义 | 依据 |
|------|------|------|
| **匹配单位 = code point** | 匹配前对 text 按 UTF-8 解码：`.` 消费一个 code point（中文 3 字节 = 一个字符）；字面量按 code point 比较；量词按 code point 计数（`中{2}` = 两个中文字符） | LLM 预期语义（`.` 匹配"一个字符"）；对齐 opencode/ripgrep 的 Unicode 感知默认 |
| **pos 以字节计** | text 是原始字节切片，匹配消费量 = 该 code point 的 UTF-8 字节数 | 与 grep 行切片（字节）自然衔接 |
| **非法 UTF-8** | `utf8Decode` 失败 → 该字节按单字节 code point 处理（消费 1 字节），行为确定不崩溃 | grep 文件可能含任意字节（grep 无二进制检查） |
| **字符类按 code point** | 成员/范围端点按 code point 值比较（`[一-龥]` 合法）；`Node.literal: u21`、class 范围端点 `u21` | 模式侧解析时同样解码 |
| **`\d` `\w` `\s` = ASCII 定义** | `\d`=[0-9]；`\w`=[a-zA-Z0-9_]；`\s`=空格 `\t` `\r`（行内无 `\n`）——**不**含 Unicode 数字/字母（`１` 全角数字不算 `\d`）；取反同理 | 与 PCRE 无 Unicode 标志一致；完整 Unicode 属性表超出子集引擎成本 |
| **`\b` 基于 `\w`（ASCII）** | 词边界判定用 ASCII 词字符集——中文两侧**无**词边界（"中文"中 `\b` 不匹配） | `\b` 与 `\w` 定义同源 |
| **大小写** | 无折叠：`[A-Z]` 仅 ASCII 大写；不支持 `(?i)` | 子集边界（不做即明确报错） |

**实现影响**：`Node.literal: u21`（code point，见 AST 节）；`Class` 范围端点 `u21`；matchNode 的 literal/any/class 分支需解码 text 当前位置（`std.unicode.utf8Decode`，失败退化为单字节）。测试覆盖：`.` 匹配中文（3 字节消费）、`[一-龥]` 范围、`中{2}` 量词、`\d` 不匹配全角数字、非法 UTF-8 字节不崩溃。

### 字符类边界语义（POSIX 约定，评论者采纳）

字符类 `[...]` 的边界歧义最高，逐条明确（解析器与 LLM 均按此契约）：

| 模式 | 语义 |
|------|------|
| `[]a]` | 类内**第一个位置**的 `]` 是字面量成员 → 集合 {`]`, `a`} |
| `[-a]` / `[a-]` | `-` 在**首或尾**位置是字面量成员 → {`-`, `a`} |
| `[a-z]` | 范围（按 code point 升序） |
| `[z-a]` | **编译错误** `invalid_range`（降序范围） |
| `[a-\d]` | **编译错误** `invalid_range`（范围端点必须是单字符字面量，类转义不可作端点）——报错文案引导修正：`invalid character range (range endpoints must be literal characters; e.g. write [a0-9] instead of [a-\d])`（评论者建议：LLM 从错误信息直接得知正确写法） |
| `[^a]` / `[^]a]` | `^` 首位置取反；取反后首 `]` 仍是字面量成员 |
| `[]` | **编译错误** `unterminated_class`（首 `]` 是成员，缺闭合 `]`） |
| `[a-a]` | 合法（单字符范围 = 成员 `a`） |
| `[[]` / `[a[b]` | `[` 在类内是普通字面量成员（非嵌套类） |
| `[\]]` `[\\]` `[\-]` | 转义字面量成员 |
| `[\d\w\s]` | 类内类转义（成员并集：数字 ∪ 词字符 ∪ 空白） |

**解析算法要点**：成员解析循环从 `[` 后开始——首个字符是 `]` 则按字面量成员处理；遇 `-` 时仅当"前有成员 + 后跟非 `]` 字符"才构成范围，否则字面量；范围两端必须是单字面量字符（字面量或转义字面量）且 `a <= b`（code point），违反 → `invalid_range`。类内不支持 `-` 范围使用类转义端点（`[a-\d]` 报错而非猜测语义）。

**不支持语法 → 编译错误**：`\1`（反向引用）、`(?=...`（前瞻）、`(?!...`（后顾）、`(?i`（标志）、`\p{`、`\A`、`\z`、`\B`、`\Q`——`compile` 返回 `CompileResult.err`（显式结果联合，错误值无载荷故不走 error 联合），错误为结构化 `{code: CompileErrorCode, pos}`（错误码枚举 + 0-based 位置），grep 按 code 映射文案并注入 pos 格式化（如 `.unsupported_construct` → `unsupported construct at position 5`）。**编译器强制处理 err 分支**——错误不可丢失，LLM 得到明确反馈后自纠（对齐 opencode/ripgrep 报错闭环）。

**交替优先级**：交替最低，`^`/`$` 只作用于表达式顶层（`^a|b$` = `(^a)|(b$)`，与 POSIX 语义一致——实现时顶层是交替，锚点在分支内）。

**空交替语义（评论者问询）**：POSIX ERE 允许空交替分支。三形态统一由 `?usize = null` 表达：

| 模式 | 解析（左结合） | 匹配语义 |
|------|----------------|----------|
| `a\|`（右空） | `alt{a, null}` | 匹配 `a` 或空 → 恒可匹配（空分支兜底） |
| `\|a`（左空） | `alt{null, a}` | 同上（空分支兜底） |
| `a\|\|b`（中间空） | `alt{alt{a, null}, b}`——parseAlt 的 while 循环逐项 emit，每轮新 alt 节点成为下轮 left → **左结合**，非右结合 | 左优先：尝试 `a` 失败 → 空分支立即成功 → **右分支 `b` 不可达**，`a\|\|b` ≡ `a\|`（恒匹配空） |

数学上正确（空交替 = 永真分支），但实现者须知：**含空分支的交替使模式恒可匹配空**（任何文本、任何位置），对 LLM 无实际用途但必须行为正确（不报错、不悬挂）。解析顺序 = 左结合是既定的（parseAlt 循环结构），测试锁定此形状。**使用侧提示已落实**：`tool_params` 描述明确警告"empty alternation branches (a|, |a, a||b) make the pattern match everywhere - avoid unless intended"（评论者建议）——LLM 误写时从工具描述即获知，而非零匹配后困惑。

### AST 表示与匹配

AST 为**节点数组 + next 链**（评论者采纳）：每个 `Node` 携带 `next: ?usize` 表达顺序连接（null = 链尾），组/交替指向首节点。`ab`（两个连续字面量）= 节点 0 `literal a`（next=1）→ 节点 1 `literal b`（next=null），`root` = 首节点索引。无显式 Sequence 变体——连接由 next 链表达。

```zig
const Kind = union(enum) {
    literal: u21,                       // code point（Unicode 策略节：字面量按 code point 比较）
    any,
    class: Class,                       // negated + ranges(分配)
    group: ?usize,                      // 组内容首节点（null = 空组，匹配空）
    alt: struct { left: ?usize, right: ?usize },  // 分支首节点（null = 空分支）
    repeat: struct { node: usize, min: usize, max: ?usize },  // 贪婪，作用于单原子节点
    anchor_start,
    anchor_end,
    word_boundary,
};
const Node = struct { kind: Kind, next: ?usize };
```

**链语义**：组内成员经 next 链连接、链尾 null 终止；组/交替节点作为**单原子**经自身的 `next` 接入外部链（`(ab)c` = 组节点 next=literal c）——内链与外链在组节点处分叉，互不干扰。空组/空分支以 `null` 表达（`()`/`a|` 匹配空），空模式 `root = null` 匹配一切（与当前 `indexOf("")` 行为一致）。

**引用方向保证（无悬空）**：编译递归下降按"组内容 → 组节点"、"左分支 → 右分支 → alt 节点"、"原子 → 量词节点"的顺序 emit——**所有引用都是后向**（引用目标先于引用者存在于数组）：

| 引用 | 形态 | emit 顺序保证 |
|------|------|---------------|
| 连接 `ab` | `literal a next→ literal b next→ null` | parseSeq 逐原子 emit，前节点的 next 指向后节点 |
| `(ab)` | `group: ?usize`（组内容首节点） | 先 emit 组内链，再 emit group 节点 |
| `a\|b` | `alt: {left, right}`（分支首节点） | 先 emit 左分支链，再右分支链，最后 alt 节点 |
| `a*` / `(ab)*` | `repeat: {node}`（原子节点索引） | 先 emit 原子，再 emit repeat 节点 |
| `^`/`$`/`\b` | 零宽节点（无消费） | 就地 emit |

**匹配**（无分配，步数计数由调用者持有传参）：

- `matchSeq(first: ?usize, pos, steps) !?usize`：**迭代实现（评论者指出的风险，修正）**——沿 next 链 `while` 循环逐节点 `matchNode`（**禁止递归实现**：长字面量序列如 1 万字面量 pattern 若递归则产生万层栈帧）；`first = null`（空序列）→ 返回 pos
- `matchNode(idx, pos, steps) !?usize`：switch 分派；`group` → matchSeq(组首, pos)；`alt` → matchSeq(left) 失败则 matchSeq(right)（左优先）；`repeat` → **迭代贪婪**（见下）；零宽节点（`^`/`$`/`\b`）校验条件后返回原 pos
- **`repeat` 迭代实现（无界递归源，评论者风险延伸修正）**：贪婪量词若递归实现（matchRepeat 递归尝试消费），递归深度 = 重复次数——`a*` 对长行、`a{1000}` 均无界/大深度 → 栈溢出。**修正为迭代**：matchSeq 内管理"回溯位置栈"——repeat 节点贪婪循环消费子节点并记录每次成功位置（消费前位置入栈），后续节点匹配失败时从栈回退上一位置重试（显式栈替代递归回溯）；repeat 匹配成功路径零递归
- **递归深度上界（修订后的完备论证）**：匹配递归仅发生在 matchNode 内嵌套（group/alt 内嵌）——顺行链（matchSeq 迭代）、重复（repeat 迭代）均零递归 → 上界 = 组嵌套深度 ≤ MAX_NEST_DEPTH（编译期）且运行时 MAX_MATCH_DEPTH 兜底
- **`match` 顶层 = 非锚定搜索（评论者指出的致命语义，修正）**：grep 行匹配语义必须对齐 `indexOf`——模式可出现在行内任意位置，不能只从 pos 0 尝试一次（否则 `"foo"` 匹配不了 `"xxfooxx"`）。扫描策略：
  - **有字面量前缀**：`i = indexOf(text, prefix)`，从每个命中位置 `matchSeq(root, i)` 尝试，失败 `i = indexOf(text, prefix, i+1)` 继续——尝试点从 O(n) 降为前缀命中数
  - **无前缀**：`for (pos in 0..text.len+1) { if (matchSeq(root, pos)) return true; }`——朴素扫描（含 pos = text.len，覆盖空匹配/`$`）
  - **锚点自然正确**：`^` 由 anchor_start 节点在非 pos 0 处失败、pos 0 成功；`$` 在 pos == text.len 成功——非锚定扫描下行为与 POSIX 一致（`^foo` 只匹配行首，`foo$` 只匹配行尾，`foo` 匹配任意位置）
  - **空模式/可空模式**：pos 0 处 `matchSeq` 立即成功（空匹配）→ 每行 true——与 `indexOf("") == 0` 一致
- **回溯正确性示例**：`(ab|a)b` 对 "ab"——alt 左分支 (ab) 消费 [0,2)，外层 b 失败 → 回溯 alt 右分支 (a) 消费 [0,1)，外层 b 消费 [1,2) ✓；`a.*b` 贪婪吃到行尾后回溯递减找到最后匹配的 b ✓
- **步数计数（契约，评论者两轮修订）**：计数器是 `match` 的**传入参数** `steps: *usize`（调用者持有），每次 `matchNode` 调用 +1。**预算按输入规模缩放（评论者修订）**：`effective_limit = MATCH_STEP_BASE(100k) + MATCH_STEP_RATIO(16) × 输入字节数`——**双检查点**：
  - **match 内部（单行）**：`steps > BASE + RATIO × text.len` → `error.MatchLimitExceeded`（match 必须返回——单行病态如 `(a+)+b` 对 100KB 行在记忆化下仍 O(n²) ≈ 10^10 步，靠 grep 侧事后检查无法阻止 match 不返回）
  - **grep 侧（累计）**：`bytes_scanned` 行循环累加（每行 `line.len`），match 返回后检查 `steps > BASE + RATIO × bytes_scanned` → 熔断（truncated + 复杂度文案，中断扫描）
  **设计理由**：正常逐 pos 扫描（无前缀模式如 `a|b`/`[ab]`/`a*`）步数 ∝ 输入字节（每字节 1-5 步）——固定 100k 预算对 512KB 文件（评论者算得 ~1.5M 步）会**误熔断**合理模式；按比例预算后正常线性成本永不触发（1.5M < 100k + 16×512k = 8.3M），仅**超线性回溯**（病态模式，步/字节 >> 16）熔断——预算语义从"总量上限"修正为"线性成本合法、超线性非法"。**预算粒度 = per-call**：计数器创建于 execute 顶层、跨文件跨行共享（恶意模式不会每行重获满预算）。`Pattern` 保持 `*const` 无内部可变状态——计数器生命周期在调用栈，多请求并发天然隔离

**所有权与复制契约（评论者两轮确认合并）**：`Pattern` 是**独占所有权（move-only）**类型——`arena` 内嵌持有 nodes 内存，**禁止浅拷贝/共享**（浅拷贝后两份共享同一 arena，任一侧 `deinit` 释放后另一侧悬垂，二次 `deinit` 双释放 UB）。该约束无法用运行时防御彻底拦截，靠**类型契约 + 使用纪律**：项目内唯一使用点是 grep.execute 局部变量，compile → 使用 → deinit 单路径。**深拷贝可行**：next 是索引而非指针，整块 `nodes` 数组 `dupe` 到新 arena 即完整的深拷贝（索引不变、链自动有效）——这是数据结构层"dupe 友好"的确切含义；但 Pattern 整体复制仍需先深拷贝 arena 内容，不改变"禁止浅拷贝"契约。契约写入 `Pattern` 定义处 `///` 注释（对齐 `ToolResult.args_owned` 不可浅拷贝先例）。

### 语义变化：子串 → 正则（G11 对比）

| 模式 | 当前（子串） | 实施后（正则） |
|------|-------------|---------------|
| `fn.*foo` | 零匹配（字面 `.*` 不存在） | 匹配 `fn` + 任意字符 + `foo` |
| `foo.bar` | 匹配字面 `foo.bar` | 匹配 `foo` + 任意单字符 + `bar`（`fooXbar` 也匹配） |
| `error.Error` | 匹配字面 | `.` 变任意字符 |
| 纯字面（无特殊字符） | 匹配 | **行为不变**（正则字面量 = 子串） |

纯字面量模式行为不变（大多数既有调用无影响）；含特殊字符的模式语义向 ripgrep/opencode 对齐。工具描述更新为 `Search for a regex pattern in file contents`，pattern 参数描述注明语法子集 + 不支持项。

### 错误处理（G10 跨模块合约）

`regex.zig` 暴露的错误集与 grep 的映射：

| 发送方 | 返回的错误/结果 | 接收方 | 匹配方式 | 处理行为 |
|--------|-----------|--------|----------|----------|
| `regex.compile` | `.err`（code + pos） | grep.execute | `switch` 强制分支 | `.err` → `regex.errorDetail(e.code)` 取文案（库内映射，switch 穷举全错误码），`allocPrint` 组合 `Error: invalid regex pattern '<pattern>': <detail> at position <pos>`；`.ok` → 持有 Pattern |
| `regex.compile` | `error.OutOfMemory` | grep.execute | `catch` 捕获 | 返回 `error.OutOfMemory` 上抛（既有工具 OOM 路径一致） |
| `regex.match` | `error.MatchLimitExceeded` | grep.searchFile/searchDir | `catch` 捕获（steps 由 grep.execute 创建传入，跨文件共享不清零；allocator 传 `ctx.allocator` 启用记忆化） | **双检查点熔断**：① match 内部单行超 `BASE + RATIO × text.len` → error 上抛；② grep 侧累计超 `BASE + RATIO × bytes_scanned` → 置 truncated、中断当前文件行循环与 searchDir 文件遍历（外层 `break :outer`），返回已收集部分（预算语义 = 线性成本合法、超线性熔断） |

grep 的错误消息走 ToolResult 既有机制（`session_content` 错误文案），无新跨模块 `!T` 传播（grep 已是 `anyerror!types.ToolResult`）。

### 生命周期（G14）

`Pattern` 生命周期枚举：

| 创建 | 销毁 | 覆盖 |
|------|------|------|
| `compile`（grep.execute 内，每次工具调用一次） | `.ok` 分支 `Pattern.deinit`（同一 execute 内 defer） | ✅ |
| `char_class.ranges`（compile 时分配） | 同 `Pattern.deinit` 释放 | ✅ |
| `CompileError`（code + pos） | **无分配，栈值**——无 deinit 义务 | ✅ 不适用 |
| 复制/共享（`var b = a`、按值传参、数组存储） | **禁止**——浅拷贝共享 arena，双 deinit 双释放（见所有权契约） | ✅ 禁止声明 |

**编译一次逐行复用**：searchFile/searchDir 开头 compile，循环内仅 `match`（零分配匹配，步数计数为调用者局部变量）——避免每行重复解析。

### 日志（G15）与错误输出通道（评论者问询）

**不集成日志，错误输出走 ToolResult**。分层依据：

| 层 | 错误输出通道 | 理由 |
|----|-------------|------|
| `regex.zig` | 结构化返回（`CompileResult` / `error.MatchLimitExceeded`） | 纯库零日志——对齐 util 层 jsonw/text 惯例，调用方决定去向 |
| grep 编译错误 | ToolResult 错误文案（code/pos 详情） | 工具错误反馈通道是 ToolResult（给 LLM 看），非日志（给开发者看）；用户/LLM 均可感知 |
| grep 预算熔断 | ToolResult 截断说明 `... (match complexity limit reached)` + `truncated` 标志 | 对齐既有 `... (max matches reached)` 截断风格——LLM 明确知道搜索不完整，可自行调整模式 |

依据：工具层（tool/*.zig）**零日志先例**（无任何工具 import log）；G15 判据三类（用户可见操作 create/delete/rename、跨组件边界 session 写盘/compact/subcall、生命周期切换 abort/undo/streaming）均不命中查询类工具。日志是系统级诊断（session/compact/SSE 生命周期事件），工具错误是模型级反馈——两者通道分离。若未来需诊断恶意模式，ToolResult 截断说明已可推断，届时再评估加 `log.biz_warn`（熔断事件：pattern + 已扫行数 + 步数）。

### G7 stdlib API 对照表（<5 个，手工对照）

| API | 位置（stdlib 源码） | 验证 |
|-----|--------------------|------|
| `std.heap.ArenaAllocator.init(child) ArenaAllocator` | std/heap/ArenaAllocator.zig `pub fn init` | ✅ 一致 |
| `arena.allocator() Allocator` | 同文件 `pub fn allocator` | ✅ 一致 |
| `arena.deinit()` | 同文件 `pub fn deinit(arena: ArenaAllocator) void` | ✅ 一致（注意 0.16 为值参数） |
| `std.AutoHashMapUnmanaged` | std.zig `pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged` | ✅ 一致（match 记忆化用，`init`/`put`/`contains`/`deinit` 均需显式 allocator） |
| `std.mem.splitScalar` / `std.mem.indexOf` | 既有 grep.zig 在用 | ✅ 一致 |
| `std.unicode.utf8Decode(bytes) Utf8DecodeError!u21` | std/unicode.zig `pub fn utf8Decode` | ✅ 一致（Unicode 策略匹配解码用；失败按单字节退化） |

其余全部为语言内建（union(enum)/switch/递归），无 std 依赖。

### 交互矩阵（G16）

单特性（正则支持）。与既有 grep 行为交叉：

| × | 正则匹配 | include glob 过滤 | 输出截断 |
|---|---------|------------------|----------|
| 正则匹配 | — | 无关（include 只过滤文件名，互不影响） | 无关（截断在匹配结果累积处，行数语义不变） |
| include glob 过滤 | | — | 无关 |
| 输出截断 | | | — |

## 实施

### 步骤 1: 新增 `src/util/regex.zig`（引擎 + 单测）

**文件**: `src/util/regex.zig`
**改动**: 完整实现引擎。关键签名：

```zig
// 递归深度防护（评论者采纳）：编译期拒绝深嵌套 + 运行时守卫兜底
pub const MAX_NEST_DEPTH: usize = 64;   // 编译期组嵌套上限（恶意模式编译期即拒绝）
pub const MAX_MATCH_DEPTH: usize = 128; // 运行时匹配递归上限（MAX_NEST_DEPTH × 2 余量）
pub const MAX_QUANTIFIER_LIMIT: usize = 1000;  // 编译期量词数值上限（评论者采纳：`{n,m}` 数值超限提前报错）
// 匹配步数预算（评论者修订：按输入规模缩放，正常线性扫描永不熔断）
pub const MATCH_STEP_BASE: usize = 100_000;    // 固定底数（覆盖小文件固定开销）
pub const MATCH_STEP_RATIO: usize = 16;        // 每扫描字节允许的步数倍数（线性成本余量，正常模式步/字节 ≈ 1-5）
pub const MEMO_THRESHOLD: usize = 2_000;      // 步骤超此值惰性创建失败记忆化集合
pub const RegexError = error{ MatchLimitExceeded };

pub const Pattern = struct {
    nodes: []Node,          // AST 节点数组（arena 分配，next 链即顺序）
    root: ?usize,           // 顶层链首节点（null = 空模式，匹配一切）
    prefix: []const u8,     // 字面量前缀（编译期提取，match 预检快速失败；空 = 无前缀）
    arena: std.heap.ArenaAllocator,  // compile 持有，deinit 整体释放
    pub fn deinit(self: *Pattern) void;
};
/// 编译错误（评论者修订）：结构化 `{code, pos}` 而非格式化 message——职责分离
/// （regex 报告"什么错、错在哪"，grep 负责文案格式化）、零分配（无 deinit）、
/// 测试可断言具体错误码与位置。
pub const CompileErrorCode = enum {
    unterminated_class,        // `[abc` / `[]`（无闭合 `]`）
    unterminated_group,        // `(ab`
    unterminated_brace,        // `a{2`
    quantifier_no_target,      // `*a` / `a**`（量词前无表达式）
    invalid_escape,            // `\q`（未知转义）
    unsupported_construct,     // `(?=` / `(?!` / `\1` / `\p{` / `\B` 等扩展语法
    invalid_quantifier_range,  // `a{2,1}`（下界 > 上界）/ `a{1,1000000}`（数值 > MAX_QUANTIFIER_LIMIT）
    invalid_range,             // `[z-a]`（降序）/ `[a-\d]`（范围端点非字面量）
    nesting_too_deep,          // 组嵌套 > MAX_NEST_DEPTH（`((((...a...))))` 深嵌套）
};
pub const CompileError = struct {
    code: CompileErrorCode,
    pos: usize,          // spec 中出错位置（0-based），栈值无分配
};
/// 错误码 → 官方文案映射（评论者采纳）：纯函数放库内与枚举同源，switch 穷举全错误码
/// （编译器保证无遗漏），grep 直接调用——消费方零映射逻辑，文案可随库单测覆盖。
/// 每条文案含**静态修复指引**（评论者建议："Did you mean" 模板按错误类型绑定，
/// 零推断零误报——不做内容级自动补全，见"不做"节）：
/// - unterminated_group → "unterminated group - did you mean to close it with ')'?"
/// - unterminated_class → "unterminated character class - did you mean ']'?"
/// - unterminated_brace → "unterminated quantifier - did you mean '}'?"
/// - quantifier_no_target → "quantifier without target - remove the dangling '*', '+', or '?'"
/// - 其余错误码同样附"did you mean" 式指引或具体改写示例（如 invalid_range → [a0-9]）
pub fn errorDetail(code: CompileErrorCode) []const u8;
pub const CompileResult = union(enum) {
    ok: Pattern,
    err: CompileError,
};
/// 仅 arena 分配（nodes）可能 OOM → 上抛 error.OutOfMemory（grep 既有 OOM 路径）；
/// 其余编译失败（语法/不支持构造）→ `.err` 结构化错误。
pub fn compile(allocator: std.mem.Allocator, spec: []const u8) (error{OutOfMemory})!CompileResult;
/// 匹配整段文本（**非锚定搜索**，评论者修正）：模式可出现在 text 任意位置——
/// 有字面量前缀时按前缀命中位置扫描，无前缀时逐 pos 扫描（对齐 indexOf/ripgrep 语义）。
/// 返回 false = 不匹配；error.MatchLimitExceeded = 超步数上限（调用者按熔断处理）。
/// `steps` 由调用者持有：**per-call 总预算**（grep.execute 级创建，跨文件跨行共享、不清零）。
/// Pattern 无内部状态（*const），计数器在调用栈，并发安全。
/// `allocator` = null 禁用失败记忆化（纯回溯，测试等价性用）；非 null 时步骤超 MEMO_THRESHOLD
/// 惰性创建记忆化集合（正常行零分配，仅灾难回溯迹象触发一次分配）。
pub fn match(self: *const Pattern, text: []const u8, steps: *usize, allocator: ?std.mem.Allocator) (error{MatchLimitExceeded})!bool;
```

**测试**（test block 放文件末尾，每语法子集 ≥1 正 + 1 负）：
- 字面量/`.`/`^`/`$`/字符类（范围/取反/转义）/分组/交替（优先级）/量词（`*` `+` `?` `{n}` `{n,}` `{n,m}` 贪婪回溯）/`\d\D\w\W\s\S`/`\b`/字面转义
- **链结构**：`ab` 双节点 next 串联、`(ab)c` 组节点外链、空组 `()`/空分支 `a|`（first=null 匹配空）、空模式 root=null
- **空交替**：`a||b` 左结合解析（`(a|ε)|b`）且恒匹配空；`|a`/`a|` 同样空分支兜底——行为断言（不报错、恒真、不悬挂）
- **回溯正确性**：`a.*b` 贪婪取最大、`(ab|a)b` 交替回溯、`a{2,3}` 贪婪 3 后回溯
- **错误码文案覆盖**：`errorDetail` 遍历 `CompileErrorCode` 全部 9 个变体断言返回非空文案 + 已知码断言精确文案（如 `invalid_quantifier_range` → "invalid quantifier range (bounds must be ≤ 1000 and min ≤ max)"；`invalid_range` → "invalid character range (range endpoints must be literal characters; e.g. write [a0-9] instead of [a-\d])"；`unterminated_group` → 含 "did you mean to close it with ')'?"）——switch 穷举由编译器保证，测试防文案回归
- **错误路径**：`[abc`（unterminated_class）、`(ab`（unterminated_group）、`a{2`（unterminated_brace）、`a**`/`*a`（quantifier_no_target）、`\q`（invalid_escape）、`(?=`（unsupported_construct）、`a{2,1}`（invalid_quantifier_range）、`a{1001}`/`a{1,1001}`/`a{1001,}`（invalid_quantifier_range，数值 > 1000）、`[z-a]`（invalid_range）、`[a-\d]`（invalid_range）、`[]`（unterminated_class）、`"("**70 + "a" + ")"**70`（nesting_too_deep，70 层嵌套 > 64）——均断言 `.err.code` 枚举值与 `.pos` 具体位置（结构化断言，不依赖文案字符串）
- **量词边界**：`a{1000}`/`a{1,1000}`/`a{1000,}` 合法编译并正确匹配（边界内）
- **深度边界**：64 层嵌套正常编译并匹配（边界内）；70 层编译错误；运行时守卫测试（构造结构深度接近上限的模式 × 长输入）断言不崩溃（MatchLimitExceeded 或正常结果，绝不栈溢出）
- **顺行链/重复零递归（评论者风险回归测试）**：① `"a"**10000 ++ "b"` 字面量模式对 100KB 行匹配（迭代沿链，无万层栈帧）② `a*` 对 100KB 全 a 行（贪婪迭代，无递归）③ `a{1000}` 匹配 1000 字符行（重复迭代，不触发深度守卫——守卫仅约束嵌套）
- **字符类边界**：`[]a]` 匹配 `]`/`a` 不匹配 `b`；`[-a]`/`[a-]` 匹配 `-`；`[^]a]` 取反且首 `]` 字面量；`[a-a]` 合法；`[[]` 匹配 `[`；`[\d]` 类内类转义
- **步数预算 + 记忆化**：`(a+)+b` 对 `"a"**5000` 快速返回 false 且**不触发步数预算**（失败记忆化后多项式）；`allocator=null`（纯回溯）与 `allocator≠null`（记忆化）对同输入结果一致（等价性测试，验证缓存不改变语义）；纯回溯路径断言 `MatchLimitExceeded` 兜底
- **per-call 预算熔断（grep 集成测试）**：多行文件 × 恶意模式（`(a+)+b`）→ 总预算耗尽后扫描提前终止，结果 `truncated=true` + 尾部含 `... (match complexity limit reached)`，快速返回（对比：per-line 预算下同样输入会扫完所有行）；**与既有截断互斥验证**：普通模式命中匹配数超限 → 尾部 `... (max matches reached)`（无复杂度文案），确认三文案不混淆
- **比例预算不误伤（评论者场景回归测试）**：`a|b` 无前缀模式对 ~512KB 文件（5000 行 × 100 字符）完整扫描**不熔断**（1.5M 步 < 100k + 16×512k）；`[ab]`/`a*` 同类验证；对比固定 100k 预算下同输入必熔断（锁定修正动机）
- **非锚定搜索（致命语义回归测试）**：`"foo"` 匹配 `"xxfooxx"`（中间位置）；`^foo` 仅匹配行首行、`foo$` 仅匹配行尾行；空模式匹配任意行；可空模式（`a*`）匹配含与不含 `a` 的行；`fo` 前缀命中多位置时逐个尝试正确
- **回归等价**：纯字面量模式 `match == indexOf`（表驱动对比）
- **前缀预检**：`fn.*foo` 前缀 "fn"——不含 "fn" 的行快速失败（断言步数消耗 ≈ 0）；含 "fn" 行正常匹配；`^import`/`a|b`/`a*foo` 无前缀但行为正确；纯字面量 `foobar` 前缀即全文

### 步骤 2: grep.zig 接入正则

**文件**: `src/tool/grep.zig`
**改动**:
- `execute` 顶层创建总预算：`var steps: usize = 0;`，传入 searchFile/searchDir（签名加 `steps: *usize` 参数）
- `searchFile`（L101）/`searchDir`（L172）开头：`const compiled = regex.compile(ctx.allocator, pattern) catch return error.OutOfMemory;` + `switch (compiled) { .ok => |*p| { ... 使用 ... defer p.deinit() }, .err => |e| return GrepResult 错误消息（allocPrint 组合 `regex.errorDetail(e.code)` + e.pos） }`——`switch` 强制处理 ok/err 两分支；错误文案映射由 `regex.errorDetail` 纯函数提供（库内与枚举同源，switch 穷举全错误码），grep 无散落映射逻辑
- 行匹配 L134/L208：`std.mem.indexOf(u8, line, pattern)` → `if (p.match(line, steps, ctx.allocator) catch { try buf.appendSlice(ctx.allocator, "... (match complexity limit reached)\n"); truncated = true; break; }) { ... }`——超限置 truncated 并中断
  - **searchFile**（L132 单层行循环）：`break` 即可
  - **searchDir**（L179 文件遍历 + L206 行循环双层）：外层加标签 `outer: while (try iter.next(ctx.io)) |entry| {`，熔断处 `break :outer;`——预算耗尽必须退出**两层**（行循环 + 文件遍历），否则外层继续遍历后续文件会每文件立即超限空转
- 工具描述 L7：`Search for a regex pattern in file contents`；`tool_params` pattern 描述注明语法子集、不支持项、**空交替警告**（评论者建议：`a|`、`|a`、`a||b` 含空分支使模式恒匹配空——LLM 若误写将匹配所有行/位置，显式提示避免困惑）：`"Regex pattern. Supported: ^ $ . [...] [^...] [a-z] (...) a|b * + ? {n} {n,} {n,m} \d \w \s \b and escaped literals. Unsupported (compile error): backreferences (?= lookahead (?i flags \p{ \B \A \z. NOTE: empty alternation branches (a|, |a, a||b) make the pattern match everywhere - avoid unless intended. Quantifier bounds ≤ 1000, nesting ≤ 64."`

**注意**: 预算熔断语义——`MatchLimitExceeded` 不再"catch false 继续"而是"catch 熔断"（per-call 总预算耗尽后继续逐行调用只会反复立即失败，中断返回已收集部分 + truncated 标志）。

### 截断合并语义（评论者问询）

grep 现有三种截断机制与预算熔断的合并契约：

| 截断点 | 触发条件 | 追加文案 | truncated | break 范围 |
|--------|----------|----------|-----------|------------|
| 匹配数超限 | `matches > MAX_MATCHES`（500） | `... (max matches reached)\n` | 置 true | 当前文件行循环 |
| 收集上限 | `buf.items.len >= TOOL_COLLECT_LIMIT`（50KB） | `[truncated]\n` | 置 true | 当前文件行循环（searchDir 顺带中断文件遍历） |
| **预算熔断（新增）** | `match` 返回 `MatchLimitExceeded` | `... (match complexity limit reached)\n` | 置 true | **两层**：searchFile 单层 `break`；searchDir 外层 `outer:` 标签 + `break :outer`（行循环 + 文件遍历——预算已耗尽，后续文件必然立即超限） |

**共用同一个 `truncated` 标志**——语义统一为"结果不完整"：`GrepResult.truncated` 是消费者判断结果完整性的唯一信号，三个原因都是"搜索未完整执行"，无需区分（前端展示 truncated 状态不关心原因）。**原因区分靠追加文案**：三种文案互斥出现（各自的触发点在不同检查分支），LLM 从尾部文案精确得知截断原因（匹配数/输出大小/复杂度）并相应调整（减少匹配上限、改 pattern、简化正则）。**优先级**：预算熔断检查发生在行匹配调用点（每行最先），匹配数/收集检查在命中分支内——天然无冲突。

### 步骤 3: grep 集成测试

**文件**: `src/tool/grep.zig` 测试段
**改动**: 新增测试：
- 正则匹配（fixture 文件含 `fn foo()` 行，pattern `fn.*foo` 命中；`^import` 命中行首；`\d+ms` 命中数字单位）
- 非法模式 → ToolResult 错误消息包含 `invalid regex pattern`
- 既有子串语义测试回归（纯字面量仍通过）

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
zig test src/util/regex.zig --cache-dir .zig-cache
zig build -Doptimize=ReleaseSafe
node ..\.opencode\skills\zig-dev\scripts\check-catch-silent.mjs . --audit
node ..\.opencode\skills\zig-dev\scripts\check-arch.mjs .
node ..\.opencode\skills\zig-dev\scripts\check-magic.mjs . --ignore <栈缓冲等既有排除项>
```

| 测试场景 | 预期结果 |
|----------|----------|
| regex.zig 全部单测（语法子集 10 类 + 错误路径 + 记忆化/预算 + 非锚定 + 前缀 + 深度/链/重复零递归 + 回归等价） | 全过 |
| grep 集成测试（正则命中/非法模式报错/子串回归） | 全过 |
| 全量测试 | All 通过，无泄漏 |
| ReleaseSafe | 无 UB |
| 架构扫描 | 无新增 issue（util 新文件零依赖） |
| 空 catch | 无新增 |
| check-magic | 无新增跨文件魔法值（MATCH_STEP_BASE/RATIO 等 6 常量各单处） |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/util/regex.zig` | 新增（引擎 + 单测） | 否（新文件） |
| `src/tool/grep.zig` | 两处匹配换正则 + 描述更新 + 集成测试 | ⚠️ 语义变化：含特殊字符的模式从子串变为正则（对齐 ripgrep；纯字面量不变） |
| `docs/REMAINING.md` | N20 标记实施 | 否 |

**测试总量预估**：regex.zig ~35 条单测 + grep 集成 ~3 条。

## 实施偏差记录

1. **alt 跨分支回溯（设计补强）**：文档只规划 repeat 迭代回溯——实施发现**交替同样需要跨分支回溯**（`(ab|a)b`：左分支成功后外层失败须重试右分支），且组内 repeat/alt 帧必须**跨嵌套 matchSeq 存活**（帧提升到 MatchCtx 共享栈 + `resume_chain`（组外链）+ `depth` 过滤防跨层误弹）。`matchSeq` 增 `group_of` 参数。
2. **失败记忆化效果推演修正**：`(a+)+b` 类模式组从不失败 → 无失败可缓存 → 记忆化无效；迭代 repeat 栈将重复回溯线性化为 O(n²)（每扫描位置）——中等输入预算内完成、大输入熔断（预算为最终兜底）。测试 19 断言改为"预算熔断必返回"。
3. **`.err` 是正常返回值**：`CompileResult.err` 为 union 正常返回——`errdefer` 不触发 → arena 泄漏（testing.allocator 捕获）。修复：`.err` 分支显式 `arena.deinit()`（error.OutOfMemory 路径仍走 errdefer）。
4. **`(?=` 检测位置**：`(` 后跟 `?` → `unsupported_construct`（parseAtom '(' 分支统一拦截，非量词错误）。
5. **`{` 非量词语义**：`{` 后无数字 → 字面量 `{`（parseBrace 返回 null，parseQuantifier 回退 emit literal）；数字超限/min>max/未闭合 → 编译错误（原设计"回退字面量"修正）。
6. **utf8Decode 切片约束**：`std.unicode.utf8Decode` 要求 1-4 字节切片——实现按首字节推断序列长度再截取解码（`decodeCpAt`），非法字节退化单字节。
7. **字符类解析重构**：实施中重写 parseClass（统一"成员读入后处理 '-'"逻辑）——修复 `[a-z]` 范围被拆单字符、尾部 `-` 缺失两个 bug。
8. **测试侧**：深嵌套测试构造修正（65 层 '('）；`(a+)+b`/`a+b` 预算测试断言修正（O(n²) 非锚定扫描必然熔断）；补 ArrayList deinit 防测试泄漏。

## 术语

| 术语 | 含义 |
|------|------|
| 递归回溯匹配器 | 正则匹配算法：按模式递归尝试匹配，失败时回溯尝试其他分支（贪婪量词递减） |
| 灾难性回溯 | 嵌套量词（如 `(a+)+b`）导致指数级尝试次数的最坏情况 |
| 零宽断言 | 不消费输入字符的匹配条件（`^`/`$`/`\b`），匹配位置本身 |
| 交替（alternation） | 正则 `a\|b`——尝试左分支失败后尝试右分支 |
