local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.dialogue.validation'

local DialogueNodeDefinition = {}
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

local SCHEMA = 'DialogueNodeDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    dialogue_id = true,
    node_type = true,
    next_node_id = true,
    choice_set_id = true,
    speaker_id = true,
    text_key = true,
    expression_id = true,
    end_reason = true,
    checkpoint_policy = true,
    skippable = true,
    loggable = true,
    memory_key = true,
    memory_value = true,
    deprecated = true,
}
local NODE_TYPES = {
    LINE = true,
    NARRATION = true,
    CHOICE = true,
    END = true,
}
local CHECKPOINT_POLICIES = {
    NONE = true,
    SAVE_BEFORE = true,
    SAVE_AFTER = true,
}
local END_REASONS = {
    COMPLETED = true,
    BRANCH_END = true,
    CANCELLED = true,
}

function DialogueNodeDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local checkpoint_policy = raw_get(value, 'checkpoint_policy')
    if checkpoint_policy == nil then
        checkpoint_policy = 'NONE'
    end
    local skippable = raw_get(value, 'skippable')
    if skippable == nil then
        skippable = true
    end
    local loggable = raw_get(value, 'loggable')
    if loggable == nil then
        loggable = true
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'dnode_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_content_id(SCHEMA, 'dialogue_id', value.dialogue_id, 'dialogue_'),
        validation_enum(SCHEMA, 'node_type', value.node_type, NODE_TYPES),
        validation_content_id(SCHEMA, 'next_node_id', value.next_node_id, 'dnode_', true),
        validation_content_id(SCHEMA, 'choice_set_id', value.choice_set_id, 'choiceset_', true),
        validation_content_id(SCHEMA, 'speaker_id', value.speaker_id, 'npc_', true),
        validation_non_empty_string(SCHEMA, 'text_key', value.text_key, 128),
        validation_content_id(SCHEMA, 'expression_id', value.expression_id, 'expression_', true),
        validation_enum(SCHEMA, 'checkpoint_policy', checkpoint_policy, CHECKPOINT_POLICIES),
        validation_boolean(SCHEMA, 'skippable', skippable),
        validation_boolean(SCHEMA, 'loggable', loggable),
        validation_content_id(SCHEMA, 'memory_key', value.memory_key, 'dmem_', true),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    local end_reason = raw_get(value, 'end_reason')
    if end_reason ~= nil then
        err = validation_enum(SCHEMA, 'end_reason', end_reason, END_REASONS)
        if err ~= nil then
            return err
        end
    end

    local node_type = value.node_type
    if node_type == 'LINE' or node_type == 'NARRATION' then
        if value.next_node_id == nil then
            return validation_invalid(SCHEMA, 'next_node_id', 'NEXT_NODE_REQUIRED')
        end
        if value.choice_set_id ~= nil then
            return validation_invalid(SCHEMA, 'choice_set_id', 'CHOICE_SET_NOT_ALLOWED')
        end
        if end_reason ~= nil then
            return validation_invalid(SCHEMA, 'end_reason', 'END_REASON_NOT_ALLOWED')
        end
    elseif node_type == 'CHOICE' then
        if value.choice_set_id == nil then
            return validation_invalid(SCHEMA, 'choice_set_id', 'CHOICE_SET_REQUIRED')
        end
        if value.next_node_id ~= nil then
            return validation_invalid(SCHEMA, 'next_node_id', 'NEXT_NODE_NOT_ALLOWED')
        end
        if end_reason ~= nil then
            return validation_invalid(SCHEMA, 'end_reason', 'END_REASON_NOT_ALLOWED')
        end
    elseif node_type == 'END' then
        if value.next_node_id ~= nil then
            return validation_invalid(SCHEMA, 'next_node_id', 'NEXT_NODE_NOT_ALLOWED')
        end
        if value.choice_set_id ~= nil then
            return validation_invalid(SCHEMA, 'choice_set_id', 'CHOICE_SET_NOT_ALLOWED')
        end
        if end_reason == nil then
            end_reason = 'COMPLETED'
        end
    end

    if value.memory_key ~= nil and value.memory_value == nil then
        return validation_invalid(SCHEMA, 'memory_value', 'MEMORY_VALUE_REQUIRED')
    end
    if value.memory_value ~= nil then
        local mv = value.memory_value
        local mv_type = type_value(mv)
        if mv_type ~= 'string' and mv_type ~= 'boolean' and mv_type ~= 'number' then
            return validation_invalid(SCHEMA, 'memory_value', 'MEMORY_VALUE_TYPE_INVALID')
        end
        if mv_type == 'string' and #mv > 64 then
            return validation_invalid(SCHEMA, 'memory_value', 'MEMORY_VALUE_TOO_LONG')
        end
        if mv_type == 'number' and mv ~= math.floor(mv) then
            return validation_invalid(SCHEMA, 'memory_value', 'MEMORY_VALUE_NOT_INTEGER')
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        dialogue_id = value.dialogue_id,
        node_type = node_type,
        next_node_id = value.next_node_id,
        choice_set_id = value.choice_set_id,
        speaker_id = value.speaker_id,
        text_key = value.text_key,
        expression_id = value.expression_id,
        end_reason = end_reason,
        checkpoint_policy = checkpoint_policy,
        skippable = skippable,
        loggable = loggable,
        memory_key = value.memory_key,
        memory_value = value.memory_value,
        deprecated = deprecated,
    })
end

return DialogueNodeDefinition
