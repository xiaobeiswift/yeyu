local PlayerProfile = require 'wzx.domain.save.player_profile'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'
local SaveManifest = require 'wzx.domain.save.save_manifest'
local SlotRevisionVector = require 'wzx.domain.save.slot_revision_vector'
local TableShape = require 'wzx.domain.common.table_shape'

local LoadGameSave = {}
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
    error_value('load game save service is read-only', 2)
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

local function slot_report(slot_id, fetch_status, extra)
    local report = {
        slot_id = slot_id,
        fetch_status = fetch_status,
    }
    if type_value(extra) == 'table' then
        local key
        local value
        for key, value in pairs(extra) do
            report[key] = value
        end
    end
    return report
end

local function verify_envelope(loaded_value, expected_owner_fingerprint)
    local dto = raw_get(loaded_value, 'dto')
    local validated = SaveEnvelope.validate(dto)
    if not validated.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'ENVELOPE_INVALID',
            {
                slot_id = loaded_value.slot_id,
                cause = validated.error and validated.error.details,
            },
            false
        )
    end
    local recomputed = SaveEnvelope.compute_payload_checksum(dto.payload)
    if not recomputed.ok then
        return recomputed
    end
    if recomputed.value ~= dto.payload_checksum
        or recomputed.value ~= loaded_value.payload_checksum
    then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'PAYLOAD_CHECKSUM_MISMATCH',
            {
                slot_id = loaded_value.slot_id,
                envelope_checksum = dto.payload_checksum,
                recomputed_checksum = recomputed.value,
                load_checksum = loaded_value.payload_checksum,
            },
            false
        )
    end
    if dto.revision ~= loaded_value.revision
        or dto.checkpoint_id ~= loaded_value.checkpoint_id
    then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'LOAD_DTO_IDENTITY_MISMATCH',
            {
                slot_id = loaded_value.slot_id,
                dto_revision = dto.revision,
                load_revision = loaded_value.revision,
            },
            false
        )
    end
    if expected_owner_fingerprint ~= nil
        and dto.owner_fingerprint ~= expected_owner_fingerprint
    then
        return fail(
            SaveErrorCodes.SAVE_OWNER_MISMATCH,
            'OWNER_FINGERPRINT_MISMATCH',
            {
                slot_id = loaded_value.slot_id,
                expected = expected_owner_fingerprint,
                actual = dto.owner_fingerprint,
            },
            false
        )
    end
    return result_ok(dto)
end

function LoadGameSave.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local coordinator = raw_get(options, 'coordinator')
    if type_value(coordinator) ~= 'table'
        or type_value(coordinator.load_slot) ~= 'function'
    then
        return invalid('COORDINATOR_REQUIRED', { field = 'coordinator' })
    end
    local view = set_metatable({}, Service)
    STATES[view] = {
        coordinator = coordinator,
    }
    return result_ok(view)
end

