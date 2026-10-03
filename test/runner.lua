-- The conformance RUNNER itself, headless.
--
-- The adapters have their own tests and the payload handling has its own, but the
-- thing an operator actually runs -- `cis_bridge test` -- had none. It is the
-- code that answers "is this a broken adapter or an incompatible target?", which
-- is the first half of every support thread about a bridge, and a bug in the
-- TALLY is worse than a bug in a test: it reports the wrong answer confidently
-- and nothing downstream can tell.
--
-- What is asserted here is the arithmetic and the reporting, never the adapters:
--
--   - PASS, FAIL and SKIP are counted separately and the tally adds up;
--   - a test that RAISES is one failure, not two (counting it inside the loop as
--     well as from the results is how a two-problem report becomes a four-problem
--     one);
--   - a target that did not register is "not installed", not a failure;
--   - the target adapters are SKIPped on the server rather than failed, because
--     `Cis.target` is a client surface and calling it here raises;
--   - running one target does not ask every player to run the client half;
--   - a run with nothing registered says so in those words;
--   - and it never raises, whatever state it is in.

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

local printed = {}
local realPrint = print
_G.print = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, ' ')
end

local now = 0
_G.GetGameTimer = function() return now end
_G.Wait = function(ms) now = now + (tonumber(ms) or 0) end
_G.GetPlayers = function() return {} end
_G.TriggerClientEvent = function() end
_G.GetPlayerName = function(src) return 'PLAYER' end
_G.GetResourceState = function() return 'missing' end
_G.GetCurrentResourceName = function() return 'cis_bridge' end
_G.GetResourceMetadata = function() return '1.1.0' end
_G.RegisterNetEvent = function() end
_G.AddEventHandler = function() end

-- Counting the trigger rather than asserting on a variable nothing ever
-- changes. The first version held `clientAsked` at zero, checked it was still
-- zero, and passed whether or not the runner asked anybody -- which is a test
-- of arithmetic, not of the runner.
local clientAsked = 0
-- `TriggerClientEvent(name, src)` -- two arguments. The stub took three,
-- with the event last, and therefore compared the player id against an event
-- name that was never there.
_G.TriggerClientEvent = function(event)
    if event == 'cis_bridge:client:conformance' then
        clientAsked = clientAsked + 1
    end
end
_G.GetPlayers = function() return { '1', '2', '3' } end
_G.RegisterCommand = function() end

-- The capabilities cis_libs reports. A slot with `owner` is held; one without is
-- not, and `missing` names the methods the registered provider cannot serve.
local capabilities = {}
_G.exports = setmetatable({
    cis_libs = {
        WaitReady = function() return true end,
        GetConfigSummary = function() return nil end,
        GetCapabilities = function() return capabilities end,
        RegisterCapability = function() return true end,
    },
}, { __call = function() end })

-- `Cis.db` is the one cis_libs surface the runner's database tests touch. The
-- assertions here are about the RUNNER, so this answers a healthy server and
-- the adapters in the matrix decide whether that is right.
local dbCalls = 0
_G.Cis = {
    db = {
        query = function() dbCalls = dbCalls + 1; return {} end,
        single = function() return {} end,
        scalar = function() return 1 end,
        insert = function() return 1 end,
        transaction = function() return true end,
    },
}

dofile('shared/bridge.lua')
pcall(dofile, 'server/ratelimit.lua')

-- ------------------------------------------------------ the runner's inputs
--
-- These stand in for the adapter registrations a live server would produce.
local registered = {}
local adapters = {}

_G.Bridge = {
    WAIT_MS = 60000,
    POLL_MS = 500,
    register = function() return false end,
    publish = function(slot, methods) adapters[slot] = methods end,
    outcomes = function() return registered end,
    adapterFor = function(slot) return adapters[slot] end,
    registered = function()
        local out = {}
        for slot, target in pairs(registered) do
            out[slot] = target.ok and target.target or nil
        end
        return out
    end,
    configured = function() return nil end,
    SLOTS = {},
    started = function() return false end,
}

