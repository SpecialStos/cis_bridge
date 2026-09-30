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
-- a name that is obviously ours.

local results = {}

local function probeName()
    return ('cis_bridge_client_conformance_%d'):format(math.random(10000, 99999))
end

local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail }
    print(('  [client] %-46s %s%s'):format(
        name, ok and 'PASS' or 'FAIL', (not ok and detail) and (' -- ' .. tostring(detail)) or ''))
end

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        print('cis_bridge: cis_libs never became ready; client conformance cannot run')
        return
    end
    local caps = exports['cis_libs']:GetCapabilities()
    if not (caps.target and caps.target.owner) then
        print('cis_bridge: no target provider registered; skipping client conformance')
        return
    end
    print('')
    print('cis_bridge client conformance -- ' .. tostring(caps.target.owner))
    print('')

    local a = probeName()
    local ok1, why1 = Cis.target.add('sphere', a, vec3(0.0, 0.0, 0.0), 1.0, {})
    check('creates a sphere zone on the client', ok1, why1)
    check('reports it as existing', Cis.target.exists(a) == true)
    local removed, removeWhy = Cis.target.remove(a)
    check('removes it', removed, removeWhy)
    check('forgets it', Cis.target.exists(a) == false)
    -- A refusal must arrive as `false, reason` and not as an error. A consumer
    -- on the other side of the exports boundary cannot read this console.
    local refused, reason = Cis.target.add('sphere', nil, vec3(0.0, 0.0, 0.0), 1.0, {})
    check('refuses a nameless target with a reason', refused == false and type(reason) == 'string', reason)
    print('')
end)

-- The server asks the client for its results, because a support thread needs
-- both halves and only the server can be asked from a console.
RegisterNetEvent('cis_bridge:client:conformance', function()
    TriggerServerEvent('cis_bridge:server:conformanceResults', results)
end)
