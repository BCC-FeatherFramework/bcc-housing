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
    local src = row.charidentifier and HousingCharacters.FindSource(row.charidentifier)
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
    if not currency or type(row.charidentifier) ~= 'string' then
        DBG:Warning('[Taxes] house', row.houseid, 'has no payable currency or holder')
        return
    end
    -- One key per house and due date: a restart on the due day never charges twice.
    local paid = HousingEconomy.Pay({ charIdentifier = row.charidentifier }, currency, taxAmount, reasonFor(row),
        { type = 'housing_house', id = row.houseid }, ('housing:tax:%s:%s'):format(row.houseid, dueKey))
    if paid.ok then
        DB.exec("UPDATE bcchousing SET taxes_collected = 'true', last_tax_processed_at = ? WHERE houseid = ?", dueKey, row.houseid)
        sendTaxWebhook(row, "paid", currency)
        DBG:Success('[Taxes] house', row.houseid, 'paid', taxAmount, currency, 'for', dueKey)
    elseif paid.code == 'insufficient_funds' then
        markOverdue(row, dueKey)
        sendTaxWebhook(row, "overdue", currency)
        DBG:Warning('[Taxes] house', row.houseid, 'overdue for', dueKey)
    else
        -- Economy unavailable: try again at the next check.
        DBG:Error('[Taxes] house', row.houseid, 'charge failed:', paid.code, paid.message)
    end
end

function HousingTaxes.Collect(currentDate)
    currentDate = currentDate or today()
    for _, row in ipairs(DB.query("SELECT * FROM bcchousing") or {}) do
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

-- Pay ahead / pay arrears --------------------------------------------------------

local function maxMonths()
    return math.max(1, math.min(tonumber(Config.Setup.MaxTaxPrepayMonths) or 12, 24))
end

-- months = how many months to pay ahead. A 'released' (overdue) house first pays
-- one period of arrears, which reactivates it; months may be 0 then.
HousingRPC:Register('bcc-housing:PayTaxes', function(params, cb, src)
    local houseId = tonumber(params and params.houseid)
    local months = math.floor(tonumber(params and params.months) or 0)
    local character = GetHousingCharacter(src)
    if not houseId or not character then return cb(false, { error = 'invalid_params' }) end
    if not IsHouseOwner(src, houseId) then
        NotifyClient(src, _U('noAccessToHouse'), 4000, 'error')
        return cb(false)
    end
    local row = DB.one("SELECT * FROM bcchousing WHERE houseid = ?", houseId)
    if not row then return cb(false) end
    local status = tostring(row.taxes_collected)
    local taxAmount = tonumber(row.tax_amount) or 0
    local currency = HousingTaxes.Currency(row)
    if not currency or taxAmount <= 0 then
        NotifyClient(src, _U('currencyNotSupported'), 4000, 'error')
        return cb(false)
    end
    if status == 'overdue' then
        NotifyClient(src, _U('taxesOverdue'), 5000, 'error')
        return cb(false, { error = 'overdue' })
    end
    if months < 0 or months > maxMonths() or (months == 0 and status ~= 'released') then
        NotifyClient(src, _U('taxesPrepayLimit', maxMonths()), 4000, 'error')
        return cb(false, { error = 'invalid_months' })
    end

    local periods = months + (status == 'released' and 1 or 0)
    local amount = taxAmount * periods
    local paymentId = Housing.NewId()
    local paid = HousingEconomy.Pay(character, currency, amount, reasonFor(row),
        { type = 'housing_house', id = houseId }, 'housing:tax-pay:' .. paymentId)
    if not paid.ok then
        NotifyClient(src, _U(HousingEconomy.MessageKey(paid, currency)), 4000, 'error')
        return cb(false, { error = paid.code })
    end

    local result = { taxesPaid = status == 'released' }
    if status == 'released' then
        DB.exec("UPDATE bcchousing SET taxes_collected = 'true' WHERE houseid = ? AND taxes_collected = 'released'", houseId)
        local reactivated = HousingProperty.SetStatus(propertyKey(row), 'active',
            HousingProperty.RequestId('tax-reactivate', houseId, paymentId), 'housing.tax_paid')
        if not reactivated.ok then DBG:Error('[PayTaxes] reactivate failed', reactivated.code) end
        NotifyClient(src, _U('taxesArrearsPaid'), 5000, 'success')
    end
    if months > 0 then
        local base = parseMysqlDate(row.taxes_paid_until)
        local now = today()
        if not base or compareDateParts(base, now) < 0 then base = now end
        local untilDate = addMonths(base, months)
        local untilKey = formatDateKey(untilDate)
        DB.exec("UPDATE bcchousing SET taxes_paid_until = ? WHERE houseid = ?", untilKey, houseId)
        result.paidUntil = untilKey
        NotifyClient(src, _U('taxesPaidAhead', formatMoney(taxAmount * months), months, untilKey), 6000, 'success')
    end
    cb(true, result)
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
