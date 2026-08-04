local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local Validation = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_dense_array = Ordered.is_dense_array
local is_integer = TableShape.is_integer
local raw_get = rawget
local result_err = Result.err
local select_value = select
local sorted_string_keys = Ordered.sorted_string_keys
local string_match = string.match
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived
local validate_serializable = TableShape.validate_serializable
local validate_source_reference = RuntimeId.validate_source_reference
local validate_stable_order_key = RuntimeId.validate_stable_order_key

local function invalid(contract_name, field, reason, details)
    details = details or {}
    details.contract = contract_name
    details.field = field
    details.reason = reason
    return result_err(
        'CONTRACT_VALIDATION_FAILED',
        'error.foundation.contract_validation_failed',
        false,
        details
    )
end
Validation.invalid = invalid

local function no_unknown_fields(contract_name, value, allowed)
    if type_value(value) ~= 'table' then
        return invalid(contract_name, '$', 'TABLE_REQUIRED')
    end
    local keys = sorted_string_keys(value)
    if not keys.ok then
        return invalid(contract_name, '$', 'NON_STRING_FIELD_KEY')
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        if not raw_get(allowed, key) then
            return invalid(contract_name, key, 'UNKNOWN_FIELD')
        end
    end
    return nil
end
Validation.no_unknown_fields = no_unknown_fields

local function integer(contract_name, field, value, minimum, maximum, optional)
    if value == nil and optional then
        return nil
    end
    if not is_integer(value, minimum, maximum) then
        return invalid(contract_name, field, 'INTEGER_OUT_OF_RANGE', {
            minimum = minimum,
            maximum = maximum,
        })
    end
    return nil
end
Validation.integer = integer

local function boolean_value(contract_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if type_value(value) ~= 'boolean' then
        return invalid(contract_name, field, 'BOOLEAN_REQUIRED')
    end
    return nil
end
Validation.boolean = boolean_value

local function enum(contract_name, field, value, allowed, optional)
    if value == nil and optional then
        return nil
    end
    if not raw_get(allowed, value) then
        return invalid(contract_name, field, 'ENUM_VALUE_INVALID', {
            actual = value,
        })
    end
    return nil
end
Validation.enum = enum

local function identifier(contract_name, field, value, prefix, optional)
    if value == nil and optional then
        return nil
    end
    local result
    if prefix ~= nil then
        result = validate_content(value, prefix, field)
    else
        result = validate_derived(value, field)
    end
    if not result.ok then
        return invalid(contract_name, field, 'IDENTIFIER_INVALID', {
            prefix = prefix,
        })
    end
    return nil
end
Validation.identifier = identifier

local function source_reference(contract_name, field, value)
    local result = validate_source_reference(value, field)
    if not result.ok then
        return invalid(contract_name, field, 'SOURCE_REFERENCE_INVALID')
    end
    return nil
end
Validation.source_reference = source_reference

local function stable_order_key(contract_name, field, value)
    local result = validate_stable_order_key(value, field)
    if not result.ok then
        return invalid(contract_name, field, 'STABLE_ORDER_KEY_INVALID')
    end
    return nil
end
Validation.stable_order_key = stable_order_key

local function hash_value(contract_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if type_value(value) ~= 'string'
        or #value ~= 64
        or string_match(value, '^[a-f0-9]+$') == nil
    then
        return invalid(contract_name, field, 'SHA256_HEX_REQUIRED')
    end
    return nil
end
Validation.hash = hash_value

local function dense_array(contract_name, field, value, minimum, maximum)
    if not is_dense_array(value) then
        return invalid(contract_name, field, 'DENSE_ARRAY_REQUIRED')
    end
    if minimum ~= nil and #value < minimum then
        return invalid(contract_name, field, 'ARRAY_TOO_SHORT', {
            minimum = minimum,
        })
    end
    if maximum ~= nil and #value > maximum then
        return invalid(contract_name, field, 'ARRAY_TOO_LONG', {
            maximum = maximum,
        })
    end
    return nil
end
Validation.dense_array = dense_array

local function sorted_unique_strings(contract_name, field, value)
    local dense = dense_array(contract_name, field, value, 0)
    if dense ~= nil then
        return dense
    end
    local previous
    local index
    for index = 1, #value do
        local current = raw_get(value, index)
        if type_value(current) ~= 'string' or current == '' then
            return invalid(contract_name, field, 'NON_EMPTY_STRING_ENTRY_REQUIRED', {
                index = index,
            })
        end
        if previous ~= nil and not bytewise_string_less(previous, current) then
            return invalid(contract_name, field, 'STRICT_ASCENDING_ORDER_REQUIRED', {
                index = index,
            })
        end
        previous = current
    end
    return nil
end
Validation.sorted_unique_strings = sorted_unique_strings

local function serializable(contract_name, field, value, maximum_depth)
    local result = validate_serializable(value, maximum_depth, '$.' .. field)
    if not result.ok then
        return invalid(contract_name, field, 'SERIALIZABLE_SHAPE_INVALID', {
            cause = result.error,
        })
    end
    return nil
end
Validation.serializable = serializable

local function table_serializable(contract_name, field, value, maximum_depth)
    if type_value(value) ~= 'table' then
        return invalid(contract_name, field, 'TABLE_REQUIRED')
    end
    return serializable(contract_name, field, value, maximum_depth)
end
Validation.table_serializable = table_serializable

local function flat_map(contract_name, field, value, value_kind)
    if type_value(value) ~= 'table' then
        return invalid(contract_name, field, 'MAP_REQUIRED')
    end
    local keys = sorted_string_keys(value)
    if not keys.ok then
        return invalid(contract_name, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        local child = raw_get(value, key)
        if key == '' then
            return invalid(contract_name, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
        end
        if value_kind == 'string'
            and (type_value(child) ~= 'string' or child == '')
        then
            return invalid(
                contract_name,
                field .. '.' .. key,
                'NON_EMPTY_STRING_REQUIRED'
            )
        elseif value_kind == 'integer' and not is_integer(child) then
            return invalid(contract_name, field .. '.' .. key, 'INTEGER_REQUIRED')
        elseif value_kind == 'scalar'
            and type_value(child) ~= 'string'
            and type_value(child) ~= 'boolean'
            and not is_integer(child)
        then
            return invalid(contract_name, field .. '.' .. key, 'SCALAR_REQUIRED')
        end
    end
    return nil
end
Validation.flat_map = flat_map

local function hash_map(contract_name, field, value)
    if type_value(value) ~= 'table' then
        return invalid(contract_name, field, 'MAP_REQUIRED')
    end
    local keys = sorted_string_keys(value)
    if not keys.ok then
        return invalid(contract_name, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        if key == '' then
            return invalid(contract_name, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
        end
        local err = hash_value(
            contract_name,
            field .. '.' .. key,
            raw_get(value, key)
        )
        if err ~= nil then
            return err
        end
    end
    return nil
end
Validation.hash_map = hash_map

local function non_negative_integer_map(contract_name, field, value)
    local err = flat_map(contract_name, field, value, 'integer')
    if err ~= nil then
        return err
    end
    local keys = sorted_string_keys(value).value
    local index
    for index = 1, #keys do
        local key = raw_get(keys, index)
        if raw_get(value, key) < 0 then
            return invalid(
                contract_name,
                field .. '.' .. key,
                'NON_NEGATIVE_INTEGER_REQUIRED'
            )
        end
    end
    return nil
end
Validation.non_negative_integer_map = non_negative_integer_map

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
