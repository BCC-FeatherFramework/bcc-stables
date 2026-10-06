-- bcc-stables' boundary to feather-economy.
--
-- bcc-stables keeps no balances. Purchases move money from the character's
-- wallet into the currency's system sink. Sales pay the character from the
-- system source (Issue), which Economy only allows for trusted suppliers; until
-- that is granted, sales fail with authorization_denied and nothing changes.
-- Config prices are whole units; Economy amounts are minor units.

StablesEconomy = {}

local RESOURCE = 'feather-economy'
local precisions = {}

local function Economy(operation, request, context)
    return StablesCore.Call(RESOURCE, operation, request, context)
end

-- 'cash' or 'gold' -> Economy currency key.
function StablesEconomy.Currency(kind)
    return Config.feather.currencies[kind]
end

local function Precision(currency)
    if precisions[currency] then
        return StablesCore.Ok(precisions[currency])
    end
    local definition = Economy('GetCurrency', currency)
    if not definition.ok then
        return definition
    end
    if type(definition.value) ~= 'table' or definition.value.enabled ~= true then
        return StablesCore.Err('invalid_currency', 'Currency is unavailable.')
    end
    precisions[currency] = tonumber(definition.value.precision) or 0
    return StablesCore.Ok(precisions[currency])
end

-- Whole config price -> integer minor units, or an error.
function StablesEconomy.ToMinor(currency, price)
    price = tonumber(price)
    if not price or price ~= price or price < 0 then
        return StablesCore.Err('invalid_price', 'Price is invalid.')
    end
    local precision = Precision(currency)
    if not precision.ok then
        return precision
    end
    return StablesCore.Ok(math.floor(price * 10 ^ precision.value + 0.5))
end

function StablesEconomy.FormatMinor(currency, amount)
    local precision = precisions[currency] or 2
    return ('%.' .. precision .. 'f'):format(amount / 10 ^ precision)
end

function StablesEconomy.GetWallet(characterId, currency)
    local result = Economy('EnsureCharacterWallets', { characterId = characterId })
    if not result.ok then
        return result
    end
    for _, account in ipairs(result.value) do
        if account.accountType == 'wallet' and account.currency == currency and account.status == 'open' then
            return StablesCore.Ok(account)
        end
    end
    return StablesCore.Err('wallet_not_found', 'Economy returned no wallet for this currency.')
end

local function SystemAccount(currency, accountType)
    local result = Economy('GetSystemAccount', { currency = currency, accountType = accountType })
    if not result.ok then
        return result
    end
    return StablesCore.Ok(result.value.accountId)
end

local function Context(character, orderId)
    return {
        actorSource = character.source,
        actorAccountId = character.accountId,
        actorCharacterId = character.characterId,
        correlationId = orderId
    }
end

-- Charges an order: wallet -> system sink. Idempotent by order ID.
function StablesEconomy.Charge(order, character)
    local payload = order.payload
    local wallet = StablesEconomy.GetWallet(character.characterId, payload.currency)
    if not wallet.ok then
        return wallet
    end
    local sink = SystemAccount(payload.currency, 'system_sink')
    if not sink.ok then
        return sink
    end
    return Economy('Transfer', {
        fromAccountId = wallet.value.accountId,
        toAccountId = sink.value,
        currency = payload.currency,
        amount = payload.amount,
        reasonCode = payload.reasonCode,
        referenceType = 'stables_order',
        referenceId = order.order_id,
        idempotencyKey = 'bcc-stables:order:' .. order.order_id
    }, Context(character, order.order_id))
end

-- Pays an order out: system source -> wallet. Idempotent by order ID.
function StablesEconomy.Payout(order, character)
    local payload = order.payload
    local wallet = StablesEconomy.GetWallet(character.characterId, payload.currency)
    if not wallet.ok then
        return wallet
    end
    return Economy('Issue', {
        accountId = wallet.value.accountId,
        currency = payload.currency,
        amount = payload.amount,
        reasonCode = payload.reasonCode,
        referenceType = 'stables_order',
        referenceId = order.order_id,
        idempotencyKey = 'bcc-stables:order:' .. order.order_id
    }, Context(character, order.order_id))
end

-- Player-facing message for an Economy refusal.
function StablesEconomy.Message(result, currency)
    local code = type(result) == 'table' and result.code or nil
    if code == 'insufficient_funds' then
        return currency == StablesEconomy.Currency('gold') and _U('shortGold') or _U('shortCash')
    end
    if code == 'authorization_denied' then
        return _U('moneyUnavailable')
    end
    if code == 'dependency_unavailable' or code == 'not_ready' then
        return _U('moneyUnavailable')
    end
    return _U('transactionFailed')
end

AddEventHandler('onResourceStart', function(resource)
    if resource == RESOURCE then
        precisions = {}
    end
end)
