import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../../src/frontends/web/app.js", import.meta.url), "utf8")

function extract(fnName) {
  let start = src.indexOf(`function ${fnName}(`)
  if (start < 0) throw new Error(`function ${fnName} not found`)
  const bodyStart = src.indexOf("{", start)
  let depth = 0
  for (let i = bodyStart; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}") { depth--; if (depth === 0) return src.slice(start, i + 1) }
  }
  throw new Error("unbalanced")
}

// ToolRegistry is a var — extract the object literal via brace matching
function extractToolRegistry() {
  const key = "var ToolRegistry ="
  const start = src.indexOf(key) + key.length
  let depth = 0
  for (let i = start; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}") { depth--; if (depth === 0) return src.slice(start, i + 1) }
  }
  throw new Error("ToolRegistry unbalanced")
}

function makeEl(tag) {
  const el = {
    tag, className: "", children: [], parentNode: null, textContent: "", _html: "", _toolName: undefined,
    appendChild(c) { c.parentNode = this; this.children.push(c); return c },
    insertBefore(n, ref) { n.parentNode = this; const i = this.children.indexOf(ref); if (i < 0) this.children.push(n); else this.children.splice(i, 0, n); return n },
    removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); return c },
    querySelector(sel) {
      const cls = sel.slice(1)
      const c = this.children.find((x) => x.className === cls || (x._cls && x._cls.includes(cls)))
      if (c) return c
      if (this._html && this._html.includes('class="' + cls + '"')) return makeEl("div")
      return null
    },
    querySelectorAll() { return [] },
    closest() { return null },
    set innerHTML(v) { this._html = String(v) }, get innerHTML() { return this._html },
    set onclick(v) { this._onclick = v }, get onclick() { return this._onclick },
  }
  el.classList = {
    add(c) { this._cls = (this._cls || "") + " " + c; el.className += " " + c },
    remove() {}, toggle() {},
    contains(c) { return (this._cls || "").includes(c) },
  }
  return el
}

globalThis.document = { createElement: (t) => makeEl(t) }
globalThis.renderMd = (s) => "[md:" + (s ?? "") + "]"
globalThis.esc = (s) => String(s)
globalThis.hljs = { highlightAll() {}, highlightElement() {} }
globalThis.highlightNewCode = () => {}
globalThis.copyText = (text, btn, label) => { if (btn) btn.textContent = label }

const ToolRegistry = eval(`(${extractToolRegistry()})`)
globalThis.ToolRegistry = ToolRegistry
globalThis.applyToolType = eval(`(${extract("applyToolType")})`)
globalThis.setToolIcon = eval(`(${extract("setToolIcon")})`)
globalThis.setToolMeta = eval(`(${extract("setToolMeta")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

function buildToolCard(name, output) {
  const card = makeEl("div")
  card.className = "tool-card open"
  card._toolName = name
  const nr = makeEl("div")
  nr.className = "name-row"
  card.appendChild(nr)
  const out = makeEl("div")
  out.className = "output"
  out.textContent = output || ""
  out.innerHTML = "[md:" + (output || "") + "]"
  card.appendChild(out)
  return card
}
function metaText(card) {
  const m = card.querySelector(".tool-meta")
  return m ? m.textContent : null
}
function labelText(card) {
  const l = card.querySelector(".tool-label")
  return l ? l._html : null
}

// --- webfetch typed view ---
console.log("webfetch: typed view shows url/format/mime/B")
{
  const card = buildToolCard("webfetch", "content")
  applyToolType(card, "webfetch", { url: "https://example.com", format: "markdown", mime: "text/html", byte_count: 123 })
  const m = metaText(card)
  check("meta has url", m && m.includes("https://example.com"))
  check("meta has format", m && m.includes("markdown"))
  check("meta has mime", m && m.includes("text/html"))
  check("meta has byte_count", m && m.includes("123B"))
  check("card has tool-webfetch class", card.className.includes("tool-webfetch"))
}

// --- bash idempotency: calling twice does not double-wrap pre/code ---
console.log("bash: idempotent pre/code wrap")
{
  const card = buildToolCard("bash", "hello world")
  applyToolType(card, "bash", { exit_code: 0, byte_count: 11 })
  const out1 = card.querySelector(".output")
  const html1 = out1 ? out1.innerHTML : ""
  applyToolType(card, "bash", { exit_code: 0, byte_count: 11 })
  const out2 = card.querySelector(".output")
  const html2 = out2 ? out2.innerHTML : ""
  check("first call wraps pre", html1.indexOf("<pre>") === 0)
  check("second call does not double wrap", html2 === html1)
  const m = metaText(card)
  check("meta has exit code", m && m.includes("exit: 0"))
}

// --- meta idempotency: cumulative _toolData across two calls ---
console.log("bash: cumulative meta across partial tool_meta events")
{
  const card = buildToolCard("bash", "out")
  applyToolType(card, "bash", { exit_code: 1 })
  applyToolType(card, "bash", { exit_code: 1, byte_count: 42 })
  const m = metaText(card)
  check("meta retains first-call field (exit)", m && m.includes("exit: 1"))
  check("meta adds second-call field (bytes)", m && m.includes("42B"))
}

// --- edit diff view ---
console.log("edit: diff coloring for unified diff output")
{
  const card = buildToolCard("edit", "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new")
  applyToolType(card, "edit", { replacements: 1, old_lines: 1, new_lines: 1 })
  check("card gets tool-diff class", card.className.includes("tool-diff"))
  check("meta shows replacements", metaText(card) && metaText(card).includes("1 replacements"))
}

// --- fallback: unknown tool goes to fallback renderer, no throw ---
console.log("fallback: unknown tool (e.g. mcp_connect)")
{
  const card = buildToolCard("mcp_connect", "data")
  let threw = false
  try { applyToolType(card, "mcp_connect", { byte_count: 5 }) } catch (e) { threw = true }
  check("does not throw", !threw)
  check("card gets tool-mcp_connect class", card.className.includes("tool-mcp_connect"))
  const m = metaText(card)
  check("fallback shows byte_count", m && m.includes("5B"))
}

// --- empty meta degrades gracefully ---
console.log("empty meta: {} renders without meta line")
{
  const card = buildToolCard("webfetch", "c")
  applyToolType(card, "webfetch", {})
  check("no crash", true)
  check("no meta line", metaText(card) === null)
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
