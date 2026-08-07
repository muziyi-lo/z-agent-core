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
    classList: { add() {}, remove() {}, toggle() {} },
    appendChild(c) { this.children.push(c); return c; },
    querySelector(sel) {
      if (sel === ".content") return this.children.find((c) => c.className === "content") ?? null
      if (sel === ".output") return this.children.find((c) => c.className === "output") ?? null
      if (sel === ".name-row") return this.children.find((c) => c.className === "name-row") ?? null
      return null
    },
    querySelectorAll() { return [] },
    closest() { return null },
    set innerHTML(v) { this._html = String(v) },
    get innerHTML() { return this._html },
    set onclick(v) { this._onclick = v },
    get onclick() { return this._onclick },
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
  check("className thinking-block", el.className === "thinking-block")
  check("header innerHTML", el.innerHTML.includes("Thinking"))
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
  check("className tool-card open", el.className === "tool-card open")
  check("_toolName", el._toolName === "bash")
  const o = el.querySelector(".output")
  check("has .output child", o !== null)
  check("output md", o && o.innerHTML === "[md:out]")
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
    container.children[0].className === "thinking-block" &&
    container.children[1].className === "tool-card open" &&
    container.children[2].className === "content-block")
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
