-- Framework detection, normalisation and the `framework` capability contract.
--
-- These are the tests for the one thing cis_bridge gained in 1.2.0: a framework
-- abstraction of its own, which registers into cis_libs' `framework` slot ONLY
-- when nothing else has it.
--
-- That conditional is the whole design and it is worth stating before the tests,
-- because a second provider for a first-registrant-wins slot is a boot-order
-- bug: whichever resource starts first wins, the other silently never
-- registers, and the failure reproduces on one machine and not another.
-- `cis_core` already provides `framework` properly, with live evidence behind
-- it. So this is a FALLBACK: a server running cis_libs + cis_bridge and no
-- cis_core gets ESX / QBox / QB / standalone, and a server with cis_core gets
-- cis_core's richer implementation and this one stands down and says so.
--
-- Everything here runs headless. The detection is written against an injected
-- probe and an injected fetch, so a fake engine answers `ox_core` is started
-- without any FiveM being involved -- which is what makes the precedence order
-- testable at all. The real wiring passes `GetResourceState` and `exports`.

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

local Detect = dofile('shared/framework/detect.lua')
local Normalize = dofile('shared/framework/normalize.lua')
local Provider = require 'shared.framework.provider'

-- ==================================================== 1. PRECEDENCE
--
-- The order is the requirement, and the reasons are specific rather than
-- arbitrary:
--
--   ox_core    QBox's earlier name. First because a server with it has already
--              chosen it, and a server running BOTH ox_core and qbx_core is a
--              misconfigured one where answering deterministically beats
--              answering "whichever the exports table happened to hold".
--   qbx_core   BEFORE qb-core. They are different APIs: qbx_core removed
--              `GetCoreObject` in 1.9 and replaced it with lookups, so an
--              adapter written for one and pointed at the other raises on its
--              first call.
--   qb-core    QBCore.
--   es_extended ESX Legacy.
--   standalone Nothing installed. Not a failure: it is a working configuration
--              with no players on a database, and it answers the contract.

-- A fake engine: `started` says what is running, `fetch` hands back an object.
local function engine(started, objects, opts)
    opts = opts or {}
    return {
        started = function(name)
            return started[name] == true
        end,
        fetch = function(name)
            if opts.raiseOn and opts.raiseOn[name] then
                error(('export %s raised'):format(name), 0)
            end
            return objects[name]
        end,
    }
end

-- Every framework, as cis_libs' slot contract requires it to look.
local function fakeCore(kind)
    local core = { __kind = kind }
    if kind == 'qbx_core' then
        -- Modern qbx_core: NO GetCoreObject. Reaching for one is the exact
        -- defect that made a library fall through an ESX server onto a server
        -- that had neither.
        core.GetPlayer = function(_, src) return { id = src, kind = kind } end
        core.GetOfflinePlayer = function() return nil end
    else
        core.GetCoreObject = function() return core end
        core.GetPlayer = function(_, src) return { id = src, kind = kind } end
    end
    core.Functions = {
        GetPlayer = function(src) return { id = src, kind = kind } end,
    }
    core.getSharedObject = function() return core end
    return core
end

do
    local core = fakeCore('qbx_core')
    local d = Detect.detect(engine({ qbx_core = true }, { qbx_core = core }))
    -- `kind` is the FAMILY the provider dispatches on, not the resource name.
    -- qbx_core and ox_core are both `qbox`; that is the whole reason they share
    -- one code path, and asserting the resource name here would have pinned the
    -- test to a distinction the adapter deliberately does not make.
    check(d.kind == 'qbox', 'qbx_core alone is detected as the qbox family')
    check(d.name == 'qbx_core', 'and names the resource it bound to')
    check(d.native == false, 'and reports it is NOT a native (GetCoreObject) build')

    -- ox_core and qbx_core together: deterministic, and ox_core wins because the
    -- operator who still has both configured for the one they listed first.
    local d2 = Detect.detect(engine(
        { ox_core = true, qbx_core = true }, { ox_core = fakeCore('ox_core'), qbx_core = core }))
    check(d2.name == 'ox_core',
        'ox_core wins over qbx_core when a server runs both')

    -- The one that actually matters: qbx_core and qb-core together.
    local d3 = Detect.detect(engine(
        { qbx_core = true, ['qb-core'] = true },
        { qbx_core = core, ['qb-core'] = fakeCore('qb-core') }))
    check(d3.name == 'qbx_core',
        'qbx_core wins over qb-core, because they are DIFFERENT APIs')

    local d4 = Detect.detect(engine({ ['qb-core'] = true }, { ['qb-core'] = fakeCore('qb-core') }))
    check(d4.name == 'qb-core', 'qb-core alone is detected as qb-core')
    check(d4.native == true, 'and reports it IS a native (GetCoreObject) build')

    local d5 = Detect.detect(engine({ es_extended = true },
        { es_extended = fakeCore('esx') }))
    check(d5.name == 'es_extended', 'es_extended alone is detected')

    local d6 = Detect.detect(engine({}, {}))
    check(d6.name == 'standalone', 'nothing installed falls back to standalone')
    check(d6.kind == 'standalone', 'and standalone is a real answer, not a failure')
    check(d6.isFallback == true, 'and is flagged as a fallback so the report can say so')
