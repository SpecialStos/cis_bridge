-- codem-inventory adapter.
--
-- The only one of the four with no boolean in its contract: HasItem and
-- AddItem answer counts and nil respectively, so every call needs a coercion
-- into the shape the service publishes.

local Adapter = {}

function Adapter.name() return 'codem-inventory' end
function Adapter.available() return GetResourceState('codem-inventory') == 'started' end

function Adapter.count(src, item)
    if not src or not item then return nil end
    local ok, total = pcall(function()
        return exports['codem-inventory']:GetItemsTotalAmount(src, item)
    end)
    return ok and tonumber(total) or nil
end

function Adapter.add(src, item, amount, metadata)
    local ok, result = pcall(function()
        return exports['codem-inventory']:AddItem(src, item, amount, nil, metadata)
    end)
    -- nil means "did not fit", which is a refusal rather than a crash.
    return ok and result ~= nil and result ~= false
end

function Adapter.remove(src, item, amount)
    local ok, result = pcall(function()
        return exports['codem-inventory']:RemoveItem(src, item, amount)
    end)
    return ok and result ~= false
end

exports('CisBridgeInventoryCodem', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    Bridge.register('inventoryProvider', 'codem-inventory',
        Bridge.configured('inventory'), 'GetItemsTotalAmount', 'CisBridgeInventoryCodem')
end)
