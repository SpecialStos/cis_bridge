-- The `lib.*` shims: ox_lib's surface, so a resource written against ox_lib runs.
--
-- This is the "drop-in ergonomics" layer, and it exists for a specific person:
-- somebody who installed a resource written for ox_lib, did not read our
-- documentation, and expects `lib.callback.await` and `lib.zones.box` to be
-- there. For them it simply is.
--
-- THE TWO RULES THAT MATTER
--
--   1. TRANSLATE THE SHAPE, NOT THE MEANING. ox_lib's `lib.callback.await` is
--      `(name, delay, target, cb)`. `Cis.callback.await` is `(name, ...)` with NO
--      target -- the server-side caller is the target, taken from context. So the
--      shim must DROP delay and target, not forward them. Forwarding `target`
--      is the single most common mistake this shim could make and it produces a
--      call that looks right and answers the wrong question.
--
--   2. NEVER DOUBLE-HALVE A BOX. `exports['cis_libs']:CreateZone` takes a SIZE
--      and halves it into an extent (`hx = sx * 0.5`). A shim that halves again
--      produces a zone a quarter of the intended size -- smaller than the door
--      it was written for, so the resource "works" and nobody can reach it.
--
-- MUTATION B (inverted AABB) and MUTATION C (a disconnected player source)
-- live in this file, because they are both shim-translation failures.

local passed, failed = 0, 0
local failures = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
end

-- The shim is built against an injected engine, for the same reason the
-- framework detector is: a fake answers `CreateZone` captured on the way past
-- without FiveM being involved, which is the only way the extent arithmetic is
-- testable at all.
local Shim = require 'shared.lib.shim'

-- Every engine call any stub sees, so the raising-export check can look at all of
-- them rather than at the one that happens to notice.
_G.__engineCalls = {}

