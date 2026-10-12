-- Payouts owed by the housing agent (sale back to the agent). The money is
-- created in the seller's wallet through Economy (policy-gated Issue). Each payout
-- is recorded with its idempotency key before it is attempted, so a payout that
-- failed (Economy unavailable) is retried later with the same key and can never
-- be paid twice. These rows are a retry queue, never a balance.
HousingPayouts = {}

function HousingPayouts.Attempt(row)
    local paid = HousingEconomy.Issue(row.identifier, row.currency or 'dollars', tonumber(row.amount) or 0,
        row.reason or 'housing.sold_to_agent', { type = 'housing_house', id = row.houseid }, row.idempotency_key)
    if paid.ok then
        DB.exec("UPDATE bcchousing_transactions SET status = 'paid' WHERE id = ?", row.id)
    end
    return paid
end

function HousingPayouts.Queue(characterId, houseId, amount, currency, reason, idempotencyKey)
    local id = DB.insert([[INSERT INTO bcchousing_transactions (houseid, identifier, amount, currency, reason, idempotency_key, status)
        VALUES (?, ?, ?, ?, ?, ?, 'pending')]], houseId, characterId, amount, currency, reason, idempotencyKey)
    return HousingPayouts.Attempt({ id = id, houseid = houseId, identifier = characterId, amount = amount,
        currency = currency, reason = reason, idempotency_key = idempotencyKey })
end

