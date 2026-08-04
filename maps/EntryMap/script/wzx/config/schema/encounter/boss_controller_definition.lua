local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.encounter.validation'

local BossControllerDefinition = {}
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

local SCHEMA = 'BossControllerDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    boss_spawn_id = true,
    phase_ids = true,
    phase_transition_policy = true,
    interrupt_profile_id = true,
    enrage_action_index = true,
    boss_bar_style_id = true,
    phase_event_budget = true,
    deprecated = true,
}
local TRANSITION_POLICIES = {
    ONE_WAY = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function BossControllerDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local phase_transition_policy = raw_get(value, 'phase_transition_policy')
    if phase_transition_policy == nil then
        phase_transition_policy = 'ONE_WAY'
    end
    local phase_event_budget = raw_get(value, 'phase_event_budget')
    if phase_event_budget == nil then
        phase_event_budget = 64
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local boss_bar_style_id = raw_get(value, 'boss_bar_style_id')
    if boss_bar_style_id == nil then
        boss_bar_style_id = 'bossbar_default'
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'bossctl_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_content_id(SCHEMA, 'boss_spawn_id', value.boss_spawn_id, 'spawn_'),
        validation_dense_array(SCHEMA, 'phase_ids', value.phase_ids),
        validation_enum(
            SCHEMA,
            'phase_transition_policy',
            phase_transition_policy,
            TRANSITION_POLICIES
        ),
        validation_content_id(
            SCHEMA,
            'interrupt_profile_id',
            value.interrupt_profile_id,
            'interrupt_',
            true
        ),
        validation_integer(SCHEMA, 'enrage_action_index', value.enrage_action_index, 1, 98, true),
        validation_non_empty_string(SCHEMA, 'boss_bar_style_id', boss_bar_style_id),
        validation_integer(SCHEMA, 'phase_event_budget', phase_event_budget, 1, 256),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if #value.phase_ids < 1 or #value.phase_ids > 16 then
        return validation_invalid(SCHEMA, 'phase_ids', 'PHASE_COUNT_OUT_OF_RANGE', {
            minimum = 1,
            maximum = 16,
        })
    end

    local seen = {}
    local index
    for index = 1, #value.phase_ids do
        local phase_id = value.phase_ids[index]
        err = validation_content_id(SCHEMA, 'phase_ids', phase_id, 'bossphase_')
        if err ~= nil then
            return err
        end
        if seen[phase_id] then
            return validation_invalid(SCHEMA, 'phase_ids', 'DUPLICATE_PHASE_ID', {
                phase_id = phase_id,
                index = index,
            })
        end
        seen[phase_id] = true
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        boss_spawn_id = value.boss_spawn_id,
        phase_ids = copy_strings(value.phase_ids),
        phase_transition_policy = phase_transition_policy,
        interrupt_profile_id = value.interrupt_profile_id,
        enrage_action_index = value.enrage_action_index,
        boss_bar_style_id = boss_bar_style_id,
        phase_event_budget = phase_event_budget,
        deprecated = deprecated,
    })
end

return BossControllerDefinition
