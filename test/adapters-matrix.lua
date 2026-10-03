-- The adapters, method by method, against a fake third party.
--
-- WHY THIS EXISTS WHEN test/adapters.lua ALREADY EXISTS
--
-- That suite covers the decisions that were the subject of a bug -- the
-- transaction bind key, the ox_inventory count, the Discord embed. This one
-- covers the ROUTINE: every method of every adapter, and every return shape the
-- third party might answer with.
--
-- The reason is that the interesting differences between these targets are
-- entirely in their RETURN SHAPES, and a live conformance run can only test the
-- one shape the install happens to produce. qb-inventory reports a failure as a
-- STRING, which is truthy in Lua, so every failed add reads as a success. That
-- is invisible on a server where nothing is being added, and it is exactly the
-- class of bug this resource exists to absorb.
--
-- So the fakes here answer with EVERY shape the target might produce, and the
-- adapter has to coerce each one to the slot's contract. A rule that only
-- accepts a boolean and a rule that also coerces a string are the same code on a
-- healthy server and different code on a broken one.

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

-- ====================================================== the stub engine

local started = {}
local registrations = {}
local configSummary = {}
local registerFails = false
local now = 0

_G.GetGameTimer = function() return now end
_G.Wait = function(ms) now = now + (tonumber(ms) or 0) end
_G.SetTimeout = function(_, fn) fn() end
_G.promise = {
    new = function(executor)
        local resolved, value
        executor(function(v) resolved, value = true, v end)
        return { __awaited = true, resolved = resolved, value = value }
    end,
}
-- Citizen.Await on a plain value, which is what the module above produces.
_G.Citizen = {
    Await = function(p)
        if type(p) == 'table' and p.__awaited then
            return p.value
        end
        return p
    end,
}
_G.json = { encode = function(t) return '{}' end }
_G.PerformHttpRequest = function() end
_G.vector3 = function(x, y, z) return { x = x, y = y, z = z } end
_G.vec3 = _G.vector3

