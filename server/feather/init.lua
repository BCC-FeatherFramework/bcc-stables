-- bcc-stables' boundary to the Feather Framework (server side).
--
-- Character identity always comes from the feather-core session of the calling
-- player; nothing the client sends is trusted as identity. Character IDs are UUIDs.

StablesCore = {}

function StablesCore.Ok(value)
    return { ok = true, value = value }
end

function StablesCore.Err(code, message, details)
    return { ok = false, code = code, message = message, details = details }
end

function DebugPrint(...)
    if not Config.devMode then
        return
    end
    local parts = {}
    for index = 1, select('#', ...) do
        local value = select(index, ...)
        parts[#parts + 1] = type(value) == 'table' and json.encode(value) or tostring(value)
    end
    -- One print per line, each ending with ^0 so the color never carries over.
    for line in (table.concat(parts, ' ') .. '\n'):gmatch('(.-)\n') do
        print('^1[DEV MODE] ^4' .. line .. '^0')
    end
end

function StablesCore.Log(event, fields)
    local parts = { ('[bcc-stables] event=%s'):format(event) }
    for key, value in pairs(fields or {}) do
        parts[#parts + 1] = ('%s=%s'):format(key, tostring(value))
    end
    print(table.concat(parts, ' '))
end

function StablesCore.Uuid(value)
    return type(value) == 'string' and #value == 36
        and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil
end

function StablesCore.NewId()
    return DB.value('SELECT UUID()')
end

-- RPC --------------------------------------------------------------------------
-- Handler shape: function(params, source) -> reply. Exceptions reply false.

StablesRPC = {}

local defaultOptions = {
    windowMs = 1000,
    maxCalls = 10,
    maxPayloadBytes = 4096,
    requireCharacter = true
}

function StablesRPC.Register(name, handler, options)
    local registered = exports['feather-core']:RegisterRPC(name, function(params, respond, src)
        local called, reply = xpcall(handler, debug.traceback, type(params) == 'table' and params or {}, src)
        if not called then
            print(('[bcc-stables] rpc %s failed: %s'):format(name, tostring(reply)))
            reply = false
        end
        respond(reply)
    end, options or defaultOptions)
    if registered ~= true then
        print(('[bcc-stables] rpc registration failed: %s'):format(name))
    end
end

-- Server-to-client procedure, fire and forget.
function StablesRPC.Notify(target, name, params)
    return exports['feather-core']:NotifyRPC(name, params or {}, target)
end

-- Notifications ----------------------------------------------------------------

function NotifyClient(src, message, duration)
    if not src or tonumber(src) == 0 then
        return
    end
    local result = exports['feather-core']:SendNotification({
        source = tonumber(src),
        style = Config.feather.notifyStyle or 'right',
        message = tostring(message),
        duration = tonumber(duration) or 4000
    })
    if type(result) ~= 'table' or result.ok ~= true then
        DebugPrint('[NotifyClient] failed', type(result) == 'table' and result.code or 'invalid_result')
    end
end

-- Characters -------------------------------------------------------------------

StablesCharacters = {}

local function IsCallable(value)
    return type(value) == 'function' or (type(value) == 'table'
        and type(rawget(value, '__cfx_functionReference')) == 'string')
end

-- The active character of a connected player, or nil.
function StablesCharacters.Get(src)
    src = tonumber(src)
    if not src or src <= 0 then
        return nil
    end
    local session = exports['feather-core']:GetSessionContext(src)
    if type(session) ~= 'table' or not session.ok or type(session.value) ~= 'table'
        or not StablesCore.Uuid(session.value.characterId) then
        return nil
    end
    return {
        source = src,
        characterId = session.value.characterId:lower(),
        accountId = session.value.accountId
    }
end

-- Display name of any character, online or offline.
function StablesCharacters.GetFullName(characterId)
    local provider = exports['feather-core']:GetProvider('character-profile', nil, 1)
    local implementation = type(provider) == 'table' and provider.ok and provider.value.implementation or nil
    if type(implementation) == 'table' and IsCallable(implementation.GetProfile) then
        local profile = implementation.GetProfile(characterId)
        if type(profile) == 'table' and profile.ok and type(profile.value) == 'table' then
            return ('%s %s'):format(profile.value.firstName or 'Unknown', profile.value.lastName or '')
        end
    end
    return 'Unknown'
end

-- Domain calls -----------------------------------------------------------------
-- Calls a Feather domain export so the invoking resource is bcc-stables, and
-- turns exceptions or malformed replies into flat error envelopes.

function StablesCore.Call(resource, operation, ...)
    if GetResourceState(resource) ~= 'started' then
        return StablesCore.Err('dependency_unavailable', resource .. ' is not started.')
    end
    local args = table.pack(...)
    local called, result = pcall(function()
        local provider = exports[resource]
        return provider[operation](provider, table.unpack(args, 1, args.n))
    end)
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return StablesCore.Err('dependency_unavailable', ('%s %s failed.'):format(resource, operation))
    end
    return result
end
