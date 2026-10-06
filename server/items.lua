-- Usable horse items through feather-inventory.
--
-- Using an item only records which instance was used and asks the client to
-- act. The client confirms once the horse is near and the animation ran; only
-- then is food consumed or a tool's condition worn. A confirmation that does not
-- match a recent use is ignored.

StablesItems = {}

local USE_WINDOW_SECONDS = 30
local pending = {} -- source -> { kind, instanceId, itemName, at }

local kinds = {} -- itemName -> { kind, event, wear }

local function Define()
    kinds = {}
    for _, item in ipairs(Config.horseFood) do
        kinds[item] = { kind = 'feed', event = 'bcc-stables:FeedHorse' }
    end
    kinds[Config.horsebrush.item] = {
        kind = 'brush',
        event = 'bcc-stables:BrushHorse',
        wear = Config.horsebrush
    }
    kinds[Config.lantern.item] = {
        kind = 'lantern',
        event = 'bcc-stables:UseLantern',
        wear = Config.lantern
    }
    if Config.flamingHooves.active then
        kinds[Config.flamingHooves.item] = {
            kind = 'hooves',
            event = 'bcc-stables:FlamingHooves',
            wear = Config.flamingHooves
        }
    end
end

-- A worn-out tool breaks on use instead of working.
local function Broken(instanceId, wear)
    if not wear or not wear.durability then
        return false
    end
    local current = StablesInventory.GetCondition(instanceId)
    local condition = current.ok and tonumber(current.value) or nil
    if condition and condition < (wear.durabilityPerUse or 1) then
        StablesInventory.RemoveById(instanceId)
        return true
    end
    return false
end

local function OnUse(itemName)
    return function(item, src)
        local definition = kinds[itemName]
        local instanceId = type(item) == 'table' and tonumber(item.id) or nil
        if not definition or not instanceId or not StablesCharacters.Get(src) then
            return { ok = true }
        end
        if Broken(instanceId, definition.wear) then
            NotifyClient(src, _U('itemBroke'))
            return { ok = true }
        end
        StablesInventory.Close(src)
        pending[src] = {
            kind = definition.kind,
            instanceId = instanceId,
            itemName = itemName,
            at = os.time()
        }
        StablesRPC.Notify(src, definition.event, { item = itemName })
        return { ok = true }
    end
end

function StablesItems.Register()
    Define()
    for itemName in pairs(kinds) do
        if not StablesInventory.ItemExists(itemName) then
            StablesCore.Log('item.missing', { item = itemName, fix = 'apply sql/install_items.sql' })
        else
            local registered = StablesInventory.RegisterUsable(itemName, OnUse(itemName))
            if not registered.ok then
                StablesCore.Log('item.register_failed', { item = itemName, code = registered.code })
            end
        end
    end
end

-- The client finished the action for its most recent item use.
StablesRPC.Register('bcc-stables:ConfirmItemUse', function(data, src)
    local use = pending[src]
    pending[src] = nil
    if not use or use.kind ~= data.kind or os.time() - use.at > USE_WINDOW_SECONDS then
        return false
    end
    local definition = kinds[use.itemName]
    if use.kind == 'feed' then
        return StablesInventory.RemoveById(use.instanceId).ok
    end
    local wear = definition and definition.wear
    if not wear or not wear.durability then
        return true
    end
    local worn = StablesInventory.Wear(use.instanceId, wear.durabilityPerUse or 1)
    if not worn.ok then
        if worn.code == 'condition_not_supported' then
            StablesCore.Log('item.condition_unsupported', { item = use.itemName, fix = 'make the item unique' })
        end
        return true
    end
    if (tonumber(worn.value.condition) or 0) < (wear.durabilityPerUse or 1) then
        StablesInventory.RemoveById(use.instanceId)
        NotifyClient(src, _U('itemBroke'))
    end
    return true
end)

AddEventHandler('playerDropped', function()
    pending[source] = nil
end)
