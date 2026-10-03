-- Tests for the boot report.
--
-- The report is the most support-cost-sensitive thing in this resource: it is
-- the artifact an operator pastes into a ticket instead of writing a paragraph
-- describing their server. So what is tested is not the printing -- which is
-- formatting -- but the DECISION it encodes: for every possible registration
-- outcome, does the report produce a row that names the cause AND a next step?
--
-- A row with an empty `fix` is a support ticket that has not been closed yet,
-- and that is the one failure mode this suite exists to catch.

local passed, failed = 0, 0
local failures = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
end

local clock = 0
_G.GetGameTimer = function() return clock end
_G.Wait = function(ms) clock = clock + (tonumber(ms) or 0) end
_G.GetCurrentResourceName = function() return 'cis_bridge' end
_G.GetResourceMetadata = function() return '1.1.0' end

-- `Bridge` is already loaded by test/run.js; these stubs are the same shape the
-- other suites stand up, kept local here so this file does not depend on the
-- order they were written in.
local started = {}
local registerFails = false
_G.GetResourceState = function(name) return started[name] or 'missing' end
-- `exports` is BOTH callable -- that is how a resource declares its own export
-- -- and indexable, because it is also how every adapter reaches a third party.
-- So the fake is a table carrying `cis_libs`, with a metatable supplying
-- `__call`.
--
-- The two are not interchangeable. Putting `cis_libs` inside the metatable makes
-- `exports.cis_libs` nil -- which is not a stub that reports itself missing, it
-- is a stub that raises "attempt to index a nil value" somewhere far from the
-- line that got it wrong.
_G.exports = setmetatable({
    cis_libs = {
        WaitReady = function() return true end,
        GetConfigSummary = function() return nil end,
        RegisterCapability = function()
            if registerFails then return false, 'held by another resource' end
            return true
        end,
        GetCapabilities = function() return _G.__caps end,
    },
}, {
    __call = function(_, name, fn) _G.__declared[name] = fn end,
})
_G.__declared = {}
_G.__caps = {}
_G.CreateThread = function() end

dofile('server/report.lua')
local GetBridgeReport = _G.__declared.GetBridgeReport

check(type(GetBridgeReport) == 'function', 'the report exports its rows for another resource')

local function mentions(value, needle)
    return type(value) == 'string' and value:find(needle, 1, true) ~= nil
end

-- Find the row for a slot. The report is a list, and a lookup by index would
-- make every assertion below depend on the slot ordering, which is a formatting
-- decision rather than a contract.
local function rowFor(rows, slot)
    for _, row in ipairs(rows) do
        if row.slot == slot then return row end
    end
    return nil
end

-- ============================================================ 1. it registered
started.great_target = 'started'
_G.exports.great_target = { a = function() end }
check(Bridge.register('target', 'great_target', nil, 'a', 'T1') == true, 'setup: target registers')

local rows = GetBridgeReport()
local targetRow = rowFor(rows, 'target')
check(type(targetRow) == 'table', 'the report has a row for the target slot')
check(targetRow.label == 'OK      ', 'a registered adapter is marked OK')
check(targetRow.detail == 'registered', 'and says so in words as well as in a label')
-- A registered row must NOT carry a fix. Printing "what to do" under a row that
-- is fine is how a support thread teaches an operator to ignore the section.
check(targetRow.fix == nil, 'a healthy row carries no fix to apply')

-- ================================================= 2. it is not on this server
started.not_here = nil
Bridge.register('database', 'not_here', nil, nil, 'D1')
rows = GetBridgeReport()
local dbRow = rowFor(rows, 'database')
check(dbRow.label == 'MISSING ', 'a resource that is not installed says MISSING')
check(mentions(dbRow.detail, 'not installed'), 'and says so in the detail too')
check(type(dbRow.fix) == 'string' and dbRow.fix ~= '',
    'every unhealth row carries a next step -- this is the whole point of the file')
check(mentions(dbRow.fix, 'oxmysql'),
    'and the fix names a resource the operator could actually start')

-- ================================================= 3. configured for something else
started.other_db = 'started'
_G.exports.other_db = { query = function() end }
Bridge.register('database', 'other_db', 'ghmattimysql', 'query', 'D2')
rows = GetBridgeReport()
dbRow = rowFor(rows, 'database')
check(dbRow.label == 'OTHER   ', 'a slot configured for another resource says OTHER')
check(dbRow.label ~= 'MISSING ', 'and is NOT reported as missing, which is a different problem')
check(mentions(dbRow.detail, 'ghmattimysql'),
    'the detail names what the configuration asked for')
