-- bcc-housing's boundary to feather-property: who owns or rents a house or a
-- hotel room is a Property interest, not a column here. bcchousing.character_id
-- and bcchousinghotels only cache the holder for fast lookups; Property wins, and
-- the start-up reconciliation corrects the cache.
--
-- Property keys:
--   bcc-housing:<uniqueName>         configured house (configs/houses.lua)
--   bcc-housing:custom:<houseid>     house created by staff
--   bcc-housing:hotel:<hotelId>      hotel (one tenant interest per character)
-- A configured house or hotel is registered once and stays registered while it
-- has no holder (it is for sale); a custom house is retired when it is deleted.

HousingProperty = {}

local RESOURCE = 'feather-property'
local registered = {} -- property key -> property id

local function call(operation, request)
    return Housing.Call(RESOURCE, operation, request)
end

local function describe(result)
    if type(result) ~= 'table' then return 'invalid_result' end
    return ('%s %s'):format(tostring(result.code), tostring(result.message or ''))
end

-- Keys ---------------------------------------------------------------------------

local function safe(value)
    return (tostring(value):gsub('[^A-Za-z0-9_.:%-]', '_'))
end

function HousingProperty.HouseKey(uniqueName)
    return 'bcc-housing:' .. safe(uniqueName)
end

function HousingProperty.CustomKey(houseId)
    return 'bcc-housing:custom:' .. tostring(tonumber(houseId))
end

function HousingProperty.HotelKey(hotelId)
    return 'bcc-housing:hotel:' .. tostring(tonumber(hotelId))
end

-- The property key of a bcchousing row.
function HousingProperty.KeyForRow(row)
    if type(row) ~= 'table' then return nil end
    if row.uniqueName and row.uniqueName ~= '' and row.uniqueName ~= 'none' then
        return HousingProperty.HouseKey(row.uniqueName)
    end
    return row.houseid and HousingProperty.CustomKey(row.houseid) or nil
end

