-- Taxes and rent (no ledger).
--
-- Each house owes tax_amount (rent for a rented house) every month on the
-- day it was bought. bcc-housing keeps no money: when a due date passes the
-- amount is taken from the holder's wallet through feather-economy. Players may
-- pay ahead; that only moves `taxes_paid_until` (a date, never a balance), and
-- due dates up to it are already covered.
--
-- When the wallet cannot pay, the house becomes 'overdue' and its feather-property
-- property is suspended (still held, cannot be sold; doors and storage locked).
-- Staff release it ('released'), the holder pays the arrears, and it is active again.

HousingTaxes = {}

local function parseMysqlDate(value)
    if not value or value == '' then return nil end

    local year, month, day = tostring(value):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or not month or not day then return nil end

    return {
        year = year,
        month = month,
        day = day
    }
end

local function daysInMonth(year, month)
    if month == 2 then
        local leapYear = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        return leapYear and 29 or 28
    end

    if month == 4 or month == 6 or month == 9 or month == 11 then
        return 30
    end

    return 31
end

local function compareDateParts(left, right)
    if left.year ~= right.year then return left.year < right.year and -1 or 1 end
    if left.month ~= right.month then return left.month < right.month and -1 or 1 end
    if left.day ~= right.day then return left.day < right.day and -1 or 1 end
    return 0
end

local function previousMonth(date)
    local year = date.year
    local month = date.month - 1
    if month < 1 then
        month = 12
        year = year - 1
    end

    return { year = year, month = month, day = 1 }
end

local function getLatestDueDate(purchasedAt, currentDate)
    local purchasedDate = parseMysqlDate(purchasedAt)
    if not purchasedDate then return nil end

    local dueMonth = {
        year = currentDate.year,
        month = currentDate.month,
        day = 1
    }
    local billingDay = math.min(purchasedDate.day, daysInMonth(dueMonth.year, dueMonth.month))
    local dueDate = {
        year = dueMonth.year,
        month = dueMonth.month,
        day = billingDay
    }

    if compareDateParts(currentDate, dueDate) < 0 then
        dueMonth = previousMonth(dueMonth)
        dueDate = {
            year = dueMonth.year,
            month = dueMonth.month,
            day = math.min(purchasedDate.day, daysInMonth(dueMonth.year, dueMonth.month))
        }
    end

    if dueDate.year == purchasedDate.year and dueDate.month == purchasedDate.month then
        return nil
    end

    if compareDateParts(dueDate, purchasedDate) <= 0 then
        return nil
    end

    return dueDate
end

local function formatDateKey(date)
    return date and ("%04d-%02d-%02d"):format(date.year, date.month, date.day) or nil
end


local function today()
    return { year = tonumber(os.date("%Y")), month = tonumber(os.date("%m")), day = tonumber(os.date("%d")) }
end

-- The same day N months later (the last day of shorter months).
local function addMonths(date, months)
    local month = date.month - 1 + months
    local year = date.year + math.floor(month / 12)
    month = month % 12 + 1
    return { year = year, month = month, day = math.min(date.day, daysInMonth(year, month)) }
end

local function formatMoney(value)
    return string.format("%.2f", tonumber(value) or 0)
end

-- Economy currency the house pays its taxes or rent in.
function HousingTaxes.Currency(row)
    local currencyType = tonumber(row.purchaseCurrencyType)
    if currencyType == nil and row.ownershipStatus == 'rented' then
        currencyType = tonumber(Config.Setup.DefaultRentalCurrency)
    end
    return HousingEconomy.Currency(currencyType or 0)
end

local function reasonFor(row)
    return row.ownershipStatus == 'rented' and 'housing.rent' or 'housing.tax'
end

local function propertyKey(row)
    return HousingProperty.KeyForRow(row)
end

local function sendTaxWebhook(house, status, currency)
    local description = table.concat({
        _U("houseIdWebhook") .. tostring(house.houseid),
        _U("taxAmountWebhook") .. formatMoney(house.tax_amount) .. ' ' .. tostring(currency)
    }, "\n")
    Discord:sendMessage(status == "paid" and _U("taxPaidWebhook") or _U("taxPaidFailedWebhook"), description)
end

local function notifyHolder(row, message)
    local src = row.character_id and HousingCharacters.FindSource(row.character_id)
    if src then NotifyClient(src, message, 6000, 'error') end
end

