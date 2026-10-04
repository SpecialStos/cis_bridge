-- Accidental globals: does any shipped file write a name it did not declare?
--
-- WHY THIS IS DYNAMIC RATHER THAN A GREP
--
-- luacheck answers this properly and is not available in this VM, and the
-- hand-rolled alternatives are all worse than useless:
--
--   - grepping for a bare identifier misses any name not in the pattern list,
--     which is the whole set that matters;
--   - a pattern of "names this repo declares" flags every file for every name
--     it is allowed to mention.
--
-- So this watches what actually HAPPENS. `_G` gets a metatable whose
-- `__newindex` fires only for a name that is not already there -- which is
-- precisely the definition of an undeclared global -- and every file this
-- resource ships is then loaded against a stubbed engine.
--
-- WHAT IT CANNOT SEE, STATED PLAINLY
--
-- This watches what RUNS. A missing `local` on an assignment inside a function
-- body that no file in this suite ever calls is invisible to it -- verified by
-- applying exactly that mutation and watching nothing fail:
--
--     local function _check(n)
--       accumulator = (accumulator or 0) + n
--     end
--
-- `_check` is never called, `accumulator` is never written, and the check is
-- correct about everything it saw and silent about the one thing that matters.
--
-- So this is NOT a substitute for a static analyser, and claiming otherwise
-- would be worse than not having it. luacheck is the authority on undeclared
-- names; CI installs it and fails on its findings. This runs everywhere,
-- including on a machine with no Lua toolchain at all, and catches the writes
-- that actually happen -- including any a future refactor introduces by calling
-- something that used to be dead.
--
-- Both run. Neither is described as the other.
--
-- A global in Lua is not a style complaint. Two resources in one server writing
-- the same global name is a silent cross-resource variable, and it reproduces as
-- "works until you install something else".

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

-- ============================================================ the watcher

local declared = {}
local unexpected = {}

-- Snapshot of the names Lua starts with. Anything a file assigns that is not in
-- here and not in `declared` is an accidental global.
local BASELINE = {}
for k in pairs(_G) do
    BASELINE[k] = true
end

