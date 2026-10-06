-- bcc-stables' boundary to the Feather Framework (client side).
-- Server calls go through feather-core RPC; messages through feather-notify.

StablesRPC = {}

-- Calls a server procedure and returns its reply, or nil on transport failure.
function StablesRPC.CallAsync(name, params)
    local result, transportError = exports['feather-core']:CallRPCAsync(name, params or {})
    if result == nil and type(transportError) == 'table' then
        print(('[bcc-stables] rpc %s failed: %s'):format(name,
            tostring(transportError.code or transportError.message)))
    end
    return result
end

-- Fire and forget: the reply is not needed.
function StablesRPC.Send(name, params)
    CreateThread(function()
        StablesRPC.CallAsync(name, params)
    end)
end

-- Server-to-client procedures (item use, horse entity refresh).
function StablesRPC.Register(name, handler)
    exports['feather-core']:RegisterRPC(name, function(params, respond)
        handler(type(params) == 'table' and params or {})
        if respond then
            respond(true)
        end
    end)
end

local function Show(style, message, duration)
    local called, result = pcall(function()
        return exports['feather-notify']:ShowNotification({
            style = style,
            message = tostring(message),
            duration = tonumber(duration) or 4000
        })
    end)
    if not called or type(result) ~= 'table' or result.ok ~= true then
        print(('[bcc-stables] notification failed: %s'):format(
            called and type(result) == 'table' and tostring(result.code) or 'provider_unavailable'))
    end
end

function Notify(message, duration)
    Show(Config.feather.notifyStyle or 'right', message, duration)
end

function NotifyBottom(message, duration)
    Show('bottom_right', message, duration)
end
