-- The boot report.
--
-- WHY THIS EXISTS, IN THE ROADMAP'S OWN TERMS
--
-- Support is roughly seventy percent of this company's cost base, and about
-- €108 per customer over eighteen months. The cheapest thing that moves that
-- number is not faster code -- it is an answer that arrives without a ticket.
-- Every line below exists to be the whole of a support conversation:
--
--   "cis_bridge is installed but registered nothing"  -> cis_core is not started
--   "the configuration names qb-target"                -> start qb-target, or edit the config
--   "exposes no GetItemCount export"                   -> update qs-inventory, or switch
--
-- A report that stops at "not registered" has moved none of that cost. A report
-- that states the cause AND the next step ends the conversation.
--
-- WHEN IT PRINTS
--
-- Once, after the adapters have had their chance. Every adapter waits up to
-- Bridge.WAIT_MS for its target to start, so the report runs after the last of
-- them has either registered or given up -- printing earlier would report a
-- target that was three seconds from starting as missing, which is the same
-- wrong answer as saying it is missing for good. It then also prints on demand
-- through `cis_bridge report`, because a server that has been running for a
-- week and has just changed its config needs the answer now.
--
-- WHAT IT NEVER PRINTS
--
-- No webhook URLs, no credentials, no player identifiers, no config values.
-- It prints the NAMES of the third-party resources present, which is the
-- operator's own server.cfg and is already in their console, and nothing else.

Report = {}

local STATUS = {
    registered = { label = 'OK      ', detail = 'registered' },
    not_installed = { label = 'MISSING ', detail = 'not installed on this server' },
    not_started = { label = 'DOWN    ', detail = 'installed but not started' },
    configured_elsewhere = { label = 'OTHER   ', detail = 'the configuration names a different resource' },
    missing_export = { label = 'NO API  ', detail = 'started, but without the exports this adapter needs' },
    -- Two DIFFERENT refusals, and the distinction is the whole point. cis_libs
    -- refuses a resource that is not in `Security.AuthorizedResources` -- which is
    -- what a stock install gets, because an empty allow-list is restrictive -- and
    -- it refuses a second registrant because the slot is already held. One fix is
    -- a line of configuration and the other is stopping a resource. A single
    -- "REFUSED" row with a single sentence sends the operator the wrong way every
    -- time, and the wrong way is "find the other resource", which does not exist
    -- in the common case.
    not_authorized = { label = 'NO AUTH ', detail = 'cis_libs will not let this resource fill the slot' },
    held_elsewhere = { label = 'REFUSED ', detail = 'another resource already provides this capability' },
    refused = { label = 'REFUSED ', detail = 'cis_libs refused the registration' },
}

--- One line per adapter slot, in the fixed order Bridge.SLOTS declares.
---
--- Every row carries three things: the outcome, the sentence that explains it,
--- and the next step. A row that cannot produce a next step prints one that says
--- the slot is not required -- which is true of the discord adapter on a server
--- with outbound logging off, and is the difference between an operator reading
--- "the discord adapter is not registered" and reading "nothing is wrong here".
local function lines()
    local outcomes = Bridge.outcomes()
    local registered = Bridge.registered()
    local out = {}
    for _, entry in ipairs(Bridge.SLOTS) do
        local slot = entry.slot
        local outcome = outcomes[slot]
        if outcome and outcome.ok then
            out[#out + 1] = {
                slot = slot,
                label = STATUS.registered.label,
                target = outcome.target,
                detail = STATUS.registered.detail,
                fix = nil,
            }
        elseif outcome then
            local status = STATUS[outcome.reason] or { label = 'UNKNOWN ', detail = outcome.detail }
            out[#out + 1] = {
                slot = slot,
                label = status.label,
                target = outcome.target,
                detail = outcome.detail or status.detail,
                fix = outcome.fix,
            }
        else
            -- No outcome at all. The adapter file never reached its
            -- registration call, which means something above it raised --
            -- `WaitReady` returning false, most likely, because cis_libs itself
            -- did not become ready. That is not "not installed"; it is this
            -- resource being unable to answer, and it says so.
            out[#out + 1] = {
                slot = slot,
                label = 'UNKNOWN ',
                target = '-',
                detail = 'the adapter never ran',
                fix = 'cis_libs did not become ready, or this resource failed to start. '
                    .. 'Look above this line for the error',
            }
        end
    end
    return out, registered