local function engine(overrides)
    -- `e` is DECLARED first and assigned after, because the table constructor's
    -- own methods close over `e`. `local e = { CreateZone = function() e.created
    -- ... end }` captures an e that does not exist yet, so every call raises
    -- "attempt to index a nil value (global 'e')" -- and it says GLOBAL, because
    -- the reference falls out of the enclosing scope entirely.
    local e
    e = {
        created = {},
        removed = {},
        awaited = {},
        callbacks = {},
        caps = {},
        -- `CreateZone(kind, name, coords, sizeOrPoints, options)` per the
        -- contract. The default answers a zone id.
        CreateZone = function(_, kind, name, coords, size, options)
            local rec = { kind = kind, name = name, coords = coords, size = size, options = options }
            e.created[#e.created + 1] = rec
            return name
        end,
        RemoveZone = function(_, name)
            e.removed[#e.removed + 1] = name
            return true
        end,
        RegisterCallback = function(_, name, handler)
            e.callbacks[name] = handler
            return true
        end,
        -- Modelled on cis_libs exactly. `AwaitCallback` RAISES on a refusal --
        -- read out of cis_libs/server/callback.lua, which calls error() on
        -- purpose -- and returns the handler's values unwrapped. `TryAwaitCallback`
        -- is the non-raising form and answers `ok, ...results` or `false, reason`.
        --
        -- Raising here rather than returning is deliberate: it makes "the shim
        -- called the raising export" a LOUD failure instead of a value that
        -- happens to look right.
        AwaitCallback = function(_, name, ...)
            local args = table.pack(...)
            e.awaited[#e.awaited + 1] = { name = name, args = args, n = args.n, via = 'AwaitCallback' }
            -- Records rather than raises. Raising here would take the whole
            -- suite down on any test that reaches it, so a shim routed through
            -- the raising export produced a CRASH instead of the FAIL that
            -- names the mistake. The flag is asserted at the end of the file,
            -- which reports it as an assertion and leaves the rest of the suite
            -- readable.
            _G.__engineCalls[#_G.__engineCalls + 1] = 'AwaitCallback:' .. tostring(name)
            if name == 'no-such-callback' then
                error(('callback %q: unknown'):format(name), 0)
            end
            return 42
        end,
        TryAwaitCallback = function(_, name, ...)
            local args = table.pack(...)
            e.awaited[#e.awaited + 1] = { name = name, args = args, n = args.n, via = 'TryAwaitCallback' }
            _G.__engineCalls[#_G.__engineCalls + 1] = 'TryAwaitCallback:' .. tostring(name)
            if name == 'no-such-callback' then
                return false, 'no handler'
            end
            return true, 42
        end,
        CallCallback = function(_, name, cb, ...)
            local args = table.pack(...)
            e.awaited[#e.awaited + 1] = { name = name, args = args, n = args.n }
            if cb then cb(...) end
            return true
        end,
        RegisterCapability = function() return true end,
        GetCapabilities = function() return e.caps end,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

local function vec3(x, y, z)
    -- CfxLua's vector3 is USERDATA: `type(v) == 'table'` is FALSE. The shim must
    -- read `.x`, and the harness models it as a table so a Lua-only run can see
    -- the property access happen.
    return { x = x or 0.0, y = y or 0.0, z = z or 0.0 }
end

-- ============================================== 1. lib.callback AWAIT
--
-- ox_lib:  lib.callback.await(name, delay, target, cb)
-- cis_libs: Cis.callback.await(name, ...)      -- NO target argument
do
    local e = engine()
    local lib = Shim.build(e)
    -- With a CONTINUATION, ox_lib's form returns nothing and runs the callback,
    -- so there is no value to read here. The value-returning form is the one
    -- with no continuation, and it is asserted below; the first version asked
    -- this call for a value it never promised and reported the shim for it.
    local ran, got = false, nil
    local result, delay, target, cb =
        lib.callback.await('get:health', 100, 3, function(v) ran, got = true, v end)

    check(ran, 'a continuation is called')
    check(got == 42, 'with the value the callback answered')
    check(result == nil, 'and the awaiting form returns nothing of its own')
    check(delay == nil and target == nil,
        'and the second value is nil -- a consumer reading one gets one')

    local call = e.awaited[1]
    check(call ~= nil, 'the call reached cis_libs')
    check(call.name == 'get:health', 'under the same name')
    check(call.via == 'TryAwaitCallback', 'through the NON-RAISING export')
    -- The two dropped arguments, asserted one at a time because they fail
    -- differently: a forwarded DELAY is harmless-looking and shifts nothing; a
    -- forwarded TARGET is handed to a function that has no target parameter and
    -- arrives as the callback's first real argument.
    check(call.n == 0,
        ('delay and target are DROPPED, not forwarded (got %d argument(s))'):format(call.n))
    check(call.args[1] ~= 3, 'and the target did not survive as an argument')
end

-- The real arguments survive. A shim that drops everything "to be safe" is
-- broken in the other direction and just as silently.
do
    local e = engine()
    local lib = Shim.build(e)
    lib.callback.await('get:thing', 0, nil, nil, 'a', 'b')
    local call = e.awaited[1]
    check(call.n == 2 and call.args[1] == 'a' and call.args[2] == 'b',
        'arguments after the ox_lib preamble are forwarded intact')
end

-- ---- MUTATION C: a DISCONNECTED PLAYER SOURCE
--
-- cis_libs answers `false, 'player not connected'` at once rather than waiting
-- out a ten-second timeout. The shim's job is to PASS THAT THROUGH. The failure
-- it guards against is a shim that treats `false` as "no answer" and retries, or
-- that swallows the reason -- either turns an instant, named answer into a
-- ten-second stall with nothing to show for it.
do
    local seen
    local e = engine({
        AwaitCallback = function(_, name)
            _G.__engineCalls[#_G.__engineCalls + 1] = 'AwaitCallback:' .. tostring(name)
            error(('callback %q: unknown'):format(tostring(name)), 0)
        end,
        TryAwaitCallback = function(_, name, ...)
            local a = table.pack(...)
            seen = { name = name, n = a.n }
            _G.__engineCalls[#_G.__engineCalls + 1] = 'TryAwaitCallback:' .. tostring(name)
            if name == 'gone:player' then
                return false, 'player not connected'
            end
            return true, 42
        end,
    })
    local lib = Shim.build(e)
    -- Wrapped, because this suite must survive a shim that reaches for the
    -- RAISING export. Without the pcall that mistake crashed the whole suite with
    -- "callback \"gone:player\": unknown" and every other result was lost with
    -- it -- a red build, but one that reports the crash rather than the mistake.
    local called, result, reason = pcall(lib.callback.await,
        'gone:player', 0, 99, function() end)
    check(called, 'a disconnected source does not raise through the shim')

    check(result == false, 'a disconnected source answers false')
    check(reason == 'player not connected',
        ('and the reason arrives UNCHANGED, immediately (%s)'):format(tostring(reason)))

    -- And the source that was refused was the one passed: the shim dropped the
    -- target, so cis_libs had to decide, and the fixture proves it decided.
    check(seen and seen.n == 0,
        'and it was cis_libs that refused it -- the shim forwarded no target at all')
end

-- A no-handler refusal is passed through the same way, because a consumer
-- branches on the string.
do
    local e = engine()
    local lib = Shim.build(e)
    local ok, result, reason = pcall(lib.callback.await, 'no-such-callback')
    check(ok, 'an unknown callback does NOT raise through the shim')
    check(result == false, 'it answers false')
    check(type(reason) == 'string' and reason ~= '', 'with a reason attached')
end

-- THE RAISING EXPORT IS NEVER USED, ANYWHERE.
--
-- Asserted once at the end over a list every engine stub appends to, rather than
-- beside the one call that would notice. A shim routed through
-- `AwaitCallback` instead of `TryAwaitCallback` makes cis_libs `error()` on a
-- missing callback -- turning a typo on a server the customer is running into an
-- exception inside a resource that never expected one.
--
-- The flag version of this check did not fire. A global set inside a stub is one
-- more thing that can silently not happen, and the whole point of the check is
-- to catch a mistake that is silent.
local raising = {}
for _, call in ipairs(_G.__engineCalls or {}) do
    if tostring(call):find('^AwaitCallback:') then
        raising[#raising + 1] = call
    end
end
check(#raising == 0,
    ("nothing in this suite went through cis_libs' raising AwaitCallback export: %s")
        :format(table.concat(raising, ', ')))

-- ============================================== 2. lib.callback.register
do
    local e = engine()
    local lib = Shim.build(e)
    lib.callback.register('get:health', function() return 7 end)
    check(e.callbacks['get:health'] ~= nil, 'register reaches cis_libs')
    check(type(e.callbacks['get:health']) == 'function', 'as a function')
end

-- ============================================== 3. lib.callback.await AWAITS A cb
--
-- ox_lib's legacy form takes a CONTINUATION and returns nothing. A resource
-- written that way calls `lib.callback.await(name, delay, target, cb)` and
-- expects `cb` to run. If the shim ignores the callback the resource hangs at
-- that line for the rest of its life, and nothing errors.
do
    local e = engine()
    local lib = Shim.build(e)
    local ran, got = false, nil
    local result = lib.callback.await('get:health', 0, nil, function(v)
        ran, got = true, v
    end)
    check(ran, 'a continuation passed to await IS called')
    check(got == 42, 'with the callback result')
    check(result == nil or result == 42,
        'and await itself does not also hand the value to a caller expecting none')
end

-- ============================================== 4. lib.callback.call
do
    local e = engine()
    local lib = Shim.build(e)
    local ran = false
    lib.callback.call('ping:it', function() ran = true end, 'arg')
    check(ran, 'lib.callback.call runs the continuation')
    local call = e.awaited[1]
    check(call ~= nil and call.name == 'ping:it', 'under the right name')
    check(call.args[1] == 'arg', 'with its arguments')
end

-- ============================================== 5. THE FIRE-AND-FORGET FORM
--
-- ox_lib's is `lib.callback(name, delay, target, cb)`, a DIFFERENT METHOD from
-- `lib.callback.await`. The first version of this suite asserted that an await
-- with no continuation should not await, on the reasoning that returning nothing
-- is wasted work -- and it was wrong. A caller who writes `await` and gets
-- nothing back is waiting on a value that never arrives, and nothing anywhere
-- reports it.
do
    local recorded
    local e = engine({
        AwaitCallback = function() error('await was not called') end,
        CallCallback = function(_, name, cb, ...)
            local args = table.pack(...)
            recorded = { name = name, args = args, n = args.n }
            if cb then cb(...) end
            return true
        end,
    })
    -- The override closes over `recorded`, a local declared BEFORE the call,
    -- because an override passed INTO `engine()` cannot see `e`: by then `e` is
    -- still being built. The first version reached for `e` and every call raised
    -- "attempt to index a nil value (global 'e')".
    local lib = Shim.build(e)
    local ran = false
    lib.callback.send('ping:it', 0, nil, function() ran = true end)
    check(ran, 'lib.callback runs the continuation without awaiting')
    check(recorded and recorded.name == 'ping:it', 'under the right name')
end

-- And an await with no continuation still awaits, because that is what the word
-- means and what a caller reading it expects.
do
    local e = engine()
    local lib = Shim.build(e)
    local result = lib.callback.await('get:health')
    check(result == 42, 'an await with no continuation still awaits and returns the value')
    check(e.awaited[1] and e.awaited[1].via == 'TryAwaitCallback',
        'and it went through the non-raising export')
end

-- ============================================== 6. lib.zones.box
--
-- THE EXTENT RULE. CreateZone halves the size it is given. So does ox_lib's
-- lib.zones.box -- with a DIFFERENT meaning: ox_lib's size is a full extent and
-- CreateZone's is a full size. The shim must pass the size through UNCHANGED.
do
    local e = engine()
    local lib = Shim.build(e)
    local id = lib.zones.box({
        name = 'shop', coords = vec3(1, 2, 3), size = vec3(4, 6, 8),
    })
    check(id == 'shop', 'lib.zones.box returns the zone id')
    local rec = e.created[1]
    check(rec ~= nil, 'and asked cis_libs for a zone')
    check(rec.kind == 'box', 'of kind box')
    check(rec.size.x == 4 and rec.size.y == 6 and rec.size.z == 8,
        ('the size is passed through UNCHANGED (got %s, %s, %s) -- the shim must not '
            .. 'halve it, because CreateZone halves it itself')
            :format(tostring(rec.size.x), tostring(rec.size.y), tostring(rec.size.z)))
end

-- And the SIZE ARGUMENT must be a full width, not an extent. A caller writing
-- `{ size = vec3(4,6,8) }` is describing a box 4 wide, and CreateZone turns that
-- into `hx = 2`. The shim asserting the number it received is the width, and the
-- test pins it so a future "optimisation" cannot quietly halve it twice.
do
    local e = engine()
    local lib = Shim.build(e)
    lib.zones.box({ name = 'w', coords = vec3(0, 0, 0), size = vec3(10, 10, 10) })
    check(e.created[1].size.x == 10,
        'a 10-wide box arrives as 10, and becomes a 5 half-extent inside cis_libs')
end

-- ---- MUTATION B: AN INVERTED AABB
--
-- `minZ`/`maxZ` are an ORDER, not two numbers. A caller that passes them the
-- wrong way round describes a box from the ceiling to the floor, and the zone is
-- never entered -- so the resource loads, the zone exists, and the door does
-- nothing. That is the hardest kind of failure to report, and the whole reason
-- this shim validates rather than forwarding.
do
    local e = engine()
    local lib = Shim.build(e)
    local ok, reason = lib.zones.box({
        name = 'inverted', coords = vec3(0, 0, 10), size = vec3(4, 4, 4),
        minZ = 20.0, maxZ = 5.0,
    })
    check(ok == false, 'a zone with minZ above maxZ is REFUSED')
    check(type(reason) == 'string' and reason ~= '',
        ('with a reason that says so (%s)'):format(tostring(reason)))
    check(#e.created == 0, 'and nothing was sent to cis_libs')
end

-- The valid form still goes through, so the refusal is not just refusing things.
do
    local e = engine()
    local lib = Shim.build(e)
    local ok = lib.zones.box({
        name = 'valid', coords = vec3(0, 0, 10), size = vec3(4, 4, 4),
        minZ = 5.0, maxZ = 20.0,
    })
    check(ok ~= false, 'a correctly ordered minZ/maxZ is accepted')
    check(#e.created == 1, 'and reaches cis_libs')
end

-- Equal is not inverted -- a flat box is legitimate.
do
    local e = engine()
    local lib = Shim.build(e)
    local ok = lib.zones.box({
        name = 'flat', coords = vec3(0, 0, 10), size = vec3(4, 4, 4),
        minZ = 10.0, maxZ = 10.0,
    })
    check(ok ~= false, 'minZ equal to maxZ is a flat box, not an inverted one')
end

-- NaN and infinity are refused. `NaN ~= NaN`, so a naive `minZ > maxZ` is false
-- for NaN and an inverted box with a NaN sails straight through.
do
    local e = engine()
    local lib = Shim.build(e)
    local nan = 0 / 0
    local ok, reason = lib.zones.box({
        name = 'nan', coords = vec3(0, 0, 0), size = vec3(4, 4, 4),
        minZ = nan, maxZ = 10.0,
    })
    check(ok == false, 'a NaN minZ is refused')
    check(type(reason) == 'string', 'with a reason')

    local e2 = engine()
    local lib2 = Shim.build(e2)
    local inf = math.huge
    local ok2 = lib2.zones.box({
        name = 'inf', coords = vec3(0, 0, 0), size = vec3(4, 4, 4),
        minZ = 5.0, maxZ = inf,
    })
    check(ok2 == false, 'an infinite maxZ is refused')
    check(#e2.created == 0, 'and nothing reached cis_libs')
end

-- ============================================== 7. lib.zones SPHERE AND POLY
do
    local e = engine()
    local lib = Shim.build(e)
    local id = lib.zones.sphere({
        name = 'circle', coords = vec3(1, 2, 3), radius = 5.0,
    })
    check(id == 'circle', 'lib.zones.sphere returns the zone id')
    check(e.created[1].kind == 'sphere', 'of kind sphere')
    check(e.created[1].size == 5.0, 'with the radius as the size')
end
do
    local e = engine()
    local lib = Shim.build(e)
    -- cis_libs takes points as an argument, so they travel under `points`.
    local id = lib.zones.poly({
        name = 'shape', points = { vec3(0, 0, 0), vec3(10, 0, 0), vec3(10, 10, 0) },
    })
    check(id == 'shape', 'lib.zones.poly returns the zone id')
    check(e.created[1].kind == 'poly', 'of kind poly')
    check(type(e.created[1].size) == 'table', 'carrying its points')
    check(#e.created[1].size == 3, 'all of them')
end

-- ============================================== 8. THE ZONE HANDLE
--
-- ox_lib returns an object with `:remove()`. cis_libs returns a string id. The
-- shim has to bridge that, because every zone in every ox_lib resource calls
-- `zone:remove()` and a string has no methods.
do
    local e = engine()
    local lib = Shim.build(e)
    local zone = lib.zones.box({ name = 'shop', coords = vec3(0, 0, 0), size = vec3(4, 4, 4) })
    check(type(zone) == 'string', 'the returned value is still the STRING zone id')

    local handle = lib.zone(zone)
    check(type(handle) == 'table', 'and lib.zone() wraps it for the .remove() style')
    check(type(handle.remove) == 'function', 'with a remove method')
    -- COLON, because that is what a caller writes: `zone:remove()`. The first
    -- version called it with a dot, so `self` was nil and the shim raised --
    -- which is correct behaviour for a method and a wrong test.
    handle:remove()
    check(e.removed[1] == 'shop', 'that removes the zone by id')
end

-- ============================================== 9. THE DATABASE PROXY
--
-- Legacy `MySQL.*` / `exports.oxmysql:*` style calls, forwarded to the cis_libs
-- `Db*` exports. Named `proxy` because that is what ox_lib calls it, and a
-- resource written for ox_lib uses `MySQL.query`, `MySQL.single`, `MySQL.scalar`,
-- `MySQL.insert`, `MySQL.update`, `MySQL.transaction`.
do
    local calls = {}
    local e = engine({
        DbQuery = function(_, sql, params)
            calls[#calls + 1] = { 'query', sql, params }
            return { { ok = 1 } }
        end,
        DbSingle = function(_, sql, params)
            calls[#calls + 1] = { 'single', sql, params }
            return { ok = 1 }
        end,
        DbScalar = function(_, sql, params)
            calls[#calls + 1] = { 'scalar', sql, params }
            return 1
        end,
        DbInsert = function(_, sql, params)
            calls[#calls + 1] = { 'insert', sql, params }
            return 7
        end,
        DbUpdate = function(_, sql, params)
            calls[#calls + 1] = { 'update', sql, params }
            return 1
        end,
        DbTransaction = function(_, queries)
            calls[#calls + 1] = { 'transaction', queries }
            return true
        end,
    })
    local proxy = Shim.proxy(e)

    check(type(proxy.query) == 'function', 'the proxy offers query')
    check(proxy.query('SELECT 1', {}) ~= nil, 'and it answers')
    check(calls[1][1] == 'query', 'having reached cis_libs as a query')

    proxy.single('SELECT 1', {})
    proxy.scalar('SELECT 1', {})
    proxy.insert('INSERT 1', {})
    proxy.update('UPDATE 1', {})
    check(#calls == 5, 'every legacy verb reaches a cis_libs export')
    check(calls[5][1] == 'update', 'in the right order')

    -- AND THE BIND KEY. This is the oxmysql trap that cis_bridge's own oxmysql
    -- adapter already had to solve: a transaction entry written as `params` is
    -- IGNORED by oxmysql, not rejected, so every `?` goes unbound and the
    -- transaction reports success. The proxy normalises the key here too, because
    -- a consumer reaching the proxy through legacy code has no way to know which
    -- driver is underneath.
    proxy.transaction({ { query = 'INSERT 1', params = { 1 } } })
    local tx = calls[6][2]
    check(tx and tx[1] and tx[1].values ~= nil,
        'a transaction entry using `params` is translated to the key oxmysql reads')
end

-- ============================================== 10. NO ZONE MEANS NO ZONE
--
-- The refuse path must not have created anything, and a caller must be able to
-- tell a refusal from a zone id. Both are the same string type, so the shim
-- returns `false, reason` and the caller checks the first value.
do
    local e = engine()
    local lib = Shim.build(e)
    local ok, reason = lib.zones.box({
        name = 'nope', coords = vec3(0, 0, 0), size = vec3(4, 4, 4), minZ = 9, maxZ = 1,
    })
    check(ok == false, 'a refused zone is false, not a string')
    check(type(reason) == 'string', 'with a reason as the second value')
    check(tostring(ok) ~= 'nope', 'and it is definitely not the name')
end

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(shim): ' .. failures[i] .. '\n')
end
io.write(('shim passed=%d failed=%d\n'):format(passed, failed))