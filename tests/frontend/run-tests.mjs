// Frontend render-logic test runner.
// Usage: node tests/frontend/run-tests.mjs
// Runs every test-*.mjs in this directory as a subprocess and aggregates exit codes.
// Note: the shipped z-agent-core binary does NOT depend on Node — these are dev-only.
import { spawnSync } from "node:child_process"
import { readdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const dir = dirname(fileURLToPath(import.meta.url))
const tests = readdirSync(dir)
  .filter((f) => f.startsWith("test-") && f.endsWith(".mjs"))
  .sort()

if (tests.length === 0) {
  console.error("no tests found in " + dir)
  process.exit(1)
}

let failed = 0
for (const t of tests) {
  const r = spawnSync(process.execPath, [join(dir, t)], { stdio: "inherit" })
  if (r.status !== 0) failed++
}

if (failed === 0) {
  console.log(`\nAll ${tests.length} frontend test file(s) passed`)
  process.exit(0)
} else {
  console.error(`\n${failed}/${tests.length} frontend test file(s) failed`)
  process.exit(1)
}
