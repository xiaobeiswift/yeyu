local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'

local TableShape = {}
local is_dense_array = Ordered.is_dense_array
local result_err = Result.err
local result_ok = Result.ok
local sorted_string_keys = Ordered.sorted_string_keys
local math_floor = math.floor
local raw_next = next

local MAX_SAFE_INTEGER = 9007199254740991

local function invalid(path, reason, details)
    details = details or {}
    details.path = path
    details.reason = reason
    return result_err('TABLE_SHAPE_INVALID', 'error.foundation.table_shape_invalid', false, details)
end

local function is_integer(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math_floor(value)
        and value >= -MAX_SAFE_INTEGER
        and value <= MAX_SAFE_INTEGER
end

local function inspect(value, path, table_depth, maximum_table_depth, active)
    local value_type = type(value)
    if value_type == 'string' or value_type == 'boolean' then
        return nil
    end
    if value_type == 'number' then
        if not is_integer(value) then
            return invalid(path, 'INTEGER_REQUIRED')
        end
        return nil
    end
    if value_type ~= 'table' then
        return invalid(path, 'SERIALIZABLE_VALUE_REQUIRED', {
            actual_type = value_type,
        })
    end
    if getmetatable(value) ~= nil then
        return invalid(path, 'PLAIN_TABLE_REQUIRED')
    end
    if table_depth > maximum_table_depth then
        return invalid(path, 'MAXIMUM_TABLE_DEPTH_EXCEEDED', {
            maximum_table_depth = maximum_table_depth,
        })
    end
    if active[value] then
        return invalid(path, 'TABLE_CYCLE_DETECTED')
    end

    active[value] = true
    local is_array = is_dense_array(value)
    local key
    local child_error
    if is_array then
        local index
        for index = 1, #value do
            child_error = inspect(
                value[index],
                path .. '[' .. tostring(index) .. ']',
                table_depth + 1,
                maximum_table_depth,
                active
            )
            if child_error ~= nil then
                active[value] = nil
                return child_error
            end
        end
    else
        for key in raw_next, value do
            if type(key) ~= 'string' or key == '' then
                active[value] = nil
                return invalid(path, 'NON_EMPTY_STRING_MAP_KEY_REQUIRED')
            end
        end
        local keys_result = sorted_string_keys(value)
        if not keys_result.ok then
            active[value] = nil
            return keys_result
        end
        local index
        for index = 1, #keys_result.value do
            key = keys_result.value[index]
            child_error = inspect(
                rawget(value, key),
                path .. '.' .. key,
                table_depth + 1,
                maximum_table_depth,
                active
            )
            if child_error ~= nil then
                active[value] = nil
                return child_error
            end
        end
    end
    active[value] = nil
    return nil
end

local function copy(value, copies)
    if type(value) ~= 'table' then
        return value
    end
    if copies[value] ~= nil then
        return copies[value]
    end
    local target = {}
    copies[value] = target
    local key
    local child
    for key, child in raw_next, value do
        target[key] = copy(child, copies)
    end
    return target
end

function TableShape.is_integer(value, minimum, maximum)
    if not is_integer(value) then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

function TableShape.validate_serializable(value, maximum_table_depth, root_path)
    if type(maximum_table_depth) ~= 'number'
        or maximum_table_depth ~= math_floor(maximum_table_depth)
        or maximum_table_depth < 1
    then
        return result_err('INVALID_ARGUMENT', 'error.foundation.maximum_depth_invalid', false)
    end
    local found = inspect(value, root_path or '$', 1, maximum_table_depth, {})
    if found ~= nil then
        return found
    end
    return result_ok(value)
end

function TableShape.deep_copy_serializable(value, maximum_table_depth, root_path)
    local validated = TableShape.validate_serializable(value, maximum_table_depth, root_path)
    if not validated.ok then
        return validated
    end
    return result_ok(copy(value, {}))
end

TableShape.MAX_SAFE_INTEGER = MAX_SAFE_INTEGER

return TableShape
