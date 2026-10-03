-- Adversarial payloads against the one surface a player can reach.
--
-- There is exactly one net event handler in this resource that a connected
-- player may fire, and the security checklist says to treat it as if a cheat
-- menu were firing it as fast as it liked with any payload it liked. That is
-- what this file does -- not a sample of payloads, but the categories that have
-- actually broken things:
--
--   - a type that is not a table at all
--   - an enormous table (10,000 rows, and a row that is itself enormous)
--   - deep nesting, which is a stack-overflow primitive rather than a memory one
--   - rows whose shape is wrong: no `name`, a non-string `name`, a boolean
--   - strings carrying terminal escape sequences, so the console is rewritten
--   - strings carrying format specifiers, so a later `:format` misbehaves
--   - a flood, which is the one that matters: the handler PRINTS
--
-- And the assertion is not "it did not raise". A handler that raises is a
-- finding, but a handler that quietly prints a megabyte of attacker-chosen text
-- into an operator's console is a worse one, so the checks here are on what
-- REACHED the output.

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

local now = 0
local clock = function() return now end
local printed = {}
local realPrint = print

_G.GetGameTimer = clock
-- `Wait` ADVANCES the clock. It has to: the client suite's entity probe is
--
--     while not HasModelLoaded(hash) and GetGameTimer() < timeout do
--         RequestModel(hash); Wait(0)
--     end
--
-- and a `Wait` that does nothing leaves `GetGameTimer()` constant, so the
-- comparison never becomes false and the loop is infinite. The first version of
-- this stub did exactly that, and the suite spent its time in a VM spin rather
-- than reporting anything. A stub that hangs is worse than a missing stub: it
-- looks like a slow test.
-- A real frame advances the clock even when it waits zero milliseconds, which
-- is the whole contract of `GetGameTimer`: it is UPTIME. A stub that adds
-- exactly the requested amount makes `Wait(0)` a no-op, and the client suite's
-- model probe --
--
--     while not HasModelLoaded(hash) and GetGameTimer() < timeout do
--         RequestModel(hash); Wait(0)
--     end
--
-- never terminates. Advancing by at least one millisecond per call is what a
-- frame actually does, and it is the difference between a suite that runs and
-- a suite that spins.
_G.Wait = function(ms)
    now = now + math.max(tonumber(ms) or 0, 1)
end
_G.GetPlayerName = function(src) return 'PLAYER_' .. tostring(src) end
_G.GetPlayers = function() return {} end
_G.TriggerClientEvent = function() end
_G.GetResourceState = function() return 'missing' end
_G.GetCurrentResourceName = function() return 'cis_bridge' end
_G.GetResourceMetadata = function() return '1.1.0' end

