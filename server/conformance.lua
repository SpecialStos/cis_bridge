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
-- WHAT A TEST IS POINTED AT, WHICH IS THE WHOLE DESIGN
--
-- At THIS RESOURCE'S OWN ADAPTER, never at a capability that happens to be
-- answering.
--
-- The inventory tests used to call `Cis.inventory.count`, which cis_libs routes
-- to the `inventory` slot -- the service cis_core owns -- while cis_bridge
-- fills the `inventoryProvider` slot underneath it. So the suite was testing
-- somebody else's code: on a server running cis_bridge without cis_core it
-- reported four broken inventory adapters on a perfectly healthy install, and
-- on a server with both it proved nothing about the adapters that are this
-- resource's responsibility. Every test below reaches the adapter through
-- `Bridge.adapterFor`, and the only `Cis.*` call left in the suite is the
-- database one, where the abstraction really is the thing under test.
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

-- Published by server/ratelimit.lua, which fxmanifest loads FIRST. That
-- ordering is the whole reason this is a global and not a `require`:
-- see the footer of adapters/discord/embed.lua.
local Cooldown = CisBridgeRateLimit

Conformance = {}

local results = {}

-- `Cis.target.*` is a CLIENT surface, so a target adapter cannot be tested from
-- the server. Declared here, before the functions that read it, because a local
-- declared below a function is not in that function's scope at all: `run` would
-- be reading a GLOBAL of the same name, which is nil, and every target would be
-- counted as "not installed" while its real reason -- it runs on the client --
-- was never printed.
local CLIENT_ONLY = { ['ox_target'] = true, ['qb-target'] = true }

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

-- SKIP is not FAIL. A check that cannot run on this realm, or that cannot run
-- on this server, is not a broken adapter -- and the README promises the runner
-- prints SKIP, which it did not have a path for at all. Recorded as ok so a
-- skip never turns a green run red, and flagged so the tally can tell the
-- operator how many assertions did not actually execute.
local function skip(target, name, detail)
    results[#results + 1] = {
        target = target, name = name, ok = true, skipped = true, detail = detail,
    }
    print(('  [%s] %-46s %s%s'):format(
        target, name, 'SKIP', detail and (' -- ' .. tostring(detail)) or ''))
    return true
end

-- A name nobody else will collide with. The target prefixes are already
-- scoped, but a conformance test that leaves a zone behind would be visible to
-- a player, and this is not worth being clever about.
local function probeName(target)
    return ('cis_bridge_conformance_%s_%d'):format(target, math.random(10000, 99999))
end

-- THE CHECK EVERY ADAPTER GETS, AND THE CHEAPEST ONE THAT MATTERS.
--
-- `GetCapabilities()` asks cis_libs to work out, for each slot, which methods
-- the registered provider cannot serve. An empty `missing` is cis_libs saying
-- "the thing you registered answers everything I might call on it" -- which is
-- exactly the class of bug this suite exists to find, checked for free, and
-- checked the same way for all eleven adapters rather than eleven times over in
-- eleven slightly different ways.
--
-- It has also caught the specific defect that a per-adapter check cannot: a
-- provider whose method table answers `Log` where the dispatcher sends `log`.
local function checkSlotContract(slot, target)
    local ok, caps = pcall(function()
        return exports['cis_libs']:GetCapabilities()
    end)
    if not ok or type(caps) ~= 'table' then
        return skip(target, 'slot contract', 'cis_libs would not report its capabilities')
    end
    local entry = caps[slot]
    if not entry or not entry.owner then
        return record(target, 'slot contract', false, ('nothing owns the %q slot'):format(slot))
    end
    if entry.owner ~= GetCurrentResourceName() then
        return record(target, 'slot contract', false,
            ('the %q slot is held by %s, not by cis_bridge'):format(slot, tostring(entry.owner)))
    end
    if not entry.resolved then
        return record(target, 'slot contract', false, 'cis_libs cannot resolve our export')
    end
    local missing = entry.missing
    if type(missing) == 'table' and #missing > 0 then
        return record(target, 'serves every method the slot declares', false,
            ('missing: %s'):format(table.concat(missing, ', ')))
    end
    return record(target, 'serves every method the slot declares', true)
