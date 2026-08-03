local Result = require 'wzx.domain.common.result'
local ErrorCodes = require 'wzx.domain.common.error_codes'
local RuntimeId = require 'wzx.domain.common.runtime_id'

local SchemaRegistry = {}
local Registry = {}
Registry.__index = Registry
Registry.__newindex = function()
    error('schema registry is read-only', 2)
end
Registry.__metatable = false
local STATES = setmetatable({}, { __mode = 'k' })

local function copy_value(value, seen)
    if type(value) ~= 'table' then
        return value
    end

    if seen[value] then
        return nil, 'cycle'
    end

    seen[value] = true
    local copy = {}
    local key
    local item
    for key, item in pairs(value) do
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
    end
    seen[value] = nil
    return copy
end

local function clone(value)
    local copy, copy_error = copy_value(value, {})
    if copy_error then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.registry_entry_cycle',
            false
        )
    end
    return Result.ok(copy)
end

local function validate_options(options)
    if type(options) ~= 'table' then
        return Result.err(
            ErrorCodes.INVALID_ARGUMENT,
            'error.foundation.registry_options_invalid',
            false
        )
    end

    local name_result = RuntimeId.validate_component(options.registry_name, 'registry_name')
    if not name_result.ok then
        return name_result
    end

    if type(options.id_field) ~= 'string' or options.id_field == '' then
        return Result.err(
            ErrorCodes.INVALID_ARGUMENT,
            'error.foundation.registry_id_field_invalid',
            false
        )
    end

    if options.normalize_entry ~= nil and type(options.normalize_entry) ~= 'function' then
        return Result.err(
            ErrorCodes.INVALID_ARGUMENT,
            'error.foundation.registry_normalizer_invalid',
            false
        )
    end

    if options.validate_entry ~= nil and type(options.validate_entry) ~= 'function' then
        return Result.err(
            ErrorCodes.INVALID_ARGUMENT,
            'error.foundation.registry_validator_invalid',
            false
        )
    end

    if options.validate_id ~= nil and type(options.validate_id) ~= 'function' then
        return Result.err(
            ErrorCodes.INVALID_ARGUMENT,
            'error.foundation.registry_id_validator_invalid',
            false
        )
    end

    return Result.ok(true)
end

local function validate_result_contract(value, message_key)
    local checked = Result.validate(value)
    if not checked.ok then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            message_key,
            false
        )
    end
    return value
end

local function call_result_contract(callback, argument, invalid_message_key, raised_message_key)
    local succeeded, value = pcall(callback, argument)
    if not succeeded then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
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

    local registry = setmetatable({}, Registry)
    STATES[registry] = {
        registry_name = options.registry_name,
        id_field = options.id_field,
        normalize_entry = options.normalize_entry,
        validate_entry = options.validate_entry,
        validate_id = options.validate_id,
        entries = {},
        sealed = false,
    }
    return Result.ok(registry)
end

function Registry:register(entry)
    local state = STATES[self]
    if state.sealed then
        return Result.err(
            ErrorCodes.REGISTRY_SEALED,
            'error.foundation.registry_sealed',
            false,
            { registry_name = state.registry_name }
        )
    end

    if type(entry) ~= 'table' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
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

    if type(normalized) ~= 'table' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.registry_normalized_entry_invalid',
            false,
            { registry_name = state.registry_name }
        )
    end

    local entry_id = normalized[state.id_field]
    if type(entry_id) ~= 'string' or entry_id == '' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
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
        return Result.err(
            ErrorCodes.REGISTRY_DUPLICATE,
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
    return Result.ok(entry_id)
end

function Registry:get(entry_id)
    local state = STATES[self]
    local entry = state.entries[entry_id]
    if entry == nil then
        return Result.err(
            ErrorCodes.REGISTRY_ENTRY_NOT_FOUND,
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
    for entry_id in pairs(state.entries) do
        ids[#ids + 1] = entry_id
    end
    table.sort(ids)

    local entries = {}
    local index
    for index = 1, #ids do
        local copied = clone(state.entries[ids[index]])
        if not copied.ok then
            return copied
        end
        entries[index] = copied.value
    end
    return Result.ok(entries)
end

function Registry:seal()
    STATES[self].sealed = true
    return Result.ok(true)
end

function Registry:is_sealed()
    return STATES[self].sealed
end

return SchemaRegistry
