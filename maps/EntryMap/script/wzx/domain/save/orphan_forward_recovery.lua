-- Pure evaluator for Manifest-last forward recovery of orphan data-slot writes.
-- Only FORWARD when durable pending intent fully matches observed orphan proofs.
-- Insufficient evidence → RECOVERY_REQUIRED; never silently adopt orphans.

local Result = require 'wzx.domain.common.result'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'
local SlotRevisionVector = require 'wzx.domain.save.slot_revision_vector'
local SaveManifest = require 'wzx.domain.save.save_manifest'
local PendingCheckpointIntent = require 'wzx.domain.save.pending_checkpoint_intent'

local OrphanForwardRecovery = {}
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

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

local function invalid(reason, details)
    return fail(SaveErrorCodes.SAVE_ARGUMENT_INVALID, reason, details)
end

local function observation_from_envelope(slot_id, envelope)
    if type_value(envelope) ~= 'table' then
        return nil
    end
    return {
        slot_id = slot_id,
        revision = envelope.revision,
        checkpoint_id = envelope.checkpoint_id,
        payload_checksum = envelope.payload_checksum,
        schema_version = envelope.schema_version,
        payload = envelope.payload,
    }
end

local function get_observation(observations, slot_id)
    return raw_get(observations, slot_id) or raw_get(observations, tostring(slot_id))
end

