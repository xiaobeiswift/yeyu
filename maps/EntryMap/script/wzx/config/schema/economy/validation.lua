-- Economy schema validation helpers. Mirrors reward/character validation style.

local ErrorCodes = require 'wzx.domain.common.error_codes'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local Validation = {}
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local is_integer = TableShape.is_integer
local next_value = next
local raw_get = rawget
local result_err = Result.err
local select_value = select
local sorted_string_keys = Ordered.sorted_string_keys
local type_value = type
local validate_content = RuntimeId.validate_content

local function invalid(schema_name, field, reason, details)
    details = details or {}
    details.schema = schema_name
    details.field = field
    details.reason = reason
    return result_err(
        ErrorCodes.SCHEMA_VALIDATION_FAILED,
        'error.economy.schema_validation_failed',
        false,
        details
    )
end
Validation.invalid = invalid

local function no_unknown_fields(schema_name, value, allowed_fields)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return invalid(schema_name, '$', 'TABLE_REQUIRED')
    end

    local keys = sorted_string_keys(value)
    if not keys.ok then
        return invalid(schema_name, '$', 'STRING_FIELD_KEYS_REQUIRED')
    end

    local index
    for index = 1, #keys.value do
        local field = keys.value[index]
        if not allowed_fields[field] then
            return invalid(schema_name, field, 'UNKNOWN_FIELD')
        end
    end
    return nil
end
Validation.no_unknown_fields = no_unknown_fields

local function integer(schema_name, field, value, minimum, maximum, optional)
    if value == nil and optional then
        return nil
    end
    if not is_integer(value, minimum, maximum) then
        return invalid(schema_name, field, 'INTEGER_OUT_OF_RANGE', {
            minimum = minimum,
            maximum = maximum,
        })
    end
    return nil
end
Validation.integer = integer

local function boolean_value(schema_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if type_value(value) ~= 'boolean' then
        return invalid(schema_name, field, 'BOOLEAN_REQUIRED')
    end
    return nil
end
Validation.boolean = boolean_value

local function non_empty_string(schema_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if type_value(value) ~= 'string' or value == '' then
        return invalid(schema_name, field, 'NON_EMPTY_STRING_REQUIRED')
    end
    return nil
end
Validation.non_empty_string = non_empty_string

local function enum(schema_name, field, value, allowed_values, optional)
    if value == nil and optional then
        return nil
    end
    if not raw_get(allowed_values, value) then
        local details = {
            actual_type = type_value(value),
        }
        if type_value(value) == 'string'
            or type_value(value) == 'boolean'
            or is_integer(value)
        then
            details.actual = value
        end
        return invalid(schema_name, field, 'ENUM_VALUE_INVALID', details)
    end
    return nil
end
Validation.enum = enum

local function content_id(schema_name, field, value, prefix, optional)
    if value == nil and optional then
        return nil
    end
    local checked = validate_content(value, prefix, field)
    if not checked.ok then
        return invalid(schema_name, field, 'CONTENT_ID_INVALID', {
            prefix = prefix,
        })
    end
    return nil
end
Validation.content_id = content_id

local function dense_array(schema_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if get_metatable(value) ~= nil or not is_dense_array(value) then
        return invalid(schema_name, field, 'DENSE_ARRAY_REQUIRED')
    end
    return nil
end
Validation.dense_array = dense_array

local function first(...)
    local count = select_value('#', ...)
    local index
    for index = 1, count do
        local found = select_value(index, ...)
        if found ~= nil then
            return found
        end
    end
    return nil
end
Validation.first = first

return Validation
