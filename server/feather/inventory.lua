-- bcc-housing's boundary to feather-inventory (replaces vorp_inventory).
--
-- House storage: one container per house row (foreign key bcchousing.houseid;
-- feather-inventory deletes it with the row). Hotel storage: one container per
-- character and hotel (foreign key bcchousing_hotel_rooms.id). Players open a
-- container through a short temporary access grant after bcc-housing checked
-- they may. Deeds are inventory items whose metadata carries the house ID and
-- property ID; ownership truth stays in feather-property.

HousingInventory = {}

local foreignKeys = {}

local function Api()
    if GetResourceState('feather-inventory') ~= 'started' then return nil end
    local called, value = pcall(function() return exports['feather-inventory']:initiate() end)
    return called and type(value) == 'table' and value or nil
end

AddEventHandler('onResourceStart', function(resource)
    if resource == 'feather-inventory' then foreignKeys = {} end
end)

local function ok(result)
    return type(result) == 'table' and result.ok == true
end

local function code(result)
    if type(result) ~= 'table' then return 'invalid_result' end
    local problem = type(result.error) == 'table' and result.error or result
    return tostring(problem.code)
end

-- Largest storage, in slots (feather-inventory stores up to 65535).
local function capSlots(slots)
    local maximum = tonumber(Config.Setup and Config.Setup.MaxStorageSlots) or 1000
    return math.max(1, math.min(math.floor(tonumber(slots) or 1), maximum, 65535))
end

local function ensureForeignKey(inventory, tableName, keyType, primaryKey)
    if foreignKeys[tableName] then return true end
    local registered = inventory.Inventory.RegisterForeignKey(tableName, keyType, primaryKey)
    if not ok(registered) then
        DBG:Error('[Inventory] foreign key', tableName, code(registered))
        return false
    end
    foreignKeys[tableName] = true
    return true
end

-- Registers (or resizes) a container. Returns { uuid, id, tableName } or nil.
local function ensureContainer(tableName, keyType, primaryKey, rowId, displayName, slots)
    local inventory = Api()
    if not inventory or not ensureForeignKey(inventory, tableName, keyType, primaryKey) then return nil end
    local registered = inventory.Inventory.RegisterInventory(tableName, rowId, tostring(displayName):sub(1, 100),
        false, nil, nil, nil, false, capSlots(slots))
    if not ok(registered) then
        DBG:Error('[Inventory] register', tableName, rowId, code(registered))
        return nil
    end
    return { uuid = registered.value.uuid, id = registered.value.id, tableName = tableName }
end

function HousingInventory.EnsureHouseStorage(houseId, displayName, slots)
    return ensureContainer('bcchousing', 'INT', 'houseid', tonumber(houseId), displayName, slots)
end

-- The hotel room row of a character (created on first use).
local function hotelRoomId(hotelId, characterId)
    DB.exec('INSERT IGNORE INTO bcchousing_hotel_rooms (hotel_id, character_id) VALUES (?, ?)', hotelId, characterId)
    return tonumber(DB.value('SELECT id FROM bcchousing_hotel_rooms WHERE hotel_id = ? AND character_id = ?',
        hotelId, characterId))
end

function HousingInventory.EnsureHotelStorage(hotelId, characterId, displayName, slots)
    local roomId = hotelRoomId(tonumber(hotelId), characterId)
    if not roomId then return nil end
    return ensureContainer('bcchousing_hotel_rooms', 'INT', 'id', roomId, displayName, slots)
end

-- Opens a container for a player bcc-housing has already authorised.
function HousingInventory.Open(src, container)
    local inventory = Api()
    if not inventory or not container then return false end
    local granted = inventory.Inventory.GrantTemporaryAccess(src, container.id, 60)
    local opened = ok(granted) and inventory.Inventory.OpenInventory(src, container.uuid, container.tableName) or granted
    if not ok(opened) then
        DBG:Error('[Inventory] open failed', code(opened))
        return false
    end
    return true
end

function HousingInventory.Close(src)
    local inventory = Api()
    if inventory then inventory.Inventory.CloseInventory(src) end
end

-- Items --------------------------------------------------------------------------

function HousingInventory.Count(src, itemName)
    local inventory = Api()
    if not inventory then return 0 end
    local result = inventory.Items.GetItemCount(itemName, src)
    return ok(result) and (tonumber(result.value) or 0) or 0
end

function HousingInventory.CanHold(src, itemName, quantity)
    local inventory = Api()
    if not inventory then return false end
    local result = inventory.Inventory.InventoryCanHold({ { item = itemName, quantity = quantity or 1 } }, src)
    return ok(result) and type(result.value) == 'table' and result.value.accepted == true
end

-- Adds items to the player's inventory, with optional metadata.
function HousingInventory.Add(src, itemName, quantity, metadata)
    local inventory = Api()
    if not inventory then return Housing.Err('dependency_unavailable', 'feather-inventory is not started.') end
    local result = inventory.Items.AddItem(itemName, quantity or 1, metadata, src)
    if ok(result) then return result end
    return Housing.Err(code(result), 'Item could not be added.')
end

-- Removes the first item of that name whose metadata[key] equals value (a deed of
-- one house) from a character's inventory. Returns true when one was removed.
function HousingInventory.RemoveByMetadata(characterId, itemName, key, value)
    local inventory = Api()
    if not inventory then return false end
    local found = inventory.Inventory.GetCharacterInventory(characterId)
    if not ok(found) or type(found.value) ~= 'table' then return false end
    local items = inventory.Inventory.GetInventoryItems(found.value.id)
    for _, item in ipairs(ok(items) and items.value or {}) do
        local metadata = type(item.metadata) == 'table' and item.metadata or {}
        if item.name == itemName and tostring(metadata[key]) == tostring(value) then
            return ok(inventory.Items.RemoveItemById(item.id))
        end
    end
    return false
end

-- The items of that name in a character's inventory, with their metadata.
function HousingInventory.ListItems(characterId, itemName)
    local inventory = Api()
    if not inventory then return {} end
    local found = inventory.Inventory.GetCharacterInventory(characterId)
    if not ok(found) or type(found.value) ~= 'table' then return {} end
    local items = inventory.Inventory.GetInventoryItems(found.value.id)
    local list = {}
    for _, item in ipairs(ok(items) and items.value or {}) do
        if item.name == itemName then list[#list + 1] = item end
    end
    return list
end

-- Registers a usable item; handler(src, item).
function HousingInventory.RegisterUsable(itemName, handler)
    local inventory = Api()
    if not inventory then return false end
    local registered = inventory.Items.RegisterUsableItem(itemName, function(item, src)
        handler(src, item)
    end)
    if not ok(registered) then DBG:Warning('[Inventory] usable item', itemName, code(registered)) end
    return ok(registered)
end
