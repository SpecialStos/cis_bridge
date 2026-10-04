-- Server-side framework capability.
--
-- The table cis_libs resolves the `framework` slot to on the server. It is
-- registered only when nothing else already holds the slot -- see
-- shared/framework/register.lua for why, which is the more interesting half.
--
-- THE METHODS ARE cis_libs' CONTRACT, not ours:
--
--   NormalizedPlayer(src)  Notify(src, message, kind)  IsLoaded()
--   HasPermission(src, permission)  GetPlayerJob(src)
--
-- A provider that misses one registers perfectly and then answers
-- `provider for "framework" has no method "X"` at the first call. So the table
-- here is a direct forward to the built one, and the shape is asserted in
-- test/framework.lua against the contract declared in cis_libs' registry.
--
-- NOT REGISTERED WHEN cis_core IS PRESENT. cis_core's framework layer is better
-- than this one -- it has live evidence behind it and this does not -- so this
-- is the fallback that makes cis_libs + cis_bridge self-sufficient, and it
-- stands down rather than competing.

local Register = CisBridgeFrameworkRegister

local ServerFramework = {}

exports('CisBridgeFrameworkServer', function()
    return ServerFramework
end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        print('[cis_bridge] framework: cis_libs never became ready; not registering')
        return
    end

    local Provider = require 'shared.framework.provider'
    Register.run('CisBridgeFrameworkServer')

    local detected = Register.detected
    local methods = Provider.build(detected)

    -- A direct forward rather than a wrapper. Every method already guards its
    -- own framework calls, and a wrapper here would add a frame that has to be
    -- reasoned about and cannot fail.
    for _, name in ipairs({
        'NormalizedPlayer', 'Notify', 'IsLoaded', 'HasPermission', 'GetPlayerJob',
    }) do
        ServerFramework[name] = methods[name]
    end

    -- Publish it for the conformance suite, which needs to reach THIS
    -- resource's own provider rather than whatever now holds the slot.
    Bridge.publish('framework', ServerFramework)
end)
