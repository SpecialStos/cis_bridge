-- Tests for the adapters themselves.
--
-- WHY THESE EXIST, WHEN THE COMMENT AT THE TOP OF test/bridge.lua SAYS ADAPTERS
-- ARE TOO THIN TO TEST
--
-- That comment was right about the CALLS and wrong about the FILE. Each adapter
-- is one line of `exports.ox_inventory:GetItemCount(src, item)` wrapped in
-- exactly one decision: which of two sufficient exports to use, what shape the
-- third party's refusal takes, and what to do with the two key names the
-- platform and the driver each call the same thing by. Those decisions are where
-- every bug in this resource has lived, and each of them is invisible to a live
-- server -- the server has one oxmysql and it answers, so the question "which
-- key would it have used" never arises until the transaction silently binds
-- nothing on somebody else's build.
--
-- So the mocks here are shaped to ask the QUESTION rather than to exercise the
-- call: the fake oxmysql records the exact table it was handed, and the test
-- asserts on that table. If the normalisation in the adapter is deleted, the
-- recorded table loses its `values` and a FAIL appears -- which is the mutation
-- gate this project's charter asks for, achieved without a mutation framework.

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

-- ===========================================================================
--  THE HARNESS
--
--  Loads one adapter file against a fake engine, runs the thread it starts, and
--  hands back what it exported. `exports` is both callable (that is how an
--  adapter declares its export) and indexable (that is how an adapter reaches a
--  third party), so it is a table with a metatable.
-- ===========================================================================

local started = {}
local registrations = {}
local configSummary = {}
local registerFails = false

-- A clock the suite drives. `Bridge.register` waits for a target to start, so
-- without this every adapter load either waits out the real window -- sixty
-- seconds per non-started target -- or, if `GetGameTimer` is missing entirely,
-- raises inside the registration helper and takes the whole suite down with a
-- message that reads like a product bug rather than a missing stub.
local clock = 0
_G.GetGameTimer = function() return clock end
_G.Wait = function(ms) clock = clock + (tonumber(ms) or 0) end

-- Whatever an adapter hands a third party is asserted on directly, by having
-- the fake record the exact table it was given. This is the whole technique:
-- the interesting question is almost never "what did it answer", it is "what
-- did it ask for" -- and a fake that only returns a value cannot answer it.