-- Retries every pending payout (or one character's).
function HousingPayouts.RetryPending(characterId)
    local rows = characterId
        and DB.query("SELECT * FROM bcchousing_transactions WHERE status = 'pending' AND identifier = ?", characterId)
        or DB.query("SELECT * FROM bcchousing_transactions WHERE status = 'pending' LIMIT 50")
    local paid = 0
    for _, row in ipairs(rows or {}) do
        if HousingPayouts.Attempt(row).ok then paid = paid + (tonumber(row.amount) or 0) end
    end
    return paid
end

CreateThread(function()
    while not DbUpdated do Wait(1000) end
    while true do
        Wait(5 * 60 * 1000)
        local called, problem = pcall(HousingPayouts.RetryPending)
        if not called then print('[bcc-housing] payouts retry failed: ' .. tostring(problem)) end
    end
end)

-- Event to handle the selling of a house
local function findHouseConfigByUniqueName(uniqueName)
    for _, config in pairs(Houses) do
        if config.uniqueName == uniqueName then
            return config
        end
    end
    return nil
end

local function handleSellHouse(src, houseIdParam, cb)
    local cbFn = type(cb) == 'function' and cb or nil
    local houseId = tonumber(houseIdParam)
    if not houseId then
        DBG:Info('handleSellHouse received invalid houseId: ' .. tostring(houseIdParam))
        if cbFn then cbFn(false, { error = 'invalid_house' }) end
        return
    end

    local user = HousingUser(src)
    if not user then
        DBG:Info('handleSellHouse: no active character for source ' .. tostring(src))
        if cbFn then cbFn(false, { error = 'no_user' }) end
        return
    end

    local character = user.getUsedCharacter
    if not character then
        DBG:Info('handleSellHouse: no character for source ' .. tostring(src))
        if cbFn then cbFn(false, { error = 'no_character' }) end
        return
    end

    local charIdentifier = character.charIdentifier
    DBG:Info(('Sell house request for houseId %s by charIdentifier %s'):format(tostring(houseId), tostring(charIdentifier)))

    local result = DB.query('SELECT * FROM bcchousing WHERE houseid = ?', houseId)
        if not result or #result == 0 then
            DBG:Info('handleSellHouse: house not found for id ' .. tostring(houseId))
            if cbFn then cbFn(false, { error = 'house_not_found' }) end
            return
        end

        local houseData = result[1]
        if houseData.ownershipStatus ~= 'purchased' then
            DBG:Info('handleSellHouse: house is not purchased, cannot be sold')
            NotifyClient(src, _U('rentedHouseCannotBeSold'), 4000, 'error')
            if cbFn then cbFn(false) end
            return
        end

        local propertyKey = HousingProperty.KeyForRow(houseData)
        if not HousingProperty.Holds(propertyKey, charIdentifier, 'owner') then
            DBG:Info('handleSellHouse: player does not own house ' .. tostring(houseId))
            NotifyClient(src, _U('noHouseOrNotOwner'), 4000, 'error')
            if cbFn then cbFn(false) end
            return
        end

        local houseConfig = findHouseConfigByUniqueName(houseData.uniqueName)
        if not houseConfig then
            DBG:Info('handleSellHouse: config not found for uniqueName ' .. tostring(houseData.uniqueName))
            NotifyClient(src, _U('houseCannotBeSold'), 4000, 'error')
            if cbFn then cbFn(false) end
            return
        end

        if not houseConfig.canSell then
            DBG:Info('handleSellHouse: house cannot be sold per config')
            NotifyClient(src, _U('houseCannotBeSold'), 4000, 'error')
            if cbFn then cbFn(false) end
            return
        end

        if tonumber(houseConfig.currencyType) == 2 then
            DBG:Info('handleSellHouse: rol currency houses cannot be sold')
            NotifyClient(src, _U('houseCannotBeSold'), 4000, 'error')
            if cbFn then cbFn(false) end
            return
        end

        local sellPrice = tonumber(houseConfig.sellPrice) or 0
        -- Ownership ends in feather-property first; the house is for sale again.
        local released = HousingProperty.Release(propertyKey,
            HousingProperty.RequestId('sell-npc', houseData.houseid, Housing.NewId()), src, 'housing.sold_to_agent')
        if not released.ok then
            DBG:Error('handleSellHouse: property release failed', released.code, released.message)
            NotifyClient(src, _U('houseCannotBeSold'), 4000, 'error')
            if cbFn then cbFn(false, { error = released.code }) end
            return
        end
        DB.exec('DELETE FROM bcchousing WHERE houseid = ?', houseData.houseid)

        if houseData.doors and houseData.doors ~= 'none' then
            local decodeOk, doorIdsJson = pcall(json.decode, houseData.doors)
            if decodeOk and type(doorIdsJson) == 'table' then
                for _, doorId in ipairs(doorIdsJson) do
                    local door = DoorLocksAPI:GetDoorById(doorId)
                    if door then door:DeleteDoor() end
                end
            end
        end

        -- The agent pays straight into the wallet; a failure stays queued and is retried.
        if sellPrice > 0 then
            local payout = HousingPayouts.Queue(charIdentifier, houseData.houseid, sellPrice, 'dollars',
                'housing.sold_to_agent', 'housing:sell-npc:' .. tostring(houseData.houseid) .. ':' .. Housing.NewId())
            if not payout.ok then
                DBG:Error('handleSellHouse: payout queued for retry', payout.code)
            end
        end

        NotifyClient(src, _U('houseSoldSuccess', sellPrice), 4000, 'success')
        Discord:sendMessage('House sold by charIdentifier: ' .. tostring(charIdentifier) .. '\nHouse ID: ' .. tostring(houseId) .. ' was sold for $' .. tostring(sellPrice))

        HousingRPC:Notify('bcc-housing:OwnsHouseClientHandler', { house = houseData, isOwner = false}, src)
        HousingRPC:Notify('bcc-housing:StopPropertyCheck', {}, src)
        HousingRPC:Notify('bcc-housing:clearBlips', { houseId = houseId }, src)
        HousingRPC:Notify('bcc-housing:ReinitializeChecksAfterSale', {}, src)

        if cbFn then cbFn(true, { amount = sellPrice }) end
end

HousingRPC:Register('bcc-housing:sellHouse', function(params, cb, src)
    handleSellHouse(src, params and params.houseId, cb)
end)

local function handleUnrentHouse(src, houseIdParam, cb)
    local cbFn = type(cb) == 'function' and cb or nil
    local houseId = tonumber(houseIdParam)
    if not houseId then
        if cbFn then cbFn(false, { error = 'invalid_house' }) end
        return
    end

    local user = HousingUser(src)
    local character = user and user.getUsedCharacter
    if not user or not character then
        if cbFn then cbFn(false, { error = 'no_character' }) end
        return
    end

    local charIdentifier = character.charIdentifier

    local result = DB.query('SELECT * FROM bcchousing WHERE houseid = ?', houseId)
        if not result or #result == 0 then
            if cbFn then cbFn(false, { error = 'house_not_found' }) end
            return
        end

        local houseData = result[1]
        if houseData.ownershipStatus ~= 'rented' then
            if cbFn then cbFn(false, { error = 'not_rented' }) end
            return
        end

        local propertyKey = HousingProperty.KeyForRow(houseData)
        if not HousingProperty.Holds(propertyKey, charIdentifier, 'tenant') then
            NotifyClient(src, _U('noHouseOrNotOwner'), 4000, 'error')
            if cbFn then cbFn(false) end
            return
        end

        -- The tenancy ends in feather-property first; the house is for rent again.
        local released = HousingProperty.Release(propertyKey,
            HousingProperty.RequestId('unrent', houseData.houseid, Housing.NewId()), src, 'housing.rent_ended')
        if not released.ok then
            DBG:Error('handleUnrentHouse: property release failed', released.code, released.message)
            if cbFn then cbFn(false, { error = released.code }) end
            return
        end
        DB.exec('DELETE FROM bcchousing WHERE houseid = ?', houseData.houseid)

        if houseData.doors and houseData.doors ~= 'none' then
            local decodeOk, doorIdsJson = pcall(json.decode, houseData.doors)
            if decodeOk and type(doorIdsJson) == 'table' then
                for _, doorId in ipairs(doorIdsJson) do
                    local door = DoorLocksAPI:GetDoorById(doorId)
                    if door then door:DeleteDoor() end
                end
            end
        end

        NotifyClient(src, _U('rentalEndedSuccess'), 4000, 'success')
        Discord:sendMessage('House rental ended by charIdentifier: ' .. tostring(charIdentifier) .. '\nHouse ID: ' .. tostring(houseId))

        HousingRPC:Notify('bcc-housing:StopPropertyCheck', {}, src)
        HousingRPC:Notify('bcc-housing:clearBlips', { houseId = houseId }, src)
        HousingRPC:Notify('bcc-housing:ReinitializeChecksAfterSale', {}, src)
        HousingRPC:Notify('bcc-housing:ClientRecHouseLoad', {}, src)

        if cbFn then cbFn(true, { houseId = houseId }) end
end

HousingRPC:Register('bcc-housing:unrentHouse', function(params, cb, src)
    handleUnrentHouse(src, params and params.houseId, cb)
end)


-- Sale to another player -------------------------------------------------------
-- The seller makes an offer; the buyer must accept it on their screen within
-- OFFER_TTL seconds. Only then does ownership move in feather-property (seller
-- must still own it) and the price move from the buyer's wallet to the seller's
-- through Economy. A failed payment moves ownership back.

local OFFER_TTL = 60
local pendingOffers = {} -- offerId -> offer

local function houseName(houseConfig, houseId)
    return (houseConfig and (houseConfig.name or houseConfig.uniqueName)) or ('#' .. tostring(houseId))
end

local function makeOffer(src, houseIdParam, targetPlayerIdParam, salePriceParam, withInventory, cb)
    local cbFn = type(cb) == 'function' and cb or nil
    local houseId = tonumber(houseIdParam)
    local targetPlayerId = tonumber(targetPlayerIdParam)
    local salePrice = tonumber(salePriceParam)
    if not houseId or not targetPlayerId or not GetPlayerName(targetPlayerId) or targetPlayerId == src then
        NotifyClient(src, _U('houseNotOwnedOrExist'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end
    if not salePrice or salePrice <= 0 or salePrice > 1000000 then
        NotifyClient(src, _U('invalidSalePrice'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end
    salePrice = math.floor(salePrice * 100 + 0.5) / 100

    local seller, buyer = GetHousingCharacter(src), GetHousingCharacter(targetPlayerId)
    if not seller or not buyer then
        NotifyClient(src, _U('houseNotOwnedOrExist'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end
    local houseData = DB.one('SELECT * FROM bcchousing WHERE houseid = ?', houseId)
    if not houseData or houseData.ownershipStatus ~= 'purchased'
        or not HousingProperty.Holds(HousingProperty.KeyForRow(houseData), seller.charIdentifier, 'owner') then
        NotifyClient(src, _U('houseNotOwnedOrExist'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end
    local houseConfig = findHouseConfigByUniqueName(houseData.uniqueName)
    if houseConfig and (not houseConfig.canSell or tonumber(houseConfig.currencyType) == 2) then
        NotifyClient(src, _U('houseCannotBeSold'), 4000, 'error')
        if cbFn then cbFn(false) end
        return
    end

    local offerId = Housing.NewId()
    pendingOffers[offerId] = {
        id = offerId, houseId = houseId, price = salePrice, withInventory = withInventory == true,
        sellerSource = src, sellerId = seller.charIdentifier, buyerSource = targetPlayerId,
        buyerId = buyer.charIdentifier, expiresAt = os.time() + OFFER_TTL
    }
    HousingRPC:Notify('bcc-housing:SaleOffer', {
        offerId = offerId,
        house = houseName(houseConfig, houseId),
        seller = seller.firstname .. ' ' .. seller.lastname,
        price = salePrice,
        withInventory = withInventory == true,
        expiresIn = OFFER_TTL
    }, targetPlayerId)
    NotifyClient(src, _U('saleOfferSent'), 4000, 'info')
    DBG:Info('[SaleOffer]', offerId, 'house', houseId, 'from', seller.charIdentifier, 'to', buyer.charIdentifier, 'for', salePrice)
    if cbFn then cbFn(true, { offerId = offerId }) end
end

local function completeSale(offer)
    local seller = { charIdentifier = offer.sellerId }
    local buyer = GetHousingCharacter(offer.buyerSource)
    local houseData = DB.one('SELECT * FROM bcchousing WHERE houseid = ?', offer.houseId)
    if not buyer or buyer.charIdentifier ~= offer.buyerId or not houseData then
        return false, 'houseNotOwnedOrExist'
    end
    local ownedByBuyer = DB.query('SELECT houseid FROM bcchousing WHERE charidentifier = ?', buyer.charIdentifier) or {}
    if #ownedByBuyer >= Config.Setup.MaxHousePerChar then
        return false, 'maxHouses'
    end
    if not HousingEconomy.HasFunds(buyer.charIdentifier, 'dollars', offer.price) then
        return false, 'noMoneyToBuyHouse'
    end

    local propertyKey = HousingProperty.KeyForRow(houseData)
    local transferred = HousingProperty.Transfer(propertyKey, offer.sellerId, buyer.charIdentifier,
        HousingProperty.RequestId('sell-player', offer.id), offer.buyerSource)
    if not transferred.ok then
        DBG:Error('[SaleOffer] property transfer failed', transferred.code, transferred.message)
        return false, 'houseCannotBeSold'
    end

    local paid = HousingEconomy.PayTo(buyer, offer.sellerId, 'dollars', offer.price, 'housing.sale',
        { type = 'housing_house', id = offer.houseId }, 'housing:sale:' .. offer.id)
    if not paid.ok then
        local undone = HousingProperty.Transfer(propertyKey, buyer.charIdentifier, offer.sellerId,
            HousingProperty.RequestId('sell-player-undo', offer.id), offer.buyerSource)
        if not undone.ok then
            print(('[bcc-housing] sale %s: payment failed and ownership could not be moved back: %s'):format(offer.id, tostring(undone.code)))
        end
        return false, HousingEconomy.MessageKey(paid, 'dollars', 'noMoneyToBuyHouse')
    end

    if offer.withInventory then
        DB.exec('UPDATE bcchousing SET charidentifier = ?, purchaseCurrencyType = 0 WHERE houseid = ?',
            buyer.charIdentifier, offer.houseId)
        SyncHouseDoors(offer.houseId) -- the locks now open for the buyer
    else
        DeleteHouseDoors(offer.houseId)
        DB.exec('UPDATE bcchousing SET charidentifier = ?, furniture = "none", doors = "none", purchaseCurrencyType = 0 WHERE houseid = ?',
            buyer.charIdentifier, offer.houseId)
    end

    local houseConfig = findHouseConfigByUniqueName(houseData.uniqueName)
    if offer.sellerSource and GetPlayerName(offer.sellerSource) then
        RemoveHousePropertyDocument(offer.sellerSource, offer.houseId)
    end
    GiveHousePropertyDocument(offer.buyerSource, buyer, houseConfig, offer.houseId, houseData.ownershipStatus)

    Discord:sendMessage(('House ID: %s was sold %s inventory by charIdentifier: %s to charIdentifier: %s for $%s'):format(
        tostring(offer.houseId), offer.withInventory and 'with' or 'without', tostring(offer.sellerId),
        tostring(buyer.charIdentifier), tostring(offer.price)))
    return true
end

HousingRPC:Register('bcc-housing:sellHouseToPlayerWithInventory', function(params, cb, src)
    makeOffer(src, params and params.houseId, params and params.targetPlayerId, params and params.salePrice, true, cb)
end)

HousingRPC:Register('bcc-housing:sellHouseToPlayerWithoutInventory', function(params, cb, src)
    makeOffer(src, params and params.houseId, params and params.targetPlayerId, params and params.salePrice, false, cb)
end)

-- The buyer's answer. Only the buyer can answer, once, before the offer expires.
HousingRPC:Register('bcc-housing:RespondSaleOffer', function(params, cb, src)
    local offer = pendingOffers[tostring(params and params.offerId)]
    local buyer = GetHousingCharacter(src)
    if not offer or not buyer or buyer.charIdentifier ~= offer.buyerId then
        NotifyClient(src, _U('saleOfferExpired'), 4000, 'error')
        return cb(false)
    end
    pendingOffers[offer.id] = nil
    local sellerOnline = offer.sellerSource and GetPlayerName(offer.sellerSource)
    if params.accept ~= true or os.time() > offer.expiresAt then
        if sellerOnline then NotifyClient(offer.sellerSource, _U('saleOfferDeclined'), 4000, 'error') end
        if params.accept == true then NotifyClient(src, _U('saleOfferExpired'), 4000, 'error') end
        return cb(false)
    end

    local ok, messageKey = completeSale(offer)
    if not ok then
        NotifyClient(src, _U(messageKey), 4000, 'error')
        if sellerOnline then NotifyClient(offer.sellerSource, _U('saleOfferFailed'), 4000, 'error') end
        return cb(false)
    end

    local priceText = tostring(offer.price)
    NotifyClient(src, _U(offer.withInventory and 'housePurchasedSuccess' or 'housePurchasedWithoutInventory', priceText), 5000, 'success')
    HousingRPC:Notify('bcc-housing:ClientRecHouseLoad', {}, src)
    if sellerOnline then
        NotifyClient(offer.sellerSource, _U(offer.withInventory and 'houseSoldSuccess' or 'houseSoldWithoutInventory', priceText), 5000, 'success')
        HousingRPC:Notify('bcc-housing:ClientRecHouseLoad', {}, offer.sellerSource)
    end
    cb(true)
end)

CreateThread(function()
    while true do
        Wait(15000)
        local now = os.time()
        for id, offer in pairs(pendingOffers) do
            if now > offer.expiresAt + 5 then pendingOffers[id] = nil end
        end
    end
end)

-- Agent payouts ------------------------------------------------------------------

-- Payouts from sales to the agent that are still pending (Economy was unavailable).
HousingRPC:Register('bcc-housing:RequestSoldHouses', function(params, cb, src)
    local character = GetHousingCharacter(src)
    if not character then return cb(false) end
    local soldHouses = {}
    for _, row in ipairs(DB.query("SELECT houseid, amount FROM bcchousing_transactions WHERE identifier = ? AND status = 'pending'",
        character.charIdentifier) or {}) do
        soldHouses[#soldHouses + 1] = { houseId = row.houseid, amount = tonumber(row.amount) or 0 }
    end
    cb(soldHouses)
end)

-- Retries the character's pending payouts now.
HousingRPC:Register('bcc-housing:collectHouseSaleMoneyFromNpc', function(_, cb, src)
    local character = GetHousingCharacter(src)
    if not character then return cb(false, { error = 'no_character' }) end
    local paid = HousingPayouts.RetryPending(character.charIdentifier)
    if paid > 0 then
        NotifyClient(src, _U('collectedHouseSalesMoney', paid), 4000, 'success')
        Discord:sendMessage('House sale payout retried for charIdentifier: ' .. tostring(character.charIdentifier) ..
            '\nPaid $' .. tostring(paid) .. ' from house sales.')
        return cb(true, { amount = paid })
    end
    NotifyClient(src, _U('noMoneyToCollect'), 4000, 'error')
    cb(false)
end)
