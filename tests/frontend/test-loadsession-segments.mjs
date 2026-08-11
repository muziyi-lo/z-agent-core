import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../../src/frontends/web/app.js", import.meta.url), "utf8")

function extract(fnName) {
  let start = src.indexOf(`async function ${fnName}(`)
  let prefix = "async "
  if (start < 0) { start = src.indexOf(`function ${fnName}(`); prefix = "" }
  if (start < 0) throw new Error(`function ${fnName} not found`)
  if (prefix) start += "async ".length
  const bodyStart = src.indexOf("{", start)
  let depth = 0
  for (let i = bodyStart; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}") { depth--; if (depth === 0) return prefix + src.slice(start, i + 1) }
  }
  throw new Error("unbalanced")
}

function makeEl(tag) {
  return {
    tag, className: "", style: {}, children: [], textContent: "", _html: "", id: "",
    classList: { add() {}, remove() {}, toggle() {} },
    appendChild(c) { this.children.push(c); return c },
    insertBefore(n, ref) { const i = this.children.indexOf(ref); if (i < 0) this.children.push(n); else this.children.splice(i, 0, n); return n },
    querySelector(sel) {
      const cls = sel.slice(1)
      const c = this.children.find((x) => x.className === cls)
      if (c) return c
      if (this._html && this._html.includes('class="' + cls + '"')) return makeEl("div")
      return null
    },
    querySelectorAll() { return [] },
    closest() { return null },
    set innerHTML(v) { this._html = String(v) }, get innerHTML() { return this._html },
    set onclick(v) { this._onclick = v }, get onclick() { return this._onclick },
  }
}

const messages = makeEl("div")
messages.scrollTop = 0
messages.scrollHeight = 0
Object.defineProperty(messages, "innerHTML", {
  set(v) { this.children.length = 0; this._html = String(v) },
  get() { return this._html },
})
const els = {
  "messages": messages,
  "send-btn": { disabled: false },
  "stop-btn": { disabled: true },
  "prompt-input": { disabled: false, focus() {} },
  "topbar": { textContent: "" },
  "topbar-title": { textContent: "" },
}
globalThis.document = {
  createElement: (t) => makeEl(t),
  getElementById: (id) => els[id] ?? null,
  querySelectorAll: () => [],
}

const session = {
  id: "s1", name: "Test Session",
  messages: [
    { role: "system", content: "You are z-agent-core" },
    { role: "user", content: "你好" },
    { role: "assistant", reasoning_content: "The user just said 你好", content: "你好！有什么可以帮你？", model: "deepseek-v4-flash", timestamp: 1 },
    { role: "user", content: "几点了？" },
    { role: "assistant", reasoning_content: "The user is asking what time it is", content: "", tool_calls: [{ id: "call_1", name: "bash", arguments: "{}" }] },
    { role: "tool", tool_call_id: "call_1", content: "%date%\n%time%\n" },
    { role: "assistant", reasoning_content: "The echo did not expand the variables", content: "", tool_calls: [{ id: "call_2", name: "bash", arguments: "{}" }] },
    { role: "tool", tool_call_id: "call_2", content: "2026-08-07 13:08:57\n" },
    { role: "assistant", reasoning_content: "", content: "现在是 2026年8月7日 13:08（下午 1 点过 8 分）。", model: "deepseek-v4-flash", timestamp: 2 },
  ],
}
globalThis.api = async () => session

globalThis.renderSystemPrompt = () => {}
globalThis.wrapContextToolGroups = () => {}
globalThis.loadSessions = () => {}
globalThis.renderMd = (s) => "[md:" + (s ?? "") + "]"
globalThis.esc = (s) => String(s)
globalThis.setTopbarTitle = () => {}
globalThis.setStreaming = () => {}
globalThis.biIcon = (name, size) => '<svg data-icon="' + name + '"></svg>'
globalThis.addCopyButton = () => {}
globalThis.hljs = { highlightAll() {} }
globalThis.isStreaming = false
globalThis.currentId = null
globalThis.currentName = null

globalThis.buildSegment = eval(`(${extract("buildSegment")})`)
globalThis.renderAssistantMessage = eval(`(${extract("renderAssistantMessage")})`)
globalThis.addMessage = eval(`(${extract("addMessage")})`)
globalThis.loadSession = eval(`(${extract("loadSession")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }
function clsList(el) { return el.children.map((c) => c.className) }
function segCls(el) { return el.children.filter((c) => c.className !== "msg-delete" && c.className !== "msg-meta").map((c) => c.className) }
function childText(el, cls) { const c = el.children.find((x) => x.className === cls); return c ? c.textContent : null }
function childHtml(el, cls) { const c = el.children.find((x) => x.className === cls); return c ? c.innerHTML : null }
function blockHtml(el, cls) {
  const block = el.children.find((x) => x.className === cls)
  if (!block) return null
  const inner = block.children.find((x) => x.className === "content")
  return inner ? inner.innerHTML : null
}

await loadSession("s1")

const top = clsList(messages)
check("6 top-level msgs", messages.children.length === 6 &&
  top[0] === "msg user" && top[1] === "msg assistant" && top[2] === "msg user" &&
  top[3] === "msg assistant" && top[4] === "msg assistant" && top[5] === "msg assistant")

const t1 = messages.children[3]  // tool-use assistant #1 (call_1)
check("tool-assistant1 [thinking,tool]",
  segCls(t1)[0].startsWith("thinking-block") && segCls(t1)[1] === "tool-card open")
check("tool1 name + output filled", t1.children[1]._toolName === "bash" &&
  childHtml(t1.children[1], "output") === "[md:%date%\n%time%\n]")
check("thinking1 open (reload preserves expanded)", t1.children[0].className.includes("open"))

const t2 = messages.children[4]  // tool-use assistant #2 (call_2)
check("tool-assistant2 [thinking,tool]", segCls(t2)[0].startsWith("thinking-block") && segCls(t2)[1] === "tool-card open")
check("tool2 output filled", childHtml(t2.children[1], "output") === "[md:2026-08-07 13:08:57\n]")

const final = messages.children[5]
check("final answer is text-only msg", segCls(final).length === 1 && segCls(final)[0] === "content-block")
check("final text content", blockHtml(final, "content-block") === "[md:现在是 2026年8月7日 13:08（下午 1 点过 8 分）。]")

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
