HouseCoords, HouseRadius, HouseId, Owner, TpHouse, TpHouseInstance, HouseOwnershipStatus, HouseTaxesOverdue, HouseTaxPaymentReleased, HousePurchasedAt = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
ActiveHouseId = nil
OwnedHouseContexts = OwnedHouseContexts or {}
HouseBlips, HotelBlips = {}, {}
local AdminAllowed = false
local OwnedHotels = {}
local HotelHandlerStarted = false

local DefaultHotelInterior = {
    enter = vector3(-325.29, 765.23, 121.64),
    inventory = vector3(-325.41, 766.9, 121.63),
    heading = 180.0
}

function SetActiveHouseContext(houseData)
    if not houseData then return end
    HouseCoords = houseData.coords or HouseCoords
    HouseRadius = houseData.radius or HouseRadius
    HouseId = houseData.houseId or HouseId
    ActiveHouseId = HouseId
    Owner = houseData.owner or Owner
    HouseOwnershipStatus = houseData.ownershipStatus or HouseOwnershipStatus
    if houseData.taxesOverdue ~= nil then
        HouseTaxesOverdue = houseData.taxesOverdue
    end
    if houseData.taxPaymentReleased ~= nil then
        HouseTaxPaymentReleased = houseData.taxPaymentReleased
    end
    HousePurchasedAt = houseData.purchasedAtFormatted or houseData.purchasedAt or HousePurchasedAt
    TpHouse = houseData.tpInt or houseData.tpHouse or TpHouse
    TpHouseInstance = houseData.tpInstance or TpHouseInstance
    ActiveHousePolyPoints = houseData.polyPoints
    ActiveHousePolyMinZ = houseData.polyMinZ
    ActiveHousePolyMaxZ = houseData.polyMaxZ
    ActiveHouseZone = houseData.zone
end

function GetHouseContext(houseId)
    if not houseId or not OwnedHouseContexts then return nil end
    return OwnedHouseContexts[houseId]
end

local function checkIfAdmin()
    local isAdmin = HousingRPC:CallAsync('bcc-housing:CheckIfAdmin')
    AdminAllowed = isAdmin == true
    return AdminAllowed
end

CreateThread(function()
    Wait(1000)
    for _, suggestion in ipairs(Config.CommandSuggestions or {}) do
        local commandName = Config[suggestion.commandConfig]
        if commandName and commandName ~= '' then
            TriggerEvent('chat:addSuggestion', '/' .. commandName, suggestion.help, suggestion.params or {})
        end
    end
end)

RegisterCommand(Config.AdminManagementMenuCommand, function(_, args)
    if not AdminAllowed then
        checkIfAdmin()
    end

    if AdminAllowed then
        HouseManagementMenu()
    end
end, false)

if Config.OpenHousingMenuCommand and Config.OpenHousingMenuCommand ~= '' then
    RegisterCommand(Config.OpenHousingMenuCommand, function(_, args)
        if not HouseId then
            Notify(_U("noHouseFound"), 'error', 4000)
            return
        end

        if not HouseCoords then
            Notify(_U("noHouseFound"), 'error', 4000)
            return
        end

        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        local accessContext = {
            coords = HouseCoords,
            radius = tonumber(HouseRadius) or tonumber(Config.DefaultMenuManageRadius) or 2.0,
            zone = ActiveHouseZone
        }

        if not IsPointInsideHousingArea(accessContext, playerCoords) then
            Notify(_U("needToBeNearHouse"), 'error', 4000)
            return
        end

        local successOwner, ownerData = HousingRPC:CallAsync('bcc-housing:getHouseOwner', { houseId = HouseId })
        if successOwner and ownerData then
            if ownerData.taxesOverdue then
                Notify(_U("taxesOverdue"), 'error', 5000)
                return
            end

            OpenHousingMainMenu(HouseId, ownerData.isOwner, ownerData.ownershipStatus, ownerData.taxPaymentReleased)
            return
        end

        local err = ownerData and ownerData.error or _U("noHouseOrNotOwner")
        Notify(err, 'error', 4000)
    end, false)
end

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    CreateThread(function()
        Wait(1000) -- wait for other scripts/player state to finish initializing after restart
        HousingRPC:CallAsync('bcc-housing:CheckIfHasHouse', {})
    end)
end)

function ManageHotelBlips()
    for _, hotelCfg in pairs(Hotels) do
        if hotelCfg.blip and hotelCfg.blip.show and not hotelCfg.Blip then
            hotelCfg.Blip = HousingBlips:SetBlip(hotelCfg.blip.name, hotelCfg.blip.sprite, hotelCfg.blip.scale, hotelCfg.location.x, hotelCfg.location.y, hotelCfg.location.z)
            local blipModifier = HousingBlips:AddBlipModifier(hotelCfg.Blip, Config.BlipColors[hotelCfg.blip.color])
            blipModifier:ApplyModifier()
            table.insert(HotelBlips, hotelCfg.Blip)
        end
    end
end

