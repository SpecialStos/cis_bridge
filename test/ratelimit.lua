-- Tests for the per-source cooldown.
--
-- This is the guard on the only player-reachable surface in the resource: a net
-- event any connected player may fire, which prints up to 64 lines per call
-- into the console an operator reads. A guard that has never been tested is a
-- guard that was removed by accident three refactors ago, and the clock it
-- depends on is exactly the kind of thing that stops being called.

local passed, failed = 0, 0
local failures = {}

-- One clock, driven by several cases below.
local up = 0

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
end

local Cooldown = dofile('server/ratelimit.lua')

-- ======================================================== 1. the guard guards
--
-- The single assertion the whole file exists for. Without it, "rate limited" is
-- a comment.
local clock = 0
local c = Cooldown.new({ intervalMs = 5000, clock = function() return clock end })

check(c:take(7) == true, 'the first call from a source is allowed')
local allowed = 0
for _ = 1, 10000 do
    if c:take(7) then allowed = allowed + 1 end
end
check(allowed == 0, 'ten thousand further calls in the same instant are ALL refused')
check(c:refused() >= 10000, 'and every refusal is counted')
check(c:held() == 1, 'one source is held')

clock = 4999
check(c:take(7) == false, 'still refused one millisecond before the window closes')
clock = 5000
check(c:take(7) == true, 'allowed again the moment the window closes')

-- ================================================= 2. per SOURCE, not global
--
-- A global guard would let one player lock every other player out of the
-- report, which turns a flood control into a denial of service on the feature.
local a = Cooldown.new({ intervalMs = 5000, clock = function() return clock end })
check(a:take(1) == true, 'player 1 is allowed')
check(a:take(2) == true, 'player 2 is allowed in the same instant')
check(a:take(1) == false, 'player 1 is still refused')
check(a:take(2) == false, 'player 2 is still refused')

-- ========================================= 3. cleanup, and the leak it prevents
check(a:held() == 2, 'two sources are held before cleanup')
a:forget(1)
check(a:held() == 1, 'forgetting one source drops exactly that one')
check(a:take(1) == true, 'and that source may call again immediately')
check(a:take(2) == false, 'while the other is still inside its window')

-- ================================== 4. A RECYCLED SOURCE ID, WHICH FIVEM DOES
--
-- FiveM hands the same server id to a different player after someone leaves.
-- Without `forget`, that new player's FIRST request lands inside the previous
-- player's window and is refused -- a bug that appears only on a busy server and
-- looks exactly like "the conformance results sometimes do not arrive".
local d = Cooldown.new({ intervalMs = 5000, clock = function() return clock end })
d:take(3)
d:forget(3)
check(d:take(3) == true, 'a reused source id is not blocked by the previous player')

-- ================= 5. A CLOCK THAT GOES BACKWARDS A LONG WAY
--
-- `GetGameTimer` is uptime. It does not go backwards on a running server, but a
-- mocked engine, a restored backup, or a realm where the answer is 0 would all
-- hand this a smaller number than it saw before, and then EVERY stored deadline
-- is suddenly far in the future.
--
-- Without the monotonic clamp that is not "a guard that stays closed" -- it is a
-- guard that stays closed for the whole remaining horizon of the OLD clock. Two
-- sources recorded at t=100000 would both be refused until the clock climbed back
-- to 105000, which on a reset clock is never. So the answer is not "it refuses"
-- but "it refuses only what is genuinely inside its own window, right now".
--
-- The earlier version of this test moved the clock backwards while holding ONE
-- source, and passed whether or not the clamp existed: `now < next` is true for
-- any smaller number, so the naive comparison refused anyway and the assertion
-- proved nothing. The case the clamp is FOR is many sources spread across a long
-- horizon, which is what this is.
local mono = Cooldown.new({ intervalMs = 5000, clock = function() return up end })
up = 0
check(mono:take(1) == true, 'a source is allowed at the start')
up = 100000
check(mono:take(2) == true, 'a second source is allowed a hundred seconds later')
check(mono:take(2) == false, 'and is inside its own window')
-- The clock resets to zero. Both deadlines -- 5000 and 105000 -- are now in the
-- future as far as a naive comparison is concerned.
up = 0
check(mono:take(1) == true,
    'a source whose window genuinely expired is allowed immediately after a clock reset')
check(mono:take(2) == false,
    'while a source that really is inside its window is still refused')

-- And the small case, which the naive comparison happens to get right and is
-- worth pinning because it is the one somebody would write the test for.
local back = -1000
local e = Cooldown.new({ intervalMs = 5000, clock = function() return back end })
check(e:take(9) == true, 'allowed at a negative timestamp')
back = -9000
check(e:take(9) == false, 'a clock that jumps backwards does not unlock the guard')
check(e:held() == 1, 'and the source stays held')

-- ============================================= 6. A CLOCK THAT IS NOT A CLOCK
--
-- `GetGameTimer` is unavailable on some realms and can answer nil through a
-- mocked or partially-loaded engine. Untonumber(nil) is nil, and arithmetic on
-- nil raises -- so the fallback is to the last value this object saw, which keeps
-- the guard CLOSED. A security control whose failure mode is "opens" is not a
-- control.
local nilClock = Cooldown.new({ intervalMs = 5000, clock = function() return nil end })
check(nilClock:take(4) == true, 'allowed when the clock answers nothing')
check(nilClock:take(4) == false, 'and still refuses the second call rather than opening')

