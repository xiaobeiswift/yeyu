local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'

local SlotRevisionVector = {}
local is_integer = TableShape.is_integer
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_derived = RuntimeId.validate_derived

local SLOT_IDS = { 2, 3, 4, 5 }
local ABSENT_CHECKPOINT_ID = 'checkpoint:absent:0'
local ABSENT_CHECKSUM = string.rep('0', 64)

SlotRevisionVector.SLOT_IDS = SLOT_IDS
SlotRevisionVector.ABSENT_CHECKPOINT_ID = ABSENT_CHECKPOINT_ID
SlotRevisionVector.ABSENT_CHECKSUM = ABSENT_CHECKSUM

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.save.' .. string.lower(code),
        false,
        details
    )
end

local function slot_key(slot_id, suffix)
    return 'slot_' .. tostring(slot_id) .. '_' .. suffix
end

function SlotRevisionVector.empty_entries()
    local entries = {}
    local index
    for index = 1, #SLOT_IDS do
        local slot_id = SLOT_IDS[index]
        entries[slot_key(slot_id, 'schema_version')] = 1
        entries[slot_key(slot_id, 'revision')] = 0
        entries[slot_key(slot_id, 'checkpoint_id')] = ABSENT_CHECKPOINT_ID
        entries[slot_key(slot_id, 'payload_checksum')] = ABSENT_CHECKSUM
    end
    return entries
end

function SlotRevisionVector.copy_entries(entries)
    if type_value(entries) ~= 'table' then
        return fail(
            SaveErrorCodes.SAVE_ARGUMENT_INVALID,
            'ENTRIES_TABLE_REQUIRED',
            { field = 'slot_revision_entries' }
        )
    end
    local copied = {}
    local key
    local value
    for key, value in raw_next, entries do
        copied[key] = value
    end
    return result_ok(copied)
end

function SlotRevisionVector.read_slot(entries, slot_id)
    if type_value(entries) ~= 'table' then
        return fail(
            SaveErrorCodes.SAVE_ARGUMENT_INVALID,
            'ENTRIES_TABLE_REQUIRED',
            { field = 'slot_revision_entries' }
        )
    end
    if not is_integer(slot_id, 2, 5) then
        return fail(
            SaveErrorCodes.SAVE_ARGUMENT_INVALID,
            'SLOT_ID_INVALID',
            { field = 'slot_id', slot_id = slot_id }
        )
    end
    local schema_version = raw_get(entries, slot_key(slot_id, 'schema_version'))
    local revision = raw_get(entries, slot_key(slot_id, 'revision'))
    local checkpoint_id = raw_get(entries, slot_key(slot_id, 'checkpoint_id'))
    local payload_checksum = raw_get(entries, slot_key(slot_id, 'payload_checksum'))
    if not is_integer(schema_version, 1)
        or not is_integer(revision, 0)
        or type_value(checkpoint_id) ~= 'string'
        or type_value(payload_checksum) ~= 'string'
    then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'SLOT_VECTOR_INCOMPLETE',
            { slot_id = slot_id }
        )
    end
    return result_ok({
        slot_id = slot_id,
        schema_version = schema_version,
        revision = revision,
        checkpoint_id = checkpoint_id,
        payload_checksum = payload_checksum,
        is_absent = revision == 0
            and checkpoint_id == ABSENT_CHECKPOINT_ID
            and payload_checksum == ABSENT_CHECKSUM,
    })
end

function SlotRevisionVector.write_slot(entries, slot_proof)
    local copied = SlotRevisionVector.copy_entries(entries)
    if not copied.ok then
        return copied
    end
    if type_value(slot_proof) ~= 'table' then
        return fail(
            SaveErrorCodes.SAVE_ARGUMENT_INVALID,
            'SLOT_PROOF_TABLE_REQUIRED',
            { field = 'slot_proof' }
        )
    end
    local slot_id = raw_get(slot_proof, 'slot_id')
    if not is_integer(slot_id, 2, 5) then
        return fail(
            SaveErrorCodes.SAVE_ARGUMENT_INVALID,
            'SLOT_ID_INVALID',
            { field = 'slot_proof.slot_id' }
        )
    end
    local schema_version = raw_get(slot_proof, 'schema_version') or 1
    local revision = raw_get(slot_proof, 'revision')
    local checkpoint_id = raw_get(slot_proof, 'checkpoint_id')
    local payload_checksum = raw_get(slot_proof, 'payload_checksum')
    if not is_integer(schema_version, 1)
        or not is_integer(revision, 0)
    then
        return fail(
            SaveErrorCodes.SAVE_ARGUMENT_INVALID,
            'SLOT_PROOF_REVISION_INVALID',
            { slot_id = slot_id }
        )
    end
    local checked_checkpoint = validate_derived(checkpoint_id, 'checkpoint_id')
    if not checked_checkpoint.ok then
        return fail(
            SaveErrorCodes.SAVE_ARGUMENT_INVALID,
            'CHECKPOINT_ID_INVALID',
            { slot_id = slot_id }
        )
    end
    if type_value(payload_checksum) ~= 'string'
        or #payload_checksum ~= 64
        or string.match(payload_checksum, '^[a-f0-9]+$') == nil
    then
        return fail(
            SaveErrorCodes.SAVE_ARGUMENT_INVALID,
            'PAYLOAD_CHECKSUM_INVALID',
            { slot_id = slot_id }
        )
    end
    local next_entries = copied.value
    next_entries[slot_key(slot_id, 'schema_version')] = schema_version
    next_entries[slot_key(slot_id, 'revision')] = revision
    next_entries[slot_key(slot_id, 'checkpoint_id')] = checkpoint_id
    next_entries[slot_key(slot_id, 'payload_checksum')] = payload_checksum
    return result_ok(next_entries)
end

function SlotRevisionVector.list_slot_ids()
    local copied = {}
    local index
    for index = 1, #SLOT_IDS do
        copied[index] = SLOT_IDS[index]
    end
    return copied
end

return SlotRevisionVector