end

-- Every adapter answers `name()`. It is one line and it is the check that
-- catches a copy-paste in a file nobody re-reads: an ox_inventory adapter that
-- reports its name as 'oxmysql' passes a presence probe and misleads every
-- diagnostic that prints the owner.
local function checkName(slot, target, adapter, expected)
    if type(adapter.name) ~= 'function' then
        return record(target, 'reports its own name', false, 'the adapter has no name()')
    end
    local ok, name = pcall(adapter.name)
    record(target, 'reports its own name', ok and name == expected,
        ok and ('answered %q, expected %q'):format(tostring(name), expected) or tostring(name))
end

local function adapterFor(slot, target)
    local adapter = Bridge.adapterFor(slot)
    if type(adapter) ~= 'table' then
        record(target, 'exposes its method table to the conformance runner', false,
            'the adapter did not publish itself; it registered but cannot be tested')
        return nil
    end
    return adapter
end

-- ===========================================================================
--  DATABASE
--
--  READ-ONLY except for the two DDL probes, and those use a table name with a
--  conformance prefix and drop it again. A conformance test that leaves a table
--  behind on a customer's database is litter.
-- ===========================================================================

-- An item name that cannot exist. Reading a count for it is the only inventory
-- operation this suite performs, and it is the operation that has broken: a
-- driver that answers nil where the slot promises a number turns a player with
-- no water bottle into an unreadable player.
local NO_SUCH_ITEM = 'cis_bridge_no_such_item'