local function StartForCharacter()
    CreateThread(RefreshPurchasedHouses) -- houses for sale: prompt, marker and blip
    HousingRPC:Notify('bcc-housing:getPlayersInfo', {})
    checkIfAdmin()
    local success, hotels = HousingRPC:CallAsync('bcc-housing:HotelDbRegistry', {})
    if success and type(hotels) == 'table' then
        OwnedHotels = hotels
    else
        OwnedHotels = {}
    end
    HousingRPC:CallAsync('bcc-housing:CheckIfHasHouse', {})
    ManageHotelBlips()
    if not HotelHandlerStarted then
        HotelHandlerStarted = true
        MainHotelHandler()
    end
end

RegisterNetEvent('Feather:Character:Spawned', function()
    StartForCharacter()
end)

-- Feather:Character:Spawned fires once; catch up after a resource restart.
CreateThread(function()
    Wait(2000)
    local ok, active = pcall(function() return exports['feather-character']:HasActiveCharacter() end)
    if ok and active == true then StartForCharacter() end
end)

local function handleOwnsHouseClient(houseTable, owner)
    local coords = json.decode(houseTable.house_coords)
    local vectorCoords = vector3(coords.x, coords.y, coords.z)
    local radius = houseTable.house_radius_limit
    local houseId = houseTable.houseid
    local ownershipStatus = houseTable.ownershipStatus
    local tpInt = houseTable.tpInt ~= 0 and houseTable.tpInt or nil
    local tpInstance = houseTable.tpInstance
    local taxesStatus = houseTable.taxes_collected
    local taxesOverdue = taxesStatus and tostring(taxesStatus) == 'overdue'
    local taxPaymentReleased = taxesStatus and tostring(taxesStatus) == 'released'

    local houseContext = {
        coords = vectorCoords,
        radius = radius,
        polyPoints = houseTable.poly_points and json.decode(houseTable.poly_points) or nil,
        polyMinZ = tonumber(houseTable.poly_min_z),
        polyMaxZ = tonumber(houseTable.poly_max_z),
        houseId = houseId,
        uniqueName = houseTable.uniqueName,
        owner = owner,
        ownershipStatus = ownershipStatus,
        taxesOverdue = taxesOverdue,
        taxPaymentReleased = taxPaymentReleased,
        purchasedAt = houseTable.purchased_at_formatted or houseTable.purchased_at,
        tpInt = tpInt,
        tpInstance = tpInstance
    }

    houseContext.polyPoints = NormalizeHousingPolyPoints(houseContext.polyPoints)
    houseContext.zone = CreateHousingPolyZone(
        ('bcc-housing-owned-%s'):format(tostring(houseId)),
        houseContext.polyPoints,
        houseContext.polyMinZ,
        houseContext.polyMaxZ,
        Config.DevMode == true
    )

    OwnedHouseContexts[houseId] = houseContext

    if not HouseId or HouseId == houseId or ActiveHouseId == houseId then
        SetActiveHouseContext(houseContext)
    end

    DBG:Info("House information set for House ID: " .. tostring(houseId))

    StartFurnCheckHandler()

    local houseCfgFound = false
    local uniqueName = houseTable.uniqueName
    for _, houseCfg in pairs(Houses) do
        if houseCfg.uniqueName == uniqueName then
            houseCfgFound = true
            if houseCfg.blip.owned.active then
                local blip = HousingBlips:SetBlip(houseCfg.blip.owned.name, houseCfg.blip.owned.sprite, 0.2, vectorCoords.x, vectorCoords.y, vectorCoords.z)
                local blipModifier = HousingBlips:AddBlipModifier(blip, Config.BlipColors[houseCfg.blip.owned.color])
                blipModifier:ApplyModifier()
                table.insert(HouseBlips, blip)
                break
            end
        end
    end

    if not houseCfgFound and Config.HouseBlip.active then
        local houseBlip = Config.HouseBlip
        local blip = HousingBlips:SetBlip(houseBlip.name, houseBlip.sprite, 0.2, vectorCoords.x, vectorCoords.y, vectorCoords.z)
        local blipModifier = HousingBlips:AddBlipModifier(blip, Config.BlipColors[houseBlip.color])
        blipModifier:ApplyModifier()
        table.insert(HouseBlips, blip)
    end

    if taxesOverdue then
        Notify(_U("taxesOverdue"), 'error', 5000)
    elseif taxPaymentReleased then
        Notify(_U("taxPaymentReleasedPlayer"), 'info', 7000)
    end

    showManageOpt(vectorCoords.x, vectorCoords.y, vectorCoords.z, houseId, houseContext)
end

HousingRPC:Register('bcc-housing:OwnsHouseClientHandler', function(params)
    if not params then return end
    if params.house then
        handleOwnsHouseClient(params.house, params.isOwner)
    else
        handleOwnsHouseClient(params, params.isOwner)
    end
end)

