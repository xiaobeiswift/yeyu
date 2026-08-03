local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local Ordered = require 'wzx.domain.common.ordered'

local SaveEnvelope = {}

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
    if type(envelope) ~= 'table' then
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