local databaseTests = {
    oxmysql = function()
        local adapter = adapterFor('database', 'oxmysql')
        if not adapter then return end
        checkName('database', 'oxmysql', adapter, 'oxmysql')

        local rows = adapter.query('SELECT 1 AS ok', {})
        record('oxmysql', 'query returns rows', type(rows) == 'table', type(rows))
        local one = adapter.single('SELECT 1 AS ok', {})
        record('oxmysql', 'single returns a row', type(one) == 'table', type(one))
        local v = adapter.scalar('SELECT 1', {})
        record('oxmysql', 'scalar returns a value', v ~= nil, tostring(v))

        -- The abstraction, because for the database slot it is genuinely part
        -- of what this adapter has to be correct about: cis_libs calls it, not
        -- the adapter directly, and an adapter that serves a direct call and
        -- not a routed one is broken for every consumer on the platform.
        local routed = Cis.db.query('SELECT 1 AS ok')
        record('oxmysql', 'answers when routed through Cis.db', type(routed) == 'table',
            type(routed))

        local tableName = 'cis_bridge_conformance'
        -- The result of the DDL is inspected. It was previously recorded as a
        -- hardcoded `true`, which made the one line whose entire job was to
        -- prove this test leaves no litter on a customer's database a line that
        -- cannot fail: a database user with no DDL privilege, or no DROP, still
        -- reported PASS. A test that cannot fail is worse than no test, because
        -- it is read as evidence.
        local created = adapter.query(('CREATE TABLE IF NOT EXISTS %s (id INT)'):format(tableName), {})
        record('oxmysql', 'applies DDL', created ~= nil, type(created))
        local inserted = adapter.insert(('INSERT INTO %s (id) VALUES (?)'):format(tableName), { 1 })
        record('oxmysql', 'insert returns an id', inserted ~= nil, tostring(inserted))
        local count = adapter.scalar(('SELECT COUNT(*) FROM %s'):format(tableName), {})
        record('oxmysql', 'the inserted row is visible', tonumber(count) == 1,
            tostring(count) .. ' row(s); a count above 1 means an earlier run did not clean up')

        -- THE TRANSACTION, AND WHY IT IS THE INTERESTING ONE.
        --
        -- Written the way the cis_libs contract documents a transaction entry
        -- -- `params`, not `values`, not `parameters` -- because that is what
        -- every consumer on this platform writes. oxmysql does not read that key
        -- at all: its entry type is `{ query, parameters?, values? }` and its
        -- parser falls back to the transaction's outer parameter array when it
        -- finds neither. So an adapter that passed the entry through untouched
        -- ran a statement with an UNBOUND `?` and reported success, and the only
        -- way to notice was to notice the wrong row afterwards.
        --
        -- This is the assertion that would have caught it, and it is worth
        -- keeping even though it passes: it is the one line in the suite that
        -- fails loudly if the normalisation in the adapter is ever removed.
        local txOk, txWhy = adapter.transaction({
            { query = ('INSERT INTO %s (id) VALUES (?)'):format(tableName), params = { 2 } },
        })
        record('oxmysql', 'a transaction binds the key the contract documents', txOk == true, txWhy)
        local txCount = adapter.scalar(('SELECT COUNT(*) FROM %s WHERE id = ?'):format(tableName), { 2 })
        record('oxmysql', 'the transaction actually bound its value', tonumber(txCount) == 1,
            ('a count of %s means the statement ran with an unbound placeholder')
                :format(tostring(txCount)))

        -- A malformed entry is refused before the driver opens a transaction,
        -- not discovered by it after six statements have run.
        local refused, why = adapter.transaction({ { notAQuery = true } })
        record('oxmysql', 'refuses an entry with no query', refused == false, why)
        record('oxmysql', 'the refusal names the offending entry',
            type(why) == 'string' and why:find('1') ~= nil, tostring(why))
        local empty = adapter.transaction({})
        record('oxmysql', 'refuses an empty transaction', empty == false, select(2, adapter.transaction({})))

        local dropped = adapter.query(('DROP TABLE IF EXISTS %s'):format(tableName), {})
        record('oxmysql', 'drops the table it created', dropped ~= nil, type(dropped))
        -- Asking the catalogue, rather than assuming the DROP worked. This is the
        -- check that makes "cleans up after itself" mean something.
        local leftovers = adapter.scalar(
            'SELECT COUNT(*) FROM information_schema.tables '
            .. 'WHERE table_schema = DATABASE() AND table_name = ?', { tableName })
        if leftovers == nil then
            -- SKIP, not FAIL. A database user with no SELECT on information_schema
            -- has told us nothing about whether the DROP worked, and reporting
            -- that as a failed adapter is the same mistake as the hardcoded `true`
            -- this replaced -- just in the pessimistic direction.
            skip('oxmysql', 'cleans up after itself',
                'this database user cannot read information_schema; the DROP result above is the only evidence')
        else
            record('oxmysql', 'cleans up after itself', tonumber(leftovers) == 0,
                leftovers and (tostring(leftovers) .. ' table(s) still present') or 'the catalogue query failed')
        end
    end,

    ['mysql-connector'] = function()
        local adapter = adapterFor('database', 'mysql-connector')
        if not adapter then return end
        checkName('database', 'mysql-connector', adapter, 'mysql-connector')
        local rows = adapter.query('SELECT 1 AS ok', {})
        record('mysql-connector', 'query returns rows', type(rows) == 'table', type(rows))
        local one = adapter.single('SELECT 1 AS ok', {})
        record('mysql-connector', 'single returns a row', type(one) == 'table', type(one))
        local v = adapter.scalar('SELECT 1', {})
        record('mysql-connector', 'scalar returns a value', v ~= nil, tostring(v))
        local routed = Cis.db.query('SELECT 1 AS ok')
        record('mysql-connector', 'answers when routed through Cis.db', type(routed) == 'table',
            type(routed))
        -- The refusal, tested on purpose. A driver that quietly ran the
        -- statements one at a time would pass a "does it work" test and fail
        -- every caller who needed them atomic.
        local txOk, txWhy = adapter.transaction({ { query = 'SELECT 1' } })
        record('mysql-connector', 'refuses a transaction rather than faking one',
            txOk == false, txWhy)
        record('mysql-connector', 'the refusal names oxmysql',
            type(txWhy) == 'string' and txWhy:find('oxmysql') ~= nil, tostring(txWhy))
    end,

    ghmattimysql = function()
        local adapter = adapterFor('database', 'ghmattimysql')
        if not adapter then return end
        checkName('database', 'ghmattimysql', adapter, 'ghmattimysql')
        local rows = adapter.query('SELECT 1 AS ok', {})
        record('ghmattimysql', 'query returns rows', type(rows) == 'table', type(rows))
        local v = adapter.scalar('SELECT 1', {})
        record('ghmattimysql', 'scalar returns a value', v ~= nil, tostring(v))
        -- THE ONE THAT WAS WRONG. The slot contract is
        -- `Update(sql, params) -> affected`, a NUMBER of rows. This adapter
        -- called `execute`, whose callback yields the raw result OBJECT, so
        -- `Cis.db.update` handed its caller an OkPacket table where a count was
        -- expected -- and a caller writing `if affected > 0 then` compared a
        -- table with a number and raised. Checked against a real row so the
        -- assertion is about the answer's TYPE, which is the whole contract.
        local tableName = 'cis_bridge_conformance_ghmatti'
        adapter.query(('CREATE TABLE IF NOT EXISTS %s (id INT)'):format(tableName), {})
        adapter.query(('INSERT INTO %s (id) VALUES (1)'):format(tableName), {})
        local affected = adapter.update(
            ('UPDATE %s SET id = 2 WHERE id = 1'):format(tableName), {})
        record('ghmattimysql', 'update returns a number of rows, not a result object',
            type(affected) == 'number', ('answered %s'):format(type(affected)))
        adapter.query(('DROP TABLE IF EXISTS %s'):format(tableName), {})
        local txOk = adapter.transaction({ { query = 'SELECT 1' } })
        record('ghmattimysql', 'refuses a transaction', txOk == false)
    end,

    mongodb = function()
        local adapter = adapterFor('database', 'mongodb')
        if not adapter then return end
        checkName('database', 'mongodb', adapter, 'mongodb')
        -- The honest test for an unsupported target: it says so, rather than
        -- raising or pretending.
        local rows, why = adapter.query('SELECT 1')
        record('mongodb', 'says it is not a SQL driver', rows == nil, why)
        record('mongodb', 'the refusal explains why',
            type(why) == 'string' and why:find('mongodb') ~= nil, tostring(why))
        record('mongodb', 'every method refuses rather than raising',
            select(1, adapter.single('SELECT 1')) == nil
            and select(1, adapter.scalar('SELECT 1')) == nil
            and select(1, adapter.insert('INSERT 1')) == nil
            and select(1, adapter.update('UPDATE 1')) == nil)
        record('mongodb', 'ready() reports a connection without raising',
            type(adapter.ready()) == 'boolean')
    end,
}

