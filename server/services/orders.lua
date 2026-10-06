-- Durable workflows for every operation that moves money.
--
-- Separate resources cannot share a transaction, so each order is recorded
-- first and then advanced step by step:
--
--   pending  -> money step (Economy charge or payout, idempotent by order ID)
--   paid     -> domain step (Assets register / metadata / retire)
--   fulfilled
--
-- A confirmed refusal (insufficient funds, permission denied) moves a pending
-- order to rejected. An unknown outcome leaves it where it is; it is retried
-- with the same idempotency key the next time the character uses the stable.
-- A domain step that can never succeed after money moved goes to review.

StablesOrders = {}

local busy = {} -- characterId -> true while an order runs

-- Codes proving a money step did not commit.
local refusals = {
    insufficient_funds = true,
    authorization_denied = true,
    invalid_input = true,
    invalid_currency = true,
    wallet_not_found = true
}

-- Codes proving a domain step can never succeed for this order.
local permanent = {
    not_owner = true,
    asset_retired = true,
    asset_not_found = true,
    idempotency_conflict = true,
    holder_type_not_allowed = true,
    invalid_input = true,
    invalid_metadata = true
}

local function Decode(row)
    local decoded, payload = pcall(json.decode, row.payload_json)
    row.payload = decoded and type(payload) == 'table' and payload or {}
    return row
end

function StablesOrders.Create(character, kind, payload)
    local orderId = StablesCore.NewId()
    DB.exec([[
        INSERT INTO `bcc_stables_orders` (`order_id`,`character_id`,`kind`,`state`,`payload_json`,`asset_id`)
        VALUES (?,?,?,?,?,?)]],
        orderId, character.characterId, kind, 'pending', json.encode(payload), payload.assetId)
    return Decode(DB.one('SELECT * FROM `bcc_stables_orders` WHERE `order_id`=?', orderId))
end

local function Save(order, state, fields)
    fields = fields or {}
    DB.exec([[
        UPDATE `bcc_stables_orders`
        SET `state`=?,`asset_id`=COALESCE(?,`asset_id`),`transaction_id`=COALESCE(?,`transaction_id`),`last_error`=?
        WHERE `order_id`=?]],
        state, fields.assetId, fields.transactionId, fields.lastError, order.order_id)
    order.state = state
    order.asset_id = fields.assetId or order.asset_id
end

local function Note(order, code)
    DB.exec('UPDATE `bcc_stables_orders` SET `last_error`=? WHERE `order_id`=?', code, order.order_id)
    StablesCore.Log('order.retry_pending', { order = order.order_id, kind = order.kind, code = code })
end

-- Money step per kind: 'charge', 'payout' or nil (free).
local moneySteps = {
    purchase = 'charge',
    tame_register = 'charge',
    tack = 'charge',
    sale = 'payout',
    tamed_sale = 'payout'
}

-- Domain step per kind, run once the money step committed.
local domainSteps = {}

domainSteps.purchase = function(order, character)
    local registered = StablesAssets.Register(order, character)
    if not registered.ok then
        return registered
    end
    local asset = registered.value
    StablesHorses.Ensure(asset.assetId, order.payload.captured == true)
    return StablesCore.Ok({ assetId = asset.assetId })
end

domainSteps.tame_register = domainSteps.purchase

domainSteps.tack = function(order, character)
    local asset = StablesAssets.GetOwned(order.payload.assetId, character.characterId)
    if not asset.ok then
        return asset
    end
    local metadata = asset.value.metadata or {}
    metadata.components = order.payload.components
    local updated = StablesAssets.UpdateMetadata('order:' .. order.order_id, asset.value.assetId,
        metadata, character, 'stables.tack', { type = 'stables_order', id = order.order_id })
    if not updated.ok then
        return updated
    end
    return StablesCore.Ok({ assetId = asset.value.assetId })
end

domainSteps.sale = function(order, character)
    local retired = StablesAssets.Retire('order:' .. order.order_id, order.payload.assetId,
        'stables.horse_sold', character.source, { type = 'stables_order', id = order.order_id })
    if not retired.ok then
        return retired
    end
    StablesHorses.ClearSelectionsOf(order.payload.assetId)
    return StablesCore.Ok({ assetId = order.payload.assetId })
end

domainSteps.tamed_sale = function()
    return StablesCore.Ok({})
end

-- Advances one order as far as it can go. Returns the order's outcome envelope.
local function Advance(order, character)
    if order.state == 'pending' then
        local step = moneySteps[order.kind]
        if step and (tonumber(order.payload.amount) or 0) > 0 then
            local moved = step == 'charge' and StablesEconomy.Charge(order, character)
                or StablesEconomy.Payout(order, character)
            if not moved.ok then
                if refusals[moved.code] then
                    Save(order, 'rejected', { lastError = moved.code })
                    return moved
                end
                Note(order, moved.code)
                return StablesCore.Err('order_pending', 'Payment outcome is unknown; it will be retried.')
            end
            Save(order, 'paid', { transactionId = type(moved.value) == 'table' and moved.value.transactionId or nil })
        else
            Save(order, 'paid')
        end
    end
    if order.state == 'paid' then
        local done = domainSteps[order.kind](order, character)
        if not done.ok then
            if permanent[done.code] then
                Save(order, 'review', { lastError = done.code })
                StablesCore.Log('order.review', { order = order.order_id, kind = order.kind, code = done.code })
                return done
            end
            Note(order, done.code)
            return StablesCore.Err('order_pending', 'Order is paid; completion will be retried.')
        end
        Save(order, 'fulfilled', { assetId = done.value.assetId })
        return StablesCore.Ok(done.value)
    end
    if order.state == 'fulfilled' then
        return StablesCore.Ok({ assetId = order.asset_id })
    end
    return StablesCore.Err('order_closed', 'Order is ' .. tostring(order.state) .. '.')
