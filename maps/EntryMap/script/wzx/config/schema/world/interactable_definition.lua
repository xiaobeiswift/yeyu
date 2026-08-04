local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.world.validation'

local InteractableDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'InteractableDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    interactable_type = true,
    location_id = true,
    marker_id = true,
    interaction_radius_cm = true,
    action_ref_id = true,
    persistence_policy = true,
    prompt_key = true,
    priority = true,
    result_type = true,
    result_ref_id = true,
    flag_id = true,
    flag_value = true,
    initial_state = true,
    deprecated = true,
}
local INTERACTABLE_TYPES = {
    CHEST = true,
    SEARCH = true,
    GATHER = true,
    NPC = true,
    ENCOUNTER = true,
    INSPECT = true,
}
local PERSISTENCE = {
    NONE = true,
    ONCE = true,
    PER_PERIOD = true,
    STATEFUL = true,
}
local RESULT_TYPES = {
    REWARD = true,
    DIALOGUE = true,
    FLAG = true,
    ENCOUNTER = true,
    NONE = true,
}
local INITIAL_STATES = {
    AVAILABLE = true,
    HIDDEN = true,
}

function InteractableDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local persistence_policy = raw_get(value, 'persistence_policy')
    if persistence_policy == nil then
        local itype = raw_get(value, 'interactable_type')
        if itype == 'CHEST' or itype == 'SEARCH' then
            persistence_policy = 'ONCE'
        else
            persistence_policy = 'NONE'
        end
    end
    local radius = raw_get(value, 'interaction_radius_cm')
    if radius == nil then
        radius = 150
    end
    local priority = raw_get(value, 'priority')
    if priority == nil then
        priority = 0
    end
    local result_type = raw_get(value, 'result_type')
    if result_type == nil then
        result_type = 'NONE'
    end
    local initial_state = raw_get(value, 'initial_state')
    if initial_state == nil then
        initial_state = 'AVAILABLE'
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'interact_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_enum(SCHEMA, 'interactable_type', value.interactable_type, INTERACTABLE_TYPES),
        validation_content_id(SCHEMA, 'location_id', value.location_id, 'location_'),
        validation_content_id(SCHEMA, 'marker_id', value.marker_id, 'marker_', true),
        validation_integer(SCHEMA, 'interaction_radius_cm', radius, 50, 1000),
        validation_enum(SCHEMA, 'persistence_policy', persistence_policy, PERSISTENCE),
        validation_non_empty_string(SCHEMA, 'prompt_key', value.prompt_key),
        validation_integer(SCHEMA, 'priority', priority, -1000, 1000),
        validation_enum(SCHEMA, 'result_type', result_type, RESULT_TYPES),
        validation_enum(SCHEMA, 'initial_state', initial_state, INITIAL_STATES),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    local interactable_type = value.interactable_type
    local action_ref_id = raw_get(value, 'action_ref_id')
    local result_ref_id = raw_get(value, 'result_ref_id')
    local flag_id = raw_get(value, 'flag_id')
    local flag_value = raw_get(value, 'flag_value')

    if interactable_type == 'CHEST' then
        if action_ref_id == nil then
            return validation_invalid(SCHEMA, 'action_ref_id', 'REWARD_REF_REQUIRED')
        end
        err = validation_content_id(SCHEMA, 'action_ref_id', action_ref_id, 'reward_')
        if err ~= nil then
            return err
        end
        if persistence_policy ~= 'ONCE' then
            return validation_invalid(SCHEMA, 'persistence_policy', 'CHEST_MUST_BE_ONCE')
        end
    elseif interactable_type == 'SEARCH' then
        if result_type == 'NONE' then
            return validation_invalid(SCHEMA, 'result_type', 'SEARCH_RESULT_REQUIRED')
        end
        if result_type == 'REWARD' then
            err = validation_content_id(SCHEMA, 'result_ref_id', result_ref_id, 'reward_')
            if err ~= nil then
                return err
            end
        elseif result_type == 'DIALOGUE' then
            err = validation_content_id(SCHEMA, 'result_ref_id', result_ref_id, 'dialogue_')
            if err ~= nil then
                return err
            end
        elseif result_type == 'FLAG' then
            err = validation_content_id(SCHEMA, 'flag_id', flag_id, 'flag_')
            if err ~= nil then
                return err
            end
            if flag_value == nil then
                return validation_invalid(SCHEMA, 'flag_value', 'FLAG_VALUE_REQUIRED')
            end
        elseif result_type == 'ENCOUNTER' then
            err = validation_content_id(SCHEMA, 'result_ref_id', result_ref_id, 'encounter_')
            if err ~= nil then
                return err
            end
        end
        if persistence_policy ~= 'ONCE' then
            return validation_invalid(SCHEMA, 'persistence_policy', 'SEARCH_MUST_BE_ONCE')
        end
    elseif interactable_type == 'NPC' then
        err = validation_content_id(SCHEMA, 'action_ref_id', action_ref_id, 'dialogue_', true)
        if err ~= nil then
            return err
        end
    elseif interactable_type == 'ENCOUNTER' then
        err = validation_content_id(SCHEMA, 'action_ref_id', action_ref_id, 'encounter_')
        if err ~= nil then
            return err
        end
    end

    if flag_value ~= nil then
        local fv_type = type_value(flag_value)
        if fv_type ~= 'boolean' and fv_type ~= 'number' and fv_type ~= 'string' then
            return validation_invalid(SCHEMA, 'flag_value', 'FLAG_VALUE_TYPE_INVALID')
        end
        if fv_type == 'string' and #flag_value > 64 then
            return validation_invalid(SCHEMA, 'flag_value', 'FLAG_VALUE_TOO_LONG')
        end
        if fv_type == 'number' and flag_value ~= math.floor(flag_value) then
            return validation_invalid(SCHEMA, 'flag_value', 'FLAG_VALUE_NOT_INTEGER')
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        interactable_type = interactable_type,
        location_id = value.location_id,
        marker_id = value.marker_id,
        interaction_radius_cm = radius,
        action_ref_id = action_ref_id,
        persistence_policy = persistence_policy,
        prompt_key = value.prompt_key,
        priority = priority,
        result_type = result_type,
        result_ref_id = result_ref_id,
        flag_id = flag_id,
        flag_value = flag_value,
        initial_state = initial_state,
        deprecated = deprecated,
    })
end

return InteractableDefinition
