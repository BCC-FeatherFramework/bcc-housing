local function findHotelConfig(hotelId)
    local numericHotelId = tonumber(hotelId)
    if not numericHotelId then return nil end

    for _, hotel in pairs(Hotels or {}) do
        if tonumber(hotel.hotelId) == numericHotelId then
            return hotel
        end
    end

    return nil
end

local function loadOwnedHotels(charId)
    local result = DB.query('SELECT `hotels` FROM `bcchousinghotels` WHERE `charidentifier` = ?', charId)
    local payload = result and result[1] and result[1].hotels
    if not payload or payload == '' or payload == 'none' then
        return {}
    end

    local ok, hotels = pcall(json.decode, payload)
    return ok and type(hotels) == 'table' and hotels or {}
end

-- A room in a hotel is a tenant interest on its feather-property property.
local function ownsHotel(charId, hotelId)
    return HousingProperty.Holds(HousingProperty.HotelKey(hotelId), charId, 'tenant') == true
end

HousingRPC:Register('bcc-housing:HotelDbRegistry', function(params, cb, src)
    local user = HousingUser(src)
    if not user then if cb then cb(false) end return end

    local character = user.getUsedCharacter
    if not character or not character.charIdentifier then
        if cb then cb(false) end
        return
    end
    local charId = character.charIdentifier

    -- The character's hotel rooms are their tenant interests on hotel properties.
    local listed = Housing.Call('feather-property', 'ListPropertiesByHolder', {
        holderType = 'character', holderId = charId, interestType = 'tenant',
        propertyType = 'hotel_room', limit = 50
    })
    if not listed.ok then
        DBG:Error('[HotelDbRegistry] property list failed', listed.code, listed.message)
        if cb then cb(false) end
        return
    end
    local ownedHotelsTable = {}
    for _, property in ipairs(listed.value.items) do
        local hotelId = tonumber(tostring(property.propertyKey):match('^bcc%-housing:hotel:(%d+)$'))
        if hotelId then ownedHotelsTable[#ownedHotelsTable + 1] = hotelId end
    end

    -- Keep the local cache in step (it is only a cache).
    DB.exec('INSERT INTO `bcchousinghotels` (`charidentifier`, `hotels`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `hotels` = VALUES(`hotels`)',
        charId, #ownedHotelsTable > 0 and json.encode(ownedHotelsTable) or 'none')

    if cb then cb(true, ownedHotelsTable) end
end)

HousingRPC:Register('bcc-housing:HotelBought', function(params, cb, src)
    local requestedHotel = params and params.hotel
    local hotelTable = findHotelConfig(requestedHotel and requestedHotel.hotelId)
    local user = HousingUser(src)
    if not user then if cb then cb(false) end return end

    local character = user.getUsedCharacter
    if not character or not character.charIdentifier then
        if cb then cb(false) end
        return
    end
    local charId = character.charIdentifier

    local hotelCost = hotelTable and tonumber(hotelTable.cost)
    if not hotelTable or not hotelCost or hotelCost <= 0 then
        if cb then cb(false) end
        return
    end

    if ownsHotel(charId, hotelTable.hotelId) then
        NotifyClient(src, _U('hotelAlreadyOwned'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    if character.money < hotelCost then
        NotifyClient(src, _U('noMoney'), 4000, "error")
        if cb then cb(false) end
        return
    end

    -- The room is a tenant interest on the hotel's property in feather-property.
    local tenancy = HousingProperty.AddTenant(HousingProperty.HotelKey(hotelTable.hotelId), charId,
        HousingProperty.RequestId('hotel', hotelTable.hotelId, charId), src, 'housing.hotel')
    if not tenancy.ok and tenancy.code ~= 'interest_exists' then
        DBG:Error('[HotelBought] property failed', tenancy.code, tenancy.message)
        NotifyClient(src, _U('hotelAlreadyOwned'), 4000, 'error')
        if cb then cb(false) end
        return
    end
    DB.exec('INSERT INTO `bcchousinghotels` (`charidentifier`, `hotels`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `charidentifier` = VALUES(`charidentifier`)', charId, 'none')

    local ownedHotelsTable = loadOwnedHotels(charId)
    table.insert(ownedHotelsTable, hotelTable.hotelId)
    local updatedHotels = json.encode(ownedHotelsTable)

    character.removeCurrency(0, hotelCost)
    DB.exec('UPDATE `bcchousinghotels` SET `hotels` = ? WHERE `charidentifier` = ?', updatedHotels, charId)

    if cb then cb(true, ownedHotelsTable) end
end)

HousingRPC:Register('bcc-housing:RegisterHotelInventory', function(params, cb, src)
    local hotelId = params and params.hotelId
    local user = HousingUser(src)
    if not user then if cb then cb(false) end return end

    local character = user.getUsedCharacter
    if not character or not character.charIdentifier then
        if cb then cb(false) end
        return
    end
    local charId = character.charIdentifier

    local hotelCfg = findHotelConfig(hotelId)
    if not hotelCfg or not ownsHotel(charId, hotelCfg.hotelId) then
        NotifyClient(src, _U('hotelNotOwned'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local invId = 'bcc-housinginv:' .. tostring(hotelCfg.hotelId) .. tostring(charId)
    local isRegistered = exports.vorp_inventory:isCustomInventoryRegistered(invId)
    if isRegistered then if cb then cb(true) end return end

    local data = {
        id = invId,
        name = _U("hotelInvName"),
        limit = tonumber(hotelCfg.invSpace),
        acceptWeapons = true,
        shared = false,
        ignoreItemStackLimit = true,
        whitelistItems = false,
        UsePermissions = false,
        UseBlackList = false,
        whitelistWeapons = false
    }
    exports.vorp_inventory:registerInventory(data)
    if cb then cb(true) end
end)

HousingRPC:Register('bcc-housing:HotelInvOpen', function(params, cb, src)
    local hotelId = params and params.hotelId
    local user = HousingUser(src)
    if not user then if cb then cb(false) end return end

    local character = user.getUsedCharacter
    if not character or not character.charIdentifier then
        if cb then cb(false) end
        return
    end
    local charId = character.charIdentifier

    local hotelCfg = findHotelConfig(hotelId)
    if not hotelCfg or not ownsHotel(charId, hotelCfg.hotelId) then
        NotifyClient(src, _U('hotelNotOwned'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local invId = 'bcc-housinginv:' .. tostring(hotelCfg.hotelId) .. tostring(charId)
    if not exports.vorp_inventory:isCustomInventoryRegistered(invId) then
        local data = {
            id = invId,
            name = _U("hotelInvName"),
            limit = tonumber(hotelCfg.invSpace),
            acceptWeapons = true,
            shared = false,
            ignoreItemStackLimit = true,
            whitelistItems = false,
            UsePermissions = false,
            UseBlackList = false,
            whitelistWeapons = false
        }
        exports.vorp_inventory:registerInventory(data)
    end

    exports.vorp_inventory:openInventory(src, invId)
    if cb then cb(true) end
end)