function OrphanForwardRecovery.evaluate(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local manifest = raw_get(input, 'manifest')
    local manifest_ok = SaveManifest.validate(manifest)
    if not manifest_ok.ok then
        return invalid('MANIFEST_INVALID', {
            cause = manifest_ok.error and manifest_ok.error.details,
        })
    end
    manifest = manifest_ok.value

    local intent_value = raw_get(input, 'intent')
    if intent_value == nil then
        return result_ok({
            action = 'RECOVERY_REQUIRED',
            reason = 'PENDING_INTENT_MISSING',
            orphan_slots = raw_get(input, 'orphan_slot_ids') or {},
        })
    end
    local intent = PendingCheckpointIntent.coerce(intent_value)
    if not intent.ok then
        return result_ok({
            action = 'RECOVERY_REQUIRED',
            reason = 'PENDING_INTENT_INVALID',
            cause = intent.error and intent.error.details,
            orphan_slots = raw_get(input, 'orphan_slot_ids') or {},
        })
    end
    intent = intent.value

    if intent.state == 'MANIFEST_COMMITTED' then
        return result_ok({
            action = 'NO_OP',
            reason = 'INTENT_ALREADY_MANIFEST_COMMITTED',
            intent = intent,
        })
    end
    if intent.state ~= 'DATA_WRITTEN' and intent.state ~= 'PREPARED' then
        return result_ok({
            action = 'RECOVERY_REQUIRED',
            reason = 'INTENT_STATE_NOT_FORWARDABLE',
            intent_state = intent.state,
        })
    end
    if intent.base_manifest_checkpoint_id ~= manifest.checkpoint_id then
        return result_ok({
            action = 'RECOVERY_REQUIRED',
            reason = 'BASE_MANIFEST_CHECKPOINT_MISMATCH',
            expected = intent.base_manifest_checkpoint_id,
            actual = manifest.checkpoint_id,
        })
    end
    if intent.target_checkpoint_id == manifest.checkpoint_id then
        return result_ok({
            action = 'NO_OP',
            reason = 'TARGET_ALREADY_COMMITTED',
            intent = intent,
        })
    end

    local observations = raw_get(input, 'observations') or {}
    if type_value(observations) ~= 'table' then
        return invalid('OBSERVATIONS_REQUIRED')
    end

    local next_entries = SlotRevisionVector.copy_entries(
        manifest.slot_revision_entries
    )
    if not next_entries.ok then
        return next_entries
    end
    next_entries = next_entries.value

    local dirty_ids = {}
    local dirty_set = {}
    local index
    for index = 1, #intent.dirty_slot_proofs do
        local proof = intent.dirty_slot_proofs[index]
        local observed = get_observation(observations, proof.slot_id)
        if observed == nil then
            return result_ok({
                action = 'RECOVERY_REQUIRED',
                reason = 'DIRTY_SLOT_MISSING',
                slot_id = proof.slot_id,
            })
        end
        if observed.checkpoint_id ~= intent.target_checkpoint_id then
            return result_ok({
                action = 'RECOVERY_REQUIRED',
                reason = 'DIRTY_SLOT_CHECKPOINT_MISMATCH',
                slot_id = proof.slot_id,
                expected = intent.target_checkpoint_id,
                actual = observed.checkpoint_id,
            })
        end
        if observed.revision ~= proof.revision then
            return result_ok({
                action = 'RECOVERY_REQUIRED',
                reason = 'DIRTY_SLOT_REVISION_MISMATCH',
                slot_id = proof.slot_id,
                expected = proof.revision,
                actual = observed.revision,
            })
        end
        local expected_checksum = proof.payload_checksum
        if expected_checksum == nil then
            expected_checksum = observed.payload_checksum
        elseif observed.payload_checksum ~= expected_checksum then
            return result_ok({
                action = 'RECOVERY_REQUIRED',
                reason = 'DIRTY_SLOT_CHECKSUM_MISMATCH',
                slot_id = proof.slot_id,
            })
        end

        local updated = SlotRevisionVector.write_slot(next_entries, {
            slot_id = proof.slot_id,
            schema_version = proof.schema_version or observed.schema_version or 1,
            revision = observed.revision,
            checkpoint_id = intent.target_checkpoint_id,
            payload_checksum = expected_checksum,
        })
        if not updated.ok then
            return updated
        end
        next_entries = updated.value
        dirty_ids[#dirty_ids + 1] = proof.slot_id
        dirty_set[proof.slot_id] = true
    end

    -- Non-dirty slots must remain exactly as in the committed manifest vector.
    -- Any foreign orphan observation blocks forward recovery.
    for index = 1, #SlotRevisionVector.SLOT_IDS do
        local slot_id = SlotRevisionVector.SLOT_IDS[index]
        if dirty_set[slot_id] ~= true then
            local expected = SlotRevisionVector.read_slot(
                manifest.slot_revision_entries,
                slot_id
            )
            if not expected.ok then
                return expected
            end
            expected = expected.value
            local observed = get_observation(observations, slot_id)
            if expected.is_absent then
                if observed ~= nil then
                    return result_ok({
                        action = 'RECOVERY_REQUIRED',
                        reason = 'UNEXPECTED_ORPHAN_ON_ABSENT_SLOT',
                        slot_id = slot_id,
                    })
                end
            else
                if observed == nil then
                    return result_ok({
                        action = 'RECOVERY_REQUIRED',
                        reason = 'CARRIED_SLOT_MISSING',
                        slot_id = slot_id,
                    })
                end
                if observed.revision ~= expected.revision
                    or observed.checkpoint_id ~= expected.checkpoint_id
                    or observed.payload_checksum ~= expected.payload_checksum
                then
                    return result_ok({
                        action = 'RECOVERY_REQUIRED',
                        reason = 'CARRIED_SLOT_PROOF_MISMATCH',
                        slot_id = slot_id,
                    })
                end
            end
        end
    end

    -- Reject observations for slots outside 2-5 or extra foreign proofs.
    local slot_key
    for slot_key in raw_next, observations do
        local numeric_id = slot_key
        if type_value(slot_key) == 'string' then
            numeric_id = tonumber(slot_key)
        end
        if type_value(numeric_id) == 'number'
            and numeric_id >= 2
            and numeric_id <= 5
            and dirty_set[numeric_id] ~= true
        then
            local expected = SlotRevisionVector.read_slot(
                manifest.slot_revision_entries,
                numeric_id
            )
            if expected.ok and not expected.value.is_absent then
                local observed = get_observation(observations, numeric_id)
                if observed ~= nil
                    and (observed.revision ~= expected.value.revision
                        or observed.checkpoint_id ~= expected.value.checkpoint_id
                        or observed.payload_checksum ~= expected.value.payload_checksum)
                then
                    return result_ok({
                        action = 'RECOVERY_REQUIRED',
                        reason = 'FOREIGN_ORPHAN_OBSERVATION',
                        slot_id = numeric_id,
                    })
                end
            end
        end
    end

    local next_manifest = {
        save_format_version = manifest.save_format_version,
        created_revision = manifest.created_revision,
        slot_revision_entries = next_entries,
        checkpoint_id = intent.target_checkpoint_id,
        save_seed = manifest.save_seed,
        feature_flag_snapshot = manifest.feature_flag_snapshot,
        recovery_epoch = manifest.recovery_epoch + 1,
    }
    if manifest.last_save_server_time ~= nil then
        next_manifest.last_save_server_time = manifest.last_save_server_time
    end
    local next_ok = SaveManifest.validate(next_manifest)
    if not next_ok.ok then
        return fail(
            SaveErrorCodes.SAVE_CHECKPOINT_INVALID,
            'NEXT_MANIFEST_INVALID',
            { cause = next_ok.error and next_ok.error.details }
        )
    end

    return result_ok({
        action = 'FORWARD_MANIFEST',
        reason = 'INTENT_AND_ORPHAN_PROOFS_MATCH',
        intent = intent,
        dirty_slot_ids = dirty_ids,
        next_manifest = next_ok.value,
        base_slot1_revision = intent.base_slot1_revision,
    })
end

function OrphanForwardRecovery.observation_from_envelope(slot_id, envelope)
    return observation_from_envelope(slot_id, envelope)
end

return OrphanForwardRecovery