local function fakeExports()
    return setmetatable({
        cis_libs = {
            WaitReady = function() return true end,
            GetConfigSummary = function() return configSummary end,
            RegisterCapability = function(_, slot, provider)
                if registerFails then
                    return false, ('capability %q is already registered by someone else'):format(slot)
                end
                registrations[#registrations + 1] = { slot = slot, provider = provider }
                return true
            end,
            GetCapabilities = function() return {} end,
        },
    }, {
        __call = function(_, name, fn)
            _G.__declared[name] = fn
        end,
    })
end

_G.__declared = {}

local function loadAdapter(rel, thirdParty, opts)
    opts = opts or {}
    _G.__declared = {}
    _G.exports = fakeExports()
    _G.GetResourceState = function(name) return started[name] or 'stopped' end
    _G.GetCurrentResourceName = function() return 'cis_bridge' end
    _G.GetResourceMetadata = function(_, _, _) return '2.2.0' end
    registrations = {}
    for name, tbl in pairs(thirdParty or {}) do
        _G.exports[name] = tbl
        started[name] = 'started'
    end
    -- The thread is captured, not started. Running it during load would do the
    -- registration before the test could set up its expectations, and the order
    -- would be a hidden dependency between the test file and the adapter.
    --
    -- `opts.runThread` exists for the one adapter whose thread is a polling
    -- loop: the Discord drain thread never returns, so running it here would
    -- hang the suite forever rather than test anything.
    local body
    _G.CreateThread = function(fn) body = fn end
    dofile(rel)
    if body and opts.runThread ~= false then
        body()
    end
    return _G.__declared
end

-- ===========================================================================
--  1. THE TRANSACTION BIND KEY
--
--  The single most consequential bug found in this resource, and the reason this
--  file exists.
--
--  cis_libs documents a transaction entry as `{ query = sql, params = {...} }`.
--  oxmysql's own type is `{ query, parameters?, values? }` -- there is no
--  `params` -- and its parser reads `query.parameters or query.values`, falling
--  back to the transaction's OUTER parameter array when it finds neither.
--
--  So an entry written to the documented contract is not rejected. It is
--  ignored, every `?` in it goes unbound, and the transaction reports success.
--  The write lands on whatever row the unbound placeholder resolved to, or fails
--  at the driver, and both look like somebody else's bug for weeks.
-- ===========================================================================

-- A fake oxmysql shaped like the real one: it takes the array, and the test
-- reads back exactly what arrived. `transactions` keeps the last call.
local lastTransaction = nil
local fakeOxmysql = {
    query = function() return {} end,
    single = function() return {} end,
    scalar = function() return 1 end,
    insert = function() return 1 end,
    update = function() return 1 end,
    transaction = function(_, queries)
        lastTransaction = queries
        return true
    end,
}

local oxmysqlExports = loadAdapter('adapters/database/oxmysql.lua', { oxmysql = fakeOxmysql })
local oxAdapter = oxmysqlExports.CisBridgeDatabaseOxmysql and
    oxmysqlExports.CisBridgeDatabaseOxmysql()
check(type(oxAdapter) == 'table', 'the oxmysql adapter exports its method table')
check(oxAdapter and registrations[1] and registrations[1].slot == 'database',
    'the oxmysql adapter registers the database slot')

-- The three spellings, each asserted to arrive as `values`.
lastTransaction = nil
local ok1 = oxAdapter.transaction({ { query = 'SELECT ?', params = { 1 } } })
check(ok1 == true, 'a transaction written with the documented `params` key succeeds')
check(lastTransaction and lastTransaction[1] and lastTransaction[1].values ~= nil,
    '`params` is translated into the key oxmysql actually reads')
check(lastTransaction and lastTransaction[1] and lastTransaction[1].values
    and lastTransaction[1].values[1] == 1, 'and the bind value survives the translation')

lastTransaction = nil
oxAdapter.transaction({ { query = 'SELECT ?', values = { 2 } } })
check(lastTransaction and lastTransaction[1].values and lastTransaction[1].values[1] == 2,
    '`values` is passed through untouched')

lastTransaction = nil
oxAdapter.transaction({ { query = 'SELECT ?', parameters = { 3 } } })
check(lastTransaction and lastTransaction[1].values and lastTransaction[1].values[1] == 3,
    '`parameters` is passed through untouched, under the key oxmysql reads last')

-- Precedence, which is the order oxmysql itself reads them in. A caller who set
-- two keys gets the same answer here as it would have got there.
lastTransaction = nil
oxAdapter.transaction({ { query = 'SELECT ?', params = { 1 }, values = { 2 } } })
check(lastTransaction and lastTransaction[1].values and lastTransaction[1].values[1] == 2,
    '`values` wins over `params`, matching oxmysql\'s own precedence')

-- The array form is NOT normalised. oxmysql also accepts `{ sql, { binds } }`
-- where entry[2] is an OBJECT mapping named placeholders, and rewriting it into
-- `values` would destroy the object. What reaches the driver is the SAME table.
lastTransaction = nil
local named = { id = 7 }
local arrayForm = { 'SELECT :id', named }
oxAdapter.transaction({ arrayForm })
check(lastTransaction and lastTransaction[1] == arrayForm,
    'the [sql, binds] array form is passed through as the same table')
check(lastTransaction and lastTransaction[1] and lastTransaction[1].values == nil,
    'and is not rewritten into a `values` entry')
check(lastTransaction and lastTransaction[1] and lastTransaction[1][2] == named,
    'and its bind object arrives as the same table')

-- A bare SQL string is oxmysql's own shorthand.
lastTransaction = nil
oxAdapter.transaction({ 'SELECT 1' })
check(lastTransaction and lastTransaction[1] == 'SELECT 1',
    'a bare SQL string passes through')

-- REFUSALS, CHECKED BEFORE THE DRIVER OPENS A TRANSACTION
local refused, why = oxAdapter.transaction({})
check(refused == false, 'an empty transaction is refused')
check(type(why) == 'string', 'the empty refusal has a reason')

lastTransaction = nil
local badEntry, badWhy = oxAdapter.transaction({ { notAQuery = true } })
check(badEntry == false, 'an entry with no query is refused')
check(type(badWhy) == 'string' and badWhy:find('1') ~= nil,
    'the refusal names the index of the offending entry')
check(lastTransaction == nil, 'and the driver was never called')

local secondBad, secondWhy = oxAdapter.transaction({ { query = 'SELECT 1' }, { nope = 1 } })
check(secondBad == false, 'a bad entry at position 2 is refused')
check(type(secondWhy) == 'string' and secondWhy:find('2') ~= nil,
    'and it is reported as position 2, not position 1')

local wrongType, wrongWhy = oxAdapter.transaction({ { query = 'SELECT 1' }, 42 })
check(wrongType == false, 'a non-table, non-string entry is refused')
check(type(wrongWhy) == 'string' and wrongWhy:find('2') ~= nil, 'and named by index')

-- The ROLLBACK path. `false` from the driver is not a crash and not a success,
-- and it must not be reported as either.
fakeOxmysql.transaction = function() return false end
local rolled, rolledWhy = oxAdapter.transaction({ { query = 'SELECT 1' } })
check(rolled == false, 'a rolled-back transaction is reported as a failure')
check(type(rolledWhy) == 'string', 'and the reason says the driver rolled it back')
fakeOxmysql.transaction = function(_, queries)
    lastTransaction = queries
    return true
end

-- ===========================================================================
--  2. THE ox_inventory COUNT DECISION
--
--  `GetItemCount` answers 0 for an item the player does not have AND 0 for an
--  inventory that does not exist. `Search(inv, 'count', item)` answers 0 in the
--  first case and FALSE in the second.
--
--  A caller asking "does this player hold three of X" gets 0 from one and nil
--  from the other, and nil reads as "I could not tell" -- so on the Search path a
--  player who has not finished spawning looks like an inventory outage.
-- ===========================================================================

local oxInvCalls = {}
local fakeOxInv = {
    GetItemCount = function(_, src, item)
        oxInvCalls[#oxInvCalls + 1] = 'GetItemCount'
        return 0
    end,
    -- Shaped like the real thing, because the two branches it takes are the
    -- whole point: a numeric source is a loaded inventory, so a missing item is
    -- ZERO; anything else is an inventory that does not exist, so FALSE.
    Search = function(_, src, search, item)
        oxInvCalls[#oxInvCalls + 1] = 'Search'
        return type(src) == 'number' and 0 or false
    end,
    AddItem = function() return true end,
    RemoveItem = function() return true end,
    CanCarryItem = function() return true end,
}

local oxInvExports = loadAdapter('adapters/inventory/ox_inventory.lua',
    { ox_inventory = fakeOxInv })
local oxInvAdapter = oxInvExports.CisBridgeInventoryOx and oxInvExports.CisBridgeInventoryOx()

oxInvCalls = {}
check(oxInvAdapter and oxInvAdapter.count(0, 'bread') == 0,
    'a missing item counts zero when GetItemCount answers')
check(oxInvCalls[1] == 'GetItemCount', 'and GetItemCount is the export that was asked')
check(oxInvAdapter and oxInvAdapter.name() == 'ox_inventory', 'the ox adapter names itself')
check(oxInvAdapter and oxInvAdapter.available() == true, 'and reports itself available')

-- A player mid-spawn is the case that matters: nil must stay nil. Zero would
-- mean "they hold none", and that reading gates every dupe check in the platform.
oxInvCalls = {}
check(oxInvAdapter.count(nil, 'bread') == nil, 'a nil source is nil, never zero')
check(oxInvAdapter.count(0, nil) == nil, 'a nil item is nil, never zero')

-- The FALLBACK path, on a build with no GetItemCount. It has to answer 0 where
-- the driver says 0 and nil where the driver says false.
fakeOxInv.GetItemCount = nil
started.ox_inventory = 'started'
local oxInvFallback = loadAdapter('adapters/inventory/ox_inventory.lua',
    { ox_inventory = fakeOxInv })
local fallbackAdapter = oxInvFallback.CisBridgeInventoryOx and
    oxInvFallback.CisBridgeInventoryOx()
check(fallbackAdapter and fallbackAdapter.count(0, 'bread') == 0,
    'the Search fallback still answers 0 for an item the player does not have')
check(fallbackAdapter and fallbackAdapter.count('not-a-number', 'bread') == nil,
    'and answers nil, not 0, where Search answers false for a missing inventory')

-- ===========================================================================
--  3. THE DISCORD EMBED
--
--  The second bug this file exists to prevent. `"footer":{}` is a 400 from
--  Discord on every message, which the adapter recorded as an unhappy endpoint
--  and the operator saw as a webhook that "stopped working some time ago".
--
--  The assertion is on the STRUCTURE rather than on the exact payload, because
--  the rule is not "this footer" but "no optional section is included empty".
-- ===========================================================================

local DiscordEmbed = dofile('adapters/discord/embed.lua')
local embed = DiscordEmbed.build('cis_libs [boot]', 'a message', 'red', '2.2.0')

local embedBody = embed.embeds and embed.embeds[1]
check(type(embedBody) == 'table', 'the builder returns an embed body')

-- Recursive: no table ANYWHERE in the payload may be empty, because every empty
-- object in a Discord embed is either ignored or rejected depending on which
-- key it sits under, and the whole class of bug is that nobody is sure which.
local function emptyTablesIn(value, path, out)
    if type(value) ~= 'table' then return out end
    local n = 0
    for k, v in pairs(value) do
        n = n + 1
        if type(v) == 'table' then
            if next(v) == nil then
                out[#out + 1] = path .. '.' .. tostring(k)
            else
                emptyTablesIn(v, path .. '.' .. tostring(k), out)
            end
        end
    end
    return out
end

local empties = emptyTablesIn(embed, 'payload', {})
check(#empties == 0,
    'the payload contains no empty table anywhere (Discord rejects an empty footer with a 400): '
    .. table.concat(empties, ', '))

check(embedBody.footer == nil, 'there is no footer key at all, not an empty one')
check(embedBody.author and embedBody.author.name:find('2.2.0', 1, true) ~= nil,
    'the author line carries the version')
check(embedBody.color == 16711680, 'a named colour resolves to its number')
check(DiscordEmbed.build('t', 'm', 'no-such-colour', '1').embeds[1].color
    == DiscordEmbed.colors.default,
    'an unknown colour name falls back to the default rather than to nil')

-- The queue refuses, rather than accepting, every URL it must not post to. These
-- are the refusals that keep a stock config from shipping a server's entire log
-- to whoever owns the placeholder domain.
--
-- Loaded with `runThread = false`: this adapter's CreateThread is the drain
-- loop, which never returns. Running it here would hang the suite, so the
-- export and the queue are taken and the loop is left alone -- which is fine,
-- because the loop is the one part of this file with no decision in it.
local discordExports = loadAdapter('adapters/discord/webhooks.lua', nil, { runThread = false })
local DiscordCapability = discordExports.CisBridgeDiscord and
    discordExports.CisBridgeDiscord()
check(type(DiscordCapability) == 'table', 'the discord adapter exports its method table')
check(DiscordCapability and type(DiscordCapability.log) == 'function',
    'and it answers `log`, the name cis_libs dispatches on')
check(DiscordCapability and type(DiscordCapability.depth) == 'function',
    'and it answers `depth`')

local DiscordQueue = _G.DiscordQueue
check(type(DiscordQueue) == 'table', 'the discord adapter publishes its queue')
if type(DiscordQueue) == 'table' then
    local before = #DiscordQueue.items
    -- EVERY refusal, in one place. The URL rule is the adapter's only outbound
    -- control, and each of these is a URL a stock config or a careless operator
    -- actually produces.
    local refusedUrls = {
        { nil, 'a nil webhook' },
        { '', 'an empty webhook' },
        { 'CHANGE-ME', 'the bare placeholder' },
        { 'https://discord.com/api/webhooks/CHANGE-ME/1', 'the documented placeholder URL' },
        { 'https://your-server.example/api/webhooks/1/t', 'somebody else\'s webhook host' },
        { 'https://discord.com/api/webhooks/1', 'a webhook URL with no token' },
        { 'http://discord.com/api/webhooks/1/t', 'plain HTTP' },
        { 'javascript:alert(1)', 'a javascript: URL' },
        { 'https://discord.com/api/webhooks/1/t/../../admin', 'a path with traversal in it' },
        { 12345, 'a number rather than a URL' },
        { {}, 'a table rather than a URL' },
    }
    for _, case in ipairs(refusedUrls) do
        check(DiscordQueue.push(case[1], 't', 'm', 'red', false) == false,
            'refuses ' .. case[2])
    end
    check(#DiscordQueue.items == before, 'and nothing was queued for any of them')

    -- The one thing that must be ACCEPTED. If this ever becomes false the whole
    -- adapter is dead again, and in exactly the silent way it was before: nothing
    -- queued, nothing errored, and an operator with a working webhook and no log.
    -- Webhook-SHAPED, and obviously not one. The rule is a pattern over the
    -- shape, so the positive case has to have a real shape; the token is a
    -- word rather than base64 so nobody can mistake this line for a URL
    -- somebody copied out of a working config.
    local real = 'https://discord.com/api/webhooks/1234567890/not-a-real-token'
    check(DiscordQueue.push(real, 't', 'm', 'red', false) == true,
        'a well-formed Discord webhook is accepted')
    check(#DiscordQueue.items == before + 1, 'and is queued')
    table.remove(DiscordQueue.items)

    -- The canary and ptb instances are real webhook hosts. Matching only
    -- discord.com would silently break an operator testing on them.
    check(DiscordQueue.push('https://canary.discord.com/api/webhooks/1/t', 't', 'm', 'red', false) == true,
        'the canary host is accepted')
    check(DiscordQueue.push('https://ptb.discord.com/api/webhooks/1/t', 't', 'm', 'red', false) == true,
        'the ptb host is accepted')
    check(DiscordQueue.push('https://discordapp.com/api/webhooks/1/t', 't', 'm', 'red', false) == true,
        'the legacy discordapp host is accepted')
    while #DiscordQueue.items > before do
        table.remove(DiscordQueue.items)
    end

    -- The bound. A queue that grows without limit on a server whose webhook is
    -- down is a memory leak with no operator signal, so the oldest entry is
    -- dropped and a counter rises. Depth alone looks healthy on a server that
    -- has been quietly truncating for an hour; the counter is the only thing
    -- that says so.
    for i = 1, 200 do
        DiscordQueue.push(real, 't' .. i, 'm', 'red', false)
    end
    check(#DiscordQueue.items <= 100, 'the queue is bounded')
    check(DiscordQueue.dropped > 0, 'and dropping is counted rather than silent')
end

-- ===========================================================================
--  4. THE REGISTRATION REFUSALS
--
--  An adapter that is refused has to survive being refused. First-registration-
--  wins means a second resource asking for a held slot is refused, and that is a
--  normal outcome on a server with two bridges rather than an error.
-- ===========================================================================

registerFails = true
local refusedExports = loadAdapter('adapters/database/oxmysql.lua', { oxmysql = fakeOxmysql })
check(refusedExports.CisBridgeDatabaseOxmysql ~= nil,
    'an adapter whose registration is refused still exports its method table')
registerFails = false

-- ------------------------------------------------------------------ report
-- A global rather than `os.exit(1)`, which would take the fengari state and
-- every suite after this one with it. See the note at the bottom of
-- test/bridge.lua.
_G.__suite_failed = (_G.__suite_failed or false) or (failed > 0)
for i = 1, #failures do
    io.stderr:write('FAIL(adapters): ' .. failures[i] .. '\n')
end
io.write(('adapters passed=%d failed=%d\n'):format(passed, failed))