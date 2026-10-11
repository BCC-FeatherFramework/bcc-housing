-- Prompts, blips, peds and objects on feather-toolkit, with the object shapes the
-- existing housing code was written against (replaces BccUtils.Prompts, Blips,
-- Ped and Objects). Toolkit tracks everything it creates and cleans it up when
-- bcc-housing stops.

local Toolkit = exports['feather-toolkit']

local function value(result, what)
    if type(result) == 'table' and result.ok then return result.value end
    DBG:Warning(('[toolkit] %s failed: %s'):format(what, type(result) == 'table' and tostring(result.code) or 'invalid_result'))
    return nil
end

-- Prompts --------------------------------------------------------------------

local Prompt = {}
Prompt.__index = Prompt

function Prompt:HasCompleted()
    local completed = Toolkit:IsPromptCompleted(self.id)
    return type(completed) == 'table' and completed.ok and completed.value == true
        or completed == true
end

function Prompt:EnabledPrompt(enabled)
    Toolkit:SetPromptEnabled(self.id, enabled == true)
end

function Prompt:TogglePrompt(visible)
    if self.handle then UiPromptSetVisible(self.handle, visible == true) end
end

function Prompt:DeletePrompt()
    if self.id then Toolkit:RemovePrompt(self.id) end
    self.id, self.handle = nil, nil
end

local Group = {}
Group.__index = Group

-- RegisterPrompt(label, control, _, _, enabled, mode['click'|'hold'], _)
function Group:RegisterPrompt(label, control, _, _, enabled, mode)
    local created = value(Toolkit:CreatePrompt({
        control = control,
        label = label,
        groupId = self.groupId,
        enabled = enabled ~= false,
        mode = mode == 'hold' and 'hold' or 'click'
    }), 'CreatePrompt')
    return setmetatable({ id = created and created.id, handle = created and created.handle }, Prompt)
end

function Group:ShowGroup(label)
    Toolkit:ShowPromptGroup(self.groupId, label)
end

HousingPrompts = {}

function HousingPrompts:SetupPromptGroup()
    return setmetatable({ groupId = GetRandomIntInRange(1, 0x7FFFFFFF) }, Group)
end

-- Blips ------------------------------------------------------------------------

local Blip = {}
Blip.__index = Blip

function Blip:Remove()
    if self.id then Toolkit:RemoveBlip(self.id) end
    self.id, self.rawblip = nil, nil
end

local Modifier = {}
Modifier.__index = Modifier

function Modifier:ApplyModifier()
    if self.blip and self.blip.rawblip and self.color then
        Citizen.InvokeNative(0x662D364ABF16DE2F, self.blip.rawblip, joaat(self.color)) -- BlipAddModifier
    end
end

HousingBlips = {}

local function SpriteHash(sprite)
    if type(sprite) == 'string' then return joaat(sprite) end
    return tonumber(sprite)
end

function HousingBlips:SetBlip(name, sprite, scale, x, y, z)
    local created = value(Toolkit:CreateBlip({ x = x, y = y, z = z, sprite = SpriteHash(sprite), name = name }), 'CreateBlip')
    if not created then return nil end
    if tonumber(scale) then SetBlipScale(created.handle, tonumber(scale) + 0.0) end
    return setmetatable({ id = created.id, rawblip = created.handle }, Blip)
end

function HousingBlips:AddBlipModifier(blip, color)
    return setmetatable({ blip = blip, color = color }, Modifier)
end

-- Removes a blip given its wrapper or its raw handle.
function HousingBlips:RemoveBlip(blip)
    if type(blip) == 'table' then return blip:Remove() end
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
end

-- Peds -------------------------------------------------------------------------

local Ped = {}
Ped.__index = Ped

function Ped:GetPed() return self.entity end
function Ped:Freeze(on) FreezeEntityPosition(self.entity, on ~= false) end
function Ped:Invincible(on) SetEntityInvincible(self.entity, on ~= false) end
function Ped:CanBeDamaged(on) SetEntityCanBeDamaged(self.entity, on == true) end
function Ped:SetBlockingOfNonTemporaryEvents(on) SetBlockingOfNonTemporaryEvents(self.entity, on ~= false) end
function Ped:SetAsMission() SetEntityAsMissionEntity(self.entity, true, true) end
function Ped:SetHeading(heading) SetEntityHeading(self.entity, tonumber(heading) or 0.0) end
function Ped:Remove()
    if self.id then Toolkit:RemoveEntity(self.id) end
    self.id, self.entity = nil, nil
end

HousingPed = {}

-- Create(model, x, y, z, heading, ...): local (non-networked) world ped.
function HousingPed:Create(model, x, y, z, heading)
    local created = value(Toolkit:CreatePed({
        model = model, x = x, y = y, z = z, heading = heading or 0.0, networked = false
    }), 'CreatePed')
    if not created then return nil end
    return setmetatable({ id = created.id, entity = created.entity }, Ped)
end

-- Objects ----------------------------------------------------------------------

local Object = {}
Object.__index = Object

function Object:GetObj() return self.entity end
function Object:PlaceOnGround() PlaceObjectOnGroundProperly(self.entity, true) end
function Object:Remove()
    if self.id then Toolkit:RemoveEntity(self.id) end
    self.id, self.entity = nil, nil
end

HousingObjects = {}

-- Create(model, x, y, z, heading, networked, offsetMode): placed exactly where
-- asked (furniture placement positions it afterwards), not frozen.
function HousingObjects:Create(model, x, y, z, heading, networked)
    if type(heading) ~= 'number' then
        networked, heading = heading, 0.0
    end
    local created = value(Toolkit:CreateObject({
        model = model, x = x, y = y, z = z, heading = heading or 0.0,
        networked = networked == true, placeOnGround = false, frozen = false
    }), 'CreateObject')
    if not created then return nil end
    return setmetatable({ id = created.id, entity = created.entity }, Object)
end
