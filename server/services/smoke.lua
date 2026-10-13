-- Read-only release check, server console only: HousingReleaseSmokeTest
-- Configuration, the Feather domains bcc-housing depends on, registration of
-- configured houses and hotels, and that no house row holds money.

local function started(resource) return GetResourceState(resource) == 'started' end

RegisterCommand('HousingReleaseSmokeTest', function(source)
    if source ~= 0 then return end
    local called, problem = xpcall(function()
        local probe = '00000000-0000-0000-0000-000000000000'
        local economy = Housing.Call('feather-economy', 'GetSystemAccount', { currency = 'dollars', accountType = 'system_sink' })
        local jobs = Housing.Call('feather-jobs', 'CheckAssignment', { characterId = probe, jobKey = 'housing_probe' })
        local authorityRole = Housing.Call('feather-authority', 'FindRoleByKey',
            { roleKey = (Config.Admin and Config.Admin.role) or 'staff.housing.admin' })

        local missingHouses, missingHotels = 0, 0
        for _, house in pairs(Houses or {}) do
            if house.uniqueName and not HousingProperty.Get(HousingProperty.HouseKey(house.uniqueName)).ok then
                missingHouses = missingHouses + 1
            end
        end
        for _, hotel in pairs(Hotels or {}) do
            if hotel.hotelId and not HousingProperty.Get(HousingProperty.HotelKey(hotel.hotelId)).ok then
                missingHotels = missingHotels + 1
            end
        end
        local unlinked = tonumber(DB.value('SELECT COUNT(*) FROM bcchousing WHERE property_id IS NULL')) or -1
        local ledger = tonumber(DB.value([[SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'bcchousing' AND COLUMN_NAME = 'ledger']])) or -1
        local pendingPayouts = tonumber(DB.value("SELECT COUNT(*) FROM bcchousing_transactions WHERE status = 'pending'")) or -1
        local inventory = started('feather-inventory') and exports['feather-inventory']:initiate() or nil
        local deed = inventory and inventory.Items.ItemExists((Config.PropertyDocuments or {}).houseItem or 'property_deed')
        local book = inventory and inventory.Items.ItemExists(Furniture and Furniture.MenuItem or 'furniture_book')

        local tests = {
            { 'development disabled', Config.DevMode == false },
            { 'Property ready', HousingProperty.ready == true },
            { 'configured houses registered', missingHouses == 0 },
            { 'hotels registered', missingHotels == 0 },
            { 'house rows linked to Property', unlinked == 0 },
            { 'Economy trusts bcc-housing', economy.ok == true },
            { 'Contracts tax types registered', HousingContracts.ready == true },
            { 'Jobs trusts bcc-housing', jobs.ok == true },
            { 'Authority staff role exists', authorityRole.ok == true },
            { 'Routing started', started('feather-routing') },
            -- Cross-resource functions arrive as callable references, not plain functions.
            { 'doorlocks API available', started('bcc-doorlocks') and type(DoorLocksAPI) == 'table'
                and DoorLocksAPI.GetDoorByInfo ~= nil },
            { 'no ledger column', ledger == 0 },
            { 'deed item installed', deed == true or (type(deed) == 'table' and deed.ok and deed.value == true) },
            { 'furniture book installed', book == true or (type(book) == 'table' and book.ok and book.value == true) }
        }
        local passed = 0
        for _, test in ipairs(tests) do
            if test[2] then passed = passed + 1 end
            print(('[HousingReleaseSmokeTest] %-30s %s'):format(test[1], test[2] and 'PASS' or 'FAIL'))
        end
        print(('[HousingReleaseSmokeTest] houses missing=%d hotels missing=%d unlinked rows=%d pending payouts=%d'):format(
            missingHouses, missingHotels, unlinked, pendingPayouts))
        print(('[HousingReleaseSmokeTest] done %d/%d passed (read-only)'):format(passed, #tests))
    end, debug.traceback)
    if not called then print('[HousingReleaseSmokeTest] FAIL ' .. tostring(problem)) end
end, true)
