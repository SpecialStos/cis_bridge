-- Contract compliance: does this resource build against cis_libs the way the
-- contract says it should?
--
-- The other three suites ask whether the CODE does what it says. This one asks
-- whether the code and the CONTRACT agree, which is a different question and the
-- only one that catches a platform moving underneath a product that still passes
-- every other test.
--
-- Almost every assertion here is a grep. That is not laziness: the failure being
-- prevented is a resource that boots, registers nothing, and reports nothing
-- wrong, and the only way to see it before a customer does is to compare the
-- source against a list. Every rule is one somebody broke at least once while
-- this resource was being written, which is why each carries that story.
--
-- Read with fengari and no FiveM server. It reads files with `io`, so it is
-- checking the SOURCE on disk -- the thing that ships -- rather than whatever
-- happens to be loaded in a running VM.

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

-- ===================================================== reading the source
--
-- fengari has NO filesystem. `io.open` answers nil and the first version of this
-- suite died on it with "attempt to call a nil value (field 'open')", which reads
-- as a Lua bug rather than as the VM having no disk. The harness therefore reads
-- every .lua file and hands them over as `__SOURCES`, already stripped of
-- comments; only the bytes come from there, because only the harness can get
-- them.
--
-- The knowledge -- which rule exists and why -- stays here, because that is the
-- expensive part and it does not belong in a test runner.
local SOURCES = _G.__SOURCES or {}
-- The same source with string CONTENTS neutralised: identifiers survive, every
-- other character inside a literal becomes `_`. Rules that ask "does the code
-- call this" run against this, so a rule cannot fire on the sentence a developer
-- wrote to explain the rule -- which is what happened to the realm rule below,
-- on the message that says `Cis.target` is a client surface.
local BARE = _G.__BARE or {}
check(type(SOURCES) == 'table' and next(SOURCES) ~= nil,
    'the harness handed over the source of this resource to audit')

local function readFile(rel)
    return SOURCES[rel]
end

