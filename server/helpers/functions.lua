---- Pulling Essentials -----
-- The bcc-doorlocks server API, fetched on every use so a restart of
-- bcc-doorlocks (or bcc-housing starting first) never leaves a stale copy.
DoorLocksAPI = setmetatable({}, {
    __index = function(_, key)
        if GetResourceState('bcc-doorlocks') ~= 'started' then return nil end
        local ok, api = pcall(function() return exports['bcc-doorlocks']:getDoorLocksAPI() end)
        return ok and type(api) == 'table' and api[key] or nil
    end
})

DbUpdated = false -- Use this to stop taxes from running till db has been made
BCCHousingResourceStopping = false

-- The player's active character from their Core session (see server/feather/init.lua).
function GetHousingCharacter(src)
    return HousingCharacters.Get(src)
end

-- Housing staff: the console, Feather Admin administrators/owners, holders of
-- staff.housing.manage (HousingAdminGrant), or holders of a Config.Admin.jobs job.
-- Fails closed.
function IsHousingAdmin(src)
    local admin = Config.Admin or {}
    if tonumber(src) == 0 then return admin.allowConsole ~= false end
    local character = GetHousingCharacter(src)
    if not character then return false end

    local allowed, reason = HousingAuthority.IsAllowed(src)
    if allowed then
        DBG:Info('[admin] allowed', src, reason)
        return true
    end
    if HousingJobs.HoldsAny(character.characterId, admin.jobs, admin.jobRequireOnDuty) then
        DBG:Info('[admin] allowed by job', src)
        return true
    end
    DBG:Info('[admin] denied', src, reason)
    return false
end

-- True when the player's character holds the house (owner, or tenant of a rented
-- house) in feather-property.
function IsHouseOwner(src, houseId)
    local character = GetHousingCharacter(src)
    local numericHouseId = tonumber(houseId)
    if not character or not numericHouseId then return false end

    local row = DB.one('SELECT houseid, uniqueName FROM bcchousing WHERE houseid = ?', numericHouseId)
    if not row then return false end
    return HousingProperty.Holds(HousingProperty.KeyForRow(row), character.characterId) == true
end

function IsDoorOwnedByCharacter(src, doorId)
    local character = GetHousingCharacter(src)
    local numericDoorId = tonumber(doorId)
    if not character or not numericDoorId then return false end

    local houses = DB.query('SELECT houseid, uniqueName, character_id, doors FROM bcchousing WHERE doors IS NOT NULL AND doors != ?', 'none') or {}
    for _, house in ipairs(houses) do
        if HousingProperty.Holds(HousingProperty.KeyForRow(house), character.characterId) then
            local ok, doors = pcall(json.decode, house.doors)
            if ok and type(doors) == 'table' then
                for _, houseDoorId in ipairs(doors) do
                    if tonumber(houseDoorId) == numericDoorId then
                        return true
                    end
                end
            end
        end
    end

    return false
end

-- Initialize an empty table to hold player data
local PlayersTable = {}

-- Event to handle player data retrieval
HousingRPC:Register('bcc-housing:GetPlayers', function(params, cb, src)
    local data = {}
    local players = GetPlayers() -- Fetch all current players on the server

    if players and #players > 0 then
        for _, playerId in ipairs(players) do
            local Character = HousingCharacters.Get(playerId)
            if Character then
                table.insert(data, {
                    serverId = playerId,
                    PlayerName = Character.firstname .. ' ' .. Character.lastname,
                    staticid = Character.characterId,
                })
            end
        end
    else
        DBG:Info("No players returned from GetPlayers() or list is empty")
    end
    if cb then cb(true, data) else return data end
end)

-- Event to update PlayersTable with player information for availability checks
HousingRPC:Register("bcc-housing:getPlayersInfo", function(params, cb, src)
    if not table.contains(PlayersTable, src) then
        table.insert(PlayersTable, src) -- Prevent duplicate entries
    end
    if cb then cb(true) end
end)

-- Helper function to check for duplicates in PlayersTable
function table.contains(table, element)
    for _, value in ipairs(table) do
        if value == element then
            return true
        end
    end
    return false
end

function NotifyClient(src, message, durationOrType, maybeDuration)
    local defaultDuration = (Config.NotifyOptions and Config.NotifyOptions.autoClose) or 4000
    local defaultType = (Config.NotifyOptions and Config.NotifyOptions.type) or "info"

    local notifyType = defaultType
    local duration = defaultDuration

    if type(durationOrType) == "string" then
        notifyType = durationOrType
        duration = tonumber(maybeDuration) or defaultDuration
    elseif type(durationOrType) == "number" then
        duration = durationOrType
        if type(maybeDuration) == "string" then
            notifyType = maybeDuration
        end
    elseif durationOrType ~= nil then
        duration = defaultDuration
    end

    if maybeDuration == nil and notifyType ~= defaultType and type(durationOrType) == "string" then
        duration = defaultDuration
    end

    if not src or tonumber(src) == 0 then return end
    -- feather-notify through Core; the type only picks the log level here.
    local result = exports['feather-core']:SendNotification({
        source = tonumber(src),
        style = Config.NotifyStyle or 'right',
        message = tostring(message),
        duration = tonumber(duration) or defaultDuration
    })
    if type(result) ~= 'table' or result.ok ~= true then
        DBG:Error('[NotifyClient] failed', type(result) == 'table' and result.code or 'invalid_result', notifyType)
    end
end

HousingRPC:Register('bcc-housing:ServerSideRssStop', function(_, cb, src)
    if src then
        DelSpawnedFurn(src)
    end
    DB.exec("UPDATE bcchousing SET player_source_spawnedfurn='none'")
    if cb then cb(true) end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    BCCHousingResourceStopping = true
    DBG:Info("[ResourceStop] Server stopping, clearing spawned furniture state and notifying clients")
    for _, playerId in ipairs(GetPlayers()) do
        DelSpawnedFurn(tonumber(playerId))
    end
    TriggerClientEvent("bcc-housing:ClearFurnitureEvent", -1)
    -- No database writes here: the stopped resource could not receive the reply.
    -- The spawned-furniture column is reset when bcc-housing starts.
end)

AddEventHandler('playerDropped', function()
    local src = source
    if src then
        DelSpawnedFurn(src)
    end
end)
