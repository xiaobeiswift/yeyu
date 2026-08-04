local PlayerProfile = require 'wzx.domain.save.player_profile'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'
local SaveManifest = require 'wzx.domain.save.save_manifest'
local SlotRevisionVector = require 'wzx.domain.save.slot_revision_vector'
local TableShape = require 'wzx.domain.common.table_shape'

local CreateNewSave = {}
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
    error_value('create new save service is read-only', 2)
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

function CreateNewSave.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local coordinator = raw_get(options, 'coordinator')
    if type_value(coordinator) ~= 'table'
        or type_value(coordinator.write_slots) ~= 'function'
        or type_value(coordinator.load_slot) ~= 'function'
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

local function default_settings_profile()
    return {
        schema_version = 1,
        revision = 0,
    }
end

function Service:create(input, invoke)
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
        raw_get(input, 'player_save_scope') or player_ref.value,
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
    local save_seed = raw_get(input, 'save_seed')
    if not is_integer(save_seed, 1, 2147483646) then
        return invalid('SAVE_SEED_INVALID', { field = 'save_seed' })
    end
    local request_id = validate_component(
        raw_get(input, 'request_id') or command_id.value,
        'request_id'
    )
    if not request_id.ok then
        return invalid('REQUEST_ID_INVALID', { field = 'request_id' })
    end

    -- Only create when slot 1 is platform-confirmed absent.
    local existing = state.coordinator:load_slot({
        player_ref = player_ref.value,
        slot_id = 1,
        request_id = request_id.value .. '_probe',
        correlation_id = request_id.value,
    }, invoke)
    if existing.ok then
        return fail(
            SaveErrorCodes.SAVE_EXISTENCE_UNKNOWN,
            'SLOT1_ALREADY_PRESENT',
            {
                player_ref = player_ref.value,
                revision = existing.value.revision,
            },
            false
        )
    end
    if not existing.error or existing.error.code ~= 'SAVE_NOT_FOUND' then
        return fail(
            SaveErrorCodes.SAVE_EXISTENCE_UNKNOWN,
            'SLOT1_EXISTENCE_NOT_CONFIRMED_ABSENT',
            {
                player_ref = player_ref.value,
                cause_code = existing.error and existing.error.code,
            },
            existing.error and existing.error.retryable == true
        )
    end

    local checkpoint = state.coordinator:allocate_checkpoint_id('checkpoint')
    if not checkpoint.ok then
        return checkpoint
    end
    local transaction = state.coordinator:allocate_transaction_id('newsave')
    if not transaction.ok then
        return transaction
    end

    local manifest = {
        save_format_version = 1,
        created_revision = 1,
        slot_revision_entries = SlotRevisionVector.empty_entries(),
        checkpoint_id = checkpoint.value,
        save_seed = save_seed,
        feature_flag_snapshot = {},
        recovery_epoch = 0,
    }
    if raw_get(input, 'last_save_server_time') ~= nil then
        if not is_integer(input.last_save_server_time, 0) then
            return invalid('LAST_SAVE_SERVER_TIME_INVALID', {
                field = 'last_save_server_time',
            })
        end
        manifest.last_save_server_time = input.last_save_server_time
    end
    local manifest_ok = SaveManifest.validate(manifest)
    if not manifest_ok.ok then
        return fail(
            SaveErrorCodes.SAVE_CHECKPOINT_INVALID,
            'MANIFEST_BUILD_INVALID',
            { cause = manifest_ok.error and manifest_ok.error.details },
            false
        )
    end

    local profile = {
        schema_version = 1,
        revision = 0,
        player_save_scope = player_save_scope.value,
    }
    if raw_get(input, 'created_at') ~= nil then
        if not is_integer(input.created_at, 0) then
            return invalid('CREATED_AT_INVALID', { field = 'created_at' })
        end
        profile.created_at = input.created_at
    end
    local profile_ok = PlayerProfile.validate(profile)
    if not profile_ok.ok then
        return fail(
            SaveErrorCodes.SAVE_CHECKPOINT_INVALID,
            'PLAYER_PROFILE_BUILD_INVALID',
            { cause = profile_ok.error and profile_ok.error.details },
            false
        )
    end

    local settings = raw_get(input, 'settings_profile') or default_settings_profile()
    if type_value(settings) ~= 'table' or get_metatable(settings) ~= nil then
        return invalid('SETTINGS_PROFILE_INVALID', { field = 'settings_profile' })
    end

    local payload = {
        manifest = manifest_ok.value,
        player_profile = profile_ok.value,
        settings_profile = settings,
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

    local written = state.coordinator:write_slots({
        player_ref = player_ref.value,
        checkpoint_id = checkpoint.value,
        transaction_id = transaction.value,
        request_id = request_id.value,
        content_version = raw_get(input, 'content_version') or 'content-v1',
        written_at = raw_get(input, 'written_at'),
        slot_writes = {
            {
                slot_id = 1,
                expected_revision = 0,
                payload = payload,
            },
        },
    }, invoke)
    if not written.ok then
        return written
    end
    if written.value.status ~= 'COMMITTED' then
        return fail(
            SaveErrorCodes.SAVE_RESULT_UNKNOWN,
            'CREATE_NOT_COMMITTED',
            {
                status = written.value.status,
                phase = written.value.phase,
                pending = written.value.pending,
            },
            true
        )
    end

    return result_ok({
        status = 'COMMITTED',
        player_ref = player_ref.value,
        player_save_scope = player_save_scope.value,
        checkpoint_id = checkpoint.value,
        transaction_id = transaction.value,
        slot1_revision = 1,
        manifest = manifest_ok.value,
        player_profile = profile_ok.value,
        settings_profile = settings,
        command_id = command_id.value,
    })
end

return CreateNewSave
