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
const renderModelMenu = eval(`(${extract("renderModelMenu")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

console.log("renderModelMenu: lists models with active flag")
{
  const models = [
    { id: "deepseek/v4-pro", name: "V4 Pro" },
    { id: "deepseek/v4-flash", name: "V4 Flash" },
  ]
  const items = renderModelMenu(models, "deepseek/v4-flash")
  check("2 items", items.length === 2)
  check("first not active", items[0].active === false)
  check("second active", items[1].active === true && items[1].id === "deepseek/v4-flash")
  check("name preserved", items[0].name === "V4 Pro")
}

console.log("renderModelMenu: no match current")
{
  const items = renderModelMenu([{ id: "a", name: "A" }], "zzz")
  check("active false when no match", items[0].active === false)
}

console.log("renderModelMenu: empty/null")
{
  check("empty array", renderModelMenu([], "x").length === 0)
  check("null array", renderModelMenu(null, "x").length === 0)
  check("undefined array", renderModelMenu(undefined, "x").length === 0)
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
