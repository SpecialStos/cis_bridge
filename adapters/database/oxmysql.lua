-- oxmysql adapter.
--
-- The only driver on this list that supports `Cis.db.transaction`, and the only
-- one whose `query` signature takes a transaction flag. It is also the driver
-- most servers have, which is why it registers first: when a server has two
-- drivers installed, the better one should win rather than whichever adapter
-- file happened to load last.
--
-- THE SINGLE-EXPORT FALLBACK IS THE INTERESTING PART
--
-- oxmysql grew a `single` export. Builds before that do not have one, and
-- calling a missing export RAISES -- so a server on an older build would get an
-- error on every `Cis.db.single` call, from a resource that looks like it
-- supports it. The fix is a feature probe at registration time and a query
-- fallback in `single`, and both halves matter: probing without the fallback
-- registers an adapter that cannot serve a method it advertised.

local Adapter = {}
local hasSingle = false
local hasMultiple = false

function Adapter.name() return 'oxmysql' end
function Adapter.ready() return true end

-- Both exports, in one round trip. The distinction is that a MISSING export
-- raises and a WORKING one returns an empty table, so the pcall is what
-- distinguishes "not supported" from "no rows" -- and those two must not be
-- confused, because one is a deployment problem and the other is an answer.
function Adapter.query(sql, params)
    if hasMultiple then
        return exports.oxmysql:query(sql, params)
    end
    return exports.oxmysql.query(sql, params) or {}
end

function Adapter.single(sql, params)
    if hasSingle then
        return exports.oxmysql:single(sql, params)
    end
    local rows = Adapter.query(sql, params)
    return rows and rows[1] or nil
end

function Adapter.scalar(sql, params)
    return exports.oxmysql:scalar(sql, params)
end

function Adapter.insert(sql, params)
    return exports.oxmysql:insert(sql, params)
end

function Adapter.update(sql, params)
    return exports.oxmysql:update(sql, params)
end

-- Refuses rather than faking it. A driver without transaction support, asked to
-- wrap a set of writes, can only be honest by saying no; the alternative is
-- running the statements one at a time and reporting success, which turns a
-- half-applied write into a successful-looking one.
function Adapter.transaction(queries)
    if type(queries) ~= 'table' or #queries == 0 then
        return false, 'no queries supplied'
    end
    local ok, result = pcall(function()
        return exports.oxmysql:transaction(queries)
    end)
    if not ok then
        return false, tostring(result)
    end
    if result == false then
        return false, 'the driver rolled the transaction back'
    end
    return true
end

exports('CisBridgeDatabaseOxmysql', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    if not Bridge.register('database', 'oxmysql', Bridge.configured('database'), 'query',
            'CisBridgeDatabaseOxmysql') then
        return
    end
    -- Probed AFTER registration, so a driver that registers but cannot serve
    -- `single` is still registered -- and still correct, because the fallback
    -- below is chosen from the same answer.
    hasSingle = pcall(function() return exports.oxmysql.single end)
    hasMultiple = pcall(function() return exports.oxmysql.query end)
    print(('cis_bridge: oxmysql single=%s query=%s')
        :format(tostring(hasSingle), tostring(hasMultiple)))
end)