-- ===========================================================================
--  INVENTORY
--
--  NOTHING is added or removed. A conformance test that gives a player an item
--  to see whether the inventory works is a test that can leave a player with an
--  item, and "can this read a count" is the property that actually breaks.
--
--  Every test below is pointed at the ADAPTER, not at `Cis.inventory`. See the
--  header for why that distinction is the whole design of this suite.
-- ===========================================================================

-- The shared body. The four targets answer `count` with different types and
-- different meanings for "you do not have that", and the differences are the
-- point -- an adapter that coerces them all to the same answer is hiding one of
-- the two questions a caller has.
--
--   count(item)  -> a NUMBER. "They have none."
--   count(src, 0) -> a NUMBER too, on ox_inventory: an absent inventory is 0.
--   nil           -> "I could not tell." Never "they have none".
local function inventoryTest(slot, target, src, onNotZero)
    local adapter = adapterFor(slot, target)
    if not adapter then return end
    checkName(slot, target, adapter, target)
    record(target, 'reports itself as available', adapter.available() == true)

    local count = adapter.count(src, NO_SUCH_ITEM)
    record(target, 'a missing item counts zero, not nil', count == 0, tostring(count))
    if onNotZero then
        onNotZero(count)
    end

    -- The refusal shapes, checked because they are the ones a consumer
    -- branches on and the ones no other assertion here would catch.
    local badSrc = adapter.count(nil, NO_SUCH_ITEM)
    record(target, 'a nil source is nil rather than zero', badSrc == nil, tostring(badSrc))
    local badItem = adapter.count(src, nil)
    record(target, 'a nil item is nil rather than zero', badItem == nil, tostring(badItem))