-- Marks a house overdue and suspends its property.
local function markOverdue(row, dueKey)
    DB.exec("UPDATE bcchousing SET taxes_collected = 'overdue', last_tax_processed_at = ? WHERE houseid = ?", dueKey, row.houseid)
    local suspended = HousingProperty.SetStatus(propertyKey(row), 'suspended',
        HousingProperty.RequestId('tax-suspend', row.houseid, dueKey), 'housing.tax_overdue')
    if not suspended.ok then
        DBG:Error('[Taxes] suspend failed', row.houseid, suspended.code, suspended.message)
    end
    notifyHolder(row, _U('taxesOverdue'))
end

-- Processes one house for the latest due date, once.
local function processHouse(row, currentDate)
    local taxAmount = tonumber(row.tax_amount) or 0
    local dueDate = getLatestDueDate(row.purchased_at, currentDate)
    if not dueDate then return end
    local lastProcessed = parseMysqlDate(row.last_tax_processed_at)
    if lastProcessed and compareDateParts(lastProcessed, dueDate) >= 0 then return end
    local dueKey = formatDateKey(dueDate)
    local status = tostring(row.taxes_collected)

    if status == 'overdue' or status == 'released' or taxAmount <= 0 then
        DB.exec("UPDATE bcchousing SET last_tax_processed_at = ? WHERE houseid = ?", dueKey, row.houseid)
        return
    end

    local paidUntil = parseMysqlDate(row.taxes_paid_until)
    if paidUntil and compareDateParts(paidUntil, dueDate) >= 0 then
        DBG:Info('[Taxes] house', row.houseid, 'due', dueKey, 'already paid until', row.taxes_paid_until)
        DB.exec("UPDATE bcchousing SET taxes_collected = 'true', last_tax_processed_at = ? WHERE houseid = ?", dueKey, row.houseid)
        return
    end

    local currency = HousingTaxes.Currency(row)
    if not currency or type(row.character_id) ~= 'string' then
        DBG:Warning('[Taxes] house', row.houseid, 'has no payable currency or holder')
        return
    end
    -- The charge is a feather-contracts obligation. Its request IDs are fixed per
    -- house, due date and holder: a restart on the due day never charges twice.
    local wallet = HousingEconomy.Wallet(row.character_id, currency)
    if not wallet.ok then
        return DBG:Error('[Taxes] house', row.houseid, 'has no wallet:', wallet.code, wallet.message)
    end
    local paid = HousingContracts.Charge(row, dueKey, HousingEconomy.ToMinor(taxAmount), currency)
    if paid.ok then
        DB.exec("UPDATE bcchousing SET taxes_collected = 'true', last_tax_processed_at = ? WHERE houseid = ?", dueKey, row.houseid)
        sendTaxWebhook(row, "paid", currency)
        DBG:Success('[Taxes] house', row.houseid, 'paid', taxAmount, currency, 'for', dueKey)
    elseif paid.code == 'insufficient_funds' then
        markOverdue(row, dueKey)
        sendTaxWebhook(row, "overdue", currency)
        DBG:Warning('[Taxes] house', row.houseid, 'overdue for', dueKey)
    elseif paid.code == 'settlement_pending' then
        -- Economy's answer is unknown; Contracts replays the same transfer and the next check sees the result.
        DBG:Warning('[Taxes] house', row.houseid, 'payment pending for', dueKey)
    else
        -- Contracts or Economy unavailable: try again at the next check.
        DBG:Error('[Taxes] house', row.houseid, 'charge failed:', paid.code, paid.message)
    end
end

function HousingTaxes.Collect(currentDate, houseId)
    currentDate = currentDate or today()
    local rows = houseId and DB.query("SELECT * FROM bcchousing WHERE houseid = ?", houseId)
        or DB.query("SELECT * FROM bcchousing")
    for _, row in ipairs(rows or {}) do
        local called, problem = pcall(processHouse, row, currentDate)
        if not called then print('[bcc-housing] taxes: house ' .. tostring(row.houseid) .. ' failed: ' .. tostring(problem)) end
    end
end

CreateThread(function()
    while not DbUpdated do Wait(1000) end
    if not Config.collectTaxes then return end
    while Config.collectTaxes do
        if HousingProperty.ready then HousingTaxes.Collect() end
        Wait(60 * 60 * 1000) -- hourly; each house is charged at most once per due date
    end
end)

