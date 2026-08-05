-- Explicit Manifest-last forward recovery for orphan data-slot writes.
-- Also used by LoadGameSave RECONCILE when durable pending intent fully matches.

local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'
local SaveManifest = require 'wzx.domain.save.save_manifest'
local SlotRevisionVector = require 'wzx.domain.save.slot_revision_vector'
local TableShape = require 'wzx.domain.common.table_shape'
local PendingCheckpointIntent = require 'wzx.domain.save.pending_checkpoint_intent'
local OrphanForwardRecovery = require 'wzx.domain.save.orphan_forward_recovery'

local RecoverOrphanCheckpoint = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_component = RuntimeId.validate_component

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('recover orphan checkpoint service is read-only', 2)
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

local function copy_table(value)
    local copied = TableShape.deep_copy_serializable(value, 4, '$')
    if not copied.ok then
        return nil
    end
    return copied.value
end

function RecoverOrphanCheckpoint.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local coordinator = raw_get(options, 'coordinator')
    if type_value(coordinator) ~= 'table'
        or type_value(coordinator.load_slot) ~= 'function'
        or type_value(coordinator.write_slots) ~= 'function'
        or type_value(coordinator.allocate_transaction_id) ~= 'function'
    then
        return invalid('COORDINATOR_REQUIRED', { field = 'coordinator' })
    end
    local view = set_metatable({}, Service)
    STATES[view] = { coordinator = coordinator }
    return result_ok(view)
end

local function verify_envelope(loaded_value, expected_fingerprint)
    local dto = raw_get(loaded_value, 'dto')
    local validated = SaveEnvelope.validate(dto)
    if not validated.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'ENVELOPE_INVALID',
            { cause = validated.error and validated.error.details },
            false
        )
    end
    if validated.value.owner_fingerprint ~= expected_fingerprint then
        return fail(
            SaveErrorCodes.SAVE_OWNER_MISMATCH,
            'OWNER_FINGERPRINT_MISMATCH',
            {
                expected = expected_fingerprint,
                actual = validated.value.owner_fingerprint,
            },
            false
        )
    end
    local recomputed = SaveEnvelope.compute_payload_checksum(validated.value.payload)
    if not recomputed.ok then
        return recomputed
    end
    if recomputed.value ~= validated.value.payload_checksum
        or recomputed.value ~= loaded_value.payload_checksum
    then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'PAYLOAD_CHECKSUM_MISMATCH',
            {
                expected = validated.value.payload_checksum,
                actual = recomputed.value,
            },
            false
        )
    end
    if validated.value.revision ~= loaded_value.revision
        or validated.value.checkpoint_id ~= loaded_value.checkpoint_id
    then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'LOAD_DTO_IDENTITY_MISMATCH',
            {
                dto_revision = validated.value.revision,
                load_revision = loaded_value.revision,
            },
            false
        )
    end
    return result_ok(validated.value)
end

