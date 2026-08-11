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

globalThis.renderMd = (s) => `[md:${s ?? ""}]`
globalThis.esc = (s) => String(s)

const renderSystemBlocks = eval(`(${extract("renderSystemBlocks")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

console.log("scenario A: env block preserved as pre, identity + markdown after")
const promptA = [
  "You are z-agent-core, an interactive CLI agent.",
  "",
  "<env>",
  "  Workspace root: /test",
  "  Platform: windows",
  "  Model: deepseek-v4-flash",
  "</env>",
  "",
  "# AGENTS.md",
  "",
  "**bold** text",
].join("\n")
const outA = renderSystemBlocks(promptA)
check("identity line via renderMd", outA.includes("[md:You are z-agent-core"))
check("env block uses pre.sys-block", outA.includes('<pre class="sys-block"><env>'))
check("env whitespace preserved", outA.includes("  Workspace root: /test"))
check("env close tag preserved", outA.includes("</env></pre>"))
// text after the env block (not wrapped in a semantic tag) is markdown
check("AGENTS heading via renderMd", outA.includes("[md:# AGENTS.md"))
check("markdown body via renderMd", outA.includes("**bold** text]"))

console.log("scenario B: project_context preserved as pre (not markdown)")
const promptB = [
  "intro",
  "",
  "<project_context>",
  "# AGENTS.md — Test",
  "",
  "**项目说明**",
  "</project_context>",
].join("\n")
const outB = renderSystemBlocks(promptB)
check("intro via renderMd", outB.includes("[md:intro]"))
check("project_context uses pre.sys-block", outB.includes('<pre class="sys-block"><project_context>'))
check("wrapper content preserved", outB.includes("# AGENTS.md — Test"))
check("markdown source not rendered (pre shows raw)", outB.includes("**项目说明**"))
check("wrapper close tag preserved", outB.includes("</project_context></pre>"))

console.log("scenario C: available_skills preserved as pre")
const promptC = [
  "<available_skills>",
  "  a-skill: A skill",
  "  z-skill: Z skill",
  "</available_skills>",
].join("\n")
const outC = renderSystemBlocks(promptC)
check("skills block uses pre.sys-block", outC.includes('<pre class="sys-block"><available_skills>'))
check("skills indentation preserved", outC.includes("  a-skill: A skill"))
check("skills close tag preserved", outC.includes("</available_skills></pre>"))

console.log("scenario D: no skills empty state (no wrapper tag)")
const outD = renderSystemBlocks("No skills are currently available.")
check("empty state rendered (via renderMd)", outD.includes("[md:No skills are currently available.]"))

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
