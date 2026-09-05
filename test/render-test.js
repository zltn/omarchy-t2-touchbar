// Differential test: the QML service's rendering must produce byte-identical
// output to the Python daemon it replaces, or a machine that switches to the
// plugin gets a subtly different Touch Bar.
//
// Run: node test/render-test.js
// It shells out to test/python-reference.py for the expected values, so both
// implementations are exercised against the same matrix on every run.

const fs = require("fs")
const path = require("path")
const { execFileSync } = require("child_process")

const root = path.join(__dirname, "..")

// `.pragma library` is a QML directive node cannot parse; strip it.
const src = fs.readFileSync(path.join(root, "lib/TouchBar.js"), "utf8")
  .replace(/^\s*\.pragma\s+library\s*$/m, "")
const TouchBar = {}
new Function("exports", src + "\n" +
  "exports.renderWorkspaceRows = renderWorkspaceRows;" +
  "exports.renderConfig = renderConfig;" +
  "exports.batteryColour = batteryColour;" +
  "exports.batteryBucket = batteryBucket;" +
  "exports.batterySvg = batterySvg;" +
  "exports.updateSvg = updateSvg;" +
  "exports.parseBattery = parseBattery;" +
  "exports.readFlag = readFlag;")(TouchBar)

const expected = JSON.parse(
  execFileSync("python3", [path.join(__dirname, "python-reference.py")], { encoding: "utf8" }))

let failures = 0
let checks = 0

function eq(label, got, want) {
  checks++
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g !== w) {
    failures++
    console.log(`FAIL ${label}\n  js:     ${g}\n  python: ${w}`)
  }
}

// Workspace rows, across every active value including "none focused".
for (const c of expected.workspaceRows) {
  eq(`renderWorkspaceRows(${c.count}, ${c.active})`,
    TouchBar.renderWorkspaceRows(c.count, c.active), c.out)
}

// Battery colour and bucket across the boundaries that matter (5%, 20%) and
// the charging override.
for (const c of expected.batteryColour) {
  eq(`batteryColour(${c.pct}, ${c.charging})`,
    TouchBar.batteryColour(c.pct, c.charging), c.out)
}
for (const c of expected.batteryBucket) {
  eq(`batteryBucket(${c.pct}, ${c.charging})`,
    TouchBar.batteryBucket(c.pct, c.charging), c.out)
}

// The generated SVGs, compared as exact strings.
for (const c of expected.batterySvg) {
  eq(`batterySvg(${c.pct}, ${c.charging})`,
    TouchBar.batterySvg(c.pct, c.charging), c.out)
}
for (const c of expected.updateSvg) {
  eq(`updateSvg(${c.available})`, TouchBar.updateSvg(c.available), c.out)
}

// Battery parsing, including the 101%-on-a-worn-cell clamp and the fall back
// to `capacity` when charge_now/charge_full are missing.
for (const c of expected.parseBattery) {
  const got = TouchBar.parseBattery(c.status, c.now, c.full, c.capacity)
  eq(`parseBattery(${JSON.stringify([c.status, c.now, c.full, c.capacity])})`,
    got === null ? null : [got.percent, got.charging], c.out)
}

for (const c of expected.readFlag) {
  eq(`readFlag(${JSON.stringify(c.text)})`, TouchBar.readFlag(c.text), c.out)
}

// Full config render against the real template, so @WORKSPACES@ substitution
// is checked in place rather than in isolation.
eq("renderConfig", TouchBar.renderConfig(expected.template.input, 5, 3),
  expected.template.out)

console.log(`\n${checks - failures}/${checks} checks passed`)
process.exit(failures === 0 ? 0 : 1)
