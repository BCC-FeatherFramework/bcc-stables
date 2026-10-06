-- bcc-stables' boundary to feather-inventory.
--
-- Each horse's saddlebags are a custom inventory keyed by its Assets UUID
-- (`bcc_stables_horses.asset_id`). Inventory owns the items; bcc-stables only
-- registers the container and decides who may open it.
--
-- Inventory errors are { ok = false, error = { code, message } }; this file
-- returns flat { ok = false, code, message } like the other domains.

StablesInventory = {}

local RESOURCE = 'feather-inventory'
local TABLE = 'bcc_stables_horses'
local api
local containers = {} -- assetId -> { uuid, id }

local function Flat(result)
    if type(result) ~= 'table' then
        return StablesCore.Err('dependency_unavailable', 'Inventory returned no result.')
    end
    if result.ok then
        return result
    end
    local problem = type(result.error) == 'table' and result.error or {}
    return StablesCore.Err(problem.code or result.code or 'inventory_failed', problem.message or result.message)
end

local function Api()
    if api then
        return api
    end
    if GetResourceState(RESOURCE) ~= 'started' then
        return nil
    end
    local called, value = pcall(function()
        return exports[RESOURCE]:initiate()
    end)
    api = called and type(value) == 'table' and value or nil
    return api
end

-- Called once at startup, after the bcc_stables_horses table exists.
function StablesInventory.Start()
    local ready = StablesCore.Call(RESOURCE, 'AwaitReady', 30000)
    if not ready.ok then
        return Flat(ready)
    end
    local inventory = Api()
    if not inventory then
        return StablesCore.Err('dependency_unavailable', 'Inventory API is unavailable.')
    end
    return Flat(inventory.Inventory.RegisterForeignKey(TABLE, 'CHAR(36)', 'asset_id'))
end

-- Registers (or refreshes) a horse's saddlebags and returns { uuid, id }.
-- Safe to call on every spawn: the owner follows the current Assets owner.
function StablesInventory.EnsureSaddlebags(assetId, model, ownerCharacterId)
    local inventory = Api()
    if not inventory then
        return StablesCore.Err('dependency_unavailable', 'Inventory API is unavailable.')
    end
    local maxWeight = 200
    for _, horseCfg in pairs(Horses) do
        if horseCfg.colors[model] then
            maxWeight = tonumber(horseCfg.colors[model].invLimit) or maxWeight
            break
        end
    end
    local registered = Flat(inventory.Inventory.RegisterInventory(
        TABLE,
        assetId,
        _U('horseInv'),
        false,
        maxWeight,
        Config.itemsBlackList,
        ownerCharacterId,
        Config.shareInventory == true,
        Config.feather.saddlebags.maxSlots
    ))
    if registered.ok then
        containers[assetId] = registered.value
    end
    return registered
end

function StablesInventory.Close(src)
    local inventory = Api()
    if inventory then
        inventory.Inventory.CloseInventory(src)
    end
end

function StablesInventory.OpenSaddlebags(src, assetId)
    local inventory = Api()
    local container = containers[assetId]
    if not inventory or not container then
        return StablesCore.Err('not_registered', 'Saddlebags are not registered for this horse yet.')
    end
    return Flat(inventory.Inventory.OpenInventory(src, container.uuid, 'storage'))
end

-- True when the horse's saddlebags hold no items (or were never created).
function StablesInventory.IsEmpty(assetId)
    local inventory = Api()
    if not inventory then
        return StablesCore.Err('dependency_unavailable', 'Inventory API is unavailable.')
    end
    local found = inventory.Inventory.GetCustomInventory(TABLE, assetId)
    if type(found) ~= 'table' or not found.ok or type(found.value) ~= 'table' then
        return StablesCore.Ok(true)
    end
    local lifecycle = Flat(inventory.Inventory.GetContainerLifecycle(found.value.id))
    if not lifecycle.ok then
        return lifecycle
    end
    return StablesCore.Ok((tonumber(lifecycle.value.itemCount) or 0) == 0)
end

-- Items -------------------------------------------------------------------------

function StablesInventory.RegisterUsable(itemName, callback)
    local inventory = Api()
    if not inventory then
        return StablesCore.Err('dependency_unavailable', 'Inventory API is unavailable.')
    end
    return Flat(inventory.Items.RegisterUsableItem(itemName, callback))
end

function StablesInventory.ItemExists(itemName)
    local inventory = Api()
    if not inventory then
        return false
    end
    local exists = inventory.Items.ItemExists(itemName)
    return type(exists) == 'table' and exists.ok == true and exists.value == true
end

-- Condition of an item instance; nil when none is recorded (treated as full).
function StablesInventory.GetCondition(instanceId)
    local inventory = Api()
    if not inventory then
        return StablesCore.Err('dependency_unavailable', 'Inventory API is unavailable.')
    end
    return Flat(inventory.Items.GetCondition(instanceId))
end

function StablesInventory.RemoveById(instanceId)
    local inventory = Api()
    if not inventory then
        return StablesCore.Err('dependency_unavailable', 'Inventory API is unavailable.')
    end
    return Flat(inventory.Items.RemoveItemById(instanceId))
end

function StablesInventory.RemoveByName(src, itemName, quantity)
    local inventory = Api()
    if not inventory then
        return StablesCore.Err('dependency_unavailable', 'Inventory API is unavailable.')
    end
    return Flat(inventory.Items.RemoveItemByName(itemName, quantity, src))
end

-- Wears an item's condition. Returns { condition } or condition_not_supported
-- for stackable definitions.
function StablesInventory.Wear(instanceId, amount)
    local inventory = Api()
    if not inventory then
        return StablesCore.Err('dependency_unavailable', 'Inventory API is unavailable.')
    end
    return Flat(inventory.Items.AdjustCondition(instanceId, -amount))
end

AddEventHandler('onResourceStart', function(resource)
    if resource == RESOURCE then
        api = nil
        containers = {}
    end
end)
