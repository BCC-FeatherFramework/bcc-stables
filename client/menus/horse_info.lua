-- Read-only horse information panel on feather-menu-v2. The menu is rebuilt on
-- every open so it always shows current values.

local menus = exports['feather-menu-v2']
local menuId

local function Value(operation, response)
    if type(response) == 'table' and response.ok then
        return response.value
    end
    print(('[bcc-stables] feather-menu-v2 %s failed: %s'):format(operation,
        type(response) == 'table' and tostring(response.code) or 'no result'))
end

function HorseInfoMenu()
    local horseHealth = Citizen.InvokeNative(0x36731AC041289BB1, MyHorse, 0, Citizen.ResultAsInteger()) -- GetAttributeCoreValue
    local horseStamina = Citizen.InvokeNative(0x36731AC041289BB1, MyHorse, 1, Citizen.ResultAsInteger()) -- GetAttributeCoreValue
    local currentLevel = Citizen.InvokeNative(0x147149F2E909323C, MyHorse, 7, Citizen.ResultAsInteger()) -- GetAttributeBaseRank
    local currentXp = Citizen.InvokeNative(0x219DA04BAA9CB065, MyHorse, 7, Citizen.ResultAsInteger()) -- GetAttributePoints

    local bondingLevels = {
        Citizen.InvokeNative(0x94A7F191DB49A44D, MyModel, 7, 1), -- GetDefaultAttributePointsNeededForRank / Bonding Level
        Citizen.InvokeNative(0x94A7F191DB49A44D, MyModel, 7, 2),
        Citizen.InvokeNative(0x94A7F191DB49A44D, MyModel, 7, 3),
        Citizen.InvokeNative(0x94A7F191DB49A44D, MyModel, 7, 4)
    }

    if not Value('AwaitReady', menus:AwaitReady(5000)) then
        return
    end
    if menuId then
        menus:DestroyMenu(menuId)
        menuId = nil
    end

    local menu = Value('CreateMenu', menus:CreateMenu({
        key = 'bcc-stables:HorseInfoMenu',
        draggable = true,
        closable = true,
        persistPosition = false,
        position = { x = '3%', y = '3%' },
        size = {
            width = '500px',
            minHeight = '325px',
            height = 'auto',
            breakpoints = {
                ['720'] = '400px',
                ['1080'] = '500px',
                ['1440'] = '600px',
                ['2160'] = '800px'
            }
        },
        focus = { keyboard = true, cursor = true }
    }))
    if not menu then
        return
    end
    menuId = menu.menuId

    local page = Value('CreatePage', menus:CreatePage(menuId, { key = 'home' }))
    if not page then
        return
    end

    local sequence = 0
    local function Add(elementType, slot, value)
        sequence = sequence + 1
        Value('AddElement', menus:AddElement(menuId, page.pageId, elementType, {
            key = ('element_%d'):format(sequence),
            slot = slot,
            value = value
        }))
    end

    Add('header', 'header', HorseName)
    Add('subheader', 'header', MyHorseBreed)
    Add('textdisplay', 'header', _U('horseInfoCoat') .. MyHorseColor)
    Add('textdisplay', 'header', _U('horseInfoHealth') .. horseHealth .. ' | ' .. _U('horseInfoStamina') .. horseStamina)
    Add('textdisplay', 'header', _U('horseInfoLevel') .. currentLevel .. ' | ' .. _U('horseInfoCurXp') .. currentXp)
    Add('line', 'header')

    Add('subheader', 'content', _U('horseInfoBondLevels'))
    Add('textdisplay', 'content', _U('horseInfoLvl_1') .. bondingLevels[1] .. _U('horseInfoXp'))
    Add('textdisplay', 'content', _U('horseInfoLvl_2') .. bondingLevels[2] .. _U('horseInfoXp') .. '\n'
        .. _U('horseInfoTrickLvl_2'))
    Add('textdisplay', 'content', _U('horseInfoLvl_3') .. bondingLevels[3] .. _U('horseInfoXp') .. '\n'
        .. _U('horseInfoTrickLvl_3'))
    Add('textdisplay', 'content', _U('horseInfoLvl_4') .. bondingLevels[4] .. _U('horseInfoXp') .. '\n'
        .. _U('horseInfoTrickLvl_4a') .. '\n' .. _U('horseInfoTrickLvl_4b'))
    Add('line', 'footer')

    Value('OpenMenu', menus:OpenMenu(menuId, {
        pageId = page.pageId,
        keyboard = true,
        cursor = true,
        replace = true
    }))
end
