-- bcc-stables' boundary to feather-assets.
--
-- Assets owns every horse's identity, model, owner and lifecycle, plus its
-- consumer metadata (name, gender, tack components). bcc-stables never stores an
-- owner itself; it asks Assets.

StablesAssets = {}

local RESOURCE = 'feather-assets'
local METADATA_VERSION = 1

local function Assets(operation, request)
    return StablesCore.Call(RESOURCE, operation, request)
end

-- Metadata document for a horse. Version 1: { name, gender, components }.
function StablesAssets.Metadata(name, gender, components)
    return {
        name = name,
        gender = gender,
        components = components or {}
    }
end

function StablesAssets.Register(order, character)
    local payload = order.payload
    return Assets('RegisterAsset', {
        requestId = 'order:' .. order.order_id,
        assetType = 'horse',
        modelKey = payload.model,
        holderType = 'character',
        holderId = character.characterId,
        provenanceType = payload.provenanceType,
        provenanceId = order.order_id,
        metadataVersion = METADATA_VERSION,
        metadata = StablesAssets.Metadata(payload.name, payload.gender, {}),
        reasonCode = payload.reasonCode,
        referenceType = 'stables_order',
        referenceId = order.order_id,
        actorSource = character.source
    })
end

function StablesAssets.Get(assetId)
    return Assets('GetAsset', { assetId = assetId })
end

-- Active horses owned by a character, newest first (bounded by the config limits).
function StablesAssets.ListOwned(characterId)
    local result = Assets('ListAssetsByHolder', {
        holderType = 'character',
        holderId = characterId,
        assetType = 'horse',
        includeMetadata = true,
        limit = 50
    })
    if not result.ok then
        return result
    end
    return StablesCore.Ok(result.value.items)
end

-- The horse asset when the character currently owns it, else an error.
function StablesAssets.GetOwned(assetId, characterId)
    if not StablesCore.Uuid(assetId) then
        return StablesCore.Err('invalid_input', 'Horse ID must be a UUID.')
    end
    local asset = StablesAssets.Get(assetId:lower())
    if not asset.ok then
        return asset
    end
    local owner = asset.value.owner
    if asset.value.assetType ~= 'horse' or asset.value.status == 'retired' or not owner
        or owner.holderType ~= 'character' or owner.holderId ~= characterId then
        return StablesCore.Err('not_owner', 'Character does not own this horse.')
    end
    return asset
end

-- Replaces the metadata document. On a lost reply the same request ID is looked
-- up first, so a retry never applies a stale revision twice. `reference` is an
-- optional { type, id } link to the stable record behind the change.
function StablesAssets.UpdateMetadata(requestId, assetId, metadata, character, reasonCode, reference)
    local found = Assets('FindOperation', { requestId = requestId })
    if found.ok and found.value.found then
        return StablesCore.Ok(found.value.result)
    end
    local asset = StablesAssets.Get(assetId)
    if not asset.ok then
        return asset
    end
    return Assets('UpdateAssetMetadata', {
        requestId = requestId,
        assetId = assetId,
        expectedRevision = asset.value.revision,
        metadataVersion = METADATA_VERSION,
        metadata = metadata,
        reasonCode = reasonCode,
        referenceType = reference and reference.type or nil,
        referenceId = reference and reference.id or nil,
        actorSource = character and character.source or nil
    })
end

function StablesAssets.Transfer(requestId, asset, fromCharacterId, toCharacterId, actorSource)
    return Assets('TransferOwnership', {
        requestId = requestId,
        assetId = asset.assetId,
        expectedRevision = asset.revision,
        fromHolderType = 'character',
        fromHolderId = fromCharacterId,
        toHolderType = 'character',
        toHolderId = toCharacterId,
        reasonCode = 'stables.trade',
        actorSource = actorSource
    })
end

-- Retires a horse (death or sale). Replays by request ID after a lost reply.
function StablesAssets.Retire(requestId, assetId, reasonCode, actorSource, reference)
    local found = Assets('FindOperation', { requestId = requestId })
    if found.ok and found.value.found then
        return StablesCore.Ok(found.value.result)
    end
    local asset = StablesAssets.Get(assetId)
    if not asset.ok then
        return asset
    end
    return Assets('RetireAsset', {
        requestId = requestId,
        assetId = assetId,
        expectedRevision = asset.value.revision,
        reasonCode = reasonCode,
        referenceType = reference and reference.type or nil,
        referenceId = reference and reference.id or nil,
        actorSource = actorSource
    })
end
