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
const decorateCodeBlocks = eval(`(${extract("decorateCodeBlocks")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

console.log("decorateCodeBlocks: adds banner before code")
{
  const html = '<pre><code class="language-powershell">foo</code></pre>'
  const out = decorateCodeBlocks(html)
  check("has code-banner", out.includes('class="code-banner"'))
  check("has lang label", out.includes('powershell'))
  check("wraps in code-block", out.includes('class="code-block"'))
  check("closing div", out.endsWith('</code></pre></div>'))
}

console.log("decorateCodeBlocks: multiple blocks")
{
  const html = '<pre><code class="language-js">a</code></pre><pre><code class="language-zig">b</code></pre>'
  const out = decorateCodeBlocks(html)
  check("2 banners", (out.match(/class="code-banner"/g) || []).length === 2)
  check("2 lang labels", out.includes('js') && out.includes('zig'))
}

console.log("decorateCodeBlocks: no language class")
{
  const html = '<pre><code>plain</code></pre>'
  const out = decorateCodeBlocks(html)
  check("no banner when no lang", !out.includes('code-banner'))
}

console.log("decorateCodeBlocks: null/empty")
{
  check("null returns null", decorateCodeBlocks(null) === null)
  check("empty returns empty", decorateCodeBlocks("") === "")
}

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
