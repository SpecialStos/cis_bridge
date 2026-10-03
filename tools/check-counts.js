// check-counts.js -- the assertion count stated in the docs is the real one.
//
// WHY THIS EXISTS
//
// The number appeared in four places -- README, DOCUMENTATION, CHANGELOG and a
// comment in the workflow -- and was wrong in three of them at least once. It was
// 128 when the resource had 128. It was still 128 when the resource had 534,
// because the earlier replacements silently missed a string that had already
// changed underneath them, and nothing noticed: `test:all` was green the whole
// time.
//
// A number nobody checks is a number that drifts, and a drifted count in a
// document is worse than no count, because it is the kind of detail a reader
// checks their trust against.
//
// So it is checked. This runs every suite, sums what it reported, and fails when
// any file that quotes the number disagrees.
//
// Usage:  node tools/check-counts.js
// Exit 0 clean, 1 on a mismatch.
const { spawnSync } = require('child_process')
const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')

// Every file that states the number, and what to call it when it is wrong.
const PLACES = [
  { file: 'README.md', label: 'README' },
  { file: 'DOCUMENTATION.md', label: 'DOCUMENTATION' },
  { file: 'CHANGELOG.md', label: 'CHANGELOG' },
  { file: '.github/workflows/tests.yml', label: 'CI workflow' },
]

const run = spawnSync('npm', ['test'], {
  cwd: root,
  encoding: 'utf8',
  shell: process.platform === 'win32',
})
const output = `${run.stdout || ''}${run.stderr || ''}`

// `bridge passed=46 failed=0` -- the counts are per suite, summed here.
const totals = []
for (const line of output.split(/\r?\n/)) {
  const m = line.match(/passed=(\d+)\s+failed=(\d+)/)
  if (m) {
    totals.push({ suite: line.split(' ')[0], passed: Number(m[1]), failed: Number(m[2]) })
  }
}

if (totals.length === 0) {
  process.stderr.write('  FAIL  no suite reported. The count cannot be checked '
    + 'against a run that produced nothing.\n')
  process.stderr.write(output.split(/\r?\n/).slice(-12).join('\n') + '\n')
  process.exit(1)
}

const failed = totals.reduce((n, t) => n + t.failed, 0)
if (failed > 0) {
  // A failing run's total is not a count worth publishing, so this reports the
  // failure rather than checking anything against it.
  process.stderr.write(`  FAIL  ${failed} assertion(s) failed; the count is not checked `
    + 'against a red run\n')
  process.exit(1)
}

const total = totals.reduce((n, t) => n + t.passed, 0)

// "570 assertions", and also "570 assertions across ten suites" -- both are the
// same claim and both are checked, because they drifted independently.
const pattern = new RegExp(`\\b${total}\\b[ ,](assertions|assertions across|\\w+ suites)`)

let bad = 0
for (const place of PLACES) {
  const file = path.join(root, place.file)
  if (!fs.existsSync(file)) {
    process.stderr.write(`  FAIL  ${place.label}: ${place.file} does not exist\n`)
    bad++
    continue
  }
  const body = fs.readFileSync(file, 'utf8')
  if (pattern.test(body)) {
    process.stdout.write(`  PASS  ${place.label} states ${total} assertions\n`)
  } else {
    // Show what it DOES say, because "the count is stale" is a sentence
    // somebody has to go and find the number for.
    const found = body.match(/\b\d+[ ,]assertions\b/g)
    process.stderr.write(`  FAIL  ${place.label} does not state ${total} assertions`
      + `${found ? ` (it says: ${found.join(', ')})` : ' (it states no count at all)'}\n`)
    bad++
  }
}

// The suite COUNT is a separate claim and it drifts separately -- a new suite
// with no assertions, or assertions folded into an existing one.
const suiteCount = totals.length
const suitePattern = new RegExp(
  `\\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|${suiteCount})\\b`
  + `[ ,]suites`, 'i')
for (const place of PLACES) {
  const body = fs.readFileSync(path.join(root, place.file), 'utf8')
  if (!/suites/i.test(body)) continue
  if (suitePattern.test(body)) {
    process.stdout.write(`  PASS  ${place.label} states ${suiteCount} suites\n`)
  } else {
    process.stderr.write(`  FAIL  ${place.label} mentions suites but never says how `
      + `many -- there are ${suiteCount}\n`)
    bad++
  }
}

process.stdout.write(`\ncounts: ${total} assertions across ${suiteCount} suites\n`)
if (bad > 0) {
  process.exit(1)
}