-- Console, DevMode only: HousingTaxCollectAt <YYYY-MM-DD> <houseid>
-- Runs the tax/rent collection for one house as if today were that date (real
-- money moves; nobody needs to be online). Use a date after the house's next due
-- date; an empty holder wallet takes the overdue path.
if Config.DevMode then
    RegisterCommand('HousingTaxCollectAt', function(source, args)
        if source ~= 0 then return end
        local date, houseId = parseMysqlDate(args[1]), tonumber(args[2])
        if not date or not houseId then
            return print('[bcc-housing] Usage: HousingTaxCollectAt <YYYY-MM-DD> <houseid>')
        end
        HousingTaxes.Collect(date, houseId)
        local row = DB.one([[SELECT taxes_collected, last_tax_processed_at, tax_obligation_id
            FROM bcchousing WHERE houseid = ?]], houseId)
        print(('[bcc-housing] house %s: taxes_collected=%s last_processed=%s obligation=%s'):format(houseId,
            tostring(row and row.taxes_collected), tostring(row and row.last_tax_processed_at),
            tostring(row and row.tax_obligation_id)))
    end, true)
end

-- Staff release of an overdue house: the holder may now pay the arrears.
function HousingTaxes.Release(houseId)
    local affected = DB.exec(
        "UPDATE bcchousing SET taxes_collected = 'released' WHERE houseid = ? AND taxes_collected = 'overdue'",
        tonumber(houseId))
    return affected ~= nil and affected > 0
end

-- Pay ahead / pay arrears --------------------------------------------------------

local function maxMonths()
    return math.max(1, math.min(tonumber(Config.Setup.MaxTaxPrepayMonths) or 12, 24))
end

-- months = how many months to pay ahead. A 'released' (overdue) house first pays
-- one period of arrears, which reactivates it; months may be 0 then.
-- The payer must hold the house. src is
-- the player's source when they are online (notifications, and the arrears are
-- paid with them as the acting debtor); without it the payment still runs and
-- bcc-housing collects the arrears itself. Returns ok, result.
function HousingTaxes.Pay(character, houseId, months, src)
    houseId = tonumber(houseId)
    months = math.floor(tonumber(months) or 0)
    if not houseId or not character then return false, { error = 'invalid_params' } end
    local key = DB.one('SELECT houseid, uniqueName FROM bcchousing WHERE houseid = ?', houseId)
    if not key or not HousingProperty.Holds(HousingProperty.KeyForRow(key), character.characterId) then
        NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
        return false
    end
    local row = DB.one("SELECT * FROM bcchousing WHERE houseid = ?", houseId)
    if not row then return false end
    local status = tostring(row.taxes_collected)
    local taxAmount = tonumber(row.tax_amount) or 0
    local currency = HousingTaxes.Currency(row)
    if not currency or taxAmount <= 0 then
        NotifyClient(src, _U('currencyNotSupported'), 4000, 'error')
        return false
    end
    if status == 'overdue' then
        NotifyClient(src, _U('taxesOverdue'), 5000, 'error')
        return false, { error = 'overdue' }
    end
    if months < 0 or months > maxMonths() or (months == 0 and status ~= 'released') then
        NotifyClient(src, _U('taxesPrepayLimit', maxMonths()), 4000, 'error')
        return false, { error = 'invalid_months' }
    end

    local paymentId = Housing.NewId()
    local result = { taxesPaid = status == 'released' }
    if status == 'released' then
        -- The arrears settle the house's open feather-contracts obligation.
        local arrears = HousingContracts.PayArrears(src, row, HousingEconomy.ToMinor(taxAmount), currency, paymentId)
        if not arrears.ok then
            NotifyClient(src, _U(HousingEconomy.MessageKey(arrears, currency)), 4000, 'error')
            return false, { error = arrears.code }
        end
        DB.exec("UPDATE bcchousing SET taxes_collected = 'true' WHERE houseid = ? AND taxes_collected = 'released'", houseId)
        local reactivated = HousingProperty.SetStatus(propertyKey(row), 'active',
            HousingProperty.RequestId('tax-reactivate', houseId, paymentId), 'housing.tax_paid')
        if not reactivated.ok then DBG:Error('[PayTaxes] reactivate failed', reactivated.code) end
        NotifyClient(src, _U('taxesArrearsPaid'), 5000, 'success')
    end
    if months > 0 then
        -- Paying ahead is not a debt: it moves money directly and only advances taxes_paid_until.
        local paid = HousingEconomy.Pay(character, currency, taxAmount * months, reasonFor(row),
            { type = 'housing_house', id = houseId }, 'housing:tax-pay:' .. paymentId)
        if not paid.ok then
            NotifyClient(src, _U(HousingEconomy.MessageKey(paid, currency)), 4000, 'error')
            result.error = paid.code
            return result.taxesPaid, result
        end
        local base = parseMysqlDate(row.taxes_paid_until)
        local now = today()
        if not base or compareDateParts(base, now) < 0 then base = now end
        local untilDate = addMonths(base, months)
        local untilKey = formatDateKey(untilDate)
        DB.exec("UPDATE bcchousing SET taxes_paid_until = ? WHERE houseid = ?", untilKey, houseId)
        result.paidUntil = untilKey
        NotifyClient(src, _U('taxesPaidAhead', formatMoney(taxAmount * months), months, untilKey), 6000, 'success')
    end
    return true, result