function Service:load(input, invoke)
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
    local session_instance_id = validate_component(
        raw_get(input, 'session_instance_id'),
        'session_instance_id'
    )
    if not session_instance_id.ok then
        return invalid('SESSION_INSTANCE_ID_INVALID', {
            field = 'session_instance_id',
        })
    end
    local request_id = validate_component(
        raw_get(input, 'request_id') or 'request_load_game_save',
        'request_id'
    )
    if not request_id.ok then
        return invalid('REQUEST_ID_INVALID', { field = 'request_id' })
    end

    local load_report = {
        session_instance_id = session_instance_id.value,
        slots = {},
    }

    local slot1 = state.coordinator:load_slot({
        player_ref = player_ref.value,
        slot_id = 1,
        request_id = request_id.value .. '_slot1',
        correlation_id = request_id.value,
    }, invoke)

    if not slot1.ok then
        if slot1.error and slot1.error.code == 'SAVE_NOT_FOUND' then
            load_report.slots[#load_report.slots + 1] = slot_report(
                1,
                'CONFIRMED_ABSENT'
            )
            return result_ok({
                mode = 'CONFIRMED_ABSENT',
                session_instance_id = session_instance_id.value,
                player_ref = player_ref.value,
                load_report = load_report,
            })
        end
        if slot1.error
            and (slot1.error.code == 'PLATFORM_UNAVAILABLE'
                or slot1.error.code == 'PLATFORM_RATE_LIMITED'
                or slot1.error.code == 'PLATFORM_RESULT_UNKNOWN')
        then
            load_report.slots[#load_report.slots + 1] = slot_report(
                1,
                'TEMPORARY_FAILURE',
                { error_code = slot1.error.code }
            )
            return fail(
                SaveErrorCodes.SAVE_DOWNLOAD_FAILED,
                'SLOT1_TEMPORARY_FAILURE',
                {
                    session_instance_id = session_instance_id.value,
                    cause_code = slot1.error.code,
                    load_report = load_report,
                },
                true
            )
        end
        load_report.slots[#load_report.slots + 1] = slot_report(
            1,
            'FAILED',
            { error_code = slot1.error and slot1.error.code }
        )
        return fail(
            SaveErrorCodes.SAVE_DOWNLOAD_FAILED,
            'SLOT1_LOAD_FAILED',
            {
                session_instance_id = session_instance_id.value,
                cause_code = slot1.error and slot1.error.code,
                load_report = load_report,
            },
            slot1.error and slot1.error.retryable == true
        )
    end

    local envelope1 = verify_envelope(slot1.value, nil)
    if not envelope1.ok then
        load_report.slots[#load_report.slots + 1] = slot_report(
            1,
            'CORRUPT',
            { reason = envelope1.error and envelope1.error.details and envelope1.error.details.reason }
        )
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'SLOT1_CORRUPT',
            {
                session_instance_id = session_instance_id.value,
                load_report = load_report,
                cause = envelope1.error and envelope1.error.details,
            },
            false
        )
    end

    local slot_one = SaveEnvelope.validate_slot_one_payload(envelope1.value.payload)
    if not slot_one.ok then
        load_report.slots[#load_report.slots + 1] = slot_report(1, 'CORRUPT')
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'SLOT1_PAYLOAD_SECTIONS_INVALID',
            {
                session_instance_id = session_instance_id.value,
                load_report = load_report,
            },
            false
        )
    end

    local manifest = SaveManifest.validate(envelope1.value.payload.manifest)
    if not manifest.ok then
        load_report.slots[#load_report.slots + 1] = slot_report(1, 'CORRUPT')
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'MANIFEST_INVALID',
            {
                session_instance_id = session_instance_id.value,
                load_report = load_report,
                cause = manifest.error and manifest.error.details,
            },
            false
        )
    end

    local profile = PlayerProfile.validate(envelope1.value.payload.player_profile)
    if not profile.ok then
        load_report.slots[#load_report.slots + 1] = slot_report(1, 'CORRUPT')
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'PLAYER_PROFILE_INVALID',
            {
                session_instance_id = session_instance_id.value,
                load_report = load_report,
            },
            false
        )
    end

    local expected_fingerprint = SaveEnvelope.owner_fingerprint_for_scope(
        profile.value.player_save_scope
    )
    if not expected_fingerprint.ok then
        return expected_fingerprint
    end
    if envelope1.value.owner_fingerprint ~= expected_fingerprint.value then
        load_report.slots[#load_report.slots + 1] = slot_report(1, 'OWNER_MISMATCH')
        return fail(
            SaveErrorCodes.SAVE_OWNER_MISMATCH,
            'SLOT1_OWNER_FINGERPRINT_MISMATCH',
            {
                session_instance_id = session_instance_id.value,
                expected = expected_fingerprint.value,
                actual = envelope1.value.owner_fingerprint,
                load_report = load_report,
            },
            false
        )
    end

    -- Manifest commit marker must equal the slot 1 envelope checkpoint for a
    -- committed private checkpoint.
    if envelope1.value.checkpoint_id ~= manifest.value.checkpoint_id then
        load_report.slots[#load_report.slots + 1] = slot_report(
            1,
            'CORRUPT',
            { reason = 'MANIFEST_CHECKPOINT_MISMATCH' }
        )
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'MANIFEST_CHECKPOINT_MISMATCH',
            {
                session_instance_id = session_instance_id.value,
                envelope_checkpoint_id = envelope1.value.checkpoint_id,
                manifest_checkpoint_id = manifest.value.checkpoint_id,
                load_report = load_report,
            },
            false
        )
    end

    load_report.slots[#load_report.slots + 1] = slot_report(1, 'FOUND', {
        revision = envelope1.value.revision,
        checkpoint_id = envelope1.value.checkpoint_id,
        schema_version = envelope1.value.schema_version,
        checksum_status = 'MATCHED',
    })

    local loaded_envelopes = {
        [1] = copy_table(envelope1.value),
    }
    local orphan_slots = {}
    local recovery_reasons = {}
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

        if not loaded.ok then
            if loaded.error and loaded.error.code == 'SAVE_NOT_FOUND' then
                if expected.value.is_absent then
                    load_report.slots[#load_report.slots + 1] = slot_report(
                        slot_id,
                        'CONFIRMED_ABSENT',
                        {
                            revision = 0,
                            checksum_status = 'ABSENT_OK',
                        }
                    )
                else
                    load_report.slots[#load_report.slots + 1] = slot_report(
                        slot_id,
                        'MISSING_REQUIRED',
                        {
                            expected_revision = expected.value.revision,
                            expected_checkpoint_id = expected.value.checkpoint_id,
                        }
                    )
                    recovery_reasons[#recovery_reasons + 1] = {
                        slot_id = slot_id,
                        reason = 'REQUIRED_SLOT_MISSING',
                    }
                end
            elseif loaded.error
                and (loaded.error.code == 'PLATFORM_UNAVAILABLE'
                    or loaded.error.code == 'PLATFORM_RATE_LIMITED'
                    or loaded.error.code == 'PLATFORM_RESULT_UNKNOWN')
            then
                load_report.slots[#load_report.slots + 1] = slot_report(
                    slot_id,
                    'TEMPORARY_FAILURE',
                    { error_code = loaded.error.code }
                )
                return fail(
                    SaveErrorCodes.SAVE_DOWNLOAD_FAILED,
                    'DATA_SLOT_TEMPORARY_FAILURE',
                    {
                        slot_id = slot_id,
                        session_instance_id = session_instance_id.value,
                        cause_code = loaded.error.code,
                        load_report = load_report,
                    },
                    true
                )
            else
                load_report.slots[#load_report.slots + 1] = slot_report(
                    slot_id,
                    'FAILED',
                    { error_code = loaded.error and loaded.error.code }
                )
                return fail(
                    SaveErrorCodes.SAVE_DOWNLOAD_FAILED,
                    'DATA_SLOT_LOAD_FAILED',
                    {
                        slot_id = slot_id,
                        session_instance_id = session_instance_id.value,
                        cause_code = loaded.error and loaded.error.code,
                        load_report = load_report,
                    },
                    false
                )
            end
        else
            local verified = verify_envelope(
                loaded.value,
                expected_fingerprint.value
            )
            if not verified.ok then
                load_report.slots[#load_report.slots + 1] = slot_report(
                    slot_id,
                    'CORRUPT',
                    {
                        reason = verified.error
                            and verified.error.details
                            and verified.error.details.reason,
                    }
                )
                recovery_reasons[#recovery_reasons + 1] = {
                    slot_id = slot_id,
                    reason = 'SLOT_CORRUPT',
                }
            else
                local actual_revision = verified.value.revision
                local actual_checkpoint = verified.value.checkpoint_id
                local actual_checksum = verified.value.payload_checksum
                local matches = actual_revision == expected.value.revision
                    and actual_checkpoint == expected.value.checkpoint_id
                    and actual_checksum == expected.value.payload_checksum

                if expected.value.is_absent then
                    -- A written data slot that Manifest still marks absent is an
                    -- orphan candidate from a crash before Manifest-last.
                    load_report.slots[#load_report.slots + 1] = slot_report(
                        slot_id,
                        'ORPHAN_SLOT_WRITE',
                        {
                            observed_revision = actual_revision,
                            observed_checkpoint_id = actual_checkpoint,
                            observed_payload_checksum = actual_checksum,
                            manifest_checkpoint_id = manifest.value.checkpoint_id,
                        }
                    )
                    orphan_slots[#orphan_slots + 1] = slot_id
                    recovery_reasons[#recovery_reasons + 1] = {
                        slot_id = slot_id,
                        reason = 'ORPHAN_SLOT_WRITE',
                    }
                elseif matches then
                    loaded_envelopes[slot_id] = copy_table(verified.value)
                    load_report.slots[#load_report.slots + 1] = slot_report(
                        slot_id,
                        'FOUND',
                        {
                            revision = actual_revision,
                            checkpoint_id = actual_checkpoint,
                            schema_version = verified.value.schema_version,
                            checksum_status = 'MATCHED',
                        }
                    )
                else
                    load_report.slots[#load_report.slots + 1] = slot_report(
                        slot_id,
                        'ORPHAN_SLOT_WRITE',
                        {
                            expected_revision = expected.value.revision,
                            observed_revision = actual_revision,
                            expected_checkpoint_id = expected.value.checkpoint_id,
                            observed_checkpoint_id = actual_checkpoint,
                            expected_payload_checksum = expected.value.payload_checksum,
                            observed_payload_checksum = actual_checksum,
                            manifest_checkpoint_id = manifest.value.checkpoint_id,
                        }
                    )
                    orphan_slots[#orphan_slots + 1] = slot_id
                    recovery_reasons[#recovery_reasons + 1] = {
                        slot_id = slot_id,
                        reason = 'ORPHAN_SLOT_WRITE',
                    }
                end
            end
        end
    end

    if #recovery_reasons > 0 then
        return result_ok({
            mode = 'RECOVERY_REQUIRED',
            session_instance_id = session_instance_id.value,
            player_ref = player_ref.value,
            player_save_scope = profile.value.player_save_scope,
            committed_manifest_checkpoint = manifest.value.checkpoint_id,
            slot1_revision = envelope1.value.revision,
            manifest = copy_table(manifest.value),
            player_profile = copy_table(profile.value),
            settings_profile = copy_table(envelope1.value.payload.settings_profile),
            loaded_envelopes = loaded_envelopes,
            orphan_slots = orphan_slots,
            recovery_reasons = recovery_reasons,
            load_report = load_report,
            writable = false,
        })
    end

    return result_ok({
        mode = 'READY',
        session_instance_id = session_instance_id.value,
        player_ref = player_ref.value,
        player_save_scope = profile.value.player_save_scope,
        committed_manifest_checkpoint = manifest.value.checkpoint_id,
        slot1_revision = envelope1.value.revision,
        save_seed = manifest.value.save_seed,
        recovery_epoch = manifest.value.recovery_epoch,
        manifest = copy_table(manifest.value),
        player_profile = copy_table(profile.value),
        settings_profile = copy_table(envelope1.value.payload.settings_profile),
        loaded_envelopes = loaded_envelopes,
        orphan_slots = {},
        recovery_reasons = {},
        load_report = load_report,
        writable = true,
    })
end

return LoadGameSave
