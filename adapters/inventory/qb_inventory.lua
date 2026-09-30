-- qb-inventory adapter.
--
-- The one target that does NOT accept metadata: RemoveItem's fourth argument is
-- a slot/ignore flag rather than a metadata table, so the signature genuinely
-- differs from the others and cannot be shared with a flag.
--
-- Return-shape is also its own: qb-inventory reports success as a STRING on
-- failure rather than a boolean, so a plain truthiness test would read the
-- error message as success.

local Adapter = {}

function Adapter.name() return 'qb-inventory' end
function Adapter.available() return GetResourceState('qb-inventory') == 'started' end

function Adapter.count(src, item)
    if not src or not item then return nil end
    local ok, total = pcall(function()
        return exports['qb-inventory']:GetItemCount(src, item)
    end)
    return ok and tonumber(total) or nil
end

function Adapter.add(src, item, amount, metadata)
    local ok, result = pcall(function()
        return exports['qb-inventory']:AddItem(src, item, amount, false, metadata)
    end)
    -- A string return is qb-inventory's way of saying no, and a string is
    -- truthy in Lua -- so the check has to be explicit or every failed add
    -- reports as a success.
    return ok and result ~= false and type(result) ~= 'string'
end

function Adapter.remove(src, item, amount)
    local ok, result = pcall(function()
        return exports['qb-inventory']:RemoveItem(src, item, amount, false)
    end)
    return ok and result ~= false and type(result) ~= 'string'
end

exports('CisBridgeInventoryQb', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    Bridge.register('inventoryProvider', 'qb-inventory',
        Bridge.configured('inventory'), 'GetItemCount', 'CisBridgeInventoryQb')
end)
