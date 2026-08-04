local PlayerProfile = require 'wzx.domain.save.player_profile'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'
local SaveManifest = require 'wzx.domain.save.save_manifest'
local TableShape = require 'wzx.domain.common.table_shape'

local SlotPayloadUtil = {}
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_component = RuntimeId.validate_component

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

function SlotPayloadUtil.copy_payload(payload)
    if payload == nil then
        return result_ok({})
    end
    if type_value(payload) ~= 'table' or get_metatable(payload) ~= nil then
        return invalid('PAYLOAD_TABLE_REQUIRED', { field = 'payload' })
    end
    local copied = TableShape.deep_copy_serializable(payload, 3, '$.payload')
    if not copied.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'PAYLOAD_COPY_FAILED',
            { cause = copied.error },
            false
        )
    end
    return result_ok(copied.value)
end

-- base_payload sections + updates (updates win on same section key).
function SlotPayloadUtil.merge_sections(base_payload, section_updates)
    local base = SlotPayloadUtil.copy_payload(base_payload)
    if not base.ok then
        return base
    end
    if type_value(section_updates) ~= 'table' or get_metatable(section_updates) ~= nil then
        return invalid('SECTION_UPDATES_REQUIRED', {
            field = 'section_updates',
        })
    end
    local merged = base.value
    local key
    local value
    for key, value in raw_next, section_updates do
        if type_value(key) ~= 'string' or key == '' then
            return invalid('SECTION_KEY_INVALID', { field = 'section_updates' })
        end
        local section_copy = TableShape.deep_copy_serializable(
            value,
            2,
            '$.section.' .. key
        )
        if not section_copy.ok then
            return fail(
                SaveErrorCodes.SAVE_CORRUPT,
                'SECTION_COPY_FAILED',
                { section_key = key },
                false
            )
        end
        merged[key] = section_copy.value
    end
    return result_ok(merged)
end

function SlotPayloadUtil.load_slot_state(
    coordinator,
    save_invoke,
    player_ref,
    slot_id,
    request_id
)
    local checked_ref = validate_component(player_ref, 'player_ref')
    if not checked_ref.ok then
        return invalid('PLAYER_REF_INVALID', { field = 'player_ref' })
    end
    local loaded = coordinator:load_slot({
        player_ref = checked_ref.value,
        slot_id = slot_id,
        request_id = request_id,
        correlation_id = request_id,
    }, save_invoke)
    if not loaded.ok then
        if loaded.error and loaded.error.code == 'SAVE_NOT_FOUND' then
            return result_ok({
                present = false,
                expected_revision = 0,
                payload = {},
            })
        end
        return loaded
    end
    local dto = loaded.value.dto
    local validated = SaveEnvelope.validate(dto)
    if not validated.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'SLOT_ENVELOPE_INVALID',
            { slot_id = slot_id },
            false
        )
    end
    local payload = SlotPayloadUtil.copy_payload(dto.payload)
    if not payload.ok then
        return payload
    end
    return result_ok({
        present = true,
        expected_revision = loaded.value.revision,
        payload = payload.value,
        checkpoint_id = loaded.value.checkpoint_id,
        payload_checksum = loaded.value.payload_checksum,
    })
end

function SlotPayloadUtil.load_slot1_context(
    coordinator,
    save_invoke,
    player_ref,
    request_id
)
    local slot1 = SlotPayloadUtil.load_slot_state(
        coordinator,
        save_invoke,
        player_ref,
        1,
        request_id
    )
    if not slot1.ok then
        return slot1
    end
    if not slot1.value.present then
        return result_ok({
            present = false,
        })
    end

    local payload = slot1.value.payload
    local sections = SaveEnvelope.validate_slot_one_payload(payload)
    if not sections.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'SLOT1_SECTIONS_INVALID',
            nil,
            false
        )
    end
    local manifest = SaveManifest.validate(payload.manifest)
    if not manifest.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'MANIFEST_INVALID',
            { cause = manifest.error and manifest.error.details },
            false
        )
    end
    local profile = PlayerProfile.validate(payload.player_profile)
    if not profile.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'PLAYER_PROFILE_INVALID',
            nil,
            false
        )
    end
    local settings = SlotPayloadUtil.copy_payload(payload.settings_profile)
    if not settings.ok then
        return settings
    end

    return result_ok({
        present = true,
        base_slot1_revision = slot1.value.expected_revision,
        base_manifest = manifest.value,
        player_profile = profile.value,
        settings_profile = settings.value,
        player_save_scope = profile.value.player_save_scope,
        committed_manifest_checkpoint = manifest.value.checkpoint_id,
    })
end

return SlotPayloadUtil
