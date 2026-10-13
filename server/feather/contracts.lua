-- bcc-housing's boundary to feather-contracts: each monthly tax or rent charge
-- is a Contracts obligation (debtor: the holder, creditor: the system). Contracts
-- owns the debt, its audit trail and the settlement through feather-economy;
-- bcc-housing keeps only the house's tax state and the open obligation's ID
-- (bcchousing.tax_obligation_id).
--
--   Charge       due date: draft, issue, then collect from the holder's wallet
--   PayArrears   the holder pays an open obligation of a released house
--   CancelOpen   staff deleted the house: the open obligation is cancelled
--
-- Every request ID is derived from the house, the due date and the holder, so
-- the hourly tax run can repeat a step after a restart or an Economy timeout
-- without creating a second obligation or charging twice.

HousingContracts = { ready = false }

local RESOURCE = 'feather-contracts'

local TYPES = {
    tax = { typeKey = 'housing_property_tax', label = 'Property tax', reasonCode = 'housing.tax' },
    rent = { typeKey = 'housing_rent', label = 'House rent', reasonCode = 'housing.rent' }
}

local function call(operation, request, context)
    if GetResourceState(RESOURCE) ~= 'started' then
        return Housing.Err('dependency_unavailable', RESOURCE .. ' is not started.')
    end
    local called, result = pcall(function()
        local provider = exports[RESOURCE]
        return provider[operation](provider, request, context)
    end)
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return Housing.Err('dependency_unavailable', ('%s %s failed.'):format(RESOURCE, operation))
    end
    return result
end

local function describe(result)
    return ('%s %s'):format(tostring(result.code), tostring(result.message or ''))
end

function HousingContracts.Kind(row)
    return row.ownershipStatus == 'rented' and 'rent' or 'tax'
end

local function requestId(kind, houseId, dueKey, characterId, step)
    return ('bcc-housing:%s:%s:%s:%s:%s'):format(kind, tostring(houseId), dueKey, characterId:lower(), step)
end

-- Draft and issue (both replay safely). Returns the obligation snapshot.
local function open(row, dueKey, amountMinor, currency)
    local kind = HousingContracts.Kind(row)
    local characterId = row.character_id:lower()
    local draft = call('CreateDraft', {
        requestId = requestId(kind, row.houseid, dueKey, characterId, 'draft'),
        obligationType = TYPES[kind].typeKey,
        issuer = { type = 'system' },
        debtor = { type = 'character', id = characterId },
        creditor = { type = 'system' },
        amount = amountMinor,
        currency = currency,
        dueInSeconds = 0,
        referenceType = 'housing_house',
        referenceId = tostring(row.houseid),
        memo = ('House %s, due %s'):format(tostring(row.houseid), dueKey),
        reasonCode = TYPES[kind].reasonCode
    })
    if not draft.ok then return draft end
    local obligationId = draft.value.obligationId
    DB.exec('UPDATE bcchousing SET tax_obligation_id = ? WHERE houseid = ?', obligationId, row.houseid)
    -- A replayed draft returns its original snapshot; a replayed issue returns the issued one.
    return call('IssueObligation', {
        requestId = requestId(kind, row.houseid, dueKey, characterId, 'issue'),
        obligationId = obligationId,
        reasonCode = TYPES[kind].reasonCode
    })
end

-- The result of one collection or payment attempt:
--   Ok('settled')  paid
--   Err('insufficient_funds')  the wallet could not pay (Contracts keeps the debt)
--   Err('settlement_pending')  Economy's answer is unknown; Contracts replays it
--   any other Err  nothing changed; try again later
local function settled(result)
    if result.ok then
        return result.value.status == 'settled' and Housing.Ok('settled')
            or Housing.Err('invalid_state', 'Obligation is ' .. tostring(result.value.status))
    end
    return result
end

