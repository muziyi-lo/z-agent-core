// Regression test: renderMd must forbid <style>/<link> injection (XSS via tool output).
// Root cause: DOMPurify.sanitize default ALLOWS <style>, so curl output containing
// example.com's <style>body{width:60vw}</style> polluted the global layout.
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

// Stub the browser globals renderMd depends on.
// Simulate DOMPurify: ALWAYS removes <script>; removes <style> ONLY if FORBID_TAGS includes it.
let sanitizeCalls = []
globalThis.marked = { parse: (c) => `<p>${c}</p>` }
globalThis.DOMPurify = {
  sanitize: (raw, opts) => {
    sanitizeCalls.push(opts || {})
    const forbid = (opts && opts.FORBID_TAGS) || []
    let out = raw.replace(/<script>[\s\S]*?<\/script>/gi, "")
    if (forbid.includes("style")) {
      out = out.replace(/<style>[\s\S]*?<\/style>/gi, "")
    }
    return out
  },
}
globalThis.decorateCodeBlocks = (html) => html

const renderMd = eval(`(${extract("renderMd")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

console.log("renderMd: forbids style/link injection")
{
  sanitizeCalls = []
  renderMd._cache = []
  const out = renderMd("<style>body{width:60vw;margin:15vh auto}</style>hello <script>bad()</script>")
  const opts = sanitizeCalls[sanitizeCalls.length - 1] || {}
  check("DOMPurify FORBID_TAGS includes style", Array.isArray(opts.FORBID_TAGS) && opts.FORBID_TAGS.includes("style"))
  check("DOMPurify FORBID_TAGS includes link", Array.isArray(opts.FORBID_TAGS) && opts.FORBID_TAGS.includes("link"))
  check("output has no <style>", !out.includes("<style"))
  check("output has no <script>", !out.includes("<script"))
}

console.log("renderMd: still renders normal markdown")
{
  renderMd._cache = []
  const out = renderMd("**bold** and `code`")
  check("normal markdown preserved", out.includes("bold"))
}

console.log(`\n${fail === 0 ? "PASS" : "FAIL"}: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
