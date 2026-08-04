local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local Ordered = require 'wzx.domain.common.ordered'
local Sha256 = require 'wzx.domain.common.sha256'

local SaveEnvelope = {}
local is_dense_array = Ordered.is_dense_array
local raw_get = rawget
local sorted_string_keys = Ordered.sorted_string_keys
local type_value = type
local tostring_value = tostring
local sha256_hex = Sha256.hex

local ALLOWED_FIELDS = {
    schema_version = true,
    revision = true,
    checkpoint_id = true,
    content_version = true,
    owner_fingerprint = true,
    payload_checksum = true,
    written_at = true,
    payload = true,
}

local function invalid(field, reason, details)
    details = details or {}
    details.field = field
    details.reason = reason
    return Result.err('SAVE_ENVELOPE_INVALID', 'error.save.envelope_invalid', false, details)
end

local function non_empty_bounded_string(value, maximum_bytes)
    return type(value) == 'string' and #value >= 1 and #value <= maximum_bytes
end

function SaveEnvelope.validate(envelope)
    if type(envelope) ~= 'table' or getmetatable(envelope) ~= nil then
        return invalid('envelope', 'TABLE_REQUIRED')
    end
    local keys = Ordered.sorted_string_keys(envelope)
    if not keys.ok then
        return invalid('envelope', 'NON_STRING_FIELD_KEY')
    end
    local field
    local index
    for index = 1, #keys.value do
        field = keys.value[index]
        if not ALLOWED_FIELDS[field] then
            return invalid(field, 'UNKNOWN_FIELD')
        end
    end
    if not TableShape.is_integer(envelope.schema_version, 1) then
        return invalid('schema_version', 'POSITIVE_INTEGER_REQUIRED')
    end
    if not TableShape.is_integer(envelope.revision, 0) then
        return invalid('revision', 'NON_NEGATIVE_INTEGER_REQUIRED')
    end
    local checkpoint = RuntimeId.validate_derived(envelope.checkpoint_id, 'checkpoint_id')
    if not checkpoint.ok then
        return invalid('checkpoint_id', 'IDENTIFIER_INVALID')
    end
    if not non_empty_bounded_string(envelope.content_version, 64) then
        return invalid('content_version', 'BOUNDED_STRING_REQUIRED')
    end
    local fingerprint_digest = type(envelope.owner_fingerprint) == 'string'
        and envelope.owner_fingerprint:match('^owner_v1_([a-f0-9]+)$')
        or nil
    if fingerprint_digest == nil or #fingerprint_digest ~= 64 then
        return invalid('owner_fingerprint', 'OWNER_FINGERPRINT_V1_REQUIRED')
    end
    if type(envelope.payload_checksum) ~= 'string'
        or envelope.payload_checksum:match('^[a-f0-9]+$') == nil
        or #envelope.payload_checksum ~= 64
    then
        return invalid('payload_checksum', 'SHA256_HEX_REQUIRED')
    end
    if envelope.written_at ~= nil and not TableShape.is_integer(envelope.written_at, 0) then
        return invalid('written_at', 'NON_NEGATIVE_INTEGER_REQUIRED')
    end
    if type(envelope.payload) ~= 'table' then
        return invalid('payload', 'TABLE_REQUIRED')
    end
    local payload = TableShape.validate_serializable(envelope.payload, 3, '$.payload')
    if not payload.ok then
        return invalid('payload', 'PAYLOAD_INVALID', { cause = payload.error })
    end
    return Result.ok(envelope)
end

function SaveEnvelope.copy(envelope)
    local validated = SaveEnvelope.validate(envelope)
    if not validated.ok then
        return validated
    end
    return TableShape.deep_copy_serializable(envelope, 4, '$')
end