function MainHotelHandler()
    DBG:Info("Initializing main hotel handler")

    local buyGroup = HousingPrompts:SetupPromptGroup()
    local buyPrompt = buyGroup:RegisterPrompt(_U("promptBuy"), HousingKeys[Config.keys.buy], 1, 1, true, 'click', nil)

    local enterGroup = HousingPrompts:SetupPromptGroup()
    local enterPrompt = enterGroup:RegisterPrompt(_U("promptEnterHotel"), HousingKeys[Config.keys.manage], 1, 1, true, 'click', nil)

    local inventoryGroup = HousingPrompts:SetupPromptGroup()
    local inventoryPrompt = inventoryGroup:RegisterPrompt(_U("hotelInvName"), HousingKeys[Config.keys.manage], 1, 1, true, 'click', nil)

    local leaveGroup = HousingPrompts:SetupPromptGroup()
    local leavePrompt = leaveGroup:RegisterPrompt(_U("promptLeaveHotel"), HousingKeys[Config.keys.manage], 1, 1, true, 'click', nil)

    local inHotel, hotelInside, instanceNumber, coordsWhenEntered = false, nil, 0, nil
    local interiorEnterCoords, interiorInventoryCoords, interiorHeading = nil, nil, nil

    while true do
        local sleep = 1000
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)

        if not inHotel then
            for _, hotel in pairs(Hotels) do
                local distance = #(playerCoords - hotel.location)
                if distance < 2 then
                    sleep = 0
                    local isOwned = false

                    if #OwnedHotels > 0 then
                        for _, hotelId in pairs(OwnedHotels) do
                            if hotel.hotelId == hotelId then
                                isOwned = true
                                enterGroup:ShowGroup(hotel.name)
                                if enterPrompt:HasCompleted() then
                                    HousingRPC:CallAsync('bcc-housing:RegisterHotelInventory', { hotelId = hotelId })
                                    local player = PlayerId()
                                    DBG:Info("Entering hotel: " .. tostring(hotelId))
                                    inHotel = true
                                    hotelInside = hotel
                                    coordsWhenEntered = playerCoords
                                    local interiorCfg = hotel.interior or {}
                                    interiorEnterCoords = interiorCfg.enter or DefaultHotelInterior.enter
                                    interiorInventoryCoords = interiorCfg.inventory or DefaultHotelInterior.inventory
                                    interiorHeading = interiorCfg.heading or DefaultHotelInterior.heading
                                    SetEntityCoords(playerPed, interiorEnterCoords.x, interiorEnterCoords.y, interiorEnterCoords.z, false, false, false, false)
                                    if interiorHeading then
                                        SetEntityHeading(playerPed, interiorHeading)
                                    end
                                    HousingInstance.Enter('hotel', hotel.hotelId)
                                    break
                                end
                            end
                        end
                    end

                    if not isOwned then
                        buyGroup:ShowGroup(hotel.name .. _U("promptGroupName") .. tostring(hotel.cost))
                        if buyPrompt:HasCompleted() then
                            DBG:Info("Buying hotel: " .. tostring(hotel.hotelId))
                            local success, updatedHotels = HousingRPC:CallAsync('bcc-housing:HotelBought', { hotel = hotel })
                            if success and type(updatedHotels) == 'table' then
                                OwnedHotels = updatedHotels
                            end
                        end
                    end
                end
            end

        elseif inHotel and hotelInside then
            sleep = 0
            local inventoryCoords = interiorInventoryCoords or DefaultHotelInterior.inventory
            local distance = #(playerCoords - inventoryCoords)
            if distance < 1 then
                inventoryGroup:ShowGroup(hotelInside.name)
                if inventoryPrompt:HasCompleted() then
                    DBG:Info("Opening hotel inventory: " .. tostring(hotelInside.hotelId))
                    HousingRPC:CallAsync('bcc-housing:HotelInvOpen', { hotelId = hotelInside.hotelId })
                end
            else
                leaveGroup:ShowGroup(hotelInside.name)
                if leavePrompt:HasCompleted() then
                    if coordsWhenEntered then
                        DBG:Info("Leaving hotel: " .. tostring(hotelInside.hotelId))
                        SetEntityCoords(PlayerPedId(), coordsWhenEntered.x, coordsWhenEntered.y, coordsWhenEntered.z, false, false, false, false)
                        inHotel = false
                        hotelInside = nil
                        coordsWhenEntered = nil
                        interiorEnterCoords, interiorInventoryCoords, interiorHeading = nil, nil, nil
                        HousingInstance.Clear()
                    end
                end
            end
        end
        Wait(sleep)
    end
end

local function clearHouseBlips(houseId)
    if HouseBlips[houseId] then
        HousingBlips:RemoveBlip(HouseBlips[houseId].rawblip) 
        HouseBlips[houseId] = nil
    end

    if HouseBlips and next(HouseBlips) then
        for _, blipData in pairs(HouseBlips) do
            if blipData and blipData.rawblip then
                HousingBlips:RemoveBlip(blipData.rawblip)
            end
        end
        HouseBlips = {}
    end
end

HousingRPC:Register('bcc-housing:clearBlips', function(params)
    local houseId = params and params.houseId or params
    if houseId then
        clearHouseBlips(houseId)
    end
end)