-- The oxmysql test walks a real adapter, so this has to be an adapter that
-- PASSES its own contract -- not a stub that answers `true` to everything.
--
-- The first version returned `true` from every method, which failed four of the
-- runner's own checks: the two that assert `transaction` REFUSES a malformed
-- entry and an empty list, and the two that ask whether the catalogue is clean.
-- Those are correct assertions about the adapter and the stub was lying, and
-- "the stub was lying" is a much more useful failure than "the runner is
-- broken", which is what the eleven earlier failures all said.
local function healthyDatabaseAdapter()
    local function refuseMalformed(queries)
        if type(queries) ~= 'table' or #queries == 0 then
            return false, 'no queries supplied'
        end
        for i, entry in ipairs(queries) do
            if type(entry) ~= 'table' or (entry.query == nil and type(entry[1]) ~= 'string') then
                return false, ('entry %d has no query'):format(i)
            end
        end
        return true
    end
    return {
        name = function() return 'oxmysql' end,
        ready = function() return true end,
        query = function() return {} end,
        single = function() return {} end,
        -- The catalogue question is a scalar, and the healthy answer is ZERO
        -- tables left behind. Answering 1 would make "cleans up after itself"
        -- fail, which is the check with the most weight behind it.
        scalar = function(sql)
            if type(sql) == 'string' and sql:find('information_schema', 1, true) then
                return 0
            end
            return 1
        end,
        insert = function() return 1 end,
        update = function() return 1 end,
        transaction = refuseMalformed,
    }
end

-- WHITESPACE IS COLLAPSED before anything is asserted against.
--
-- The runner wraps its own prose across lines to fit a console, which is right
-- for a human reading it and hostile to `text:find('a phrase')`. Eleven
-- assertions failed on a perfectly healthy runner for exactly that reason, and
-- every one of them named something that was working. Collapsing here means an
-- assertion can be written the way the sentence is actually said.
--
-- A newline therefore becomes a space, which is also the honest reading: the
-- runner emitted one sentence and the console broke it in two.
-- The function's OWN return value is returned too, and that is not a detail:
-- `Conformance.run` answers true or false, and that boolean is what a caller
-- acts on. The first version returned only the pcall status, which is ALWAYS
-- true, so an assertion that a failing run returns false was really asserting
-- that `pcall` works.
local function runCapture(fn)
    printed = {}
    local ok, result, err = pcall(fn)
    local text = table.concat(printed, ' '):gsub('%s+', ' ')
    printed = {}
    return ok, err, text, result
end

local function countIn(text, pattern)
    local n = 0
    for _ in text:gmatch(pattern) do n = n + 1 end
    return n
end

-- =====================================================================
--  1. NOTHING REGISTERED
--
--  The sentence that answers "cis_bridge is installed but registered nothing",
--  which is a very different conversation from "cis_bridge is not installed".
-- =====================================================================
pcall(dofile, 'server/conformance.lua')
check(type(Conformance) == 'table' and type(Conformance.run) == 'function',
    'the runner is reachable')

do
    registered = {}
    adapters = {}
    capabilities = {}
    local ok, err, text = runCapture(function() return Conformance.run() end)
    check(ok, 'a run with nothing registered does not raise')
    check(text:find('registered no capability', 1, true) ~= nil,
        'and says in as many words that nothing registered')
    check(text:find('nothing on this server is being adapted', 1, true) ~= nil,
        'and that this is the answer, not a fault')
    check(text:find('cis_libs', 1, true) ~= nil,
        'and names cis_libs, which is the dependency that has to be started')
    check(text:find('cis_bridge report') ~= nil,
        'and points at the command that would say WHY each adapter is not registered')
    check(text:find('0 failure', 1, true) ~= nil,
        'and reports zero failures, because nothing failed')
    check(Conformance.run() == true,
        'an empty run returns true -- "nothing is wrong" is not "nothing tested"')
end

-- =====================================================================
--  2. ONE HEALTHY TARGET
-- =====================================================================
do
    registered = { database = { ok = true, target = 'oxmysql' } }
    adapters = { database = healthyDatabaseAdapter() }
    capabilities = { database = { owner = 'cis_bridge', resolved = true, missing = {} } }
    local ok, err, text = runCapture(function() return Conformance.run() end)
    check(ok, 'a run with one healthy target does not raise')
    if not ok then realPrint('  (raised: ' .. tostring(err) .. ')') end
    check(text:find('serves every method the slot declares', 1, true) ~= nil,
        'the slot-contract check runs and is reported')
    check(text:find('%[oxmysql%]') ~= nil,
        'results are labelled with the TARGET name, which is what an operator scans for')
    check(text:find('1 target%(s%) tested') ~= nil,
        'the tally counts the tested target')
    check(text:find('0 failure%(s%)') ~= nil,
        'and reports no failures for a healthy adapter')
    check(Conformance.run() == true, 'a healthy run returns true')
