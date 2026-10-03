-- Tests for the registration helper.
--
-- Every adapter is a thin wrapper around a third-party export, so there is very
-- little pure logic here to test and pretending otherwise would be testing the
-- mock. `Bridge.register` is the exception, and it is the right exception: its
-- four conditions are the difference between an adapter that works and one that
-- raises on every call, and each of them has a real failure behind it.

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

-- A fake cis_libs that records what it was asked to register.
local registeredWith = {}
local registerShouldFail = false
exports = {
    ['cis_libs'] = {
        WaitReady = function() return true end,
        GetConfigSummary = function() return nil end,
        RegisterCapability = function(_, slot, provider)
            if registerShouldFail then
                return false, 'capability "x" is already registered by y'
            end
            registeredWith[slot] = provider
            return true
        end,
    },
}

local started = {}
GetResourceState = function(name) return started[name] or 'stopped' end
GetCurrentResourceName = function() return 'cis_bridge' end

-- A started target whose probe export EXISTS, and one where it does not.
--
-- The probe in Bridge.register indexes `exports[target][probeExport]`, and
-- indexing a plain table that lacks the key yields nil rather than raising --
-- which is exactly what a missing export looks like. So an empty table IS the
-- absent case, and no metatable is needed to fake one.
started.ox_target = 'started'
exports.ox_target = { addSphereZone = function() end }
exports.probe_target = {}

-- ============================================== 1. a target that is not running
-- The failure this prevents: an adapter that registers against a target nobody
-- has, and then raises on every single call, in a product that looks installed.
check(Bridge.register('target', 'nothing_here', nil, nil, 'X') == false,
    'a target that is not started does not register')
check(registeredWith.target == nil, 'and nothing was handed to cis_libs')

-- ============================================ 2. the configured name disagrees
-- A server with ox_target installed and qb-target configured. Registering the
-- one that is present would work by accident on a server where the operator
-- never tested the other one.
check(Bridge.register('target', 'ox_target', 'qb-target', 'addSphereZone', 'X') == false,
    'a target the configuration does not name does not register')
check(registeredWith.target == nil, 'and still nothing was handed to cis_libs')

-- Matching names, and no configured name at all, are both allowed.
started.qb_target = 'started'
check(Bridge.register('target', 'ox_target', 'ox_target', 'addSphereZone', 'X') == true,
    'a target the configuration names registers')
check(registeredWith.target == 'cis_bridge:X',
    'the provider string is this resource and the export the adapter passed')
registeredWith = {}
started.oxmysql = 'started'
exports.oxmysql = { query = function() end }
check(Bridge.register('database', 'oxmysql', nil, 'query', 'Y') == true,
    'an adapter with no rival registers on presence alone')
check(registeredWith.database == 'cis_bridge:Y', 'and is handed to cis_libs under its own name')

-- ============================ 2b. AUTO AND NONE ARE ANSWERS, NOT RIVAL NAMES
--
-- `GetConfigSummary` reports the CONFIGURED value for a slot, and the two
-- strings below are what a stock server actually gets.
--
-- 'AUTO' is the default for `Framework.Database.Type` -- "work it out from what
-- is started". Reading it as a rival resource name meant every adapter compared
-- itself against the string 'AUTO', found a mismatch, and refused. On a server
-- with oxmysql running, with nothing wrong anywhere. No driver registered, ever,
-- and the message said "the configuration names AUTO", which is true and tells
-- the operator nothing they can act on.
--
-- 'NONE' is what the summary reports for a slot nobody configured. Same shape of
-- mistake from the other direction: it is an answer, not a competitor.
registeredWith = {}
started.oxmysql = 'started'
check(Bridge.register('database', 'oxmysql', 'AUTO', 'query', 'A') == true,
    'a configuration of AUTO registers the one driver that is running')
check(registeredWith.database == 'cis_bridge:A', 'and hands it over under its own name')
registeredWith = {}
check(Bridge.register('database', 'oxmysql', 'auto', 'query', 'A') == true,
    'lowercase auto is treated the same, because config is written by hand')
registeredWith = {}
check(Bridge.register('database', 'oxmysql', 'NONE', 'query', 'A') == true,
    'a configuration of NONE registers rather than refusing')
registeredWith = {}
check(Bridge.register('database', 'oxmysql', '', 'query', 'A') == true,
    'an empty configured name registers too, as it always did')
registeredWith = {}
check(Bridge.register('database', 'oxmysql', 'ghmattimysql', 'query', 'A') == false,
    'a REAL rival name still refuses, so AUTO has not weakened the check')

