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
    local result = DB.query('SELECT `hotels` FROM `bcchousinghotels` WHERE `character_id` = ?', charId)
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
    local character = GetHousingCharacter(src)
    if not character or not character.characterId then
        if cb then cb(false) end
        return
    end
    local charId = character.characterId

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
    DB.exec('INSERT INTO `bcchousinghotels` (`character_id`, `hotels`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `hotels` = VALUES(`hotels`)',
        charId, #ownedHotelsTable > 0 and json.encode(ownedHotelsTable) or 'none')

    if cb then cb(true, ownedHotelsTable) end
end)

-- Buys a room: a tenant interest on the hotel's property, then the payment.
-- offlineCharacter is used by the console tests (no player needed).
local function handleHotelBought(params, cb, src, offlineCharacter)
    local requestedHotel = params and params.hotel
    local hotelTable = findHotelConfig(requestedHotel and requestedHotel.hotelId)
    local character = offlineCharacter or GetHousingCharacter(src)
    if not character or not character.characterId then
        if cb then cb(false) end
        return
    end
    local charId = character.characterId

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

    if not HousingEconomy.HasFunds(charId, 'dollars', hotelCost) then
        NotifyClient(src, _U('noMoney'), 4000, "error")
        if cb then cb(false) end
        return
    end

    -- The room is a tenant interest on the hotel's property in feather-property.
    -- One ID per attempt: a failed payment ends the tenancy, and a retry must not
    -- replay the old (ended) grant.
    local attemptId = Housing.NewId()
    local hotelKey = HousingProperty.HotelKey(hotelTable.hotelId)
    local tenancy = HousingProperty.AddTenant(hotelKey, charId,
        HousingProperty.RequestId('hotel', hotelTable.hotelId, attemptId), src, 'housing.hotel')
    if not tenancy.ok then
        DBG:Error('[HotelBought] property failed', tenancy.code, tenancy.message)
        NotifyClient(src, _U(tenancy.code == 'interest_exists' and 'hotelAlreadyOwned' or 'transactionFailed'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local paid = HousingEconomy.Pay(character, 'dollars', hotelCost, 'housing.hotel',
        { type = 'housing_hotel', id = hotelTable.hotelId }, 'housing:hotel:' .. attemptId)
    if not paid.ok then
        HousingProperty.EndHolder(hotelKey, charId, HousingProperty.RequestId('hotel-undo', attemptId), src, 'housing.purchase_failed')
        NotifyClient(src, _U(HousingEconomy.MessageKey(paid, 'dollars')), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local ownedHotelsTable = loadOwnedHotels(charId)
    table.insert(ownedHotelsTable, hotelTable.hotelId)
    DB.exec('INSERT INTO `bcchousinghotels` (`character_id`, `hotels`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `hotels` = VALUES(`hotels`)',
        charId, json.encode(ownedHotelsTable))

    if cb then cb(true, ownedHotelsTable) end
end

HousingRPC:Register('bcc-housing:HotelBought', function(params, cb, src)
    handleHotelBought(params, cb, src)
end)

HousingFlows = HousingFlows or {}

function HousingFlows.BuyHotelRoom(character, hotelId)
    local result = { ok = false }
    handleHotelBought({ hotel = { hotelId = hotelId } },
        function(ok, value) result = { ok = ok, value = value } end, nil, character)
    return result
end

HousingRPC:Register('bcc-housing:RegisterHotelInventory', function(params, cb, src)
    local hotelId = params and params.hotelId
    local character = GetHousingCharacter(src)
    if not character or not character.characterId then
        if cb then cb(false) end
        return
    end
    local charId = character.characterId

    local hotelCfg = findHotelConfig(hotelId)
    if not hotelCfg or not ownsHotel(charId, hotelCfg.hotelId) then
        NotifyClient(src, _U('hotelNotOwned'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    -- One feather-inventory container per character and hotel.
    if not HousingInventory.EnsureHotelStorage(hotelCfg.hotelId, charId, _U("hotelInvName"), tonumber(hotelCfg.invSpace)) then
        if cb then cb(false) end
        return
    end
    if cb then cb(true) end
end)

HousingRPC:Register('bcc-housing:HotelInvOpen', function(params, cb, src)
    local hotelId = params and params.hotelId
    local character = GetHousingCharacter(src)
    if not character or not character.characterId then
        if cb then cb(false) end
        return
    end
    local charId = character.characterId

    local hotelCfg = findHotelConfig(hotelId)
    if not hotelCfg or not ownsHotel(charId, hotelCfg.hotelId) then
        NotifyClient(src, _U('hotelNotOwned'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local container = HousingInventory.EnsureHotelStorage(hotelCfg.hotelId, charId, _U("hotelInvName"), tonumber(hotelCfg.invSpace))
    if cb then cb(container ~= nil and HousingInventory.Open(src, container)) end
end)
