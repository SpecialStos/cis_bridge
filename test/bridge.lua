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
for i = 1, #failures do
    io.stderr:write('FAIL(bridge): ' .. failures[i] .. '\n')
end
io.write(('bridge passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