end

local inventoryTests = {
    ['ox_inventory'] = function()
        -- src 0 is the console. ox_inventory has no inventory for it, so this
        -- is the case where `Search` answers false and `GetItemCount` answers
        -- 0 -- and the adapter has to make the choice deliberately, because the
        -- slot promises a number.
        inventoryTest('inventoryProvider', 'ox_inventory', 0)
        local adapter = Bridge.adapterFor('inventoryProvider')
        if adapter and type(adapter.canCarry) == 'function' then
            local ok = adapter.canCarry(0, NO_SUCH_ITEM, 1)
            record('ox_inventory', 'canCarry answers a boolean without raising',
                type(ok) == 'boolean', tostring(ok))
        else
            skip('ox_inventory', 'canCarry answers a boolean without raising',
                'this adapter does not expose canCarry')
        end
    end,
    ['qb-inventory'] = function()
        -- src 1, because qb-inventory's GetItemCount answers 0 for a player who
        -- has nothing rather than nil, and that is the answer being asserted.
        inventoryTest('inventoryProvider', 'qb-inventory', 1)
    end,
    ['qs-inventory'] = function()
        inventoryTest('inventoryProvider', 'qs-inventory', 1)
    end,
    ['codem-inventory'] = function()
        inventoryTest('inventoryProvider', 'codem-inventory', 1)
    end,
}

-- ===========================================================================
--  DISCORD
--
--  This test sends nothing, and that is a real constraint rather than a
--  stylistic one. Enqueuing a genuine webhook URL would eventually be posted by
--  the drain loop, so the only URL this touches is the CHANGE-ME placeholder --
--  and the property under test is precisely that the adapter refuses it. Walking
--  the whole path (capability -> method dispatch -> usable()) with a URL that is
--  guaranteed to be discarded exercises the contract without putting a message
--  on anybody's channel.
--
--  It also checks the embed, because the embed is where this adapter failed for
--  its entire life: an optional `footer` object built from a config table that
--  is always empty serialized to `"footer":{}`, which Discord rejects with a 400.
--  The whole feature was dead and the only symptom was a webhook that "stopped
--  working some time ago". The payload is asserted here rather than posted.
-- ===========================================================================

local function discordTest()
    local adapter = adapterFor('discord', 'cis_bridge')
    if not adapter then return end
    checkSlotContract('discord', 'cis_bridge')
    record('discord', 'the capability answers with its method table',
        type(adapter) == 'table' and type(adapter.log) == 'function' and type(adapter.depth) == 'function')

    local depthBefore = select(1, adapter.depth())
    local accepted = adapter.log('https://discord.com/api/webhooks/CHANGE-ME/x',
        'cis_bridge conformance', 'this message is never sent', 'red', false)
    record('discord', 'refuses an unconfigured placeholder webhook', accepted == false)
    local depthAfter = select(1, adapter.depth())
    record('discord', 'queues nothing for a refused webhook', depthAfter == depthBefore)
    local droppedBefore = select(2, adapter.depth())

    local empty = adapter.log(nil, 'title', 'message', 'red', false)
    record('discord', 'refuses a nil webhook', empty == false)
    local blank = adapter.log('', 'title', 'message', 'red', false)
    record('discord', 'refuses an empty webhook', blank == false)
    record('discord', 'still queued nothing',
        select(1, adapter.depth()) == depthBefore and select(2, adapter.depth()) == droppedBefore)

    -- The URL is an ARGUMENT to this method and this is the platform's only
    -- outbound request, so anything that is not a Discord webhook has to be
    -- refused before it reaches the queue. Refusing it here is safe: the drain
    -- loop posts what IS queued, and nothing is queued by a refusal.
    --
    -- The URL used is an unroutable `.invalid` host, which is reserved by
    -- RFC 6761 and can never resolve. So even a bug that queued it would not
    -- send it anywhere, and this assertion can never cause a real request.
    local offsite = adapter.log('https://cis_bridge.invalid/api/webhooks/1/token',
        'cis_bridge conformance', 'never sent', 'red', false)
    record('discord', 'refuses a webhook on a host that is not Discord', offsite == false)
    local plain = adapter.log('http://discord.com/api/webhooks/1/token',
        'cis_bridge conformance', 'never sent', 'red', false)
    record('discord', 'refuses a webhook that is not HTTPS', plain == false)
    record('discord', 'queued nothing for either',
        select(1, adapter.depth()) == depthBefore and select(2, adapter.depth()) == droppedBefore)
