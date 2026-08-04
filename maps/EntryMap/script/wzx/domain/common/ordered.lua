local Result = require 'wzx.domain.common.result'

local Ordered = {}
local MAX_SAFE_INTEGER = 9007199254740991
local result_err = Result.err
local result_ok = Result.ok
local math_floor = math.floor
local raw_next = next
local string_byte = string.byte
local table_sort = table.sort

-- Lua 5.1 string relational operators may follow the process collation locale.
-- Canonical gameplay order is unsigned byte order instead.
local function bytewise_string_less(left, right)
    if type(left) ~= 'string' or type(right) ~= 'string' then
        return false
    end
    local shared_length = math.min(#left, #right)
    local index
    for index = 1, shared_length do
        local left_byte = string_byte(left, index)
        local right_byte = string_byte(right, index)
        if left_byte ~= right_byte then
            return left_byte < right_byte
        end
    end
    return #left < #right
end
Ordered.bytewise_string_less = bytewise_string_less

local function is_dense_array(value)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return false
    end

    local count = 0
    local maximum = 0
    local key
    for key in raw_next, value do
        if type(key) ~= 'number'
            or key ~= key
            or key == math.huge
            or key == -math.huge
            or key < 1
            or key > MAX_SAFE_INTEGER
            or key ~= math_floor(key)
        then
            return false
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
    end
    if count ~= maximum then
        return false
    end
    local index
    for index = 1, maximum do
        if rawget(value, index) == nil then
            return false
        end
    end
    return true
end
Ordered.is_dense_array = is_dense_array

local function copy_array(value)
    if not is_dense_array(value) then
        return result_err('INVALID_ARGUMENT', 'error.foundation.array_not_dense', false)
    end

    local copy = {}
    local length = 0
    local key
    for key in raw_next, value do
        if key > length then
            length = key
        end
    end
    local i
    for i = 1, length do
        copy[i] = rawget(value, i)
    end
    return result_ok(copy)
end
Ordered.copy_array = copy_array

function Ordered.sorted_string_keys(value)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return result_err('INVALID_ARGUMENT', 'error.foundation.map_expected', false)
    end

    local keys = {}
    local key
    for key in raw_next, value do
        if type(key) ~= 'string' then
            return result_err('INVALID_ARGUMENT', 'error.foundation.map_key_not_string', false)
        end
        keys[#keys + 1] = key
    end
    table_sort(keys, bytewise_string_less)
    return result_ok(keys)
end

function Ordered.sorted_copy(value, less)
    local copied = copy_array(value)
    if not copied.ok then
        return copied
    end
    if type(less) ~= 'function' then
        return result_err(
            'INVALID_ARGUMENT',
            'error.foundation.order_comparator_required',
            false
        )
    end
    table_sort(copied.value, less)
    return copied
end

return Ordered
