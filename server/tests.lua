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
        local tests = {
            { 'stable ready', StablesCore.ready == true },
            { 'migration ledger', migrations == StablesMigrations.Count },
            { 'assets reader trusted', not asset.ok and asset.code == 'asset_not_found' },
            { 'jobs reader trusted', check.code ~= 'authorization_denied' },
            { 'economy reader trusted', sink.ok == true },
            { 'saddlebag foreign key', #foreignKey == 1 },
            { 'item definitions', #missingItems == 0 }
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
