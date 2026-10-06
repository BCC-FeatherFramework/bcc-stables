-- Advertises bcc-stables' player commands in feather-chat. The developer-only
-- commands (horseSetWild, horseWrithe) are intentionally not advertised.
-- Descriptions use the server language: bcc-stables keeps its own locale files.

local registered = false

local function Register()
    if registered or GetResourceState('feather-chat') ~= 'started' then
        return
    end
    local health = exports['feather-chat']:GetHealth()
    if type(health) ~= 'table' or not health.ok or health.value.state ~= 'ready' then
        return
    end
    local definitions = {
        {
            key = 'bcc-stables.horse-respawn',
            trigger = '/' .. Config.commands.horseRespawn,
            description = _U('chatSuggestionHorseRespawn')
        },
        {
            key = 'bcc-stables.horse-info',
            trigger = '/' .. Config.commands.horseInfo,
            description = _U('chatSuggestionHorseInfo')
        }
    }
    for _, definition in ipairs(definitions) do
        local result = exports['feather-chat']:RegisterSuggestion(definition)
        if not result.ok and result.code ~= 'conflict' then
            print(('[bcc-stables] chat suggestion %s failed: %s'):format(definition.trigger, tostring(result.code)))
            return
        end
    end
    registered = true
end

AddEventHandler('chat.ready.v1', Register)

AddEventHandler('onResourceStop', function(resource)
    if resource == 'feather-chat' then
        registered = false
    end
end)

CreateThread(Register)