-- A stable, unique request ID for one housing action.
function HousingProperty.RequestId(action, ...)
    local parts = { 'bcc-housing', action }
    for _, part in ipairs({ ... }) do parts[#parts + 1] = safe(part) end
    local id = table.concat(parts, ':')
    return #id <= 128 and id or id:sub(1, 91) .. ':' .. Housing.NewId()
end

-- Registration ---------------------------------------------------------------------

-- Finds the property by key or registers it. Returns a Property snapshot envelope.
function HousingProperty.Ensure(propertyKey, propertyType, label, caps)
    local found = call('FindPropertyByKey', { propertyKey = propertyKey })
    if found.ok then
        registered[propertyKey] = found.value.propertyId
        return found
    end
    if found.code ~= 'property_not_found' then return found end
    caps = caps or {}
    local created = call('RegisterProperty', {
        requestId = HousingProperty.RequestId('register', propertyKey),
        propertyKey = propertyKey,
        propertyType = propertyType,
        label = tostring(label or propertyKey):sub(1, 100),
        maxOwners = caps.maxOwners,
        maxTenants = caps.maxTenants,
        reasonCode = 'housing.setup'
    })
    if created.ok then registered[propertyKey] = created.value.propertyId end
    return created
end

local function houseLabel(house)
    return (house.name and house.name ~= '' and house.name or house.uniqueName) .. ' (' .. tostring(house.uniqueName) .. ')'
end

-- One holder per house: an owner or a tenant. Roommates (allowed_ids) stay in
-- bcc-housing until feather-access exists.
local HOUSE_CAPS = { maxOwners = 1, maxTenants = 1 }

function HousingProperty.EnsureHouse(house)
    return HousingProperty.Ensure(HousingProperty.HouseKey(house.uniqueName), 'house', houseLabel(house), HOUSE_CAPS)
end

function HousingProperty.EnsureCustom(houseId, label)
    return HousingProperty.Ensure(HousingProperty.CustomKey(houseId), 'house',
        label or ('House ' .. tostring(houseId)), HOUSE_CAPS)
end

function HousingProperty.EnsureHotel(hotel)
    return HousingProperty.Ensure(HousingProperty.HotelKey(hotel.hotelId), 'hotel_room',
        hotel.name or ('Hotel ' .. tostring(hotel.hotelId)))
end

-- Registers every configured house and hotel (idempotent; runs on start).
function HousingProperty.RegisterConfigured()
    local houses, hotels, failed = 0, 0, 0
    for _, house in pairs(Houses or {}) do
        if house.uniqueName then
            local result = HousingProperty.EnsureHouse(house)
            if result.ok then houses = houses + 1 else
                failed = failed + 1
                print(('[bcc-housing] property: house %s not registered: %s'):format(tostring(house.uniqueName), describe(result)))
            end
        end
    end
    for _, hotel in pairs(Hotels or {}) do
        if hotel.hotelId then
            local result = HousingProperty.EnsureHotel(hotel)
            if result.ok then hotels = hotels + 1 else
                failed = failed + 1
                print(('[bcc-housing] property: hotel %s not registered: %s'):format(tostring(hotel.hotelId), describe(result)))
            end
        end
    end
    print(('[bcc-housing] property: %d house(s) and %d hotel(s) registered, %d failed'):format(houses, hotels, failed))
    return failed == 0
end

-- Reads -------------------------------------------------------------------------

function HousingProperty.Get(propertyKey)
    return call('FindPropertyByKey', { propertyKey = propertyKey })
end

-- The current holder of a house: { characterId, interestType, interestId } or nil.
function HousingProperty.Holder(snapshot)
    local interest = snapshot and (snapshot.owners[1] or snapshot.tenants[1])
    if not interest or interest.holderType ~= 'character' then return nil end
    return { characterId = interest.holderId, interestType = interest.interestType, interestId = interest.interestId }
end

-- Whether the character holds the property (as owner or tenant, or the given type).
function HousingProperty.Holds(propertyKey, characterId, interestType)
    if not propertyKey or type(characterId) ~= 'string' then return false end
    local result = call('CheckInterest', {
        propertyKey = propertyKey,
        holderType = 'character',
        holderId = characterId,
        interestType = interestType
    })
    if not result.ok then
        DBG:Warning('[property] check failed', propertyKey, describe(result))
        return false
    end
    return result.value.matched == true, result.value
end

-- Mutations -----------------------------------------------------------------------
-- Each takes a stable requestId so a retry never applies twice, and the player
-- who triggered it (actorSource) for the audit trail.

-- Gives a house nobody holds to a character, as owner ('owner') or tenant
-- ('tenant'). Fails with house_taken when someone already holds it.
function HousingProperty.Assign(propertyKey, characterId, interestType, requestId, actorSource, reasonCode)
    local snapshot = HousingProperty.Get(propertyKey)
    if not snapshot.ok then return snapshot end
    if snapshot.value.status ~= 'active' then
        return Housing.Err('property_unavailable', 'The property is not available.', { status = snapshot.value.status })
    end
    if HousingProperty.Holder(snapshot.value) then
        return Housing.Err('house_taken', 'Someone already holds this property.')
    end
    if interestType == 'owner' then
        return call('TransferOwnership', {
            requestId = requestId,
            propertyId = snapshot.value.propertyId,
            expectedRevision = snapshot.value.revision,
            toHolderType = 'character',
            toHolderId = characterId,
            reasonCode = reasonCode or 'housing.purchase',
            actorSource = actorSource
        })
    end
    return call('GrantInterest', {
        requestId = requestId,
        propertyId = snapshot.value.propertyId,
        expectedRevision = snapshot.value.revision,
        holderType = 'character',
        holderId = characterId,
        interestType = 'tenant',
        reasonCode = reasonCode or 'housing.rent',
        actorSource = actorSource
    })
end

-- Moves ownership from one character to another (sale between players).
function HousingProperty.Transfer(propertyKey, fromCharacterId, toCharacterId, requestId, actorSource)
    local snapshot = HousingProperty.Get(propertyKey)
    if not snapshot.ok then return snapshot end
    return call('TransferOwnership', {
        requestId = requestId,
        propertyId = snapshot.value.propertyId,
        expectedRevision = snapshot.value.revision,
        toHolderType = 'character',
        toHolderId = toCharacterId,
        fromHolderType = 'character',
        fromHolderId = fromCharacterId,
        reasonCode = 'housing.sale',
        actorSource = actorSource
    })
end

-- Grants a tenant interest on a property that may already have tenants (hotels).
function HousingProperty.AddTenant(propertyKey, characterId, requestId, actorSource, reasonCode)
    local snapshot = HousingProperty.Get(propertyKey)
    if not snapshot.ok then return snapshot end
    return call('GrantInterest', {
        requestId = requestId,
        propertyId = snapshot.value.propertyId,
        expectedRevision = snapshot.value.revision,
        holderType = 'character',
        holderId = characterId,
        interestType = 'tenant',
        reasonCode = reasonCode or 'housing.hotel',
        actorSource = actorSource
    })
end

-- Ends every owner and tenant interest (sold back, rent ended, house deleted).
-- The house stays registered and becomes available.
-- opts.holderId: the release is refused unless this character is the holder and
-- the property is active (a suspended house cannot be sold or given up). The
-- check uses the same snapshot whose revision every EndInterest expects, so a
-- suspension or a second release in between fails instead of slipping through.
function HousingProperty.Release(propertyKey, requestId, actorSource, reasonCode, opts)
    local snapshot = HousingProperty.Get(propertyKey)
    if not snapshot.ok then return snapshot end
    if opts and opts.holderId then
        if snapshot.value.status ~= 'active' then
            return Housing.Err('property_unavailable', 'The property is not active.', { status = snapshot.value.status })
        end
        local holder = HousingProperty.Holder(snapshot.value)
        if not holder or holder.characterId ~= opts.holderId then
            return Housing.Err('holder_mismatch', 'The character does not hold this property.')
        end
    end
    local interests = {}
    for _, list in ipairs({ snapshot.value.owners, snapshot.value.tenants }) do
        for _, interest in ipairs(list) do interests[#interests + 1] = interest end
    end
    local revision = snapshot.value.revision
    for _, interest in ipairs(interests) do
        local ended = call('EndInterest', {
            requestId = HousingProperty.RequestId('end', requestId, interest.interestId),
            propertyId = snapshot.value.propertyId,
            expectedRevision = revision,
            interestId = interest.interestId,
            reasonCode = reasonCode or 'housing.release',
            actorSource = actorSource
        })
        if not ended.ok then return ended end
        revision = ended.value.revision
    end
    return Housing.Ok({ propertyId = snapshot.value.propertyId, ended = #interests, revision = revision })
end

-- Ends one character's interest(s) on a property (a hotel guest leaves, or a
-- failed hotel payment is undone). Other holders are untouched.
function HousingProperty.EndHolder(propertyKey, characterId, requestId, actorSource, reasonCode)
    local snapshot = HousingProperty.Get(propertyKey)
    if not snapshot.ok then return snapshot end
    local revision = snapshot.value.revision
    for _, list in ipairs({ snapshot.value.owners, snapshot.value.tenants }) do
        for _, interest in ipairs(list) do
            if interest.holderType == 'character' and interest.holderId == characterId then
                local ended = call('EndInterest', {
                    requestId = HousingProperty.RequestId('end', requestId, interest.interestId),
                    propertyId = snapshot.value.propertyId,
                    expectedRevision = revision,
                    interestId = interest.interestId,
                    reasonCode = reasonCode or 'housing.release',
                    actorSource = actorSource
                })
                if not ended.ok then return ended end
                revision = ended.value.revision
            end
        end
    end
    return Housing.Ok({ propertyId = snapshot.value.propertyId, revision = revision })
end

-- Retires a custom house for good (its interests end in the same commit).
function HousingProperty.Retire(propertyKey, requestId, actorSource)
    local snapshot = HousingProperty.Get(propertyKey)
    if not snapshot.ok then return snapshot end
    if snapshot.value.status == 'retired' then return snapshot end
    return call('ChangePropertyStatus', {
        requestId = requestId,
        propertyId = snapshot.value.propertyId,
        expectedRevision = snapshot.value.revision,
        status = 'retired',
        reasonCode = 'housing.deleted',
        actorSource = actorSource
    })
end

-- Suspends (overdue taxes) or reactivates a house.
function HousingProperty.SetStatus(propertyKey, status, requestId, reasonCode)
    local snapshot = HousingProperty.Get(propertyKey)
    if not snapshot.ok then return snapshot end
    if snapshot.value.status == status then return snapshot end
    return call('ChangePropertyStatus', {
        requestId = requestId,
        propertyId = snapshot.value.propertyId,
        expectedRevision = snapshot.value.revision,
        status = status,
        reasonCode = reasonCode or 'housing.tax_status'
    })
end

-- Start-up ------------------------------------------------------------------------

-- Compares the cached holder of every house row with Property. Property wins: a
-- different holder updates the cache; a row whose property has no holder is
-- reported (it is not deleted automatically).
function HousingProperty.Reconcile()
    local fixed, orphaned = 0, 0
    for _, row in ipairs(DB.query('SELECT houseid, character_id, uniqueName, property_id FROM bcchousing') or {}) do
        local key = HousingProperty.KeyForRow(row)
        local snapshot = key and HousingProperty.Get(key)
        if snapshot and snapshot.ok then
            local holder = HousingProperty.Holder(snapshot.value)
            if row.property_id ~= snapshot.value.propertyId then
                DB.exec('UPDATE bcchousing SET property_id = ? WHERE houseid = ?', snapshot.value.propertyId, row.houseid)
            end
            if holder and holder.characterId ~= row.character_id then
                DB.exec('UPDATE bcchousing SET character_id = ? WHERE houseid = ?', holder.characterId, row.houseid)
                fixed = fixed + 1
            elseif not holder then
                orphaned = orphaned + 1
                print(('[bcc-housing] property: house %s (%s) has no holder in feather-property; check it with HousingPropertyStatus')
                    :format(tostring(row.houseid), key))
            end
        else
            orphaned = orphaned + 1
            print(('[bcc-housing] property: house %s (%s) is not registered: %s'):format(
                tostring(row.houseid), tostring(key), describe(snapshot)))
        end
    end
    print(('[bcc-housing] property: reconciled, %d cache fix(es), %d house(s) to check'):format(fixed, orphaned))
end

local function start()
    print('[bcc-housing] property: waiting for feather-property and the database')
    local ready = Housing.Call(RESOURCE, 'AwaitReady', 30000)
    if not ready.ok then
        return print('[bcc-housing] property: feather-property is not ready: ' .. describe(ready))
    end
    while not DbUpdated do Wait(500) end
    local called, problem = xpcall(function()
        HousingProperty.RegisterConfigured()
        HousingProperty.Reconcile()
    end, debug.traceback)
    if not called then
        return print('[bcc-housing] property: start-up failed: ' .. tostring(problem))
    end
    HousingProperty.ready = true
    print('[bcc-housing] property: ready')
end

CreateThread(start)

AddEventHandler('onResourceStart', function(resource)
    if resource == RESOURCE then
        registered = {}
        HousingProperty.ready = false
        CreateThread(start)
    end
end)

-- Console: HousingPropertyStatus <houseid>
RegisterCommand('HousingPropertyStatus', function(source, args)
    if source ~= 0 then return end
    local row = DB.one('SELECT houseid, character_id, uniqueName, property_id FROM bcchousing WHERE houseid = ?', tonumber(args[1]))
    if not row then return print('[bcc-housing] Usage: HousingPropertyStatus <houseid> (house row not found)') end
    local key = HousingProperty.KeyForRow(row)
    local snapshot = HousingProperty.Get(key)
    if not snapshot.ok then return print(('[bcc-housing] %s: %s'):format(key, describe(snapshot))) end
    local holder = HousingProperty.Holder(snapshot.value)
    print(('[bcc-housing] house %s key=%s property=%s status=%s holder=%s (%s) cache=%s'):format(
        row.houseid, key, snapshot.value.propertyId, snapshot.value.status,
        holder and holder.characterId or 'none', holder and holder.interestType or '-', tostring(row.character_id)))
end, true)