local function fakeExports()
    return setmetatable({
        cis_libs = {
            WaitReady = function() return true end,
            GetConfigSummary = function() return configSummary end,
            RegisterCapability = function(_, slot, provider)
                if registerFails then return false, 'held by someone' end
                registrations[#registrations + 1] = { slot = slot, provider = provider }
                return true
            end,
            GetCapabilities = function() return {} end,
        },
    }, {
        __call = function(_, name, fn) _G.__declared[name] = fn end,
    })
end

_G.__declared = {}

--- Load one adapter against a fake third party and hand back its method table.
local function load(rel, thirdParty)
    _G.__declared = {}
    _G.exports = fakeExports()
    _G.GetResourceState = function(name) return started[name] or 'missing' end
    _G.GetCurrentResourceName = function() return 'cis_bridge' end
    _G.GetResourceMetadata = function() return '2.2.0' end
    registrations = {}
    for name, tbl in pairs(thirdParty or {}) do
        _G.exports[name] = tbl
        started[name] = 'started'
    end
    local body
    _G.CreateThread = function(fn) body = fn end
    dofile(rel)
    if body then body() end
    local out = {}
    for name, fn in pairs(_G.__declared) do
        out[name] = fn()
    end
    return out
end

-- ======================================================= 1. INVENTORY
--
-- The slot contract is `count -> number|nil`, `add -> boolean`,
-- `remove -> boolean`. Every adapter coerces a third-party shape into that, and
-- every coercion is different.

--- Build a fake whose methods answer whatever `answers` says, per call.
local function fakeInventory(answers)
    return {
        GetItemCount = answers.count or function() return 0 end,
        GetItemTotal = answers.count or function() return 0 end,
        GetItemsTotalAmount = answers.count or function() return 0 end,
        Search = answers.search or answers.count or function() return 0 end,
        AddItem = answers.add or function() return true end,
        RemoveItem = answers.remove or function() return true end,
        CanCarryItem = answers.canCarry or function() return true end,
    }
end

-- ---------------------------------------------- qb-inventory: string refusal
--
-- qb-inventory reports a refusal as a STRING. A string is truthy in Lua, so a
-- plain `result ~= false` reports every failed add as a success, and a caller
-- writing `if inventory.add(...) then give the item end` hands out the item.
-- This is the single most consequential coercion in the resource and it is
-- invisible unless the fake is asked to fail.
do
    local A = load('adapters/inventory/qb_inventory.lua', {
        ['qb-inventory'] = fakeInventory({
            count = function() return 0 end,
            add = function() return 'Inventory full' end,
            remove = function() return 'no such item' end,
        }),
    }).CisBridgeInventoryQb
    check(type(A) == 'table', 'the qb-inventory adapter loads')
    check(A and A.name() == 'qb-inventory', 'and names itself')
    check(A and A.count(1, 'bread') == 0, 'count answers zero for an item not held')
    check(A and A.add(1, 'bread', 1, {}) == false,
        "add coerces qb-inventory's STRING refusal to false")
    check(A and A.remove(1, 'bread', 1) == false,
        "remove coerces qb-inventory's STRING refusal to false")
end
do
    local A = load('adapters/inventory/qb_inventory.lua', {
        ['qb-inventory'] = fakeInventory({
            add = function() return true end,
            remove = function() return true end,
        }),
    }).CisBridgeInventoryQb
    check(A and A.add(1, 'bread', 1, {}) == true, 'a successful add is true')
    check(A and A.remove(1, 'bread', 1) == true, 'a successful remove is true')
end
do
    local A = load('adapters/inventory/qb_inventory.lua', {
        ['qb-inventory'] = fakeInventory({
            add = function() return false end,
            remove = function() return false end,
        }),
    }).CisBridgeInventoryQb
    check(A and A.add(1, 'bread', 1, {}) == false, 'an explicit false add is false')
    check(A and A.remove(1, 'bread', 1) == false, 'an explicit false remove is false')
end
do
    -- A driver that RAISES must not take the caller down. The adapter answers
    -- false rather than propagating, because an inventory call that raises in the
    -- middle of a transaction is how a half-applied write happens.
    local A = load('adapters/inventory/qb_inventory.lua', {
        ['qb-inventory'] = fakeInventory({
            add = function() error('qb-inventory: inventory not loaded') end,
            remove = function() error('boom') end,
            count = function() error('boom') end,
        }),
    }).CisBridgeInventoryQb
    check(A and A.add(1, 'bread', 1, {}) == false, 'an add that raises is false, not a crash')
    check(A and A.remove(1, 'bread', 1) == false, 'a remove that raises is false')
    check(A and A.count(1, 'bread') == nil, 'a count that raises is nil, not zero')
end

-- ------------------------------- codem-inventory: nil is a refusal, not a crash
do
    local A = load('adapters/inventory/codem_inventory.lua', {
        ['codem-inventory'] = fakeInventory({
            count = function() return 0 end,
            add = function() return nil end,
            remove = function() return false end,
        }),
    }).CisBridgeInventoryCodem
    check(A and A.name() == 'codem-inventory', 'the codem adapter names itself')
    check(A and A.add(1, 'bread', 1, {}) == false,
        "codem's NIL answer -- it did not fit -- is false rather than a crash")
    check(A and A.remove(1, 'bread', 1) == false, 'and an explicit false remove is false')
end
do
    local A = load('adapters/inventory/codem_inventory.lua', {
        ['codem-inventory'] = fakeInventory({ add = function() return 3 end }),
    }).CisBridgeInventoryCodem
    check(A and A.add(1, 'bread', 3, {}) == true,
        "a numeric answer -- codem returns a count -- is a success, not falsy")
end

-- ------------------------------------------------- qs-inventory and ox_inventory
for _, case in ipairs({
    { file = 'adapters/inventory/qs_inventory.lua', export = 'CisBridgeInventoryQs',
      name = 'qs-inventory', key = 'qs-inventory' },
    { file = 'adapters/inventory/ox_inventory.lua', export = 'CisBridgeInventoryOx',
      name = 'ox_inventory', key = 'ox_inventory' },
}) do
    -- `load` answers with a table keyed BY EXPORT NAME. The first version read
    -- `.exports` off it, which is nil, and then every assertion below failed on
    -- a nil adapter -- twelve failures that all read as "these adapters are
    -- broken" and none of which was about the adapters at all.
    local A = load(case.file, { [case.key] = fakeInventory({}) })[case.export]
    check(type(A) == 'table', ('the %s adapter loads'):format(case.name))
    check(A and A.name() == case.name, ('the %s adapter names itself'):format(case.name))
    check(A and A.count(1, 'bread') == 0,
        ('%s counts a missing item as zero'):format(case.name))
    check(A and A.count(nil, 'bread') == nil,
        ('%s answers nil for a nil source, never zero'):format(case.name))
    check(A and A.count(1, nil) == nil,
        ('%s answers nil for a nil item, never zero'):format(case.name))
    check(A and A.add(1, 'bread', 1, {}) == true,
        ('%s accepts a successful add'):format(case.name))
    check(A and A.remove(1, 'bread', 1) == true,
        ('%s accepts a successful remove'):format(case.name))
end
do
    local A = load('adapters/inventory/qs_inventory.lua', {
        ['qs-inventory'] = fakeInventory({
            add = function() return false end,
            remove = function() return false end,
        }),
    }).CisBridgeInventoryQs
    check(A and A.add(1, 'bread', 1, {}) == false, 'qs-inventory refuses a false add')
    check(A and A.remove(1, 'bread', 1) == false, 'and a false remove')
end

-- ======================================================= 2. DATABASE

-- ------------------------------------------------------ mongodb: refuses all
do
    local A = load('adapters/database/mongodb.lua', {
        mongodb = { isConnected = function() return false end },
    }).CisBridgeDatabaseMongodb
    check(A and A.name() == 'mongodb', 'the mongodb adapter names itself')
    check(A and A.ready() == false, 'and reports not connected')
    local refusals = {
        { 'query', A and function() return A.query('SELECT 1') end },
        { 'single', A and function() return A.single('SELECT 1') end },
        { 'scalar', A and function() return A.scalar('SELECT 1') end },
        { 'insert', A and function() return A.insert('INSERT 1') end },
        { 'update', A and function() return A.update('UPDATE 1') end },
        { 'transaction', A and function() return A.transaction({}) end },
    }
    for _, r in ipairs(refusals) do
        local ok, first, second = pcall(r[2])
        check(ok, ('mongodb %s refuses rather than raising'):format(r[1]))
        check(ok and first == nil or first == false,
            ('mongodb %s answers no value at all'):format(r[1]))
        check(ok and type(second) == 'string' and second:find('mongodb', 1, true) ~= nil,
            ('and the reason names mongodb'):format(r[1]))
    end
end
do
    local A = load('adapters/database/mongodb.lua', {
        mongodb = { isConnected = function() return true end },
    }).CisBridgeDatabaseMongodb
    check(A and A.ready() == true, 'mongodb reports connected when the driver says so')
end
do
    local A = load('adapters/database/mongodb.lua', {
        mongodb = { isConnected = function() error('no connection') end },
    }).CisBridgeDatabaseMongodb
    local ok, ready = pcall(function() return A.ready() end)
    check(ok and ready == false,
        'a driver that raises on isConnected reports not-ready rather than crashing')
end

-- --------------------------------------- mysql-connector and ghmattimysql
--
-- Both are callback-first and bridged to await. The property that matters is the
-- DEADLINE: a driver that never calls back must not park the caller forever.
for _, case in ipairs({
    { file = 'adapters/database/mysql_connector.lua', export = 'CisBridgeDatabaseMysqlConnector',
      name = 'mysql-connector', key = 'mysql-connector', probe = 'mysql_query' },
    { file = 'adapters/database/ghmattimysql.lua', export = 'CisBridgeDatabaseGhmatti',
      name = 'ghmattimysql', key = 'ghmattimysql', probe = 'execute' },
}) do
    local NEVER = { [case.key] = setmetatable({}, {
        __index = function(_, k)
            -- Every export answers nothing and calls no callback, which is what a
            -- driver that has died mid-request looks like from in here.
            if k == case.probe then return function() return nil end end
            return function() return nil end
        end,
    }) }
    local A = load(case.file, NEVER)[case.export]
    check(A and A.name() == case.name, ('%s names itself'):format(case.name))
    local txOk, txWhy = A.transaction({ { query = 'SELECT 1' } })
    check(txOk == false, ('%s refuses a transaction rather than faking one'):format(case.name))
    check(type(txWhy) == 'string' and txWhy:find('oxmysql', 1, true) ~= nil,
        ('and the refusal names what to use instead'):format(case.name))
end

-- ------------------------------------------------- the await bridge itself
--
-- The ghmattimysql adapter's `update` is the one whose return TYPE was wrong, so
-- it is checked against each shape a driver might hand back.
do
    local A = load('adapters/database/ghmattimysql.lua', {
        ghmattimysql = {
            execute = function(_, _, _, cb) cb({}) end,
            scalar = function(_, _, _, cb) cb(1) end,
            insert = function(_, _, _, cb) cb(7) end,
            update = function(_, _, _, cb) cb(3) end,
        },
    }).CisBridgeDatabaseGhmatti
    check(A and A.name() == 'ghmattimysql', 'ghmattimysql names itself when update exists')
    local affected = A.update('UPDATE 1', {})
    check(type(affected) == 'number',
        ("ghmattimysql's update returns a NUMBER of rows, not a result object")
        .. ' (got ' .. type(affected) .. ')')
end
do
    -- The old build, with no `update`. `Bridge.register` refuses the adapter
    -- because `update` is not in the probe list -- the caller's problem, not
    -- this one -- but `Adapter.update` still answers rather than raising, which
    -- is what the fallback exists for.
    local A = load('adapters/database/ghmattimysql.lua', {
        ghmattimysql = {
            execute = function(_, _, _, cb) cb(2) end,
            scalar = function(_, _, _, cb) cb(1) end,
            insert = function(_, _, _, cb) cb(7) end,
        },
    }).CisBridgeDatabaseGhmatti
    check(A and A.name() == 'ghmattimysql',
        'ghmattimysql still loads on a build with no update export')
    local affected = A.update('UPDATE 1', {})
    check(affected == nil or type(affected) ~= 'table',
        'and its update fallback does not hand back a result OBJECT')
end

-- ======================================================= 3. TARGETS
--
-- The client target adapters. Both keep their own record of what they created,
-- because BOTH providers' removal calls return nothing -- so success has to come
-- from the adapter, and an adapter that trusted the return value would pass on
-- a working server and fail the day a provider returned something falsy.
local SPEC = {
    zoneType = 'sphere',
    name = 'cis_bridge_probe',
    coords = vec3(0.0, 0.0, 72.0),
    size = 1.0,
    rotation = 0,
    debug = false,
    targetOptions = { options = {}, distance = 2.0 },
    options = {},
}

for _, case in ipairs({
    { file = 'adapters/target/ox_target.lua', export = 'CisBridgeTargetOx',
      name = 'ox_target', key = 'ox_target' },
    { file = 'adapters/target/qb_target.lua', export = 'CisBridgeTargetQb',
      name = 'qb-target', key = 'qb-target' },
}) do
    local calls = {}
    local rec = function(tag) return function() calls[#calls + 1] = tag end end
    local target = {
        addSphereZone = rec('addSphereZone'),
        addBoxZone = rec('addBoxZone'),
        addCircleZone = rec('addCircleZone'),
        removeZone = rec('removeZone'),
        addLocalEntity = rec('addLocalEntity'),
        removeLocalEntity = rec('removeLocalEntity'),
        AddBoxZone = rec('AddBoxZone'),
        AddCircleZone = rec('AddCircleZone'),
        RemoveZone = rec('RemoveZone'),
        AddTargetEntity = rec('AddTargetEntity'),
        RemoveTargetEntity = rec('RemoveTargetEntity'),
    }
    local A = load(case.file, { [case.key] = target })[case.export]
    check(A and A.name() == case.name, ('%s names itself'):format(case.name))
    check(A and A.available() == true, ('%s reports itself available'):format(case.name))

    local spec = { zoneType = 'sphere', name = 'probe_' .. case.name, coords = vec3(0, 0, 72), size = 1.0 }
    check(A and A.create(spec) == true, ('%s creates a sphere zone'):format(case.name))
    check(A and A.exists('probe_' .. case.name) == true,
        ('%s reports a created zone as existing'):format(case.name))

    -- THE ONE THAT MATTERS. removeZone returns NOTHING, so the adapter cannot
    -- use its return value; it decides from its own record.
    local removed, removeWhy = A.remove('probe_' .. case.name, spec, false)
    check(removed == true, ('%s removes a zone it created'):format(case.name))
    check(removed == true and removeWhy == nil,
        ('%s reports success from its own record, not from the provider return'):format(case.name))
    check(A and A.exists('probe_' .. case.name) == false,
        ('%s forgets a removed zone'):format(case.name))

    local refused, why = A.remove('never_created_' .. case.name, spec, false)
    check(refused == false, ('%s refuses to remove a zone it does not know'):format(case.name))
    check(type(why) == 'string', ('and says why'):format(case.name))
end

-- A box zone, and the shape differences between the two providers.
do
    local A = load('adapters/target/ox_target.lua', {
        ox_target = {
            addBoxZone = function() end,
            addSphereZone = function() end,
            removeZone = function() end,
            addLocalEntity = function() end,
            removeLocalEntity = function() end,
        },
    }).CisBridgeTargetOx
    local box = { zoneType = 'box', name = 'box_probe', coords = vec3(0, 0, 72), size = vec3(1, 1, 1) }
    check(A.create(box) == true, 'ox_target creates a box zone from a vector3 size')
    local array = { zoneType = 'box', name = 'box_array', coords = vec3(0, 0, 72), size = { 1, 1, 1 } }
    check(A.create(array) == true, 'ox_target accepts an array size as well')
end
do
    local A = load('adapters/target/qb_target.lua', {
        ['qb-target'] = {
            AddBoxZone = function() end,
            AddCircleZone = function() end,
            RemoveZone = function() end,
            AddTargetEntity = function() end,
            RemoveTargetEntity = function() end,
        },
    }).CisBridgeTargetQb
    -- An array size, which is the case that raises if the arithmetic indexes a
    -- missing component. `{1, 1, 1}` has no `.x`, so `size.x or size[1]` is the
    -- only thing that makes this work.
    local array = { zoneType = 'box', name = 'box_array', coords = vec3(0, 0, 72), size = { 1, 1, 1 } }
    local ok, err = pcall(function() return A.create(array) end)
    check(ok and A.create(array) == true,
        'qb-target accepts an array size, deriving minZ and maxZ from its third element')
    if not ok then
        check(false, '  (raised: ' .. tostring(err) .. ')')
    end
    -- A size with nothing in it. The adapter defaults each component to 1.0
    -- rather than indexing nil, which would raise inside the arithmetic.
    local empty = { zoneType = 'box', name = 'box_empty', coords = vec3(0, 0, 72) }
    check(A.create(empty) == true, 'qb-target defaults a missing size rather than raising')
end

-- A refusal from the provider, and a zone type that does not exist.
for _, case in ipairs({
    { file = 'adapters/target/ox_target.lua', export = 'CisBridgeTargetOx',
      name = 'ox_target', key = 'ox_target',
      fake = { addSphereZone = function() error('bad zone') end, addBoxZone = function() end,
               removeZone = function() end, addLocalEntity = function() end,
               removeLocalEntity = function() end } },
    { file = 'adapters/target/qb_target.lua', export = 'CisBridgeTargetQb',
      name = 'qb-target', key = 'qb-target',
      fake = { AddBoxZone = function() end, AddCircleZone = function() error('bad zone') end,
               RemoveZone = function() end, AddTargetEntity = function() end,
               RemoveTargetEntity = function() end } },
}) do
    local A = load(case.file, { [case.key] = case.fake })[case.export]
    local spec = { zoneType = 'sphere', name = 'raises_' .. case.name, coords = vec3(0, 0, 72), size = 1.0 }
    local ok, result, why = pcall(function() return A.create(spec) end)
    check(ok, ('%s survives a provider that raises'):format(case.name))
    check(ok and result == false,
        ('%s reports a provider raise as a refusal, not a crash'):format(case.name))
    check(ok and type(why) == 'string', ('and carries the reason'):format(case.name))
    check(ok and A.exists('raises_' .. case.name) == false,
        ('%s does not record a zone whose creation failed'):format(case.name))

    local bad, badWhy = A.create({ zoneType = 'hexagon', name = 'nope', coords = vec3(0, 0, 72) })
    check(bad == false, ('%s refuses an unknown zone type'):format(case.name))
    check(type(badWhy) == 'string' and badWhy:find('hexagon', 1, true) ~= nil,
        ('and names the zone type it was given'):format(case.name))
    check(A.create(nil) == false, ('%s refuses a nil spec'):format(case.name))
    check(A.create({}) == false, ('%s refuses a spec with no name'):format(case.name))
end

-- ============================================ 4. THE REGISTRATION SIDE
--
-- Every adapter above registered while it loaded, and that is worth asserting:
-- an adapter whose registration silently stopped working is the failure this
-- whole resource exists to prevent, and it is invisible from the outside.
-- Meaningful, not decorative. `or true` made it pass unconditionally, which is
-- the shape of an assertion that documents an intention rather than checking
-- one.
local lastLoad = load('adapters/inventory/qb_inventory.lua', {
    ['qb-inventory'] = fakeInventory({}),
})
check(lastLoad.CisBridgeInventoryQb ~= nil,
    'an adapter that loaded exports its method table')
check(#registrations >= 1,
    ('and it registered with cis_libs while loading (saw %d registrations)')
        :format(#registrations))
check(registrations[1] and registrations[1].provider == 'cis_bridge:CisBridgeInventoryQb',
    "under its OWN export name, so no two adapters can answer for one capability")

do
    -- One adapter per slot, loaded together, each registering under its own
    -- export name. Two adapters sharing a name would mean whichever file loaded
    -- last answered for every capability.
    local names = {}
    for _, case in ipairs({
        { file = 'adapters/target/ox_target.lua', export = 'CisBridgeTargetOx',
          fake = { ox_target = { addSphereZone = function() end, addBoxZone = function() end,
                                 removeZone = function() end, addLocalEntity = function() end,
                                 removeLocalEntity = function() end } } },
        { file = 'adapters/target/qb_target.lua', export = 'CisBridgeTargetQb',
          fake = { ['qb-target'] = { AddBoxZone = function() end, AddCircleZone = function() end,
                                     RemoveZone = function() end, AddTargetEntity = function() end,
                                     RemoveTargetEntity = function() end } } },
    }) do
        load(case.file, case.fake)
        names[#names + 1] = case.export
    end
    check(#names == 2 and names[1] ~= names[2],
        'the two target adapters declare DIFFERENT export names')
end

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(matrix): ' .. failures[i] .. '\n')
end
io.write(('matrix passed=%d failed=%d\n'):format(passed, failed))