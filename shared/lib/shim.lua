-- The `lib.*` shim: ox_lib's surface, over cis_libs.
--
-- WHO THIS IS FOR
--
-- Somebody who installed a resource written against ox_lib, did not read our
-- documentation, and expects `lib.callback.await` and `lib.zones.box` to be
-- there. For them it simply is.
--
-- It is a TRANSLATION LAYER AND NOTHING ELSE. No player table is stored, no
-- entity is tracked, no state is duplicated. Every call is forwarded and the
-- answer comes back untouched -- including a refusal, because a consumer
-- branching on `reason` is the whole reason a refusal carries one.
--
-- THE TWO TRANSLATIONS THAT ARE EASY TO GET WRONG
--
-- 1. CALLBACK AWAIT. ox_lib is `(name, delay, target, cb)`. cis_libs is
--    `(name, ...)` with NO target: on the server the caller IS the target and it
--    is taken from context, and on the client there is no target at all.
--    So the shim DROPS delay and target rather than forwarding them.
--    Forwarding `target` hands a value to a function that has no such parameter,
--    where it arrives as the first real argument -- a call that looks right and
--    answers the wrong question. `test/shim.lua` asserts the dropped arguments
--    did not survive, which is the only way that mistake gets caught.
--
-- 2. THE BOX EXTENT. `exports['cis_libs']:CreateZone` takes a SIZE and halves
--    it into an extent (`hx = sx * 0.5`). ox_lib's `lib.zones.box` takes a
--    full width. Both describe the same box. So the shim passes the size
--    through UNCHANGED and lets cis_libs do the one halving.
--    Halving here as well produces a zone a quarter of the intended size --
--    smaller than the thing it was written for, so the resource loads, the zone
--    exists, and nobody can reach it.
--
-- Validation is added, not removed. A shim that forwarded everything would carry
-- every caller bug through; the one case worth catching here is an inverted
-- vertical extent, because `minZ > maxZ` describes a box from the ceiling to
-- the floor, the zone is never entered, and nothing anywhere reports an error.

local Shim = {}

--- A number that is finite.
---
--- `NaN ~= NaN` and `math.huge > math.huge` is false, so a plain comparison
--- check lets both through -- and an inverted extent whose `minZ` is NaN sails
--- straight past `minZ > maxZ` while describing a box that can never be entered.
local function finite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

--- The vertical extent, validated.
---
--- Returns `true` or `false, reason`. A caller that passes neither is fine:
--- cis_libs derives it from the coords and the size.
local function validateExtent(spec, name)
    local minZ, maxZ = spec.minZ, spec.maxZ
    if minZ == nil and maxZ == nil then return true end
    if minZ == nil or maxZ == nil then
        return false, ('zone %q gives only one of minZ/maxZ; give both or neither')
            :format(tostring(name))
    end
    if not finite(minZ) or not finite(maxZ) then
        return false, ('zone %q has a minZ or maxZ that is not a finite number (minZ=%s, maxZ=%s)')
            :format(tostring(name), tostring(minZ), tostring(maxZ))
    end
    if minZ > maxZ then
        -- The sentence an operator needs, not the sentence a developer needs.
        return false, ('zone %q is inverted: minZ (%s) is ABOVE maxZ (%s), so the zone '
            .. 'runs from the ceiling to the floor and can never be entered. Pass the '
            .. 'lower one first')
            :format(tostring(name), tostring(minZ), tostring(maxZ))
    end
    return true
end

