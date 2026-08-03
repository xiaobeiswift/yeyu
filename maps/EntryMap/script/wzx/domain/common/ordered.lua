local Result = require 'wzx.domain.common.result'

local Ordered = {}
local MAX_SAFE_INTEGER = 9007199254740991

function Ordered.is_dense_array(value)
    if type(value) ~= 'table' then
        return false
    end

    local count = 0
    local maximum = 0
    local key
    for key in pairs(value) do
        if type(key) ~= 'number'
            or key ~= key
            or key == math.huge
            or key == -math.huge
            or key < 1
            or key > MAX_SAFE_INTEGER
            or key ~= math.floor(key)
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

function Ordered.copy_array(value)
    if not Ordered.is_dense_array(value) then
        return Result.err('INVALID_ARGUMENT', 'error.foundation.array_not_dense', false)
    end

    local copy = {}
    local length = 0
    local key
    for key in pairs(value) do
        if key > length then
            length = key
        end
    end
    local i
    for i = 1, length do
        copy[i] = value[i]
    end
    return Result.ok(copy)
end

function Ordered.sorted_string_keys(value)
    if type(value) ~= 'table' then
        return Result.err('INVALID_ARGUMENT', 'error.foundation.map_expected', false)
    end

    local keys = {}
    local key
    for key in pairs(value) do
        if type(key) ~= 'string' then
            return Result.err('INVALID_ARGUMENT', 'error.foundation.map_key_not_string', false)
        end
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return Result.ok(keys)
end

function Ordered.sorted_copy(value, less)
    local copied = Ordered.copy_array(value)
    if not copied.ok then
        return copied
    end
    table.sort(copied.value, less)
    return copied
end

return Ordered
