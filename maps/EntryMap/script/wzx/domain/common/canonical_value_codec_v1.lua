local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local DecimalInteger = require 'wzx.domain.common.decimal_integer'

local Codec = {}

Codec.TYPE_STRING = 'STRING'
Codec.TYPE_INTEGER = 'INTEGER'
Codec.TYPE_BOOLEAN = 'BOOLEAN'

local MAGIC = 'WZX-RECEIPT-V1\0'
local MAX_U32 = 4294967295
local MAX_SAFE_INTEGER = 9007199254740991
local TAGS = {
    STRING = 'S',
    INTEGER = 'I',
    BOOLEAN = 'B',
}

local function u32be(value)
    if type(value) ~= 'number' or value < 0 or value > MAX_U32 or value ~= math.floor(value) then
        return nil
    end
    local b1 = math.floor(value / 16777216) % 256
    local b2 = math.floor(value / 65536) % 256
    local b3 = math.floor(value / 256) % 256
    local b4 = value % 256
    return string.char(b1, b2, b3, b4)
end

local function is_ascii_name(value, max_bytes)
    return type(value) == 'string'
        and #value >= 1
        and #value <= max_bytes
        and value:match('^[a-z][a-z0-9_]*$') ~= nil
end

local function is_valid_utf8(value)
    local index = 1
    local length = #value
    while index <= length do
        local first = value:byte(index)
        if first <= 127 then
            index = index + 1
        elseif first >= 194 and first <= 223 then
            local second = value:byte(index + 1)
            if second == nil or second < 128 or second > 191 then
                return false
            end
            index = index + 2
        elseif first >= 224 and first <= 239 then
            local second = value:byte(index + 1)
            local third = value:byte(index + 2)
            if second == nil or third == nil
                or third < 128 or third > 191
                or (first == 224 and (second < 160 or second > 191))
                or (first == 237 and (second < 128 or second > 159))
                or (first ~= 224 and first ~= 237 and (second < 128 or second > 191))
            then
                return false
            end
            index = index + 3
        elseif first >= 240 and first <= 244 then
            local second = value:byte(index + 1)
            local third = value:byte(index + 2)
            local fourth = value:byte(index + 3)
            if second == nil or third == nil or fourth == nil
                or third < 128 or third > 191
                or fourth < 128 or fourth > 191
                or (first == 240 and (second < 144 or second > 191))
                or (first == 244 and (second < 128 or second > 143))
                or (first ~= 240 and first ~= 244 and (second < 128 or second > 191))
            then
                return false
            end
            index = index + 4
        else
            return false
        end
    end
    return true
end

local function encode_integer(value)
    if type(value) ~= 'number'
        or value ~= math.floor(value)
        or value < -MAX_SAFE_INTEGER
        or value > MAX_SAFE_INTEGER
    then
        return nil
    end
    return DecimalInteger.encode(value)
end

local function encode_value(value_type, value)
    if value_type == Codec.TYPE_STRING then
        if type(value) ~= 'string' or not is_valid_utf8(value) then
            return nil
        end
        return value
    end
    if value_type == Codec.TYPE_INTEGER then
        return encode_integer(value)
    end
    if value_type == Codec.TYPE_BOOLEAN then
        if type(value) ~= 'boolean' then
            return nil
        end
        return value and '1' or '0'
    end
    return nil
end

function Codec.encode(namespace, field_specs, values)
    if not is_ascii_name(namespace, 48) then
        return Result.err('CANONICAL_SCHEMA_INVALID', 'error.foundation.canonical_namespace_invalid', false)
    end
    if not Ordered.is_dense_array(field_specs) or type(values) ~= 'table' then
        return Result.err('CANONICAL_SCHEMA_INVALID', 'error.foundation.canonical_fields_invalid', false)
    end

    local namespace_length = u32be(#namespace)
    local field_count = u32be(#field_specs)
    if namespace_length == nil or field_count == nil then
        return Result.err('CANONICAL_SCHEMA_INVALID', 'error.foundation.canonical_length_overflow', false)
    end

    local chunks = { MAGIC, namespace_length, namespace, field_count }
    local known_fields = {}
    local i
    for i = 1, #field_specs do
        local spec = field_specs[i]
        if type(spec) ~= 'table'
            or not is_ascii_name(spec.name, 64)
            or TAGS[spec.type] == nil
            or known_fields[spec.name]
        then
            return Result.err('CANONICAL_SCHEMA_INVALID', 'error.foundation.canonical_field_spec_invalid', false, {
                field_index = i,
            })
        end
        known_fields[spec.name] = true

        local value = values[spec.name]
        if value == nil then
            return Result.err('CANONICAL_VALUE_INVALID', 'error.foundation.canonical_field_missing', false, {
                field = spec.name,
            })
        end
        local encoded_value = encode_value(spec.type, value)
        if encoded_value == nil then
            return Result.err('CANONICAL_VALUE_INVALID', 'error.foundation.canonical_field_value_invalid', false, {
                field = spec.name,
                expected_type = spec.type,
            })
        end

        local name_length = u32be(#spec.name)
        local value_length = u32be(#encoded_value)
        if name_length == nil or value_length == nil then
            return Result.err('CANONICAL_VALUE_INVALID', 'error.foundation.canonical_length_overflow', false, {
                field = spec.name,
            })
        end

        chunks[#chunks + 1] = name_length
        chunks[#chunks + 1] = spec.name
        chunks[#chunks + 1] = TAGS[spec.type]
        chunks[#chunks + 1] = value_length
        chunks[#chunks + 1] = encoded_value
    end

    local keys_result = Ordered.sorted_string_keys(values)
    if not keys_result.ok then
        return keys_result
    end
    for i = 1, #keys_result.value do
        local key = keys_result.value[i]
        if not known_fields[key] then
            return Result.err('CANONICAL_VALUE_INVALID', 'error.foundation.canonical_unknown_field', false, {
                field = key,
            })
        end
    end

    return Result.ok(table.concat(chunks))
end

return Codec
