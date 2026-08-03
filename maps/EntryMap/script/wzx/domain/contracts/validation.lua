local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local Validation = {}

function Validation.invalid(contract_name, field, reason, details)
    details = details or {}
    details.contract = contract_name
    details.field = field
    details.reason = reason
    return Result.err(
        'CONTRACT_VALIDATION_FAILED',
        'error.foundation.contract_validation_failed',
        false,
        details
    )
end

function Validation.no_unknown_fields(contract_name, value, allowed)
    if type(value) ~= 'table' then
        return Validation.invalid(contract_name, '$', 'TABLE_REQUIRED')
    end
    local keys = Ordered.sorted_string_keys(value)
    if not keys.ok then
        return Validation.invalid(contract_name, '$', 'NON_STRING_FIELD_KEY')
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        if not allowed[key] then
            return Validation.invalid(contract_name, key, 'UNKNOWN_FIELD')
        end
    end
    return nil
end

function Validation.integer(contract_name, field, value, minimum, maximum, optional)
    if value == nil and optional then
        return nil
    end
    if not TableShape.is_integer(value, minimum, maximum) then
        return Validation.invalid(contract_name, field, 'INTEGER_OUT_OF_RANGE', {
            minimum = minimum,
            maximum = maximum,
        })
    end
    return nil
end

function Validation.boolean(contract_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if type(value) ~= 'boolean' then
        return Validation.invalid(contract_name, field, 'BOOLEAN_REQUIRED')
    end
    return nil
end

function Validation.enum(contract_name, field, value, allowed, optional)
    if value == nil and optional then
        return nil
    end
    if not allowed[value] then
        return Validation.invalid(contract_name, field, 'ENUM_VALUE_INVALID', {
            actual = value,
        })
    end
    return nil
end

function Validation.identifier(contract_name, field, value, prefix, optional)
    if value == nil and optional then
        return nil
    end
    local result
    if prefix ~= nil then
        result = RuntimeId.validate_content(value, prefix, field)
    else
        result = RuntimeId.validate_derived(value, field)
    end
    if not result.ok then
        return Validation.invalid(contract_name, field, 'IDENTIFIER_INVALID', {
            prefix = prefix,
        })
    end
    return nil
end

function Validation.source_reference(contract_name, field, value)
    local result = RuntimeId.validate_source_reference(value, field)
    if not result.ok then
        return Validation.invalid(contract_name, field, 'SOURCE_REFERENCE_INVALID')
    end
    return nil
end

function Validation.stable_order_key(contract_name, field, value)
    local result = RuntimeId.validate_stable_order_key(value, field)
    if not result.ok then
        return Validation.invalid(contract_name, field, 'STABLE_ORDER_KEY_INVALID')
    end
    return nil
end

function Validation.hash(contract_name, field, value, optional)
    if value == nil and optional then
        return nil
    end
    if type(value) ~= 'string' or #value ~= 64 or value:match('^[a-f0-9]+$') == nil then
        return Validation.invalid(contract_name, field, 'SHA256_HEX_REQUIRED')
    end
    return nil
end

function Validation.dense_array(contract_name, field, value, minimum, maximum)
    if not Ordered.is_dense_array(value) then
        return Validation.invalid(contract_name, field, 'DENSE_ARRAY_REQUIRED')
    end
    if minimum ~= nil and #value < minimum then
        return Validation.invalid(contract_name, field, 'ARRAY_TOO_SHORT', { minimum = minimum })
    end
    if maximum ~= nil and #value > maximum then
        return Validation.invalid(contract_name, field, 'ARRAY_TOO_LONG', { maximum = maximum })
    end
    return nil
end

function Validation.sorted_unique_strings(contract_name, field, value)
    local dense = Validation.dense_array(contract_name, field, value, 0)
    if dense ~= nil then
        return dense
    end
    local previous
    local index
    for index = 1, #value do
        local current = value[index]
        if type(current) ~= 'string' or current == '' then
            return Validation.invalid(contract_name, field, 'NON_EMPTY_STRING_ENTRY_REQUIRED', {
                index = index,
            })
        end
        if previous ~= nil and previous >= current then
            return Validation.invalid(contract_name, field, 'STRICT_ASCENDING_ORDER_REQUIRED', {
                index = index,
            })
        end
        previous = current
    end
    return nil
end

function Validation.serializable(contract_name, field, value, maximum_depth)
    local result = TableShape.validate_serializable(value, maximum_depth, '$.' .. field)
    if not result.ok then
        return Validation.invalid(contract_name, field, 'SERIALIZABLE_SHAPE_INVALID', {
            cause = result.error,
        })
    end
    return nil
end

function Validation.table_serializable(contract_name, field, value, maximum_depth)
    if type(value) ~= 'table' then
        return Validation.invalid(contract_name, field, 'TABLE_REQUIRED')
    end
    return Validation.serializable(contract_name, field, value, maximum_depth)
end

function Validation.flat_map(contract_name, field, value, value_kind)
    if type(value) ~= 'table' then
        return Validation.invalid(contract_name, field, 'MAP_REQUIRED')
    end
    local keys = Ordered.sorted_string_keys(value)
    if not keys.ok then
        return Validation.invalid(contract_name, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        local child = value[key]
        if key == '' then
            return Validation.invalid(contract_name, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
        end
        if value_kind == 'string' and (type(child) ~= 'string' or child == '') then
            return Validation.invalid(contract_name, field .. '.' .. key, 'NON_EMPTY_STRING_REQUIRED')
        elseif value_kind == 'integer' and not TableShape.is_integer(child) then
            return Validation.invalid(contract_name, field .. '.' .. key, 'INTEGER_REQUIRED')
        elseif value_kind == 'scalar'
            and type(child) ~= 'string'
            and type(child) ~= 'boolean'
            and not TableShape.is_integer(child)
        then
            return Validation.invalid(contract_name, field .. '.' .. key, 'SCALAR_REQUIRED')
        end
    end
    return nil
end

function Validation.hash_map(contract_name, field, value)
    if type(value) ~= 'table' then
        return Validation.invalid(contract_name, field, 'MAP_REQUIRED')
    end
    local keys = Ordered.sorted_string_keys(value)
    if not keys.ok then
        return Validation.invalid(contract_name, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        if key == '' then
            return Validation.invalid(contract_name, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
        end
        local err = Validation.hash(contract_name, field .. '.' .. key, value[key])
        if err ~= nil then
            return err
        end
    end
    return nil
end

function Validation.non_negative_integer_map(contract_name, field, value)
    local err = Validation.flat_map(contract_name, field, value, 'integer')
    if err ~= nil then
        return err
    end
    local keys = Ordered.sorted_string_keys(value).value
    local index
    for index = 1, #keys do
        local key = keys[index]
        if value[key] < 0 then
            return Validation.invalid(
                contract_name,
                field .. '.' .. key,
                'NON_NEGATIVE_INTEGER_REQUIRED'
            )
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

return Validation
