-- Flows shared by the RPC handlers and the console tests. A handler given a
-- character (an offline one in the tests) skips everything a player needs to be
-- online for; client events are only sent when there is a player source.
HousingFlows = HousingFlows or {}

local function NotifyPlayer(name, params, src)
    if src then HousingRPC:Notify(name, params, src) end
end

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

local function handleHousePurchase(src, houseCoords, moneyTypeParam, cb, offlineCharacter)
    local cbFn = type(cb) == 'function' and cb or nil
    if not houseCoords then
        if cbFn then cbFn(false, { error = 'invalid_coords' }) end
        return
    end

    local character = offlineCharacter or GetHousingCharacter(src)
    if not character then
        if cbFn then cbFn(false, { error = 'no_character' }) end
        return
    end

    local moneyType = tonumber(moneyTypeParam) or 0
    local isRental = moneyType == 1

    local houseCoordsJson = json.encode(houseCoords)

    local ownedHouses = DB.query('SELECT * FROM bcchousing WHERE character_id=?', character.characterId)
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
    -- 2 (Rol tokens) is refused below: Feather Economy has dollars and gold only.

    local currencyType = configuredCurrency

    local moneyAmount = tonumber(isRental and selectedHouse.rentalDeposit or selectedHouse.price) or 0
    local currency = HousingEconomy.Currency(currencyType)
    if not currency then
        NotifyClient(src, _U('currencyNotSupported'), 4000, 'error')
        if cbFn then cbFn(false, { error = 'currency_not_supported' }) end
        return
    end
    -- Early check for a friendly message; the payment itself is what decides.
    if moneyAmount > 0 and not HousingEconomy.HasFunds(character.characterId, currency, moneyAmount) then
        NotifyClient(src, _U(currency == 'gold' and 'notEnoughGold' or 'notEnoughMoney'), 4000, 'error')
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

    -- Ownership first: feather-property decides who holds the house. It refuses
    -- when someone already holds it, so two buyers can never both get it.
    local propertyKey = HousingProperty.HouseKey(selectedHouse.uniqueName)
    local purchaseId = Housing.NewId()
    local assigned = HousingProperty.Assign(propertyKey, character.characterId,
        isRental and 'tenant' or 'owner', HousingProperty.RequestId('purchase', selectedHouse.uniqueName, purchaseId),
        src, isRental and 'housing.rent' or 'housing.purchase')
    if not assigned.ok then
        pendingHousePurchases[selectedHouse.uniqueName] = nil
        DBG:Warning('handleHousePurchase: property refused', selectedHouse.uniqueName, assigned.code, assigned.message)
        NotifyClient(src, _U('housePurchaseFailed'), 4000, 'error')
        if cbFn then cbFn(false, { error = assigned.code }) end
        return
    end

    local insertOk, houseId = pcall(DB.insert, [[
        INSERT INTO `bcchousing`
            (`character_id`, `house_coords`, `house_radius_limit`, `doors`, `invlimit`, `tax_amount`,
             `tpInt`, `tpInstance`, `uniqueName`, `ownershipStatus`, `purchaseCurrencyType`,
             `poly_points`, `poly_min_z`, `poly_max_z`, `purchased_at`, `property_id`)
        SELECT
            ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, NOW(), ?
        WHERE NOT EXISTS (SELECT 1 FROM `bcchousing` WHERE `uniqueName` = ?)
    ]], character.characterId, houseCoordsJson, houseRadiusLimit, '[]', selectedHouse.invLimit, taxAmount,
        selectedHouse.tpInt, selectedHouse.tpInstance, selectedHouse.uniqueName, ownershipStatus, currencyType,
        polyPoints, polyMinZ, polyMaxZ, assigned.value.propertyId, selectedHouse.uniqueName)
    pendingHousePurchases[selectedHouse.uniqueName] = nil

    if not insertOk or not houseId or tonumber(houseId) == 0 then
        DBG:Info('handleHousePurchase: house already owned or insert failed for ' .. tostring(selectedHouse.uniqueName))
        -- Undo the ownership so the house is for sale again.
        HousingProperty.Release(propertyKey, HousingProperty.RequestId('purchase-undo', purchaseId), src, 'housing.purchase_failed')
        NotifyClient(src, _U('housePurchaseFailed'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end

    -- Payment last, so a failed payment only has to undo the row and the ownership.
    if moneyAmount > 0 then
        local paid = HousingEconomy.Pay(character, currency, moneyAmount,
            isRental and 'housing.rent_deposit' or 'housing.purchase',
            { type = 'housing_house', id = houseId }, 'housing:purchase:' .. purchaseId)
        if not paid.ok then
            DB.exec('DELETE FROM bcchousing WHERE houseid = ?', houseId)
            HousingProperty.Release(propertyKey, HousingProperty.RequestId('purchase-undo', purchaseId), src, 'housing.purchase_failed')
            NotifyClient(src, _U(HousingEconomy.MessageKey(paid, currency,
                currency == 'gold' and 'notEnoughGold' or 'notEnoughMoney')), 4000, 'error')
            if cbFn then cbFn(false, { error = paid.code }) end
            return
        end
    end

    insertHouseDoors(selectedHouse.doors, character.characterId, houseId, selectedHouse.uniqueName)
    GiveHousePropertyDocument(src, character, selectedHouse, houseId, ownershipStatus)

    NotifyPlayer('bcc-housing:clearBlips', { houseId = selectedHouse.houseId }, src)
    NotifyPlayer('bcc-housing:housePurchased', { houseCoords = coordsToPayload(selectedHouse.houseCoords) }, src)

    local displayAmount
    if currency == 'dollars' then
        displayAmount = '$' .. tostring(moneyAmount)
    else
        displayAmount = tostring(moneyAmount) .. ' ' .. _U('currencyGold')
    end

    if ownershipStatus == 'purchased' then
        NotifyClient(src, _U('housePurchaseSuccessCurrency', selectedHouse.name, displayAmount), 4000, 'success')
    else
        NotifyClient(src, _U('houseRentSuccess', selectedHouse.name, displayAmount), 4000, 'success')
    end

    Discord:sendMessage('House purchased by characterId: ' .. tostring(character.characterId) ..
        '\nHouse: ' .. selectedHouse.name .. ' was **' .. ownershipStatus .. '** for ' .. displayAmount ..
        '\nCharacter Name: ' .. tostring(character.firstname) .. ' ' .. tostring(character.lastname))

    NotifyPlayer('bcc-housing:ClientRecHouseLoad', {}, src)

    if cbFn then cbFn(true, { uniqueName = selectedHouse.uniqueName, ownershipStatus = ownershipStatus }) end
end

HousingRPC:Register('bcc-housing:buyHouse', function(params, cb, src)
    handleHousePurchase(src, params and params.houseCoords, params and params.moneyType, cb)
end)

-- Buys (moneyType 0) or rents (moneyType 1) the configured house at houseCoords.
function HousingFlows.Purchase(character, houseCoords, moneyType)
    local result = { ok = false }
    handleHousePurchase(nil, houseCoords, moneyType, function(ok, value) result = { ok = ok, value = value } end, character)
    return result
end


-- Locks the configured doors of a house for its new holder through the
-- bcc-doorlocks server API (bcc-housing never writes the doorlocks table) and
-- stores their door IDs on the house row.
function insertHouseDoors(doors, characterId, houseId, uniqueName)
    local houseConfig = nil
    for _, house in pairs(Houses) do
        if house.uniqueName == uniqueName then
            houseConfig = house
            break
        end
    end
    if not houseConfig or not houseConfig.doors or #houseConfig.doors == 0 then
        DBG:Info("No doors found for the house.")
        return
    end

    local doorIds = {}
    for _, door in pairs(houseConfig.doors) do
        local locked = door.locked ~= false
        local existing = DoorLocksAPI:GetDoorByInfo(door.doorinfo)
        if existing then
            existing:UpdateAllowedJobs({})
            existing:UpdateKeyItem('none')
            existing:UpdateAllowedIds({ characterId })
            existing:UpdateLockStatus(locked)
            doorIds[#doorIds + 1] = existing.id
        else
            local doorId = DoorLocksAPI:AddDoor(door.doorinfo, {}, 'none', { characterId }, locked)
            if doorId then
                doorIds[#doorIds + 1] = doorId
            else
                DBG:Error("Door could not be created for house", houseId, door.doorinfo)
            end
        end
    end

    if #doorIds ~= #houseConfig.doors then
        DBG:Error("Failed to insert all doors for the house.", #doorIds .. " from " .. #houseConfig.doors)
    end
    DB.exec("UPDATE bcchousing SET doors = ? WHERE houseid = ?", json.encode(doorIds), houseId)
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
