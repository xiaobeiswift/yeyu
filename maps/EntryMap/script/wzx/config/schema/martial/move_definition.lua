local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.martial.validation'

local MoveDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string
local validation_sorted_unique_strings = Validation.sorted_unique_strings

local SCHEMA = 'MoveDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    source_martial_id = true,
    move_type = true,
    name_key = true,
    description_template_key = true,
    unlock_level = true,
    qi_cost = true,
    action_cooldown = true,
    initial_cooldown = true,
    target_rule_id = true,
    effect_bundle_id = true,
    trigger_type = true,
    trigger_priority = true,
    trigger_limit_per_action = true,
    once_per_combat = true,
    ai_tags = true,
    presentation_cue_id = true,
    deprecated = true,
}
local MOVE_TYPES = {
    BASIC = true,
    ACTIVE = true,
    PASSIVE = true,
    REACTION = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function MoveDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local move_type = raw_get(value, 'move_type')
    local action_cooldown = raw_get(value, 'action_cooldown')
    if action_cooldown == nil then
        action_cooldown = 0
    end
    local initial_cooldown = raw_get(value, 'initial_cooldown')
    if initial_cooldown == nil then
        initial_cooldown = 0
    end
    local qi_cost = raw_get(value, 'qi_cost')
    if qi_cost == nil then
        qi_cost = 0
    end
    local trigger_priority = raw_get(value, 'trigger_priority')
    if trigger_priority == nil then
        trigger_priority = 100
    end
    local trigger_limit = raw_get(value, 'trigger_limit_per_action')
    if trigger_limit == nil then
        trigger_limit = 1
    end
    local once_per_combat = raw_get(value, 'once_per_combat')
    if once_per_combat == nil then
        once_per_combat = false
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local ai_tags = raw_get(value, 'ai_tags')
    if ai_tags == nil then
        ai_tags = {}
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'move_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_content_id(
            SCHEMA,
            'source_martial_id',
            raw_get(value, 'source_martial_id'),
            'martial_'
        ),
        validation_enum(SCHEMA, 'move_type', move_type, MOVE_TYPES),
        validation_non_empty_string(SCHEMA, 'name_key', raw_get(value, 'name_key')),
        validation_non_empty_string(
            SCHEMA,
            'description_template_key',
            raw_get(value, 'description_template_key')
        ),
        validation_integer(SCHEMA, 'unlock_level', raw_get(value, 'unlock_level'), 1, 10),
        validation_integer(SCHEMA, 'qi_cost', qi_cost, 0, 2000),
        validation_integer(SCHEMA, 'action_cooldown', action_cooldown, 0, 99),
        validation_integer(SCHEMA, 'initial_cooldown', initial_cooldown, 0, 99),
        validation_content_id(
            SCHEMA,
            'target_rule_id',
            raw_get(value, 'target_rule_id'),
            'target_'
        ),
        validation_content_id(
            SCHEMA,
            'effect_bundle_id',
            raw_get(value, 'effect_bundle_id'),
            'effect_'
        ),
        validation_integer(SCHEMA, 'trigger_priority', trigger_priority, 0, 10000),
        validation_integer(SCHEMA, 'trigger_limit_per_action', trigger_limit, 1, 99),
        validation_boolean(SCHEMA, 'once_per_combat', once_per_combat),
        validation_dense_array(SCHEMA, 'ai_tags', ai_tags),
        validation_sorted_unique_strings(SCHEMA, 'ai_tags', ai_tags),
        validation_content_id(
            SCHEMA,
            'presentation_cue_id',
            raw_get(value, 'presentation_cue_id'),
            'cue_',
            true
        ),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end
    if initial_cooldown > action_cooldown then
        return validation_invalid(SCHEMA, 'initial_cooldown', 'INITIAL_COOLDOWN_EXCEEDS_ACTION')
    end

    local trigger_type = raw_get(value, 'trigger_type')
    if move_type == 'ACTIVE' or move_type == 'BASIC' then
        if trigger_type ~= nil then
            return validation_invalid(SCHEMA, 'trigger_type', 'ACTIVE_TRIGGER_MUST_BE_EMPTY')
        end
    else
        if type_value(trigger_type) ~= 'string' or trigger_type == '' then
            return validation_invalid(SCHEMA, 'trigger_type', 'PASSIVE_TRIGGER_REQUIRED')
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        source_martial_id = value.source_martial_id,
        move_type = move_type,
        name_key = value.name_key,
        description_template_key = value.description_template_key,
        unlock_level = value.unlock_level,
        qi_cost = qi_cost,
        action_cooldown = action_cooldown,
        initial_cooldown = initial_cooldown,
        target_rule_id = value.target_rule_id,
        effect_bundle_id = value.effect_bundle_id,
        trigger_type = trigger_type,
        trigger_priority = trigger_priority,
        trigger_limit_per_action = trigger_limit,
        once_per_combat = once_per_combat,
        ai_tags = copy_strings(ai_tags),
        presentation_cue_id = value.presentation_cue_id,
        deprecated = deprecated,
    })
end

return MoveDefinition
