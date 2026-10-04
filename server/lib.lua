-- The `lib.*` shim, exported.
--
-- WHY AN EXPORT AND NOT A GLOBAL `lib`
--
-- **Each FiveM resource has its own Lua state.** `TriggerEvent` does not cross
-- resources, and a global written in cis_bridge is a different variable from
-- the same name in the resource that reads it. So a shim that "installs lib"
-- installs it for ITSELF and nobody else -- which looks like a working drop-in
-- on the machine it was built on and silently does nothing on a customer's.
--
-- The honest shape is an export, and a consumer takes it with one line:
--
--     local lib = exports['cis_bridge']:GetLibShim()
--
-- One line, and not nothing -- and worth more than a silent injection, because
-- a line SAYS the dependency is there. Somebody who removes cis_bridge finds out
-- from their own source rather than from a support ticket.
--
-- SERVER SIDE, AND THAT IS NOT AN ARBITRARY CHOICE: the database proxy is
-- server-only by definition, and a callback shim a consumer wants on the client
-- reaches for cis_libs' own `Cis.*` directly, which is what the client realm is
-- for. Declaring these as shared would also make them invisible to the api
-- validator, which scans `server_scripts` and `client_scripts` and so cannot
-- see an export declared in a shared script at all.

local Shim = require 'shared.lib.shim'

-- Every engine call below is a COLON call: `exports['cis_libs']` is an exports
-- table and `exports['cis_libs']:Name(...)` passes it as self. The fake in
-- test/shim.lua is shaped the same way, so losing that argument fails in a unit
-- suite instead of on a server.
local function engine()
    local e = {}
    for _, name in ipairs({
        'CreateZone', 'RemoveZone', 'ZoneContains',
        'RegisterCallback', 'TryAwaitCallback', 'CallCallback',
        'DbQuery', 'DbSingle', 'DbScalar', 'DbInsert', 'DbUpdate', 'DbTransaction',
    }) do
        e[name] = function(_, ...)
            return exports['cis_libs'][name](exports['cis_libs'], ...)
        end
    end
    return e
end

local lib, proxy

exports('GetLibShim', function()
    if lib == nil then
        lib = Shim.build(engine())
    end
    return lib
end)

exports('GetDbProxy', function()
    if proxy == nil then
        proxy = Shim.proxy(engine())
    end
    return proxy
end)
