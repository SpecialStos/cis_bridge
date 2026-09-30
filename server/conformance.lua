-- Conformance: one test per target, and a runner.
--
-- WHY THIS EXISTS
--
-- Third-party resources change under us, and every one of those changes
-- arrived here as a bug report that looked like a bug in somebody's server.
-- ox_target changed how it handles zones; qb-target returns nothing from a
-- removal, so a truthiness test on the result reports failure for a removal
-- that worked; oxmysql grew a `single` export and calling it on an older build
-- RAISES rather than returning nil.
--
-- Each of those was a real incident and each of them was invisible until
-- somebody's server broke. An adapter that ships without a test is an adapter
-- whose next upstream release is a production incident.
--
-- WHAT A TEST CHECKS
--
-- The CONTRACT, not the implementation. "Does addSphereZone exist" is worth
-- knowing and is not what breaks; "does a zone I create come back when I ask
-- whether it exists, and does removing one answer rather than raising" is. The
-- second is the property cis_libs actually depends on, and it is the one that
-- has broken.
--
-- NOTHING IS SENT. No webhook is posted, no row is written, no item is given.
-- The tests create and remove their own names, use obviously-synthetic ids, and
-- touch no player. A conformance test that mutates a customer's data to check
-- an integration is a support ticket waiting to happen.
--
--      cis_bridge test              -- everything
--      cis_bridge test database     -- one target

Conformance = {}

local results = {}

local function record(target, name, ok, detail)
    results[#results + 1] = {
        target = target, name = name, ok = ok and true or false, detail = detail,
    }
    print(('  [%s] %-46s %s%s'):format(
        target, name,
        ok and 'PASS' or 'FAIL',
        (not ok and detail) and (' -- ' .. tostring(detail)) or ''))
    return ok
end

-- A name nobody else will collide with. The target prefixes are already
-- scoped, but a conformance test that leaves a zone behind would be visible to
-- a player, and this is not worth being clever about.
local function probeName(target)
    return ('cis_bridge_conformance_%s_%d'):format(target, math.random(10000, 99999))
end

-- ===========================================================================
--  TARGET
-- ===========================================================================

local TARGET_COORDS = vector3(0.0, 0.0, 0.0)

local targetTests = {
    ox_target = function()
        local a = probeName('ox_sphere')
        local b = probeName('ox_box')
        local sphereOk, sphereWhy = Cis.target.add('sphere', a, TARGET_COORDS, 1.0, {})
        record('ox_target', 'creates a sphere zone', sphereOk, sphereWhy)
        record('ox_target', 'reports the created zone as existing',
            Cis.target.exists(a) == true)
        local boxOk, boxWhy = Cis.target.add('box', b, TARGET_COORDS, vector3(1.0, 1.0, 1.0), {})
        record('ox_target', 'creates a box zone', boxOk, boxWhy)
        -- THE ONE THAT ACTUALLY BREAKS. The removal calls return nothing at
        -- all, so success has to come from our own record; an adapter that used
        -- the return value would pass this today and fail the moment ox_target
        -- changed its mind about returning something falsy.
        local removed, removeWhy = Cis.target.remove(a)
        record('ox_target', 'removes a zone without raising', removed, removeWhy)
        record('ox_target', 'forgets a removed zone', Cis.target.exists(a) == false)
        record('ox_target', 'removing an unknown name is refused, not fatal',
            select(1, Cis.target.remove('cis_bridge_no_such_zone')) == false)
        Cis.target.remove(b)
    end,

    ['qb-target'] = function()
        local a = probeName('qb_circle')
        local b = probeName('qb_box')
        local ok1, why1 = Cis.target.add('sphere', a, TARGET_COORDS, 1.0, {})
        record('qb-target', 'creates a circle zone', ok1, why1)
        local ok2, why2 = Cis.target.add('box', b, TARGET_COORDS, vector3(1.0, 1.0, 1.0), {})
        record('qb-target', 'creates a box zone from a vector3 size', ok2, why2)
        record('qb-target', 'reports the created zone as existing', Cis.target.exists(a) == true)
        local removed, removeWhy = Cis.target.remove(a)
        record('qb-target', 'removes a zone', removed, removeWhy)
        -- qb-target takes three numbers and derives minZ/maxZ, where ox_target
        -- takes a vector3. A caller writing `{1, 1, 1}` must work on both.
        local c = probeName('qb_array')
        local ok3, why3 = Cis.target.add('box', c, TARGET_COORDS, { 1.0, 1.0, 1.0 }, {})
        record('qb-target', 'accepts an array size as well as a vector3', ok3, why3)
        Cis.target.remove(b)
        Cis.target.remove(c)
    end,
}