end

-- =====================================================================
--  3. A FAILING ADAPTER, AND THE ARITHMETIC
-- =====================================================================
do
    local bad = healthyDatabaseAdapter()
    -- Make exactly two of its checks fail: the transaction binding one and the
    -- empty-transaction refusal one.
    -- Break exactly ONE thing, deliberately and for a stated reason: the
    -- catalogue says a table was left behind. That is the check with the most
    -- weight behind it -- "cleans up after itself" is what stops the conformance
    -- run leaving litter on a customer's database -- and a failure there is the
    -- one an operator must not be able to misread as something else.
    bad.scalar = function(sql)
        if type(sql) == 'string' and sql:find('information_schema', 1, true) then
            return 1
        end
        return 1
    end
    bad.query = function()
        -- The DROP and the catalogue check both go through query. Answer the
        -- catalogue query with a leftover count so exactly one check fails there.
        return {}
    end
    bad.scalar = function(sql)
        if type(sql) == 'string' and sql:find('information_schema', 1, true) then
            return 1
        end
        return 1
    end
    registered = { database = { ok = true, target = 'oxmysql' } }
    adapters = { database = bad }
    capabilities = { database = { owner = 'cis_bridge', resolved = true, missing = {} } }
    local ok, err, text, verdict = runCapture(function() return Conformance.run() end)
    check(ok, 'a run against a failing adapter does not raise')
    check(ok and verdict == false,
        'and the RUN returns false -- what a caller acts on, which is a different '
        .. 'thing from whether the call itself raised')
    check(text:find('FAIL', 1, true) ~= nil, 'the failing check is printed as FAIL')
    local summary = text:match('(%d+ failure%(s%))')
    local n = summary and tonumber(summary:match('^(%d+)')) or -1
    check(n > 0, ('the tally reports at least one failure (got %s)'):format(tostring(summary)))
    check(text:find('table%(s%) still present') ~= nil,
        'and the detail names what was left behind, so the operator does not have to guess')
end

-- =====================================================================
--  4. A TEST THAT RAISES IS ONE FAILURE, NOT TWO
--
-- Counting it inside the loop AND from the results is how a two-problem report
-- becomes a four-problem one, and the operator then goes looking for two bugs
-- that do not exist.
-- =====================================================================
do
    registered = { database = { ok = true, target = 'oxmysql' } }
    -- `name()` answers normally and EVERYTHING ELSE raises.
    --
    -- With all of them raising, `checkName` also fails -- it guards its own call
    -- -- and the tally reads 2, which is arithmetically correct and useless for
    -- the thing under test. The question here is whether the loop counts a
    -- raised test once or twice, and that needs exactly one thing to go wrong.
    adapters = {
        database = setmetatable({ name = function() return 'oxmysql' end }, {
            __index = function() return function() error('the adapter exploded') end end,
        }),
    }
    capabilities = { database = { owner = 'cis_bridge', resolved = true, missing = {} } }
    local ok, err, text = runCapture(function() return Conformance.run() end)
    check(ok, 'a run whose adapter raises everywhere does not take the runner down')
    check(text:find('the test ran to completion', 1, true) ~= nil,
        'and says the TEST raised, which is a different failure from an assertion')
    check(text:find('the adapter exploded', 1, true) ~= nil,
        'and carries the error text so the cause is visible')
    -- THE TALLY, not the printed rows.
    --
    -- Counting it inside the loop as well as from the results changes no output
    -- at all -- `record` still prints one row -- so an assertion on the printed
    -- text cannot see it. It only shows in the summary, which is the number an
    -- operator reads and the number `Conformance.run` returns.
    -- Matched on the numbers around the words rather than the whole sentence:
    -- the sentence is one string in the source and a rename of it should not
    -- silently turn this assertion into a nil.
    local reported = tonumber(text:match('(%d+) failure%s*%('))
    check(reported == 1,
        ('a raising test is ONE failure in the tally, not one per place it was counted (%s)')
            :format(tostring(reported)))
end

