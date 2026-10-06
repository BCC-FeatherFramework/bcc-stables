-- Server-console reconciliation for stable orders (master plan: every
-- cross-domain workflow has an operator command that reports and repairs
-- incomplete operations).
--
--   StablesOrdersReport [all]
--       Lists unresolved orders (pending, paid, review); `all` adds recent closed ones.
--   StablesOrdersRetry <orderId>
--       Runs an unresolved order again with its original idempotency keys.
--   StablesOrdersResolve <orderId> <fulfilled|rejected> <note...>
--       Closes an unresolved order by hand after staff fixed it elsewhere.

local PREFIX = '[StablesOrders]'

local function Short(value)
    return value and tostring(value):sub(1, 8) or '-'
end

RegisterCommand('StablesOrdersReport', function(source, args)
    if source ~= 0 then
        return
    end
    local includeClosed = args[1] == 'all'
    local rows = StablesOrders.List(includeClosed, 50)
    if #rows == 0 then
        print(PREFIX .. ' no unresolved orders')
        return
    end
    print(('%s %-36s %-13s %-9s %-8s %-8s %-6s %s'):format(
        PREFIX, 'order', 'kind', 'state', 'char', 'asset', 'age', 'detail'))
    for _, row in ipairs(rows) do
        local detail = row.last_error or row.resolution or ''
        if row.state == 'paid' or row.state == 'review' then
            detail = ('money moved (tx %s) %s'):format(Short(row.transaction_id), detail)
        end
        print(('%s %-36s %-13s %-9s %-8s %-8s %-6s %s'):format(
            PREFIX, row.order_id, row.kind, row.state, Short(row.character_id), Short(row.asset_id),
            tostring(row.age_minutes) .. 'm', detail))
    end
    print(('%s %d order(s); retry with StablesOrdersRetry <orderId>'):format(PREFIX, #rows))
end, true)

RegisterCommand('StablesOrdersRetry', function(source, args)
    if source ~= 0 then
        return
    end
    if not StablesCore.Uuid(args[1]) then
        print(PREFIX .. ' usage: StablesOrdersRetry <orderId>')
        return
    end
    local result = StablesOrders.Retry(args[1]:lower())
    local order = StablesOrders.Get(args[1]:lower())
    print(('%s retry %s: %s state=%s code=%s'):format(PREFIX, args[1],
        result.ok and 'OK' or 'FAILED', order and order.state or '-', tostring(result.code)))
end, true)

RegisterCommand('StablesOrdersResolve', function(source, args)
    if source ~= 0 then
        return
    end
    local orderId, outcome = args[1], args[2]
    local note = table.concat(args, ' ', 3)
    if not StablesCore.Uuid(orderId) or (outcome ~= 'fulfilled' and outcome ~= 'rejected') or #note < 3 then
        print(PREFIX .. ' usage: StablesOrdersResolve <orderId> <fulfilled|rejected> <note>')
        return
    end
    local result = StablesOrders.Resolve(orderId:lower(), outcome, note:sub(1, 255))
    if not result.ok then
        print(('%s resolve %s: FAILED code=%s'):format(PREFIX, orderId, tostring(result.code)))
        return
    end
    local order = result.value
    print(('%s resolve %s: %s (was %s)'):format(PREFIX, orderId, outcome, order.state))
    if outcome == 'rejected' and order.transaction_id then
        print(('%s note: money already moved in Economy transaction %s; refund or settle it there'):format(
            PREFIX, order.transaction_id))
    end
end, true)