-- ================================= 3b. THE PROBE MAY BE A LIST, AND NAMES ITSELF
--
-- One export is not enough to establish compatibility. An adapter that calls six
-- of a target's exports has six ways to be wrong, and probing one of them proves
-- only that the target exists.
started.multi = 'started'
exports.multi = { a = function() end, b = function() end }
check(Bridge.register('target', 'multi', nil, { 'a', 'b' }, 'M') == true,
    'a target exposing every required export registers')
started.partial = 'started'
exports.partial = { a = function() end }
check(Bridge.register('target', 'partial', nil, { 'a', 'b', 'c' }, 'M') == false,
    'a target missing one of several required exports does not register')
check(Bridge.register('target', 'partial', nil, { 'b' }, 'M') == false,
    'and the missing name is what decides it, not merely that one is missing')
check(Bridge.register('target', 'partial', nil, { 'a' }, 'M') == true,
    'the same target registers when only what it has is required')

-- An EMPTY list is not a probe. A caller who passes `{}` means "I have no
-- opinion", which is the same as passing nil -- treating it as "everything is
-- missing" would refuse an adapter that asked for nothing.
check(Bridge.register('target', 'partial', nil, {}, 'M') == true,
    'an empty probe list is no probe, and does not refuse the adapter')

-- ============================================ 2c. THE CONFIGURED NAME, READ THROUGH
--
-- cis_bridge has no config file of its own -- it asks cis_libs, which asks the
-- product that owns the config -- so a disagreement about what the operator
-- chose is impossible by construction. What is testable is the failure shape:
-- an answer that arrives as something other than a table, or as a call that
-- raises, must be nil rather than a half-populated value that reads as a choice.
local summaryValue = nil
exports['cis_libs'].GetConfigSummary = function() return summaryValue end
summaryValue = nil
check(Bridge.configured('database') == nil, 'no summary yet is nil, not AUTO')
summaryValue = { database = 'AUTO', inventory = 'ox_inventory', target = 'ox_target' }
check(Bridge.configured('database') == 'AUTO', 'a configured name is read through')
check(Bridge.configured('inventory') == 'ox_inventory', 'per key, not as a whole blob')
check(Bridge.configured('nothing_configured') == nil, 'an absent key is nil')
exports['cis_libs'].GetConfigSummary = function() error('cis_libs is not ready') end
check(Bridge.configured('database') == nil, 'a raising summary is nil rather than an error')
exports['cis_libs'].GetConfigSummary = function() return nil end
check(Bridge.configured('database') == nil, 'a nil summary is nil')

-- ================================================= 3. the probe export exists
-- Old oxmysql has no `single`; a target whose exports were renamed is the same
-- problem. Registering anyway means the capability exists and every call to it
-- raises, which is harder to diagnose than not registering at all.
started.probe_target = 'started'
check(Bridge.register('target', 'probe_target', nil, 'addSphereZone', 'X') == false,
    'a started target with no matching export does not register')
exports.probe_ok = { addSphereZone = function() end }
started.probe_ok = 'started'
check(Bridge.register('target', 'probe_ok', nil, 'addSphereZone', 'X') == true,
    'a started target with the export registers')

-- ==================================== 4. a refused registration is not a crash
-- First-registration-wins means a second resource asking for a held slot is
-- refused. The adapter has to survive being refused: it is a normal outcome on
-- a server with two bridges, not an error condition.
registerShouldFail = true
check(Bridge.register('target', 'ox_target', nil, nil, 'X') == false,
    'a refused registration returns false rather than raising')
registerShouldFail = false

-- ============================================ 5. an adapter must name itself
-- Two adapters registering one export name means the second silently replaces
-- the first, so whichever file loaded last answers for every capability. That
-- is why the name is required rather than derived from the slot.
local named = pcall(Bridge.register, 'target', 'ox_target', nil, nil, nil)
check(not named, 'registering without an export name is refused loudly')

-- ============================================ 6. what registered is knowable
-- "cis_bridge is installed but registered nothing" and "cis_bridge is not
-- installed" are different sentences, and the conformance runner is built on
-- being able to tell them apart.
-- The set is keyed by SLOT and valued by TARGET, and it reflects the most
-- recent successful registration for each. That is what the conformance runner
-- iterates, so it has to name the target rather than the slot.
local reg = Bridge.registered()
check(type(reg) == 'table', 'the registered set is readable')
check(reg.target == 'probe_ok', 'a slot records the target that won it')
check(reg.database == 'oxmysql', 'each slot records its own target')

-- ------------------------------------------------------------------ report
-- The exit code is set through a GLOBAL, not `os.exit(1)`. `os.exit` inside a
-- suite takes the whole fengari state down with it, so a failure here meant
-- test/adapters.lua never ran and CI reported one suite's problem as though it
-- were the only problem there was.
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(bridge): ' .. failures[i] .. '\n')
end
io.write(('bridge passed=%d failed=%d\n'):format(passed, failed))