end

--- Render the report. `why` is printed as a headline so a pasted console line
--- still makes sense on its own.
function Report.render()
    local rows, registered = lines()
    print('')
    print('================================ cis_bridge ================================')
    print(('cis_bridge %s -- what this resource adapted on this server')
        :format(tostring(GetResourceMetadata(GetCurrentResourceName(), 'version', 0))))
    print('')
    print('  state    slot            target')
    print('  -------  --------------  ---------------------------------------------')
    local count = 0
    for _, row in ipairs(rows) do
        count = count + (row.label == STATUS.registered.label and 1 or 0)
        print(('  %s  %-14s  %-16s %s'):format(
            row.label, row.slot, row.target, row.detail))
    end
    print('')

    -- cis_libs' own view, because ours and its can disagree and the
    -- disagreement is the interesting one. `GetCapabilities` resolves every slot
    -- to say whether a provider is there AND whether it can serve what the slot
    -- declares -- which is a stronger statement than "we called
    -- RegisterCapability and it returned true".
    local ok, caps = pcall(function()
        return exports['cis_libs']:GetCapabilities()
    end)
    if ok and type(caps) == 'table' then
        local rows2 = {}
        for slot, entry in pairs(caps) do
            if type(entry) == 'table' and entry.owner then
                rows2[#rows2 + 1] = {
                    slot = slot,
                    owner = tostring(entry.owner),
                    resolved = entry.resolved == true,
                    missing = type(entry.missing) == 'table' and entry.missing or {},
                }
            end
        end
        table.sort(rows2, function(a, b) return a.slot < b.slot end)
        if #rows2 > 0 then
            print('  capabilities cis_libs can see:')
            for _, row in ipairs(rows2) do
                print(('    %-18s %s%s'):format(row.slot, row.owner,
                    row.resolved and '' or '   [cis_libs cannot resolve this export]'))
                if #row.missing > 0 then
                    -- The single most useful line in this file. A provider that
                    -- registered but cannot serve the methods a slot declares is
                    -- a capability that raises on the first real call, and the
                    -- registration looked completely normal.
                    print(('      and cannot serve: %s'):format(table.concat(row.missing, ', ')))
                end
            end
            print('')
        end
    end

    -- The headline. One sentence, and it is the one an operator pastes into a
    -- support thread.
    if count == 0 then
        print('  Nothing on this server is being adapted.')
        print('')
        print('  That is only correct if you have no third-party resources and no')
        print('  outbound logging. If you expected something above to say OK, the')
        print('  reason is on its own line. The most common one by a distance is a')
        print('  missing `ensure cis_libs`, which cis_bridge needs in order to')
        print('  register anything at all.')
        print('')
    else
        print(('  %d of %d adapter slot(s) registered.'):format(count, #rows))
        print('')
    end

    -- The fixes, grouped so the console does not read as a wall of prose.
    local fixes = {}
    for _, row in ipairs(rows) do
        if row.fix then
            fixes[#fixes + 1] = row
        end
    end
    if #fixes > 0 then
        print('  what to do about the rows above:')
        for _, row in ipairs(fixes) do
            print(('    %-14s %s'):format(row.slot, row.fix))
        end
        print('')
    end

    print('  Next: run `cis_bridge test` to exercise every adapter that registered.')
    print('       It sends nothing and writes nothing to a player.')
    print('=======================================================================')
    print('')
    return true
end

exports('GetBridgeReport', function()
    local out = {}
    for _, row in ipairs(lines()) do
        out[#out + 1] = row
    end
    return out
end)

-- Printed once, after the adapters have had their full chance.
--
-- The delay is not a guess: it is Bridge.WAIT_MS plus a margin, because an
-- adapter that is still waiting will still be waiting at any earlier moment and
-- the report would then describe a state the server is about to leave. Waiting
-- for the slowest adapter means the report is true when it prints, which is the
-- only property worth having in a diagnostic.
CreateThread(function()
    Wait(Bridge.WAIT_MS + 2000)
    Report.render()
end)