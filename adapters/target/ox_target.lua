-- ox_target adapter.
--
-- These calls used to live in cis_libs's client/target.lua, in the same file as
-- the abstraction they served. That was the defect: "support a third target"
-- meant editing the file that owned the abstraction, so the abstraction and the
-- thing it abstracted over had to be understood together to change either.
--
-- The shape cis_libs hands over is a plain spec table:
--   { zoneType, name, coords, size, rotation, debug, targetOptions, options }
-- and what it expects back is `ok[, reason]` from create and remove, plus a
-- boolean from exists. Nothing here knows anything about zones.

local Adapter = {}

function Adapter.available()
    return GetResourceState('ox_target') == 'started'
end

function Adapter.name()
    return 'ox_target'
end

-- ox_target's removeZone and removeLocalEntity return NOTHING at all, so their
-- return value cannot be used as a success flag. This adapter therefore keeps
-- its own record of what it created, and reports success from that.
--
-- It is the PROVIDER's record rather than the library's, which is the right way
-- round: only this side can see whether the provider call actually landed. The
-- abstraction keeps its own spec map for a different reason -- deciding what to
-- remove -- and the two are deliberately separate.
local created = {}

function Adapter.create(spec)
    if not spec or type(spec.name) ~= 'string' then
        return false, 'no spec'
    end
    local options = spec.targetOptions and spec.targetOptions.options or {}
    local ok, err = pcall(function()
        if spec.zoneType == 'sphere' then
            exports.ox_target:addSphereZone({
                name = spec.name,
                coords = spec.coords,
                radius = spec.size,
                options = options,
                debug = spec.debug,
            })
        elseif spec.zoneType == 'box' then
            exports.ox_target:addBoxZone({
                name = spec.name,
                coords = spec.coords,
                size = spec.size,
                rotation = spec.rotation or 0,
                options = options,
                debug = spec.debug,
            })
        elseif spec.zoneType == 'ped' then
            exports.ox_target:addLocalEntity(spec.options and spec.options.entity, options)
        else
            error(('unknown zoneType %s'):format(tostring(spec.zoneType)))
        end
    end)
    if not ok then
        return false, tostring(err)
    end
    created[spec.name] = spec.zoneType
    return true
end

function Adapter.remove(name, spec, isPed)
    if not created[name] then
        return false, ('no target named %s'):format(tostring(name))
    end
    local ok, err = pcall(function()
        if isPed then
            exports.ox_target:removeLocalEntity(spec.options and spec.options.entity)
        else
            exports.ox_target:removeZone(name)
        end
    end)
    -- The record is cleared on failure as well as on success. A half-removed
    -- target that we still believe in is a leak: the abstraction will keep
    -- offering to remove something that no longer exists, and a resource that
    -- creates and destroys a zone on a loop will grow the map without bound.
    created[name] = nil
    if not ok then
        return false, tostring(err)
    end
    return true
end

function Adapter.exists(name)
    return created[name] ~= nil
end

exports('CisBridgeTargetOx', function()
    return Adapter
end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        return
    end
    Bridge.register('target', 'ox_target', Bridge.configured('target'), 'addSphereZone', 'CisBridgeTargetOx')
end)
