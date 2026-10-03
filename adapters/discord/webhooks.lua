-- Discord webhook adapter.
--
-- Bounded, rate-limited, and it never blocks the caller: a slow or dead webhook
-- drops entries rather than growing without limit.
--
-- This is the ONLY place in the platform that makes an outbound network
-- request, which is why it is a file in cis_bridge rather than a function in a
-- library. A server owner who wants zero outbound traffic from this platform
-- has one file to reason about and one master switch
-- (Config.Printing.UseDiscordLogs) that means it.

DiscordQueue = {
    items = {},
    dropped = 0,
}

local MAX_QUEUE = 100
-- Discord accepts roughly 5 requests/5s per webhook. 1200ms is comfortably
-- under that and still lets a burst drain in seconds rather than minutes. The
-- real limit is not this number but the batch size below, which is why a
-- backlog is paced in groups rather than one message per interval.
--
-- The colour table moved to adapters/discord/embed.lua with the rest of the
-- embed builder, so that the builder and the palette it reads travel together
-- and can be loaded without the engine.

local lastSend = 0
local SEND_INTERVAL = 1200
local FAILURE_BACKOFF = 15000
local consecutiveFailures = 0

-- The operator's master switch lives in cis_core's config file, which is a
-- different Lua state, so it used to be read as a `Config` global here and was
-- therefore always nil -- and every push returned false before it queued
-- anything. The decision is not this adapter's to make: cis_libs asks for a
-- log line only when UseDiscordLogs is on, so being asked IS the switch. What
-- is left to decide here is whether the URL is real, and that is `usable`.
function DiscordQueue.enabled()
    return true
end

-- A stock config ships placeholder URLs. Posting to one of those would send
-- every log line the server ever produces to whatever third party owns that
-- placeholder, so an unconfigured URL is treated as no URL at all and the
-- message is discarded silently -- the log line itself already went to the
-- console, which is the point of having two sinks.
--
-- THE URL IS ALSO CHECKED FOR SHAPE, NOT JUST FOR BEING ABSENT.
--
-- This is the only place in the platform that makes an outbound request, and the
-- URL arrives as an ARGUMENT: `log(webhookURL, ...)`. cis_libs passes its own
-- configured links, but every other resource on the server can call this
-- capability with whatever it likes. A rule that only rejects the literal string
-- 'CHANGE-ME' means any URL that is not that string is a live request target,
-- and the resource that supplied it can point the SERVER at an address of its
-- choosing -- its own collector, an internal service, a metadata endpoint. That
-- is server-side request forgery built out of a logging adapter, and it needs
-- nothing more than a call.
--
-- So the destination is a property of the adapter, not of the caller: the only
-- host this will ever contact is Discord, and only a path that looks like a
-- webhook. Everything else is discarded before it reaches the queue, so the
-- worst outcome of a hostile caller is a dropped log line -- which is what a
-- log line is worth to a caller that should not have had one.
--
-- Discord's own hosts. An ALLOW-LIST rather than a pattern that looks for the
-- word "discord" somewhere in the string, for two reasons.
--
-- The obvious single-pattern version cannot be written correctly in a Lua
-- pattern: Lua patterns have no alternation, so `(app)` is five literal
-- characters and not a group. A hand-rolled pattern that looks right is worse
-- than a table here, because the first version of this matched NOTHING and the
-- adapter silently stopped sending -- which is the exact failure this whole file
-- was rewritten to end.
--
-- And an allow-list is the more honest shape of the rule anyway. The property
-- is "this adapter contacts Discord and nothing else", and a table says that
-- directly. A pattern has to be re-derived every time somebody adds a host, and
-- the derivation is where the mistake happens.
local ALLOWED_HOSTS = {
    ['discord.com'] = true,
    ['discordapp.com'] = true,
    ['canary.discord.com'] = true,
    ['ptb.discord.com'] = true,
}

