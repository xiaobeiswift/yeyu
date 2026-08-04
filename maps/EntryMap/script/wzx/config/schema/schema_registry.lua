local Result = require 'wzx.domain.common.result'
local ErrorCodes = require 'wzx.domain.common.error_codes'
local Ordered = require 'wzx.domain.common.ordered'
local RuntimeId = require 'wzx.domain.common.runtime_id'

local SchemaRegistry = {}
local bytewise_string_less = Ordered.bytewise_string_less
local invalid_argument_code = ErrorCodes.INVALID_ARGUMENT
local next_value = next
local pcall_value = pcall
local raw_get = rawget
local registry_duplicate_code = ErrorCodes.REGISTRY_DUPLICATE
local registry_entry_not_found_code = ErrorCodes.REGISTRY_ENTRY_NOT_FOUND
local registry_sealed_code = ErrorCodes.REGISTRY_SEALED
local result_err = Result.err
local result_ok = Result.ok
local result_validate = Result.validate
local schema_validation_failed_code = ErrorCodes.SCHEMA_VALIDATION_FAILED
local set_metatable = setmetatable
local table_sort = table.sort
local type_value = type
local validate_component = RuntimeId.validate_component
local Registry = {}
Registry.__index = Registry
Registry.__newindex = function()
    error('schema registry is read-only', 2)
end
Registry.__metatable = false
local STATES = set_metatable({}, { __mode = 'k' })

local function copy_value(value, seen)
    if type_value(value) ~= 'table' then
        return value
    end

    if seen[value] then
        return nil, 'cycle'
    end

    seen[value] = true
    local copy = {}
    local key
    local item
    key, item = next_value(value, nil)
    while key ~= nil do
        local copied_key, key_error = copy_value(key, seen)
        if key_error then
            seen[value] = nil
            return nil, key_error
        end

        local copied_item, item_error = copy_value(item, seen)
        if item_error then
            seen[value] = nil
            return nil, item_error
        end
        copy[copied_key] = copied_item
        key, item = next_value(value, key)
    end
    seen[value] = nil
    return copy
end

local function clone(value)
    local copy, copy_error = copy_value(value, {})
    if copy_error then
        return result_err(
            schema_validation_failed_code,
            'error.foundation.registry_entry_cycle',
            false
        )
    end
    return result_ok(copy)
end

local function validate_options(options)
    if type_value(options) ~= 'table' then
        return result_err(
            invalid_argument_code,
            'error.foundation.registry_options_invalid',
            false
        )
    end

    local name_result = validate_component(
        raw_get(options, 'registry_name'),
        'registry_name'
    )
    if not name_result.ok then
        return name_result
    end

    if type_value(raw_get(options, 'id_field')) ~= 'string'
        or raw_get(options, 'id_field') == ''
    then
        return result_err(
            invalid_argument_code,
            'error.foundation.registry_id_field_invalid',
            false
        )
    end

    if raw_get(options, 'normalize_entry') ~= nil
        and type_value(raw_get(options, 'normalize_entry')) ~= 'function'
    then
        return result_err(
            invalid_argument_code,
            'error.foundation.registry_normalizer_invalid',
            false
        )
    end

    if raw_get(options, 'validate_entry') ~= nil
        and type_value(raw_get(options, 'validate_entry')) ~= 'function'
    then
        return result_err(
            invalid_argument_code,
            'error.foundation.registry_validator_invalid',
            false
        )
    end

    if raw_get(options, 'validate_id') ~= nil
        and type_value(raw_get(options, 'validate_id')) ~= 'function'
    then
        return result_err(
            invalid_argument_code,
            'error.foundation.registry_id_validator_invalid',
            false
        )
    end

    return result_ok(true)
end

local function validate_result_contract(value, message_key)
    local checked = result_validate(value)
    if not checked.ok then
        return result_err(
            schema_validation_failed_code,
            message_key,
            false
        )
    end
    return value
end

local function call_result_contract(callback, argument, invalid_message_key, raised_message_key)
    local succeeded, value = pcall_value(callback, argument)
    if not succeeded then
        return result_err(
            schema_validation_failed_code,
            raised_message_key,
            false
        )
    end
    return validate_result_contract(value, invalid_message_key)
