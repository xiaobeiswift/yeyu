local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'
local SaveManifest = require 'wzx.domain.save.save_manifest'
local SlotRevisionVector = require 'wzx.domain.save.slot_revision_vector'
local TableShape = require 'wzx.domain.common.table_shape'

local SaveCheckpoint = {}
local error_value = error
local get_metatable = getmetatable
local is_integer = TableShape.is_integer
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_component = RuntimeId.validate_component

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('save checkpoint service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.save.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(SaveErrorCodes.SAVE_ARGUMENT_INVALID, reason, details, false)
end

function SaveCheckpoint.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local coordinator = raw_get(options, 'coordinator')
    if type_value(coordinator) ~= 'table'
        or type_value(coordinator.write_slots) ~= 'function'
        or type_value(coordinator.allocate_checkpoint_id) ~= 'function'
        or type_value(coordinator.allocate_transaction_id) ~= 'function'
    then
        return invalid('COORDINATOR_REQUIRED', { field = 'coordinator' })
    end
    local view = set_metatable({}, Service)
    STATES[view] = {
        coordinator = coordinator,
    }
    return result_ok(view)
end

local function copy_settings(settings)
    local copied = TableShape.deep_copy_serializable(settings, 3, '$.settings_profile')
    if not copied.ok then
        return nil
    end
    return copied.value
end

function Service:save(input, invoke)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    if type_value(invoke) ~= 'function' then
        return invalid('INVOKE_REQUIRED', { field = 'invoke' })
    end

    local player_ref = validate_component(
        raw_get(input, 'player_ref'),
        'player_ref'
    )
    if not player_ref.ok then
        return invalid('PLAYER_REF_INVALID', { field = 'player_ref' })
    end
    local player_save_scope = validate_component(
        raw_get(input, 'player_save_scope'),
        'player_save_scope'
    )
    if not player_save_scope.ok then
        return invalid('PLAYER_SAVE_SCOPE_INVALID', {
            field = 'player_save_scope',
        })
    end
    local command_id = validate_component(
        raw_get(input, 'command_id'),
        'command_id'
    )
    if not command_id.ok then
        return invalid('COMMAND_ID_INVALID', { field = 'command_id' })
    end
    local request_id = validate_component(
        raw_get(input, 'request_id') or command_id.value,
        'request_id'
    )
    if not request_id.ok then
        return invalid('REQUEST_ID_INVALID', { field = 'request_id' })
    end
    if not is_integer(raw_get(input, 'base_slot1_revision'), 0) then
        return invalid('BASE_SLOT1_REVISION_INVALID', {
            field = 'base_slot1_revision',
        })
    end
    local base_manifest = raw_get(input, 'base_manifest')
    local manifest_ok = SaveManifest.validate(base_manifest)
    if not manifest_ok.ok then
        return invalid('BASE_MANIFEST_INVALID', {
            field = 'base_manifest',
            cause = manifest_ok.error and manifest_ok.error.details,
        })
    end
    local player_profile = raw_get(input, 'player_profile')
    if type_value(player_profile) ~= 'table' then
        return invalid('PLAYER_PROFILE_REQUIRED', { field = 'player_profile' })
    end
    if player_profile.player_save_scope ~= player_save_scope.value then
        return invalid('PLAYER_PROFILE_SCOPE_MISMATCH', {
            field = 'player_profile.player_save_scope',
        })
    end
    local settings_profile = raw_get(input, 'settings_profile')
    if type_value(settings_profile) ~= 'table' then
        return invalid('SETTINGS_PROFILE_REQUIRED', {
            field = 'settings_profile',
        })
    end

    local dirty_slots = raw_get(input, 'dirty_slots') or {}
    if type_value(dirty_slots) ~= 'table' or get_metatable(dirty_slots) ~= nil then
        return invalid('DIRTY_SLOTS_REQUIRED', { field = 'dirty_slots' })
    end

    local checkpoint = state.coordinator:allocate_checkpoint_id('checkpoint')
    if not checkpoint.ok then
        return checkpoint
    end
    local data_tx = state.coordinator:allocate_transaction_id('ckpt_data')
    if not data_tx.ok then
        return data_tx
    end
    local manifest_tx = state.coordinator:allocate_transaction_id('ckpt_manifest')
    if not manifest_tx.ok then
        return manifest_tx
    end

    local next_entries = SlotRevisionVector.copy_entries(
        manifest_ok.value.slot_revision_entries
    )
    if not next_entries.ok then
        return next_entries
    end
    next_entries = next_entries.value

    local data_writes = {}
    local index
    for index = 1, #dirty_slots do
        local row = dirty_slots[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return invalid('DIRTY_SLOT_TABLE_REQUIRED', {
                field = 'dirty_slots[' .. tostring(index) .. ']',
            })
        end
        local slot_id = raw_get(row, 'slot_id')
        if not is_integer(slot_id, 2, 5) then
            return invalid('DIRTY_SLOT_ID_INVALID', {
                field = 'dirty_slots[' .. tostring(index) .. '].slot_id',
            })
        end
        if not is_integer(raw_get(row, 'expected_revision'), 0) then
            return invalid('DIRTY_EXPECTED_REVISION_INVALID', {
                field = 'dirty_slots['
                    .. tostring(index)
                    .. '].expected_revision',
            })
        end
        if type_value(raw_get(row, 'payload')) ~= 'table' then
            return invalid('DIRTY_PAYLOAD_REQUIRED', {
                field = 'dirty_slots[' .. tostring(index) .. '].payload',
            })
        end

        local envelope = SaveEnvelope.build({
            player_save_scope = player_save_scope.value,
            revision = row.expected_revision + 1,
            checkpoint_id = checkpoint.value,
            content_version = raw_get(input, 'content_version') or 'content-v1',
            payload = row.payload,
            written_at = raw_get(input, 'written_at'),
            schema_version = row.schema_version or 1,
        })
        if not envelope.ok then
            return envelope
        end

        local updated = SlotRevisionVector.write_slot(next_entries, {
            slot_id = slot_id,
            schema_version = envelope.value.schema_version,
            revision = envelope.value.revision,
            checkpoint_id = envelope.value.checkpoint_id,
            payload_checksum = envelope.value.payload_checksum,
        })
        if not updated.ok then
            return updated
        end
        next_entries = updated.value
        data_writes[#data_writes + 1] = {
            slot_id = slot_id,
            expected_revision = row.expected_revision,
            payload = row.payload,
            schema_version = envelope.value.schema_version,
            proof = {
                revision = envelope.value.revision,
                checkpoint_id = envelope.value.checkpoint_id,
                payload_checksum = envelope.value.payload_checksum,
            },
        }
    end

    table.sort(data_writes, function(left, right)
        return left.slot_id < right.slot_id
    end)
    local previous = 0
    for index = 1, #data_writes do
        if data_writes[index].slot_id <= previous then
            return invalid('DIRTY_SLOT_IDS_MUST_BE_UNIQUE', {
                slot_id = data_writes[index].slot_id,
            })
        end
        previous = data_writes[index].slot_id
    end

    if #data_writes > 0 then
        local slot_writes = {}
        for index = 1, #data_writes do
            slot_writes[index] = {
                slot_id = data_writes[index].slot_id,
                expected_revision = data_writes[index].expected_revision,
                payload = data_writes[index].payload,
                schema_version = data_writes[index].schema_version,
            }
        end
        local data_written = state.coordinator:write_slots({
            player_ref = player_ref.value,
            checkpoint_id = checkpoint.value,
            transaction_id = data_tx.value,
            request_id = request_id.value .. '_data',
            content_version = raw_get(input, 'content_version') or 'content-v1',
            written_at = raw_get(input, 'written_at'),
            slot_writes = slot_writes,
        }, invoke)
        if not data_written.ok then
            return data_written
        end
        if data_written.value.status ~= 'COMMITTED' then
            return fail(
                SaveErrorCodes.SAVE_RESULT_UNKNOWN,
                'DATA_SLOTS_NOT_COMMITTED',
                {
                    status = data_written.value.status,
                    phase = data_written.value.phase,
                    pending = data_written.value.pending,
                    checkpoint_id = checkpoint.value,
                },
                true
            )
        end
    end

    local next_manifest = {
        save_format_version = manifest_ok.value.save_format_version,
        created_revision = manifest_ok.value.created_revision,
        slot_revision_entries = next_entries,
        checkpoint_id = checkpoint.value,
        save_seed = manifest_ok.value.save_seed,
        feature_flag_snapshot = manifest_ok.value.feature_flag_snapshot,
        recovery_epoch = manifest_ok.value.recovery_epoch,
    }
    if raw_get(input, 'last_save_server_time') ~= nil then
        if not is_integer(input.last_save_server_time, 0) then
            return invalid('LAST_SAVE_SERVER_TIME_INVALID', {
                field = 'last_save_server_time',
            })
        end
        next_manifest.last_save_server_time = input.last_save_server_time
    elseif manifest_ok.value.last_save_server_time ~= nil then
        next_manifest.last_save_server_time = manifest_ok.value.last_save_server_time
    end
    local next_manifest_ok = SaveManifest.validate(next_manifest)
    if not next_manifest_ok.ok then
        return fail(
            SaveErrorCodes.SAVE_CHECKPOINT_INVALID,
            'NEXT_MANIFEST_INVALID',
            { cause = next_manifest_ok.error and next_manifest_ok.error.details },
            false
        )
    end

    local settings_copy = copy_settings(settings_profile)
    if settings_copy == nil then
        return invalid('SETTINGS_PROFILE_COPY_FAILED', {
            field = 'settings_profile',
        })
    end
    local profile_copy = TableShape.deep_copy_serializable(
        player_profile,
        2,
        '$.player_profile'
    )
    if not profile_copy.ok then
        return invalid('PLAYER_PROFILE_COPY_FAILED', {
            field = 'player_profile',
        })
    end

    local slot1_payload = {
        manifest = next_manifest_ok.value,
        player_profile = profile_copy.value,
        settings_profile = settings_copy,
    }
    local slot_one = SaveEnvelope.validate_slot_one_payload(slot1_payload)
    if not slot_one.ok then
        return fail(
            SaveErrorCodes.SAVE_CHECKPOINT_INVALID,
            'SLOT1_PAYLOAD_INVALID',
            {},
            false
        )
    end

    -- Manifest-last: only write slot 1 after data slots are confirmed.
    local manifest_written = state.coordinator:write_slots({
        player_ref = player_ref.value,
        checkpoint_id = checkpoint.value,
        transaction_id = manifest_tx.value,
        request_id = request_id.value .. '_manifest',
        content_version = raw_get(input, 'content_version') or 'content-v1',
        written_at = raw_get(input, 'written_at'),
        slot_writes = {
            {
                slot_id = 1,
                expected_revision = input.base_slot1_revision,
                payload = slot1_payload,
            },
        },
    }, invoke)
    if not manifest_written.ok then
        return fail(
            SaveErrorCodes.SAVE_RESULT_UNKNOWN,
            'MANIFEST_WRITE_FAILED_AFTER_DATA',
            {
                cause_code = manifest_written.error and manifest_written.error.code,
                checkpoint_id = checkpoint.value,
                data_slots_committed = #data_writes > 0,
                recovery = 'QUERY_OR_RECONCILE',
            },
            true
        )
    end
    if manifest_written.value.status ~= 'COMMITTED' then
        return fail(
            SaveErrorCodes.SAVE_RESULT_UNKNOWN,
            'MANIFEST_NOT_COMMITTED_AFTER_DATA',
            {
                status = manifest_written.value.status,
                phase = manifest_written.value.phase,
                pending = manifest_written.value.pending,
                checkpoint_id = checkpoint.value,
                data_slots_committed = #data_writes > 0,
                recovery = 'QUERY_OR_RECONCILE',
            },
            true
        )
    end

    local slot_vector = {}
    for index = 1, #SlotRevisionVector.SLOT_IDS do
        local slot_id = SlotRevisionVector.SLOT_IDS[index]
        local proof = SlotRevisionVector.read_slot(next_entries, slot_id)
        if not proof.ok then
            return proof
        end
        slot_vector[#slot_vector + 1] = proof.value
    end

    return result_ok({
        status = 'COMMITTED',
        command_id = command_id.value,
        checkpoint_id = checkpoint.value,
        slot1_revision = input.base_slot1_revision + 1,
        manifest = next_manifest_ok.value,
        slot_revision_vector = slot_vector,
        dirty_slot_count = #data_writes,
        data_transaction_id = data_tx.value,
        manifest_transaction_id = manifest_tx.value,
    })
end

return SaveCheckpoint
