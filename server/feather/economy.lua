-- bcc-housing's boundary to feather-economy. bcc-housing keeps no balances:
-- every payment is one Economy movement, and every movement has a stable
-- idempotency key so a retry never charges twice.
--
-- Amounts in the housing config are whole units with up to two decimals
-- (dollars or gold); Economy amounts are minor units (cents).
--
--   Pay      character wallet -> system sink   (purchase, rent, taxes, furniture, storage)
--   PayTo    buyer wallet     -> seller wallet (sale between players)
--   Issue    system source    -> wallet        (sale back to the agent, furniture sell-back)
--
-- Issue creates currency, so it is policy-gated in Economy: bcc-housing must be in
-- trustedSuppliers and have the economy.currency.issue service grant. It is called
-- without an actor source, as the bcc-housing service principal.

HousingEconomy = {}

local RESOURCE = 'feather-economy'

-- Housing currency types: 0 = dollars, 1 = gold. 2 (Rol tokens) has no Feather
-- currency and is refused.
local CURRENCIES = { [0] = 'dollars', [1] = 'gold' }

function HousingEconomy.Currency(currencyType)
    return CURRENCIES[tonumber(currencyType) or 0]
end

function HousingEconomy.ToMinor(amount)
    return math.floor((tonumber(amount) or 0) * 100 + 0.5)
end

function HousingEconomy.ToMajor(minor)
    return (tonumber(minor) or 0) / 100
end

local function call(operation, request, context)
    if GetResourceState(RESOURCE) ~= 'started' then
        return Housing.Err('economy_unavailable', 'Feather Economy is not started.')
    end
    local called, result = pcall(function()
        local provider = exports[RESOURCE]
        return provider[operation](provider, request, context)
    end)
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return Housing.Err('economy_unavailable', ('Feather Economy %s failed.'):format(operation))
    end
    return result
end

-- The character's wallet account for a currency (provisioned if missing).
function HousingEconomy.Wallet(characterId, currency)
    local result = call('EnsureCharacterWallets', { characterId = characterId })
    if not result.ok then return result end
    for _, account in ipairs(result.value) do
        if account.accountType == 'wallet' and account.currency == currency then
            return Housing.Ok(account)
        end
    end
    return Housing.Err('wallet_not_found', 'Economy returned no wallet for ' .. tostring(currency) .. '.')
end

-- Wallet balance in whole units, or nil when Economy is unavailable.
function HousingEconomy.Balance(characterId, currency)
    local wallet = HousingEconomy.Wallet(characterId, currency)
    if not wallet.ok then return nil end
    local account = call('GetAccount', { accountId = wallet.value.accountId })
    if not account.ok then return nil end
    return HousingEconomy.ToMajor(account.value.balance)
end

function HousingEconomy.HasFunds(characterId, currency, amount)
    local balance = HousingEconomy.Balance(characterId, currency)
    return balance ~= nil and balance >= (tonumber(amount) or 0)
end

local function sink(currency)
    local result = call('GetSystemAccount', { currency = currency, accountType = 'system_sink' })
    if not result.ok then return result end
    return Housing.Ok(result.value.accountId)
end

local function reference(ref)
    if type(ref) ~= 'table' then return nil, nil end
    return ref.type, ref.id ~= nil and tostring(ref.id) or nil
end

local function logResult(what, reasonCode, amount, currency, result)
    if result.ok then
        DBG:Success(('[Economy] %s %s %s %s done: tx %s replayed %s'):format(what, reasonCode, tostring(amount),
            currency, tostring(result.value and result.value.transactionId), tostring(result.value and result.value.replayed)))
    else
        DBG:Error(('[Economy] %s %s %s %s failed: %s %s'):format(what, reasonCode, tostring(amount), currency,
            tostring(result.code), tostring(result.message)))
    end
    return result
end

-- Character pays an amount to the system sink.
function HousingEconomy.Pay(character, currency, amount, reasonCode, ref, idempotencyKey)
    local wallet = HousingEconomy.Wallet(character.characterId, currency)
    if not wallet.ok then return wallet end
    local target = sink(currency)
    if not target.ok then return target end
    local referenceType, referenceId = reference(ref)
    return logResult('pay', reasonCode, amount, currency, call('Transfer', {
        fromAccountId = wallet.value.accountId,
        toAccountId = target.value,
        currency = currency,
        amount = HousingEconomy.ToMinor(amount),
        reasonCode = reasonCode,
        referenceType = referenceType,
        referenceId = referenceId,
        idempotencyKey = idempotencyKey
    }, {
        actorCharacterId = character.characterId,
        actorAccountId = character.accountId,
        correlationId = idempotencyKey
    }))
end

-- One character pays another (wallet to wallet).
function HousingEconomy.PayTo(payer, payeeCharacterId, currency, amount, reasonCode, ref, idempotencyKey)
    local from = HousingEconomy.Wallet(payer.characterId, currency)
    if not from.ok then return from end
    local to = HousingEconomy.Wallet(payeeCharacterId, currency)
    if not to.ok then return to end
    local referenceType, referenceId = reference(ref)
    return logResult('pay-to', reasonCode, amount, currency, call('Transfer', {
        fromAccountId = from.value.accountId,
        toAccountId = to.value.accountId,
        currency = currency,
        amount = HousingEconomy.ToMinor(amount),
        reasonCode = reasonCode,
        referenceType = referenceType,
        referenceId = referenceId,
        idempotencyKey = idempotencyKey
    }, {
        actorCharacterId = payer.characterId,
        actorAccountId = payer.accountId,
        correlationId = idempotencyKey
    }))
end

-- Creates an amount in a character's wallet (policy-gated supply). Works while
-- the character is offline.
function HousingEconomy.Issue(characterId, currency, amount, reasonCode, ref, idempotencyKey)
    local wallet = HousingEconomy.Wallet(characterId, currency)
    if not wallet.ok then return wallet end
    local referenceType, referenceId = reference(ref)
    return logResult('issue', reasonCode, amount, currency, call('Issue', {
        accountId = wallet.value.accountId,
        currency = currency,
        amount = HousingEconomy.ToMinor(amount),
        reasonCode = reasonCode,
        referenceType = referenceType,
        referenceId = referenceId,
        idempotencyKey = idempotencyKey
    }, {
        correlationId = idempotencyKey
    }))
end

-- Player-facing message key for an Economy failure. insufficientKey overrides the
-- generic "not enough cash/gold" text (e.g. a house-specific one).
function HousingEconomy.MessageKey(result, currency, insufficientKey)
    local code = type(result) == 'table' and result.code or nil
    if code == 'insufficient_funds' then
        return insufficientKey or (currency == 'gold' and 'noGold' or 'noMoney')
    end
    return 'transactionFailed'
end