-- Charges the holder for one due date: a new obligation, collected at once.
function HousingContracts.Charge(row, dueKey, amountMinor, currency)
    if not HousingContracts.ready then
        return Housing.Err('dependency_unavailable', 'Contracts types are not registered yet.')
    end
    HousingContracts.CancelOpen(row, 'housing.holder_changed', row.character_id)
    local issued = open(row, dueKey, amountMinor, currency)
    if not issued.ok then return issued end
    return settled(call('SettleObligation', {
        requestId = requestId(HousingContracts.Kind(row), row.houseid, dueKey, row.character_id, 'collect'),
        obligationId = issued.value.obligationId
    }))
end

-- The holder pays the arrears of a released house. A house that went overdue
-- before taxes moved to Contracts has no obligation yet; one is opened for its
-- last processed due date first.
function HousingContracts.PayArrears(src, row, amountMinor, currency, paymentId)
    if not HousingContracts.ready then
        return Housing.Err('dependency_unavailable', 'Contracts types are not registered yet.')
    end
    local obligationId = row.tax_obligation_id
    if type(obligationId) ~= 'string' or obligationId == '' then
        local dueKey = row.last_tax_processed_at and tostring(row.last_tax_processed_at):sub(1, 10) or 'arrears'
        local issued = open(row, dueKey, amountMinor, currency)
        if not issued.ok then return issued end
        obligationId = issued.value.obligationId
    else
        -- An earlier payment whose Economy answer came late may already have settled it.
        local current = call('GetObligation', { obligationId = obligationId })
        if current.ok and current.value.status == 'settled' then return Housing.Ok('settled') end
    end
    return settled(call('SettleObligation', {
        requestId = 'bcc-housing:arrears:' .. paymentId,
        obligationId = obligationId
    }, { actorSource = src }))
end

function HousingContracts.Get(obligationId)
    return call('GetObligation', { obligationId = obligationId })
end

-- Cancels the house's open obligation. With keepFor, an obligation whose debtor
-- is that character is kept (it is the current holder's debt).
function HousingContracts.CancelOpen(row, reasonCode, keepFor)
    local obligationId = row.tax_obligation_id
    if type(obligationId) ~= 'string' or obligationId == '' or GetResourceState(RESOURCE) ~= 'started' then return end
    local current = call('GetObligation', { obligationId = obligationId })
    if not current.ok then return end
    local status = current.value.status
    if status == 'settled' or status == 'cancelled' or status == 'defaulted' then return end
    if keepFor and current.value.debtor and current.value.debtor.id == tostring(keepFor):lower() then return end
    local cancelled = call('CancelObligation', {
        requestId = 'bcc-housing:cancel:' .. obligationId,
        obligationId = obligationId,
        reasonCode = reasonCode
    })
    if cancelled.ok then
        DB.exec('UPDATE bcchousing SET tax_obligation_id = NULL WHERE houseid = ? AND tax_obligation_id = ?',
            row.houseid, obligationId)
    else
        DBG:Error('[Contracts] cancel failed', obligationId, describe(cancelled))
    end
end

-- Registration ----------------------------------------------------------------------

local function register()
    HousingContracts.ready = false
    local ready = call('AwaitReady', 30000)
    if not ready.ok then
        return print('[bcc-housing] contracts: feather-contracts is not ready: ' .. describe(ready))
    end
    for _, definition in pairs(TYPES) do
        local registered = call('RegisterObligationType', {
            typeKey = definition.typeKey,
            label = definition.label,
            issuerTypes = { 'system' },
            creditorTypes = { 'system' },
            currencies = { 'dollars', 'gold' },
            requiresAcceptance = false,
            debtorMaySettle = true,
            issuerMaySettle = true,
            debtorMayDispute = false
        })
        if not registered.ok then
            return print(('[bcc-housing] contracts: %s not registered: %s'):format(definition.typeKey, describe(registered)))
        end
    end
    HousingContracts.ready = true
    print('[bcc-housing] contracts: obligation types registered')
end

CreateThread(register)

AddEventHandler('onResourceStart', function(resource)
    if resource == RESOURCE then CreateThread(register) end
end)
