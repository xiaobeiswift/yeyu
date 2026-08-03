local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.domain.contracts.validation'
local Ordered = require 'wzx.domain.common.ordered'

local SaveManifest = {}

local CONTRACT = 'SaveManifestV1'
local FIELDS = {
    save_format_version = true,
    created_revision = true,
    slot_revision_entries = true,
    checkpoint_id = true,
    last_save_server_time = true,
    save_seed = true,
    feature_flag_snapshot = true,
    recovery_epoch = true,
}
local SLOT_IDS = { 2, 3, 4, 5 }

local function slot_key(slot_id, suffix)
    return 'slot_' .. tostring(slot_id) .. '_' .. suffix
end

local function validate_revision_entries(entries)
    if type(entries) ~= 'table' then
        return Validation.invalid(CONTRACT, 'slot_revision_entries', 'FLAT_MAP_REQUIRED')
    end
    local allowed = {}
    local index
    for index = 1, #SLOT_IDS do
        local slot_id = SLOT_IDS[index]
        allowed[slot_key(slot_id, 'schema_version')] = true
        allowed[slot_key(slot_id, 'revision')] = true
        allowed[slot_key(slot_id, 'checkpoint_id')] = true
        allowed[slot_key(slot_id, 'payload_checksum')] = true
    end
    local keys = Ordered.sorted_string_keys(entries)
    if not keys.ok then
        return Validation.invalid(CONTRACT, 'slot_revision_entries', 'NON_STRING_FIELD_KEY')
    end
    local key
    for index = 1, #keys.value do
        key = keys.value[index]
        if not allowed[key] then
            return Validation.invalid(CONTRACT, 'slot_revision_entries.' .. tostring(key), 'UNKNOWN_SLOT_VECTOR_FIELD')
        end
    end
    for index = 1, #SLOT_IDS do
        local slot_id = SLOT_IDS[index]
        local schema_key = slot_key(slot_id, 'schema_version')
        local revision_key = slot_key(slot_id, 'revision')
        local checkpoint_key = slot_key(slot_id, 'checkpoint_id')
        local checksum_key = slot_key(slot_id, 'payload_checksum')
        local err = Validation.first(
            Validation.integer(CONTRACT, 'slot_revision_entries.' .. schema_key, entries[schema_key], 1),
            Validation.integer(CONTRACT, 'slot_revision_entries.' .. revision_key, entries[revision_key], 0),
            Validation.identifier(CONTRACT, 'slot_revision_entries.' .. checkpoint_key, entries[checkpoint_key]),
            Validation.hash(CONTRACT, 'slot_revision_entries.' .. checksum_key, entries[checksum_key])
        )
        if err ~= nil then
            return err
        end
    end
    return nil
end

function SaveManifest.validate(value)
    local err = Validation.no_unknown_fields(CONTRACT, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.integer(CONTRACT, 'save_format_version', value.save_format_version, 1),
        Validation.integer(CONTRACT, 'created_revision', value.created_revision, 0),
        validate_revision_entries(value.slot_revision_entries),
        Validation.identifier(CONTRACT, 'checkpoint_id', value.checkpoint_id),
        Validation.integer(CONTRACT, 'last_save_server_time', value.last_save_server_time, 0, nil, true),
        Validation.integer(CONTRACT, 'save_seed', value.save_seed, 1, 2147483646),
        Validation.sorted_unique_strings(CONTRACT, 'feature_flag_snapshot', value.feature_flag_snapshot),
        Validation.integer(CONTRACT, 'recovery_epoch', value.recovery_epoch, 0)
    )
    if err ~= nil then
        return err
    end
    return Result.ok(value)
end

return SaveManifest
