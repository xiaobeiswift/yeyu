local Result = require "wzx.domain.common.result"
local Sha256 = require "wzx.domain.common.sha256"

local SerializableSnapshot = {}

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_TABLE_DEPTH = 32
local MAX_U32 = 4294967295
local FINGERPRINT_MAGIC = "WZX-FAKE-REQUEST-V1\0"

local function invalid(path, reason, details)
    details = details or {}
    details.path = path
    details.reason = reason
    return Result.err(
        "FAKE_SNAPSHOT_INVALID",
        "error.fake.snapshot_invalid",
        false,
        details
    )
end

local function is_finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function is_safe_integer(value)
    return is_finite_number(value)
        and value == math.floor(value)
        and value >= -MAX_SAFE_INTEGER
        and value <= MAX_SAFE_INTEGER
end

local function classify_table(value, path)
    local key
    local key_type
    local numeric_count = 0
    local maximum_index = 0
    local has_string_key = false
    local has_numeric_key = false

    for key in pairs(value) do
        key_type = type(key)
        if key_type == "string" then
            if key == "" then
                return nil, invalid(path, "NON_EMPTY_STRING_MAP_KEY_REQUIRED")
            end
            has_string_key = true
        elseif key_type == "number"
            and is_safe_integer(key)
            and key >= 1
        then
            has_numeric_key = true
            numeric_count = numeric_count + 1
            if key > maximum_index then
                maximum_index = key
            end
        else
            return nil, invalid(path, "STRING_MAP_OR_ARRAY_KEY_REQUIRED", {
                actual_key_type = key_type,
            })
        end

        if has_string_key and has_numeric_key then
            return nil, invalid(path, "MIXED_TABLE_KEYS_FORBIDDEN")
        end
    end

    if has_numeric_key then
        if numeric_count ~= maximum_index then
            return nil, invalid(path, "DENSE_ARRAY_REQUIRED", {
                count = numeric_count,
                maximum_index = maximum_index,
            })
        end
        return "ARRAY"
    end

    return "MAP"
end

local function sorted_string_keys(value)
    local keys = {}
    local key
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function copy_value(value, path, depth, active)
    local value_type = type(value)
    local kind
    local kind_error
    local target
    local index
    local keys
    local key
    local child
    local child_copy
    local child_error

    if value_type == "string" or value_type == "boolean" then
        return value
    end
    if value_type == "number" then
        if not is_finite_number(value) then
            return nil, invalid(path, "FINITE_NUMBER_REQUIRED")
        end
        return value
    end
    if value_type ~= "table" then
        return nil, invalid(path, "SERIALIZABLE_VALUE_REQUIRED", {
            actual_type = value_type,
        })
    end
    if depth > MAX_TABLE_DEPTH then
        return nil, invalid(path, "MAXIMUM_TABLE_DEPTH_EXCEEDED", {
            maximum_table_depth = MAX_TABLE_DEPTH,
        })
    end
    if active[value] then
        return nil, invalid(path, "TABLE_CYCLE_DETECTED")
    end

    kind, kind_error = classify_table(value, path)
    if not kind then
        return nil, kind_error
    end

    active[value] = true
    target = {}
    if kind == "ARRAY" then
        for index = 1, #value do
            child_copy, child_error = copy_value(
                value[index],
                path .. "[" .. tostring(index) .. "]",
                depth + 1,
                active
            )
            if child_error then
                active[value] = nil
                return nil, child_error
            end
            target[index] = child_copy
        end
    else
        keys = sorted_string_keys(value)
        for index = 1, #keys do
            key = keys[index]
            child = value[key]
            child_copy, child_error = copy_value(
                child,
                path .. "." .. key,
                depth + 1,
                active
            )
            if child_error then
                active[value] = nil
                return nil, child_error
            end
            target[key] = child_copy
        end
    end
    active[value] = nil
    return target
end

local function u32be(value)
    if not is_safe_integer(value) or value < 0 or value > MAX_U32 then
        return nil
    end
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
    )
end

