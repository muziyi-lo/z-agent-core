import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../../src/frontends/web/app.js", import.meta.url), "utf8")

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

function makeEl(tag) {
  const el = {
    tag, className: "", children: [], parentNode: null, textContent: "", _html: "", _attrs: {},
    appendChild(c) { c.parentNode = this; this.children.push(c); return c },
    insertBefore(n, ref) { n.parentNode = this; const i = this.children.indexOf(ref); if (i < 0) this.children.push(n); else this.children.splice(i, 0, n); return n },
    removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); return c },
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
    closest(sel) {
      const isClass = sel.startsWith(".")
      const cls = isClass ? sel.slice(1) : sel
      let n = this
      while (n) {
        const tokens = (n.className || "").split(/\s+/)
        const tagMatch = !isClass && n.tag === cls
        if (tagMatch || tokens.indexOf(cls) !== -1) return n
        n = n.parentNode
      }
      return null
    },
    set innerHTML(v) { this._html = String(v) }, get innerHTML() { return this._html },
    set onclick(v) { this._onclick = v }, get onclick() { return this._onclick },
  }
  el.classList = {
    add(c) { if (el.className.indexOf(c) === -1) el.className += " " + c },
    remove(c) { el.className = el.className.replace(new RegExp("\\s*" + c), "") },
    toggle(c) {
      if (el.className.indexOf(c) === -1) { el.className += " " + c; return true }
      el.className = el.className.replace(new RegExp("\\s*" + c), ""); return false
    },
    contains(c) { return el.className.indexOf(c) !== -1 },
  }
  return el
}
globalThis.document = { createElement: (t) => makeEl(t) }

const makeCard = eval(`(${extract("makeCard")})`)
globalThis.setCardOpen = eval(`(${extract("setCardOpen")})`)
globalThis.handleCardClick = eval(`(${extract("handleCardClick")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

// --- makeCard: defaultOpen + structure ---
console.log("makeCard: defaultOpen true")
{
  const card = makeCard({ head: "H", body: makeEl("div"), defaultOpen: true })
  check("has .open class", card.className.indexOf("open") !== -1)
  check("aria-expanded true", card._attrs["aria-expanded"] === "true")
}
console.log("makeCard: defaultOpen false")
{
  const card = makeCard({ head: "H", body: makeEl("div"), defaultOpen: false })
  check("no .open class", card.className.indexOf("open") === -1)
  check("aria-expanded false", card._attrs["aria-expanded"] === "false")
}
console.log("makeCard: structure")
{
  const card = makeCard({ head: "H", body: makeEl("div"), defaultOpen: true })
  check("has .card-head", card.querySelector(".card-head") !== null)
  check("has .card-body", card.querySelector(".card-body") !== null)
  check("head content", card.querySelector(".card-head").innerHTML === "H")
}

// --- setCardOpen ---
console.log("setCardOpen: set true/false")
{
  const card = makeCard({ head: "H", body: makeEl("div"), defaultOpen: false })
  setCardOpen(card, true)
  check("open added", card.className.indexOf("open") !== -1)
  check("aria true", card._attrs["aria-expanded"] === "true")
  setCardOpen(card, false)
  check("open removed", card.className.indexOf("open") === -1)
  check("aria false", card._attrs["aria-expanded"] === "false")
}
console.log("setCardOpen: idempotent")
{
  const card = makeCard({ head: "H", body: makeEl("div"), defaultOpen: false })
  setCardOpen(card, true)
  setCardOpen(card, true)
  check("still open after double-set", card.className.indexOf("open") !== -1)
}

// --- handleCardClick guards ---
console.log("handleCardClick: guards")
{
  const card = makeCard({ head: "H", body: makeEl("div"), defaultOpen: false })
  const head = card.querySelector(".card-head")
  const body = card.querySelector(".card-body")
  // click body -> no toggle
  handleCardClick({ target: body })
  check("body click no toggle", card.className.indexOf("open") === -1)
  // click head button -> no toggle
  const btn = makeEl("button")
  btn.className = "copy-cmd"
  head.appendChild(btn)
  handleCardClick({ target: btn })
  check("head button no toggle", card.className.indexOf("open") === -1)
  // click head blank -> toggle
  // click head blank -> toggle
  handleCardClick({ target: head })
  check("head blank toggles open", card.className.indexOf("open") !== -1)
  // click outside card -> no error
  const outside = makeEl("div")
  handleCardClick({ target: outside })
  check("outside click no error", true)
  // click card gap (card itself, not head/body child) -> toggle
  handleCardClick({ target: card })
  check("card gap toggles closed", card.className.indexOf("open") === -1)
}

// --- head XSS contract ---
console.log("makeCard: head XSS escape preserved")
{
  const escaped = "&lt;img onerror=alert(1)&gt;"
  const card = makeCard({ head: escaped, body: makeEl("div"), defaultOpen: false })
  check("head innerHTML not double-escaped", card.querySelector(".card-head").innerHTML === escaped)
  check("no raw <img in head", card.querySelector(".card-head").innerHTML.indexOf("<img") === -1)
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)

