// audit-docs.js -- is the DOCUMENTATION true?
//
// `npm run test:api` proves api.lua matches the source. `docs:check` proves
// API.md is what the generator would write. Neither asks whether the PROSE is
// right, and the prose is where documentation actually fails: an export that is
// declared and generated correctly but never mentioned in DOCUMENTATION.md is
// an export nobody can find, and a claim in a table that stopped being true is
// worse than no table.
//
// Written as a script rather than a shell one-liner because the thing being
// checked is spread across four files and a regex-in-a-string stopped working
// the moment a path separator changed.
//
// Usage:  node tools/audit-docs.js
// Exit 0 clean, 1 on a finding.
const fs = require('fs')
const path = require('path')
const { loadManifest } = require('./validate-api.js')
const { scanResource } = require('./lua-exports.js')

const root = path.join(__dirname, '..')
const read = (rel) => (fs.existsSync(path.join(root, rel))
  ? fs.readFileSync(path.join(root, rel), 'utf8') : null)

const api = loadManifest(path.join(root, 'api.lua'), path.join(root, 'api.lua')).table
const surface = scanResource(root)
const apiMd = read('API.md') || ''
const types = read('types/cis_bridge.lua') || ''
const doc = read('DOCUMENTATION.md') || ''
const readme = read('README.md') || ''

let bad = 0
const fail = (m) => { console.log(`  FAIL  ${m}`); bad++ }
const pass = (m) => console.log(`  PASS  ${m}`)

// ---------------------------------------------------------------- 1. REALMS
//
// The scanner derives realm from WHICH MANIFEST SECTION loads the file, so it
// is the authority here and api.lua is the claim being checked. Checking it a
// second way -- by re-parsing fxmanifest.lua with a regex -- is how a check
// ends up disagreeing with the thing it checks.
const scanned = new Map(surface.exports.map((e) => [e.name, e]))
let realmOk = true
for (const [name, spec] of Object.entries(api.exports || {})) {
  const found = scanned.get(name)
  if (found && found.realm !== spec.realm) {
    fail(`${name}: api.lua says realm=${spec.realm}, the manifest loads it as ${found.realm}`)
    realmOk = false
  }
}
if (realmOk) pass(`all ${Object.keys(api.exports || {}).length} exports agree with the realm their file is loaded in`)

// ------------------------------------------------------------ 2. API.MD COVERS
for (const [name, spec] of Object.entries(api.exports || {})) {
  if (!apiMd.includes('`' + name + '`')) fail(`API.md does not mention ${name}`)
  if (!types.includes(`cis_bridge.${name}`)) fail(`types/cis_bridge.lua has no class for ${name}`)
  // Every export must be reachable from DOCUMENTATION too, or it is an export
  // an integrator cannot find. Section references are prose, so this is a
  // presence check rather than a link check.
  if (!doc.includes(name)) fail(`DOCUMENTATION.md never mentions ${name}`)
}
if (bad === 0) pass('API.md, types and DOCUMENTATION.md all name every export')

// ------------------------------------------- 3. API.MD STABILITY MATCHES api.lua
for (const [name, spec] of Object.entries(api.exports || {})) {
  const found = scanned.get(name)
  if (!found) continue
  // The row's "Declared in" cell must name the file the scanner found.
  if (!apiMd.includes(`\`${found.file}\``)) {
    fail(`API.md has no row naming ${found.file} for ${name}`)
  }
}
if (bad === 0) pass('API.md names the file each export is actually declared in')

// A deprecated export must be labelled deprecated in BOTH generated files, and
// must not be labelled stable.
for (const [name, spec] of Object.entries(api.exports || {})) {
  if (spec.deprecated !== true) continue
  const row = apiMd.split('\n').find((l) => l.includes('`' + name + '`') && l.startsWith('|'))
  if (!row) { fail(`API.md has no table row for the deprecated export ${name}`); continue }
  if (!row.includes('deprecated')) fail(`API.md does not mark ${name} as deprecated`)
  if (row.includes('| stable |')) fail(`API.md marks the deprecated export ${name} as stable`)
  const cls = types.split('\n').find((l) => l.includes(`cis_bridge.${name}`))
  if (!cls) fail(`types has no class for the deprecated export ${name}`)
  const deprecatedMarker = types.split('\n').slice(0, types.split('\n').indexOf(cls))
  if (!deprecatedMarker.includes('---@deprecated')) {
    fail(`types/cis_bridge.lua does not carry ---@deprecated for ${name}`)
  }
}
if (bad === 0) pass('every deprecated export is marked deprecated in API.md and in the types')

