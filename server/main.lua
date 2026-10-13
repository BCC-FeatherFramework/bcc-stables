-- bcc-stables server: stable purchases, tack, sales, trades, horse state and
-- saddlebags on the Feather Framework.
--
-- Every handler derives the character from the caller's Core session, rechecks
-- horse ownership with feather-assets, and recomputes prices from config. The
-- client only says what the player wants to do.

StablesCore.ready = false
local cooldowns = {} -- 'type:characterId' -> os.time()

-- Flows shared by the RPC handlers and the console tests. They take a character
-- ({ characterId, source? }) and work while it is offline; position checks
-- (near a stable, trainer or the other player) stay in the RPC handlers.
StablesFlows = {}

-- Helpers ------------------------------------------------------------------------

local function HorseConfig(model)
    if type(model) ~= 'string' then
        return nil
    end
    for _, horseCfg in pairs(Horses) do
        local colorCfg = horseCfg.colors[model]
        if colorCfg then
            return colorCfg, horseCfg
        end
    end
    return nil
end

local function HorseConfigByHash(hash)
    for _, horseCfg in pairs(Horses) do
        for model, colorCfg in pairs(horseCfg.colors) do
            if joaat(model) == hash then
                return colorCfg, model
            end
        end
    end
    return nil
end

local function ValidName(name)
    if type(name) ~= 'string' then
        return nil
    end
    name = name:match('^%s*(.-)%s*$')
    if #name < 1 or #name > Config.feather.nameMaxLength or name:find('%c') or name:find('[<>]') then
        return nil
    end
    return name
end

local function Gender(value)
    return value == 'female' and 'female' or 'male'
end

local function IsTrainer(character)
    return StablesJobs.HasAny(character.characterId, Config.trainerJob)
end

-- The caller's active character, or nil while the stable is unavailable.
local function Begin(src)
    if not StablesCore.ready then
        return nil
    end
    return StablesCharacters.Get(src)
end

local function NearStable(src, site)
    local siteCfg = Stables[site]
    if not siteCfg then
        return false
    end
    local coords = GetEntityCoords(GetPlayerPed(src))
    return #(coords - siteCfg.npc.coords) <= siteCfg.shop.distance + 5.0
end

local function NearTrainer(src)
    local coords = GetEntityCoords(GetPlayerPed(src))
    for _, siteCfg in pairs(Trainers) do
        if #(coords - siteCfg.npc.coords) <= siteCfg.shop.distance + 5.0 then
            return true
        end
    end
    return false
end

-- The horse entity the client named, when it exists next to the player.
local function NearEntity(src, netId, distance)
    local entity = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if entity == 0 or not DoesEntityExist(entity)
        or #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(entity)) > distance then
        return nil
    end
    return entity
end

local function OwnedCount(character)
    local owned = StablesAssets.ListOwned(character.characterId)
    if not owned.ok then
        return nil
    end
    return #owned.value
end

-- Shared purchase rules: horse limit, then a wallet balance preflight.
local function CanAfford(character, currency, amount)
    if amount <= 0 then
        return true
    end
    local wallet = StablesEconomy.GetWallet(character.characterId, currency)
    if not wallet.ok then
        NotifyClient(character.source, StablesEconomy.Message(wallet, currency))
        return false
    end
    if (tonumber(wallet.value.balance) or 0) < amount then
        NotifyClient(character.source, StablesEconomy.Message({ code = 'insufficient_funds' }, currency))
        return false
    end
    return true
end

local function WithinLimit(character, trainer)
    local maxHorses = trainer and tonumber(Config.maxTrainerHorses) or tonumber(Config.maxPlayerHorses)
    local count = OwnedCount(character)
    if not count then
        NotifyClient(character.source, _U('stableUnavailable'))
        return false
    end
    if count >= maxHorses then
        NotifyClient(character.source, _U('horseLimit') .. maxHorses .. _U('horses'))
        return false
    end
    return true
end

