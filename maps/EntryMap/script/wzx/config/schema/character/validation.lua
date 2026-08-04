local ErrorCodes = require 'wzx.domain.common.error_codes'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local Validation = {}

function Validation.invalid(schema_name, field, reason, details)
    details = details or {}
    details.schema = schema_name
    details.field = field
    details.reason = reason
    return Result.err(
        ErrorCodes.SCHEMA_VALIDATION_FAILED,
        'error.character.schema_validation_failed',
        false,
        details
    )
end

function Validation.no_unknown_fields(schema_name, value, allowed_fields)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return Validation.invalid(schema_name, '$', 'TABLE_REQUIRED')
    end

    local keys = Ordered.sorted_string_keys(value)
    if not keys.ok then
        return Validation.invalid(schema_name, '$', 'STRING_FIELD_KEYS_REQUIRED')
    end

    local index
    for index = 1, #keys.value do
        local field = keys.value[index]
        if not allowed_fields[field] then
            return Validation.invalid(schema_name, field, 'UNKNOWN_FIELD')
        end
    end
    return nil
end

function Validation.integer(schema_name, field, value, minimum, maximum, optional)
    if value == nil and optional then
        return nil
    end
    if not TableShape.is_integer(value, minimum, maximum) then
        return Validation.invalid(schema_name, field, 'INTEGER_OUT_OF_RANGE', {
            minimum = minimum,
            maximum = maximum,
        })
    end
    return nil
end

function Validation.boolean(schema_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if type(value) ~= 'boolean' then
        return Validation.invalid(schema_name, field, 'BOOLEAN_REQUIRED')
    end
    return nil
end

function Validation.non_empty_string(schema_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if type(value) ~= 'string' or value == '' then
        return Validation.invalid(schema_name, field, 'NON_EMPTY_STRING_REQUIRED')
    end
    return nil
end

function Validation.enum(schema_name, field, value, allowed_values)
    if not allowed_values[value] then
        local details = {
            actual_type = type(value),
        }
        if type(value) == 'string'
            or type(value) == 'boolean'
            or TableShape.is_integer(value)
        then
            details.actual = value
        end
        return Validation.invalid(schema_name, field, 'ENUM_VALUE_INVALID', {
            actual = details.actual,
            actual_type = details.actual_type,
        })
    end
    return nil
end

function Validation.error_summary(err)
    local summary = {
        code = type(err) == 'table' and err.code or 'UNKNOWN',
        message_key = type(err) == 'table' and err.message_key or 'error.unknown',
        retryable = type(err) == 'table' and err.retryable == true,
    }
    if type(err) ~= 'table'
        or type(err.details) ~= 'table'
        or getmetatable(err.details) ~= nil
    then
        return summary
    end

    local details = {}
    local key
    local value
    for key, value in pairs(err.details) do
        if type(key) == 'string'
            and (type(value) == 'string'
                or type(value) == 'boolean'
                or TableShape.is_integer(value))
        then
            details[key] = value
        end
    end
    summary.details = details
    return summary
end

function Validation.content_id(schema_name, field, value, prefix, optional)
    if value == nil and optional then
        return nil
    end
    local checked = RuntimeId.validate_content(value, prefix, field)
    if not checked.ok then
        return Validation.invalid(schema_name, field, 'CONTENT_ID_INVALID', {
            prefix = prefix,
        })
    end
    return nil
end

function Validation.dense_array(schema_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if getmetatable(value) ~= nil or not Ordered.is_dense_array(value) then
        return Validation.invalid(schema_name, field, 'DENSE_ARRAY_REQUIRED')
    end
    return nil
end

function Validation.sorted_unique_strings(schema_name, field, value, optional)
    local dense = Validation.dense_array(schema_name, field, value, optional)
    if dense ~= nil or (value == nil and optional) then
        return dense
    end

    local previous
    local index
    for index = 1, #value do
        local current = value[index]
        if type(current) ~= 'string' or current == '' then
            return Validation.invalid(
                schema_name,
                field,
                'NON_EMPTY_STRING_ENTRY_REQUIRED',
                { index = index }
            )
        end
        if previous ~= nil and not Ordered.bytewise_string_less(previous, current) then
            return Validation.invalid(
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

function Validation.sorted_unique_content_ids(
    schema_name,
    field,
    value,
    prefix,
    optional
)
    local ordered = Validation.sorted_unique_strings(schema_name, field, value, optional)
    if ordered ~= nil or (value == nil and optional) then
        return ordered
    end

    local index
    for index = 1, #value do
        local checked = Validation.content_id(
            schema_name,
            field .. '[' .. tostring(index) .. ']',
            value[index],
            prefix
        )
        if checked ~= nil then
            return checked
        end
    end
    return nil
end

function Validation.exact_integer_map(
    schema_name,
    field,
    value,
    ordered_keys,
    minimum,
    maximum
)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return Validation.invalid(schema_name, field, 'MAP_REQUIRED')
    end

    local expected = {}
    local index
    for index = 1, #ordered_keys do
        expected[ordered_keys[index]] = true
    end

    local actual_keys = Ordered.sorted_string_keys(value)
    if not actual_keys.ok then
        return Validation.invalid(schema_name, field, 'STRING_MAP_KEYS_REQUIRED')
    end
    for index = 1, #actual_keys.value do
        local key = actual_keys.value[index]
        if not expected[key] then
            return Validation.invalid(
                schema_name,
                field .. '.' .. key,
                'UNKNOWN_MAP_KEY'
            )
        end
    end

    for index = 1, #ordered_keys do
        local key = ordered_keys[index]
        if rawget(value, key) == nil then
            return Validation.invalid(
                schema_name,
                field .. '.' .. key,
                'MAP_KEY_REQUIRED'
            )
        end
        local integer = Validation.integer(
            schema_name,
            field .. '.' .. key,
            value[key],
            minimum,
            maximum
        )
        if integer ~= nil then
            return integer
        end
    end
    return nil
end

function Validation.first(...)
    local count = select('#', ...)
    local index
    for index = 1, count do
        local found = select(index, ...)
        if found ~= nil then
            return found
        end
    end
    return nil
end

function Validation.bytewise_string_less(left, right)
    return Ordered.bytewise_string_less(left, right)
end

return Validation
