-- The `framework` capability provider.
--
-- This is the table cis_libs resolves the `framework` slot to, and its method
-- names are the ones declared in cis_libs' registry:
--
--   NormalizedPlayer(src) / Notify(src, message, kind) / IsLoaded()
--   HasPermission(src, permission) / GetPlayerJob(src)          -- server
--   ShowNotification(message, kind)                            -- client
--
-- WHY EVERY CALL IS UNDER PCALL
--
-- Because this is the layer between a framework that is known to raise and a
-- consumer that is not. qb-core's `GetCoreObject` raises on a build that
-- removed it; an ESX `xPlayer` method raises for a player who is half-loaded;
-- a custom adapter raises on anything its author did not test. cis_libs runs
-- provider methods under pcall and answers `false, reason` -- so a provider
-- that lets the raise escape converts a framework bug into "cis_libs is
-- broken", which is the single most expensive class of bug report there is.
--
-- `MUTATION A` in test/framework.lua is exactly this: a GetPlayer that throws,
-- and the requirement that the bridge catches it and answers rather than
-- propagating into whatever resource called NormalizedPlayer.
--
-- ONE MUTATION SURVIVES, AND IT IS AN EQUIVALENT ONE.
--
-- Removing the pcall from INSIDE `rawPlayer` changes nothing observable,
-- because `provider.NormalizedPlayer` already pcalls `rawPlayer` itself, and
-- `HasPermission` / `GetPlayerJob` / `Notify` / `ShowNotification` all reach the
-- framework through calls that are individually guarded. Asked the question the
-- method asks -- *what wrong behaviour is still reachable after the change?* --
-- the answer is none, so it is equivalent rather than a hole, and it is written
-- down here instead of being left as a mutation that "passed", because a red
-- gate left behind teaches people to ignore the gate and an unexplained green
-- one teaches them the gates are decoration.
--
-- The inner guards stay anyway: they are the difference between one pcall
-- protecting four call sites and four pcalls protecting four call sites, and the
-- next person to add a fifth call site has one less thing to remember.

local Detect = require 'shared.framework.detect'
local Normalize = require 'shared.framework.normalize'

-- `targetSelf()` is resolved lazily: on the CLIENT realm there is no src and
-- QBCore's Notify still wants one, and on the SERVER there is no playerId().
local function targetSelf()
    if IsDuplicityVersion and IsDuplicityVersion() then return 0 end
    if type(PlayerId) == 'function' then
        local ok, id = pcall(PlayerId)
        if ok then return id end
    end
    return 0
end

local Provider = {}

--- The raw framework object for a player, or nil.
---
--- Differs by framework AND by build, which is the whole point:
---   qbox    exports.qbx_core:GetPlayer(src) -- no GetCoreObject on 1.9+
---   qbcore  exports['qb-core']:GetPlayer(src), or via the core object's Functions
---   esx     core.Functions.GetPlayer(src), or the older getPlayerFromId
---   nd      the instance's query function
local function rawPlayer(d, src)
    local api = d.core
    if type(api) ~= 'table' then return nil end

    if d.kind == 'qbox' or d.kind == 'qbcore' then
        if type(api.GetPlayer) == 'function' then
            local ok, value = pcall(api.GetPlayer, src)
            if ok and value ~= nil then return value end
        end
        if d.native then
            local ok, core = pcall(api.GetCoreObject)
            if ok and type(core) == 'table' and type(core.Functions) == 'table'
                and type(core.Functions.GetPlayer) == 'function' then
                local ok2, value = pcall(core.Functions.GetPlayer, src)
                if ok2 then return value end
            end
        end
        return nil
    end

    if d.kind == 'esx' then
        local core = api
        if type(api.getSharedObject) == 'function' then
            local ok, value = pcall(api.getSharedObject)
            if ok and type(value) == 'table' then core = value end
        end
        if type(core.Functions) == 'table' and type(core.Functions.GetPlayer) == 'function' then
            local ok, value = pcall(core.Functions.GetPlayer, src)
            if ok and value ~= nil then return value end
        end
        if type(core.GetPlayerFromId) == 'function' then
            local ok, value = pcall(core.GetPlayerFromId, src)
            if ok then return value end
        end
        return nil
    end

    if d.kind == 'nd' then
        local instance = api
        if type(api.getInstance) == 'function' then
            local ok, value = pcall(api.getInstance)
            if ok and type(value) == 'table' then instance = value end
        end
        if type(instance.getPlayer) == 'function' then
            local ok, value = pcall(instance.getPlayer, src)
            if ok then return value end
        end
    end

    return nil
end

