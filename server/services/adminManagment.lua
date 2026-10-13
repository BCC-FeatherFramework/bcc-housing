local function formatPurchasedAt(value)
    if not value or value == '' then
        return nil
    end

    local timestamp = tonumber(value)
    if timestamp then
        if timestamp > 9999999999 then
            timestamp = math.floor(timestamp / 1000)
        end

        return os.date("%Y-%m-%d %H:%M", timestamp)
    end

    return tostring(value):sub(1, 16)
end

local function collectAdminHouseData()
    local result = DB.query('SELECT * FROM bcchousing')
    if not result then
        DBG:Error('Error: No house data found in the database.')
        return {}
    end
    DBG:Info('House data retrieved from database:', #result, 'houses found.')

    local allHouses = {}

    for _, houseInfo in ipairs(result) do
        local houseCharacterId = houseInfo.character_id
        houseInfo.purchased_at_formatted = formatPurchasedAt(houseInfo.purchased_at)
        DBG:Info('Processing house with ID:', houseInfo.houseid, 'and character identifier:', houseCharacterId)

        if houseCharacterId then
            -- Names come from the Feather character profile (online or offline).
            houseInfo.firstName, houseInfo.lastName = HousingCharacters.GetName(tostring(houseCharacterId))
        else
            houseInfo.firstName = 'Unknown'
            houseInfo.lastName = 'Unknown'
            DBG:Info('Warning: houseCharacterId is missing for house ID:', houseInfo.houseid)
        end

        table.insert(allHouses, houseInfo)
    end

    DBG:Info('All houses prepared for client:', allHouses)
    return allHouses
end

local function pushAdminHouseData(src, houses)
    HousingRPC:Notify('bcc-housing:AdminManagementMenu', { houses = houses }, src)
end

HousingRPC:Register('bcc-housing:AdminGetAllHouses', function(_, cb, src)
    if not IsHousingAdmin(src) then
        NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    DBG:Info('AdminGetAllHouses RPC triggered by source:', src)
    local houses = collectAdminHouseData()
    pushAdminHouseData(src, houses)
    if cb then cb(true, houses) end
end)

HousingRPC:Register('bcc-house:AdminManagementDelHouse', function(params, cb, src)
    if not IsHousingAdmin(src) then
        NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local houseId = params and params.houseId
    if not houseId then
        if cb then cb(false, { error = 'invalid_house' }) end
        return
    end

    -- Property first: a configured house is released (for sale again), a
    -- staff-created house is retired. The row is deleted only when that succeeded.
    local row = DB.one('SELECT houseid, uniqueName, tax_obligation_id FROM bcchousing WHERE houseid = ?', tonumber(houseId))
    if not row then
        NotifyClient(src, _U('failedDeleteHouse'), 5000, "error")
        if cb then cb(false) end
        return
    end
    local propertyKey = HousingProperty.KeyForRow(row)
    local requestId = HousingProperty.RequestId('admin-delete', row.houseid, Housing.NewId())
    local released = (row.uniqueName and row.uniqueName ~= 'none' and row.uniqueName ~= '')
        and HousingProperty.Release(propertyKey, requestId, src, 'housing.deleted')
        or HousingProperty.Retire(propertyKey, requestId, src)
    if not released.ok and released.code ~= 'property_not_found' then
        DBG:Error('[AdminManagementDelHouse] property failed', released.code, released.message)
        NotifyClient(src, _U('failedDeleteHouse'), 5000, "error")
        if cb then cb(false) end
        return
    end

    -- An unpaid tax or rent obligation goes with the house.
    HousingContracts.CancelOpen(row, 'housing.deleted')
    local affected = DB.exec("DELETE FROM bcchousing WHERE houseid=?", row.houseid)
    if affected and affected > 0 then
        NotifyClient(src, _U('housesDeleted'), 5000, "success")
        if cb then cb(true) end
    else
        NotifyClient(src, _U('failedDeleteHouse'), 5000, "error")
        if cb then cb(false) end
    end
end)

HousingRPC:Register('bcc-house:AdminManagementChangeHouseRadius', function(params, cb, src)
    if not IsHousingAdmin(src) then
        NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local houseId = params and params.houseId
    local radius = params and params.radius
    if not houseId or not radius then
        if cb then cb(false, { error = 'invalid_params' }) end
        return
    end

    local affected = DB.exec("UPDATE bcchousing SET `house_radius_limit`=? WHERE houseid=?", radius, houseId)
    if affected and affected > 0 then
        NotifyClient(src, _U('radiusUpdatedSuccess'), 5000, "success")
        if cb then cb(true) end
    else
        NotifyClient(src, _U('radiusUpdatedFailed'), 5000, "error")
        if cb then cb(false) end
    end
end)

HousingRPC:Register('bcc-house:AdminManagementChangeInvLimit', function(params, cb, src)
    if not IsHousingAdmin(src) then
        NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local houseId = params and params.houseId
    local invLimit = params and params.invLimit
    if not houseId or not invLimit then
        if cb then cb(false, { error = 'invalid_params' }) end
        return
    end

    local affected = DB.exec("UPDATE bcchousing SET `invlimit`=? WHERE houseid=?", tostring(invLimit), houseId)
    if affected and affected > 0 then
        NotifyClient(src, _U('invUpdatedSuccess'), 5000, "success")
        if cb then cb(true) end
    else
        NotifyClient(src, _U('invUpdatedFailed'), 5000, "error")
        if cb then cb(false) end
    end
end)

HousingRPC:Register('bcc-house:AdminManagementChangeTaxAmount', function(params, cb, src)
    if not IsHousingAdmin(src) then
        NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local houseId = params and params.houseId
    local tax = params and params.tax
    if not houseId or not tax then
        if cb then cb(false, { error = 'invalid_params' }) end
        return
    end

    local affected = DB.exec("UPDATE bcchousing SET `tax_amount`=? WHERE houseid=?", tax, houseId)
    if affected and affected > 0 then
        NotifyClient(src, _U('taxUpdatedSuccess'), 5000, "success")
        if cb then cb(true) end
    else
        NotifyClient(src, _U('taxUpdatedFailed'), 5000, "error")
        if cb then cb(false) end
    end
end)

HousingRPC:Register('bcc-house:AdminReleaseHouseTaxPayment', function(params, cb, src)
    if not IsHousingAdmin(src) then
        NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
        if cb then cb(false) end
        return
    end

    local houseId = params and params.houseId
    if not houseId then
        if cb then cb(false, { error = 'invalid_house' }) end
        return
    end

    local affectedRows = DB.exec(
        "UPDATE bcchousing SET taxes_collected = 'released' WHERE houseid = ? AND taxes_collected = 'overdue'",
        houseId
    )

    if affectedRows and affectedRows > 0 then
        NotifyClient(src, _U('taxPaymentReleasedAdmin'), 5000, 'success')
        if cb then cb(true) end
        return
    end

    NotifyClient(src, _U('taxPaymentReleaseFailed'), 5000, 'error')
    if cb then cb(false) end
end)