local function append_canonical(parts, value, depth)
    local value_type = type_value(value)
    if value_type == 'string' then
        parts[#parts + 1] = 'S'
        parts[#parts + 1] = tostring_value(#value)
        parts[#parts + 1] = ':'
        parts[#parts + 1] = value
        return nil
    end
    if value_type == 'boolean' then
        parts[#parts + 1] = value and 'B1' or 'B0'
        return nil
    end
    if value_type == 'number' then
        if not TableShape.is_integer(value) then
            return invalid('payload', 'INTEGER_REQUIRED')
        end
        parts[#parts + 1] = 'I'
        parts[#parts + 1] = tostring_value(value)
        parts[#parts + 1] = ';'
        return nil
    end
    if value_type ~= 'table' or getmetatable(value) ~= nil then
        return invalid('payload', 'SERIALIZABLE_VALUE_REQUIRED')
    end
    if depth > 3 then
        return invalid('payload', 'MAXIMUM_TABLE_DEPTH_EXCEEDED')
    end
    if is_dense_array(value) then
        parts[#parts + 1] = 'A'
        parts[#parts + 1] = tostring_value(#value)
        parts[#parts + 1] = '['
        local index
        for index = 1, #value do
            local err = append_canonical(parts, raw_get(value, index), depth + 1)
            if err ~= nil then
                return err
            end
        end
        parts[#parts + 1] = ']'
        return nil
    end

    local keys = sorted_string_keys(value)
    if not keys.ok then
        return invalid('payload', 'NON_STRING_FIELD_KEY')
    end
    parts[#parts + 1] = 'O'
    parts[#parts + 1] = tostring_value(#keys.value)
    parts[#parts + 1] = '{'
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        parts[#parts + 1] = 'K'
        parts[#parts + 1] = tostring_value(#key)
        parts[#parts + 1] = ':'
        parts[#parts + 1] = key
        local err = append_canonical(parts, raw_get(value, key), depth + 1)
        if err ~= nil then
            return err
        end
    end
    parts[#parts + 1] = '}'
    return nil
end

function SaveEnvelope.compute_payload_checksum(payload)
    local shape = TableShape.validate_serializable(payload, 3, '$.payload')
    if not shape.ok then
        return Result.err(
            'SAVE_ENVELOPE_INVALID',
            'error.save.envelope_invalid',
            false,
            {
                field = 'payload',
                reason = 'PAYLOAD_INVALID',
                cause = shape.error,
            }
        )
    end
    local parts = { 'WZX-SAVE-PAYLOAD-V1\0' }
    local err = append_canonical(parts, payload, 0)
    if err ~= nil then
        return err
    end
    local digest, hash_error = sha256_hex(table.concat(parts))
    if digest == nil then
        return Result.err(
            'SAVE_ENVELOPE_INVALID',
            'error.save.envelope_invalid',
            false,
            {
                field = 'payload_checksum',
                reason = 'SHA256_FAILED',
                cause = hash_error,
            }
        )
    end
    return Result.ok(digest)
end

function SaveEnvelope.owner_fingerprint_for_scope(player_save_scope)
    local scope = RuntimeId.validate_component(
        player_save_scope,
        'player_save_scope'
    )
    if not scope.ok then
        return Result.err(
            'SAVE_ENVELOPE_INVALID',
            'error.save.envelope_invalid',
            false,
            {
                field = 'owner_fingerprint',
                reason = 'OWNER_SCOPE_INVALID',
                cause_code = scope.error.code,
            }
        )
    end
    local digest, hash_error = sha256_hex(
        'owner_scope_v1\0' .. scope.value
    )
    if digest == nil then
        return Result.err(
            'SAVE_ENVELOPE_INVALID',
            'error.save.envelope_invalid',
            false,
            {
                field = 'owner_fingerprint',
                reason = 'SHA256_FAILED',
                cause = hash_error,
            }
        )
    end
    return Result.ok('owner_v1_' .. digest)
end

function SaveEnvelope.build(options)
    if type_value(options) ~= 'table' or getmetatable(options) ~= nil then
        return invalid('options', 'TABLE_REQUIRED')
    end
    local fingerprint = SaveEnvelope.owner_fingerprint_for_scope(
        options.player_save_scope
    )
    if not fingerprint.ok then
        return fingerprint
    end
    local checksum = SaveEnvelope.compute_payload_checksum(options.payload)
    if not checksum.ok then
        return checksum
    end
    local envelope = {
        schema_version = options.schema_version or 1,
        revision = options.revision,
        checkpoint_id = options.checkpoint_id,
        content_version = options.content_version or 'content-v1',
        owner_fingerprint = fingerprint.value,
        payload_checksum = checksum.value,
        payload = options.payload,
    }
    if options.written_at ~= nil then
        envelope.written_at = options.written_at
    end
    return SaveEnvelope.validate(envelope)
end

function SaveEnvelope.validate_slot_one_payload(payload)
    if type(payload) ~= 'table' then
        return invalid('payload', 'TABLE_REQUIRED')
    end
    local required = { 'manifest', 'player_profile', 'settings_profile' }
    local allowed = {
        manifest = true,
        player_profile = true,
        settings_profile = true,
    }
    local keys = Ordered.sorted_string_keys(payload)
    if not keys.ok then
        return invalid('payload', 'NON_STRING_FIELD_KEY')
    end
    local field
    local index
    for index = 1, #keys.value do
        field = keys.value[index]
        if not allowed[field] then
            return invalid('payload.' .. tostring(field), 'UNKNOWN_SLOT_ONE_SECTION')
        end
    end
    for index = 1, #required do
        field = required[index]
        if type(payload[field]) ~= 'table' then
            return invalid('payload.' .. field, 'SECTION_TABLE_REQUIRED')
        end
    end
    return Result.ok(payload)
end

return SaveEnvelope
