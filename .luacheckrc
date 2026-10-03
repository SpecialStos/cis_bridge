-- Real lint. `npm run lint`.
--
-- luacheck is not an npm dependency and is not installed by `npm ci`: CI
-- installs a pinned release and this repository keeps its zero-runtime-
-- dependency property. `npm run lint` therefore says so plainly when the tool
-- is absent instead of exiting 0 and leaving a reader to assume the code was
-- checked -- which is the failure shape this repository has already paid for
-- once, where a missing `luac5.4` made every file in the tree look like a
-- syntax error.
--
-- It catches what a syntax check cannot: an unused local, a shadowed name, a
-- global assigned in one file and read in another by accident, and a variable
-- written on one line and read on the next from a branch that never runs. The
-- last one is the class that matters here -- this resource makes decisions at
-- registration time and reads them later, so an assignment that silently fails
-- to happen is a capability that answers differently than its source says.

std = "lua54"

-- Everything the FiveM runtime provides that this resource CALLS. A short list,
-- written by hand rather than generated: this repository calls a couple of dozen
-- natives and generates nothing, so a generator would be machinery to maintain
-- a list of eight lines.
--
-- `exports` and `require` are std; the rest are CfxLua.
read_globals = {
    -- scheduler and resource lifecycle
    "CreateThread", "Wait", "WaitReady",
    "GetGameTimer", "SetTimeout", "Citizen", "Await",
    "GetResourceState", "GetResourceMetadata", "GetCurrentResourceName",
    "AddCommand",
    -- events
    "RegisterNetEvent", "TriggerClientEvent", "TriggerServerEvent",
    -- players
    "GetPlayers", "GetPlayerName",
    -- entities, for the client conformance probe
    "GetHashKey", "RequestModel", "HasModelLoaded", "CreatePed", "DeleteEntity",
    "DoesEntityExist", "SetEntityAsMissionEntity", "SetModelAsNoLongerNeeded",
    -- outbound, the one request this platform makes
    "PerformHttpRequest",
}

-- What this repository DEFINES. Each is a global on purpose, because that is
-- how one resource file reaches another: `Bridge` is shared, `Conformance` and
-- `Report` are read by a command registered in a different file.
--
-- Declared writable rather than read-only so that luacheck does not resolve a
-- name appearing in both lists to read-only and then report the assignment that
-- defines it. Only these four are ours; everything else a file touches has to
-- be a local or an error.
globals = {
    "Bridge",
    "Conformance",
    "Report",
    "DiscordQueue",
}

-- The test suites stand the whole engine up themselves, so every FiveM global is
-- assigned rather than read. That is what the suites are FOR, and reading it as
-- a lint failure would mean disabling the file instead.
files["test/"] = {
    -- Every stub the suites define. Listed rather than wildcarded because a
    -- wildcard here would silence a typo in a stub name -- the stub would not
    -- match, the code would call nil, and the suite would raise.
    globals = {
        "exports", "CreateThread", "GetResourceState", "GetCurrentResourceName",
        "GetResourceMetadata", "GetGameTimer", "Wait",
        "__declared", "__caps", "__suite_failed",
    },
}

-- luacheck's default is 120. The shipped Lua holds to it -- the longest line in
-- any adapter, the report or the runner is 113 -- and a real limit is worth
-- having on code.
max_line_length = 120

-- api.lua is exempt, and the reason is that it is DATA: one table of prose
-- describing every export, where a `use` sentence that explains a decision is
-- allowed to be a sentence. Wrapping those strings to fit a number would either
-- truncate the explanation or make it unreadable, and a lint rule that forces
-- either is not buying anything.
--
-- It is not loaded at runtime and `npm run test:api` validates it on its own
-- terms -- against the surface the code actually registers.
files["api.lua"] = { max_line_length = false }