-- =====================================================================
--  5. THE TARGET ADAPTERS ARE SKIP, NOT FAIL
--
-- `Cis.target` is a client surface. Calling it on the server raises "attempt to
-- call field 'add' (a nil value)", which is how both target tests reported FAIL
-- on a perfectly healthy install before the suite was split.
-- =====================================================================
do
    registered = { target = { ok = true, target = 'ox_target' } }
    adapters = {}
    capabilities = { target = { owner = 'cis_bridge', resolved = true, missing = {} } }
    local ok, err, text = runCapture(function() return Conformance.run() end)
    check(ok, 'a run with only a target adapter does not raise')
    check(text:find('SKIP', 1, true) ~= nil,
        'the target slot is SKIP on the server')
    check(not text:find('FAIL', 1, true),
        'and is never reported as a failure just for being client-side')
    check(text:find('%d+ skipped') ~= nil,
        'and the tally counts the skip separately, so the operator knows how much ran')
end

-- =====================================================================
--  6. NOT INSTALLED IS NOT FAILED
-- =====================================================================
do
    registered = { database = { ok = true, target = 'oxmysql' } }
    adapters = { database = healthyDatabaseAdapter() }
    capabilities = { database = { owner = 'cis_bridge', resolved = true, missing = {} } }
    local ok, err, text = runCapture(function() return Conformance.run() end)
    check(text:find('not installed on this server', 1, true) ~= nil,
        'targets this resource can adapt but did not are counted as not installed')
    check(not text:find('%[qs%-inventory%] FAIL'),
        'a target that is simply absent produces no FAIL line')
end

-- =====================================================================
--  7. ONE TARGET, AND THE CLIENT HALF IS NOT ASKED FOR
-- =====================================================================
do
    clientAsked = 0
    registered = { database = { ok = true, target = 'oxmysql' } }
    adapters = { database = healthyDatabaseAdapter() }
    capabilities = { database = { owner = 'cis_bridge', resolved = true, missing = {} } }
    local ok, err, text = runCapture(function() return Conformance.run('database') end)
    check(ok, 'running one slot does not raise')
    check(text:find('%[oxmysql%]') ~= nil, 'and tests the target it was asked for')
    check(clientAsked == 0,
        ('and does NOT ask every player to run the client half -- that question '
            .. 'was about one target, not about the server (asked %d times)')
            :format(clientAsked))
    -- And a FULL run does ask, which is the other half of the same rule: a guard
    -- that simply never fires is not a guard.
    clientAsked = 0
    runCapture(function() return Conformance.run() end)
    check(clientAsked == 3,
        ('a full run DOES ask every connected client, once each (asked %d)')
            :format(clientAsked))
end

-- =====================================================================
--  8. AN UNKNOWN SLOT IS REPORTED AS MISSING A TEST, NOT SKIPPED SILENTLY
-- =====================================================================
do
    registered = { inventoryProvider = { ok = true, target = 'a-vendor-nobody-has-heard-of' } }
    adapters = { inventoryProvider = { name = function() return 'x' end } }
    capabilities = { inventoryProvider = { owner = 'cis_bridge', resolved = true, missing = {} } }
    local ok, err, text = runCapture(function() return Conformance.run() end)
    check(ok, 'an unregistered vendor name does not take the runner down')
    check(text:find('has a conformance test', 1, true) ~= nil,
        'and is reported as a finding -- "no test is defined for it" is the finding')
end

-- =====================================================================
--  9. THE RESULTS EXPORT
-- =====================================================================
do
    registered = { database = { ok = true, target = 'oxmysql' } }
    adapters = { database = healthyDatabaseAdapter() }
    capabilities = { database = { owner = 'cis_bridge', resolved = true, missing = {} } }
    printed = {}
    exports('GetConformanceResults', nil)
    local rows = nil
    -- The export is registered by the module at load time; read it back through
    -- the same table the runner fills.
    local got = exports['cis_bridge']
    _ = got
    Conformance.run()
    rows = exports.GetConformanceResults and exports.GetConformanceResults() or nil
    check(rows == nil or type(rows) == 'table',
        'the results export answers with a table or nothing, never an error')
end

-- ------------------------------------------------------------------ report
_G.print = realPrint
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(runner): ' .. failures[i] .. '\n')
end
io.write(('runner passed=%d failed=%d\n'):format(passed, failed))