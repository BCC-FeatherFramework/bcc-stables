-- Read-only release check; safe on production.
--   Usage (server console): StablesReleaseSmokeTest

local ZERO_UUID = '00000000-0000-0000-0000-000000000000'

RegisterCommand('StablesReleaseSmokeTest', function(source)
    if source ~= 0 then
        return
    end
    local called, reason = xpcall(function()
        local migrations = tonumber(DB.value('SELECT COUNT(*) FROM `bcc_stables_schema_migrations`'))
        -- A trusted reader gets asset_not_found for an unknown UUID; an untrusted one gets authorization_denied.
        local asset = StablesCore.Call('feather-assets', 'GetAsset', { assetId = ZERO_UUID })
        local check = StablesCore.Call('feather-jobs', 'CheckAssignment', {
            characterId = ZERO_UUID,
            jobKey = 'trainer'
        })
        local sink = StablesCore.Call('feather-economy', 'GetSystemAccount', {
            currency = Config.feather.currencies.cash,
            accountType = 'system_sink'
        })
        local foreignKey = DB.query("SHOW COLUMNS FROM `inventory` LIKE 'bcc_stables_horses_id'") or {}
        local missingItems = {}
        for _, item in ipairs({ Config.horsebrush.item, Config.lantern.item, Config.reviver }) do
            if not StablesInventory.ItemExists(item) then
                missingItems[#missingItems + 1] = item
            end
        end
        for _, item in ipairs(Config.horseFood) do
            if not StablesInventory.ItemExists(item) then
                missingItems[#missingItems + 1] = item
            end
        end
        local registered = {}
        for _, command in ipairs(GetRegisteredCommands() or {}) do
            registered[command.name] = true
        end
        local tests = {
            { 'stable ready', StablesCore.ready == true },
            { 'migration ledger', migrations == StablesMigrations.Count },
            { 'assets reader trusted', not asset.ok and asset.code == 'asset_not_found' },
            { 'jobs reader trusted', check.code ~= 'authorization_denied' },
            { 'economy reader trusted', sink.ok == true },
            { 'saddlebag foreign key', #foreignKey == 1 },
            { 'item definitions', #missingItems == 0 },
            { 'development commands absent', not registered.StablesFlowTest }
        }
        local passed = 0
        for _, test in ipairs(tests) do
            if test[2] then
                passed = passed + 1
            end
            print(('[StablesReleaseSmokeTest] %-24s %s'):format(test[1], test[2] and 'PASS' or 'FAIL'))
        end
        if #missingItems > 0 then
            print('[StablesReleaseSmokeTest] missing items: ' .. table.concat(missingItems, ', '))
        end
        print(('[StablesReleaseSmokeTest] done %d/%d passed (read-only)'):format(passed, #tests))
        print('[StablesReleaseSmokeTest] note: horse sales also need Economy supply access (see README)')
    end, debug.traceback)
    if not called then
        print('[StablesReleaseSmokeTest] FAIL ' .. tostring(reason))
    end
end, true)

if not Config.devMode then
    return
end

-- DevMode only. MOVES MONEY AND CHANGES HORSES; both characters may be offline.
-- Registers a captured horse for the first character (charges Config.regCost),
-- trades it to the second, tries to sell it (refused while bcc-stables has no
-- Economy supply grant; with the grant it is sold and retired), then retires it
-- as a permanent death. Runs the same flows as the in-game handlers, without the
-- position checks (near the trainer, stable or other player).
--   Usage (server console): StablesFlowTest <serverId|characterUuid> <otherServerId|otherCharacterUuid>
RegisterCommand('StablesFlowTest', function(source, args)
    if source ~= 0 then
        return
    end
    local called, reason = xpcall(function()
        local function Character(value)
            if tonumber(value) then
                return StablesCharacters.Get(value)
            end
            return StablesCore.Uuid(value) and { characterId = value:lower() } or nil
        end
        local seller, buyer = Character(args[1]), Character(args[2])
        if not seller or not buyer or seller.characterId == buyer.characterId then
            print('[StablesFlowTest] usage: StablesFlowTest <serverId|characterUuid> <otherServerId|otherCharacterUuid>')
            return
        end
        local passed, total = 0, 0
        local function Check(name, condition)
            total = total + 1
            if condition then
                passed = passed + 1
            end
            print(('[StablesFlowTest] %-32s %s'):format(name, condition and 'PASS' or 'FAIL'))
        end
        local function Owns(character, assetId)
            return StablesAssets.GetOwned(assetId, character.characterId).ok
        end
        local function Listed(character, assetId)
            local owned = StablesAssets.ListOwned(character.characterId)
            for _, asset in ipairs(owned.ok and owned.value or {}) do
                if asset.assetId == assetId then
                    return true
                end
            end
            return false
        end

        -- Capture: register a tamed horse (first configured model, sorted).
        local models = {}
        for _, horseCfg in pairs(Horses) do
            for model in pairs(horseCfg.colors) do
                models[#models + 1] = model
            end
        end
        table.sort(models)
        local tamed = StablesFlows.Tame(seller, models[1], 'Flow Test', 'male')
        Check('captured horse registered', tamed.ok and tamed.value.assetId ~= nil)
        if not tamed.ok then
            print(('[StablesFlowTest] registration failed code=%s'):format(tostring(tamed.code)))
            return print(('[StablesFlowTest] done %d/%d passed'):format(passed, total))
        end
        local assetId = tamed.value.assetId
        local row = StablesHorses.Row(assetId)
        Check('marked as captured', row ~= nil and tonumber(row.captured) == 1)
        local order = DB.one([[SELECT `state`,`transaction_id` FROM `bcc_stables_orders`
            WHERE `asset_id`=? AND `kind`='tame_register']], assetId)
        Check('registration fee charged', order ~= nil and order.state == 'fulfilled' and order.transaction_id ~= nil)
        Check('first character owns it', Owns(seller, assetId))

        -- Trade.
        local previous = StablesHorses.Selected(seller.characterId)
        StablesHorses.Select(seller.characterId, assetId)
        local traded = StablesFlows.Trade(seller, buyer.characterId, assetId)
        Check('traded to second character', traded.ok and Owns(buyer, assetId) and Listed(buyer, assetId))
        Check('first character released', not Owns(seller, assetId) and not Listed(seller, assetId))
        Check('selection cleared after trade', StablesHorses.Selected(seller.characterId) ~= assetId)
        if previous and previous ~= assetId and Owns(seller, previous) then
            StablesHorses.Select(seller.characterId, previous)
        end
        local again = StablesFlows.Trade(seller, buyer.characterId, assetId)
        Check('former owner cannot trade it', not again.ok and again.code == 'not_owner')

        -- Sale.
        local sold = StablesFlows.Sell(buyer, assetId)
        if sold.ok then
            local asset = StablesAssets.Get(assetId)
            Check('sold horse retired', asset.ok and asset.value.status == 'retired' and not Listed(buyer, assetId))
        else
            Check('refused sale keeps the horse', sold.code == 'authorization_denied' and Owns(buyer, assetId))

            -- Permanent death.
            local wrong = StablesFlows.RetireDead(seller, assetId)
            Check('non-owner cannot retire it', not wrong.ok and wrong.code == 'not_owner')
            local dead = StablesFlows.RetireDead(buyer, assetId)
            local asset = StablesAssets.Get(assetId)
            Check('dead horse retired', dead.ok and asset.ok and asset.value.status == 'retired')
            Check('retired horse not listed', not Listed(buyer, assetId) and not Owns(buyer, assetId))
        end
        print(('[StablesFlowTest] done %d/%d passed (MUTATING: horse %s)'):format(passed, total, assetId))
    end, debug.traceback)
    if not called then
        print('[StablesFlowTest] FAIL ' .. tostring(reason))
    end
end, true)