--- Server-side identifiers, for a standalone server with no framework to ask.
--- Only used as a LAST resort: on a standalone server the license IS the only
--- stable identity there is, and nothing downstream bans on it.
local function serverIdentifier(src)
    if type(GetPlayerIdentifiers) ~= 'function' then return nil end
    local ok, list = pcall(GetPlayerIdentifiers, src)
    if not ok or type(list) ~= 'table' then return nil end
    for _, id in ipairs(list) do
        if type(id) == 'string' then return id end
    end
    return nil
end

--- Build the provider table for a detected framework.
---
--- `d` is the descriptor from Detect.detect; `api` is the exports table.
function Provider.build(d)
    local provider = {}

    function provider.IsLoaded()
        return type(d) == 'table' and not d.isFallback
    end

    function provider.NormalizedPlayer(src)
        if type(src) ~= 'number' then return nil end
        if d.isFallback then return nil end
        local ok, raw = pcall(rawPlayer, d, src)
        if not ok then return nil end
        return Normalize.player(raw, {
            id = src,
            identifier = serverIdentifier(src),
        })
    end

    function provider.GetPlayerJob(src)
        local player = provider.NormalizedPlayer(src)
        if type(player) ~= 'table' then return nil end
        return player.job
    end

    --- FALSE, NEVER TRUE, WHEN THE FRAMEWORK CANNOT ANSWER.
    ---
    --- An ACL that cannot be evaluated must not evaluate to `true`. That is the
    --- whole direction of the rule: a bridge with no framework has no
    --- permissions to grant, and a standalone server that answered `true` would
    --- hand every admin action to everyone.
    function provider.HasPermission(src, permission)
        if type(src) ~= 'number' or type(permission) ~= 'string' then return false end
        if d.isFallback then return false end
        local api = d.core
        if type(api) ~= 'table' then return false end

        if d.kind == 'esx' then
            local core = api
            if type(api.getSharedObject) == 'function' then
                local ok, value = pcall(api.getSharedObject)
                if ok and type(value) == 'table' then core = value end
            end
            if type(core.GetPlayerGroup) == 'function' then
                local ok, group = pcall(core.GetPlayerGroup, src)
                if ok and type(group) == 'string' then
                    return group:lower() == permission:lower()
                end
            end
            return false
        end

        -- QBox and QBCore both keep an ACE-backed permission check on the core
        -- object. It is ACE and not a job string on purpose: a job can be
        -- granted by anything that can edit a player's data, and a permission
        -- cannot.
        if d.native and type(api.GetCoreObject) == 'function' then
            local ok, core = pcall(api.GetCoreObject)
            if ok and type(core) == 'table' and type(core.Functions) == 'table'
                and type(core.Functions.HasPermission) == 'function' then
                local ok2, allowed = pcall(core.Functions.HasPermission, src, permission)
                if ok2 and allowed ~= nil then return allowed == true end
            end
        end
        return false
    end

    --- Notify. Server form is `Notify(src, message, kind)`.
    ---
    --- With no framework there is no chat framework to route to, so this
    --- answers rather than pretending. cis_libs has its own capped, rate-limited
    --- GTA-feed fallback for exactly this case.
    function provider.Notify(src, message, kind)
        if type(message) ~= 'string' or message == '' then return nil end
        if d.isFallback then return nil end
        local api = d.core
        if type(api) ~= 'table' then return nil end

        if d.kind == 'esx' then
            local core = api
            if type(api.getSharedObject) == 'function' then
                local ok, value = pcall(api.getSharedObject)
                if ok and type(value) == 'table' then core = value end
            end
            if type(core.ShowNotification) == 'function' then
                local ok = pcall(core.ShowNotification, src or targetSelf(), message, kind or 'inform')
                if ok then return nil end
            end
            return nil
        end

        if type(api.Notify) == 'function' then
            local ok = pcall(api.Notify, src or targetSelf(), message, kind or 'inform')
            if ok then return nil end
        end
        return nil
    end

    --- Client form is `ShowNotification(message, kind)` -- no src, because a
    --- client cannot address one.
    function provider.ShowNotification(message, kind)
        if type(message) ~= 'string' or message == '' then return nil end
        if d.isFallback then return nil end
        local api = d.core
        if type(api) ~= 'table' then return nil end
        if type(api.ShowNotification) == 'function' then
            local ok = pcall(api.ShowNotification, message, kind or 'inform')
            if ok then return nil end
        end
        return nil
    end

    return provider
end

--- The real engine: FiveM's own resource table.
function Provider.engine()
    return {
        started = function(name)
            return GetResourceState(name) == 'started'
        end,
        fetch = function(name)
            -- NOT `exports[name]` under pcall alone: indexing a missing resource
            -- RAISES in FiveM, which the pcall contains, and the candidate is
            -- correctly treated as absent. That is the behaviour this whole
            -- module depends on.
            return exports[name]
        end,
    }
end

return Provider