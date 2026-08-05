-- Slot-5 section: save_pending_checkpoint
-- Durable intent for Manifest-last forward recovery after data slots commit.
-- Flat scalar fields only (payload → section → scalars) for three-layer limit.
-- payload_checksum may be omitted for a dirty slot so the carrier can embed the
-- intent without a self-referential checksum.

local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'
local SlotRevisionVector = require 'wzx.domain.save.slot_revision_vector'

local PendingCheckpointIntent = {}
local get_metatable = getmetatable
local is_integer = TableShape.is_integer
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_derived = RuntimeId.validate_derived

local CURRENT_SCHEMA_VERSION = 1
local SECTION_KEY = 'save_pending_checkpoint'
local STATES = {
    PREPARED = true,
    DATA_WRITTEN = true,
    MANIFEST_COMMITTED = true,
}
local SLOT_IDS = SlotRevisionVector.SLOT_IDS

local FIELDS = {
    schema_version = true,
    command_id = true,
    target_checkpoint_id = true,
    base_manifest_checkpoint_id = true,
    base_slot1_revision = true,
    state = true,
}
local index
for index = 1, #SLOT_IDS do
    local slot_id = SLOT_IDS[index]
    FIELDS['slot_' .. tostring(slot_id) .. '_dirty'] = true
    FIELDS['slot_' .. tostring(slot_id) .. '_schema_version'] = true
    FIELDS['slot_' .. tostring(slot_id) .. '_revision'] = true
    FIELDS['slot_' .. tostring(slot_id) .. '_payload_checksum'] = true
end

PendingCheckpointIntent.SECTION_KEY = SECTION_KEY
PendingCheckpointIntent.STATES = STATES

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        SaveErrorCodes.SAVE_ARGUMENT_INVALID,
        'error.save.pending_checkpoint_intent_invalid',
        false,
        details
    )
end

local function no_unknown_fields(value, allowed)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return invalid('TABLE_REQUIRED')
    end
    local key
    for key in raw_next, value do
        if type_value(key) ~= 'string' or allowed[key] ~= true then
            return invalid('UNKNOWN_FIELD', { field = tostring(key) })
        end
    end
    return nil
end

local function is_sha256(value)
    return type_value(value) == 'string'
        and #value == 64
        and string.match(value, '^[a-f0-9]+$') ~= nil
end

local function field(slot_id, suffix)
    return 'slot_' .. tostring(slot_id) .. '_' .. suffix
end

function PendingCheckpointIntent.validate(value)
    local unknown = no_unknown_fields(value, FIELDS)
    if unknown ~= nil then
        return unknown
    end
    if not is_integer(raw_get(value, 'schema_version'), 1, CURRENT_SCHEMA_VERSION) then
        return invalid('SCHEMA_VERSION_INVALID', { field = 'schema_version' })
    end
    local command_id = validate_component(raw_get(value, 'command_id'), 'command_id')
    if not command_id.ok then
        return invalid('COMMAND_ID_INVALID', { field = 'command_id' })
    end
    local target_checkpoint_id = validate_derived(
        raw_get(value, 'target_checkpoint_id'),
        'target_checkpoint_id'
    )
    if not target_checkpoint_id.ok then
        return invalid('TARGET_CHECKPOINT_ID_INVALID', {
            field = 'target_checkpoint_id',
        })
    end
    local base_manifest_checkpoint_id = validate_derived(
        raw_get(value, 'base_manifest_checkpoint_id'),
        'base_manifest_checkpoint_id'
    )
    if not base_manifest_checkpoint_id.ok then
        return invalid('BASE_MANIFEST_CHECKPOINT_ID_INVALID', {
            field = 'base_manifest_checkpoint_id',
        })
    end
    if not is_integer(raw_get(value, 'base_slot1_revision'), 0) then
        return invalid('BASE_SLOT1_REVISION_INVALID', {
            field = 'base_slot1_revision',
        })
    end
    local state = raw_get(value, 'state')
    if type_value(state) ~= 'string' or STATES[state] ~= true then
        return invalid('STATE_INVALID', { field = 'state', value = state })
    end

    local dirty_slot_proofs = {}
    for index = 1, #SLOT_IDS do
        local slot_id = SLOT_IDS[index]
        local dirty = raw_get(value, field(slot_id, 'dirty'))
        if dirty == true then
            local schema_version = raw_get(value, field(slot_id, 'schema_version'))
            local revision = raw_get(value, field(slot_id, 'revision'))
            local payload_checksum = raw_get(value, field(slot_id, 'payload_checksum'))
            if not is_integer(schema_version, 1) then
                return invalid('PROOF_SCHEMA_VERSION_INVALID', {
                    slot_id = slot_id,
                })
            end
            if not is_integer(revision, 1) then
                return invalid('PROOF_REVISION_INVALID', { slot_id = slot_id })
            end
            if payload_checksum ~= nil and not is_sha256(payload_checksum) then
                return invalid('PROOF_PAYLOAD_CHECKSUM_INVALID', {
                    slot_id = slot_id,
                })
            end
            dirty_slot_proofs[#dirty_slot_proofs + 1] = {
                slot_id = slot_id,
                schema_version = schema_version,
                revision = revision,
                payload_checksum = payload_checksum,
            }
        elseif dirty ~= nil and dirty ~= false then
            return invalid('DIRTY_FLAG_BOOLEAN_REQUIRED', { slot_id = slot_id })
        end
    end
    if #dirty_slot_proofs < 1 then
        return invalid('DIRTY_SLOT_PROOFS_EMPTY')
    end

    return result_ok({
        schema_version = value.schema_version,
        command_id = command_id.value,
        target_checkpoint_id = target_checkpoint_id.value,
        base_manifest_checkpoint_id = base_manifest_checkpoint_id.value,
        base_slot1_revision = value.base_slot1_revision,
        state = state,
        dirty_slot_proofs = dirty_slot_proofs,
    })
