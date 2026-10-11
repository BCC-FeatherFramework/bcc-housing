-- Housing administration is a feather-authority capability, evaluated through
-- Authority directly. bcc-housing owns the capability and one staff
-- role that grants it; the console commands below assign or clear that role
-- for a connected player's active character.
HousingAuthority = {}

local REASON_CODE = 'bcc-housing.admin'
local ROLE_LABEL = 'Housing Administrator'
local CAPABILITY_DESCRIPTION = 'Create, edit and delete bcc-housing houses; manage any house.'

local function adminConfig()
    return (Config and Config.Admin) or {}
end

function HousingAuthority.CapabilityKey()
    return adminConfig().capability or 'staff.housing.manage'
end

local function roleKey()
    return adminConfig().role or 'staff.housing.admin'
end

local function describe(result)
    if type(result) ~= 'table' then return 'invalid_result' end
    return ('%s %s'):format(tostring(result.code), tostring(result.message or ''))
end

local function ownedRole()
    local role = exports['feather-authority']:FindRoleByKey({ roleKey = roleKey() })
    if type(role) ~= 'table' or not role.ok then return role end
    if role.value.ownerResource ~= GetCurrentResourceName() then
        return { ok = false, code = 'role_owner_conflict',
            message = ('Role %s belongs to %s.'):format(roleKey(), tostring(role.value.ownerResource)) }
    end
    return role
end

-- Registers the capability, creates the role and grants the capability to it.
-- Every step is idempotent, so this is safe on each bcc-housing or Authority start.
function HousingAuthority.Provision()
    local ready = exports['feather-authority']:AwaitReady(30000)
    if type(ready) ~= 'table' or not ready.ok then
        return print('[bcc-housing] authority: feather-authority is not ready: ' .. describe(ready))
    end

    local capability = HousingAuthority.CapabilityKey()
    local registered = exports['feather-authority']:RegisterCapabilities({
        requestId = 'bcc-housing:capability:' .. capability,
        capabilities = { { key = capability, description = CAPABILITY_DESCRIPTION, riskClass = 'high' } }
    })
    if type(registered) ~= 'table' or not registered.ok then
        return print('[bcc-housing] authority: capability registration failed: ' .. describe(registered))
    end

    local role = ownedRole()
    if type(role) == 'table' and role.code == 'role_not_found' then
        role = exports['feather-authority']:CreateRole({
            requestId = 'bcc-housing:role:' .. roleKey(),
            roleKey = roleKey(),
            label = ROLE_LABEL,
            roleClass = 'staff',
            reasonCode = REASON_CODE
        })
    end
    if type(role) ~= 'table' or not role.ok then
        return print('[bcc-housing] authority: role setup failed: ' .. describe(role))
    end

    local grants = exports['feather-authority']:ListRoleGrants({ roleId = role.value.roleId })
    if type(grants) ~= 'table' or not grants.ok then
        return print('[bcc-housing] authority: grant lookup failed: ' .. describe(grants))
    end
    for _, grant in ipairs(grants.value) do
        if grant.capabilityKey == capability and grant.scopeType == 'server' and grant.status == 'active' then
            return print(('[bcc-housing] authority: ready (%s -> %s)'):format(roleKey(), capability))
        end
    end

    local granted = exports['feather-authority']:GrantRoleCapability({
        requestId = ('bcc-housing:grant:%s:%s:r%d'):format(roleKey(), capability, role.value.revision),
        roleId = role.value.roleId,
        capabilityKey = capability,
        expectedRevision = role.value.revision,
        scopeType = 'server',
        reasonCode = REASON_CODE
    })
    if type(granted) ~= 'table' or not granted.ok then
        return print('[bcc-housing] authority: capability grant failed: ' .. describe(granted))
    end
    print(('[bcc-housing] authority: ready (%s -> %s)'):format(roleKey(), capability))
end