-- The token is the part after the id. Its own character class is deliberately
-- loose -- Discord has changed it before -- but it is anchored at both ends and
-- cannot contain a slash, so the path cannot be extended past it.
local WEBHOOK_PATH = '^/api/webhooks/%d+/[%w%-%._]+$'

local function usable(url)
    if type(url) ~= 'string' or url == '' then
        return false
    end
    -- Two captures, which Lua patterns DO have. Splitting the host out and
    -- matching it against a table is what makes the host check exact: nothing
    -- that merely contains "discord" gets through, and nothing that is Discord's
    -- but unlisted is contacted.
    local host, path = url:match('^https://([^/]+)(/.*)$')
    if not host or not ALLOWED_HOSTS[host] then
        return false
    end
    return path:match(WEBHOOK_PATH) ~= nil
end

-- Built at send time, not push time: the version string is read when the batch
-- goes out, so a resource that was updated while a message sat in the queue is
-- reflected in what is sent.
--
-- The builder itself lives in adapters/discord/embed.lua, and the whole reason
-- is in that file's header: it used to be a local function here, it built a
-- `footer` object from a config table that is always empty, Discord rejected the
-- resulting `"footer":{}` with a 400 on every single message, and no test could
-- see it because a function inside this file cannot be loaded without the
-- engine. There are no cosmetics because cis_libs will not re-export webhook
-- configuration to a foreign resource, so there is nothing truthful to put in
-- one -- and an empty optional section is rejected outright.
local DiscordEmbed = require 'adapters.discord.embed'

local function embedPayload(title, message, color)
    -- cis_libs's version, not this resource's. The message says it is a
    -- cis_libs log line -- cis_libs is what calls `log` -- and stamping it with
    -- the version of the file that happens to sit on the transport is the kind
    -- of small lie that makes a bug report harder to place. Resource metadata
    -- is a public read and crosses no boundary.
    return DiscordEmbed.build(title, message, color,
        GetResourceMetadata('cis_libs', 'version', 0))
end

function DiscordQueue.push(url, title, message, color, ping)
    -- Never raises and never blocks. Logging must not be able to fail or stall
    -- the code path that produced the log line, so every refusal below is a
    -- plain false the caller is free to ignore.
    if not DiscordQueue.enabled() then
        return false
    end
    if not usable(url) then
        return false
    end
    if #DiscordQueue.items >= MAX_QUEUE then
        -- Drop the oldest: a stale INFO line is worth less than a live ERROR.
        -- The count is kept because a silently truncating queue is how a server
        -- ends up with a webhook that looks fine and is missing its warnings.
        table.remove(DiscordQueue.items, 1)
        DiscordQueue.dropped = DiscordQueue.dropped + 1
    end
    DiscordQueue.items[#DiscordQueue.items + 1] = {
        url = url,
        title = title,
        message = message,
        color = color,
        ping = ping,
    }
    return true
end

local function post(item)
    local body = json.encode(embedPayload(item.title, item.message, item.color))
    -- 200 and 204 are both success here: Discord answers 204 for a webhook
    -- with nothing to render. Treating 204 as a failure would put a server
    -- that posts a filtered-out log into a permanent backoff.
    PerformHttpRequest(item.url, function(status)
        if status ~= 200 and status ~= 204 then
            consecutiveFailures = consecutiveFailures + 1
        else
            consecutiveFailures = 0
        end
    end, 'POST', body, {
        ['Content-Type'] = 'application/json',
    })

    -- A separate request, not a field on the embed: Discord does not let an
    -- embed carry its own mention, so a ping is a second post to the same
    -- webhook. That is why a ping costs twice the rate-limit budget, and why
    -- the queue treats a pinged item as one item.
    if item.ping then
        PerformHttpRequest(item.url, function() end, 'POST', json.encode({ content = '@everyone' }), {
            ['Content-Type'] = 'application/json',
        })
    end
end

