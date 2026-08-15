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

const promptHistoryPush = eval(`(${extract("promptHistoryPush")})`)
const promptHistoryUp = eval(`(${extract("promptHistoryUp")})`)
const promptHistoryDown = eval(`(${extract("promptHistoryDown")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

const EMPTY = { entries: [], cursor: -1, draft: null }

console.log("promptHistoryPush")
{
  const s = promptHistoryPush(EMPTY, "  hello  ")
  check("trims and appends", s.entries.length === 1 && s.entries[0] === "hello")
  check("returns new object (immutable)", s !== EMPTY && EMPTY.entries.length === 0)
  check("cursor resets to -1", s.cursor === -1 && s.draft === null)
  check("blank skipped", promptHistoryPush(EMPTY, "   ").entries.length === 0)
  check("empty skipped", promptHistoryPush(EMPTY, "").entries.length === 0)
  const s2 = promptHistoryPush(s, "hello")
  check("trailing duplicate skipped", s2.entries.length === 1)
  const s3 = promptHistoryPush(s2, "world")
  check("appends after duplicate", s3.entries.length === 2 && s3.entries[1] === "world")
}

console.log("promptHistoryUp")
{
  const r0 = promptHistoryUp(EMPTY, "draft")
  check("empty history returns null value", r0.value === null && r0.state === EMPTY)

  const h = { entries: ["a", "b", "c"], cursor: -1, draft: null }
  const r1 = promptHistoryUp(h, "typing now")
  check("first Up saves draft + jumps to last", r1.value === "c")
  check("draft stored as current value", r1.state.draft === "typing now" && r1.state.cursor === 2)
  check("original untouched", h.cursor === -1 && h.draft === null)

  const r2 = promptHistoryUp(r1.state, "typing now")
  check("second Up steps back", r2.value === "b" && r2.state.cursor === 1)
  check("draft preserved across navigation", r2.state.draft === "typing now")

  const r3 = promptHistoryUp(r2.state, "typing now")
  check("third Up reaches first entry", r3.value === "a" && r3.state.cursor === 0)

  const r4 = promptHistoryUp(r3.state, "typing now")
  check("Up at oldest entry is no-op", r4.value === "a" && r4.state.cursor === 0)
}

console.log("promptHistoryDown")
{
  const r0 = promptHistoryDown(EMPTY)
  check("empty history returns null value", r0.value === null && r0.state === EMPTY)

  const atBase = { entries: ["a", "b", "c"], cursor: -1, draft: null }
  const rb = promptHistoryDown(atBase)
  check("Down at new-input position is no-op", rb.value === null && rb.state === atBase)

  const nav = { entries: ["a", "b", "c"], cursor: 1, draft: "draft" }
  const r1 = promptHistoryDown(nav)
  check("Down steps forward", r1.value === "c" && r1.state.cursor === 2)

  const r2 = promptHistoryDown(r1.state)
  check("Down at last restores draft", r2.value === "draft" && r2.state.cursor === -1)
  check("draft cleared after restore", r2.state.draft === null)

  const noDraft = { entries: ["a"], cursor: 0, draft: null }
  const r3 = promptHistoryDown(noDraft)
  check("Down with empty draft returns null value", r3.value === null && r3.state.cursor === -1)
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