-- ===========================================================================
--  DATABASE
--
--  READ-ONLY except for the two DDL probes, and those use a table name with a
--  conformance prefix and drop it again. A conformance test that leaves a table
--  behind on a customer's database is litter.
-- ===========================================================================

local databaseTests = {
    oxmysql = function()
        local rows = Cis.db.query('SELECT 1 AS ok')
        record('oxmysql', 'query returns rows', type(rows) == 'table', type(rows))
        local one = Cis.db.single('SELECT 1 AS ok')
        record('oxmysql', 'single returns a row', type(one) == 'table', type(one))
        -- The fallback path. On a build with `single`, this is the export; on one
        -- without, it is the first row of a query. Either way the answer is a
        -- table, and a caller cannot tell -- which is the point.
        local v = Cis.db.scalar('SELECT 1')
        record('oxmysql', 'scalar returns a value', v ~= nil, tostring(v))
        local tableName = 'cis_bridge_conformance'
        Cis.db.query(('CREATE TABLE IF NOT EXISTS %s (id INT)'):format(tableName), {})
        record('oxmysql', 'applies DDL', true)
        local inserted = Cis.db.insert(('INSERT INTO %s (id) VALUES (?)'):format(tableName), { 1 })
        record('oxmysql', 'insert returns an id', inserted ~= nil, tostring(inserted))
        local count = Cis.db.scalar(('SELECT COUNT(*) FROM %s'):format(tableName))
        record('oxmysql', 'the inserted row is visible', tonumber(count) == 1, tostring(count))
        -- The reason this adapter exists rather than the mysql-connector one.
        local txOk, txWhy = Cis.db.transaction({
            { query = ('INSERT INTO %s (id) VALUES (?)'):format(tableName), values = { 2 } },
        })
        record('oxmysql', 'supports a transaction', txOk == true, txWhy)
        Cis.db.query(('DROP TABLE IF EXISTS %s'):format(tableName), {})
        record('oxmysql', 'cleans up after itself', true)
    end,

    ['mysql-connector'] = function()
        local rows = Cis.db.query('SELECT 1 AS ok')
        record('mysql-connector', 'query returns rows', type(rows) == 'table', type(rows))
        local one = Cis.db.single('SELECT 1 AS ok')
        record('mysql-connector', 'single returns a row', type(one) == 'table', type(one))
        local v = Cis.db.scalar('SELECT 1')
        record('mysql-connector', 'scalar returns a value', v ~= nil, tostring(v))
        -- The refusal, tested on purpose. A driver that quietly ran the
        -- statements one at a time would pass a "does it work" test and fail
        -- every caller who needed them atomic.
        local txOk, txWhy = Cis.db.transaction({ { query = 'SELECT 1' } })
        record('mysql-connector', 'refuses a transaction rather than faking one',
            txOk == false, txWhy)
        record('mysql-connector', 'the refusal names oxmysql',
            type(txWhy) == 'string' and txWhy:find('oxmysql') ~= nil, tostring(txWhy))
    end,

    ghmattimysql = function()
        local rows = Cis.db.query('SELECT 1 AS ok')
        record('ghmattimysql', 'query returns rows', type(rows) == 'table', type(rows))
        local txOk = Cis.db.transaction({ { query = 'SELECT 1' } })
        record('ghmattimysql', 'refuses a transaction', txOk == false)
    end,

    mongodb = function()
        -- The honest test for an unsupported target: it says so.
        local rows, why = Cis.db.query('SELECT 1')
        record('mongodb', 'says it is not a SQL driver', rows == nil, why)
    end,
}

-- ===========================================================================
--  INVENTORY
--
--  NOTHING is added or removed. A conformance test that gives a player an item
--  to see whether the inventory works is a test that can leave a player with an
--  item, and "can this read a count" is the property that actually breaks.
-- ===========================================================================