end

-- ===========================================================================
--  THE TESTS, BY SLOT
-- ===========================================================================

local tests = {
    database = function(slot, target)
        local test = databaseTests[target]
        if not test then
            record(target, 'has a conformance test', false,
                'a database adapter registered under a name this suite does not know')
            return
        end
        checkSlotContract(slot, target)
        test()
    end,
    inventoryProvider = function(slot, target)
        local test = inventoryTests[target]
        if not test then
            record(target, 'has a conformance test', false,
                'an inventory adapter registered under a name this suite does not know')
            return
        end
        checkSlotContract(slot, target)
        test()
    end,
    discord = function() discordTest() end,
    target = function(slot, target)
        -- `Cis.target.*` is a CLIENT surface. `init.lua` defines it inside its
        -- not-server branch, so on the server `Cis.target` is nil and every call
        -- raised "attempt to call field 'add' (a nil value)". Both target tests
        -- therefore failed on a healthy install, and the client half -- which is
        -- the only place they can run -- was never reached.
        --
        -- The client registry is INDEPENDENT of the server one, so this slot is
        -- held on the server by the adapter and on the client by the same
        -- adapter in the same file; the checks themselves run over there. See
        -- client/conformance.lua, which the runner reaches through
        -- Conformance.requestClient below.
        skip(target, 'conformance runs on the client',
            'Cis.target.* is a client surface; the server asks clients to run its half')
    end,
}