local stringClock = Cooldown.new({ intervalMs = 5000, clock = function() return 'later' end })
check(stringClock:take(5) == true, 'allowed when the clock answers a string')
check(stringClock:take(5) == false, 'and still refuses rather than opening')

-- ================================================ 7. MALFORMED SOURCES
--
-- `source` is set by the engine and this handler is not reachable with a
-- fabricated one -- but the handler is the only thing standing between a
-- malformed packet and a table keyed by a table, and a refusal is the cheap
-- direction.
--
-- Every call goes through `pcall`, because a guard that RAISES on a malformed
-- source is not a clean failure: it takes the handler down, which is the one
-- outcome a security control must never produce. Removing the type check makes
-- `self.last[nil] = ...` raise "table index is nil", and the first version of
-- these assertions reported that as a suite crash rather than as the failure it
-- is. The CI result was red either way; the diagnostic was not.
local m = Cooldown.new({ intervalMs = 5000, clock = function() return clock end })
-- `table.unpack` rather than the global `unpack`: CfxLua is 5.4, where the
-- global is gone and only the table form exists. fengari is 5.3 and provides
-- both, so a suite written against the global passes here and raises on the
-- server -- which is the "tests pass, product breaks" shape.
local function refuses(kind, value)
    local ok, result = pcall(m.take, m, value)
    check(ok, 'a ' .. kind .. ' source does not raise')
    check(ok and result == false, 'and is refused')
end
refuses('nil', nil)
refuses('string', '7')
refuses('table', {})
refuses('NaN', 0 / 0)
refuses('boolean', true)
check(m:held() == 0, 'and none of them is retained')
check(m:take(1) == true, 'a real source is unaffected by the malformed ones')

-- ================================================= 8. DEFAULTS, NOT SURPRISES
--
-- Constructed with no options at all, which is how the handler builds it if the
-- options ever go missing. `GetGameTimer` is NOT defined in this VM, so this also
-- proves the default clock is resolved lazily and that its absence leaves the
-- guard closed rather than raising on `self.clock()`.
--
-- The previous version stored `GetGameTimer` at construction, which on a realm
-- without that native was a silent nil -- so the first call raised and the guard
-- designed to close a hole was what broke the handler. Found by this assertion,
-- not by a live server.
local defaulted = Cooldown.new()
check(type(defaulted) == 'table', 'constructed with no options')
check(defaulted.intervalMs == 5000, 'the interval defaults to five seconds')
check(defaulted.clock == nil,
    'no clock is captured at construction, so a missing native is not captured as nil')
local took, tookErr = pcall(function() return defaulted:take(1) end)
check(took, 'the first call with no clock available does not raise')
check(took and defaulted:take(1) == false,
    'and the guard is still CLOSED rather than open, which is the only safe direction')
check(defaulted:held() == 1, 'and the source is held')

-- A clock that RAISES is the same shape as one that is absent.
local boom = Cooldown.new({ intervalMs = 5000, clock = function() error('no timer here') end })
local boomOk = pcall(function() return boom:take(2) end)
check(boomOk, 'a clock that raises does not take the guard down')
check(boomOk and boom:take(2) == false, 'and the guard is closed anyway')

-- A clock that returns a table.
local badClock = Cooldown.new({ intervalMs = 5000, clock = function() return {} end })
local badOk = pcall(function() return badClock:take(3) end)
check(badOk, 'a clock answering with a table does not raise')
check(badOk and badClock:take(3) == false, 'and the guard is closed')

-- A clock that is not a function at all.
local notFn = Cooldown.new({ intervalMs = 5000, clock = 'later' })
check(notFn.clock == nil, 'a non-function clock option is discarded rather than stored')
local notFnOk = pcall(function() return notFn:take(4) end)
check(notFnOk, 'and the guard still works')

-- A zero or negative interval is STORED AS GIVEN rather than silently floored.
-- Asserted rather than left alone because the two behaviours are very
-- different: a floor hides a caller's mistake, and a caller who asked for no
-- cooldown and got one would be chasing a bug nobody can reproduce. There is no
-- safety argument for overriding it -- `intervalMs` is a constant inside this
-- resource, never operator input, so the only way to reach a wrong value is a
-- code change, and a code change should be visible.
local zero = Cooldown.new({ intervalMs = 0, clock = function() return 0 end })
check(zero.intervalMs == 0, 'an interval of zero is stored as given')
check(zero:take(1) == true, 'and a zero interval means the first call is allowed')
local neg = Cooldown.new({ intervalMs = -1000, clock = function() return 0 end })
check(neg.intervalMs == -1000, 'a negative interval is stored as given')
check(neg:take(1) == true, 'and the first call is still allowed')

-- ------------------------------------------------------------------ report
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(ratelimit): ' .. failures[i] .. '\n')
end
io.write(('ratelimit passed=%d failed=%d\n'):format(passed, failed))