-- Fails closed: any missing account, capability or assignment denies. Asks
-- Authority directly: Core's default policy provider is feather-admin, which
-- only knows Admin's own actions.
function HousingAuthority.IsAllowed(src)
    local session = exports['feather-core']:GetSessionContext(src)
    if type(session) ~= 'table' or not session.ok or type(session.value) ~= 'table'
        or type(session.value.characterId) ~= 'string' then
        return false, 'unauthenticated'
    end
    -- Feather Admin staff: Admin grants its roles capabilities named
    -- staff.admin.<action>. A character holding one of the configured ones (by
    -- default one that only administrators and owners get) is allowed.
    for _, capability in ipairs(adminConfig().staffCapabilities or {}) do
        local staff = exports['feather-authority']:Evaluate({
            subjectType = 'character',
            subjectId = session.value.characterId,
            capabilityKey = capability,
            scopeType = 'server'
        })
        if type(staff) == 'table' and staff.ok == true and type(staff.value) == 'table'
            and staff.value.allowed == true then
            return true, 'admin_staff:' .. capability
        end
    end
    local decision = exports['feather-authority']:Evaluate({
        subjectType = 'character',
        subjectId = session.value.characterId,
        capabilityKey = HousingAuthority.CapabilityKey(),
        scopeType = 'server'
    })
    if type(decision) ~= 'table' or decision.ok ~= true or type(decision.value) ~= 'table' then
        return false, type(decision) == 'table' and decision.code or 'invalid_result'
    end
    return decision.value.allowed == true, decision.value.reason
end

-- Assigns (roleWanted = true) or clears the housing admin role for a connected player.
local function replaceAssignment(target, roleWanted)
    local session = exports['feather-core']:GetSessionContext(target)
    if type(session) ~= 'table' or not session.ok or type(session.value) ~= 'table'
        or type(session.value.characterId) ~= 'string' then
        return false, 'Player ' .. tostring(target) .. ' has no active character.'
    end
    local characterId = session.value.characterId
    local request = {
        requestId = ('bcc-housing:%s:%s:%d:%d'):format(roleWanted and 'assign' or 'clear',
            characterId, os.time(), GetGameTimer() % 100000),
        subjectType = 'character',
        subjectId = characterId,
        scopeType = 'server',
        reason = roleWanted and 'Housing administration granted from the server console.'
            or 'Housing administration removed from the server console.',
        reasonCode = REASON_CODE
    }
    if roleWanted then
        local role = ownedRole()
        if type(role) ~= 'table' or not role.ok then return false, 'Role lookup failed: ' .. describe(role) end
        request.roleId = role.value.roleId
        request.expectedRoleRevision = role.value.revision
    end
    local result = exports['feather-authority']:ReplaceOwnedStaffAssignment(request)
    if type(result) ~= 'table' or not result.ok then return false, describe(result) end
    return true, characterId
end

RegisterCommand('HousingAdminGrant', function(source, args)
    if source ~= 0 then return end
    local target = tonumber(args[1])
    if not target then return print('[bcc-housing] Usage: HousingAdminGrant <server id>') end
    local ok, detail = replaceAssignment(target, true)
    print(ok and ('[bcc-housing] Housing admin granted to character %s'):format(detail)
        or ('[bcc-housing] Housing admin grant failed: %s'):format(detail))
end, true)

RegisterCommand('HousingAdminRevoke', function(source, args)
    if source ~= 0 then return end
    local target = tonumber(args[1])
    if not target then return print('[bcc-housing] Usage: HousingAdminRevoke <server id>') end
    local ok, detail = replaceAssignment(target, false)
    print(ok and ('[bcc-housing] Housing admin removed from character %s'):format(detail)
        or ('[bcc-housing] Housing admin removal failed: %s'):format(detail))
end, true)

CreateThread(HousingAuthority.Provision)

AddEventHandler('onResourceStart', function(resource)
    if resource == 'feather-authority' then CreateThread(HousingAuthority.Provision) end
end)