-- Every target this resource can adapt, so the runner can report what it did
-- NOT test. A static list, used only for the "not installed" count and for
-- answering "which targets do you support" without a running server.
local KNOWN_TARGETS = {
    'codem-inventory', 'ghmattimysql', 'mysql-connector', 'mongodb', 'ox_inventory',
    'ox_target', 'oxmysql', 'qb-inventory', 'qb-target', 'qs-inventory',
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

    if #order == 0 then
        print('  cis_bridge registered no capability. That is the answer: nothing on this')
        print('  server is being adapted. Check that cis_libs is started and that the')
        print('  third-party resources you expect are started BEFORE cis_bridge.')
        print('')
        -- The next command, in the same shape the boot report uses.
        --
        -- It was missing here and the report had it, which is the wrong way
        -- round: an operator who has just run `cis_bridge test` and got an
        -- empty answer is MORE likely to need the other command than one reading
        -- a boot log, and the boot log already told them.
        print('  `cis_bridge report` says what each adapter was waiting for, and the')
        print('  fix for each one that is not registered.')
        print('')
    end

    local ran, failed = 0, 0
    for _, slot in ipairs(order) do
        local target = targets[slot]
        if not only or target == only or slot == only then
            local test = tests[slot]
            if not test then
                -- By SLOT, not by target. The discord slot registers against
                -- this resource rather than a third party, so its target name is
                -- "cis_bridge" and a lookup by name found nothing -- reporting
                -- "has a conformance test: FAIL" on every server that had the
                -- adapter working perfectly. A capability that is installed and
                -- healthy is the last thing a support thread should be told is
                -- broken.
                record(target, 'has a conformance test', false,
                    ('no conformance test is defined for the %q slot'):format(slot))
            else
                local ok, err = pcall(test, slot, target)
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
    local notRun = 0
    for _, r in ipairs(results) do
        if r.skipped then
            notRun = notRun + 1
        elseif not r.ok then
            failed = failed + 1
        end
    end

    -- Not-installed is computed against what the suite COULD test, not against
    -- every third-party resource that exists. The target adapters are excluded
    -- because their checks run on the client and are reported separately; a
    -- server without ox_target would otherwise be told it "failed" here.
    local notInstalled = 0
    if not only then
        local seen = {}
        for _, target in pairs(targets) do
            if not CLIENT_ONLY[target] then
                seen[target] = true
            end
        end
        for _, name in ipairs(KNOWN_TARGETS) do
            if not seen[name] then
                notInstalled = notInstalled + 1
            end
        end
        if notInstalled > 0 then
            print(('  (%d target(s) not installed on this server)'):format(notInstalled))
        end
    end

    print('')
    print(('cis_bridge: %d target(s) tested, %d not installed, %d skipped, %d failure(s)')
        :format(ran, notInstalled, notRun, failed))
    if not only and Conformance.requestClient then
        -- Only on a full run: `cis_bridge test <target>` is a question about
        -- one target, and asking every player on the server to answer it is
        -- not what was asked for.
        Conformance.requestClient()
    end
    return failed == 0
end

-- `Cis.target.*` is a client surface, so a target adapter cannot be tested from
-- the server. Declared above, with the rest of the file's constants.

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

--- Ask every connected client to run its half, and print what comes back.
---
--- This is the only way the client half can be reached. `client/conformance.lua`
--- answers this event, but nothing sent it: the client ran its checks on join,
--- printed them to a console the operator is usually not looking at, and the
--- whole reason the file exists -- "a support thread needs both halves and only
--- the server can be asked from a console" -- did not happen. The event was also
--- DECLARED in api.lua as a published server->client event while nothing in
--- the platform triggered it, which the contract checker cannot catch: a
--- declared event that is never sent is still a declared event.
---
--- The answer arrives as a table of results. An untrusted client can send
--- anything, so this prints and counts, and never treats a client's PASS as
--- proof of anything the server did not check itself. It also REFUSES a payload
--- that is large, because this handler is reachable by any connected player and
--- an unbounded table from an untrusted source is a memory cost with no upside.
function Conformance.requestClient()
    local asked = 0
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src then
            TriggerClientEvent('cis_bridge:client:conformance', src)
            asked = asked + 1
        end
    end
    print(('cis_bridge: asked %d client(s) to run their half of the conformance suite'):format(asked))
    return asked
end

-- A client answers with a table of rows. Bounded, because the sender is any
-- connected player and this handler prints whatever it is given.
local MAX_CLIENT_RESULTS = 64

-- THIS HANDLER IS REACHABLE BY EVERY CONNECTED PLAYER, AND IT PRINTS.
--
-- `cis_bridge:server:conformanceResults` is a net event, so a cheat menu can
-- fire it as fast as the executor likes with any payload. Each accepted call
-- prints up to MAX_CLIENT_RESULTS lines into the server console, and the server
-- console is the operator's only window onto a running server -- so a player who
-- fires this in a loop does not break anything, they bury it. A console that
-- scrolls at thousands of lines a second is a console nobody is reading, which
-- means the one command this resource exists to provide stops being useful
-- exactly when it is needed.
--
-- The cooldown is per SOURCE and generous enough that a real answer is never
-- refused. The whole point of this event is a report a human asked for, which
-- happens on the order of once per server lifetime, so five seconds costs
-- nothing and removes the flood entirely.
--
-- Refusals are counted rather than logged. A per-refusal log line from a
-- flooding client is the same flood with extra steps.
local CLIENT_COOLDOWN_MS = 5000
local clientCooldown = Cooldown.new({ intervalMs = CLIENT_COOLDOWN_MS })

--- Drop a player's cooldown when they disconnect.
---
--- Without this the table is a slow leak keyed by a source id that FiveM reuses,
--- so a server that churns players for a month accumulates one entry per player
--- who ever answered -- and the entry outlives the session by however long the
--- server runs.
AddEventHandler('playerDropped', function()
    local src = source
    if src then
        clientCooldown:forget(src)
    end
end)

RegisterNetEvent('cis_bridge:server:conformanceResults', function(payload)
    local src = source
    if src == 0 or type(payload) ~= 'table' then
        return
    end

    -- Cooldown BEFORE any work, and before printing the player's name. The name
    -- is the one thing here that goes to the console unconditionally.
    if not clientCooldown:take(src) then
        return
    end

    -- VALIDATE BEFORE ANNOUNCING.
    --
    -- The rows are walked and filtered first, and if nothing survives then
    -- nothing is printed at all -- not a header, not a summary, not the player's
    -- name.
    --
    -- The previous version printed the report header and the "reported N
    -- failures" line before it looked at a single row, so a payload with no
    -- valid rows in it -- an empty table, a nested table, five thousand junk
    -- entries -- produced a block of console that reads exactly like a report
    -- arrived. That is worse than printing nothing: an operator scanning for the
    -- conformance output cannot tell a report from a forgery of one, and the
    -- forgery is the thing a hostile client produces on purpose.
    local rows, shown, notRun, failed = {}, 0, 0, 0
    for _, r in ipairs(payload) do
        -- Stop at the bound, and count how many were dropped so the summary can
        -- say so rather than the reader assuming it is the whole thing.
        if shown >= MAX_CLIENT_RESULTS then
            notRun = notRun + 1
        elseif type(r) == 'table' and type(r.name) == 'string' then
            shown = shown + 1
            if r.skipped == true then
                notRun = notRun + 1
            elseif r.ok ~= true then
                failed = failed + 1
            end
            rows[#rows + 1] = r
        end
    end

    if shown == 0 then
        return
    end

    local who = GetPlayerName(src) or ('id %d'):format(src)
    print('')
    print(('cis_bridge: client results from %s'):format(tostring(who)))
    for _, r in ipairs(rows) do
        local label = r.name:sub(1, 46)
        local detail = type(r.detail) == 'string' and r.detail:sub(1, 120) or nil
        if r.skipped == true then
            print(('  [client] %-46s %s%s'):format(
                'client', label, 'SKIP', detail and (' -- ' .. detail) or ''))
        else
            print(('  [client] %-46s %s%s'):format(
                'client', label,
                r.ok == true and 'PASS' or 'FAIL',
                (r.ok ~= true and detail) and (' -- ' .. detail) or ''))
        end
    end
    print(('cis_bridge: client %s reported %d failure(s) across %d check(s), %d skipped')
        :format(tostring(who), failed, shown, notRun))
end)

-- Console only, and it says why rather than failing silently.
--
-- There is no framework permission check here, and there used to be one:
-- `exports['cis_libs']:GetFramework()` followed by `fw.HasPermission(src,
-- 'admin')`. That names cis_core's framework export from a resource whose entire
-- reason to exist is not to, it reads a deprecated export that cis_libs
-- documents as removed in 3.0.0, and it cannot work: cis_libs' own `cis_debug`
-- command has the identical check and the identical bug, documented at length
-- in server/initialize.lua -- `fw.HasPermission` was nil on every server whose
-- framework came from another resource, the `and` chain short-circuited to a
-- refusal, and the command was silently dead in game on every server. So an
-- operator with admin rights was told nothing at all.
--
-- FiveM's own `restricted` flag is the control that actually works, and it is
-- what the argument below sets. cis_libs never runs `add_ace` for the owner --
-- it prints the line and lets them decide -- and so does this, because an SDK
-- that grants itself console access to a customer's server is not an SDK.
RegisterCommand('cis_bridge', function(src, args)
    if src ~= 0 then
        print('cis_bridge: this is a server console command. Run it from the txAdmin '
            .. 'console or the server terminal.')
        print('  To allow it in game for your admins instead, add this to server.cfg:')
        print('    add_ace group.admin command.cis_bridge allow')
        return
    end
    local first = args and args[1]
    -- `report` and `test` are different questions and were not separable before
    -- because there was only one of them. `report` says what is wired up;
    -- `test` says whether it works. A support thread usually wants the first and
    -- an operator debugging an integration wants the second, and being handed
    -- the wrong one costs a round trip either way.
    if first == 'report' then
        if Report and Report.render then
            Report.render()
        else
            print('cis_bridge: the report module is not loaded')
        end
        return
    end
    Conformance.run(first)
end, true)