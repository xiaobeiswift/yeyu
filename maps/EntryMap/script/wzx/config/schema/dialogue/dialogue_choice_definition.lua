local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.dialogue.validation'

local DialogueChoiceDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'DialogueChoiceDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    dialogue_id = true,
    choice_set_id = true,
    entry_order = true,
    text_key = true,
    next_node_id = true,
    choice_memory_key = true,
    choice_memory_value = true,
    once_per_save = true,
    deprecated = true,
}

function DialogueChoiceDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local once_per_save = raw_get(value, 'once_per_save')
    if once_per_save == nil then
        once_per_save = false
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'choice_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_content_id(SCHEMA, 'dialogue_id', value.dialogue_id, 'dialogue_'),
        validation_content_id(SCHEMA, 'choice_set_id', value.choice_set_id, 'choiceset_'),
        validation_integer(SCHEMA, 'entry_order', value.entry_order, 1, 32),
        validation_non_empty_string(SCHEMA, 'text_key', value.text_key, 128),
        validation_content_id(SCHEMA, 'next_node_id', value.next_node_id, 'dnode_'),
        validation_content_id(
            SCHEMA,
            'choice_memory_key',
            value.choice_memory_key,
            'dmem_',
            true
        ),
        validation_boolean(SCHEMA, 'once_per_save', once_per_save),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if value.choice_memory_key ~= nil and value.choice_memory_value == nil then
        return validation_invalid(SCHEMA, 'choice_memory_value', 'MEMORY_VALUE_REQUIRED')
    end
    if value.choice_memory_value ~= nil then
        local mv = value.choice_memory_value
        local mv_type = type_value(mv)
        if mv_type ~= 'string' and mv_type ~= 'boolean' and mv_type ~= 'number' then
            return validation_invalid(SCHEMA, 'choice_memory_value', 'MEMORY_VALUE_TYPE_INVALID')
        end
        if mv_type == 'string' and #mv > 64 then
            return validation_invalid(SCHEMA, 'choice_memory_value', 'MEMORY_VALUE_TOO_LONG')
        end
        if mv_type == 'number' and mv ~= math.floor(mv) then
            return validation_invalid(SCHEMA, 'choice_memory_value', 'MEMORY_VALUE_NOT_INTEGER')
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        dialogue_id = value.dialogue_id,
        choice_set_id = value.choice_set_id,
        entry_order = value.entry_order,
        text_key = value.text_key,
        next_node_id = value.next_node_id,
        choice_memory_key = value.choice_memory_key,
        choice_memory_value = value.choice_memory_value,
        once_per_save = once_per_save,
        deprecated = deprecated,
    })
end

return DialogueChoiceDefinition