local function linesOf(rel, from)
    local body = (from or SOURCES)[rel]
    if not body then return nil end
    local out = {}
    -- The harness already flattened every newline to a space, so this splits on
    -- a character that cannot occur inside a stripped source line.
    for line in (body .. '|'):gmatch('([^|]*)|') do
        out[#out + 1] = line
    end
    return out, body
end

-- Comments are already gone: the harness strips them, once, with one scanner.
-- Every rule below has a header explaining the incident it prevents, and a header
-- explaining an incident is full of the very names it is explaining -- so a rule
-- that matched comments would fire on its own documentation, and a rule that
-- fires on its own documentation is a rule that gets deleted.

-- The files the manifest actually loads, split by realm. Derived from the
-- manifest rather than hard-coded, because a hard-coded list goes stale the
-- moment an adapter is added -- and then the suite stops checking the new one,
-- which is the exact failure mode a compliance suite exists to prevent.
local manifest = readFile('fxmanifest.lua') or ''

local function scriptsIn(section)
    local out = {}
    -- `shared_scripts { ... }` and friends, or the singular `dependency` form.
    local body = manifest:match(section .. '%s*{(.-)}')
    if not body then return out end
    for entry in body:gmatch("['\"]([^'\"]+)['\"]") do
        -- `@other/file.lua` is a reference into a SIBLING resource. It resolves
        -- against the resources root, not against this directory, so it is
        -- recorded for the realm it belongs to and not checked for existence.
        out[#out + 1] = entry
    end
    return out
end

local SHARED = scriptsIn('shared_scripts')
local CLIENT = scriptsIn('client_scripts')
local SERVER = scriptsIn('server_scripts')

-- Two files are `require`d rather than listed: the Discord embed builder and
-- the cooldown. Both are server-realm, both are reached through `require`, and
-- both are loaded without the engine by the unit suites.
local EXTRA_SERVER = { 'adapters/discord/embed.lua', 'server/ratelimit.lua' }

local function shippedByRealm()
    local server, client = {}, {}
    local function add(list, into)
        for _, entry in ipairs(list) do
            if entry:sub(1, 1) ~= '@' then
                into[entry] = true
            end
        end
    end
    add(SERVER, server)
    add(EXTRA_SERVER, server)
    add(CLIENT, client)
    return server, client
end

local SERVER_FILES, CLIENT_FILES = shippedByRealm()

-- Every shipped file this resource has, whether the manifest lists it or a
-- `require` reaches it. Written out rather than built by iterating a table of
-- tables: `{ a, b, { x = 1 } }` is a nested table constructor whose meaning
-- depends on how the parser reads the trailing brace, and "clever" here bought
-- nothing over three named calls.
local SHIPPED = {}
local function collect(into, out)
    for name in pairs(into) do
        out[#out + 1] = name
    end
end
collect(SERVER_FILES, SHIPPED)
collect(CLIENT_FILES, SHIPPED)
SHIPPED[#SHIPPED + 1] = 'shared/bridge.lua'
table.sort(SHIPPED)

check(#SHIPPED >= 15, 'the manifest describes at least fifteen shipped files (found '
    .. tostring(#SHIPPED) .. ')')

-- ============================================ 1. the two manifest requirements
--
-- Both are in the contract, both are load-bearing, and both have the same
-- failure: a resource that starts, looks installed, and does nothing.

check(SERVER_FILES['shared/bridge.lua'] == true or SHARED[1] == 'shared/bridge.lua'
    or manifest:find("'shared/bridge%.lua'", 1) ~= nil,
    'shared/bridge.lua is loaded')

local declaresDependency = manifest:match("dependencies%s*{[^}]*'cis_libs'") ~= nil
    or manifest:match("dependency%s+'cis_libs'") ~= nil
check(declaresDependency,
    "fxmanifest declares cis_libs as a dependency -- without it FiveM may start this "
    .. "resource first, and every adapter's WaitReady then waits for something that "
    .. "is not coming yet")

local includesInit = false
for _, entry in ipairs(SHARED) do
    if entry == '@cis_libs/init.lua' then includesInit = true end
end
check(includesInit,
    "shared_scripts includes '@cis_libs/init.lua' -- this resource calls Cis.db.* and "
    .. "Cis.target.* in its conformance suites, and with the facade unloaded `Cis` is "
    .. "nil, so every server check reported 'attempt to index global Cis' on a healthy "
    .. "install and the client half died before printing a line")

check(manifest:find("lua54%s+'yes'") ~= nil,
    "fxmanifest sets lua54 'yes'")

check(manifest:find('game%s+') ~= nil, 'fxmanifest names a game')

-- =========================================== 2. NO DEPRECATED cis_libs API
--
-- The contract lists these explicitly: logged once per calling resource per
-- boot, removed in 3.0.0. Calling one today works and is how a resource breaks
-- on a cis_libs upgrade -- the worst time to find out, because it is a platform
-- release affecting every product at once.
local DEPRECATED = {
    { name = 'GetFramework', why = 'use Cis.registry.resolve or Cis.framework.*' },
    { name = 'GetClosestDoor', why = 'use Cis.doors.closest' },
    { name = 'SetDoorState', why = 'use Cis.doors.state' },
    { name = 'AddDoor', why = 'use Cis.doors.add' },
    { name = 'RemoveDoor', why = 'use Cis.doors' },
    { name = 'GetDoorState', why = 'use Cis.doors.state' },
    { name = 'GetAllDoors', why = 'use Cis.doors.all' },
    { name = 'DoorExists', why = 'use Cis.doors.state' },
    { name = 'SetDoorHeading', why = 'use Cis.doors' },
}

for _, rel in ipairs(SHIPPED) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        for _, dep in ipairs(DEPRECATED) do
            -- A CALL or a reference, not a bare mention: `exports[...]:GetFramework()`
            -- and a bare `GetFramework` both count, and a word in a string does not.
            if line:find('%f[%w]' .. dep.name .. '%f[^%w]') then
                check(false, ('%s calls the deprecated cis_libs API %s (%s)')
                    :format(rel, dep.name, dep.why))
            end
        end
    end
end
check(true, 'the deprecated-API scan completed over every shipped file')

-- ======================================== 3. EVERY cis_libs EXPORT EXISTS
--
-- The list is cis_libs' own, read out of its source. A call to an export that
-- does not exist does not return nil -- it raises "No such export", at the first
-- real call, on a live server, in whatever code path happened to reach it.
local CIS_LIBS_EXPORTS = {
    'AwaitCallback', 'AwaitCallbackClient', 'CheckResourceVersion', 'CreatePed',
    'CreateSafeCallback', 'CreateTarget', 'CreateZone', 'DbInsert', 'DbQuery',
    'DbScalar', 'DbSingle', 'DbTransaction', 'DbUpdate', 'DetectDatabase',
    'DetectFramework', 'GetCapabilities', 'GetClientConfig', 'GetConfigSummary',
    'GetDiagnostics', 'GetDiscordConfig', 'GetDiscordQueueDepth',
    'GetKnownTargets', 'GetLastRefusal', 'GetNormalizedPlayer', 'GetSelfCheck',
    'InventoryCount', 'InventoryHas', 'InventoryAdd', 'InventoryRemove',
    'IsReady', 'LogError', 'LogWarn', 'LogInfo', 'LogDebug', 'Notify',
    'NotifyClient', 'RateOk', 'RegisterCallback', 'RegisterCapability',
    'RemoveTarget', 'TargetExists', 'UnregisterCapability', 'UpdateTarget',
    'WaitCapability', 'WaitReady', 'ZoneContains',
    -- The legacy database aliases, still present and still callable.
    'DatabaseExecute', 'DatabaseFetchAll', 'DatabaseFetchOne', 'DatabaseInsert',
    'DatabaseUpdate', 'DatabaseDelete',
    -- Deprecated but still exported; a call is caught above, so listing them
    -- here only changes WHICH message fires.
    'GetFramework',
}

local exportSet = {}
for _, name in ipairs(CIS_LIBS_EXPORTS) do exportSet[name] = true end

for _, rel in ipairs(SHIPPED) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        -- The bracket and quote characters are neutralised in BARE, so the match
        -- accepts either the source form or the stripped form. Relaxed to
        -- `[%W_]` on purpose rather than pinned to the exact shape, because the
        -- alternative is a rule that needs updating every time the bracket
        -- style changes -- which is the kind of rule that gets deleted.
        for name in line:gmatch("exports%[[%W_]?cis_libs[%W_]?%]%s*:%s*([%a_][%w_]*)") do
            check(exportSet[name] == true,
                ('%s calls cis_libs:%s, which is not an export cis_libs defines')
                    :format(rel, name))
        end
    end
end
check(true, 'the cis_libs-export scan completed over every shipped file')

-- ================================================== 4. REALM BOUNDARIES
--
-- `Cis.target` is a client surface and `Cis.db` is a server surface, and the two
-- halves are different files for a reason: `init.lua` defines `Cis.target`
-- inside its not-server branch, so on the server `Cis.target` is nil and the
-- call raises "attempt to call field 'add' (a nil value)". That is not a
-- theoretical failure; it is what both target conformance tests reported on a
-- perfectly healthy install before the suite was split.

for rel in pairs(CLIENT_FILES) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        check(line:find('Cis%.db%.') == nil,
            ('%s is a client file and calls Cis.db, which is a server surface'):format(rel))
    end
end
for rel in pairs(SERVER_FILES) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        check(line:find('Cis%.target%.') == nil,
            ('%s is a server file and calls Cis.target, which is a client surface'):format(rel))
        check(line:find('Cis%.zones%.') == nil,
            ('%s is a server file and calls Cis.zones, which is a client surface'):format(rel))
        check(line:find('Cis%.player%.') == nil,
            ('%s is a server file and calls Cis.player, which is a client surface'):format(rel))
        check(line:find('Cis%.streaming%.') == nil,
            ('%s is a server file and calls Cis.streaming, which is a client surface'):format(rel))
        check(line:find('Cis%.world%.') == nil,
            ('%s is a server file and calls Cis.world, which is a client surface'):format(rel))
        check(line:find('Cis%.keybind%.') == nil,
            ('%s is a server file and calls Cis.keybind, which is a client surface'):format(rel))
    end
end
check(true, 'the realm scan completed over every shipped file')

-- ================================ 5. Cis.* NAMESPACES THAT cis_libs KNOWS
--
-- A namespace that does not exist is `nil`, and `nil.method()` raises at the
-- call rather than at load -- so a typo in a namespace name is invisible to
-- every other check in this repository.
local KNOWN_NAMESPACES = {
    callback = true, db = true, doors = true, framework = true, hooks = true,
    inventory = true, log = true, net = true, player = true, points = true,
    raycast = true, registry = true, require = true, security = true,
    statebag = true, streaming = true, sync = true, target = true,
    ui = true, vehicle = true, wait = true, waitFor = true, world = true,
    zones = true, command = true, keybind = true,
}

for _, rel in ipairs(SHIPPED) do
    local lines = linesOf(rel, BARE)
    for _, line in ipairs(lines or {}) do
        for ns in line:gmatch('Cis%.([%a_][%w_]*)%.') do
            check(KNOWN_NAMESPACES[ns] == true,
                ('%s calls Cis.%s, which cis_libs does not define. Known namespaces: %s')
                    :format(rel, ns,
                        (function()
                            local t = {}
                            for k in pairs(KNOWN_NAMESPACES) do t[#t + 1] = k end
                            table.sort(t)
                            return table.concat(t, ', ')
                        end)()))
        end
    end
end
check(true, 'the namespace scan completed over every shipped file')

-- ============================== 6. NO cis_libs INTERNAL FILES ARE INCLUDED
--
-- The contract is explicit: no `@cis_libs/server/registry.lua` or any other
-- internal include. Reaching into a sibling's internals means its globals and
-- locals arrive in this resource's Lua state unannounced, and the day that file
-- moves, this one breaks in a way that reads as a cis_libs bug.
for _, entry in ipairs(SHARED) do
    if entry:sub(1, 1) == '@' then
        check(entry == '@cis_libs/init.lua',
            ('shared_scripts includes %s, which is a cis_libs INTERNAL file. Only '
                .. '@cis_libs/init.lua is published for consumers'):format(entry))
    end
end
check(true, 'the internal-include scan completed')

-- ================================ 7. NO SERVER IDS SUPPLIED BY A CLIENT
--
-- `source` is the only identity on the server side that a caller cannot choose.
-- This resource has one net event handler, and it takes no arguments at all --
-- the whole point of the design is that the server asks and the client answers
-- with observations. A future edit that adds a parameter has to add the check
-- here at the same time.
local confLines = linesOf('server/conformance.lua') or {}
local netEventLines = {}
for _, line in ipairs(confLines) do
    if line:find('RegisterNetEvent') then
        netEventLines[#netEventLines + 1] = line
    end
end
check(#netEventLines >= 1, 'the server registers at least one net event handler')
for _, line in ipairs(netEventLines) do
    -- `function(payload)` -- one parameter, which is the client's answer and is
    -- treated as untrusted data rather than as an identity.
    check(line:find('function%(payload%)') ~= nil,
        'the net event handler takes only the client payload and no player id')
end
check(true, 'the source-derivation scan completed')

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(contract): ' .. failures[i] .. '\n')
end
io.write(('contract passed=%d failed=%d\n'):format(passed, failed))