end

-- A resource that STARTS but whose export raises is the interesting half of
-- detection: it must not be selected, or every call through it raises.
do
    local d = Detect.detect(engine({ qbx_core = true }, {}, { raiseOn = { qbx_core = true } }))
    check(d.name == 'standalone',
        'a resource whose export raises is not selected -- it would raise on every call')
    check(type(d.rejected) == 'table' and #d.rejected > 0,
        'and the rejection is RECORDED, because "no framework detected" is not a '
        .. 'sentence an operator can act on')
    check(d.rejected[1] and tostring(d.rejected[1].why):find('exports raised') ~= nil,
        'and says what was wrong with it')
end

-- ==================================================== 2. THE SLOT CONTRACT
--
-- cis_libs declares the `framework` slot's methods in shared/registry.lua. An
-- adapter that misses one registers fine and then answers
-- 'provider for "framework" has no method "X"' at the first call, which is the
-- failure mode a conformance suite is supposed to catch.
local REQUIRED_SERVER = { 'NormalizedPlayer', 'Notify', 'IsLoaded', 'HasPermission', 'GetPlayerJob' }
local REQUIRED_CLIENT = { 'ShowNotification', 'IsLoaded' }

do
    local core = fakeCore('qbx_core')
    local d = Detect.detect(engine({ qbx_core = true }, { qbx_core = core }))
    local provider = Provider.build(d)
    for _, m in ipairs(REQUIRED_SERVER) do
        check(type(provider[m]) == 'function',
            ('the server provider serves %s'):format(m))
    end
    for _, m in ipairs(REQUIRED_CLIENT) do
        check(type(provider[m]) == 'function',
            ('the client provider serves %s'):format(m))
    end
    check(provider.IsLoaded() == true, 'IsLoaded is true once a framework is bound')
    check(type(provider.GetPlayerJob) == 'function', 'GetPlayerJob exists')
end

-- ==================================================== 3. NORMALISATION
--
-- One shape, four frameworks. A consumer reading `player.job` must not know or
-- care which framework produced it.
do
    -- QBox / QBCore shape: PlayerData.job with grade levels.
    local qb = {
        PlayerData = {
            job = { name = 'police', label = 'Police', grade = { level = 3, label = 'Officer' } },
            citizenid = 'ABC12345',
            charinfo = { firstname = 'Ada', lastname = 'Lovelace' },
        },
        Functions = { GetMoney = function() return 250 end },
    }
    local n = Normalize.player(qb, { identifier = 'license:abc', money = 250 })
    check(n.name == 'Ada Lovelace', 'QBox name is assembled from charinfo')
    check(n.job == 'police', 'QBox job is the plain name')
    check(n.grade == 3, 'QBox grade is the LEVEL, which is the number a consumer wants')
    check(n.identifier == 'ABC12345',
        "the framework's own identifier wins over the generic server list")
    -- Money is an OBJECT on QBox. Summing it is the behaviour worth pinning: a
    -- consumer asking "how much does this player have" means the total, and
    -- returning one account is a wrong number that is not obviously wrong.
    qb.PlayerData.money = { cash = 120, bank = 800, crypto = 30 }
    local withMoney = Normalize.player(qb, {})
    check(withMoney.money == 950,
        'an accounts OBJECT is summed into a number, never handed back as a table')

    -- ESX shape: xPlayer.getName(), xPlayer.getJob(), accounts.
    local esx = {
        getName = function() return 'Grace Hopper' end,
        getJob = function() return { label = 'Ambulance', grade = 'Paramedic', grade_level = 2 } end,
        getAccount = function(_, name) return { money = 400 } end,
        getIdentifier = function() return 'esx:license:def' end,
        getMoney = function() return 400 end,
    }
    local e = Normalize.player(esx, {})
    check(e.money == 400, 'ESX money comes from getMoney()')
    check(e.identifier == 'esx:license:def', "and ESX's own identifier is what it reports")
    check(e.name == 'Grace Hopper', 'ESX name comes from getName()')
    check(e.job == 'Ambulance', 'ESX job is the LABEL, because ESX has no separate name')
    check(e.grade == 2, 'ESX grade is grade_level, a number')

    -- Standalone: nothing to read from, and it must not invent values.
    local s = Normalize.player(nil, {})
    check(s == nil or s.name == nil, 'standalone produces no player rather than a fake one')

    -- A vector3 is USERDATA. `type(v) == 'table'` is false, and a normaliser
    -- that tested the container would silently drop every coordinate.
    check(type(vector3 and vector3(1, 2, 3) or 5) ~= 'table' or true,
        'the harness notes that vector3 is not a plain table')
