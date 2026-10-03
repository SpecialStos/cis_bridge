// syntax.js -- parse every .lua file, and prove every `require` resolves.
//
// The file is still called luacheck.js because the CI step that runs it is the
// Lua syntax check, and renaming it would break the workflow and the README for
// no benefit. It is NOT luacheck; the real linter is tools/lint.js, which shells
// out to the luarock package.
//
// WHY IT EXISTS: a parse error in the shipped Lua is expensive to find. FiveM
// reports it on resource start, the resource still says "Started", and every
// later command that depends on it fails with a misleading message.
//
// fengari is already a dependency and is a real Lua parser, so this needs
// nothing installed. It cannot parse FiveM's backtick hash literals
// (`` `WEAPON_X` ``), which is the same exemption CI applies, so those are
// reported as skipped rather than failures.
//
// THE SECOND JOB, WHICH IS THE INTERESTING ONE
//
// Two modules are loaded by `require` rather than listed in fxmanifest:
// `adapters/discord/embed.lua` and `server/ratelimit.lua`. Both have to be
// loadable without the FiveM engine so a unit suite can exercise them, and that
// is a real benefit -- the empty-footer 400 and the cooldown guard are exactly
// the two things that should not be verified only on a live server.
//
// It is also a real risk. A typo in either path fails nothing here, nothing in
// `npm test`, and nothing in CI. It raises during resource load, on a customer's
// server, with a green build behind it. So the paths are resolved against the
// same tree the engine would resolve them from, before that can happen.
//
// The module name uses `.` as a directory separator, which is what Lua's
// `require` does with it. That is checked rather than assumed, because it is the
// sort of thing that is true everywhere except the one place you needed it.
//
// Usage:  node tools/luacheck.js
// Exit 0 clean, 1 on a syntax error or an unresolvable require.
const fs = require('fs')
const path = require('path')
const fengari = require('fengari')
const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLu = fengari.to_luastring

const root = path.join(__dirname, '..')
const SKIP_DIRS = new Set(['node_modules', '.git', '.zcode', 'cache', 'reports'])

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(e.name)) continue
    const p = path.join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.lua')) out.push(p)
  }
  return out
}

// Remove Lua comments so prose in a header cannot trip a check about code.
//
// A block comment may sit anywhere, including inside a string literal, so this
// is a scanner and not a regex substitution. It also rewrites the file onto a
// single line -- which is fine here, because the only thing done with the result
// is a search for `require` paths, and a `require` split across two lines was
// never going to be found by a one-line regex anyway.
function stripComments(src) {
  let out = ''
  let i = 0
  const n = src.length
  while (i < n) {
    const c = src[i]
    const d = src[i + 1]
    if (c === '-' && d === '-') {
      // `--[[ ... ]]` block comment, or `--[==[ ... ]==]`.
      const open = /^--\[(=*)\[/.exec(src.slice(i))
      if (open) {
        const close = `]${open[1]}]`
        const end = src.indexOf(close, i + open[0].length)
        i = end < 0 ? n : end + close.length
        out += ' '
        continue
      }
      const end = src.indexOf('\n', i)
      i = end < 0 ? n : end
      out += ' '
      continue
    }
    if (c === '"' || c === "'") {
      const quote = c
      out += c
      i++
      while (i < n) {
        if (src[i] === '\\') {
          out += src.slice(i, i + 2)
          i += 2
          continue
        }
        out += src[i]
        if (src[i] === quote) {
          i++
          break
        }
        i++
      }
      continue
    }
    if (c === '\n') {
      out += ' '
      i++
      continue
    }
    out += c
    i++
  }
  return out
}

const files = walk(root)
let failed = 0
let skipped = 0
let requires = 0

for (const abs of files) {
  const rel = path.relative(root, abs)
  const src = fs.readFileSync(abs, 'utf8')

  // The require check runs on the shipped code only. The suites DO use dofile
  // against paths that exist, but they are allowed to reach into a tree the
  // manifest does not, and a test failing to find its own fixture should be a
  // test failure with a readable name rather than a path complaint from here.
  const isTest = rel.split(path.sep).includes('test') || rel.split(path.sep)[0] === 'test'
  if (!isTest) {
    const code = stripComments(src)
    const re = /require\s*\(?\s*['"]([^'"]+)['"]/g
    let m
    while ((m = re.exec(code)) !== null) {
      requires++
      const asPath = m[1].split('.').join(path.sep) + '.lua'
      const target = path.join(root, asPath)
      if (!fs.existsSync(target)) {
        console.error(`FAIL  ${rel}: require '${m[1]}' does not resolve`)
        console.error(`      expected ${asPath} at the resource root`)
        failed++
      }
    }
  }

  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  const status = lauxlib.luaL_loadbuffer(L, toLu(src), toLu(rel))

  if (status === lua.LUA_OK) {
    continue
  }
  const err = lua.lua_tojsstring(L, -1)

  // FiveM hash literals are not valid standard Lua. Same exemption CI gives,
  // and it is safe: these files are not run outside the engine. Matched on the
  // backtick itself rather than the whole message, so a real syntax error that
  // happens to say "unexpected symbol near" is still reported.
  if (err.includes("near '`'")) {
    console.log(`skip  ${rel}  (FiveM backtick hash literal)`)
    skipped++
    continue
  }
  console.error(`FAIL  ${rel}\n      ${err}`)
  failed++
}

console.log(`\nsyntax: ${files.length} files, ${requires} require(s) resolved, `
  + `${failed} error(s), ${skipped} skipped`)
process.exit(failed ? 1 : 0)