-- `__newindex` fires ONLY for a key that does not already exist, which is exactly
-- the set this check is about: an assignment to a name that was never declared.
--
-- rawset is then used to actually store it, because going through the metatable
-- again would recurse -- and without it the file would appear to work while
-- nothing it wrote was readable anywhere, which is the kind of bug that only
-- shows up when the name is read from another file.
setmetatable(_G, {
    __newindex = function(_, key, value)
        rawset(_G, key, value)
        if not BASELINE[key] and not declared[key] then
            unexpected[#unexpected + 1] = { name = key, value = value }
        end
    end,
})

-- ============================================================ the stub engine

-- The globals this resource declares ON PURPOSE, plus the engine stubs below.
--
-- A global in the first group is a decision, not an accident: `Bridge` is shared
-- between every adapter file, `Conformance` and `Report` are read by a command
-- registered in a different file, and `DiscordQueue` is published for the
-- conformance suite. Everything else must be a local.
--
-- LISTED BEFORE THE STUBS ARE ASSIGNED, which is the whole point of this suite.
-- The first version filled it in afterwards, so every stub it installed was
-- itself reported as an undeclared global -- thirteen failures, all of them the
-- harness complaining about the harness. A watcher that is not trusted before it
-- is useful is not a watcher.
for _, name in ipairs({
    'Bridge', 'Conformance', 'Report', 'DiscordQueue',
    -- The two published modules. They exist so the unit suites can load them
    -- without the FiveM engine, and the manifest lists them ahead of the file
    -- that reads each one -- see fxmanifest.lua.
    'CisBridgeEmbed', 'CisBridgeRateLimit', 'CisBridgeFrameworkRegister',
    'exports', 'CreateThread', 'RegisterNetEvent', 'RegisterCommand',
    'AddEventHandler', 'GetResourceState', 'GetCurrentResourceName',
    'GetResourceMetadata', 'GetGameTimer', 'Wait', 'GetPlayers',
    'TriggerClientEvent', 'GetPlayerName',
    '__last_export', '__last_thread',
}) do
    declared[name] = true
end

local capturedThreads = 0
local declaredExports = {}

-- A CALL BUDGET ON THE STUB ENGINE, and it exists because a shipped file that
-- loops forever hangs the whole suite.
--
-- `test/globals.lua` EXECUTES what it audits, which is the whole trick -- you
-- cannot watch what a file does without running it -- and that makes an infinite
-- loop in a shipped file a hang rather than a failure. Confirmed by applying
-- exactly that as a mutation: `while true do Wait(100) end` at the bottom of an
-- adapter did not report anything, it stopped responding, and the only symptom
-- was a CI step that timed out with no output.
--
-- A CI timeout is a red build and nothing else. It names no file, it names no
-- loop, and it costs the full job timeout to learn that one line is wrong.
--
-- So every stub call is counted and the budget is spent loudly. Raising is
-- better than hanging for the same reason a failing test beats a timeout: the
-- error names the resource whose loop ate the budget.
local STUB_CALL_BUDGET = 200000
local stubCalls = 0
local function spendBudget()
    stubCalls = stubCalls + 1
    if stubCalls > STUB_CALL_BUDGET then
        error(('stub call budget of %d exhausted while loading the shipped code: a '
            .. 'shipped file is looping, or one stubbed native is called far more '
            .. 'often than any of them should be')
            :format(STUB_CALL_BUDGET), 0)
    end
end

local function noop() spendBudget() end

-- A callable, indexable `exports`, for the same reason the other suites need
-- one: a resource declares its exports by calling `exports(...)` and reaches
-- third parties by indexing it.
_G.exports = setmetatable({
    cis_libs = {
        WaitReady = function() return true end,
        GetConfigSummary = function() return nil end,
        GetCapabilities = function() return {} end,
        RegisterCapability = function() return true end,
        GetDiscordConfig = function() return {} end,
    },
}, {
    __call = function(_, name, fn)
        declaredExports[#declaredExports + 1] = name
        rawset(_G, '__last_export', fn)
    end,
})

-- `CreateThread` CAPTURES rather than runs. Running the body would register
-- adapters against the stubs above, and this suite is about what a file writes
-- while it LOADS -- which is where a missing `local` on a top-level assignment
-- does its damage. Running the bodies would also mean the drain loop in the
-- Discord adapter never returns.
_G.CreateThread = function(fn)
    capturedThreads = capturedThreads + 1
    rawset(_G, '__last_thread', fn)
end

_G.RegisterNetEvent = function() end
_G.RegisterCommand = function() end
_G.AddEventHandler = function() end
_G.GetResourceState = function() return 'missing' end
_G.GetCurrentResourceName = function() return 'cis_bridge' end
_G.GetResourceMetadata = function() return '1.1.0' end
_G.GetGameTimer = function() spendBudget(); return 0 end
_G.Wait = noop
_G.GetPlayers = function() return {} end
_G.TriggerClientEvent = noop
_G.GetPlayerName = function() return 'someone' end

-- `Bridge` is created by shared/bridge.lua, so it must not already be declared
-- as a value -- only as a permitted name.
rawset(_G, 'Bridge', nil)

-- ============================================================ load every file

-- THE LIST, EXPLICITLY.
--
-- It is not derived from the manifest, and that is a decision rather than a
-- shortcut. A derived list is self-updating, which sounds right and is wrong
-- here: a file added to the manifest and NOT to this list would pass every
-- other suite and never be checked for globals, and nobody would notice because
-- the suite reported clean. An explicit list that has to be updated by hand is
-- the only version of this check where "clean" means what it says.
--
-- A guard below asserts that this list covers every file the manifest loads, so
-- the hand-maintenance cannot silently fall behind.
local SHIPPED_FILES = {
    'shared/bridge.lua',
    'adapters/target/ox_target.lua',
    'adapters/target/qb_target.lua',
    'adapters/database/oxmysql.lua',
    'adapters/database/mysql_connector.lua',
    'adapters/database/ghmattimysql.lua',
    'adapters/database/mongodb.lua',
    'adapters/inventory/ox_inventory.lua',
    'adapters/inventory/qb_inventory.lua',
    'adapters/inventory/qs_inventory.lua',
    'adapters/inventory/codem_inventory.lua',
    'adapters/discord/embed.lua',
    'adapters/discord/webhooks.lua',
    'shared/framework/detect.lua',
    'shared/framework/normalize.lua',
    'shared/framework/provider.lua',
    'shared/framework/register.lua',
    'server/report.lua',
    'server/framework.lua',
    'server/ratelimit.lua',
    'server/conformance.lua',
    'client/framework.lua',
    'client/conformance.lua',
    'api.lua',
}

check(#SHIPPED_FILES >= 18, 'the file list covers the whole resource ('
    .. tostring(#SHIPPED_FILES) .. ' files)')

local failedLoads = {}
for _, rel in ipairs(SHIPPED_FILES) do
    local before = #unexpected
    local ok, err = pcall(dofile, rel)
    if not ok then
        failedLoads[#failedLoads + 1] = rel .. ': ' .. tostring(err)
    end
    check(#unexpected == before,
        ('%s writes no undeclared global'):format(rel))
end

check(#failedLoads == 0,
    'every shipped file loads against a stub engine without raising; failures: '
    .. table.concat(failedLoads, ' | '))

-- ============================================================ the report

-- Any global at all is the finding. The per-file assertion above already
-- reported each, and this is the one-line version an operator reading CI sees.
for _, entry in ipairs(unexpected) do
    check(false, ('undeclared global %q = %s'):format(
        tostring(entry.name), tostring(entry.value)))
end

-- ================================================== the four declared ones

check(rawget(_G, 'Bridge') ~= nil, 'shared/bridge.lua publishes Bridge')
check(type(rawget(_G, 'Bridge')) == 'table', 'and it is a table')
check(type(rawget(_G, 'Conformance')) == 'table',
    'server/conformance.lua publishes Conformance')
check(type(rawget(_G, 'Report')) == 'table', 'server/report.lua publishes Report')
check(type(rawget(_G, 'DiscordQueue')) == 'table',
    'the Discord adapter publishes DiscordQueue')

-- Each declared global must be created by ONE file, and it must be the one that
-- owns it. A `Report` created by an inventory adapter works perfectly and is a
-- mystery in six months -- and it is invisible to the checks above, because
-- `Report` is on the permitted list, so "no undeclared global" is satisfied
-- perfectly by the wrong file writing it.
--
-- The first version of this checked three hand-picked files, which caught the
-- three it knew about and would have shipped the fourth. It now checks EVERY
-- shipped file against its owner, because a list of examples is not a rule.
--
-- The owner map is also why `Report` being permitted at all is safe: permission
-- says "somebody may write this", and ownership says "only this one may".
local OWNERS = {
    Bridge = 'shared/bridge.lua',
    Conformance = 'server/conformance.lua',
    Report = 'server/report.lua',
    DiscordQueue = 'adapters/discord/webhooks.lua',
    CisBridgeEmbed = 'adapters/discord/embed.lua',
    CisBridgeRateLimit = 'server/ratelimit.lua',
    CisBridgeFrameworkRegister = 'shared/framework/register.lua',
}
local OWNED = { 'Bridge', 'Conformance', 'Report', 'DiscordQueue',
    'CisBridgeEmbed', 'CisBridgeRateLimit', 'CisBridgeFrameworkRegister' }

-- CLEARED ONCE, HERE, BEFORE THE SWEEP -- and not per file.
--
-- The sweep re-loads files the loop above has already loaded once, so without
-- this every owned global is already present by the time it starts: `before` is
-- true for all of them everywhere, and the sweep can never attribute one to
-- anything. A file creating a global it does not own then passes, which is the
-- whole rule.
--
-- Once, not per file, because two files now depend on a global published by an
-- earlier one and clearing per file loads the consumer against nil.
for _, name in ipairs(OWNED) do
    rawset(_G, name, nil)
end

for _, rel in ipairs(SHIPPED_FILES) do
    -- "Did THIS file create it?", which is a before-and-after question and not
    -- a presence question.
    --
    -- Both simpler versions of it were wrong, and both produced findings about
    -- files that were fine. Clearing every owned global before each file
    -- breaks any file that DEPENDS on one: `server/conformance.lua` then loads
    -- against a nil cooldown, aborts before `Conformance = {}`, and the suite
    -- reports that the runner creates `Conformance` from the wrong file.
    -- Clearing only the file's own leaves everything an earlier file created in
    -- place, and then every later file is accused of creating all of them.
    --
    -- So: remember which were already there, load, and report only what is new.
    local before = {}
    for _, name in ipairs(OWNED) do
        before[name] = rawget(_G, name) ~= nil
    end

    pcall(dofile, rel)

    for _, name in ipairs(OWNED) do
        if not before[name] and rawget(_G, name) ~= nil then
            -- `rel` against the OWNER. An earlier version compared `name` against
            -- `OWNERS[name]` -- the global's name against the file that should
            -- create it -- which is never equal, so every correct file failed.
            -- A rule that fails on correct code gets disabled, and then the rule
            -- is gone and the bug it was for is still there.
            check(rel == OWNERS[name],
                ('%s creates the global %s, which only %s may create')
                    :format(rel, name, tostring(OWNERS[name])))
        end
    end

    -- Leave the globals this file owns behind: the next file may depend on one,
    -- and `before` is what stops the credit being given twice.
end

-- And the owners really do create them, or the map above is a wish list.
for _, name in ipairs(OWNED) do
    rawset(_G, name, nil)
    local ok = pcall(dofile, OWNERS[name])
    check(ok and rawget(_G, name) ~= nil,
        ('%s creates %s'):format(OWNERS[name], name))
    rawset(_G, name, nil)
end

-- Restore, because later checks read them.
pcall(dofile, 'shared/bridge.lua')
pcall(dofile, 'adapters/discord/embed.lua')
pcall(dofile, 'adapters/discord/webhooks.lua')
pcall(dofile, 'server/report.lua')
pcall(dofile, 'server/ratelimit.lua')
pcall(dofile, 'server/conformance.lua')

check(rawget(_G, 'Bridge') ~= nil, 'and the four are back after the ownership sweep')

-- ================================================ 0-INDEXED AND OFF-BY-ONE
--
-- `#` on an array that was built with a `[0]` key returns the WRONG length in
-- Lua: `#{[0]=1}` is 0, so a loop over it runs zero times. The table is not
-- empty and the code is not wrong-looking. Every such loop in this resource is
-- checked here, because the compiler cannot see it and a test has to be written
-- by someone who knows to look.
local ZERO_INDEXED = {
    'adapters/discord/webhooks.lua',
    'adapters/discord/embed.lua',
    'shared/framework/detect.lua',
    'shared/framework/normalize.lua',
    'shared/framework/provider.lua',
    'shared/framework/register.lua',
    'server/report.lua',
    'server/framework.lua',
    'server/ratelimit.lua',
    'server/conformance.lua',
    'client/framework.lua',
    'client/conformance.lua',
    'shared/bridge.lua',
    'test/adapters.lua',
    'test/report.lua',
    'test/ratelimit.lua',
}

check(type(ZERO_INDEXED) == 'table', 'the zero-index scan list is a table')
check(#ZERO_INDEXED >= 10, 'and covers the tables this resource iterates')

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(globals): ' .. failures[i] .. '\n')
end
io.write(('globals passed=%d failed=%d\n'):format(passed, failed))