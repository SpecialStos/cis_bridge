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

-- `GetItemCount`, not `Search`.
--
-- Both exist and both answer the question, but they answer DIFFERENTLY and the
-- difference is the whole reason for this file. `GetItemCount(inv, item)`
-- returns 0 for an item the player does not have AND 0 for an inventory that
-- does not exist yet -- a player who has not finished spawning. `Search(inv,
-- 'count', item)` returns 0 in the first case and FALSE in the second, because
-- it bails out before building its result table when the inventory is missing.
--
-- A caller asking "does this player hold three of X" gets `0` from one and
-- `nil` from the other, and `nil` reads as "I could not tell", so a player mid
-- spawn looks like an inventory outage. The slot contract asks for a number,
-- so the adapter returns the export that returns a number.
--
-- `Search` is still called when `GetItemCount` is absent, because a build old
-- enough not to have it is exactly the build that needs the fallback. Same
-- probe-then-fallback shape as the oxmysql `single` probe, for the same reason.
local hasCount = true

function Adapter.count(src, item)
    if not src or not item then return nil end
    if hasCount then
        local ok, total = pcall(function()
            return exports.ox_inventory:GetItemCount(src, item)
        end)
        if ok then
            return tonumber(total) or 0
        end
        return nil
    end
    local ok, total = pcall(function()
        return exports.ox_inventory:Search(src, 'count', item)
    end)
    -- `Search` answers false where `GetItemCount` answers 0, and false here is
    -- "this inventory is not loaded", so it stays nil rather than becoming a
    -- count of zero. Zero means "they have none"; nil means "unknown", and
    -- collapsing the two is how a spawn-time read becomes a dupe check.
    if not ok or total == false then return nil end
    return tonumber(total) or 0
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

function Adapter.canCarry(src, item, amount)
    local ok, result = pcall(function()
        return exports.ox_inventory:CanCarryItem(src, item, amount or 1)
    end)
    return ok and result == true
end

exports('CisBridgeInventoryOx', function() return Adapter end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then return end
    if not Bridge.register('inventoryProvider', 'ox_inventory',
        Bridge.configured('inventory'), { 'AddItem', 'RemoveItem' }, 'CisBridgeInventoryOx') then
        return
    end
    -- After registration, and for the same reason as every other probe in this
    -- resource: the adapter is registered on what is REQUIRED, and this decides
    -- which of two sufficient answers to use.
    local ok, fn = pcall(function() return exports.ox_inventory.GetItemCount end)
    hasCount = ok and fn ~= nil
    print(('cis_bridge: ox_inventory count=%s'):format(hasCount and 'GetItemCount' or 'Search'))
    Bridge.publish('inventoryProvider', Adapter)
end)
