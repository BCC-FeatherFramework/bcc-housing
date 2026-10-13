-- Console, DevMode only: the house and hotel flows on feather-property with
-- nobody online. MOVES MONEY AND CHANGES HOUSES.
--
--   HousingPropertyFlowTest <characterUuid> <otherCharacterUuid>
--
-- Both characters must hold no house; the first needs money for the cheapest
-- free house that can be rented and sold (dollars), plus a hotel room. On that
-- house: the first character rents it (deposit), the second cannot end the
-- rental, the first ends it; the first buys it, sells it with its inventory to
-- the second for 1.00 (the second is given that 1.00 by the first first), can no
-- longer sell it, and the second sells it to the agent (payout created through
-- Economy). Then the first buys a hotel room, cannot buy it twice, and the room
-- is ended again. Runs the same flows as the in-game handlers, without what
-- needs a player (menus, the offer on the buyer's screen, client events).

if not Config.DevMode then return end

local function Uuid(value)
    return type(value) == 'string'
        and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
        and value:lower() or nil
end

-- The cheapest configured dollar house nobody holds that can be rented and sold.
local function FreeHouse()
    local best
    for _, house in pairs(Houses) do
        local currency = tonumber(house.currencyType) or 0
        if house.uniqueName and house.canSell and house.allowRental ~= false and currency == 0
            and (tonumber(house.price) or 0) > 0
            and not DB.one('SELECT houseid FROM bcchousing WHERE uniqueName = ?', house.uniqueName) then
            local snapshot = HousingProperty.Get(HousingProperty.HouseKey(house.uniqueName))
            if snapshot.ok and snapshot.value.status == 'active' and not HousingProperty.Holder(snapshot.value)
                and (not best or tonumber(house.price) < tonumber(best.price)) then
                best = house
            end
        end
    end
    return best
end

RegisterCommand('HousingPropertyFlowTest', function(source, args)
    if source ~= 0 then return end
    local firstId, secondId = Uuid(args[1]), Uuid(args[2])
    if not firstId or not secondId or firstId == secondId then
        return print('[HousingPropertyFlowTest] usage: HousingPropertyFlowTest <characterUuid> <otherCharacterUuid>')
    end
    for _, characterId in ipairs({ firstId, secondId }) do
        if DB.one('SELECT houseid FROM bcchousing WHERE character_id = ?', characterId) then
            return print('[HousingPropertyFlowTest] ' .. characterId .. ' already holds a house (MaxHousePerChar)')
        end
    end
    local house = FreeHouse()
    if not house then return print('[HousingPropertyFlowTest] no free house that can be rented and sold') end

    local first, second = { characterId = firstId }, { characterId = secondId }
    local key = HousingProperty.HouseKey(house.uniqueName)
    local runId = Housing.NewId()
    local passed, total = 0, 0
    local function Check(name, condition)
        total = total + 1
        if condition then passed = passed + 1 end
        print(('[HousingPropertyFlowTest] %-36s %s'):format(name, condition and 'PASS' or 'FAIL'))
    end
    local function Row() return DB.one('SELECT * FROM bcchousing WHERE uniqueName = ?', house.uniqueName) end
    local function Holder()
        local snapshot = HousingProperty.Get(key)
        local holder = snapshot.ok and HousingProperty.Holder(snapshot.value)
        return holder and holder.characterId and holder.characterId:lower() or nil
    end
    local function Balance(character) return HousingEconomy.Balance(character.characterId, 'dollars') or 0 end
    print(('[HousingPropertyFlowTest] house %s (%s): price %s, deposit %s, agent pays %s'):format(house.uniqueName,
        tostring(house.name), tostring(house.price), tostring(house.rentalDeposit), tostring(house.sellPrice)))

    local called, problem = xpcall(function()
        -- Rent, then end the rental.
        local before = Balance(first)
        local rented = HousingFlows.Purchase(first, house.houseCoords, 1)
        local row = Row()
        Check('rented', rented.ok and row ~= nil and row.ownershipStatus == 'rented'
            and HousingProperty.Holds(key, firstId, 'tenant'))
        if not rented.ok or not row then return end
        Check('deposit charged', math.abs(before - Balance(first) - (tonumber(house.rentalDeposit) or 0)) < 0.001)
        local wrongUnrent = HousingFlows.Unrent(second, row.houseid)
        Check('other character cannot end rental', not wrongUnrent.ok and Holder() == firstId)
        local unrented = HousingFlows.Unrent(first, row.houseid)
        Check('rental ended', unrented.ok and Row() == nil and Holder() == nil)

        -- Buy.
        before = Balance(first)
        local bought = HousingFlows.Purchase(first, house.houseCoords, 0)
        row = Row()
        Check('bought', bought.ok and row ~= nil and row.ownershipStatus == 'purchased'
            and HousingProperty.Holds(key, firstId, 'owner'))
        if not bought.ok or not row then return end
        Check('price charged', math.abs(before - Balance(first) - tonumber(house.price)) < 0.001)
        Wait(500) -- the deed of an offline buyer is stored on the row asynchronously
        Check('deed stored', (Row() or {}).property_deed ~= nil)

        -- Sale to the other character, with inventory.
        local funded = HousingEconomy.PayTo(first, secondId, 'dollars', 1.00, 'housing.test_fund',
            { type = 'housing_house', id = row.houseid }, 'housing:test-fund:' .. runId)
        Check('second character funded 1.00', funded.ok)
        local sold, messageKey = HousingFlows.SellToPlayer(first, second, row.houseid, 1.00, true)
        Check('sold to second character', sold == true and Holder() == secondId
            and (Row() or {}).character_id == secondId)
        if not sold then return print('[HousingPropertyFlowTest] sale failed: ' .. tostring(messageKey)) end
        local stale = HousingFlows.SellToAgent(first, row.houseid)
        Check('former owner cannot sell', not stale.ok and Holder() == secondId)

        -- Sale to the agent.
        local agent = HousingFlows.SellToAgent(second, row.houseid)
        local payout = DB.one([[SELECT status FROM bcchousing_transactions
            WHERE houseid = ? AND character_id = ? ORDER BY id DESC LIMIT 1]], row.houseid, secondId)
        Check('sold to agent', agent.ok and Row() == nil and Holder() == nil)
        Check('agent payout paid', payout ~= nil and payout.status == 'paid')
    end, debug.traceback)
    if not called then print('[HousingPropertyFlowTest] FAIL ' .. tostring(problem)) end

    -- Hotel room.
    local hotel
    for _, candidate in pairs(Hotels or {}) do
        if candidate.hotelId and not HousingProperty.Holds(HousingProperty.HotelKey(candidate.hotelId), firstId, 'tenant')
            and (not hotel or tonumber(candidate.hotelId) < tonumber(hotel.hotelId)) then
            hotel = candidate
        end
    end
    if hotel then
        local hotelKey = HousingProperty.HotelKey(hotel.hotelId)
        local room = HousingFlows.BuyHotelRoom(first, hotel.hotelId)
        Check('hotel room bought', room.ok and HousingProperty.Holds(hotelKey, firstId, 'tenant'))
        local twice = HousingFlows.BuyHotelRoom(first, hotel.hotelId)
        Check('hotel room not bought twice', not twice.ok)
        if room.ok then
            -- Test cleanup: end the tenancy and drop the room from the cache.
            local ended = HousingProperty.EndHolder(hotelKey, firstId,
                HousingProperty.RequestId('test-hotel-end', runId), nil, 'housing.test_cleanup')
            local rooms = {}
            for _, id in ipairs(type(room.value) == 'table' and room.value or {}) do
                if tonumber(id) ~= tonumber(hotel.hotelId) then rooms[#rooms + 1] = id end
            end
            DB.exec('UPDATE bcchousinghotels SET hotels = ? WHERE character_id = ?',
                #rooms > 0 and json.encode(rooms) or 'none', firstId)
            Check('hotel room ended (cleanup)', ended.ok and not HousingProperty.Holds(hotelKey, firstId, 'tenant'))
        end
    else
        print('[HousingPropertyFlowTest] the first character already has a room in every hotel; hotel checks skipped')
    end
    print(('[HousingPropertyFlowTest] done %d/%d passed (MUTATING: house %s, run %s)'):format(passed, total,
        house.uniqueName, runId))
end, true)
