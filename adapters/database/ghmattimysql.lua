-- ghmattimysql adapter.
--
-- Deprecated in favour of mysql-connector, and the last server running it is
-- usually a server nobody wants to touch. It is here because removing it turns
-- a working server into a broken one on the day the bridge is installed, and a
-- bridge that breaks servers is worse than a bridge that carries a legacy
-- adapter.

local TIMEOUT = 15000
local Adapter = {}

function Adapter.name() return 'ghmattimysql' end
function Adapter.ready() return true end

local function await(build)
    return promise.new(function(resolve)
        local settled = false
        local function settle(value)
            if settled then return end
            settled = true
            resolve(value)
        end
        local ok = pcall(build, settle)
        if not ok then return settle(nil) end
        SetTimeout(TIMEOUT, function() settle(nil) end)
    end)
end

function Adapter.query(sql, params)
    return Citizen.Await(await(function(done)
        exports.ghmattimysql:execute(sql, params or {}, function(rows)
            done(rows or {})
        end)
    end))
end

function Adapter.single(sql, params)
    local rows = Adapter.query(sql, params)
    return rows and rows[1] or nil
end

function Adapter.scalar(sql, params)
    return Citizen.Await(await(function(done)
        exports.ghmattimysql:scalar(sql, params or {}, function(value)
            done(value)
        end)
    end))
end

function Adapter.insert(sql, params)
    return Citizen.Await(await(function(done)
        exports.ghmattimysql:insert(sql, params or {}, function(id)
            done(id)
        end)
    end))
end

-- The slot contract is `Update(sql, params) -> affected`, a NUMBER of rows. The
-- driver was called through `execute`, whose callback yields the raw result
-- object, so every `Cis.db.update` on a ghmattimysql server handed its caller
-- an OkPacket table where a count was expected -- and a caller doing
-- `if affected > 0 then` compared a table with a number and raised.
--
-- ghmattimysql exposes `update` on newer builds and only `execute` on older
-- ones, so which one answers is a fact about the install rather than about the
-- code. Probed, with the old path kept as the fallback. This is the same
-- pattern, and for the same reason, as the oxmysql adapter's `single` probe.
local hasUpdate = false

function Adapter.update(sql, params)
    if hasUpdate then
        return Citizen.Await(await(function(done)
            exports.ghmattimysql:update(sql, params or {}, function(affected)
                done(affected)
            end)
        end))
    end
    return Citizen.Await(await(function(done)
        exports.ghmattimysql:execute(sql, params or {}, function(affected)
            done(affected)
        end)
    end))
end

function Adapter.transaction()
    return false, 'transactions require oxmysql; this driver does not support them'
end

exports('CisBridgeDatabaseGhmatti', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    -- Probe for `update` AFTER registering, on the same reasoning as the
    -- oxmysql adapter: a build that registers but can only serve `execute`
    -- still serves the contract, through the fallback above.
    local ok, fn = pcall(function() return exports.ghmattimysql.update end)
    hasUpdate = ok and fn ~= nil
    if Bridge.register('database', 'ghmattimysql', Bridge.configured('database'),
            { 'execute', 'scalar', 'insert' }, 'CisBridgeDatabaseGhmatti') then
        Bridge.publish('database', Adapter)
    end
    print(('cis_bridge: ghmattimysql update=%s execute=%s')
        :format(tostring(hasUpdate), tostring(not hasUpdate)))
end)
