-- qs-inventory adapter.

local Adapter = {}

function Adapter.name() return 'qs-inventory' end
function Adapter.available() return GetResourceState('qs-inventory') == 'started' end

function Adapter.count(src, item)
    if not src or not item then return nil end
    local ok, total = pcall(function()
        return exports['qs-inventory']:GetItemTotal(src, item)
    end)
    return ok and tonumber(total) or nil
end

function Adapter.add(src, item, amount, metadata)
    local ok, result = pcall(function()
        return exports['qs-inventory']:AddItem(src, item, amount, nil, metadata)
    end)
    return ok and result ~= false
end

function Adapter.remove(src, item, amount)
    local ok, result = pcall(function()
        return exports['qs-inventory']:RemoveItem(src, item, amount)
    end)
    return ok and result ~= false
end

exports('CisBridgeInventoryQs', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    if Bridge.register('inventoryProvider', 'qs-inventory',
            Bridge.configured('inventory'), { 'GetItemTotal', 'AddItem', 'RemoveItem' },
            'CisBridgeInventoryQs') then
        Bridge.publish('inventoryProvider', Adapter)
    end
end)
