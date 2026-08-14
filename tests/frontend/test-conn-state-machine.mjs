import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../../src/frontends/web/app.js", import.meta.url), "utf8")

// --- extract `var conn = {...}` object literal via brace matching ---
function extractConn() {
  const start = src.indexOf("var conn = {")
  if (start < 0) throw new Error("conn not found")
  const bodyStart = src.indexOf("{", start)
  let depth = 0
  for (let i = bodyStart; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}") { depth--; if (depth === 0) return src.slice(start, i + 1) }
  }
  throw new Error("unbalanced conn")
}

// --- stubs: conn.go references setTimeout/clearTimeout/showStatusBanner/loadSession/currentId ---
let banner = null
globalThis.showStatusBanner = (msg, kind) => { banner = { msg, kind, parentNode: { removeChild() {} } }; return banner }
globalThis.loadSession = () => Promise.resolve()
globalThis.currentId = "sess-1"

// schedule timers synchronously for deterministic tests
let timers = []
globalThis.setTimeout = (fn, ms) => { timers.push({ fn, ms }); return timers.length }
globalThis.clearTimeout = (id) => { timers = timers.filter((t) => timers.indexOf(t) !== id - 1) }

const raw = extractConn()
const objSrc = raw.slice("var conn = ".length)
const conn = eval(`(${objSrc})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }
function runTimers() { const todo = timers.splice(0); todo.forEach((t) => t.fn()) }
const flushMicro = () => new Promise((r) => setImmediate(r))

// --- transitions ---
// 1. idle -> send -> streaming
conn.phase = "idle"
conn.go("send")
check("idle send -> streaming", conn.phase === "streaming")

// 2. streaming -> done -> idle
conn.go("done")
check("streaming done -> idle", conn.phase === "idle")

// 3. streaming -> disconnect -> recovering
conn.phase = "streaming"
banner = null
conn.go("disconnect")
check("streaming disconnect -> recovering", conn.phase === "recovering")
check("recover banner shown", banner && banner.msg.includes("恢复会话"))

// 4. recovering -> recover_success -> idle (async loadSession resolves)
conn.phase = "recovering"
conn.banner = { parentNode: { removeChild() {} } }
conn.go("recover_success")
check("recover_success -> idle", conn.phase === "idle")
check("recover_success clears banner", conn.banner === null)

// 5. recovering -> recover_fail -> (retry) -> recover_fail -> degraded
conn.phase = "recovering"
conn.retry = 0
timers = []
conn.go("recover_fail") // schedules retry timer, retry=1
check("first recover_fail schedules timer", timers.length === 1)
check("first recover_fail stays recovering", conn.phase === "recovering")
check("retry count incremented", conn.retry === 1)
runTimers() // timer fires -> recover() -> loadSession resolves (microtask) -> recover_success
await flushMicro()
check("retry timer led to success -> idle", conn.phase === "idle")

// degraded path: force two recover_fail without intervening success
conn.phase = "recovering"
conn.retry = 0
conn.go("recover_fail") // retry=1, schedules timer
conn.retry = conn.MAX_RETRY // simulate the scheduled retry also failing
banner = null
conn.go("recover_fail") // retry >= MAX_RETRY -> degraded
check("second recover_fail -> degraded", conn.phase === "degraded")
check("degraded banner", banner && banner.msg.includes("刷新页面"))

// 6. recovering -> send -> streaming (clears timer, resets retry)
conn.phase = "recovering"
conn.retry = 1
timers = []
conn.timer = 123
conn.go("send")
check("recovering send -> streaming", conn.phase === "streaming")
check("retry reset on send", conn.retry === 0)
check("timer cleared on send", conn.timer === null)

// 7. degraded -> send -> streaming
conn.go("send")
check("degraded send -> streaming", conn.phase === "streaming")

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
