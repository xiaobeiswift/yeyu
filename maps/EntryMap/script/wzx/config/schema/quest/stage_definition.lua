local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.quest.validation'

local StageDefinition = {}
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

local SCHEMA = 'QuestStageDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    quest_id = true,
    objective_ids = true,
    completion_mode = true,
    completion_count = true,
    next_stage_id = true,
    checkpoint = true,
    journal_text_key = true,
    deprecated = true,
}
local COMPLETION_MODES = {
    ALL = true,
    ANY = true,
    COUNT = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function StageDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local completion_mode = raw_get(value, 'completion_mode')
    if completion_mode == nil then
        completion_mode = 'ALL'
    end
    local checkpoint = raw_get(value, 'checkpoint')
    if checkpoint == nil then
        checkpoint = false
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'stage_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_content_id(SCHEMA, 'quest_id', value.quest_id, 'quest_'),
        validation_dense_array(SCHEMA, 'objective_ids', value.objective_ids),
        validation_enum(SCHEMA, 'completion_mode', completion_mode, COMPLETION_MODES),
        validation_integer(SCHEMA, 'completion_count', value.completion_count, 1, 64, true),
        validation_content_id(SCHEMA, 'next_stage_id', value.next_stage_id, 'stage_', true),
        validation_boolean(SCHEMA, 'checkpoint', checkpoint),
        validation_non_empty_string(SCHEMA, 'journal_text_key', value.journal_text_key),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if #value.objective_ids < 1 or #value.objective_ids > 32 then
        return validation_invalid(SCHEMA, 'objective_ids', 'OBJECTIVE_COUNT_OUT_OF_RANGE', {
            minimum = 1,
            maximum = 32,
        })
    end
    if completion_mode == 'COUNT' then
        err = validation_integer(SCHEMA, 'completion_count', value.completion_count, 1, 64)
        if err ~= nil then
            return err
        end
        if value.completion_count > #value.objective_ids then
            return validation_invalid(SCHEMA, 'completion_count', 'COUNT_EXCEEDS_OBJECTIVES')
        end
    end

    local seen = {}
    local index
    for index = 1, #value.objective_ids do
        local objective_id = value.objective_ids[index]
        err = validation_content_id(SCHEMA, 'objective_ids', objective_id, 'objective_')
        if err ~= nil then
            return err
        end
        if seen[objective_id] then
            return validation_invalid(SCHEMA, 'objective_ids', 'DUPLICATE_OBJECTIVE_ID', {
                objective_id = objective_id,
                index = index,
            })
        end
        seen[objective_id] = true
    end

    if value.next_stage_id ~= nil and value.next_stage_id == value.id then
        return validation_invalid(SCHEMA, 'next_stage_id', 'SELF_LOOP_FORBIDDEN')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        quest_id = value.quest_id,
        objective_ids = copy_strings(value.objective_ids),
        completion_mode = completion_mode,
        completion_count = value.completion_count,
        next_stage_id = value.next_stage_id,
        checkpoint = checkpoint,
        journal_text_key = value.journal_text_key,
        deprecated = deprecated,
    })
end

return StageDefinition