end

function PendingCheckpointIntent.build(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local section = {
        schema_version = raw_get(input, 'schema_version') or CURRENT_SCHEMA_VERSION,
        command_id = raw_get(input, 'command_id'),
        target_checkpoint_id = raw_get(input, 'target_checkpoint_id'),
        base_manifest_checkpoint_id = raw_get(input, 'base_manifest_checkpoint_id'),
        base_slot1_revision = raw_get(input, 'base_slot1_revision'),
        state = raw_get(input, 'state') or 'DATA_WRITTEN',
    }

    local proofs = raw_get(input, 'dirty_slot_proofs')
    if type_value(proofs) == 'table' then
        local proof_index
        for proof_index = 1, #proofs do
            local proof = proofs[proof_index]
            if type_value(proof) == 'table' and is_integer(proof.slot_id, 2, 5) then
                local slot_id = proof.slot_id
                section[field(slot_id, 'dirty')] = true
                section[field(slot_id, 'schema_version')] = proof.schema_version or 1
                section[field(slot_id, 'revision')] = proof.revision
                if proof.payload_checksum ~= nil then
                    section[field(slot_id, 'payload_checksum')] = proof.payload_checksum
                end
            end
        end
    else
        for index = 1, #SLOT_IDS do
            local slot_id = SLOT_IDS[index]
            local dirty = raw_get(input, field(slot_id, 'dirty'))
            if dirty == true then
                section[field(slot_id, 'dirty')] = true
                section[field(slot_id, 'schema_version')] =
                    raw_get(input, field(slot_id, 'schema_version'))
                section[field(slot_id, 'revision')] =
                    raw_get(input, field(slot_id, 'revision'))
                local checksum = raw_get(input, field(slot_id, 'payload_checksum'))
                if checksum ~= nil then
                    section[field(slot_id, 'payload_checksum')] = checksum
                end
            end
        end
    end

    return PendingCheckpointIntent.validate(section)
end

function PendingCheckpointIntent.extract_from_payload(payload)
    if type_value(payload) ~= 'table' then
        return result_ok(nil)
    end
    local section = raw_get(payload, SECTION_KEY)
    if section == nil then
        return result_ok(nil)
    end
    return PendingCheckpointIntent.validate(section)
end

-- Accept flat durable section or already-normalized validate()/build() result.
function PendingCheckpointIntent.coerce(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    if type_value(raw_get(value, 'dirty_slot_proofs')) == 'table' then
        local section = PendingCheckpointIntent.to_section(value)
        if not section.ok then
            return section
        end
        return PendingCheckpointIntent.validate(section.value)
    end
    return PendingCheckpointIntent.validate(value)
end

function PendingCheckpointIntent.list_dirty_slot_ids(intent)
    local validated = PendingCheckpointIntent.coerce(intent)
    if not validated.ok then
        return validated
    end
    local ids = {}
    for index = 1, #validated.value.dirty_slot_proofs do
        ids[index] = validated.value.dirty_slot_proofs[index].slot_id
    end
    return result_ok(ids)
end

function PendingCheckpointIntent.to_section(intent)
    if type_value(intent) ~= 'table' then
        return invalid('INPUT_REQUIRED')
    end
    local proofs = raw_get(intent, 'dirty_slot_proofs')
    if type_value(proofs) ~= 'table' then
        local validated = PendingCheckpointIntent.validate(intent)
        if not validated.ok then
            return validated
        end
        intent = validated.value
        proofs = intent.dirty_slot_proofs
    end
    local section = {
        schema_version = intent.schema_version,
        command_id = intent.command_id,
        target_checkpoint_id = intent.target_checkpoint_id,
        base_manifest_checkpoint_id = intent.base_manifest_checkpoint_id,
        base_slot1_revision = intent.base_slot1_revision,
        state = intent.state,
    }
    for index = 1, #proofs do
        local proof = proofs[index]
        section[field(proof.slot_id, 'dirty')] = true
        section[field(proof.slot_id, 'schema_version')] = proof.schema_version
        section[field(proof.slot_id, 'revision')] = proof.revision
        if proof.payload_checksum ~= nil then
            section[field(proof.slot_id, 'payload_checksum')] = proof.payload_checksum
        end
    end
    return result_ok(section)
end

return PendingCheckpointIntent
