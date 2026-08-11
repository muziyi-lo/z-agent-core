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
const groupSessions = eval(`(${extract("groupSessions")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

// fixed "now": 2026-08-11 12:00 UTC
const now = new Date(Date.UTC(2026, 7, 11, 12, 0, 0))
const day = 86400
const s = (id, ts) => ({ id, timestamp: ts })

console.log("groupSessions: pinned first")
{
  const list = [
    s("a", 1),                      // older
    s("b", now.getTime() / 1000),   // today
    s("c", now.getTime() / 1000 - day), // yesterday (same time prev day)
  ]
  const g = groupSessions(list, ["a"], now)
  check("pinned group has a", g.pinned.length === 1 && g.pinned[0].id === "a")
  check("today has b", g.today.length === 1 && g.today[0].id === "b")
  check("yesterday has c", g.yesterday.length === 1 && g.yesterday[0].id === "c")
  check("week empty", g.week.length === 0)
  check("older empty", g.older.length === 0)
}

console.log("groupSessions: no pinned")
{
  const list = [s("x", 1)]
  const g = groupSessions(list, [], now)
  check("older has x", g.older.length === 1 && g.older[0].id === "x")
  check("pinned empty", g.pinned.length === 0)
}

console.log("groupSessions: week boundary")
{
  const ts = now.getTime() / 1000 - 3 * day  // 3 days ago = this week
  const g = groupSessions([s("w", ts)], [], now)
  check("week has w", g.week.length === 1 && g.week[0].id === "w")
}

console.log("groupSessions: empty list")
{
  const g = groupSessions([], [], now)
  check("all empty", g.pinned.length === 0 && g.today.length === 0 && g.yesterday.length === 0 && g.week.length === 0 && g.older.length === 0)
}

console.log("groupSessions: null list")
{
  const g = groupSessions(null, [], now)
  check("all empty for null", g.pinned.length === 0 && g.older.length === 0)
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
