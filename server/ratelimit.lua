-- A per-source cooldown, on its own so it can be tested without a server.
--
-- It is one file for the same reason `adapters/discord/embed.lua` is: the thing
-- it guards is a security control, and a security control that can only be
-- exercised on a live server is a control nobody has tested. A cheat menu can
-- fire a net event thousands of times a second, and the only thing standing
-- between that and a console scrolling at the same rate is the eight lines
-- below -- so they get their own file and their own suite.
--
-- WHAT IT IS FOR
--
-- `cis_bridge:server:conformanceResults` is answered by a net event, so any
-- connected player may send it, as fast as they like, with any payload. Each
-- accepted call prints up to 64 lines into the server console. The server console
-- is the operator's only window onto a running server, so a player who fires this
-- in a loop does not break the server -- they bury the one command an operator has
-- for finding out what is wrong with it, which is strictly worse.
--
-- WHY NOT FIVE M's OWN BUILT-IN LIMITS
--
-- They exist and they do cap the byte rate. They do not stop the printing: five
-- seconds of a spammer is still five seconds of console at the top of the log,
-- and the report an operator asked for is somewhere underneath it. A cooldown
-- that refuses the CALL is the control; a rate limit that drops the bytes is
-- only the backstop.
--
-- WHY A CLASS RATHER THAN A PLAIN TABLE
--
-- Three things that are easy to get wrong and are all of them wrong in this
-- direction -- that is, in the "the guard quietly stopped guarding" direction,
-- which is the one that matters:
--
--   - a clock, so the behaviour is testable and so a `GetGameTimer` that is
--     unavailable on this realm does not take the handler down with it;
--   - `now` clamped forward on a clock that goes backwards, because `GetGameTimer`
--     is uptime-based and a source id is reused by FiveM after a player leaves;
--   - cleanup on `playerDropped`, without which the table is a slow leak keyed by
--     a source id the server hands out again.

local Cooldown = {}
Cooldown.__index = Cooldown

--- @param opts table|nil  { intervalMs = number, clock = function }.
---   `clock` defaults to `GetGameTimer` and exists so a test can drive time
---   without sleeping, which is the difference between a suite that runs in a
---   second and one that takes five minutes.
---
---   The default is stored as `nil` and resolved at CALL time, not captured
---   here. Capturing it reads `GetGameTimer` from whatever Lua state happens to
---   be current, and on a realm where that native is absent the constructor
---   silently stores a nil -- so the first `take()` raises on `self.clock()` and
---   the guard that was supposed to close a hole becomes the thing that breaks
---   the handler. Resolving late means a native that appears later still works,
---   and a native that never appears falls back to a CLOSED guard rather than to
---   an exception.
function Cooldown.new(opts)
    opts = opts or {}
    return setmetatable({
        intervalMs = tonumber(opts.intervalMs) or 5000,
        clock = type(opts.clock) == 'function' and opts.clock or nil,
        last = {},
        -- Monotonic guard. `GetGameTimer` is uptime and FiveM recycles source ids,
        -- so a stored deadline from a PREVIOUS player can be in the future
        -- relative to the new one's first call -- and without this the new
        -- player's very first request would be refused, which is a bug that
        -- appears only on a busy server and is miserable to chase.
        now = 0,
        refusals = 0,
    }, Cooldown)
end

--- Read the clock, or give up safely.
---
--- Every failure here resolves to nil, and a nil timestamp below resolves to the
--- last value this object saw. The guard therefore stays CLOSED when the clock is
--- unavailable, which is the only direction a guard is allowed to fail in.
local function readClock(self)
    local clock = self.clock
    if clock == nil and type(GetGameTimer) == 'function' then
        clock = GetGameTimer
    end
    if type(clock) ~= 'function' then
        return nil
    end
    local ok, value = pcall(clock)
    if not ok or type(value) ~= 'number' then
        return nil
    end
    return value
end

--- Take the slot for a source, or refuse.
---
--- @return boolean allowed
function Cooldown:take(src)
    -- A non-integer source is not a player and not a number this table can key
    -- on. Refusing is the safe direction: the only caller that can produce one is
    -- already handling a malformed packet, and allowing it would key the table on
    -- a table.
    if type(src) ~= 'number' or src ~= src then
        self.refusals = self.refusals + 1
        return false
    end
    local now = readClock(self) or self.now
    if now < self.now then
        now = self.now
    end
    self.now = now
    local next = self.last[src]
    if next ~= nil and now < next then
        self.refusals = self.refusals + 1
        return false
    end
    self.last[src] = now + self.intervalMs
    return true
end

--- Forget a source. Called from `playerDropped`.
function Cooldown:forget(src)
    self.last[src] = nil
end

--- How many calls have been refused since the resource started.
function Cooldown:refused()
    return self.refusals
end

--- How many sources are currently held. The boot report prints it when it is not
--- zero, because a non-zero number here means somebody was talking to a handler
--- they should not have been able to reach.
function Cooldown:held()
    local n = 0
    for _ in pairs(self.last) do
        n = n + 1
    end
    return n
end

return Cooldown