end

HousingRPC:Register('bcc-housing:PayTaxes', function(params, cb, src)
    local character = GetHousingCharacter(src)
    if not character then return cb(false, { error = 'invalid_params' }) end
    cb(HousingTaxes.Pay(character, params and params.houseid, params and params.months, src))
end)

-- Shows the tax state: amount per month, paid-until date, status.
HousingRPC:Register('bcc-housing:CheckLedger', function(params, cb, src)
    local houseId = tonumber(params and params.houseid)
    if not houseId or not IsHouseOwner(src, houseId) then
        if cb then cb(false, { error = 'house_not_found' }) end
        return
    end
    local row = DB.one("SELECT tax_amount, taxes_paid_until, taxes_collected, purchaseCurrencyType, ownershipStatus FROM bcchousing WHERE houseid = ?", houseId)
    if not row then
        if cb then cb(false, { error = 'house_not_found' }) end
        return
    end
    local currency = HousingTaxes.Currency(row) or 'dollars'
    local amount = formatMoney(row.tax_amount) .. ' ' .. currency
    local paidUntil = row.taxes_paid_until and formatDateKey(parseMysqlDate(row.taxes_paid_until)) or nil
    NotifyClient(src, paidUntil and _U('taxesPaidUntil', paidUntil, amount) or _U('taxesNotPaidAhead', amount), 6000, 'info')
    if cb then
        cb(true, { taxAmount = tonumber(row.tax_amount) or 0, currency = currency, paidUntil = paidUntil,
            status = tostring(row.taxes_collected), maxMonths = maxMonths() })
    end
end)

