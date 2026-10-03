const fs = require('fs')
const path = require('path')
const fengari = require('fengari')

const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring

const root = path.join(__dirname, '..')

// `adapters/discord/webhooks.lua` does `require 'adapters.discord.embed'`.
// fengari's default package.path is the process working directory, which is not
// guaranteed to be this repository -- so on a run from anywhere else the require
// fails with "module not found" and it reads as the adapter being broken.
const LUA_PATH = root.replace(/\\/g, '/') + '/?.lua'

// A fresh interpreter per suite.
//
// They shared one state until the report suite started failing on rows it had
// never touched, and the cause was worth more than the symptom: `Bridge` keeps
// its registered map and its outcome table in LOCALS, so the adapters
// test/adapters.lua registered were still registered when test/report.lua asked
// what was registered. The report was not wrong about anything -- it was
// reading another suite's world, and `inventoryProvider` came back healthy
// because a file in a different state had filled it in.
//
// Sharing a state also makes the suites order-dependent in a way nothing
// declares: a suite that happens to run second sees whatever the first left
// behind. Each suite now loads shared/bridge.lua for itself, which is what
// independence means here, and which is also how the resource actually runs --
// one server, one Bridge.
function newState() {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  lauxlib.luaL_dostring(L, toLua(`package.path = ${JSON.stringify(LUA_PATH)}`))
  return L
}

function runFile(L, rel) {
  const src = fs.readFileSync(path.join(root, rel), 'utf8')
  const status = lauxlib.luaL_dostring(L, toLua(src))
  if (status !== lua.LUA_OK) {
    const err = lua.lua_tojsstring(L, -1)
    throw new Error(`${rel}: ${err}`)
  }
}

// Read a global off the Lua stack and leave the stack as it was found.
//
// `lua_getglobal` pushes, so the value has to be popped whatever it turns out to
// be. `-2` is the standard "pop one" index; writing it as `-(2) - 1` produces
// -3, which asks Lua to shrink the stack below its base and raises "invalid new
// top" -- a crash in the harness that reads exactly like a crash in the code
// under test.
function readGlobal(L, name) {
  lua.lua_getglobal(L, toLua(name))
  const value = lua.lua_toboolean(L, -1)
  lua.lua_settop(L, -2)
  return value
}

// Each suite names its own file. shared/bridge.lua is loaded underneath every
// one of them rather than once at the top, which is the same reason: a helper
// that outlives its suite is a helper nobody can reset.
//
// No suite calls os.exit. It would take the whole process down mid-run, so a
// failure in one file was reported against the previous one and the rest never
// ran at all. Each sets the global `__suite_failed` instead, and the exit code
// is decided here -- after every suite has run and every suite has reported.
const SUITES = [
  'test/bridge.lua',
  'test/adapters.lua',
  'test/report.lua',
]

let failed = false
for (const suite of SUITES) {
  const L = newState()
  runFile(L, 'shared/bridge.lua')
  runFile(L, suite)
  if (readGlobal(L, '__suite_failed')) {
    failed = true
  }
}

if (failed) {
  process.exitCode = 1
}