end

-- Retries the character's unfinished orders. Returns true when none remain.
function StablesOrders.Resume(character)
    local rows = DB.query([[
        SELECT * FROM `bcc_stables_orders`
        WHERE `character_id`=? AND `state` IN ('pending','paid')
        ORDER BY `created_at`]], character.characterId) or {}
    local clear = true
    for _, row in ipairs(rows) do
        local outcome = Advance(Decode(row), character)
        if not outcome.ok and outcome.code == 'order_pending' then
            clear = false
        end
    end
    return clear
end

-- Runs a new order for the character. One order at a time per character, and
-- never while an older one is still unresolved.
function StablesOrders.Run(character, kind, payload)
    if busy[character.characterId] then
        return StablesCore.Err('order_pending', 'Another stable order is running.')
    end
    busy[character.characterId] = true
    local called, result = pcall(function()
        if not StablesOrders.Resume(character) then
            return StablesCore.Err('order_pending', 'An earlier stable order is unresolved.')
        end
        return Advance(StablesOrders.Create(character, kind, payload), character)
    end)
    busy[character.characterId] = nil
    if not called then
        print('[bcc-stables] order failed: ' .. tostring(result))
        return StablesCore.Err('order_pending', 'Order was interrupted; it will be retried.')
    end
    return result
end

-- Reconciliation -----------------------------------------------------------------
-- Staff tools behind the StablesOrders* console commands. The owning character
-- may be offline: Assets and Economy work on character UUIDs.

local closedStates = {
    fulfilled = true,
    rejected = true
}

function StablesOrders.Get(orderId)
    local row = DB.one('SELECT * FROM `bcc_stables_orders` WHERE `order_id`=?', orderId)
    return row and Decode(row) or nil
end

-- Unresolved orders first (oldest first), optionally followed by recent closed ones.
function StablesOrders.List(includeClosed, limit)
    local sql = [[
        SELECT *, TIMESTAMPDIFF(MINUTE, `created_at`, CURRENT_TIMESTAMP) AS age_minutes
        FROM `bcc_stables_orders`]]
    if not includeClosed then
        sql = sql .. " WHERE `state` IN ('pending','paid','review')"
    end
    sql = sql .. " ORDER BY `state` IN ('fulfilled','rejected'), `created_at` LIMIT ?"
    local rows = DB.query(sql, limit) or {}
    for index, row in ipairs(rows) do
        rows[index] = Decode(row)
    end
    return rows
end

-- Runs an unresolved order again. A review order is sent back to its domain
-- step: review is only ever reached after the money step committed.
function StablesOrders.Retry(orderId)
    local order = StablesOrders.Get(orderId)
    if not order then
        return StablesCore.Err('order_not_found', 'Order not found.')
    end
    if closedStates[order.state] then
        return StablesCore.Err('order_closed', 'Order is already ' .. order.state .. '.')
    end
    if busy[order.character_id] then
        return StablesCore.Err('order_pending', 'The character has a stable operation running; try again.')
    end
    busy[order.character_id] = true
    local called, result = pcall(function()
        if order.state == 'review' then
            Save(order, 'paid', { lastError = order.last_error })
        end
        local source = nil
        for _, playerId in ipairs(GetPlayers()) do
            local character = StablesCharacters.Get(playerId)
            if character and character.characterId == order.character_id then
                source = character.source
            end
        end
        return Advance(order, {
            characterId = order.character_id,
            source = source
        })
    end)
    busy[order.character_id] = nil
    if not called then
        print('[bcc-stables] order retry failed: ' .. tostring(result))
        return StablesCore.Err('internal_error', 'Retry was interrupted.')
    end
    return result
end

-- Closes an unresolved order by hand after staff fixed it outside the stable
-- (for example refunded the player). Nothing is charged, paid or registered.
function StablesOrders.Resolve(orderId, outcome, note)
    local order = StablesOrders.Get(orderId)
    if not order then
        return StablesCore.Err('order_not_found', 'Order not found.')
    end
    if closedStates[order.state] then
        return StablesCore.Err('order_closed', 'Order is already ' .. order.state .. '.')
    end
    if busy[order.character_id] then
        return StablesCore.Err('order_pending', 'The character has a stable operation running; try again.')
    end
    DB.exec([[
        UPDATE `bcc_stables_orders`
        SET `state`=?,`resolution`=?,`resolved_at`=CURRENT_TIMESTAMP
        WHERE `order_id`=? AND `state` IN ('pending','paid','review')]],
        outcome, note, order.order_id)
    StablesCore.Log('order.resolved', { order = order.order_id, kind = order.kind, outcome = outcome })
    return StablesCore.Ok(order)
end

-- Holds the per-character lock around non-order operations that must not
-- interleave with orders (trades, deaths).
function StablesOrders.Exclusive(character, operation)
    if busy[character.characterId] then
        return StablesCore.Err('order_pending', 'Another stable operation is running.')
    end
    busy[character.characterId] = true
    local called, result = pcall(operation)
    busy[character.characterId] = nil
    if not called then
        print('[bcc-stables] operation failed: ' .. tostring(result))
        return StablesCore.Err('internal_error', 'Operation failed.')
    end
    return result
end
