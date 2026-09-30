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

function Adapter.update(sql, params)
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
    Bridge.register('database', 'ghmattimysql', Bridge.configured('database'),
        'execute', 'CisBridgeDatabaseGhmatti')
end)
