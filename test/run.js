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

// Every adapter is a thin wrapper around a third-party export, so there is very
// little pure logic here to unit test -- and pretending otherwise would be
// testing the mock. What IS worth checking without a server is the registration
// helper, because its four conditions are the difference between an adapter
// that works and one that raises on every call. The FiveM stubs it needs are
// stood up inside the Lua test, where they can be shaped per case.
runFile('shared/bridge.lua')
runFile('test/bridge.lua')
