-- mysql-connector adapter.
--
-- NOT mysql-async. Both used to be named here and the promise was false: the
-- two share a name and nothing else. mysql-async exports `mysql_fetch_all`,
-- `mysql_fetch_scalar` and `mysql_execute`; this adapter calls
-- `mysql_query`, `mysql_scalar`, `mysql_insert` and `mysql_update`, which are
-- mysql-connector's. Pointed at a mysql-async server it registers -- the
-- resource is started, and the probe export is not the one that would have
-- caught this -- and then raises on the first query. Naming it accurately is
-- the difference between "not supported" and "supported, and broken".
--
-- THE CALLBACK SHAPE IS THE WHOLE PROBLEM. mysql-connector is callback-first:
-- `mysql_query(sql, params, cb)` and the answer arrives later. A library whose
-- database calls are await-style -- which every consumer's code is written
-- against -- has to bridge that, and the bridge is a promise plus a deadline.
--
-- The deadline is not optional. A driver that never calls back parks the
-- caller's coroutine FOREVER, and a coroutine parked forever is a request
-- amplifier: a consumer that retries on nil retries into a thread that cannot
-- finish. Every await below therefore has a ceiling, and answers nil at it.
--
-- `transaction` refuses. Only oxmysql supports one, and pretending otherwise
-- would mean running the statements one at a time and reporting success.

local TIMEOUT = 15000
local Adapter = {}

function Adapter.name() return 'mysql-connector' end
function Adapter.ready() return true end

-- One bridge for every shape. `settle(nil)` on a timeout is the same as a
-- driver answering with nothing, which is deliberate: a caller cannot tell
-- them apart, and pretending it can is how a missing row becomes a hang.
local function await(build)
    return promise.new(function(resolve)
        local settled = false
        local function settle(value)
            if settled then return end
            settled = true
            resolve(value)
        end
        local ok, err = pcall(build, settle)
        if not ok then
            return settle(nil)
        end
        SetTimeout(TIMEOUT, function() settle(nil) end)
    end)
end

function Adapter.query(sql, params)
    return Citizen.Await(await(function(done)
        exports['mysql-connector']:mysql_query(sql, params or {}, function(rows)
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
        exports['mysql-connector']:mysql_scalar(sql, params or {}, function(value)
            done(value)
        end)
    end))
end

function Adapter.insert(sql, params)
    return Citizen.Await(await(function(done)
        exports['mysql-connector']:mysql_insert(sql, params or {}, function(id)
            done(id)
        end)
    end))
end

function Adapter.update(sql, params)
    return Citizen.Await(await(function(done)
        exports['mysql-connector']:mysql_update(sql, params or {}, function(affected)
            done(affected)
        end)
    end))
end

-- Says no, immediately, and names what to switch to. An await-style refusal is
-- a caller holding a write lock for the length of the timeout, and the answer
-- has to arrive before that, not instead of it.
function Adapter.transaction()
    return false, 'transactions require oxmysql; this driver does not support them'
end

exports('CisBridgeDatabaseMysqlConnector', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    if Bridge.register('database', 'mysql-connector', Bridge.configured('database'),
            { 'mysql_query', 'mysql_scalar', 'mysql_insert', 'mysql_update' },
            'CisBridgeDatabaseMysqlConnector') then
        Bridge.publish('database', Adapter)
    end
end)
