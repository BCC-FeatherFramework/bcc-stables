-- bcc-stables' boundary to feather-jobs.
--
-- Config job entries { name, grade } are feather-jobs job keys and minimum
-- grade ordinals. Jobs returns facts; bcc-stables decides what they permit.

StablesJobs = {}

local RESOURCE = 'feather-jobs'

-- True when the character holds any of the listed jobs at the required grade.
function StablesJobs.HasAny(characterId, jobs)
    for _, job in pairs(jobs or {}) do
        local check = StablesCore.Call(RESOURCE, 'CheckAssignment', {
            characterId = characterId,
            jobKey = job.name,
            minGradeOrdinal = tonumber(job.grade) or 0
        })
        if check.ok and check.value.matched == true then
            return true
        end
    end
    return false
end

-- Job keys of every open assignment, for job-restricted horses in the shop.
function StablesJobs.Keys(characterId)
    local snapshot = StablesCore.Call(RESOURCE, 'GetEffectiveJobSnapshot', { characterId = characterId })
    local keys = {}
    if snapshot.ok and type(snapshot.value) == 'table' then
        for _, assignment in ipairs(snapshot.value.assignments or {}) do
            keys[#keys + 1] = assignment.jobKey
        end
    end
    return keys
end
