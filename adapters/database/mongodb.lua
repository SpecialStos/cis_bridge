-- mongodb adapter.
--
-- The odd one out: the capability contract is SQL-shaped (query, single,
-- insert, update) and this target is not. Rather than pretend, `query` refuses
-- and says so, and `ready` reports what it can.
--
-- It is here at all because a server running MongoDB would otherwise install the
-- bridge, find no database capability, and read that as a broken product rather
-- than an unsupported target. An adapter that says "not supported" is worth
-- more than no adapter at all.

local Adapter = {}

function Adapter.name() return 'mongodb' end

function Adapter.ready()
    local ok, connected = pcall(function()
        return exports.mongodb:isConnected()
    end)
    return ok and connected == true
end

function Adapter.query()
    return nil, 'mongodb is not a SQL driver; Cis.db.query has no mongodb equivalent'
end

function Adapter.single()
    return nil, 'mongodb is not a SQL driver; Cis.db.single has no mongodb equivalent'
end

function Adapter.scalar()
    return nil, 'mongodb is not a SQL driver; Cis.db.scalar has no mongodb equivalent'
end

function Adapter.insert()
    return nil, 'mongodb is not a SQL driver; Cis.db.insert has no mongodb equivalent'
end

function Adapter.update()
    return nil, 'mongodb is not a SQL driver; Cis.db.update has no mongodb equivalent'
end

function Adapter.transaction()
    return false, 'mongodb is not a SQL driver; Cis.db.transaction has no mongodb equivalent'
end

exports('CisBridgeDatabaseMongodb', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    Bridge.register('database', 'mongodb', Bridge.configured('database'),
        'isConnected', 'CisBridgeDatabaseMongodb')
end)
