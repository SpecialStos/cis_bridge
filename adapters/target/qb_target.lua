-- qb-target adapter.
--
-- qb-target takes a box zone as THREE numbers and derives minZ/maxZ from the
-- centre, where ox_target takes a vector3 size. That difference is the whole
-- reason a target needs its own adapter rather than a shared implementation
-- with a flag: the arithmetic is not a parameter, it is a different API.

local Adapter = {}
local created = {}

function Adapter.available()
    return GetResourceState('qb-target') == 'started'
end

function Adapter.name()
    return 'qb-target'
end

function Adapter.create(spec)
    if not spec or type(spec.name) ~= 'string' then
        return false, 'no spec'
    end
    local options = spec.targetOptions or {}
    local ok, err = pcall(function()
        if spec.zoneType == 'sphere' then
            exports['qb-target']:AddCircleZone(spec.name, spec.coords, spec.size, {
                name = spec.name,
                debugPoly = spec.debug,
            }, options)
        elseif spec.zoneType == 'box' then
            -- A vector3 or an array, because callers write it both ways and
            -- neither is wrong. A missing component is 1.0 rather than nil,
            -- which would make the arithmetic below raise.
            local size = spec.size or {}
            local sx = size.x or size[1] or 1.0
            local sy = size.y or size[2] or 1.0
            local sz = size.z or size[3] or 1.0
            exports['qb-target']:AddBoxZone(spec.name, spec.coords, sx, sy, {
                name = spec.name,
                heading = spec.rotation or 0,
                debugPoly = spec.debug,
                minZ = spec.coords.z - sz / 2,
                maxZ = spec.coords.z + sz / 2,
            }, options)
        elseif spec.zoneType == 'ped' then
            exports['qb-target']:AddTargetEntity(spec.options and spec.options.entity, {
                options = options.options or {},
                distance = options.distance or 2.0,
            })
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
            exports['qb-target']:RemoveTargetEntity(spec.options and spec.options.entity)
        else
            exports['qb-target']:RemoveZone(name)
        end
    end)
    created[name] = nil
    if not ok then
        return false, tostring(err)
    end
    return true
end

function Adapter.exists(name)
    return created[name] ~= nil
end

exports('CisBridgeTargetQb', function()
    return Adapter
end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        return
    end
    if Bridge.register('target', 'qb-target', Bridge.configured('target'),
            { 'AddBoxZone', 'AddCircleZone', 'RemoveZone', 'AddTargetEntity', 'RemoveTargetEntity' },
            'CisBridgeTargetQb') then
        Bridge.publish('target', Adapter)
    end
end)
