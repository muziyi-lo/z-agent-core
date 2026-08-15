import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../../src/frontends/web/app.js", import.meta.url), "utf8")

// --- brace-matching extractor ---
function extract(fnName) {
  const start = src.indexOf(`function ${fnName}(`)
  if (start < 0) throw new Error(`function ${fnName} not found`)
  const bodyStart = src.indexOf("{", start)
  let depth = 0
  for (let i = bodyStart; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}") { depth--; if (depth === 0) return src.slice(start, i + 1) }
  }
  throw new Error("unbalanced")
}

// --- DOM stub ---
function makeEl(tag) {
  return {
    tag, className: "", style: {}, children: [], textContent: "", _html: "", _attrs: {},
    classList: { add() {}, remove() {}, toggle() {} },
    appendChild(c) { this.children.push(c); return c },
    insertBefore(n, ref) { const i = this.children.indexOf(ref); if (i < 0) this.children.push(n); else this.children.splice(i, 0, n); return n },
    setAttribute(k, v) { this._attrs[k] = v },
    remove() { const p = this.parentNode; if (p) { const i = p.children.indexOf(this); if (i >= 0) p.children.splice(i, 1) } },
    querySelector(sel) {
      const cls = sel.startsWith(".") ? sel.slice(1) : sel
      const walk = (node) => {
        for (const c of node.children || []) {
          if (c.className && c.className.indexOf(cls) !== -1) return c
          const r = walk(c); if (r) return r
        }
        return null
      }
      return walk(this)
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
const els = {
  "messages": messages,
  "send-btn": { disabled: false },
  "stop-btn": { disabled: true },
  "prompt-input": { disabled: false, focus() {} },
  "topbar": { textContent: "" },
}
globalThis.document = {
  createElement: (t) => makeEl(t),
  getElementById: (id) => els[id] ?? null,
  querySelectorAll: () => [],
}

// --- EventSource stub ---
class FakeEventSource {
  constructor(url) { this.url = url; this.handlers = {}; this.closed = false }
  addEventListener(t, fn) { this.handlers[t] = fn }
  close() { this.closed = true }
}
globalThis.EventSource = FakeEventSource

// --- module-level globals sendPrompt touches ---
globalThis.A = "/api"
globalThis.currentId = null
globalThis.currentName = null
globalThis.currentModel = null
globalThis.evtSrc = null
globalThis.isStreaming = false
globalThis.abortInFlight = false
globalThis.genUuidV4 = () => "test-uuid"
globalThis.addMessage = () => {}
globalThis.scrollToBottom = () => {}
globalThis.renderSystemPrompt = () => {}
globalThis.applyToolType = () => {}
globalThis.wrapContextToolGroups = () => {}
globalThis.updateMarkdownBlocks = (container, content) => { container.innerHTML = "[md:" + content + "]" }
globalThis.renderMd = (s) => "[md:" + (s ?? "") + "]"
globalThis.esc = (s) => String(s)
globalThis.hljs = { highlightAll() {}, highlightElement() {} }
globalThis.highlightNewCode = () => {}
globalThis.renderMdBlocks = () => ""
globalThis.addCopyButton = () => {}
globalThis.loadModels = () => {}
globalThis.loadSessions = () => {}
globalThis.setStreaming = () => {}
globalThis.promptHistory = { entries: [], cursor: -1, draft: null }
globalThis.promptHistoryPush = (state, text) => ({ entries: state.entries.concat(text), cursor: -1, draft: null })

// sendPrompt calls conn.go('send'); provide a minimal stub (full state machine
// is exercised by dedicated tests, here we only need no-crash + phase bookkeeping)
globalThis.conn = { phase: "idle", go: () => {} }

// sendPrompt depends on buildSegment + makeCard (already in app.js); extract + eval all
globalThis.makeCard = eval(`(${extract("makeCard")})`)
globalThis.buildSegment = eval(`(${extract("buildSegment")})`)
globalThis.sendPrompt = eval(`(${extract("sendPrompt")})`)

// --- helpers ---
function fire(type, data) { evtSrc.handlers[type]({ data: JSON.stringify(data) }) }
function flatChildren(el) { return el.children.map((c) => c.className) }
function childText(el, cls) { const c = el.children.find((x) => x.className === cls); return c ? c.textContent : null }
function childHtml(el, cls) { const c = el.children.find((x) => x.className === cls); return c ? c.innerHTML : null }

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

// --- scenario A: multi-phase stream (narration → tool → thinking → tool → answer) ---
console.log("scenario A: multi-phase interleave")
sendPrompt("test")
const asstA = messages.children[messages.children.length - 1]

fire("thinking_start", {})
fire("thinking_delta", { text: "plan the time lookup" })
fire("thinking_end", { duration_ms: 1200 })
fire("content_start", {})
fire("content_delta", { text: "Let me check the time" })
fire("tool_start", { name: "bash" })
fire("tool_delta", { text: "2026-08-07 13:08:57" })
fire("tool_meta", { exit_code: 0 })
fire("thinking_start", {})
fire("thinking_end", { duration_ms: 100 })
fire("tool_start", { name: "bash" })
fire("tool_delta", { text: "%date%" })
fire("tool_meta", { exit_code: 0 })
fire("content_start", {})
fire("content_delta", { text: "It is 13:08." })
fire("done", {})

const clsA = flatChildren(asstA)
check("order [thinking,text,tool,thinking,tool,text]",
  clsA[0].indexOf("thinking-block") !== -1 &&
  clsA[1] === "content-block" &&
  clsA[2].indexOf("tool-card") !== -1 &&
  clsA[3].indexOf("thinking-block") !== -1 &&
  clsA[4].indexOf("tool-card") !== -1 &&
  clsA[5] === "content-block")
check("narration text in 2nd child", childText(asstA.children[1], "content") === "Let me check the time")
check("final text in last child", childHtml(asstA.children[5], "content") === "[md:It is 13:08.]")
check("tool1 output", asstA.children[2].querySelector(".output").textContent === "2026-08-07 13:08:57")

// --- scenario B: tools then final content (regular tool round) ---
console.log("scenario B: tools first, content last")
sendPrompt("test2")
const asstB = messages.children[messages.children.length - 1]

fire("thinking_start", {})
fire("thinking_end", { duration_ms: 100 })
fire("tool_start", { name: "glob" })
fire("tool_delta", { text: "3 files" })
fire("tool_meta", { exit_code: 0 })
fire("thinking_start", {})
fire("thinking_end", { duration_ms: 100 })
fire("tool_start", { name: "read" })
fire("tool_delta", { text: "file content" })
fire("tool_meta", { exit_code: 0 })
fire("content_start", {})
fire("content_delta", { text: "Final answer here." })
fire("done", {})

const clsB = flatChildren(asstB)
check("order [thinking,tool,thinking,tool,text]",
  clsB[0].indexOf("thinking-block") !== -1 &&
  clsB[1].indexOf("tool-card") !== -1 &&
  clsB[2].indexOf("thinking-block") !== -1 &&
  clsB[3].indexOf("tool-card") !== -1 &&
  clsB[4] === "content-block")
check("content last", childHtml(asstB.children[4], "content") === "[md:Final answer here.]")

// --- scenario C: content_delta before content_start (defensive lazy create) ---
console.log("scenario C: delta before start")
sendPrompt("test3")
const asstC = messages.children[messages.children.length - 1]
fire("thinking_start", {})
fire("thinking_end", { duration_ms: 50 })
fire("content_delta", { text: "orphan delta" })   // no content_start first
fire("content_delta", { text: " more" })
fire("done", {})
const clsC = flatChildren(asstC)
check("content-block created lazily", clsC[1] === "content-block")
check("text accumulates", childText(asstC.children[1], "content") === "orphan delta more")

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