-- The one polling loop in this file. Two intervals:
--
--   1000ms -- how long an idle queue takes to notice the first new message.
--     Nothing happens in the body while empty, so the only cost of a shorter
--     wait is a scheduler wakeup per tick on the common case (logging on,
--     nothing to send). Nothing is lost by waiting this long either: a log line
--     that waits a second for a webhook is not late.
--
--   SEND_INTERVAL, or the backoff -- the pacing between bursts, enforced by
--     sleeping the REMAINING time rather than a fixed wait, so a batch that
--     overruns does not push the next one further out.
CreateThread(function()
    while true do
        if #DiscordQueue.items == 0 then
            Wait(1000)
        else
            local wait = SEND_INTERVAL
            if consecutiveFailures > 0 then
                -- Back off while the endpoint is unhappy instead of hammering
                -- it. Capped at 4x (60s) because an endpoint that has been
                -- down for an hour is not going to be reached by a longer
                -- wait, and a queue that backs off without limit is a queue
                -- that never recovers when the endpoint comes back.
                wait = FAILURE_BACKOFF * math.min(4, consecutiveFailures)
            end
            local since = GetGameTimer() - lastSend
            if since < wait then
                Wait(wait - since)
            else
                -- Drain in a small batch so a burst is not paced at one
                -- message per interval forever. Five is a batch, not a rate:
                -- the next burst still waits a full interval, so a server with
                -- a 100-deep backlog drains in about 24s and a server sending
                -- one line a second is unaffected.
                for _ = 1, math.min(#DiscordQueue.items, 5) do
                    if #DiscordQueue.items == 0 then
                        break
                    end
                    post(table.remove(DiscordQueue.items, 1))
                    lastSend = GetGameTimer()
                end
            end
        end
    end
end)

-- The capability table. The shape is the `discord` slot declared in cis_libs'
-- registry, and the method names are the SLOT's names.
--
-- cis_libs' lookup tries the method as written, then the name its own contract
-- string declares, then the other case -- so `log` and `Log` both resolve, and
-- this file is written in the lowercase form because that is what
-- `CisRegistry.call('discord', 'log', ...)` passes and therefore what a reader
-- greps for.
--
-- This is the FIRST return value and not a table of several methods wrapped in
-- one function, because that wrapping is what it used to be. A provider table
-- is what cis_libs calls `provider()` to obtain and then indexes by method
-- name; a table whose single key happened to be a function meant the dispatcher
-- found no `log` and answered "provider for "discord" has no method "log"",
-- with the real cause -- the names -- nowhere in the message.
local DiscordCapability = {
    log = function(webhookURL, title, message, color, ping)
        return DiscordQueue.push(webhookURL, title, message, color, ping)
    end,
    -- Depth AND cumulative drops, because depth alone looks healthy on a
    -- server that has been quietly truncating for an hour. A rising `dropped`
    -- counter is the only signal an operator gets that the webhook is not
    -- keeping up.
    depth = function()
        return #DiscordQueue.items, DiscordQueue.dropped
    end,
}

exports('CisBridgeDiscord', function()
    return DiscordCapability
end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        return
    end
    -- No `configured` argument on purpose. There is no rival Discord adapter
    -- and no operator choice to respect -- this registers on presence alone,
    -- and the only thing gating it is Config.Printing.UseDiscordLogs, which
    -- cis_libs checks BEFORE it ever reaches the capability. Being asked to log
    -- is the switch; the only thing left to decide here is whether the URL is
    -- real, and that is `usable`. Registering is not sending: a server with this
    -- installed and outbound logging off has a queue that never fills.
    --
    -- The target is THIS resource, not "Discord". `Bridge.register` proves the
    -- target is really running with `GetResourceState(target)`, and no FiveM
    -- resource is called Discord -- `DiscordConfig` is a Lua table in cis_core,
    -- not a resource. Passing that name made the presence check fail on every
    -- boot and the capability could never register, so the one adapter in this
    -- resource that has no third-party dependency was the one that never
    -- registered. The webhook sender lives here, so here is what is started.
    Bridge.register('discord', GetCurrentResourceName(), nil, nil, 'CisBridgeDiscord')
    Bridge.publish('discord', DiscordCapability)
end)