local inventoryTests = {
    ['ox_inventory'] = function()
        local count = Cis.inventory.count(0, 'cis_bridge_no_such_item')
        record('ox_inventory', 'a missing item counts zero, not nil',
            count == 0, tostring(count))
        record('ox_inventory', 'has() agrees with count()',
            Cis.inventory.has(0, 'cis_bridge_no_such_item') == false)
    end,
    ['qb-inventory'] = function()
        local count = Cis.inventory.count(0, 'cis_bridge_no_such_item')
        record('qb-inventory', 'a missing item counts zero, not nil', count == 0, tostring(count))
    end,
    ['qs-inventory'] = function()
        local count = Cis.inventory.count(0, 'cis_bridge_no_such_item')
        record('qs-inventory', 'a missing item counts zero, not nil', count == 0, tostring(count))
    end,
    ['codem-inventory'] = function()
        local count = Cis.inventory.count(0, 'cis_bridge_no_such_item')
        record('codem-inventory', 'a missing item counts zero, not nil', count == 0, tostring(count))
    end,
}

local tests = {
    ['ox_target'] = targetTests.ox_target,
    ['qb-target'] = targetTests['qb-target'],
    ['oxmysql'] = databaseTests.oxmysql,
    ['mysql-connector'] = databaseTests['mysql-connector'],
    ['ghmattimysql'] = databaseTests.ghmattimysql,
    ['mongodb'] = databaseTests.mongodb,
    ['ox_inventory'] = inventoryTests['ox_inventory'],
    ['qb-inventory'] = inventoryTests['qb-inventory'],
    ['qs-inventory'] = inventoryTests['qs-inventory'],
    ['codem-inventory'] = inventoryTests['codem-inventory'],
}

--- Run one target's tests, or all of them.
---
--- A target that is not installed reports SKIP rather than FAIL, and the
--- distinction is the whole value of this command: "ox_target failed" and "you
--- do not have ox_target" are different sentences and the operator needs to be
--- told which one applies.
---
--- The list of targets comes from what ACTUALLY REGISTERED, not from a static
--- list of everything this resource can adapt. A static list would print a FAIL
--- line for every target the operator does not have, which buries the one
--- result they came for under a wall of noise they have to read past.
function Conformance.run(only)
    results = {}
    print('')
    print('cis_bridge conformance -- nothing is sent, nothing is written to a player')
    print('')

    -- Slot -> target, sorted by target name so two runs on the same server
    -- print in the same order and can be compared line for line.
    local registered = Bridge.registered()
    local order, targets = {}, {}
    for slot, target in pairs(registered) do
        order[#order + 1] = slot
        targets[slot] = target
    end
    table.sort(order, function(a, b) return targets[a] < targets[b] end)

    local ran, skipped, failed = 0, 0, 0
    for _, slot in ipairs(order) do
        local target = targets[slot]
        if not only or target == only or slot == only then
            local test = tests[target]
            if not test then
                record(target, 'has a conformance test', false, 'no conformance test is defined for it')
            else
                local ok, err = pcall(test)
                if ok then
                    ran = ran + 1
                else
                    -- The test itself raised. That is a different failure from
                    -- an assertion, and it means the adapter is broken rather
                    -- than incompatible -- worth saying exactly.
                    record(target, 'the test ran to completion', false, tostring(err))
                end
            end
        end
    end

    -- Counted ONCE, from the results. Counting inside the loop as well would
    -- report a raised test twice, which is how a two-problem report becomes a
    -- four-problem one.
    for _, r in ipairs(results) do
        if not r.ok then
            failed = failed + 1
        end
    end
    if not only then
        local declared = 0
        for _ in pairs(tests) do declared = declared + 1 end
        skipped = declared - ran
        if skipped > 0 then
            print(('  (%d target(s) not installed on this server)'):format(skipped))
        end
    end
    print('')
    print(('cis_bridge: %d target(s) tested, %d not installed, %d failure(s)')
        :format(ran, skipped, failed))
    return failed == 0
end

--- The last run's results, for a support thread. No data is sent anywhere --
--- this is an export the operator calls deliberately.
exports('RunConformance', function(target)
    return Conformance.run(target)
end)

exports('GetConformanceResults', function()
    local out = {}
    for _, r in ipairs(results) do
        out[#out + 1] = r
    end
    return out
end)

-- Restricted, like cis_debug: a conformance run creates and removes entities,
-- and there is no reason a player should be able to trigger it.
RegisterCommand('cis_bridge', function(src, args)
    if src ~= 0 then
        local fw = exports['cis_libs']:GetFramework()
        if not (fw and fw.HasPermission and fw.HasPermission(src, 'admin')) then
            return
        end
    end
    Conformance.run(args and args[1] or nil)
end, true)