-- Validates a stable purchase and returns its order payload, or nil.
local function PurchasePayload(character, data)
    local site = data.site
    if not NearStable(character.source, site) then
        return nil
    end
    local colorCfg = HorseConfig(data.ModelH)
    if not colorCfg then
        return nil
    end
    local siteCfg = Stables[site]
    local trainer = IsTrainer(character)
    if siteCfg.trainerBuy and not trainer then
        NotifyClient(character.source, _U('trainerBuyHorse'))
        return nil
    end
    if siteCfg.shop.jobsEnabled and not StablesJobs.HasAny(character.characterId, siteCfg.shop.jobs) then
        NotifyClient(character.source, _U('needJob'))
        return nil
    end
    if colorCfg.job and #colorCfg.job > 0 then
        local jobs = {}
        for _, jobKey in ipairs(colorCfg.job) do
            jobs[#jobs + 1] = { name = jobKey, grade = 0 }
        end
        if not StablesJobs.HasAny(character.characterId, jobs) then
            NotifyClient(character.source, _U('needJob'))
            return nil
        end
    end
    if not WithinLimit(character, trainer) then
        return nil
    end
    local kind = data.IsCash and 'cash' or 'gold'
    if (kind == 'cash' and Config.currencyType == 1) or (kind == 'gold' and Config.currencyType == 0) then
        return nil
    end
    local currency = StablesEconomy.Currency(kind)
    local amount = StablesEconomy.ToMinor(currency, kind == 'cash' and colorCfg.cashPrice or colorCfg.goldPrice)
    if not amount.ok then
        NotifyClient(character.source, _U('moneyUnavailable'))
        return nil
    end
    if not CanAfford(character, currency, amount.value) then
        return nil
    end
    return {
        model = data.ModelH,
        currency = currency,
        amount = amount.value,
        captured = false,
        provenanceType = 'stable_purchase',
        reasonCode = 'stables.purchase'
    }
end

-- Validates registering a tamed horse and returns its order payload, or nil.
-- Registration rules for a tamed horse, without the position check.
local function TameRules(character, model)
    if not Config.allowKeep or not HorseConfig(model) then
        return nil
    end
    local trainer = IsTrainer(character)
    if Config.trainerOnly and not trainer then
        NotifyClient(character.source, _U('trainerRegHorse'))
        return nil
    end
    if not WithinLimit(character, trainer) then
        return nil
    end
    local currency = StablesEconomy.Currency('cash')
    local amount = StablesEconomy.ToMinor(currency, Config.regCost)
    if not amount.ok then
        NotifyClient(character.source, _U('moneyUnavailable'))
        return nil
    end
    if not CanAfford(character, currency, amount.value) then
        return nil
    end
    return {
        model = model,
        currency = currency,
        amount = amount.value,
        captured = true,
        provenanceType = 'tamed_capture',
        reasonCode = 'stables.tame_register'
    }
end

local function TamePayload(character, data)
    if not NearTrainer(character.source) then
        return nil
    end
    return TameRules(character, data.ModelH)
end

local function NotifyOrderFailure(src, result, currency)
    if result.code == 'order_pending' then
        NotifyClient(src, _U('purchasePending'))
    else
        NotifyClient(src, StablesEconomy.Message(result, currency))
    end
end

-- Owned horse or a notification, for the per-horse handlers.
local function OwnedHorse(character, horseId)
    local asset = StablesAssets.GetOwned(horseId, character.characterId)
    if not asset.ok then
        if asset.code == 'not_owner' then
            NotifyClient(character.source, _U('notYourHorse'))
        end
        return nil
    end
    return asset.value
end

-- Registers a captured horse for the character (charges Config.regCost).
function StablesFlows.Tame(character, model, name, gender)
    local payload = TameRules(character, model)
    if not payload then
        return StablesCore.Err('not_allowed', 'This horse cannot be registered now.')
    end
    payload.name = name
    payload.gender = Gender(gender)
    return StablesOrders.Run(character, 'tame_register', payload)
end

-- Moves an owned horse to another character, under the owner's order lock.
function StablesFlows.Trade(character, targetCharacterId, horseId)
    return StablesOrders.Exclusive(character, function()
        local horse = OwnedHorse(character, horseId)
        if not horse then
            return StablesCore.Err('not_owner', 'Not the owner.')
        end
        local transferred = StablesAssets.Transfer('trade:' .. StablesCore.NewId(), horse,
            character.characterId, targetCharacterId, character.source)
        if transferred.ok then
            StablesHorses.ClearSelectionsOf(horse.assetId)
        end
        return transferred
    end)
end

-- Retires an owned horse that died permanently. Replays by its request ID.
function StablesFlows.RetireDead(character, horseId)
    local horse = OwnedHorse(character, horseId)
    if not horse then
        return StablesCore.Err('not_owner', 'Not the owner.')
    end
    local retired = StablesOrders.Exclusive(character, function()
        return StablesAssets.Retire('death:' .. horse.assetId, horse.assetId, 'stables.horse_died', character.source)
    end)
    if retired.ok then
        StablesHorses.ClearSelectionsOf(horse.assetId)
    end
    return retired
end

-- Sells an owned horse to the stable: payout, then the horse is retired.
-- Returns the result, the currency and the amount in minor units.
function StablesFlows.Sell(character, horseId)
    local horse = OwnedHorse(character, horseId)
    if not horse then
        return StablesCore.Err('not_owner', 'Not the owner.')
    end
    local colorCfg = HorseConfig(horse.modelKey)
    if not colorCfg then
        return StablesCore.Err('invalid_input', 'Horse model is not configured.')
    end
    local empty = StablesInventory.IsEmpty(horse.assetId)
    if not empty.ok or not empty.value then
        return StablesCore.Err('saddlebags_not_empty', 'Empty the saddlebags first.')
    end
    local row = StablesHorses.Row(horse.assetId) or {}
    local multiplier = tonumber(row.captured) == 1 and Config.tamedSellPrice or Config.sellPrice
    local currency = StablesEconomy.Currency('cash')
    local amount = StablesEconomy.ToMinor(currency, multiplier * colorCfg.cashPrice)
    if not amount.ok then
        return amount
    end
    return StablesOrders.Run(character, 'sale', {
        assetId = horse.assetId,
        currency = currency,
        amount = amount.value,
        reasonCode = 'stables.horse_sale'
    }), currency, amount.value
end

-- Shop and purchases ---------------------------------------------------------------

StablesRPC.Register('bcc-stables:GetMyHorses', function(_, src)
    local character = Begin(src)
    if not character then
        NotifyClient(src, _U('stableUnavailable'))
        return false
    end
    StablesOrders.Resume(character)
    local horses = StablesHorses.ListForClient(character.characterId)
    if not horses.ok then
        NotifyClient(src, _U('stableUnavailable'))
        return false
    end
    return horses.value
end)

-- Preflight before the naming keyboard opens; the order itself rechecks everything.
StablesRPC.Register('bcc-stables:BuyHorse', function(data, src)
    local character = Begin(src)
    return character ~= nil and PurchasePayload(character, data) ~= nil
end)

StablesRPC.Register('bcc-stables:SaveNewHorse', function(data, src)
    local character = Begin(src)
    if not character then
        return false
    end
    local name = ValidName(data.name)
    if not name then
        NotifyClient(src, _U('invalidHorseName'))
        return false
    end
    local payload = PurchasePayload(character, data)
    if not payload then
        return false
    end
    payload.name = name
    payload.gender = Gender(data.gender)
    local result = StablesOrders.Run(character, 'purchase', payload)
    if not result.ok then
        NotifyOrderFailure(src, result, payload.currency)
        return false
    end
    NotifyClient(src, _U('purchaseSuccessful'))
    return true
end)

StablesRPC.Register('bcc-stables:RegisterHorse', function(data, src)
    local character = Begin(src)
    return character ~= nil and TamePayload(character, data) ~= nil
end)

StablesRPC.Register('bcc-stables:SaveTamedHorse', function(data, src)
    local character = Begin(src)
    if not character then
        return false
    end
    local name = ValidName(data.name)
    if not name then
        NotifyClient(src, _U('invalidHorseName'))
        return false
    end
    if not NearTrainer(src) then
        return false
    end
    local result = StablesFlows.Tame(character, data.ModelH, name, data.gender)
    if not result.ok then
        if result.code ~= 'not_allowed' then
            NotifyOrderFailure(src, result, StablesEconomy.Currency('cash'))
        end
        return false
    end
    return true
end)

-- Tack: the server prices every component the horse does not already wear,
-- charges once, then saves the components to the horse's Assets metadata.
StablesRPC.Register('bcc-stables:SaveTack', function(data, src)
    local character = Begin(src)
    if not character or type(data.components) ~= 'table' then
        return false
    end
    local horse = OwnedHorse(character, data.horseId)
    if not horse then
        return false
    end
    local owned = {}
    for _, hash in ipairs((horse.metadata or {}).components or {}) do
        owned[tostring(hash):upper()] = true
    end
    local catalog = {}
    for _, category in pairs(HorseComp) do
        for _, comp in ipairs(category) do
            catalog[comp.hash:upper()] = comp
        end
    end
    local components, cash, gold = {}, 0, 0
    for index = 1, math.min(#data.components, 32) do
        local hash = data.components[index]
        if type(hash) == 'string' and catalog[hash:upper()] then
            components[#components + 1] = catalog[hash:upper()].hash
            if not owned[hash:upper()] then
                cash = cash + (tonumber(catalog[hash:upper()].cashPrice) or 0)
                gold = gold + (tonumber(catalog[hash:upper()].goldPrice) or 0)
            end
        end
    end
    local kind = tonumber(data.currencyType) == 1 and 'gold' or 'cash'
    local currency = StablesEconomy.Currency(kind)
    local amount = StablesEconomy.ToMinor(currency, kind == 'gold' and gold or cash)
    if not amount.ok or not CanAfford(character, currency, amount.value) then
        return false
    end
    local result = StablesOrders.Run(character, 'tack', {
        assetId = horse.assetId,
        components = components,
        currency = currency,
        amount = amount.value,
        reasonCode = 'stables.tack'
    })
    if not result.ok then
        NotifyOrderFailure(src, result, currency)
        return false
    end
    if amount.value > 0 then
        NotifyClient(src, _U('purchaseSuccessful'))
    end
    return true
end)

StablesRPC.Register('bcc-stables:UpdateHorseName', function(data, src)
    local character = Begin(src)
    if not character then
        return false
    end
    local name = ValidName(data.name)
    if not name then
        NotifyClient(src, _U('invalidHorseName'))
        return false
    end
    local horse = OwnedHorse(character, data.horseId)
    if not horse then
        return false
    end
    local metadata = horse.metadata or {}
    metadata.name = name
    local updated = StablesAssets.UpdateMetadata('rename:' .. StablesCore.NewId(), horse.assetId,
        metadata, character, 'stables.rename')
    if not updated.ok then
        NotifyClient(src, _U('transactionFailed'))
        return false
    end
    return true
end)

-- Sales --------------------------------------------------------------------------

StablesRPC.Register('bcc-stables:SellMyHorse', function(data, src)
    local character = Begin(src)
    if not character then
        return false
    end
    if not NearStable(src, data.site) then
        return false
    end
    local result, currency, amount = StablesFlows.Sell(character, data.horseId)
    if not result.ok then
        if result.code == 'saddlebags_not_empty' then
            NotifyClient(src, _U('emptySaddlebags'))
        elseif result.code == 'authorization_denied' then
            NotifyClient(src, _U('saleUnavailable'))
        elseif currency then
            NotifyOrderFailure(src, result, currency)
        end
        return false
    end
    NotifyClient(src, _U('soldHorse') .. StablesEconomy.FormatMinor(currency, amount))
    return true
end)

StablesRPC.Register('bcc-stables:SellTamedHorse', function(data, src)
    local character = Begin(src)
    if not character or not Config.allowSale or not NearTrainer(src) then
        return false
    end
    local key = 'sellTame:' .. character.characterId
    if cooldowns[key] and os.difftime(os.time(), cooldowns[key]) < Config.cooldown.sellTame * 60 then
        NotifyClient(src, _U('sellCooldown'))
        return false
    end
    if Config.trainerOnly and not IsTrainer(character) then
        NotifyClient(src, _U('trainerSellHorse'))
        return false
    end
    local colorCfg = HorseConfigByHash(tonumber(data.hash))
    if not colorCfg then
        return false
    end
    local currency = StablesEconomy.Currency('cash')
    local amount = StablesEconomy.ToMinor(currency, math.ceil(Config.tamedSellPrice * colorCfg.cashPrice))
    if not amount.ok then
        return false
    end
    local result = StablesOrders.Run(character, 'tamed_sale', {
        currency = currency,
        amount = amount.value,
        reasonCode = 'stables.tamed_sale'
    })
    if not result.ok then
        if result.code == 'authorization_denied' then
            NotifyClient(src, _U('saleUnavailable'))
        else
            NotifyOrderFailure(src, result, currency)
        end
        return false
    end
    cooldowns[key] = os.time()
    NotifyClient(src, _U('soldHorse') .. StablesEconomy.FormatMinor(currency, amount.value))
    return true
end)

StablesRPC.Register('bcc-stables:CheckPlayerCooldown', function(data, src)
    local character = Begin(src)
    local cooldown = Config.cooldown[data.type]
    if not character or not cooldown then
        return false
    end
    local last = cooldowns[tostring(data.type) .. ':' .. character.characterId]
    return last ~= nil and os.difftime(os.time(), last) < cooldown * 60
end)

-- Trade ------------------------------------------------------------------------

StablesRPC.Register('bcc-stables:SaveHorseTrade', function(data, src)
    local character = Begin(src)
    local target = StablesCharacters.Get(tonumber(data.serverId))
    if not character or not target or target.characterId == character.characterId then
        NotifyClient(src, _U('tradeFailed'))
        return false
    end
    local distance = #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target.source)))
    if distance > Config.feather.tradeDistance then
        NotifyClient(src, _U('tradeTooFar'))
        return false
    end
    local result = StablesFlows.Trade(character, target.characterId, data.horseId)
    if not result.ok then
        NotifyClient(src, _U('tradeFailed'))
        return false
    end
    NotifyClient(src, _U('youGave') .. StablesCharacters.GetFullName(target.characterId) .. _U('aHorse'))
    NotifyClient(target.source, StablesCharacters.GetFullName(character.characterId) .. _U('gaveHorse'))
    return true
end)

-- Horse state ---------------------------------------------------------------------

StablesRPC.Register('bcc-stables:SelectHorse', function(data, src)
    local character = Begin(src)
    local horse = character and OwnedHorse(character, data.horseId)
    if not horse then
        return false
    end
    StablesHorses.Select(character.characterId, horse.assetId)
    return true
end)

StablesRPC.Register('bcc-stables:GetHorseData', function(_, src)
    local character = Begin(src)
    if not character then
        return false
    end
    local selectedId = StablesHorses.Selected(character.characterId)
    if not selectedId then
        NotifyClient(src, _U('noSelectedHorse'))
        return false
    end
    local asset = StablesAssets.GetOwned(selectedId, character.characterId)
    if asset.ok and asset.value.status ~= 'active' then
        NotifyClient(src, _U('noSelectedHorse'))
        return false
    end
    if not asset.ok then
        if asset.code == 'not_owner' then
            StablesHorses.ClearSelection(character.characterId)
            NotifyClient(src, _U('noSelectedHorse'))
        else
            NotifyClient(src, _U('stableUnavailable'))
        end
        return false
    end
    StablesHorses.Ensure(asset.value.assetId, false)
    return StablesHorses.ToClient(asset.value, StablesHorses.Row(asset.value.assetId), selectedId)
end)

StablesRPC.Register('bcc-stables:UpdateHorseXp', function(data, src)
    local character = Begin(src)
    local horse = character and OwnedHorse(character, data.horseId)
    if horse then
        StablesHorses.SaveXp(horse.assetId, data.xp)
    end
    return horse ~= nil
end, { windowMs = 1000, maxCalls = 5, maxPayloadBytes = 256, requireCharacter = true })

StablesRPC.Register('bcc-stables:SaveHorseStats', function(data, src)
    local character = Begin(src)
    local horse = character and OwnedHorse(character, data.horseId)
    if horse then
        StablesHorses.SaveStats(horse.assetId, data.health, data.stamina)
    end
    return horse ~= nil
end, { windowMs = 1000, maxCalls = 5, maxPayloadBytes = 256, requireCharacter = true })

StablesRPC.Register('bcc-stables:SetHorseWrithe', function(data, src)
    local character = Begin(src)
    local horse = character and OwnedHorse(character, data.horseId)
    if horse and Config.death.persistentWrithe then
        StablesHorses.SetWrithe(horse.assetId, true)
    end
    return horse ~= nil
end)

-- After death or revive. 'dead' retires the horse only when deaths are
-- permanent; 'deselect' only when that option is on; nil means revived.
StablesRPC.Register('bcc-stables:UpdateHorseStatus', function(data, src)
    local character = Begin(src)
    local horse = character and OwnedHorse(character, data.horseId)
    if not horse then
        return false
    end
    StablesHorses.SetWrithe(horse.assetId, false)
    if data.action == 'dead' and Config.death.permanent then
        return StablesFlows.RetireDead(character, horse.assetId).ok
    end
    if data.action == 'deselect' and Config.death.deselect then
        StablesHorses.ClearSelection(character.characterId)
    end
    return true
end)

StablesRPC.Register('bcc-stables:HorseReviveItem', function(_, src)
    local character = Begin(src)
    if not character then
        return false
    end
    local removed = StablesInventory.RemoveByName(src, Config.reviver, 1)
    return removed.ok
end)

-- Saddlebags ----------------------------------------------------------------------
-- Own horse: ownership check. Another player's horse (shareInventory): the
-- player must stand next to that horse entity, whose state names the asset.

StablesRPC.Register('bcc-stables:OpenInventory', function(data, src)
    local character = Begin(src)
    if not character or not StablesCore.Uuid(data.horseId) then
        return false
    end
    local assetId = data.horseId:lower()
    local entity = NearEntity(src, data.netId, Config.feather.lootDistance)
    if not entity then
        NotifyClient(src, _U('tooFar'))
        return false
    end
    local asset
    if data.looting then
        if not Config.shareInventory or Entity(entity).state.myHorseId ~= assetId then
            return false
        end
        asset = StablesAssets.Get(assetId)
        if not asset.ok or not asset.value.owner then
            return false
        end
        asset = asset.value
    else
        asset = OwnedHorse(character, assetId)
        if not asset then
            return false
        end
    end
    local registered = StablesInventory.EnsureSaddlebags(asset.assetId, asset.modelKey, asset.owner.holderId)
    if not registered.ok then
        NotifyClient(src, _U('stableUnavailable'))
        return false
    end
    return StablesInventory.OpenSaddlebags(src, asset.assetId).ok
end)

-- Jobs ---------------------------------------------------------------------------

StablesRPC.Register('bcc-stables:CheckJob', function(data, src)
    local character = Begin(src)
    if not character then
        return false
    end
    local jobs = data.trainer and Config.trainerJob or (Stables[data.site] and Stables[data.site].shop.jobs) or {}
    return {
        StablesJobs.HasAny(character.characterId, jobs),
        StablesJobs.Keys(character.characterId)
    }
end)

-- Routing: a player returning to the shared world re-resolves their horse entity.
AddEventHandler('routing.player.left.v1', function(event)
    local src = type(event) == 'table' and tonumber(event.source) or nil
    if not src then
        return
    end
    SetTimeout(3000, function()
        StablesRPC.Notify(src, 'bcc-stables:UpdateMyHorseEntity', {})
    end)
end)

-- Startup ------------------------------------------------------------------------

CreateThread(function()
    local called, result = xpcall(function()
        if DB.awaitReady(30000) ~= true then
            return StablesCore.Err('dependency_unavailable', 'Database did not become ready.')
        end
        for _, resource in ipairs({ 'feather-assets', 'feather-economy', 'feather-jobs' }) do
            local ready = StablesCore.Call(resource, 'AwaitReady', 30000)
            if not ready.ok then
                return StablesCore.Err('dependency_unavailable', resource .. ' did not become ready.')
            end
        end
        local migrated = StablesMigrations.Run()
        if not migrated.ok then
            return migrated
        end
        local inventory = StablesInventory.Start()
        if not inventory.ok then
            return inventory
        end
        StablesItems.Register()
        StablesCore.ready = true
        StablesCore.Log('startup.ready', { migrationsApplied = migrated.value.applied })
        return StablesCore.Ok(true)
    end, debug.traceback)
    if not called then
        print('[bcc-stables] startup traceback: ' .. tostring(result))
    elseif not result.ok then
        StablesCore.Log('startup.failed', { code = result.code, message = result.message })
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == 'feather-assets' or resource == 'feather-economy' or resource == 'feather-inventory'
        or resource == 'feather-jobs' or resource == 'feather-core' then
        StablesCore.ready = false
        StablesCore.Log('dependency.stopped', { resource = resource })
    end
end)
