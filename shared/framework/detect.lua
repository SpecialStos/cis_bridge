-- Framework detection.
--
-- WHY THIS EXISTS AT ALL, GIVEN cis_core ALREADY PROVIDES `framework`
--
-- Because a server that installs cis_libs and cis_bridge and NOTHING ELSE has
-- no framework abstraction today, and the customer is not going to know that
-- and install a third resource to fix it. cis_core's implementation is better
-- than this one -- it has live evidence behind it and this does not -- so this
-- is a FALLBACK, and it says so.
--
-- The slot is first-registrant-wins. Two providers for one slot is a
-- boot-order bug: whichever starts first wins, the other silently never
-- registers, and the failure reproduces on one machine and not on another. So
-- `shouldYield` below stands down whenever anything else already holds the
-- slot, and the boot report says who won.
--
-- WHAT THE CUSTOMER ACTUALLY NEEDS
--
-- Not documentation. Somebody who installed a resource, did not read the
-- changelog, and expects `Cis.framework.player(src)` to return a player. So:
--
--   - detection is automatic, with nothing to configure and nothing to read;
--   - version drift is a DETECTED FACT, not a guess -- qbx_core removed
--     `GetCoreObject` in 1.9 and a bridge written against the old API raises on
--     its first call;
--   - every framework call is under pcall, because a framework raising is a
--     thing that happens and it must not reach a consumer;
--   - and a framework that STARTS but cannot be reached is treated as absent,
--     with the reason recorded. Selecting it would make every call raise.

local Detect = {}

-- The candidates, in precedence order, with what each one MUST expose for this
-- adapter to be able to drive it.
--
-- `requires` is a PRESENCE test on the exports table, never a call. Calling
-- something to see whether it works is how a probe becomes the thing that
-- raises: qbx_core's `GetCoreObject` on a modern build raises, so probing by
-- calling it would reject every current QBox server and fall through to
-- standalone -- which is the exact defect this ordering exists to prevent.
--
-- `order` notes why each entry is where it is.
local CANDIDATES = {
    { name = 'ox_core',     kind = 'qbox',   requires = { 'GetPlayer' },
      why = 'QBox under its earlier name. First: a server still running it has chosen it.' },
    { name = 'qbx_core',    kind = 'qbox',   requires = { 'GetPlayer' },
      why = 'QBox current. Before qb-core because they are different APIs.' },
    { name = 'qb-core',     kind = 'qbcore', requires = { 'GetCoreObject', 'GetPlayer' },
      why = 'QBCore legacy.' },
    { name = 'es_extended', kind = 'esx',    requires = { 'getSharedObject' },
      why = 'ESX Legacy.' },
    { name = 'esx_core',    kind = 'esx',    requires = { 'getSharedObject' },
      why = 'the ESX Legacy resource is also published as esx_core by some builds.' },
    { name = 'nd_core',     kind = 'nd',     requires = { 'getInstance' },
      why = 'ND_Core. Last of the knowns, and the one most likely to be absent.' },
}

Detect.CANDIDATES = CANDIDATES

--- Is this exports table one we can actually drive?
---
--- Presence, never a call. See the note on CANDIDATES.
local function hasAll(api, requires)
    if type(api) ~= 'table' then return false end
    for _, name in ipairs(requires) do
        if type(api[name]) == nil then return false end
    end
    return true
end

--- Detect the framework.
---
--- `engine` is injected so this is testable without FiveM: it needs only
--- `started(name)` and `fetch(name)`, and the real wiring passes
--- `GetResourceState` and `exports`. Every call into it is under pcall,
--- because `exports[missing]` RAISES rather than answering nil, and a probe
--- that assumes it does is a probe that takes the boot down.
---
--- @param engine { started: fun(name):boolean, fetch: fun(name):any }
--- @return table descriptor: { kind, name, core, native, isFallback, rejected }
function Detect.detect(engine)
    local rejected = {}

    for _, candidate in ipairs(CANDIDATES) do
        local okStarted, started = pcall(engine.started, candidate.name)
        if not okStarted then
            rejected[#rejected + 1] = {
                name = candidate.name, why = 'the resource state check raised',
            }
        elseif started then
            local okFetch, api = pcall(engine.fetch, candidate.name)
            if not okFetch then
                -- STARTED AND UNREACHABLE. Selected nothing, on purpose: an
                -- adapter for a framework whose exports raise turns every call
                -- into an error, which is worse than admitting it is not here.
                rejected[#rejected + 1] = {
                    name = candidate.name, why = 'started, but its exports raised when read',
                }
            elseif hasAll(api, candidate.requires) then
                return {
                    kind = candidate.kind,
                    name = candidate.name,
                    core = api,
                    -- Whether this build hands back a core object. qbx_core
                    -- removed it in 1.9; a bridge that assumes it is there
                    -- raises on a current QBox server and on nothing else, which
                    -- is the hardest kind of version drift to report.
                    native = type(api.GetCoreObject) == 'function',
                    isFallback = false,
                    rejected = rejected,
                }
            else
                local missing = {}
                for _, name in ipairs(candidate.requires) do
                    if type(api[name]) == nil then missing[#missing + 1] = name end
                end
                rejected[#rejected + 1] = {
                    name = candidate.name,
                    why = ('started, but exposes no %s export'):format(table.concat(missing, ' or ')),
                }
            end
        end
    end

    return {
        kind = 'standalone',
        name = 'standalone',
        core = nil,
        native = false,
        -- A FLAG, not a failure. No framework is a working server with no player
        -- data. Reporting it as a problem would put a red line in the boot report
        -- on a server that has nothing wrong with it.
        isFallback = true,
        rejected = rejected,
    }
end

--- Should this resource stand down because something else holds the slot?
---
--- The whole design in one function. `entry` is cis_libs' `GetCapabilities()`
--- value for the slot: `{ owner, resolved, missing }`.
function Detect.shouldYield(entry)
    if type(entry) ~= 'table' then return false end
    local owner = entry.owner
    if type(owner) ~= 'string' or owner == '' then return false end
    return owner ~= 'cis_bridge'
end

--- A one-sentence explanation of what was found, for a console and a report.
function Detect.describe(d)
    if not d then return 'nothing detected' end
    if d.isFallback then
        return 'no framework detected; running standalone'
    end
    local native = d.native and '' or ' (no GetCoreObject: a post-1.9 build)'
    return ('%s (%s)%s'):format(d.name, d.kind, native)
end

return Detect