end

function SchemaRegistry.new(options)
    local options_result = validate_options(options)
    if not options_result.ok then
        return options_result
    end

    local registry = set_metatable({}, Registry)
    STATES[registry] = {
        registry_name = raw_get(options, 'registry_name'),
        id_field = raw_get(options, 'id_field'),
        normalize_entry = raw_get(options, 'normalize_entry'),
        validate_entry = raw_get(options, 'validate_entry'),
        validate_id = raw_get(options, 'validate_id'),
        entries = {},
        sealed = false,
    }
    return result_ok(registry)
end

function Registry:register(entry)
    local state = STATES[self]
    if state.sealed then
        return result_err(
            registry_sealed_code,
            'error.foundation.registry_sealed',
            false,
            { registry_name = state.registry_name }
        )
    end

    if type_value(entry) ~= 'table' then
        return result_err(
            schema_validation_failed_code,
            'error.foundation.registry_entry_invalid',
            false,
            { registry_name = state.registry_name }
        )
    end

    local normalized = entry
    if state.normalize_entry then
        local normalized_result = call_result_contract(
            state.normalize_entry,
            entry,
            'error.foundation.registry_normalizer_result_invalid',
            'error.foundation.registry_normalizer_failed'
        )
        if not normalized_result.ok then
            return normalized_result
        end
        normalized = normalized_result.value
    end

    if type_value(normalized) ~= 'table' then
        return result_err(
            schema_validation_failed_code,
            'error.foundation.registry_normalized_entry_invalid',
            false,
            { registry_name = state.registry_name }
        )
    end

    local entry_id = raw_get(normalized, state.id_field)
    if type_value(entry_id) ~= 'string' or entry_id == '' then
        return result_err(
            schema_validation_failed_code,
            'error.foundation.registry_entry_id_invalid',
            false,
            {
                registry_name = state.registry_name,
                id_field = state.id_field,
            }
        )
    end

    if state.validate_id then
        local id_result = call_result_contract(
            state.validate_id,
            entry_id,
            'error.foundation.registry_id_validator_result_invalid',
            'error.foundation.registry_id_validator_failed'
        )
        if not id_result.ok then
            return id_result
        end
    end

    if state.validate_entry then
        local entry_result = call_result_contract(
            state.validate_entry,
            normalized,
            'error.foundation.registry_validator_result_invalid',
            'error.foundation.registry_validator_failed'
        )
        if not entry_result.ok then
            return entry_result
        end
    end

    if state.entries[entry_id] ~= nil then
        return result_err(
            registry_duplicate_code,
            'error.foundation.registry_duplicate',
            false,
            {
                registry_name = state.registry_name,
                entry_id = entry_id,
            }
        )
    end

    local copied = clone(normalized)
    if not copied.ok then
        return copied
    end
    state.entries[entry_id] = copied.value
    return result_ok(entry_id)
end

function Registry:get(entry_id)
    local state = STATES[self]
    local entry = state.entries[entry_id]
    if entry == nil then
        return result_err(
            registry_entry_not_found_code,
            'error.foundation.registry_entry_not_found',
            false,
            {
                registry_name = state.registry_name,
                entry_id = entry_id,
            }
        )
    end
    return clone(entry)
end

function Registry:contains(entry_id)
    return STATES[self].entries[entry_id] ~= nil
end

function Registry:list()
    local state = STATES[self]
    local ids = {}
    local entry_id
    entry_id = next_value(state.entries, nil)
    while entry_id ~= nil do
        ids[#ids + 1] = entry_id
        entry_id = next_value(state.entries, entry_id)
    end
    table_sort(ids, bytewise_string_less)

    local entries = {}
    local index
    for index = 1, #ids do
        local copied = clone(state.entries[ids[index]])
        if not copied.ok then
            return copied
        end
        entries[index] = copied.value
    end
    return result_ok(entries)
end

function Registry:seal()
    STATES[self].sealed = true
    return result_ok(true)
end

function Registry:is_sealed()
    return STATES[self].sealed
end

return SchemaRegistry
