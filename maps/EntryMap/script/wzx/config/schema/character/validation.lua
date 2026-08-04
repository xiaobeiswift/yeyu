local ErrorCodes = require 'wzx.domain.common.error_codes'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local Validation = {}
local bytewise_string_less_value = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local is_integer = TableShape.is_integer
local next_value = next
local raw_get = rawget
local result_err = Result.err
local schema_validation_failed_code = ErrorCodes.SCHEMA_VALIDATION_FAILED
local select_value = select
local sorted_string_keys = Ordered.sorted_string_keys
local tostring_value = tostring
local type_value = type
local validate_content = RuntimeId.validate_content

local function invalid(schema_name, field, reason, details)
    details = details or {}
    details.schema = schema_name
    details.field = field
    details.reason = reason
    return result_err(
        schema_validation_failed_code,
        'error.character.schema_validation_failed',
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

local function enum(schema_name, field, value, allowed_values)
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
        return invalid(schema_name, field, 'ENUM_VALUE_INVALID', {
            actual = details.actual,
            actual_type = details.actual_type,
        })
    end
    return nil
end
Validation.enum = enum

local function error_summary(err)
    local err_is_table = type_value(err) == 'table'
    local summary = {
        code = err_is_table and raw_get(err, 'code') or 'UNKNOWN',
        message_key = err_is_table
            and raw_get(err, 'message_key')
            or 'error.unknown',
        retryable = err_is_table and raw_get(err, 'retryable') == true,
    }
    local source_details = err_is_table and raw_get(err, 'details') or nil
    if type_value(source_details) ~= 'table'
        or get_metatable(source_details) ~= nil
    then
        return summary
    end

    local details = {}
    local key
    local value
    key, value = next_value(source_details, nil)
    while key ~= nil do
        if type_value(key) == 'string'
            and (type_value(value) == 'string'
                or type_value(value) == 'boolean'
                or is_integer(value))
        then
            details[key] = value
        end
        key, value = next_value(source_details, key)
    end
    summary.details = details
    return summary
end
Validation.error_summary = error_summary

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

local function sorted_unique_strings(schema_name, field, value, optional)
    local dense = dense_array(schema_name, field, value, optional)
    if dense ~= nil or (value == nil and optional) then
        return dense
    end

    local previous
    local index
    for index = 1, #value do
        local current = raw_get(value, index)
        if type_value(current) ~= 'string' or current == '' then
            return invalid(
                schema_name,
                field,
                'NON_EMPTY_STRING_ENTRY_REQUIRED',
                { index = index }
            )
        end
        if previous ~= nil
            and not bytewise_string_less_value(previous, current)
        then
            return invalid(
                schema_name,
                field,
                'STRICT_ASCENDING_ORDER_REQUIRED',
                { index = index }
            )
        end
        previous = current
    end
    return nil
end
Validation.sorted_unique_strings = sorted_unique_strings

local function sorted_unique_content_ids(
    schema_name,
    field,
    value,
    prefix,
    optional
)
    local ordered = sorted_unique_strings(schema_name, field, value, optional)
    if ordered ~= nil or (value == nil and optional) then
        return ordered
    end

    local index
    for index = 1, #value do
        local checked = content_id(
            schema_name,
            field .. '[' .. tostring_value(index) .. ']',
            raw_get(value, index),
            prefix
        )
        if checked ~= nil then
            return checked
        end
    end
    return nil
end
Validation.sorted_unique_content_ids = sorted_unique_content_ids

local function exact_integer_map(
    schema_name,
    field,
    value,
    ordered_keys,
    minimum,
    maximum
)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return invalid(schema_name, field, 'MAP_REQUIRED')
    end

    local expected = {}
    local index
    for index = 1, #ordered_keys do
        expected[raw_get(ordered_keys, index)] = true
    end

    local actual_keys = sorted_string_keys(value)
    if not actual_keys.ok then
        return invalid(schema_name, field, 'STRING_MAP_KEYS_REQUIRED')
    end
    for index = 1, #actual_keys.value do
        local key = actual_keys.value[index]
        if not expected[key] then
            return invalid(
                schema_name,
                field .. '.' .. key,
                'UNKNOWN_MAP_KEY'
            )
        end
    end

    for index = 1, #ordered_keys do
        local key = raw_get(ordered_keys, index)
        if raw_get(value, key) == nil then
            return invalid(
                schema_name,
                field .. '.' .. key,
                'MAP_KEY_REQUIRED'
            )
        end
        local integer_result = integer(
            schema_name,
            field .. '.' .. key,
            raw_get(value, key),
            minimum,
            maximum
        )
        if integer_result ~= nil then
            return integer_result
        end
    end
    return nil
end
Validation.exact_integer_map = exact_integer_map

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

local function bytewise_string_less(left, right)
    return bytewise_string_less_value(left, right)
end
Validation.bytewise_string_less = bytewise_string_less

return Validation
