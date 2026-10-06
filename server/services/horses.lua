-- Gameplay state for each horse asset: bonding XP, core health/stamina, writhe,
-- capture origin, and each character's selected horse. Ownership is never read
-- from these tables; it always comes from feather-assets.

StablesHorses = {}

local MAX_XP = 100000

local function Clamp(value, minimum, maximum, fallback)
    value = tonumber(value)
    if not value or value ~= value then
        return fallback
    end
    return math.max(minimum, math.min(maximum, math.floor(value)))
end

function StablesHorses.Ensure(assetId, captured)
    DB.exec([[
        INSERT IGNORE INTO `bcc_stables_horses` (`asset_id`,`captured`)
        VALUES (?,?)]], assetId, captured and 1 or 0)
end

-- assetId -> row for several horses in one query.
function StablesHorses.Rows(assetIds)
    local rows = {}
    if #assetIds == 0 then
        return rows
    end
    local marks = {}
    for index = 1, #assetIds do
        marks[index] = '?'
    end
    local result = DB.query([[
        SELECT `asset_id`,`xp`,`health`,`stamina`,`writhe`,`captured`
        FROM `bcc_stables_horses`
        WHERE `asset_id` IN (]] .. table.concat(marks, ',') .. ')', table.unpack(assetIds)) or {}
    for _, row in ipairs(result) do
        rows[row.asset_id] = row
    end
    return rows
end

function StablesHorses.Row(assetId)
    return StablesHorses.Rows({ assetId })[assetId]
end

function StablesHorses.SaveStats(assetId, health, stamina)
    DB.exec([[
        UPDATE `bcc_stables_horses` SET `health`=?,`stamina`=?
        WHERE `asset_id`=?]],
        Clamp(health, 0, 100, 100), Clamp(stamina, 0, 100, 100), assetId)
end

function StablesHorses.SaveXp(assetId, xp)
    DB.exec('UPDATE `bcc_stables_horses` SET `xp`=? WHERE `asset_id`=?', Clamp(xp, 0, MAX_XP, 0), assetId)
end

function StablesHorses.SetWrithe(assetId, writhe)
    DB.exec('UPDATE `bcc_stables_horses` SET `writhe`=? WHERE `asset_id`=?', writhe and 1 or 0, assetId)
end

-- Selection ----------------------------------------------------------------------

function StablesHorses.Select(characterId, assetId)
    DB.exec([[
        INSERT INTO `bcc_stables_selection` (`character_id`,`asset_id`) VALUES (?,?)
        ON DUPLICATE KEY UPDATE `asset_id`=VALUES(`asset_id`)]], characterId, assetId)
end

function StablesHorses.Selected(characterId)
    return DB.value('SELECT `asset_id` FROM `bcc_stables_selection` WHERE `character_id`=?', characterId)
end

function StablesHorses.ClearSelection(characterId)
    DB.exec('DELETE FROM `bcc_stables_selection` WHERE `character_id`=?', characterId)
end

-- A horse that changed hands or was retired is nobody's selection any more.
function StablesHorses.ClearSelectionsOf(assetId)
    DB.exec('DELETE FROM `bcc_stables_selection` WHERE `asset_id`=?', assetId)
end

-- Client shape --------------------------------------------------------------------
-- Same fields the stable UI and client scripts used before the port; `id` is now
-- the horse's Assets UUID and `components` stays a JSON string.

function StablesHorses.ToClient(asset, row, selectedId)
    local metadata = asset.metadata or {}
    row = row or {}
    return {
        id = asset.assetId,
        model = asset.modelKey,
        status = asset.status,
        name = metadata.name or 'Horse',
        gender = metadata.gender == 'female' and 'female' or 'male',
        components = json.encode(metadata.components or {}),
        selected = asset.assetId == selectedId and 1 or 0,
        xp = tonumber(row.xp) or 0,
        health = tonumber(row.health) or 100,
        stamina = tonumber(row.stamina) or 100,
        writhe = tonumber(row.writhe) or 0,
        captured = tonumber(row.captured) or 0
    }
end

-- The character's horses in client shape (gameplay rows created on demand).
function StablesHorses.ListForClient(characterId)
    local owned = StablesAssets.ListOwned(characterId)
    if not owned.ok then
        return owned
    end
    local ids = {}
    for _, asset in ipairs(owned.value) do
        ids[#ids + 1] = asset.assetId
    end
    local rows = StablesHorses.Rows(ids)
    local selectedId = StablesHorses.Selected(characterId)
    local horses = {}
    for _, asset in ipairs(owned.value) do
        if not rows[asset.assetId] then
            StablesHorses.Ensure(asset.assetId, false)
        end
        horses[#horses + 1] = StablesHorses.ToClient(asset, rows[asset.assetId], selectedId)
    end
    return StablesCore.Ok(horses)
end
