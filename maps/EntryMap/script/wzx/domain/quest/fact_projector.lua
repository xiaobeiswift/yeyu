-- Map submitted domain facts onto quest objective progress (system 14).
-- Only white-listed payload fields are read; no side effects.

local Result = require 'wzx.domain.common.result'
local QuestErrorCodes = require 'wzx.domain.quest.error_codes'

local FactProjector = {}
local get_metatable = getmetatable
local math_min = math.min
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.quest.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(QuestErrorCodes.QUEST_ARGUMENT_INVALID, reason, details)
end

local function once_complete(objective)
    return {
        delta = objective.required_count,
        complete = true,
        reason = 'ONCE_FACT',
    }
end

local function accumulate(objective, amount)
    if type_value(amount) ~= 'number' or amount < 1 then
        return nil
    end
    return {
        delta = amount,
        complete = false,
        reason = 'ACCUMULATE',
    }
end

--- Project a fact onto one objective definition.
-- @return ok + { matched=bool, delta?, complete? } or error
function FactProjector.project(objective, event)
    if type_value(objective) ~= 'table' or get_metatable(objective) ~= nil then
        return invalid('OBJECTIVE_REQUIRED')
    end
    if type_value(event) ~= 'table' or get_metatable(event) ~= nil then
        return invalid('EVENT_REQUIRED')
    end
    if objective.event_type == nil or event.event_type ~= objective.event_type then
        return result_ok({ matched = false, reason = 'EVENT_TYPE_MISMATCH' })
    end

    local payload = raw_get(event, 'payload')
    if type_value(payload) ~= 'table' then
        return result_ok({ matched = false, reason = 'PAYLOAD_MISSING' })
    end

    if objective.objective_type == 'COMPLETE_ENCOUNTER' then
        local encounter_id = raw_get(payload, 'encounter_id')
        local result = raw_get(payload, 'result')
        if objective.target_id ~= nil and encounter_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'ENCOUNTER_ID_MISMATCH' })
        end
        if result ~= nil and result ~= 'ATTACKER_WIN' and result ~= 'VICTORY' then
            return result_ok({ matched = false, reason = 'RESULT_NOT_VICTORY' })
        end
        if objective.progress_semantics == 'ONCE_FACT' then
            local projected = once_complete(objective)
            projected.matched = true
            return result_ok(projected)
        end
        local projected = accumulate(objective, 1)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'DEFEAT_ENEMY' then
        local defeated = raw_get(payload, 'defeated_entries')
        if type_value(defeated) ~= 'table' then
            return result_ok({ matched = false, reason = 'DEFEATED_ENTRIES_MISSING' })
        end
        local total = 0
        local index
        for index = 1, #defeated do
            local entry = defeated[index]
            if type_value(entry) == 'table' then
                local enemy_id = raw_get(entry, 'enemy_id')
                local count = raw_get(entry, 'count') or 1
                local tags = raw_get(entry, 'tags')
                local matched = false
                if objective.target_id ~= nil and enemy_id == objective.target_id then
                    matched = true
                elseif objective.target_tag ~= nil and type_value(tags) == 'table' then
                    local tag_index
                    for tag_index = 1, #tags do
                        if tags[tag_index] == objective.target_tag then
                            matched = true
                            break
                        end
                    end
                end
                if matched and type_value(count) == 'number' and count > 0 then
                    total = total + count
                end
            end
        end
        if total < 1 then
            return result_ok({ matched = false, reason = 'NO_MATCHING_DEFEATS' })
        end
        local projected = accumulate(objective, total)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'TALK' then
        local dialogue_id = raw_get(payload, 'dialogue_id')
        if objective.target_id ~= nil and dialogue_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'DIALOGUE_MISMATCH' })
        end
        local projected = once_complete(objective)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'REACH_LOCATION' then
        local location_id = raw_get(payload, 'location_id')
        if objective.target_id ~= nil and location_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'LOCATION_MISMATCH' })
        end
        local projected = once_complete(objective)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'OPEN_CHEST' then
        local interactable_id = raw_get(payload, 'interactable_id')
        if objective.target_id ~= nil and interactable_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'INTERACTABLE_MISMATCH' })
        end
        local projected = once_complete(objective)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'SEARCH_POINT' then
        local interactable_id = raw_get(payload, 'interactable_id')
        if objective.target_id ~= nil and interactable_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'INTERACTABLE_MISMATCH' })
        end
        local projected = once_complete(objective)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'TRAVERSAL_LANDING' then
        local to_cell_id = raw_get(payload, 'to_cell_id')
            or raw_get(payload, 'target_cell_id')
        if objective.target_id ~= nil and to_cell_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'CELL_MISMATCH' })
        end
        local projected = once_complete(objective)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'WATER_WALK_ENTER' then
        local water_zone_id = raw_get(payload, 'water_zone_id')
        if objective.target_id ~= nil and water_zone_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'WATER_ZONE_MISMATCH' })
        end
        local projected = once_complete(objective)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'WATER_WALK_EXIT' then
        local water_zone_id = raw_get(payload, 'water_zone_id')
        if objective.target_id ~= nil and water_zone_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'WATER_ZONE_MISMATCH' })
        end
        local projected = once_complete(objective)
        projected.matched = true
        return result_ok(projected)
    end

    if objective.objective_type == 'ACQUIRE_ITEM' then
        local item_id = raw_get(payload, 'item_id')
        local amount = raw_get(payload, 'amount') or 0
        if objective.target_id ~= nil and item_id ~= objective.target_id then
            return result_ok({ matched = false, reason = 'ITEM_MISMATCH' })
        end
        if type_value(amount) ~= 'number' or amount < 1 then
            return result_ok({ matched = false, reason = 'AMOUNT_INVALID' })
        end
        local projected = accumulate(objective, amount)
        projected.matched = true
        return result_ok(projected)
    end

    return result_ok({ matched = false, reason = 'OBJECTIVE_TYPE_UNSUPPORTED' })
end

function FactProjector.apply_delta(progress, required_count, delta, semantics)
    if type_value(progress) ~= 'number' or type_value(required_count) ~= 'number' then
        return invalid('PROGRESS_REQUIRED')
    end
    if type_value(delta) ~= 'number' or delta < 0 then
        return invalid('DELTA_INVALID')
    end
    local next_progress = progress
    if semantics == 'ONCE_FACT' then
        next_progress = math_min(required_count, math.max(progress, delta > 0 and required_count or progress))
        if delta > 0 then
            next_progress = required_count
        end
    else
        next_progress = math_min(required_count, progress + delta)
    end
    return result_ok({
        progress = next_progress,
        status = next_progress >= required_count and 'COMPLETE' or 'IN_PROGRESS',
        increased = next_progress > progress,
    })
end

return FactProjector
