-- Job checks through feather-jobs (replaces character.job / character.jobGrade).
-- Jobs are feather-jobs job keys; a grade is the minimum grade ordinal. Fails
-- closed when feather-jobs is not running or does not know the job.
HousingJobs = {}

function HousingJobs.Holds(characterId, jobKey, minGrade, requireOnDuty)
    if type(characterId) ~= 'string' or type(jobKey) ~= 'string' or jobKey == '' then return false end
    local request = { characterId = characterId, jobKey = jobKey }
    if tonumber(minGrade) and tonumber(minGrade) > 0 then
        request.minGradeOrdinal = math.floor(tonumber(minGrade))
    end
    if requireOnDuty then request.dutyState = 'on_duty' end
    local result = Housing.Call('feather-jobs', 'CheckAssignment', request)
    if not result.ok then
        DBG:Warning('[jobs] check failed:', jobKey, tostring(result.code))
        return false
    end
    return type(result.value) == 'table' and result.value.matched == true
end

-- True when the character holds one of the entries: 'job' or { name|job|[1], grade|[2] }.
function HousingJobs.HoldsAny(characterId, entries, requireOnDuty)
    for _, entry in ipairs(type(entries) == 'table' and entries or {}) do
        local job, grade = entry, 0
        if type(entry) == 'table' then
            job = entry.name or entry.job or entry.jobname or entry[1]
            grade = tonumber(entry.grade or entry[2] or 0) or 0
        end
        if HousingJobs.Holds(characterId, job, grade, requireOnDuty) then return true end
    end
    return false
end
