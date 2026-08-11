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
const moreMenuAction = eval(`(${extract("moreMenuAction")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

console.log("moreMenuAction: action passthrough")
{
  const r = moreMenuAction("rename", "s1")
  check("rename action", r.action === "rename" && r.sessionId === "s1")
}

console.log("moreMenuAction: delete")
{
  const r = moreMenuAction("delete", "s2")
  check("delete action", r.action === "delete" && r.sessionId === "s2")
}

console.log("moreMenuAction: pin")
{
  const r = moreMenuAction("pin", "s3")
  check("pin action", r.action === "pin" && r.sessionId === "s3")
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
