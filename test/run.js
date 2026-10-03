const fs = require('fs')
const path = require('path')
const fengari = require('fengari')

const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring

const root = path.join(__dirname, '..')
const L = lauxlib.luaL_newstate()
lualib.luaL_openlibs(L)

function runFile(rel) {
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
function readGlobal(name) {
  lua.lua_getglobal(L, toLua(name))
  const value = lua.lua_toboolean(L, -1)
  lua.lua_settop(L, -2)
  return value
}

// `adapters/discord/webhooks.lua` does `require 'adapters.discord.embed'`.
// fengari's default package.path is the process working directory, which is
// not guaranteed to be this repository -- so on a run from anywhere else the
// require fails with "module not found" and it looks like the adapter is broken.
lauxlib.luaL_dostring(L, toLua(`package.path = ${JSON.stringify(root.replace(/\\/g, '/') + '/?.lua')}`))

// Three suites, in dependency order. Each stands its own FiveM stubs up inside
// the Lua, where they can be shaped per case -- which is the only way an adapter
// can be asked the question that actually matters ("what did you hand the third
// party?") rather than the one that is easy to fake ("what did it return?").
//
// shared/bridge.lua is loaded first, as a real file, because the registration
// helper is what both later suites stand on.
//
// No suite calls os.exit. It would take the whole fengari state down mid-run, so
// a failure in the second file was reported against the first and the third
// never ran at all. Each suite sets the global `__suite_failed` instead, and the
// exit code is decided here -- after every suite has run and every suite has
// been allowed to report.
const SUITES = [
  'test/bridge.lua',
  'test/adapters.lua',
]

runFile('shared/bridge.lua')
for (const suite of SUITES) {
  runFile(suite)
}

if (readGlobal('__suite_failed')) {
  process.exitCode = 1
}