-- `print` is RECORDED, not suppressed. The handler's whole job is to print, so
-- a suite that cannot see what it printed proves nothing about the only thing
-- that matters. The real one is restored before this file's own report.
_G.print = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    printed[#printed + 1] = table.concat(parts, ' ')
end

local registeredEvents = {}
local registeredCommands = {}
_G.RegisterNetEvent = function(name, fn)
    registeredEvents[name] = registeredEvents[name] or {}
    table.insert(registeredEvents[name], fn)
end
_G.AddEventHandler = function() end
_G.RegisterCommand = function(name, fn, restricted)
    registeredCommands[name] = { handler = fn, restricted = restricted }
end
_G.exports = setmetatable({
    cis_libs = {
        WaitReady = function() return true end,
        GetConfigSummary = function() return nil end,
        GetCapabilities = function() return {} end,
        RegisterCapability = function() return true end,
    },
}, {
    __call = function() end,
})

-- The registration helper, as a no-op that records. `server/conformance.lua`
-- reads `Bridge.publish`, `Bridge.outcomes` and `Bridge.adapterFor`, and
-- `Bridge.registered` for the runner -- none of which matter to the handler
-- under test, so a stub that answers empty is enough and keeps this suite from
-- depending on the registration logic.
local outcomes = {}
local adapters = {}
_G.Bridge = {
    register = function() return false end,
    publish = function(slot, methods) adapters[slot] = methods end,
    outcomes = function() return outcomes end,
    adapterFor = function(slot) return adapters[slot] end,
    registered = function() return {} end,
    configured = function() return nil end,
    SLOTS = {},
    WAIT_MS = 60000,
    POLL_MS = 500,
    started = function() return false end,
}

dofile('shared/bridge.lua')
pcall(dofile, 'server/ratelimit.lua')

-- ====================================================== load the handler

local loaded, loadErr = pcall(dofile, 'server/conformance.lua')
check(loaded, 'server/conformance.lua loads against a stub engine'
    .. (loaded and '' or (': ' .. tostring(loadErr))))

local handlers = registeredEvents['cis_bridge:server:conformanceResults']
check(type(handlers) == 'table' and #handlers >= 1,
    'it registers a handler for cis_bridge:server:conformanceResults')

local fire = handlers and handlers[1]
if type(fire) ~= 'function' then
    fire = function() end
    check(false, 'no handler to test; the rest of this file would be vacuous')
end

-- `source` is FiveM's global and the handler reads it. Setting it is the only
-- way to drive the handler, and it is also the exact capability a cheat menu
-- has -- which is why the cases below treat `source` as an ATTACKER CHOICE and
-- check that a chosen value of 0 buys nothing.
local function fireAs(src, payload)
    _G.source = src
    local ok, err = pcall(fire, payload)
    return ok, err
end

local function outputSince(mark)
    local n = #printed - mark
    return n, table.concat(printed, '\n', mark + 1, #printed)
end

-- ============================================== 1. NOT A TABLE
--
-- The cheapest thing a player can send and the one most often handled by
-- trusting. Each must be refused without printing and without raising.
for _, case in ipairs({
    { 'nil', nil },
    { 'a string', 'cis_bridge: please' },
    { 'a number', 42 },
    { 'a boolean', true },
    { 'a function', function() return 1 end },
    { 'a zero-length string', '' },
}) do
    local mark = #printed
    local ok, err = fireAs(7, case[2])
    check(ok, ('a payload that is %s does not raise'):format(case[1]))
    check(ok and select(1, outputSince(mark)) == 0,
        ('and prints nothing for a payload that is %s'):format(case[1]))
    if not ok then
        realPrint('  (raised: ' .. tostring(err) .. ')')
    end
end

-- ============================================== 2. src == 0 BUYS NOTHING
--
-- `source` is the identity the engine supplies, and a client cannot set it to
-- 0 -- but a handler that skips its checks on 0 is a handler whose checks are
-- only as good as the assumption that nobody can reach them.
do
    local mark = #printed
    fireAs(0, { { name = 'forged', ok = true } })
    check(select(1, outputSince(mark)) == 0,
        'a payload claiming source 0 prints nothing')
end

-- ============================================== 3. MALFORMED ROWS
--
-- A row is expected to be a table with a string `name`. Every other shape must
-- be skipped rather than printed, and skipped rows must not consume the row
-- budget -- otherwise 10,000 junk rows displace the one real result.
local mark = #printed
fireAs(8, {
    'not a table',
    42,
    true,
    {},
    { ok = true },
    { name = 42, ok = true },
    { name = {}, ok = true },
    { name = 'a real row', ok = true, detail = 'fine' },
})
local rows, text = outputSince(mark)
check(rows > 0, 'a well-formed row is still reported')
check(text:find('a real row', 1, true) ~= nil, 'and it is the one that appears')
check(text:find('forged', 1, true) == nil, 'nothing invented is printed')

-- ============================================== 4. AN ENORMOUS TABLE
--
-- 10,000 rows. The handler must print at most MAX_CLIENT_RESULTS and must say
-- so rather than truncating silently -- a silent truncation reads as "that is
-- all of them", which is a lie about the state of the platform.
local big = {}
for i = 1, 10000 do
    big[i] = { name = ('row %d'):format(i), ok = true }
end
mark = #printed
local okBig, errBig = fireAs(9, big)
check(okBig, 'a ten-thousand-row payload does not raise')
if not okBig then realPrint('  (raised: ' .. tostring(errBig) .. ')') end
rows, text = outputSince(mark)
-- One line per printed row, plus a blank, the header and the summary.
check(rows <= 70, ('printing is bounded at 70 lines for a ten-thousand-row payload (got %d)')
    :format(rows))
check(text:find('row 1,') ~= nil or text:find('row 1') ~= nil,
    'and it starts at the first row rather than the last')

-- One enormous row. A single row carrying a megabyte of text must be truncated
-- to the same length as any other.
local huge = { { name = string.rep('A', 1000000), ok = true, detail = string.rep('B', 1000000) } }
mark = #printed
local okHuge = fireAs(10, huge)
check(okHuge, 'a row carrying a megabyte of text does not raise')
rows, text = outputSince(mark)
check(#text < 5000, ('that row is truncated before printing (output was %d bytes)'):format(#text))

-- ============================================== 5. DEEP NESTING
--
-- A deeply nested table is a stack-overflow primitive in a serialiser, and the
-- engine's own deserialisation is not this handler's problem -- but a handler
-- that WALKS a client table has to survive being handed one. Ten thousand
-- levels is far past what any renderer can display and far past what a
-- `table.concat` can walk.
local deep = {}
local node = deep
for _ = 1, 10000 do
    node.next = {}
    node = node.next
end
mark = #printed
local okDeep, errDeep = fireAs(11, deep)
check(okDeep, 'a ten-thousand-deep nested payload does not raise')
if not okDeep then realPrint('  (raised: ' .. tostring(errDeep) .. ')') end
check(select(1, outputSince(mark)) == 0,
    'and prints nothing, because no row in it has a name')

-- ============================================== 6. STRINGS THAT ATTACK THE CONSOLE
--
-- The output of this handler goes to an operator. A row that carries terminal
-- escape sequences can rewrite the console above the line the operator is
-- reading, and a very long `detail` is the same attack in one dimension.
local ESC = string.char(27)
mark = #printed
fireAs(12, {
    {
        name = 'evil',
        ok = false,
        detail = ESC .. '[2J' .. ESC .. '[H' .. string.rep('x', 5000),
    },
})
rows, text = outputSince(mark)
check(#text < 5000, ('an escape-sequence payload is truncated (%d bytes of output)'):format(#text))

-- A format specifier. The handler builds lines with `:format`, and a row
-- carrying `%s` in a field that is NOT passed to format is harmless -- but if
-- any future edit passes a row's text into `:format`, this is the payload that
-- turns it into an argument error. It is asserted here so that edit fails a
-- test rather than a customer's console.
mark = #printed
local okFmt = fireAs(13, {
    { name = '%s%d%s%s%s%s', ok = false, detail = '%s %s %s' },
})
check(okFmt, 'a row carrying format specifiers does not raise')
rows = select(1, outputSince(mark))
check(rows > 0, 'and is still reported, truncated rather than dropped')

-- ============================================== 7. THE FLOOD
--
-- The one that is not about payload SHAPE. A cheat menu can fire this event
-- thousands of times a second, and each accepted call prints. So: one accepted
-- call, then refusals, and the refusal count is what tells an operator somebody
-- was talking to a handler they should not have been able to reach.
now = 100000
mark = #printed
for _ = 1, 5000 do
    fireAs(14, { { name = 'flood', ok = true } })
end
rows = select(1, outputSince(mark))
check(rows > 0 and rows < 20,
    ('five thousand calls in one instant produce one report, not five thousand (got %d lines)')
        :format(rows))

-- A DIFFERENT source is unaffected. A global guard would let one player lock
-- every other player out of the report.
mark = #printed
fireAs(15, { { name = 'someone else', ok = true } })
check(select(1, outputSince(mark)) > 0, 'another player is not locked out by the first one')

-- And the window expires.
now = 100000 + 6000
mark = #printed
fireAs(14, { { name = 'after the window', ok = true } })
check(select(1, outputSince(mark)) > 0, 'the same player may report again once the window closes')

-- ============================================== 8. THE COMMAND
--
-- `cis_bridge` is the one restricted command. It is refused for any player, and
-- the refusal prints the add_ace line rather than granting access to somebody's
-- server -- an SDK that installs its own console access is not an SDK.
local cmd = registeredCommands['cis_bridge']
check(type(cmd) == 'table' and type(cmd.handler) == 'function', 'the cis_bridge command exists')
check(cmd and cmd.restricted == true, 'and is registered as restricted')
if cmd then
    mark = #printed
    cmd.handler(0, {})            -- console: the allowed path
    cmd.handler(3, {})            -- a player: must be refused
    local _, out = outputSince(mark)
    check(out:find('server console command', 1, true) ~= nil,
        'a player is told it is a console command')
    check(out:find('add_ace', 1, true) ~= nil,
        'and is shown the add_ace line rather than simply refused')
end

-- The client-side command is deliberately NOT restricted -- a developer testing
-- a target adapter should not have to be a server admin -- so its allocation is
-- bounded by a cooldown instead. It lives in the CLIENT file, so the client
-- file is loaded here too; checking for it without loading the file would be an
-- assertion that passes by never finding the command, which is the first version
-- of this line and is a test that cannot fail.
-- Enough of a client for the suite to actually RUN, which the first version of
-- this did not and the result was a test that could not fail.
--
-- With no target provider the client half printed "skipping client conformance"
-- four times and the cooldown assertion counted a string it never saw, so it
-- passed whether or not the cooldown existed. A guard assertion against code
-- that never reaches its subject is not a weak assertion; it is an absent one.
_G.Cis = {
    target = {
        add = function() return true end,
        exists = function() return false end,
        remove = function() return true end,
    },
}
-- FiveM builds a vector3 with `vector3()`, not with a table constructor, and the
-- client suite calls both. Stubbing only `vec3` left `vector3` nil, so the first
-- run of the client command raised inside its own zone creation -- a failure in
-- the TEST, and worth surfacing rather than swallowing, because a stub that is
-- missing is invisible until it is the thing being measured.
_G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
_G.vector3 = _G.vec3
-- cis_libs reports a target provider, so `run()` proceeds past its skip.
_G.exports.cis_libs.GetCapabilities = function()
    return { target = { owner = 'cis_bridge', resolved = true, missing = {} } }
end
-- The adapter the client suite publishes, so its identity checks are exercised.
adapters['target'] = {
    name = function() return 'ox_target' end,
    available = function() return true end,
    create = function() return true end,
    remove = function() return true end,
    exists = function() return false end,
}
-- The entity probe. Returning false from the model request short-circuits the
-- client suite's one spawn, so the check that matters -- how OFTEN the command
-- may be run -- is not entangled with whether a ped could be created in a VM
-- with no game.
_G.GetHashKey = function() return 0 end
_G.HasModelLoaded = function() return false end
_G.RequestModel = function() end
_G.CreatePed = function() return 0 end
_G.DoesEntityExist = function() return false end
_G.DeleteEntity = function() end
_G.SetModelAsNoLongerNeeded = function() end
_G.SetEntityAsMissionEntity = function() end

local clientLoaded, clientErr = pcall(dofile, 'client/conformance.lua')
check(clientLoaded, 'client/conformance.lua loads against a stub engine'
    .. (clientLoaded and '' or (': ' .. tostring(clientErr))))

local clientCmd = registeredCommands['cis_bridge_client']
check(type(clientCmd) == 'table', 'the client command is registered')
check(clientCmd and clientCmd.restricted == false,
    'and is deliberately NOT restricted, so a developer can run it')
if clientCmd and type(clientCmd.handler) == 'function' then
    -- The command creates and removes a target and spawns a ped on every run,
    -- so an unthrottled one is a client-side allocation loop any player can
    -- start. Firing it four times must produce one report.
    mark = #printed
    for attempt = 1, 4 do
        local okc, errc = pcall(clientCmd.handler)
        check(okc, 'the client command does not raise')
        if not okc then
            realPrint('  (run ' .. attempt .. ' raised: ' .. tostring(errc) .. ')')
        end
    end
    _, clientText = outputSince(mark)
    local reports = 0
    -- The exact header the client half prints. Keyed on the full string rather
    -- than a distinctive fragment, so a rename shows up as a failure rather than
    -- as a silently-zero count -- which is the failure this whole block was
    -- written to fix.
    for _ in clientText:gmatch('cis_bridge client conformance %-%-') do
        reports = reports + 1
    end
    check(reports >= 1,
        'and the client actually ran at least once, so the count below means something')
    check(reports <= 1,
        ('four runs of the client command produce at most one report (got %d)'):format(reports))
end

-- ------------------------------------------------------------------ report
_G.print = realPrint
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(handler): ' .. failures[i] .. '\n')
end
io.write(('handler passed=%d failed=%d\n'):format(passed, failed))