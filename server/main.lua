HousingRPC:Register('bcc-housing:CheckIfAdmin', function(params, cb, src)
    cb(IsHousingAdmin(src) == true)
end)

HousingRPC:Register('bcc-housing:CheckJob', function(params, cb, src)
    local location = params and params.location
    local character = GetHousingCharacter(src)
    if not character or not location then return cb(false) end
    local agent = Agents[location]
    local jobCfg = agent and agent.shop and agent.shop.jobs
    if type(jobCfg) ~= 'table' or not character then return cb(false) end

    -- { name = job key, grade = minimum grade ordinal } through feather-jobs.
    cb(HousingJobs.HoldsAny(character.characterId, jobCfg, false))
end)

-- Check for version updates
