-- The seam between this resource and cis_libs.
--
-- An adapter's whole job is: check whether my target is actually running, and
-- if it is, register myself as the capability. That is small enough to be one
-- helper, and small enough that every adapter MUST use it rather than
-- hand-rolling the same four lines.
--
-- The four lines matter more than they look:
--
--   1. Is the resource started? An adapter that registers against a target
--      that is not there is an adapter whose every call raises.
--   2. Does the configured name match? A server with ox_target installed but
--      configured for qb-target should use neither, and should be told so --
--      "the target you configured is not installed" is a different problem
--      from "no target is installed", and the operator needs to be told which.
--   3. Does the export we need exist? Older oxmysql has no `single`; a
--      feature probe beats calling it and catching the raise on every query.
--   4. Register, and say so. A silent registration is a registration nobody
--      can debug.

Bridge = {}

local registered = {}

--- Is a third-party resource actually running?
function Bridge.started(name)
    return GetResourceState(name) == 'started'
end

--- Register this resource as the provider for a capability.
---
--- `configured` is the operator's choice, read from cis_libs. `nil` means "no
--- opinion" -- an adapter whose target is unambiguous (oxmysql is the only
--- database most servers have) registers on presence alone, and one that
--- competes with a rival (two target resources, two inventory resources)
--- respects the configured name.
---
--- `probeExport` is what the adapter needs the target to HAVE, and it may be a
--- single name or a list of them. The list form exists because one export is
--- not enough to establish compatibility: an adapter that calls six of a
--- target's exports has six ways to be wrong, and probing one of them proves
--- only that the target exists. Every missing name is named, so the console line
--- answers "which" and not merely "no".
---
--- `exportName` is PER ADAPTER and that is not a style choice. Two adapters in
--- one resource registering the same export name means the second silently
--- replaces the first, so whichever file happened to load last answers for
--- every capability -- and a server with ox_target and no qb-target would end
--- up being served by whichever qb adapter ran last, which fails on every call
--- and names a resource that is not even installed. One name per adapter.
---
--- @return boolean registered
function Bridge.register(slot, target, configured, probeExport, exportName)
    -- AUTO IS "NO OPINION", and reading it as a rival resource name is what
    -- stopped a stock install from ever registering a driver. `Database.Type`
    -- ships as "AUTO" in both the config and the library defaults, so every
    -- adapter compared its own name against the string "AUTO", found a
    -- mismatch, and refused -- on a server where oxmysql was running, with
    -- nothing wrong anywhere. AUTO means "work it out from what is started",
    -- which is exactly the presence path a nil already took.
    if configured == 'AUTO' or configured == 'auto' then
        configured = nil
    end
    -- The same sentence, from the other direction. 'NONE' is what
    -- `GetConfigSummary` reports for a slot nobody configured, and it is an
    -- ANSWER rather than a rival: there is no operator choice to respect, so
    -- treating it as one refuses the only driver on the server.
    if configured == 'NONE' or configured == 'none' then
        configured = nil
    end
    if configured and configured ~= '' and configured ~= target then
        print(('[cis_bridge] %s: not registered, the configuration names %q')
            :format(slot, tostring(configured)))
        return false
    end
    if not Bridge.started(target) then
        print(('[cis_bridge] %s: %s is not started; %s is not registered')
            :format(slot, target, slot))
        return false
    end
    if probeExport ~= nil and probeExport ~= '' then
        local required = type(probeExport) == 'table' and probeExport or { probeExport }
        local missing = {}
        -- Read one target table, then index it per name. Reading
        -- `exports[target]` per name would cross the boundary per probe and,
        -- worse, on a stopped resource would RAISE on some names and not others
        -- -- so which names are reported as missing would depend on which of
        -- them happened to raise.
        local okTarget, targetExports = pcall(function()
            return exports[target]
        end)
        for _, name in ipairs(required) do
            local present = false
            if okTarget and targetExports then
                -- The VALUE, not the absence of an error. Indexing a missing
                -- export in FiveM answers nil rather than raising, so a bare
                -- `pcall` around the index records "yes, present" for every
                -- target ever seen -- which is the same mistake that let an
                -- oxmysql adapter take its `single` branch against a build that
                -- had no `single`.
                local okName, fn = pcall(function()
                    return targetExports[name]
                end)
                present = okName and fn ~= nil
            end
            if not present then
                missing[#missing + 1] = tostring(name)
            end
        end
        if #missing > 0 then
            print(('[cis_bridge] %s: %s is started but exposes no %s export; not registered')
                :format(slot, target, table.concat(missing, ' or ')))
            return false
        end
    end
    if type(exportName) ~= 'string' or exportName == '' then
        error(('Bridge.register(%s) needs the export name of the calling adapter'):format(slot), 2)
    end
    local provider = GetCurrentResourceName() .. ':' .. exportName
    local ok, why = exports['cis_libs']:RegisterCapability(slot, provider)
    if not ok then
        print(('[cis_bridge] %s: registration REFUSED -- %s'):format(slot, tostring(why)))
        return false
    end
    registered[slot] = target
    print(('[cis_bridge] %s: %s registered'):format(slot, target))
    return true
end

--- What this resource actually registered. The conformance runner reads it, and
--- so does the boot report: "cis_bridge is installed but registered nothing" is
--- a very different sentence from "cis_bridge is not installed".
function Bridge.registered()
    return registered
end

-- The method table each adapter registered, kept here so the conformance runner
-- can test THIS RESOURCE'S OWN CODE rather than whatever capability happens to
-- be answering.
--
-- This is not tidiness. cis_libs routes `Cis.inventory.count` to the
-- `inventory` slot, which cis_core owns, and cis_bridge fills the
-- `inventoryProvider` slot underneath it -- so a conformance suite that calls
-- `Cis.inventory.*` is testing cis_core, and on a server without cis_core
-- installed it reports four failing inventory adapters on a perfectly healthy
-- bridge. Testing the adapter directly is also the more honest question: "does
-- ox_inventory answer the way we assumed" is a fact about ox_inventory, and it
-- should not change because somebody's service layer is missing.
local adapters = {}

--- Publish an adapter's method table after it has registered.
---
--- Called by the adapter itself, immediately after `Bridge.register` answers
--- true, so the two cannot drift: an adapter that registers without publishing
--- is simply absent from the conformance run, and an adapter that publishes
--- without registering is a row that reports on a capability nobody holds.
function Bridge.publish(slot, methods)
    if type(methods) ~= 'table' then
        error(('Bridge.publish(%s) needs the adapter method table'):format(slot), 2)
    end
    adapters[slot] = methods
end

--- The method table registered for a slot, or nil.
function Bridge.adapterFor(slot)
    return adapters[slot]
end

--- The configured third-party names, read through cis_libs so this resource has
--- no config file of its own and cannot disagree with the operator's.
---
--- Read fresh each call rather than cached: an operator editing a config and
--- restarting one resource is a normal thing to do, and a cached answer makes
--- the second restart behave differently from the first for no visible reason.
function Bridge.configured(key)
    local ok, summary = pcall(function()
        return exports['cis_libs']:GetConfigSummary()
    end)
    if not ok or type(summary) ~= 'table' then
        return nil
    end
    return summary[key]
end
