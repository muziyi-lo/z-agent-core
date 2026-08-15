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

const sessionExportFileName = eval(`(${extract("sessionExportFileName")})`)

let pass = 0, fail = 0
function check(name, cond) { if (cond) { pass++; console.log("  ok " + name) } else { fail++; console.log("  FAIL " + name) } }

console.log("sessionExportFileName: named sessions")
check("plain name kept", sessionExportFileName({ name: "grep regex test", id: "abc" }) === "grep regex test.json")
check("chinese name kept", sessionExportFileName({ name: "你好世界", id: "abc" }) === "你好世界.json")
check("spaces trimmed", sessionExportFileName({ name: "  hello  ", id: "abc" }) === "hello.json")
check("invalid chars replaced", sessionExportFileName({ name: "a/b\\c:d*e?f\"g<h>i|j", id: "abc" }) === "a_b_c_d_e_f_g_h_i_j.json")
check("control chars replaced", sessionExportFileName({ name: "a\x00b\x1f", id: "abc" }) === "a_b_.json")
check("trailing dot stripped", sessionExportFileName({ name: "chat.", id: "abc" }) === "chat.json")
check("trailing spaces stripped", sessionExportFileName({ name: "chat   ", id: "abc" }) === "chat.json")
check("leading dot stripped", sessionExportFileName({ name: "...hidden", id: "abc" }) === "hidden.json")
check("overlong truncated", sessionExportFileName({ name: "x".repeat(300), id: "abc" }).length === 105)

console.log("sessionExportFileName: fallback to id")
check("uuid name falls back", sessionExportFileName({ name: "52f07232-780e-40fb-a77d-0e81bea4398c", id: "myid" }) === "session-myid.json")
check("uuid uppercase falls back", sessionExportFileName({ name: "52F07232-780E-40FB-A77D-0E81BEA4398C", id: "myid" }) === "session-myid.json")
check("empty name falls back", sessionExportFileName({ name: "", id: "myid" }) === "session-myid.json")
check("blank name falls back", sessionExportFileName({ name: "   ", id: "myid" }) === "session-myid.json")
check("missing name falls back", sessionExportFileName({ id: "myid" }) === "session-myid.json")
check("sanitized-to-empty falls back", sessionExportFileName({ name: "...", id: "myid" }) === "session-myid.json")

console.log(`\nresult: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