function RecoverOrphanCheckpoint.evaluate_from_loaded(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    return OrphanForwardRecovery.evaluate({
        manifest = raw_get(input, 'manifest'),
        intent = raw_get(input, 'intent'),
        observations = raw_get(input, 'observations'),
        orphan_slot_ids = raw_get(input, 'orphan_slot_ids'),
    })
end

function RecoverOrphanCheckpoint.build_slot1_payload(input)
    if type_value(input) ~= 'table' then
        return invalid('INPUT_REQUIRED')
    end
    local next_manifest = raw_get(input, 'next_manifest')
    local player_profile = raw_get(input, 'player_profile')
    local settings_profile = raw_get(input, 'settings_profile')
    local manifest_ok = SaveManifest.validate(next_manifest)
    if not manifest_ok.ok then
        return fail(
            SaveErrorCodes.SAVE_CHECKPOINT_INVALID,
            'NEXT_MANIFEST_INVALID',
            { cause = manifest_ok.error and manifest_ok.error.details },
            false
        )
    end
    if type_value(player_profile) ~= 'table' or type_value(settings_profile) ~= 'table' then
        return invalid('SLOT1_SECTIONS_REQUIRED')
    end
    local profile_copy = TableShape.deep_copy_serializable(
        player_profile,
        2,
        '$.player_profile'
    )
    if not profile_copy.ok then
        return invalid('PLAYER_PROFILE_COPY_FAILED')
    end
    local settings_copy = TableShape.deep_copy_serializable(
        settings_profile,
        3,
        '$.settings_profile'
    )
    if not settings_copy.ok then
        return invalid('SETTINGS_PROFILE_COPY_FAILED')
    end
    local payload = {
        manifest = manifest_ok.value,
        player_profile = profile_copy.value,
        settings_profile = settings_copy.value,
    }
    local slot_one = SaveEnvelope.validate_slot_one_payload(payload)
    if not slot_one.ok then
        return fail(
            SaveErrorCodes.SAVE_CHECKPOINT_INVALID,
            'SLOT1_PAYLOAD_INVALID',
            {},
            false
        )
    end
    return result_ok(payload)
end

function Service:recover(input, invoke)
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

    local player_ref = validate_component(raw_get(input, 'player_ref'), 'player_ref')
    if not player_ref.ok then
        return invalid('PLAYER_REF_INVALID', { field = 'player_ref' })
    end
    local request_id = validate_component(
        raw_get(input, 'request_id') or 'recover_orphan_1',
        'request_id'
    )
    if not request_id.ok then
        return invalid('REQUEST_ID_INVALID', { field = 'request_id' })
    end
    local player_save_scope = validate_component(
        raw_get(input, 'player_save_scope') or player_ref.value,
        'player_save_scope'
    )
    if not player_save_scope.ok then
        return invalid('PLAYER_SAVE_SCOPE_INVALID', {
            field = 'player_save_scope',
        })
    end

    local fingerprint = SaveEnvelope.owner_fingerprint_for_scope(
        player_save_scope.value
    )
    if not fingerprint.ok then
        return fingerprint
    end

    local slot1 = state.coordinator:load_slot({
        player_ref = player_ref.value,
        slot_id = 1,
        request_id = request_id.value .. '_slot1',
        correlation_id = request_id.value,
    }, invoke)
    if not slot1.ok then
        return slot1
    end
    local envelope1 = verify_envelope(slot1.value, fingerprint.value)
    if not envelope1.ok then
        return envelope1
    end
    local manifest = SaveManifest.validate(envelope1.value.payload.manifest)
    if not manifest.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'MANIFEST_INVALID',
            { cause = manifest.error and manifest.error.details },
            false
        )
    end

    local observations = {}
    local orphan_slot_ids = {}
    local intent = raw_get(input, 'intent')
    local slot_ids = SlotRevisionVector.list_slot_ids()
    local index
    for index = 1, #slot_ids do
        local slot_id = slot_ids[index]
        local expected = SlotRevisionVector.read_slot(
            manifest.value.slot_revision_entries,
            slot_id
        )
        if not expected.ok then
            return expected
        end
        local loaded = state.coordinator:load_slot({
            player_ref = player_ref.value,
            slot_id = slot_id,
            request_id = request_id.value .. '_slot' .. tostring(slot_id),
            correlation_id = request_id.value,
        }, invoke)
        if loaded.ok then
            local verified = verify_envelope(loaded.value, fingerprint.value)
            if not verified.ok then
                return verified
            end
            local obs = OrphanForwardRecovery.observation_from_envelope(
                slot_id,
                verified.value
            )
            observations[slot_id] = obs
            local matches = obs.revision == expected.value.revision
                and obs.checkpoint_id == expected.value.checkpoint_id
                and obs.payload_checksum == expected.value.payload_checksum
            if expected.value.is_absent or not matches then
                orphan_slot_ids[#orphan_slot_ids + 1] = slot_id
            end
            if intent == nil then
                local extracted = PendingCheckpointIntent.extract_from_payload(
                    verified.value.payload
                )
                if extracted.ok and extracted.value ~= nil then
                    intent = extracted.value
                end
            end
        elseif loaded.error and loaded.error.code ~= 'SAVE_NOT_FOUND' then
            return loaded
        end
    end

    local evaluated = OrphanForwardRecovery.evaluate({
        manifest = manifest.value,
        intent = intent,
        observations = observations,
        orphan_slot_ids = orphan_slot_ids,
    })
    if not evaluated.ok then
        return evaluated
    end
    if evaluated.value.action ~= 'FORWARD_MANIFEST' then
        return fail(
            SaveErrorCodes.RECOVERY_AMBIGUOUS,
            evaluated.value.reason or 'FORWARD_NOT_SAFE',
            {
                action = evaluated.value.action,
                evaluation = evaluated.value,
                orphan_slots = orphan_slot_ids,
            },
            false
        )
    end

    local payload = RecoverOrphanCheckpoint.build_slot1_payload({
        next_manifest = evaluated.value.next_manifest,
        player_profile = envelope1.value.payload.player_profile,
        settings_profile = envelope1.value.payload.settings_profile,
    })
    if not payload.ok then
        return payload
    end

    local tx = state.coordinator:allocate_transaction_id('orphan_fwd')
    if not tx.ok then
        return tx
    end
    local written = state.coordinator:write_slots({
        player_ref = player_ref.value,
        checkpoint_id = evaluated.value.next_manifest.checkpoint_id,
        transaction_id = tx.value,
        request_id = request_id.value .. '_manifest',
        content_version = envelope1.value.content_version or 'content-v1',
        slot_writes = {
            {
                slot_id = 1,
                expected_revision = envelope1.value.revision,
                payload = payload.value,
            },
        },
    }, invoke)
    if not written.ok then
        return fail(
            SaveErrorCodes.SAVE_RESULT_UNKNOWN,
            'FORWARD_MANIFEST_WRITE_FAILED',
            {
                cause_code = written.error and written.error.code,
                checkpoint_id = evaluated.value.next_manifest.checkpoint_id,
                recovery = 'QUERY_OR_RECONCILE',
            },
            true
        )
    end
    if written.value.status ~= 'COMMITTED' then
        return fail(
            SaveErrorCodes.SAVE_RESULT_UNKNOWN,
            'FORWARD_MANIFEST_NOT_COMMITTED',
            {
                status = written.value.status,
                checkpoint_id = evaluated.value.next_manifest.checkpoint_id,
                recovery = 'QUERY_OR_RECONCILE',
            },
            true
        )
    end

    return result_ok({
        status = 'COMMITTED',
        action = 'FORWARD_MANIFEST',
        checkpoint_id = evaluated.value.next_manifest.checkpoint_id,
        slot1_revision = envelope1.value.revision + 1,
        recovery_epoch = evaluated.value.next_manifest.recovery_epoch,
        dirty_slot_ids = evaluated.value.dirty_slot_ids,
        manifest = copy_table(evaluated.value.next_manifest),
        orphan_slots_resolved = orphan_slot_ids,
    })
end

return RecoverOrphanCheckpoint
