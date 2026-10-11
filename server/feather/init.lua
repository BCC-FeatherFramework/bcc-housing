-- bcc-housing's boundary to the Feather Framework (server side).
--
-- Keeps the call shapes the existing services were written against (an RPC
-- object with Register/Notify/Call/CallAsync, character objects with
-- charIdentifier/firstname/lastname, Discord:sendMessage) while every value now
-- comes from feather-core sessions and the Character provider. Character IDs are
-- UUIDs; nothing the client sends is trusted for identity.

-- RPC --------------------------------------------------------------------------
-- Handler shape as before: function(params, cb, source). cb(...) may return
-- several values; Core forwards them all.

HousingRPC = {}

local defaultRpcOptions = { windowMs = 1000, maxCalls = 20, maxPayloadBytes = 32768, requireCharacter = true }

function HousingRPC:Register(name, handler, options)
    local registered = exports['feather-core']:RegisterRPC(name, function(params, respond, src)
        local called, problem = xpcall(handler, debug.traceback, params or {}, respond, src)
        if not called then
            print(('[bcc-housing] rpc %s failed: %s'):format(name, tostring(problem)))
            respond(false)
        end
    end, options or defaultRpcOptions)
    if registered ~= true then
        print(('[bcc-housing] rpc registration failed: %s'):format(name))
    end
end

-- Server-to-client procedures.
function HousingRPC:Notify(name, params, target)
    return exports['feather-core']:NotifyRPC(name, params or {}, target)
end

function HousingRPC:Call(name, params, callback, target)
    return exports['feather-core']:CallRPC(name, params or {}, callback, target)
end

function HousingRPC:CallAsync(name, params, target)
    return exports['feather-core']:CallRPCAsync(name, params or {}, target)
end

-- Characters -------------------------------------------------------------------

HousingCharacters = {}
local names = {} -- characterId -> { firstname, lastname }

local function IsCallable(value)
    return type(value) == 'function' or (type(value) == 'table'
        and type(rawget(value, '__cfx_functionReference')) == 'string')
end

local function ProfileProvider()
    local provider = exports['feather-core']:GetProvider('character-profile', nil, 1)
    local implementation = type(provider) == 'table' and provider.ok and provider.value.implementation or nil
    if type(implementation) ~= 'table' then return nil end
    return implementation
end

-- First and last name of any character, online or offline.
function HousingCharacters.GetName(characterId)
    if type(characterId) ~= 'string' then return 'Unknown', 'Unknown' end
    local cached = names[characterId]
    if cached then return cached.firstname, cached.lastname end
    local provider = ProfileProvider()
    if provider and IsCallable(provider.GetProfile) then
        local profile = provider.GetProfile(characterId)
        if type(profile) == 'table' and profile.ok and type(profile.value) == 'table' then
            names[characterId] = {
                firstname = profile.value.firstName or 'Unknown',
                lastname = profile.value.lastName or 'Unknown'
            }
            return names[characterId].firstname, names[characterId].lastname
        end
    end
    return 'Unknown', 'Unknown'
end

function HousingCharacters.GetFullName(characterId)
    local firstname, lastname = HousingCharacters.GetName(characterId)
    return firstname .. ' ' .. lastname
end

-- The active character of a connected player, or nil.
function HousingCharacters.Get(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end
    local session = exports['feather-core']:GetSessionContext(src)
    if type(session) ~= 'table' or not session.ok or type(session.value) ~= 'table'
        or type(session.value.characterId) ~= 'string' then
        return nil
    end
    local characterId = session.value.characterId:lower()
    local firstname, lastname = HousingCharacters.GetName(characterId)
    return {
        source = src,
        charIdentifier = characterId,
        identifier = characterId,
        accountId = session.value.accountId,
        firstname = firstname,
        lastname = lastname
    }
end

-- Server ID of a character if they are online, else nil.
function HousingCharacters.FindSource(characterId)
    for _, playerId in ipairs(GetPlayers()) do
        local character = HousingCharacters.Get(playerId)
        if character and character.charIdentifier == characterId then return tonumber(playerId) end
    end
    return nil
end

AddEventHandler('onResourceStart', function(resource)
    if resource == 'feather-character' then names = {} end
end)

-- Domain calls -----------------------------------------------------------------
-- Calls a Feather domain export so the invoking resource is bcc-housing, and
-- turns exceptions or malformed replies into error envelopes.

function Housing.Call(resource, operation, request)
    if GetResourceState(resource) ~= 'started' then
        return Housing.Err('dependency_unavailable', resource .. ' is not started.')
    end
    local called, result = pcall(function()
        local provider = exports[resource]
        return provider[operation](provider, request)
    end)
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return Housing.Err('dependency_unavailable', ('%s %s failed.'):format(resource, operation))
    end
    return result
end

-- A server-generated UUID for request IDs.
function Housing.NewId()
    return DB.value('SELECT UUID()')
end

-- Discord webhook (replaces BccUtils.Discord). Sends nothing when no link is set.
Discord = {}

function Discord:sendMessage(title, description)
    local link = Config.WebhookLink
    if type(link) ~= 'string' or not link:match('^https://discord%.com/api/webhooks/') then return end
    local content = description and (tostring(title) .. '\n' .. tostring(description)) or tostring(title)
    PerformHttpRequest(link, function() end, 'POST', json.encode({
        username = Config.WebhookTitle or 'BCC-Housing',
        avatar_url = (Config.WebhookAvatar ~= '' and Config.WebhookAvatar) or nil,
        content = content:sub(1, 2000)
    }), { ['Content-Type'] = 'application/json' })
end