-- Console, DevMode only ------------------------------------------------------------
-- The in-game tax steps with nobody online:
--   HousingTaxRelease <houseid>                         staff release of an overdue house
--   HousingTaxPayAs <characterUuid> <houseid> <months>  the holder pays (arrears first, then months ahead)
--   HousingArrearsFlowTest <houseid> <YYYY-MM-DD> <otherCharacterUuid>
--     Full overdue path. MOVES MONEY: the holder's money, all but 0.01 less than one
--     period's tax, is parked with the other character so the charge on that date
--     cannot be paid; the house must go overdue and be suspended, refuse payment,
--     be released by staff; then the money is returned and the holder pays the
--     arrears, which settles the same Contracts obligation and reactivates the
--     house. The parked money is returned even when a step fails. Offline the
--     arrears are collected by bcc-housing (no player session to act as debtor).
if Config.DevMode then
    local function Uuid(value)
        return type(value) == 'string'
            and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
            and value:lower() or nil
    end

    RegisterCommand('HousingTaxRelease', function(source, args)
        if source ~= 0 then return end
        print(('[bcc-housing] release house %s: %s'):format(tostring(args[1]),
            HousingTaxes.Release(args[1]) and 'released' or 'not overdue'))
    end, true)

    RegisterCommand('HousingTaxPayAs', function(source, args)
        if source ~= 0 then return end
        local characterId = Uuid(args[1])
        if not characterId or not tonumber(args[2]) then
            return print('[bcc-housing] Usage: HousingTaxPayAs <characterUuid> <houseid> <months>')
        end
        local ok, result = HousingTaxes.Pay({ characterId = characterId }, args[2], args[3])
        print(('[bcc-housing] pay house %s: ok=%s %s'):format(args[2], tostring(ok), json.encode(result or {})))
    end, true)

    RegisterCommand('HousingArrearsFlowTest', function(source, args)
        if source ~= 0 then return end
        local houseId, date, otherId = tonumber(args[1]), parseMysqlDate(args[2]), Uuid(args[3])
        local row = houseId and DB.one('SELECT * FROM bcchousing WHERE houseid = ?', houseId)
        if not row or not date or not otherId or not Uuid(row.character_id) or row.character_id:lower() == otherId then
            return print('[bcc-housing] Usage: HousingArrearsFlowTest <houseid> <YYYY-MM-DD> <otherCharacterUuid>'
                .. ' (the house needs a holder; the other character must differ)')
        end
        local passed, total = 0, 0
        local function Check(name, condition)
            total = total + 1
            if condition then passed = passed + 1 end
            print(('[HousingArrearsFlowTest] %-34s %s'):format(name, condition and 'PASS' or 'FAIL'))
        end
        local holder = { characterId = row.character_id:lower() }
        local currency = HousingTaxes.Currency(row)
        local taxMinor = HousingEconomy.ToMinor(row.tax_amount)
        local key = propertyKey(row)
        local function House() return DB.one('SELECT * FROM bcchousing WHERE houseid = ?', houseId) end
        local function PropertyStatus()
            local snapshot = HousingProperty.Get(key)
            return snapshot.ok and snapshot.value.status or nil
        end
        if not currency or taxMinor <= 0 or tostring(row.taxes_collected) == 'overdue'
            or tostring(row.taxes_collected) == 'released' then
            return print('[HousingArrearsFlowTest] the house needs a tax amount, a currency and no open arrears')
        end

        local balance = HousingEconomy.Balance(holder.characterId, currency)
        local parkMinor = balance and (HousingEconomy.ToMinor(balance) - taxMinor + 1) or 0
        local parked = false
        local runId = Housing.NewId()
        local called, problem = xpcall(function()
            if parkMinor > 0 then
                local park = HousingEconomy.PayTo(holder, otherId, currency, HousingEconomy.ToMajor(parkMinor),
                    'housing.test_park', { type = 'housing_house', id = houseId }, 'housing:test-park:' .. runId)
                parked = park.ok
                Check('holder money parked', park.ok)
                if not park.ok then return end
            end

            HousingTaxes.Collect(date, houseId)
            local overdue = House()
            local obligation = overdue.tax_obligation_id and HousingContracts.Get(overdue.tax_obligation_id)
            Check('charge leaves house overdue', overdue.taxes_collected == 'overdue')
            Check('property suspended', PropertyStatus() == 'suspended')
            Check('obligation stays open', obligation and obligation.ok
                and (obligation.value.status == 'issued' or obligation.value.status == 'due'))
            local refused, refusal = HousingTaxes.Pay(holder, houseId, 0)
            Check('payment refused while overdue', not refused and refusal and refusal.error == 'overdue')

            Check('staff release', HousingTaxes.Release(houseId) and House().taxes_collected == 'released')

            if parked then
                local back = HousingEconomy.PayTo({ characterId = otherId }, holder.characterId, currency,
                    HousingEconomy.ToMajor(parkMinor), 'housing.test_park', { type = 'housing_house', id = houseId },
                    'housing:test-return:' .. runId)
                parked = not back.ok
                Check('holder money returned', back.ok)
            end

            local paid = HousingTaxes.Pay(holder, houseId, 0)
            local after = House()
            local settled = HousingContracts.Get(overdue.tax_obligation_id)
            Check('arrears paid', paid and after.taxes_collected == 'true')
            Check('property active again', PropertyStatus() == 'active')
            Check('same obligation settled', settled.ok and settled.value.status == 'settled')
        end, debug.traceback)
        if parked then
            local back = HousingEconomy.PayTo({ characterId = otherId }, holder.characterId, currency,
                HousingEconomy.ToMajor(parkMinor), 'housing.test_park', { type = 'housing_house', id = houseId },
                'housing:test-return:' .. runId)
            print(('[HousingArrearsFlowTest] parked money returned after a failure: %s'):format(tostring(back.ok)))
        end
        if not called then print('[HousingArrearsFlowTest] FAIL ' .. tostring(problem)) end
        print(('[HousingArrearsFlowTest] done %d/%d passed (MUTATING: house %s, run %s)'):format(passed, total, houseId, runId))
    end, true)
end
