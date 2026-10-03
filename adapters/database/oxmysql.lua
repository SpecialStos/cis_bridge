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

-- THE BIND-ARRAY KEY IS A REAL TRAP, AND IT IS SILENT.
--
-- cis_libs documents a transaction entry as `{ query = sql, params = { ... } }`
-- and that is the shape every consumer on this platform writes, because it is
-- the shape the contract tells them to write. oxmysql's own type is
--
--     TransactionQuery = { query, parameters?, values? }
--
-- -- there is no `params` -- and its parser reads `query.parameters or
-- query.values`, falling back to the transaction's OUTER parameter array when
-- neither key is present.
--
-- So `params` is not rejected. It is IGNORED. Every `?` in that statement goes
-- unbound, and there is nothing to notice: the transaction commits and reports
-- success. A migration written as `WHERE id = ?` with `params = { id }` writes
-- whichever row the unbound bind resolves to, or fails at the driver, and both
-- look like somebody else's bug.
--
-- This is exactly the class of thing an adapter exists to absorb. cis_libs
-- publishes one documented shape; oxmysql accepts two and names them
-- differently; the join between them belongs to the file that already knows
-- both sides, and nowhere else. Every accepted spelling is normalised to
-- `values`, which is the key oxmysql reads last and therefore the one that
-- always wins.
--
-- Read in the order oxmysql itself reads them, so a caller who set more than
-- one gets the same answer here as it would have got there.
local function normaliseQueries(queries)
    local out = {}
    for i = 1, #queries do
        local entry = queries[i]
        local kind = type(entry)
        if kind ~= 'table' then
            -- A bare SQL string is oxmysql's own accepted shorthand and is
            -- passed through untouched. Anything else non-table is handed on
            -- as well so the driver produces its own error message rather than
            -- a paraphrase of it.
            out[i] = entry
        elseif type(entry.query) == 'string' then
            local binds = entry.values
            if binds == nil then binds = entry.parameters end
            if binds == nil then binds = entry.params end
            out[i] = { query = entry.query, values = binds }
        else
            -- oxmysql also accepts `{ sql, { binds } }`, where entry[2] is an
            -- OBJECT mapping named placeholders. Normalising it would destroy
            -- the object, so the array form is left exactly as it arrived.
            out[i] = entry
        end
    end
    return out
end

-- Refuses rather than faking it. A driver without transaction support, asked to
-- wrap a set of writes, can only be honest by saying no; the alternative is
-- running the statements one at a time and reporting success, which turns a
-- half-applied write into a successful-looking one.
function Adapter.transaction(queries)
    if type(queries) ~= 'table' or #queries == 0 then
        return false, 'no queries supplied'
    end
    -- Checked here, before BEGIN is issued, rather than left to the driver.
    -- oxmysql opens the transaction and only then walks the array, so a
    -- malformed entry at position 7 is discovered after the connection has
    -- committed to six statements -- the rollback is the driver's, it works,
    -- and the caller's error message arrives as a raw stack from inside
    -- somebody else's resource. Naming the index costs one loop and turns an
    -- opaque driver failure into a sentence an operator can act on.
    for i = 1, #queries do
        local entry = queries[i]
        local kind = type(entry)
        if kind ~= 'table' and kind ~= 'string' then
            return false, ('entry %d is a %s; a transaction takes query tables or SQL strings')
                :format(i, kind)
        end
        if kind == 'table' and entry.query == nil and type(entry[1]) ~= 'string' then
            return false, ('entry %d has no query; a transaction entry is '
                .. '{ query = sql, params = {...} }'):format(i)
        end
    end
    local ok, result = pcall(function()
        return exports.oxmysql:transaction(normaliseQueries(queries))
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
    -- `single` and `transaction` are deliberately NOT required. Both are probed
    -- and answered below -- one has a fallback, the other a refusal -- and a
    -- build missing either is precisely the build this adapter exists to serve.
    -- Requiring them would refuse registration on the old installs the fallback
    -- was written for, which is backwards.
    if not Bridge.register('database', 'oxmysql', Bridge.configured('database'),
            { 'query', 'scalar', 'insert', 'update' },
            'CisBridgeDatabaseOxmysql') then
        return
    end
    -- Probed AFTER registration, so a driver that registers but cannot serve
    -- `single` is still registered -- and still correct, because the fallback
    -- below is chosen from the same answer.
    --
    -- The VALUE has to be captured, not just the fact that indexing did not
    -- raise. Indexing a missing export in FiveM yields nil rather than raising,
    -- so `pcall(...)` on its own recorded "yes, supported" for every build ever
    -- seen -- and the `single` branch below was taken against a driver that has
    -- no `single`, which raises on every `Cis.db.single` call. This is the exact
    -- incident the fallback exists to prevent, defeated by the probe.
    -- `Bridge.register` gets this right for the same reason.
    local okSingle, fnSingle = pcall(function() return exports.oxmysql.single end)
    hasSingle = okSingle and fnSingle ~= nil
    local okMultiple, fnMultiple = pcall(function() return exports.oxmysql.query end)
    hasMultiple = okMultiple and fnMultiple ~= nil
    print(('cis_bridge: oxmysql single=%s query=%s')
        :format(tostring(hasSingle), tostring(hasMultiple)))
    Bridge.publish('database', Adapter)
end)
