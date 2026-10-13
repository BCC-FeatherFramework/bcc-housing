-- Interiors (hotel rooms and teleport houses) run in their own routing buckets,
-- owned by feather-routing. The client only asks to enter a hotel or a house;
-- the server checks the player may, picks the route and moves them. The client
-- never chooses a bucket number.
--   hotel room: private, one route per character and hotel
--   teleport house: shared by the holder and roommates, one route per house

local Routing = 'feather-routing'

local function joinRoute(src, key)
    local route = Housing.Call(Routing, 'CreateRoute', { key = key, mode = 'strict', populationEnabled = false })
    if not route.ok then return route end
    local routeId = route.value.routeId or route.value.id
    -- CreateRoute takes one spec table; JoinRoute takes (routeId, source).
    local called, joined = pcall(function() return exports[Routing]:JoinRoute(routeId, src) end)
    if not called or type(joined) ~= 'table' then
        return Housing.Err('dependency_unavailable', 'feather-routing JoinRoute failed.')
    end
    return joined
end

local function mayEnterHouse(src, houseId)
    if IsHouseOwner(src, houseId) or IsHousingAdmin(src) then return true end
    local character = GetHousingCharacter(src)
    local row = character and DB.one('SELECT allowed_ids FROM bcchousing WHERE houseid = ?', houseId)
    local ok, allowed = pcall(json.decode, row and row.allowed_ids or '[]')
    for _, id in ipairs(ok and type(allowed) == 'table' and allowed or {}) do
        if tostring(id) == character.characterId then return true end
    end
    return false
end

-- params: { kind = 'hotel', hotelId } or { kind = 'house', houseId }
HousingRPC:Register('bcc-housing:EnterInstance', function(params, cb, src)
    local character = GetHousingCharacter(src)
    if not character then return cb(false, { error = 'no_character' }) end
    local key
    if params.kind == 'hotel' then
        local hotelId = tonumber(params.hotelId)
        if not hotelId or not HousingProperty.Holds(HousingProperty.HotelKey(hotelId), character.characterId, 'tenant') then
            NotifyClient(src, _U('hotelNotOwned'), 4000, 'error')
            return cb(false, { error = 'not_allowed' })
        end
        key = ('hotel:%d:%s'):format(hotelId, character.characterId)
    elseif params.kind == 'house' then
        local houseId = tonumber(params.houseId)
        if not houseId or not mayEnterHouse(src, houseId) then
            NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
            return cb(false, { error = 'not_allowed' })
        end
        key = ('house:%d'):format(houseId)
    else
        return cb(false, { error = 'invalid_kind' })
    end
    local joined = joinRoute(src, key)
    if not joined.ok then
        DBG:Error('[Instance] join failed', key, joined.code, joined.message)
        return cb(false, { error = joined.code })
    end
    cb(true)
end)

HousingRPC:Register('bcc-housing:LeaveInstance', function(_, cb, src)
    local left = Housing.Call(Routing, 'LeaveRoute', src)
    if not left.ok then DBG:Error('[Instance] leave failed', left.code) end
    cb(left.ok == true)
end)
