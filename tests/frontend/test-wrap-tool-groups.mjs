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

function makeEl(tag) {
  const el = {
    tag, className: "", children: [], parentNode: null, textContent: "", _html: "", _toolName: undefined,
    classList: { add() {}, remove() {}, toggle() {} },
    appendChild(c) { c.parentNode = this; this.children.push(c); return c },
    insertBefore(n, ref) { n.parentNode = this; const i = this.children.indexOf(ref); if (i < 0) this.children.push(n); else this.children.splice(i, 0, n); return n },
    querySelectorAll(sel) {
      if (sel !== ".tool-card") return []
      const out = []
      const walk = (e) => { e.children.forEach((c) => { if (c.className.includes("tool-card")) out.push(c); walk(c) }) }
      walk(this)
      return out
    },
    set innerHTML(v) { this._html = String(v) }, get innerHTML() { return this._html },
  }
  Object.defineProperty(el, "nextSibling", {
    get() {
      if (!this.parentNode) return null
      const i = this.parentNode.children.indexOf(this)
      return i >= 0 && i < this.parentNode.children.length - 1 ? this.parentNode.children[i + 1] : null
    },
  })
  return el
}
globalThis.document = { createElement: (t) => makeEl(t) }
globalThis.renderMd = (s) => "[md:" + (s ?? "") + "]"
globalThis.esc = (s) => String(s)
globalThis.hljs = { highlightAll() {}, highlightElement() {} }
globalThis.highlightNewCode = () => {}

const buildSegment = eval(`(${extract("buildSegment")})`)
globalThis.isContextTool = eval(`(${extract("isContextTool")})`)
globalThis.wrapContextToolGroups = eval(`(${extract("wrapContextToolGroups")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

// scenario 1: consecutive context tools read+glob grouped, bash excluded
console.log("scenario 1: [read, glob, bash]")
{
  const asst = makeEl("div")
  const read = buildSegment({ type: "tool", name: "read" })
  const glob = buildSegment({ type: "tool", name: "glob" })
  const bash = buildSegment({ type: "tool", name: "bash" })
  asst.appendChild(read); asst.appendChild(glob); asst.appendChild(bash)
  wrapContextToolGroups(asst)
  const cls = asst.children.map((c) => c.className)
  check("group wraps read+glob", cls[0] === "context-tool-group" && cls[1] === "tool-card open")
  check("bash stays outside", cls[1] === "tool-card open")
  const group = asst.children[0]
  check("group contains read+glob", group.children.some((c) => c._toolName === "read") && group.children.some((c) => c._toolName === "glob"))
  check("group summary", group.children[0].textContent.includes("read: 1") && group.children[0].textContent.includes("glob: 1"))
}

// scenario 2: tool name missing -> no grouping (isContextTool false)
console.log("scenario 2: unnamed tool")
{
  const asst = makeEl("div")
  const t = makeEl("div")
  t.className = "tool-card open"
  asst.appendChild(t)
  wrapContextToolGroups(asst)
  check("no grouping without _toolName", asst.children.length === 1 && asst.children[0].className === "tool-card open")
}

// scenario 3: per-assistant calls (the only call pattern post-refactor) isolate groups
console.log("scenario 3: per-assistant isolation")
{
  const m1 = makeEl("div"); m1.className = "msg assistant"
  const m2 = makeEl("div"); m2.className = "msg assistant"
  m1.appendChild(buildSegment({ type: "tool", name: "read" }))
  m2.appendChild(buildSegment({ type: "tool", name: "read" }))
  // reload/stream both call wrapContextToolGroups per assistant message
  wrapContextToolGroups(m1)
  wrapContextToolGroups(m2)
  check("assistant1 grouped", m1.children[0].className === "context-tool-group")
  check("assistant2 grouped", m2.children[0].className === "context-tool-group")
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
