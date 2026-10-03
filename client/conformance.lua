-- Client-side conformance for the target adapters.
--
-- The client half, and it exists for one specific reason: a target resource can
-- be started on the server and still be broken on a client. ox_target renders
-- and registers on both sides, and a client that cannot create a zone produces
-- a door that does not respond -- which looks exactly like a server-side
-- permission problem and is not one.
--
-- So the client checks the same contract, on the client, and reports it back.
-- Nothing is persisted and nothing is sent: a zone is created and removed under
-- a name that is obviously ours, and the one entity this spawns is deleted
-- before the function returns.
--
-- It runs on request rather than on join. A suite that runs itself in every
-- player's session spends a zone creation and a removal on every connection to
-- print to a console the operator is not watching, and -- because the target
-- slot lives in the CLIENT registry, independently of the server's -- its
-- results were never collected by anything even when they passed.
--
--      cis_bridge test          -- server asks every connected client

local results = {}

local function probeName(suffix)
    return ('cis_bridge_client_conformance_%s_%d'):format(
        suffix or 'zone', math.random(10000, 99999))
end

local function record(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail }
    print(('  [client] %-46s %s%s'):format(
        name, ok and 'PASS' or 'FAIL', (not ok and detail) and (' -- ' .. tostring(detail)) or ''))
end

