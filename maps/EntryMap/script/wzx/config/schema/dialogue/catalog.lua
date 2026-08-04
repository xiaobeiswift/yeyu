local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local DialogueErrorCodes = require 'wzx.domain.dialogue.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.dialogue.validation'
local DialogueDefinition = require 'wzx.config.schema.dialogue.dialogue_definition'
local DialogueNodeDefinition = require 'wzx.config.schema.dialogue.dialogue_node_definition'
local DialogueChoiceDefinition = require 'wzx.config.schema.dialogue.dialogue_choice_definition'

local Catalog = {}
local error_value = error
local get_metatable = getmetatable
local result_err = Result.err
local result_ok = Result.ok
local schema_registry_new = SchemaRegistry.new
local set_metatable = setmetatable
local type_value = type
local validate_content_id = RuntimeId.validate_content
local validation_dense_array = Validation.dense_array
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local CatalogView = {}
CatalogView.__index = CatalogView
CatalogView.__newindex = function()
    error_value('dialogue catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'DialogueCatalog'
local COLLECTION_ORDER = {
    'choice_definitions',
    'node_definitions',
    'dialogue_definitions',
}
local COLLECTION_FIELDS = {
    choice_definitions = true,
    node_definitions = true,
    dialogue_definitions = true,
}
local COLLECTION_SPECS = {
    choice_definitions = {
        registry_name = 'choice_definitions',
        normalize_entry = DialogueChoiceDefinition.validate,
    },
    node_definitions = {
        registry_name = 'node_definitions',
        normalize_entry = DialogueNodeDefinition.validate,
    },
    dialogue_definitions = {
        registry_name = 'dialogue_definitions',
        normalize_entry = DialogueDefinition.validate,
    },
}

local function invalid(field, reason, details)
    return validation_invalid(SCHEMA, field, reason, details)
end

local function catalog_error(code, message_key, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(code, message_key, false, details)
end

local function validate_source(source)
    if type_value(source) ~= 'table' or get_metatable(source) ~= nil then
        return invalid('$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, source, COLLECTION_FIELDS)
    if err ~= nil then
        return err
    end
    local index
    for index = 1, #COLLECTION_ORDER do
        local collection_name = COLLECTION_ORDER[index]
        local collection = source[collection_name]
        if collection == nil then
            source[collection_name] = {}
            collection = source[collection_name]
        end
        err = validation_dense_array(SCHEMA, collection_name, collection)
        if err ~= nil then
            return err
        end
    end
    return result_ok(true)
end

local function build_registry(collection_name, entries)
    local spec = COLLECTION_SPECS[collection_name]
    local created = schema_registry_new({
        registry_name = spec.registry_name,
        id_field = 'id',
        normalize_entry = spec.normalize_entry,
    })
    if not created.ok then
        return created
    end
    local registry = created.value
    local index
    for index = 1, #entries do
        local registered = registry:register(entries[index])
        if not registered.ok then
            return registered
        end
    end
    local sealed = registry:seal()
    if not sealed.ok then
        return sealed
    end
    return result_ok(registry)
end

local function validate_cross_references(registries)
    local choices = registries.choice_definitions:list()
    if not choices.ok then
        return choices
    end
    local nodes = registries.node_definitions:list()
    if not nodes.ok then
        return nodes
    end
    local dialogues = registries.dialogue_definitions:list()
    if not dialogues.ok then
        return dialogues
    end

    local choices_by_set = {}
    local index
    for index = 1, #choices.value do
        local choice = choices.value[index]
        local dialogue = registries.dialogue_definitions:get(choice.dialogue_id)
        if not dialogue.ok then
            return invalid('dialogue_id', 'REFERENCE_NOT_FOUND', {
                choice_id = choice.id,
                reference_id = choice.dialogue_id,
            })
        end
        local next_node = registries.node_definitions:get(choice.next_node_id)
        if not next_node.ok then
            return invalid('next_node_id', 'REFERENCE_NOT_FOUND', {
                choice_id = choice.id,
                reference_id = choice.next_node_id,
            })
        end
        if next_node.value.dialogue_id ~= choice.dialogue_id then
            return invalid('next_node_id', 'CHOICE_NEXT_DIALOGUE_MISMATCH', {
                choice_id = choice.id,
                next_node_id = choice.next_node_id,
            })
        end
        local set_key = choice.dialogue_id .. '|' .. choice.choice_set_id
        local bucket = choices_by_set[set_key]
        if bucket == nil then
            bucket = {}
            choices_by_set[set_key] = bucket
        end
        if bucket[choice.entry_order] ~= nil then
            return invalid('entry_order', 'DUPLICATE_CHOICE_ORDER', {
                choice_set_id = choice.choice_set_id,
                entry_order = choice.entry_order,
            })
        end
        bucket[choice.entry_order] = choice.id
    end

    for index = 1, #nodes.value do
        local node = nodes.value[index]
        local dialogue = registries.dialogue_definitions:get(node.dialogue_id)
        if not dialogue.ok then
            return invalid('dialogue_id', 'REFERENCE_NOT_FOUND', {
                node_id = node.id,
                reference_id = node.dialogue_id,
            })
        end
        if node.rules_version ~= dialogue.value.rules_version then
            return invalid('rules_version', 'NODE_RULES_MISMATCH', {
                node_id = node.id,
                dialogue_id = node.dialogue_id,
            })
        end
        if node.next_node_id ~= nil then
            local next_node = registries.node_definitions:get(node.next_node_id)
            if not next_node.ok then
                return invalid('next_node_id', 'REFERENCE_NOT_FOUND', {
                    node_id = node.id,
                    reference_id = node.next_node_id,
                })
            end
            if next_node.value.dialogue_id ~= node.dialogue_id then
                return invalid('next_node_id', 'NEXT_NODE_DIALOGUE_MISMATCH', {
                    node_id = node.id,
                    next_node_id = node.next_node_id,
                })
            end
        end
        if node.node_type == 'CHOICE' then
            local set_key = node.dialogue_id .. '|' .. node.choice_set_id
            local bucket = choices_by_set[set_key]
            if bucket == nil then
                return invalid('choice_set_id', 'CHOICE_SET_EMPTY', {
                    node_id = node.id,
                    choice_set_id = node.choice_set_id,
                })
            end
        end
    end

    for index = 1, #dialogues.value do
        local dialogue = dialogues.value[index]
        local node_index
        for node_index = 1, #dialogue.node_ids do
            local node_id = dialogue.node_ids[node_index]
            local node = registries.node_definitions:get(node_id)
            if not node.ok then
                return invalid('node_ids', 'REFERENCE_NOT_FOUND', {
                    dialogue_id = dialogue.id,
                    reference_id = node_id,
                })
            end
            if node.value.dialogue_id ~= dialogue.id then
                return invalid('dialogue_id', 'NODE_DIALOGUE_MISMATCH', {
                    dialogue_id = dialogue.id,
                    node_id = node_id,
                })
            end
        end
        local start = registries.node_definitions:get(dialogue.start_node_id)
        if not start.ok then
            return invalid('start_node_id', 'REFERENCE_NOT_FOUND', {
                dialogue_id = dialogue.id,
                reference_id = dialogue.start_node_id,
            })
        end
        if start.value.node_type == 'END' then
            return invalid('start_node_id', 'START_NODE_CANNOT_BE_END', {
                dialogue_id = dialogue.id,
            })
        end
    end

    return result_ok(true)
end

function CatalogView:require_dialogue(dialogue_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_ARGUMENT_INVALID,
            'error.dialogue.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(dialogue_id, 'dialogue_', 'dialogue_id')
    if not checked.ok then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_ARGUMENT_INVALID,
            'error.dialogue.dialogue_id_invalid',
            'DIALOGUE_ID_INVALID',
            { field = 'dialogue_id' }
        )
    end
    local found = state.registries.dialogue_definitions:get(dialogue_id)
    if not found.ok then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_UNKNOWN,
            'error.dialogue.definition_unknown',
            'DIALOGUE_UNKNOWN',
            { dialogue_id = dialogue_id }
        )
    end
    if found.value.deprecated then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_DEPRECATED,
            'error.dialogue.deprecated',
            'DIALOGUE_DEPRECATED',
            { dialogue_id = dialogue_id }
        )
    end
    return found
end

function CatalogView:require_node(node_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_ARGUMENT_INVALID,
            'error.dialogue.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.node_definitions:get(node_id)
    if not found.ok then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_NODE_UNKNOWN,
            'error.dialogue.node_unknown',
            'NODE_UNKNOWN',
            { node_id = node_id }
        )
    end
    return found
end

function CatalogView:require_choice(choice_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_ARGUMENT_INVALID,
            'error.dialogue.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.choice_definitions:get(choice_id)
    if not found.ok then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_CHOICE_UNKNOWN,
            'error.dialogue.choice_unknown',
            'CHOICE_UNKNOWN',
            { choice_id = choice_id }
        )
    end
    return found
end

function CatalogView:list_choices_for_set(dialogue_id, choice_set_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            DialogueErrorCodes.DIALOGUE_ARGUMENT_INVALID,
            'error.dialogue.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local listed = state.registries.choice_definitions:list()
    if not listed.ok then
        return listed
    end
    local matched = {}
    local index
    for index = 1, #listed.value do
        local choice = listed.value[index]
        if choice.dialogue_id == dialogue_id and choice.choice_set_id == choice_set_id then
            matched[#matched + 1] = choice
        end
    end
    table.sort(matched, function(left, right)
        if left.entry_order ~= right.entry_order then
            return left.entry_order < right.entry_order
        end
        return Ordered.bytewise_string_less(left.id, right.id)
    end)
    return result_ok(matched)
end

function Catalog.seal(source)
    local validated = validate_source(source)
    if not validated.ok then
        return validated
    end

    local registries = {}
    local index
    for index = 1, #COLLECTION_ORDER do
        local collection_name = COLLECTION_ORDER[index]
        local built = build_registry(collection_name, source[collection_name])
        if not built.ok then
            return built
        end
        registries[collection_name] = built.value
    end

    local cross = validate_cross_references(registries)
    if not cross.ok then
        return cross
    end

    local view = set_metatable({}, CatalogView)
    STATES[view] = {
        registries = registries,
    }
    return result_ok(view)
end

return Catalog
