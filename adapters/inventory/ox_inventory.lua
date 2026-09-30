-- ox_inventory adapter.
--
-- ox_inventory's GetInventoryItems returns a LIST of entries, each with a name
-- and a count. Every adapter has to flatten its own shape into the
-- name -> amount map that consumers actually use, and that flattening is the
-- part that differs; the method names are almost identical across the four.
--
-- GPL-3.0, and on roughly half of all servers. That is exactly why this is one
-- file, optional, never vendored and never modified: isolation is the whole
-- mitigation, and the isolation is only real if nothing outside this file names
-- ox_inventory.

local Adapter = {}

function Adapter.name() return 'ox_inventory' end
function Adapter.available() return GetResourceState('ox_inventory') == 'started' end

function Adapter.count(src, item)
    if not src or not item then return nil end
    local total = exports.ox_inventory:Search(src, 'count', item)
    return tonumber(total) or nil
end

function Adapter.add(src, item, amount, metadata)
    local ok, result = pcall(function()
        return exports.ox_inventory:AddItem(src, item, amount, metadata)
    end)
    return ok and result ~= false
end

function Adapter.remove(src, item, amount)
    local ok, result = pcall(function()
        return exports.ox_inventory:RemoveItem(src, item, amount)
    end)
    return ok and result ~= false
end

exports('CisBridgeInventoryOx', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    Bridge.register('inventoryProvider', 'ox_inventory',
        Bridge.configured('inventory'), 'Search', 'CisBridgeInventoryOx')
end)
