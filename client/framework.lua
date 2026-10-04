-- Client-side framework capability.
--
-- The client registry is SEPARATE and resolves `framework`, `target` and
-- `doorsClient` only. A server registration for `framework` says nothing about
-- this one, and the method set here is the client's half of the same contract:
--
--   ShowNotification(message, kind)   IsLoaded()
--
-- `Notify` is the server form and takes a src, so it is deliberately absent:
-- a client cannot address a player, and a provider that offered it would be
-- inviting a call with a src that means nothing.

local Register = CisBridgeFrameworkRegister

local ClientFramework = {}

exports('CisBridgeFrameworkClient', function()
    return ClientFramework
end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        print('[cis_bridge] framework (client): cis_libs never became ready; not registering')
        return
    end

    local Provider = require 'shared.framework.provider'
    Register.run('CisBridgeFrameworkClient')

    local detected = Register.detected
    local methods = Provider.build(detected)
    for _, name in ipairs({ 'ShowNotification', 'IsLoaded' }) do
        ClientFramework[name] = methods[name]
    end
end)
