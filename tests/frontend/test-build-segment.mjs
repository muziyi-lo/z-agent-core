import { readFileSync } from "node:fs"

// --- minimal DOM stub (buildSegment/renderAssistantMessage touch only these) ---
function makeEl(tag) {
  const el = {
    tag,
    className: "",
    style: {},
    children: [],
    textContent: "",
    _html: "",
    _attrs: {},
    appendChild(c) { this.children.push(c); return c; },
    setAttribute(k, v) { this._attrs[k] = v },
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
    set innerHTML(v) { this._html = String(v) },
    get innerHTML() { return this._html },
    set onclick(v) { this._onclick = v },
    get onclick() { return this._onclick },
  }
  el.classList = {
    add(c) { if (el.className.indexOf(c) === -1) el.className += " " + c },
    remove(c) { el.className = el.className.replace(new RegExp("\\s*" + c), "") },
    toggle(c) {
      if (el.className.indexOf(c) === -1) { el.className += " " + c; return true }
      el.className = el.className.replace(new RegExp("\\s*" + c), ""); return false
    },
  }
  return el
}
globalThis.document = { createElement: (t) => makeEl(t) }
globalThis.renderMd = (s) => `[md:${s ?? ""}]`
globalThis.esc = (s) => String(s)

// --- extract two functions from app.js via brace matching ---
const src = readFileSync(new URL("../../src/frontends/web/app.js", import.meta.url), "utf8")
function extract(fnName) {
  const start = src.indexOf(`function ${fnName}(`)
  if (start < 0) throw new Error(`function ${fnName} not found`)
  const bodyStart = src.indexOf("{", start)
  let depth = 0
  let i = bodyStart
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}") {
      depth--
      if (depth === 0) break
    }
  }
  return src.slice(start, i + 1)
}
const fnSrc = `${extract("buildSegment")}\n${extract("renderAssistantMessage")}`
// CARD-UNIFY: buildSegment 委托 makeCard，需一并提取注入
globalThis.makeCard = eval(`(${extract("makeCard")})`)
const buildSegment = eval(`(${extract("buildSegment")})`)
const renderAssistantMessage = eval(`(${extract("renderAssistantMessage")})`)

// --- assertions ---
let pass = 0
let fail = 0
function check(name, cond) {
  if (cond) { pass++; console.log(`  ok ${name}`) } else { fail++; console.log(`  FAIL ${name}`) }
}

console.log("buildSegment: reasoning")
{
  const el = buildSegment({ type: "reasoning", text: "think hard" })
  check("className has thinking-block", el.className.indexOf("thinking-block") !== -1)
  check("className has card", el.className.indexOf("card") !== -1)
  const h = el.querySelector(".card-head")
  check("has .card-head", h !== null && h.innerHTML.includes("Thinking"))
  const c = el.querySelector(".content")
  check("has .content child", c !== null)
  check("content md", c && c.innerHTML === "[md:think hard]")
}

console.log("buildSegment: text")
{
  const el = buildSegment({ type: "text", text: "hello" })
  check("className content-block", el.className === "content-block")
  const c = el.querySelector(".content")
  check("has .content child", c !== null)
  check("content md", c && c.innerHTML === "[md:hello]")
}

console.log("buildSegment: tool")
{
  const el = buildSegment({ type: "tool", name: "bash", output: "out" })
  check("className has tool-card", el.className.indexOf("tool-card") !== -1)
  check("className has open (default)", el.className.indexOf("open") !== -1)
  check("_toolName", el._toolName === "bash")
  const o = el.querySelector(".output")
  check("has .output child", o !== null)
  check("output md", o && o.innerHTML === "[md:out]")
  // CARD-UNIFY: 折叠交互由 #messages 委托 handleCardClick 承担，卡片自身不绑 onclick
  check("no onclick bound on card", el.onclick == null)
}

console.log("buildSegment: unknown type")
{
  const el = buildSegment({ type: "bogus" })
  check("returns div", el && el.tag === "div")
}

console.log("renderAssistantMessage: order preserved")
{
  const container = makeEl("div")
  renderAssistantMessage(container, {
    segments: [
      { type: "reasoning", text: "r" },
      { type: "tool", name: "bash", output: "o" },
      { type: "text", text: "t" },
    ],
  })
  check("3 children", container.children.length === 3)
  check("order [reasoning,tool,text]",
    container.children[0].className.indexOf("thinking-block") !== -1 &&
    container.children[1].className.indexOf("tool-card") !== -1 &&
    container.children[2].className === "content-block")
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