check(type(dbRow.fix) == 'string' and mentions(dbRow.fix, 'ghmattimysql'),
    'and the fix names it too, so the operator can act on either sentence')

-- ====================================================== 4. started, wrong exports
started.wrong = 'started'
_G.exports.wrong = { SomethingElse = function() end }
Bridge.register('database', 'wrong', nil, 'query', 'D3')
rows = GetBridgeReport()
dbRow = rowFor(rows, 'database')
check(dbRow.label == 'NO API  ', 'a started target with the wrong exports says NO API')
check(dbRow.label ~= 'MISSING ', 'and is not conflated with not-installed: the fix is different')
check(type(dbRow.fix) == 'string' and mentions(dbRow.fix, 'query'),
    'and the fix names the export that is missing')

-- ============================================== 5. installed, but never came up
started.slow = 'stopped'
check(Bridge.register('database', 'slow', nil, 'a', 'D4') == false,
    'setup: a resource that never starts does not register')
rows = GetBridgeReport()
dbRow = rowFor(rows, 'database')
check(dbRow.label == 'DOWN    ', 'a resource that is installed but not up says DOWN')
check(dbRow.label ~= 'MISSING ', 'and is not conflated with not-installed either')
check(type(dbRow.fix) == 'string' and mentions(dbRow.fix, 'server.cfg'),
    'and the fix points at the start order, which is the actual cause')

-- =============================================== 6. refused by another resource
registerFails = true
Bridge.register('database', 'other_db', nil, 'query', 'D5')
registerFails = false
rows = GetBridgeReport()
dbRow = rowFor(rows, 'database')
check(dbRow.label == 'REFUSED ', 'a slot another resource already holds says REFUSED')
check(type(dbRow.fix) == 'string' and mentions(dbRow.fix, 'one resource'),
    'and the fix explains that only one provider may hold a slot')

-- ============================================ 7. the adapter never even ran
--
-- The row with no outcome at all. This happens when cis_libs never became ready,
-- and it is the case where the report is most valuable and least obvious: the
-- slot is empty, the operator has oxmysql running, and nothing has said a word.
-- Reporting MISSING here would be a lie -- the resource IS installed.
_G.__caps = { database = { owner = 'cis_core', resolved = true, missing = { 'query' } } }
rows = GetBridgeReport()
-- `inventoryProvider` is the slot no adapter in this suite ever attempted, which
-- is the state under test. `database` is not: it was registered four times above,
-- so reading it here would be reading the last of those.
local unknownRow = rowFor(rows, 'inventoryProvider')
check(unknownRow ~= nil, 'the untried slot has a row')
check(unknownRow.label == 'UNKNOWN ', 'a slot with no registration attempt says UNKNOWN')
check(unknownRow.label ~= 'MISSING ', 'and never claims the resource is absent, which it did not check')
check(type(unknownRow.fix) == 'string' and mentions(unknownRow.fix, 'cis_libs'),
    'and the fix points at cis_libs, which is what failing to become ready means')

-- ======================================= 8. cis_libs can see something we cannot
--
-- The capability a provider holds but cannot serve. It registered, the
-- registration was accepted, and every real call will raise -- the state that
-- looks perfectly healthy from inside this resource and is invisible until a
-- player tries to open something.
_G.__caps = {
    target = { owner = 'cis_bridge', resolved = true, missing = { 'remove', 'exists' } },
    database = { owner = 'cis_core', resolved = false },
}
rows = GetBridgeReport()
check(type(rows) == 'table' and #rows >= 4,
    'the report has a row for every declared slot, registered or not')
check(rowFor(rows, 'target') ~= nil, 'the target slot is present')
check(rowFor(rows, 'inventoryProvider') ~= nil, 'the inventory slot is present under its SLOT name')
check(rowFor(rows, 'discord') ~= nil, 'the discord slot is present')

-- ------------------------------------------------------- no unhealth row is bare
--
-- The property, checked over the whole report rather than row by row. If this
-- ever fails, the file has stopped doing its job regardless of what the
-- individual rows say.
local bare = {}
for _, row in ipairs(rows) do
    if row.label ~= 'OK      ' and row.label ~= 'UNKNOWN ' then
        if type(row.fix) ~= 'string' or row.fix == '' then
            bare[#bare + 1] = row.slot .. ' (' .. tostring(row.label) .. ')'
        end
    end
end
check(#bare == 0, 'no unhealthy row lacks a next step; bare rows: ' .. table.concat(bare, ', '))

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(report): ' .. failures[i] .. '\n')
end
io.write(('report passed=%d failed=%d\n'):format(passed, failed))