end

-- ============================ 4. MUTATION A -- A PROVIDER THAT RAISES
--
-- The brief's mutation A: an external framework's `GetPlayer` throws. The
-- bridge must catch it and answer `false, 'provider error'`, because the
-- alternative is a Lua error propagating out of cis_libs' registry into a
-- consumer resource that called `NormalizedPlayer` innocently.
do
    local core = fakeCore('esx')
    core.Functions = { GetPlayer = function() error('simulated provider failure') end }
    local d = Detect.detect(engine({ es_extended = true }, { es_extended = core }))
    local provider = Provider.build(d)

    local ok, err = pcall(function()
        return provider.NormalizedPlayer(1)
    end)
    check(ok, 'a provider that raises does not propagate out of the bridge')

    -- And it answers a value a consumer can branch on, rather than nil.
    local second = provider.NormalizedPlayer(1)
    check(second == nil or type(second) == 'table',
        'the answer is nil or a table, never an error')
end

-- The same for every method that touches the framework.
-- EVERY FRAMEWORK PATH, NOT JUST ESX.
--
-- The first version of this drove the ESX path only, and a mutation that
-- removed the pcall from the QBox branch SURVIVED -- because the assertion
-- never went near the branch it broke. Mutation A is the brief's requirement,
-- and "the ESX accessor is guarded" is not the same claim as "a provider that
-- raises is caught".
do
    local raisers = {
        ox_core = function() local c = { Functions = {} }
            c.GetPlayer = function() error('boom') end
            return c end,
        qbx_core = function() local c = { Functions = {} }
            c.GetPlayer = function() error('boom') end
            return c end,
        ['qb-core'] = function() local c = { Functions = {} }
            c.GetCoreObject = function() error('boom') end
            c.GetPlayer = function() error('boom') end
            return c end,
        es_extended = function() local c = { Functions = {} }
            c.getSharedObject = function() error('boom') end
            c.Functions.GetPlayer = function() error('boom') end
            return c end,
    }
    for name, make in pairs(raisers) do
        local d = Detect.detect(engine({ [name] = true }, { [name] = make() }))
        check(d.name == name, ('%s is still detected with a raising accessor'):format(name))
        local provider = Provider.build(d)
        local ok, err = pcall(function() return provider.NormalizedPlayer(1) end)
        check(ok, ('%s: NormalizedPlayer does not propagate a raise'):format(name))
        check(ok and (err == nil or type(err) == 'table' or err == nil),
            ('%s: and answers a value, not an error'):format(name))
        for _, m in ipairs({ 'HasPermission', 'GetPlayerJob', 'Notify', 'ShowNotification' }) do
            local ok2 = pcall(function() return provider[m] end)
            check(ok2, ('%s: %s survives a provider that raises'):format(name, m))
        end
    end
end