--- Build the `lib` table over an injected engine.
---
--- Injected so `test/shim.lua` can capture exactly what crossed the boundary --
--- which is the only way the two rules above are testable at all, since a real
--- CreateZone answers a zone id and tells you nothing about what it was handed.
function Shim.build(engine)
    -- EVERY engine call below is a COLON call, and the fake in test/shim.lua is
    -- written to match.
    --
    -- The real thing is `exports['cis_libs']:Name(...)`, which passes the exports
    -- table as self. A shim that called `engine.Name(...)` instead would lose that
    -- argument, every stub would receive its first real parameter one slot left,
    -- and the failure would read as "the framework is broken" on a live server.
    -- Mirroring the call shape here means getting it wrong fails in a unit suite
    -- instead.

    local lib = { callback = {}, zones = {} }

    -- ------------------------------------------------------------------
    --  lib.callback
    -- ------------------------------------------------------------------

    --- `lib.callback.register(name, handler)`
    function lib.callback.register(name, handler)
        if type(name) ~= 'string' or name == '' then
            return false, 'a callback name must be a non-empty string'
        end
        if type(handler) ~= 'function' then
            return false, ('callback %q needs a function'):format(name)
        end
        return engine:RegisterCallback(name, handler) ~= false
    end

    --- `lib.callback.await(name, delay, target, cb)` -> whatever the handler returned
    ---
    --- Or `false, reason` from cis_libs, passed through UNCHANGED. A shim that
    --- treated `false` as "no answer" and retried would turn an instant, named
    --- refusal into a ten-second stall with nothing to show for it.
    function lib.callback.await(name, delay, target, cb, ...)
        if type(name) ~= 'string' or name == '' then
            return false, 'a callback name must be a non-empty string'
        end

        -- IS THE THIRD ARGUMENT A CONTINUATION?
        --
        -- ox_lib's positional preamble means the continuation's position is not
        -- fixed: with `(name, delay, target, cb)` it is fourth, and with
        -- `(name, ...args)` -- which is what every resource that only ever uses
        -- the callback's own arguments actually writes -- there is none at all.
        -- So it is found by TYPE, and a caller who wants to pass a function as a
        -- real argument is the rarer mistake to make.
        local args = table.pack(...)
        if type(delay) == 'function' then
            cb, delay, target = delay, nil, nil
        elseif type(target) == 'function' then
            cb, target = target, nil
        end

        -- `TryAwaitCallback`, NEVER `AwaitCallback`.
        --
        -- Read out of cis_libs/server/callback.lua: `AwaitCallback` calls
        -- `error('callback %q: %s')` on a refusal, deliberately and loudly,
        -- because its result has one slot and a `false` would be
        -- indistinguishable from a handler that legitimately returned false.
        --
        -- That is the right decision for cis_libs and the WRONG ONE HERE. This
        -- shim exists so a resource written against ox_lib keeps working, and
        -- ox_lib's `lib.callback.await` ANSWERS `false` on a missing handler
        -- rather than raising. Routing it through the raising form would take a
        -- missing callback -- a typo, on a server the customer is running -- and
        -- turn it into an exception inside a resource that never expected one.
        --
        -- `TryAwaitCallback` is the non-raising form and answers `ok, ...results`
        -- on success, `false, reason` on a refusal.
        local results = table.pack(engine:TryAwaitCallback(name, table.unpack(args, 1, args.n)))
        local ok = results[1]
        if not ok then
            -- Handed back EXACTLY as received. A shim that reworded this would
            -- break every consumer branching on the string, and the string is
            -- the part that tells them what to do.
            return false, results[2]
        end
        local value = results[2]
        if cb then
            -- The legacy form answers NOTHING and runs the continuation. Calling
            -- it with every value is what ox_lib does, and a resource written
            -- that way calls `await` and waits -- so if this is dropped the
            -- resource hangs on that line for the rest of its life, silently.
            cb(value)
            return nil
        end
        return value
    end


    --- `lib.callback(name, delay, target, cb)` -- ox_lib's FIRE-AND-FORGET form.
    ---
    --- This is the one that does NOT await, and it is a different method rather
    --- than a mode of `await`. `lib.callback.await('x')` with no continuation
    --- awaits and returns the value, because that is what a caller writing it
    --- means; `lib.callback('x')` means "send it and tell me nothing".
    ---
    --- The first version of this shim had an `awaitQuiet`, on the reasoning that
    --- an await with nothing to return was wasted work. The test asserting that
    --- failed against a stub that raised on AwaitCallback -- and the stub was
    --- right: a caller who wrote `await` and got nothing would hang on the line
    --- after it. The distinction is between two METHODS, not between two modes
    --- of one.
    function lib.callback.send(name, delay, target, cb, ...)
        -- Fixed POSITIONS, matching ox_lib, rather than counting the varargs.
        -- Counting was the first version and it was wrong by one: `...` here is
        -- `(0, nil, fn)` for a call the reader sees as `(name, delay, target, cb)`,
        -- so `n >= 4` was false and the delay was forwarded as the CONTINUATION.
        -- The stub then called a number, and the error named the stub rather than
        -- the shim -- which is the worst way for a translation bug to surface.
        if type(cb) == 'function' then
            return engine:CallCallback(name, cb, ...)
        end
        return engine:CallCallback(name)
    end

    --- `lib.callback.call(name, cb, ...)`
    function lib.callback.call(name, cb, ...)
        if type(cb) ~= 'function' then
            return false, 'lib.callback.call needs a continuation'
        end
        engine:CallCallback(name, cb, ...)
        return true
    end

    -- ------------------------------------------------------------------
    --  lib.zones
    -- ------------------------------------------------------------------

    local function makeZone(kind, spec, sizeOrPoints)
        if type(spec) ~= 'table' then
            return false, 'a zone needs a spec table'
        end
        if type(spec.name) ~= 'string' or spec.name == '' then
            return false, 'a zone needs a non-empty name'
        end

        local okExtent, reason = validateExtent(spec, spec.name)
        if not okExtent then
            return false, reason
        end

        -- The coords are a vector3 -- USERDATA in CfxLua, where
        -- `type(coords) == 'table'` is FALSE. So the check is on `.x`, which
        -- works for userdata and for a plain table alike, rather than on the
        -- container.
        --
        -- NOT REQUIRED FOR A POLY. A polygon is defined by its POINTS and has no
        -- centre at all, so demanding coords of one refused every poly a caller
        -- wrote correctly -- and the refusal said "needs coords", which sends them
        -- to add a centre that does not mean anything. Validated when present,
        -- required only for the two kinds that have one.
        local coords = spec.coords
        if coords == nil then
            if kind ~= 'poly' then
                return false, ('a %s zone needs coords, and they must be a vector3')
                    :format(kind)
            end
        else
            if type(coords) ~= 'table' and type(coords) ~= 'userdata' then
                return false, ('zone %q needs coords, and they must be a vector3')
                    :format(spec.name)
            end
            if not finite(coords.x) or not finite(coords.y) or not finite(coords.z) then
                return false, ('zone %q has coords that are not finite'):format(spec.name)
            end
        end

        -- ox_lib reads size as `coords.w` for a heading and `size` for the
        -- extent; cis_libs takes `size` and the heading in options.
        local options = spec.options or {}
        if options.heading == nil and coords ~= nil and finite(coords.w) then
            options.heading = coords.w
        end
        options.debug = spec.debug
        if spec.data ~= nil then options.data = spec.data end
        if spec.onEnter then options.onEnter = spec.onEnter end
        if spec.onExit then options.onExit = spec.onExit end
        if spec.onInside then options.onInside = spec.onInside end

        local id = engine:CreateZone(kind, spec.name, coords, sizeOrPoints, options)
        if id == nil then
            return false, ('cis_libs did not return an id for zone %q'):format(spec.name)
        end
        return id
    end

    --- `lib.zones.box({ name, coords, size, ... })` -> zoneId string
    ---
    --- `size` is passed through UNCHANGED. See the header.
    function lib.zones.box(spec)
        local size = type(spec) == 'table' and spec.size or nil
        if type(size) ~= 'table' and type(size) ~= 'userdata' then
            return false, 'a box zone needs a size'
        end
        if not finite(size.x) or not finite(size.y) or not finite(size.z) then
            return false, ('box zone %q has a size that is not finite')
                :format(tostring(type(spec) == 'table' and spec.name))
        end
        -- A zero or negative half-extent is a zone nothing can be inside of.
        if size.x <= 0 or size.y <= 0 or size.z <= 0 then
            return false, ('box zone %q has a size of %s, %s, %s; every axis must be '
                .. 'positive or the zone can never be entered')
                :format(tostring(type(spec) == 'table' and spec.name),
                    tostring(size.x), tostring(size.y), tostring(size.z))
        end
        return makeZone('box', spec, size)
    end

    --- `lib.zones.sphere({ name, coords, radius, ... })` -> zoneId string
    function lib.zones.sphere(spec)
        local radius = type(spec) == 'table' and spec.radius or nil
        if not finite(radius) then
            return false, 'a sphere zone needs a numeric radius'
        end
        if radius <= 0 then
            return false, 'a sphere zone needs a positive radius'
        end
        return makeZone('sphere', spec, radius)
    end

    --- `lib.zones.poly({ name, points, ... })` -> zoneId string
    ---
    --- cis_libs takes the points in the SIZE position, because the shape IS the
    --- argument it cannot default.
    function lib.zones.poly(spec)
        local points = type(spec) == 'table' and spec.points or nil
        if type(points) ~= 'table' then
            return false, 'a poly zone needs a table of points'
        end
        if #points < 3 then
            return false, ('a poly zone needs at least three points, got %d'):format(#points)
        end
        for i, point in ipairs(points) do
            if type(point) ~= 'table' and type(point) ~= 'userdata' then
                return false, ('poly zone point %d is not a vector3'):format(i)
            end
            if not finite(point.x) or not finite(point.y) then
                return false, ('poly zone point %d is not finite'):format(i)
            end
        end
        return makeZone('poly', spec, points)
    end

    -- ------------------------------------------------------------------
    --  The `.remove()` style, which a string does not have
    -- ------------------------------------------------------------------

    --- Wrap a zone id in an object with `:remove()`, which is what every ox_lib
    --- resource calls. A bare string has no methods, and a resource that calls
    --- `zone:remove()` on one raises "attempt to index a string".
    function lib.zone(id)
        if type(id) ~= 'string' then return nil end
        local handle = { id = id }
        function handle:remove()
            return engine:RemoveZone(self.id)
        end
        function handle:contains(point)
            return engine.ZoneContains and engine:ZoneContains(self.id, point) or false
        end
        function handle:__tostring()
            return ('zone(%s)'):format(self.id)
        end
        return handle
    end

    return lib
end

--- The legacy MySQL / oxmysql surface, over cis_libs' `Db*` exports.
---
--- Named `proxy` because that is the name a resource written for ox_lib uses.
--- A pure forward: the verbs map one to one, so there is nothing to decide and
--- therefore nothing to get wrong except the ONE thing below.
function Shim.proxy(engine)
    local p = {}

    function p.query(sql, params) return engine:DbQuery(sql, params) end
    function p.single(sql, params) return engine:DbSingle(sql, params) end
    function p.scalar(sql, params) return engine:DbScalar(sql, params) end
    function p.insert(sql, params) return engine:DbInsert(sql, params) end
    function p.update(sql, params) return engine:DbUpdate(sql, params) end
    function p.prepare(sql) return sql end

    --- `proxy.transaction(queries)`
    ---
    --- AND THE BIND KEY. oxmysql's entry type is `{ query, parameters?, values? }`
    --- -- there is no `params` -- and its parser reads `parameters or values`,
    --- falling back to the transaction's OUTER parameter array when it finds
    --- neither. An entry written as `params` is therefore not REJECTED, it is
    --- IGNORED: every `?` goes unbound and the transaction reports success.
    ---
    --- Every consumer reaching this proxy through legacy code has no way of
    --- knowing which driver is underneath, so the key is normalised here rather
    --- than left to whichever one answers. It is the same normalisation the
    --- oxmysql adapter does, and it is here because a second path into the same
    --- trap is not a second reason to leave it open.
    function p.transaction(queries)
        if type(queries) ~= 'table' or #queries == 0 then
            return false, 'no queries supplied'
        end
        local out = {}
        for i = 1, #queries do
            local entry = queries[i]
            if type(entry) ~= 'table' then
                return false, ('entry %d is a %s; a transaction takes query tables')
                    :format(i, type(entry))
            end
            if type(entry.query) ~= 'string' and type(entry[1]) ~= 'string' then
                return false, ('entry %d has no query'):format(i)
            end
            if type(entry.query) == 'string' then
                -- Read in the order oxmysql reads them, so a caller who set two
                -- gets the same answer here as it would have got there.
                local binds = entry.values
                if binds == nil then binds = entry.parameters end
                if binds == nil then binds = entry.params end
                out[i] = { query = entry.query, values = binds }
            else
                -- The `[sql, binds]` array form, where binds may be an OBJECT of
                -- named placeholders. Rewriting it would destroy the object.
                out[i] = entry
            end
        end
        return engine:DbTransaction(out)
    end

    --- Aliases some resources use rather than the `MySQL.*` shape.
    p.fetchAll = p.query
    p.fetchSingle = p.single
    p.fetchScalar = p.scalar
    p.execute = p.update

    return p
end

CisBridgeLibShim = Shim

return Shim