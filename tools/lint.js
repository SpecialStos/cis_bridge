// lint.js -- run luacheck, and be honest when it is not there.
//
// `npm run test:syntax` is a SYNTAX check. It uses fengari, which is already a
// dependency, and it answers one question: does every file parse. That question
// has to be answerable anywhere, with nothing installed.
//
// This answers a different one: is the code actually sound -- unused locals,
// shadowed names, accidental globals, variables read on a path that never
// assigns them. luacheck is a luarock package, not an npm one, so it is not in
// package-lock and `npm ci` will not bring it. CI installs it; a developer may
// not have it.
//
// WHICH IS WHY THE MISSING CASE MATTERS, TWICE OVER.
//
// A wrapper that shells out and returns luacheck's exit code exits 1 when
// luacheck is absent -- which reads as "your code failed lint" and sends
// somebody hunting through their own source for a problem that is not there.
// The inverse is worse: exiting 0 would make an absent tool indistinguishable
// from clean code, and "no findings" would be reported as a pass.
//
// So the missing case prints that the check DID NOT RUN and exits 0, while CI
// installs luacheck first and therefore actually runs it.
//
// DETECTING "ABSENT" IS THE SUBTLE PART. With `shell: true` on Windows a
// missing executable is not a spawn error at all -- the shell starts, prints
// "'luacheck' is not recognized as an internal or external command" to stderr
// and exits 1. So `result.error` is nil and `result.status` is 1, which is
// indistinguishable from luacheck itself reporting one finding. Checking only
// `result.error` therefore reports every finding on a machine without luacheck
// as a lint failure, and exits 0 on the same machine if the count happens to be
// different. The message text is what tells them apart.
//
// Usage:  node tools/lint.js
// Exit 0 clean, 1 on a finding, 0-and-warned when luacheck is absent.
const { spawnSync } = require('child_process')
const path = require('path')

const root = path.join(__dirname, '..')
const useShell = process.platform === 'win32'

function probe() {
  const r = spawnSync('luacheck', ['--version'], {
    cwd: root,
    encoding: 'utf8',
    shell: useShell,
  })
  const output = `${r.stdout || ''}${r.stderr || ''}`
  const notFound = r.error !== undefined && r.error !== null
    || /not recognized|not found|command not found|no such file/i.test(output)
  return { available: !notFound, output }
}

if (!probe().available) {
  console.warn('')
  console.warn('  luacheck is not installed, so this check DID NOT RUN.')
  console.warn('  Do not read the absence of findings as a pass.')
  console.warn('  Install it with:  luarocks install luacheck')
  console.warn('  CI installs it and does run it.')
  console.warn('')
  process.exit(0)
}

const result = spawnSync('luacheck', ['.'], {
  cwd: root,
  stdio: 'inherit',
  shell: useShell,
})

process.exit(result.status === null ? 1 : result.status)