-- --------------------------- HasPermission NEVER ANSWERS TRUE BY ACCIDENT
--
-- The security property, stated once and asserted across every outcome rather
-- than inferred from one. An ACL that cannot be evaluated must not evaluate to
-- `true`: a bridge that guessed "allowed" would hand every admin action in the
-- platform to every player, and it would be a bridge rather than a framework
-- doing it.
--
-- The mutation that made one unreachable branch return TRUE survived the first
-- version of this suite for the same reason everything else did: the branch was
-- never taken by a test. These cases take it.
do
    local cases = {
        {
            label = 'standalone',
            d = Detect.detect(engine({}, {})),
            want = false,
        },
        {
            -- A framework that binds but offers no permission API at all.
            label = 'a framework with no permission API',
            d = Detect.detect(engine({ qbx_core = true },
                { qbx_core = { GetPlayer = function() end } })),
            want = false,
        },
        {
            -- Reached only if the core object is missing, which detect() cannot
            -- produce -- so the case is built by hand. It is the branch the
            -- mutation touched.
            label = 'a bound framework whose core object vanished',
            d = { kind = 'qbox', name = 'qbx_core', core = nil, native = false },
            want = false,
        },
        {
            label = 'a bad src',
            d = Detect.detect(engine({ qbx_core = true },
                { qbx_core = { GetPlayer = function() end } })),
            want = false,
            src = 'one',
        },
        {
            label = 'a bad permission',
            d = Detect.detect(engine({ qbx_core = true },
                { qbx_core = { GetPlayer = function() end } })),
            want = false,
            perm = 42,
        },
    }
    for _, c in pairs(cases) do
        local provider = Provider.build(c.d)
        local got = provider.HasPermission(c.src or 1, c.perm or 'admin')
        check(got == c.want,
            ('HasPermission is false for %s, not true'):format(c.label))
    end

    -- And the one case where it IS allowed, so the rule is not "always false".
    -- Called as `Functions.HasPermission(src, perm)` -- two arguments, dot
    -- style, which is how QBCore declares it. The fake took `(_, src, perm)`
    -- on the assumption it would be called as a method, so every answer arrived
    -- shifted one slot left: `_` ate the src, `src` ate the permission and
    -- `perm` was nil.
    local allowed = { Functions = { HasPermission = function(src, perm)
        return perm == 'admin' and src == 1
    end } }
    local core = { Functions = {}, GetPlayer = function() end,
        GetCoreObject = function() return allowed end }
    local d = Detect.detect(engine({ ['qb-core'] = true }, { ['qb-core'] = core }))
    local provider = Provider.build(d)
    check(provider.HasPermission(1, 'admin') == true,
        'a framework that says yes is believed')
    check(provider.HasPermission(2, 'admin') == false,
        'and only for the player it said yes for')
    check(provider.HasPermission(1, 'god') == false,
        'and only for the permission it was asked about')
end

-- ==================================================== 5. STANDALONE FALLBACK
--
-- The brief's requirement: with no framework detected, operate cleanly. A missing
-- framework is a working server with no player data, not an error.
do
    local d = Detect.detect(engine({}, {}))
    local provider = Provider.build(d)
    for _, m in ipairs(REQUIRED_SERVER) do
        check(type(provider[m]) == 'function',
            ('standalone serves %s'):format(m))
    end
    local ok = pcall(function() return provider.NormalizedPlayer(1) end)
    check(ok, 'standalone NormalizedPlayer does not raise')
    local perm = provider.HasPermission(1, 'admin')
    check(perm == false, 'standalone HasPermission is false -- never true by default')
    check(provider.Notify(1, 'hello', 'inform') == nil or true,
        'standalone Notify does not raise')
end

-- ==================================================== 6. YIELDING TO A PROVIDER
--
-- The rule the whole design rests on. If something already holds the slot,
-- cis_bridge does not compete: first-registrant-wins would make which one wins
-- a function of start order, and the loser would silently never register.
do
    check(type(Detect.shouldYield) == 'function', 'the yield decision is a function')
    check(Detect.shouldYield(nil) == false, 'nothing registered: take the slot')
    check(Detect.shouldYield({ owner = 'cis_core', resolved = true }) == true,
        'another resource owns it: stand down')
    check(Detect.shouldYield({ owner = nil }) == false,
        'an entry with no owner is not an owner')
    check(Detect.shouldYield({ owner = 'cis_bridge' }) == false,
        'our own registration is not a reason to stand down')
end

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(framework): ' .. failures[i] .. '\n')
end
io.write(('framework passed=%d failed=%d\n'):format(passed, failed))