local function append_length_prefixed(chunks, value, path)
    local encoded_length = u32be(#value)
    if encoded_length == nil then
        return invalid(path, "BYTE_LENGTH_EXCEEDED")
    end
    chunks[#chunks + 1] = encoded_length
    chunks[#chunks + 1] = value
    return nil
end

local function encode_value(value, path, depth, active, chunks)
    local value_type = type(value)
    local encoded
    local kind
    local kind_error
    local count_bytes
    local index
    local keys
    local key
    local found

    if value_type == "string" then
        chunks[#chunks + 1] = "S"
        return append_length_prefixed(chunks, value, path)
    end
    if value_type == "boolean" then
        chunks[#chunks + 1] = value and "T" or "F"
        return nil
    end
    if value_type == "number" then
        if not is_safe_integer(value) then
            return invalid(path, "SAFE_INTEGER_REQUIRED_FOR_FINGERPRINT")
        end
        if value == 0 then
            encoded = "0"
        else
            encoded = string.format("%.0f", value)
        end
        chunks[#chunks + 1] = "I"
        return append_length_prefixed(chunks, encoded, path)
    end
    if value_type ~= "table" then
        return invalid(path, "SERIALIZABLE_VALUE_REQUIRED", {
            actual_type = value_type,
        })
    end
    if depth > MAX_TABLE_DEPTH then
        return invalid(path, "MAXIMUM_TABLE_DEPTH_EXCEEDED", {
            maximum_table_depth = MAX_TABLE_DEPTH,
        })
    end
    if active[value] then
        return invalid(path, "TABLE_CYCLE_DETECTED")
    end

    kind, kind_error = classify_table(value, path)
    if not kind then
        return kind_error
    end
    active[value] = true

    if kind == "ARRAY" then
        chunks[#chunks + 1] = "A"
        count_bytes = u32be(#value)
        if count_bytes == nil then
            active[value] = nil
            return invalid(path, "ARRAY_LENGTH_EXCEEDED")
        end
        chunks[#chunks + 1] = count_bytes
        for index = 1, #value do
            found = encode_value(
                value[index],
                path .. "[" .. tostring(index) .. "]",
                depth + 1,
                active,
                chunks
            )
            if found then
                active[value] = nil
                return found
            end
        end
    else
        keys = sorted_string_keys(value)
        chunks[#chunks + 1] = "M"
        count_bytes = u32be(#keys)
        if count_bytes == nil then
            active[value] = nil
            return invalid(path, "MAP_LENGTH_EXCEEDED")
        end
        chunks[#chunks + 1] = count_bytes
        for index = 1, #keys do
            key = keys[index]
            found = append_length_prefixed(chunks, key, path .. ".<key>")
            if found then
                active[value] = nil
                return found
            end
            found = encode_value(
                value[key],
                path .. "." .. key,
                depth + 1,
                active,
                chunks
            )
            if found then
                active[value] = nil
                return found
            end
        end
    end

    active[value] = nil
    return nil
end

function SerializableSnapshot.deep_copy(value, root_path)
    local copied
    local found

    copied, found = copy_value(value, root_path or "$", 1, {})
    if found then
        return found
    end
    return Result.ok(copied)
end

function SerializableSnapshot.fingerprint_request(operation_name, request)
    local chunks = { FINGERPRINT_MAGIC }
    local business_fields = {}
    local key
    local operation_error
    local encode_error
    local digest
    local digest_error

    if type(operation_name) ~= "string" or operation_name == "" then
        return invalid("$operation", "NON_EMPTY_OPERATION_REQUIRED")
    end
    if type(request) ~= "table" then
        return invalid("$request", "TABLE_REQUIRED")
    end

    operation_error = append_length_prefixed(chunks, operation_name, "$operation")
    if operation_error then
        return operation_error
    end

    for key in pairs(request) do
        if key ~= "context" then
            business_fields[key] = request[key]
        end
    end

    encode_error = encode_value(
        business_fields,
        "$request.business",
        1,
        {},
        chunks
    )
    if encode_error then
        return encode_error
    end

    digest, digest_error = Sha256.hex(table.concat(chunks))
    if digest == nil then
        return Result.err("FAKE_FINGERPRINT_FAILED", "error.fake.fingerprint_failed", false, {
            reason = digest_error,
        })
    end
    return Result.ok(digest)
end

SerializableSnapshot.MAX_TABLE_DEPTH = MAX_TABLE_DEPTH

return SerializableSnapshot
