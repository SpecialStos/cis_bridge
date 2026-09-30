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
--- `exportName` is PER ADAPTER and that is not a style choice. Two adapters in
--- one resource registering the same export name means the second silently
--- replaces the first, so whichever file happened to load last answers for
--- every capability -- and a server with ox_target and no qb-target would end
--- up being served by whichever qb adapter ran last, which fails on every call
--- and names a resource that is not even installed. One name per adapter.
---
--- @return boolean registered
function Bridge.register(slot, target, configured, probeExport, exportName)
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
    if probeExport then
        local ok, fn = pcall(function()
            return exports[target][probeExport]
        end)
        if not ok or fn == nil then
            print(('[cis_bridge] %s: %s is started but exposes no %q export; not registered')
                :format(slot, target, tostring(probeExport)))
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
