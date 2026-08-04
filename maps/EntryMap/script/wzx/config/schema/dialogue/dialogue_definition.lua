local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.dialogue.validation'

local DialogueDefinition = {}
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

local SCHEMA = 'DialogueDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    graph_version = true,
    rules_version = true,
    start_node_id = true,
    node_ids = true,
    interrupt_policy = true,
    save_policy = true,
    completion_key = true,
    default_npc_id = true,
    deprecated = true,
}
local INTERRUPT_POLICIES = {
    ALLOW_AT_SAFE_NODE = true,
    DENY = true,
}
local SAVE_POLICIES = {
    CHECKPOINT_ONLY = true,
    NO_RESUME = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function DialogueDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local interrupt_policy = raw_get(value, 'interrupt_policy')
    if interrupt_policy == nil then
        interrupt_policy = 'ALLOW_AT_SAFE_NODE'
    end
    local save_policy = raw_get(value, 'save_policy')
    if save_policy == nil then
        save_policy = 'NO_RESUME'
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'dialogue_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'graph_version', value.graph_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_content_id(SCHEMA, 'start_node_id', value.start_node_id, 'dnode_'),
        validation_dense_array(SCHEMA, 'node_ids', value.node_ids),
        validation_enum(SCHEMA, 'interrupt_policy', interrupt_policy, INTERRUPT_POLICIES),
        validation_enum(SCHEMA, 'save_policy', save_policy, SAVE_POLICIES),
        validation_content_id(SCHEMA, 'completion_key', value.completion_key, 'dcomp_', true),
        validation_content_id(SCHEMA, 'default_npc_id', value.default_npc_id, 'npc_', true),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if #value.node_ids < 1 or #value.node_ids > 256 then
        return validation_invalid(SCHEMA, 'node_ids', 'NODE_COUNT_OUT_OF_RANGE', {
            count = #value.node_ids,
        })
    end

    local index
    local seen = {}
    local start_found = false
    for index = 1, #value.node_ids do
        local node_id = value.node_ids[index]
        err = validation_content_id(SCHEMA, 'node_ids', node_id, 'dnode_')
        if err ~= nil then
            return err
        end
        if seen[node_id] then
            return validation_invalid(SCHEMA, 'node_ids', 'DUPLICATE_NODE_ID', {
                node_id = node_id,
            })
        end
        seen[node_id] = true
        if node_id == value.start_node_id then
            start_found = true
        end
    end
    if not start_found then
        return validation_invalid(SCHEMA, 'start_node_id', 'START_NODE_NOT_IN_GRAPH', {
            start_node_id = value.start_node_id,
        })
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        graph_version = value.graph_version,
        rules_version = value.rules_version,
        start_node_id = value.start_node_id,
        node_ids = copy_strings(value.node_ids),
        interrupt_policy = interrupt_policy,
        save_policy = save_policy,
        completion_key = value.completion_key,
        default_npc_id = value.default_npc_id,
        deprecated = deprecated,
    })
end

return DialogueDefinition