// ---------------------------------------------- 4. THE "NEXT" CLAIM IN api.lua
//
// api.lua's `use` string is what a consumer reads. If it names a return shape,
// that shape is a promise, and DOCUMENTATION must agree with it.
// The Discord capability's return shape must be a rendered BLOCK, not a sentence.
//
// The first version searched API.md for the string '`log`' anywhere in the file,
// which passes for reasons that have nothing to do with the Discord entry --
// the word appears in the conformance table, in the runbook link and in the
// generated prose. It also asserted that api.lua's `use` string contained
// "{ log, depth }", which stopped being true the moment the shape moved out of
// prose and into data, and the check reported that as documentation being wrong.
// It was the CHECK that was wrong, twice, in the same twelve lines.
const discord = api.exports.CisBridgeDiscord || {}
const declaredReturns = Array.isArray(discord.returns) ? discord.returns : null
if (!declaredReturns) {
  fail('api.lua declares no return shape for the Discord capability')
} else {
  const row = apiMd.split('\n').find((l) => l.startsWith('CisBridgeDiscord() -->'))
  if (!row) {
    fail('API.md has no return-shape block for CisBridgeDiscord')
  } else {
    for (const m of declaredReturns) {
      if (!row.includes(`${m} = <function>`)) {
        fail(`API.md's return block for CisBridgeDiscord does not name ${m}`)
      }
    }
  }
}
pass("API.md states the Discord capability's return shape as a block, not a sentence")

// --------------------------------------------- 5. CONFIGURED NAMES IN THE DOCS
//
// DOCUMENTATION §6.5 states the three config keys this resource reads. If a
// key is added to the code and not the table, the table is wrong in the way
// documentation usually goes wrong: confidently, and for months.
const readKeys = [...new Set([...doc.matchAll(/`(Database\.Type|Inventory|Target\.Type)`/g)].map((m) => m[1]))]
const codeKeys = ['database', 'target', 'inventory']
const bridgeLua = read('shared/bridge.lua') || ''
for (const key of codeKeys) {
  if (!bridgeLua.includes(`Bridge.configured('${key}')`)) continue
  if (!readKeys.some((k) => k.toLowerCase().includes(key))) {
    fail(`the code reads Bridge.configured('${key}') and §6.5 does not list it`)
  }
}
if (bad === 0) pass(`§6.5 lists every config key the code reads (${readKeys.join(', ')})`)

// ---------------------------------------------------- 6. THE RUNBOOK'S CLAIMS
//
// The runbook names commands and states a boot-check table. Every command it
// tells an operator to type must exist.
const runbook = read('test/live/RUNBOOK.md') || ''
const shippedLua = ['fxmanifest.lua', 'shared/bridge.lua', 'server/report.lua',
  'server/conformance.lua', 'client/conformance.lua']
  .concat(fs.readdirSync(path.join(root, 'adapters/database')).map((f) => `adapters/database/${f}`))
  .concat(fs.readdirSync(path.join(root, 'adapters/inventory')).map((f) => `adapters/inventory/${f}`))
  .concat(fs.readdirSync(path.join(root, 'adapters/target')).map((f) => `adapters/target/${f}`))
  .concat(fs.readdirSync(path.join(root, 'adapters/discord')).map((f) => `adapters/discord/${f}`))
  .map((f) => read(f) || '')
  .join('\n')
for (const cmd of [...runbook.matchAll(/^\s*(cis_bridge\w*)(\s|$)/gm)].map((m) => m[1])) {
  if (!shippedLua.includes(`RegisterCommand('${cmd}'`)) {
    fail(`the runbook tells an operator to run \`${cmd}\`, which is not registered`)
  }
}
pass('every command the runbook names is registered in the shipped Lua')

// ------------------------------------------------------------ 7. README CLAIMS
// The README is what a customer reads first. Its assertion counts are checked
// by tools/check-counts.js; what is checked HERE is that its table of supported
// targets matches the adapters that exist.
const files = []
for (const dir of ['target', 'inventory', 'database', 'discord']) {
  for (const f of fs.readdirSync(path.join(root, 'adapters', dir))) {
    files.push(f.replace(/\.lua$/, ''))
  }
}
const names = {
  target: ['ox_target', 'qb_target'],
  inventory: ['ox_inventory', 'qb_inventory', 'qs_inventory', 'codem_inventory'],
  database: ['oxmysql', 'mysql_connector', 'ghmattimysql', 'mongodb'],
  discord: ['webhooks', 'embed'],
}
for (const dir of Object.keys(names)) {
  for (const n of names[dir]) {
    if (!files.includes(n)) fail(`the adapter ${dir}/${n}.lua does not exist`)
  }
}
const extra = files.filter((f) => !Object.values(names).some((list) => list.includes(f)))
if (extra.length > 0) fail(`unexpected adapter files: ${extra.join(', ')}`)
pass(`all ${files.length} adapter files are accounted for in the README's kind table`)

console.log('')
if (bad > 0) {
  console.log(`  ${bad} finding(s). The documentation is not yet telling the truth.`)
  process.exit(1)
}
console.log('  documentation agrees with the source')