local function skip(name, detail)
    results[#results + 1] = { name = name, ok = true, skipped = true, detail = detail }
    print(('  [client] %-46s %s -- %s'):format(name, 'SKIP', tostring(detail)))
end

-- Which target answered, from cis_libs' own view of the CLIENT registry. The
-- server's registry is a different one and says nothing about this half.
local function providerName()
    local ok, caps = pcall(function()
        return exports['cis_libs']:GetCapabilities()
    end)
    if not ok or type(caps) ~= 'table' or type(caps.target) ~= 'table' then
        return nil, nil
    end
    return caps.target.owner, caps.target
end

-- Spawn a vanilla ped for the entity path, and delete it before returning.
--
-- Both providers SILENTLY DO NOTHING for an entity that does not exist: ox_target
-- logs a warning and returns, qb-target registers against a handle that is not a
-- ped. So "create a target on this entity" reports success either way, and a
-- test that skipped the entity path would leave the one case that differs
-- between the two providers entirely untested.
local function withPed(fn)
    local hash = GetHashKey('a_m_m_business_01')
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < timeout do
        RequestModel(hash)
        Wait(0)
    end
    if not HasModelLoaded(hash) then
        return nil, 'a_m_m_business_01 did not load'
    end
    local ped = CreatePed(0, hash, 0.0, 0.0, 72.0, 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then
        return nil, 'the ped could not be created'
    end
    SetEntityAsMissionEntity(ped, true, true)
    local ok, err = pcall(fn, ped)
    -- Deleted whatever happened above, including a raise: a conformance run
    -- that leaves a ped standing in the world is visible to a player, and
    -- unlike a zone it does not time out.
    if DoesEntityExist(ped) then
        DeleteEntity(ped)
    end
    return ok, err
end

local function run()
    results = {}
    if not exports['cis_libs']:WaitReady(15000) then
        print('cis_bridge: cis_libs never became ready; client conformance cannot run')
        return results
    end

    local owner, entry = providerName()
    if not owner then
        print('cis_bridge: no target provider registered; skipping client conformance')
        return results
    end
    print('')
    print('cis_bridge client conformance -- ' .. tostring(owner))
    print('')

    -- The same cheap universal check the server runs: does the provider our
    -- adapter registered actually answer every method the slot declares, in
    -- THIS realm? The server can pass this check and the client fail it --
    -- they are separate registries -- which is the entire reason this file
    -- exists.
    if entry then
        local missing = entry.missing
        record('serves every method the slot declares, on the client',
            type(missing) ~= 'table' or #missing == 0,
            type(missing) == 'table' and #missing > 0 and table.concat(missing, ', ') or nil)
    end

    local adapter = Bridge.adapterFor('target')
    if type(adapter) == 'table' then
        record('the target adapter publishes its method table',
            type(adapter.create) == 'function' and type(adapter.remove) == 'function'
            and type(adapter.exists) == 'function')
        record('the adapter names itself', adapter.name() == owner,
            ('answered %q, the registry says %q'):format(tostring(adapter.name()), tostring(owner)))
        record('the adapter reports itself available', adapter.available() == true)
    else
        skip('the target adapter publishes its method table',
            'no adapter published itself on the client')
    end

    -- SPHERE. The simplest create, and the one that has broken.
    local a = probeName('sphere')
    local ok1, why1 = Cis.target.add('sphere', a, vec3(0.0, 0.0, 0.0), 1.0, {})
    record('creates a sphere zone', ok1, why1)
    record('reports the created zone as existing', Cis.target.exists(a) == true)
    local removed, removeWhy = Cis.target.remove(a)
    record('removes it', removed, removeWhy)
    -- THE ONE THAT ACTUALLY BREAKS. Both providers' removal calls return
    -- nothing at all, so success has to come from our own record; an adapter
    -- that used the return value would pass this today and fail the moment a
    -- provider changed its mind about returning something falsy.
    record('forgets a removed zone', Cis.target.exists(a) == false)
    record('removing an unknown name is refused, not fatal',
        select(1, Cis.target.remove(probeName('never_created'))) == false)

    -- BOX, IN BOTH SHAPES. qb-target takes three numbers and derives minZ and
    -- maxZ from the centre; ox_target takes a vector3. A caller writing
    -- `{1, 1, 1}` must work on both, and it is the adapter's job to make it so.
    local b = probeName('box_vector')
    local ok2, why2 = Cis.target.add('box', b, vec3(0.0, 0.0, 0.0), vector3(1.0, 1.0, 1.0), {})
    record('creates a box zone from a vector3 size', ok2, why2)
    local c = probeName('box_array')
    local ok3, why3 = Cis.target.add('box', c, vec3(0.0, 0.0, 0.0), { 1.0, 1.0, 1.0 }, {})
    record('accepts an array size as well as a vector3', ok3, why3)
    record('both boxes exist', Cis.target.exists(b) == true and Cis.target.exists(c) == true)
    Cis.target.remove(b)
    Cis.target.remove(c)

    -- THE ENTITY PATH, on a real ped.
    local pedOk, pedErr = withPed(function(ped)
        local name = probeName('entity')
        local created, why = Cis.target.add('ped', name, vec3(0.0, 0.0, 0.0), 1.0, { entity = ped })
        record('creates a target on a real entity', created, why)
        local gone, goneWhy = Cis.target.remove(name, true)
        record('removes an entity target', gone, goneWhy)
    end)
    if not pedOk then
        record('creates a target on a real entity', false,
            type(pedErr) == 'string' and pedErr or 'the entity path raised')
    end

    -- REFUSALS. A refusal has to arrive as `false, reason` and not as an error:
    -- a consumer on the other side of the exports boundary cannot read this
    -- console, so a raise here is a silent failure over there.
    local refused, reason = Cis.target.add('sphere', nil, vec3(0.0, 0.0, 0.0), 1.0, {})
    record('refuses a nameless target with a reason', refused == false and type(reason) == 'string',
        reason)
    local badType, badTypeWhy = Cis.target.add('hexagon', probeName('bad'), vec3(0.0, 0.0, 0.0), 1.0, {})
    record('refuses an unknown zone type with a reason',
        badType == false and type(badTypeWhy) == 'string', badTypeWhy)

    print('')
    return results
end

-- The server asks the client for its results, because a support thread needs
-- both halves and only the server can be asked from a console.
RegisterNetEvent('cis_bridge:client:conformance', function()
    local payload = run()
    -- `skipped` rides along so the server's tally can say how much of the client
    -- half actually executed. Without it a skipped check is indistinguishable
    -- from a passing one in the report, which is the same failure mode SKIP was
    -- introduced to end.
    TriggerServerEvent('cis_bridge:server:conformanceResults', payload)
end)

-- Also reachable from the client console, so a developer testing a target adapter
-- does not have to be a server admin to run it.
--
-- Cooldown, because this is the ONE command in the resource that any player can
-- invoke and that ALLOCATES -- a ped, and four target zones, per run. Un-
-- restricted and unthrottled, a macro turns a one-line diagnostic into a client
-- that spends its frame budget creating and deleting entities, on a server where
-- the person who would notice is not looking at their own console. Ten seconds is
-- far longer than a human needs to read a report and costs a spammer nothing,
-- because the report is the thing being spammed.
local lastRun = 0
RegisterCommand('cis_bridge_client', function()
    local now = GetGameTimer()
    if now - lastRun < 10000 then
        -- Said to the player rather than printed to a shared console, because this
        -- is the only line in the resource that goes to one.
        print('cis_bridge: that ran a moment ago. It creates and removes a target and a '
            .. 'ped each time, so it is not free.')
        return
    end
    lastRun = now
    run()
end, false)