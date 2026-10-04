-- Registering the `framework` capability, or standing down.
--
-- Published as a global for `server/framework.lua` and `client/framework.lua`
-- to read, because fxmanifest loads this file first. Same mechanism as
-- `server/ratelimit.lua` -- no `require`, because no sibling resource in this
-- platform uses a dotted one and an unproven load-time mechanism is a
-- boot-blocking unknown.
--
-- THE YIELD IS THE POINT.
--
-- The slot is first-registrant-wins. `cis_core` provides `framework` properly,
-- with live evidence behind it, and if both of us register then whichever
-- resource boots first wins and the other silently never registers -- a bug
-- that reproduces on one machine and not on another, and the worst kind to
-- support.
--
-- So this asks first. Somebody already owns the slot, this stands down, and the
-- boot report says who won. cis_bridge becomes SELF-SUFFICIENT for framework --
-- cis_libs + cis_bridge alone is a working platform on ESX, QBox, QBCore or
-- standalone -- and it defers to the better implementation when there is one.

local Detect = require 'shared.framework.detect'
local Provider = require 'shared.framework.provider'

local Register = {}

--- Whether another resource already holds the slot.
--- @return boolean yield, string|nil owner
function Register.claimIfFree()
    local ok, caps = pcall(function()
        return exports['cis_libs']:GetCapabilities()
    end)
    if not ok or type(caps) ~= 'table' then
        -- Cannot tell, so take it. "A server where the capability graph cannot
        -- be read is a server where nobody is reading it", and a bridge that
        -- declines to work because a diagnostic failed is worse than one that
        -- works and might be second in line.
        return false, nil
    end
    local entry = caps.framework
    if Detect.shouldYield(entry) then
        return true, entry and entry.owner or nil
    end
    return false, entry and entry.owner or nil
end

--- Detect, build, and register. Returns the descriptor either way.
function Register.run(exportName)
    local descriptor = Detect.detect(Provider.engine())

    local yieldTo, owner = Register.claimIfFree()
    if yieldTo then
        print(('[cis_bridge] framework: %s already provides it; cis_bridge stands down')
            :format(tostring(owner)))
        Register.owner = owner
        Register.detected = descriptor
        return descriptor, false
    end

    local methods = Provider.build(descriptor)
    local ok, why = exports['cis_libs']:RegisterCapability('framework',
        'cis_bridge:' .. exportName)
    if not ok then
        -- Named, because "registration failed" with no reason is how a support
        -- thread becomes three messages instead of one. The overwhelmingly
        -- likely cause since 2.2.0 is that cis_bridge is not in
        -- Security.AuthorizedResources, and an empty list refuses everything.
        print(('[cis_bridge] framework: registration REFUSED -- %s'):format(tostring(why)))
        Register.owner = nil
        Register.detected = descriptor
        return descriptor, false
    end

    print(('[cis_bridge] framework: registered -- %s'):format(Detect.describe(descriptor)))
    for _, r in ipairs(descriptor.rejected or {}) do
        print(('[cis_bridge] framework:   %s not used -- %s')
            :format(r.name, r.why))
    end
    Register.owner = 'cis_bridge'
    Register.detected = descriptor
    return descriptor, true
end

CisBridgeFrameworkRegister = Register

return Register
