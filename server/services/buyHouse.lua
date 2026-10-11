-- Event to handle the purchasing of a house
local pendingHousePurchases = {}

local function coordsToPayload(vec)
    if not vec then
        return { x = 0.0, y = 0.0, z = 0.0 }
    end

    return {
        x = vec.x or 0.0,
        y = vec.y or 0.0,
        z = vec.z or 0.0
    }
end

local function encodePolyPoints(points)
    if type(points) ~= 'table' or #points < 3 then
        return nil
    end

    local normalized = {}
    for _, point in ipairs(points) do
        local x = point.x or point[1]
        local y = point.y or point[2]
        if x and y then
            local z = point.z or point[3]
            local normalizedPoint = {
                x = tonumber(x) or 0.0,
                y = tonumber(y) or 0.0
            }
            if z then
                normalizedPoint.z = tonumber(z) or 0.0
            end
            normalized[#normalized + 1] = normalizedPoint
        end
    end

    if #normalized < 3 then
        return nil
    end

    return json.encode(normalized)
end

local function handleHousePurchase(src, houseCoords, moneyTypeParam, cb)
    local cbFn = type(cb) == 'function' and cb or nil
    if not houseCoords then
        if cbFn then cbFn(false, { error = 'invalid_coords' }) end
        return
    end

    local user = HousingUser(src)
    if not user then
        if cbFn then cbFn(false, { error = 'no_user' }) end
        return
    end

    local character = user.getUsedCharacter
    if not character then
        if cbFn then cbFn(false, { error = 'no_character' }) end
        return
    end

    local moneyType = tonumber(moneyTypeParam) or 0
    local isRental = moneyType == 1

    local houseCoordsJson = json.encode(houseCoords)

    local ownedHouses = DB.query('SELECT * FROM bcchousing WHERE charidentifier=?', character.charIdentifier)
    if #ownedHouses >= Config.Setup.MaxHousePerChar then
        NotifyClient(src, _U('youOwnMaximum'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end

    local selectedHouse
    for _, house in pairs(Houses) do
        if house.uniqueName and #(house.houseCoords - houseCoords) < 0.1 then
            selectedHouse = house
            break
        end
    end

    if not selectedHouse then
        NotifyClient(src, _U('houseNotFound'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end

    local rentalEnabled = selectedHouse.allowRental
    if rentalEnabled == nil then
        rentalEnabled = true
    end
    if isRental and not rentalEnabled then
        NotifyClient(src, _U('rentalDisabledNotify'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end

    local configuredCurrency = tonumber(selectedHouse.currencyType)
    if configuredCurrency == nil then
        configuredCurrency = isRental and tonumber(Config.Setup.DefaultRentalCurrency) or 0
    end
    if configuredCurrency ~= 0 and configuredCurrency ~= 1 and configuredCurrency ~= 2 then
        configuredCurrency = 0
    end

    local currencyType = configuredCurrency

    local moneyAmount = isRental and selectedHouse.rentalDeposit or selectedHouse.price
    local hasFunds
    if currencyType == 0 then
        hasFunds = character.money >= moneyAmount
    elseif currencyType == 1 then
        hasFunds = character.gold >= moneyAmount
    else
        hasFunds = (tonumber(character.rol) or 0) >= moneyAmount
    end
    if not hasFunds then
        if currencyType == 0 then
            NotifyClient(src, _U('notEnoughMoney'), 4000, 'error')
        elseif currencyType == 1 then
            NotifyClient(src, _U('notEnoughGold'), 4000, 'error')
        else
            NotifyClient(src, _U('notEnoughRol'), 4000, 'error')
        end
        if cbFn then cbFn(false) end
        return
    end

    if pendingHousePurchases[selectedHouse.uniqueName] then
        NotifyClient(src, _U('housePurchaseFailed'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end
    pendingHousePurchases[selectedHouse.uniqueName] = true

    local ownershipStatus = isRental and 'rented' or 'purchased'
    local houseRadiusLimit = tonumber(selectedHouse.houseRadiusLimit) or 0
    local taxAmount = ownershipStatus == 'purchased' and selectedHouse.taxAmount or selectedHouse.rentCharge
    local polyPoints = encodePolyPoints(selectedHouse.polyPoints)
    local polyMinZ = tonumber(selectedHouse.polyMinZ)
    local polyMaxZ = tonumber(selectedHouse.polyMaxZ)

    local insertOk, houseId = pcall(DB.insert, [[
        INSERT INTO `bcchousing`
            (`charidentifier`, `house_coords`, `house_radius_limit`, `doors`, `invlimit`, `tax_amount`,
             `tpInt`, `tpInstance`, `uniqueName`, `ownershipStatus`, `purchaseCurrencyType`,
             `poly_points`, `poly_min_z`, `poly_max_z`, `purchased_at`)
        SELECT
            ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, NOW()
        WHERE NOT EXISTS (SELECT 1 FROM `bcchousing` WHERE `uniqueName` = ?)
    ]], character.charIdentifier, houseCoordsJson, houseRadiusLimit, '[]', selectedHouse.invLimit, taxAmount,
        selectedHouse.tpInt, selectedHouse.tpInstance, selectedHouse.uniqueName, ownershipStatus, currencyType,
        polyPoints, polyMinZ, polyMaxZ, selectedHouse.uniqueName)
    pendingHousePurchases[selectedHouse.uniqueName] = nil

    if not insertOk or not houseId or tonumber(houseId) == 0 then
        DBG:Info('handleHousePurchase: house already owned or insert failed for ' .. tostring(selectedHouse.uniqueName))
        NotifyClient(src, _U('housePurchaseFailed'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end

    character.removeCurrency(currencyType, moneyAmount)
    insertHouseDoors(selectedHouse.doors, character.charIdentifier, houseId, selectedHouse.uniqueName)
    GiveHousePropertyDocument(src, character, selectedHouse, houseId, ownershipStatus)

    HousingRPC:Notify('bcc-housing:clearBlips', { houseId = selectedHouse.houseId }, src)
    HousingRPC:Notify('bcc-housing:housePurchased', { houseCoords = coordsToPayload(selectedHouse.houseCoords) }, src)

    local displayAmount
    if currencyType == 0 then
        displayAmount = '$' .. tostring(moneyAmount)
    elseif currencyType == 1 then
        displayAmount = tostring(moneyAmount) .. ' ' .. _U('currencyGold')
    else
        displayAmount = tostring(moneyAmount) .. ' ' .. _U('currencyRol')
    end

    if ownershipStatus == 'purchased' then
        NotifyClient(src, _U('housePurchaseSuccessCurrency', selectedHouse.name, displayAmount), 4000, 'success')
    else
        NotifyClient(src, _U('houseRentSuccess', selectedHouse.name, displayAmount), 4000, 'success')
    end

    Discord:sendMessage('House purchased by charIdentifier: ' .. tostring(character.charIdentifier) ..
        '\nHouse: ' .. selectedHouse.name .. ' was **' .. ownershipStatus .. '** for ' .. displayAmount ..
        '\nCharacter Name: ' .. tostring(character.firstname) .. ' ' .. tostring(character.lastname))

    HousingRPC:Notify('bcc-housing:ClientRecHouseLoad', {}, src)

    if cbFn then cbFn(true, { uniqueName = selectedHouse.uniqueName, ownershipStatus = ownershipStatus }) end
end

HousingRPC:Register('bcc-housing:buyHouse', function(params, cb, src)
    handleHousePurchase(src, params and params.houseCoords, params and params.moneyType, cb)
end)


function insertHouseDoors(doors, charidentifier, houseId, uniqueName)
    local doorIds = {} -- Store door ids to update the house later

    -- Get the house configuration from the uniqueName to ensure correct doors are inserted
    local houseConfig = nil
    for _, house in pairs(Houses) do
        if house.uniqueName == uniqueName then
            houseConfig = house
            break
        end
    end

    if houseConfig and houseConfig.doors and #houseConfig.doors > 0 then
        -- Insert each door specific to the house's unique configuration
        for _, door in pairs(houseConfig.doors) do
            local doorinfo = door.doorinfo
            local locked = door.locked and 'true' or 'false'
            local jobsAllowed = '[]' -- Default no jobs allowed
            local keyItem = 'none'   -- Default key item
            local idsAllowed = '[' .. charidentifier .. ']'

            local doorData = DB.query('SELECT * FROM `doorlocks` WHERE `doorinfo` = ?', doorinfo)
            if not doorData then
                DBG:Info("Database query failed while checking if the door exists.")
                return
            end
            if #doorData == 0 then
                -- Insert the door if it doesn't exist
                local doorId = DB.insert(
                    "INSERT INTO doorlocks (doorinfo, jobsallowedtoopen, keyitem, locked, ids_allowed) VALUES (?, ?, ?, ?, ?)",
                    doorinfo, jobsAllowed, keyItem, locked, idsAllowed
                )
                DBG:Info("Door inserted into DB with jobs: " .. jobsAllowed .. ", key: " .. keyItem .. ", ids: " .. idsAllowed)

                TriggerClientEvent('bcc-doorlocks:ClientSetDoorStatus', -1, json.decode(doorinfo), locked, true, false, false)

                -- Debug: print the values to be inserted
                DBG:Info("Door inserted with ID: ", doorId)
                table.insert(doorIds, doorId)

            else
                DBG:Info("Door already exists in DB")
                local affectedRows = DB.exec(
                    "UPDATE doorlocks SET jobsallowedtoopen = ?, keyitem = ?, locked = ?, ids_allowed = ? WHERE doorinfo = ?",
                    jobsAllowed, keyItem, locked, idsAllowed, doorinfo
                )
                assert(affectedRows > 0, "Failed to update doorlocks table with new values.")
                DBG:Info("Door updated in DB with jobs: " .. jobsAllowed .. ", key: " .. keyItem .. ", ids: " .. idsAllowed)

                if #doorData > 1 then
                    DBG:Warning("Multiple doors found with the same doorinfo:", doorData[0].doorinfo)
                    DBG:Warning("Multiple doors found with the same doorinfo:", doorData[1].doorinfo)
                end
                -- TriggerClientEvent('bcc-doorlocks:ClientSetDoorStatus', -1, json.decode(doorinfo), locked, false, false, false)
                for i = 1, #doorData do
                    local doorId = doorData[i].doorid
                    DBG:Info("Door inserted with ID: ", doorId)
                    table.insert(doorIds, doorId)
                end
            end
        end

        -- Once all doors are inserted, update the house with the door IDs
        if #doorIds ~= #houseConfig.doors then
            DBG:Error("Failed to insert all doors for the house.", #doorIds .. " from " .. #houseConfig.doors)
        end
        local doorIdsJson = json.encode(doorIds)
        local affectedDoorRows = DB.exec("UPDATE bcchousing SET doors = ? WHERE houseid = ?", doorIdsJson, houseId)
        if affectedDoorRows > 0 then
            DBG:Info("Updated house with door IDs:" .. doorIdsJson)
        else
            DBG:Error("Failed to update house with door IDs.")
        end
    else
        DBG:Info("No doors found for the house.")
    end
end

HousingRPC:Register('bcc-housing:getPurchasedHouses', function(_, cb, src)
    local purchasedHouses = {}
    local results = DB.query('SELECT uniqueName FROM bcchousing')
    if results then
        for _, row in ipairs(results) do
            for _, cfg in pairs(Houses) do
                if row.uniqueName == cfg.uniqueName then
                    table.insert(purchasedHouses, cfg.houseCoords)
                    break
                end
            end
        end
    end
    if cb then cb(true, purchasedHouses) end
end)
