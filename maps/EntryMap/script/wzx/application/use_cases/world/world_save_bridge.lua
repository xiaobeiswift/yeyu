-- System 12 world slot-2 save bridge.
-- Persists world_* sections (including world_position.last_landing_receipt_id)
-- through SaveCoordinator critical checkpoints. Systems never call SaveStore.
-- Traversal landings also register system-18 save_recovery_transactions on slot 5
-- that only REFERENCE landing_receipt_id (never re-derive it).

local CreateNewSave = require 'wzx.application.use_cases.save.create_new_save'
local RecoveryJournal = require 'wzx.domain.save.recovery_journal'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveCheckpoint = require 'wzx.application.use_cases.save.save_checkpoint'
local SlotPayloadUtil = require 'wzx.application.save.slot_payload_util'

local WorldSaveBridge = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_component = RuntimeId.validate_component

local Bridge = {}
Bridge.__index = Bridge
Bridge.__newindex = function()
    error_value('world save bridge is read-only', 2)
end
Bridge.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local DEFAULT_SAVE_SEED = 1

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.world.save_bridge_' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid_argument(reason, details)
    return fail('INVALID_ARGUMENT', reason, details, false)
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math.floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function ensure_slot1_context(state, player_ref, player_save_scope, request_id, input)
    local context = SlotPayloadUtil.load_slot1_context(
        state.coordinator,
        state.save_invoke,
        player_ref,
        request_id .. '_slot1'
    )
    if not context.ok then
        return context
    end
    if context.value.present then
        return context
    end
    if state.auto_create_save ~= true then
        return fail(
            'SAVE_NOT_READY',
            'SLOT1_REQUIRED_BEFORE_WORLD_PERSIST',
            { player_ref = player_ref },
            false
        )
    end
    local save_seed = raw_get(input, 'save_seed') or state.default_save_seed
    if not is_safe_integer(save_seed, 1, 2147483646) then
        return invalid_argument('SAVE_SEED_INVALID', { field = 'save_seed' })
    end
    local created = state.create_new_save:create({
        player_ref = player_ref,
        player_save_scope = player_save_scope,
        command_id = raw_get(input, 'create_command_id')
            or (request_id .. '_create'),
        request_id = request_id .. '_create',
        save_seed = save_seed,
        content_version = raw_get(input, 'content_version') or 'content-v1',
    }, state.save_invoke)
    if not created.ok then
        return created
    end
    return result_ok({
        present = true,
        base_slot1_revision = created.value.slot1_revision,
        base_manifest = created.value.manifest,
        player_profile = created.value.player_profile,
        settings_profile = created.value.settings_profile,
        player_save_scope = created.value.player_save_scope,
        committed_manifest_checkpoint = created.value.checkpoint_id,
        created_now = true,
    })
end

function Bridge:persist_player_world(input)
    local state = STATES[self]
    if state == nil then
        return invalid_argument('BRIDGE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED', { field = 'input' })
    end

    local player_save_scope = validate_component(
        raw_get(input, 'player_save_scope'),
        'player_save_scope'
    )
    if not player_save_scope.ok then
        return invalid_argument('PLAYER_SAVE_SCOPE_INVALID', {
            field = 'player_save_scope',
        })
    end
    local player_ref = validate_component(
        raw_get(input, 'player_ref') or player_save_scope.value,
        'player_ref'
    )
    if not player_ref.ok then
        return invalid_argument('PLAYER_REF_INVALID', { field = 'player_ref' })
    end
    local request_id = raw_get(input, 'request_id') or 'request_world_save'

    local bundle = raw_get(input, 'bundle')
    if bundle == nil then
        local exported = state.store:export_save_bundle()
        if not exported.ok then
            return exported
        end
        bundle = exported.value
    end
    if type_value(bundle) ~= 'table' or get_metatable(bundle) ~= nil then
        return invalid_argument('WORLD_BUNDLE_INVALID', { field = 'bundle' })
    end
    if type_value(bundle.world_position) ~= 'table' then
        return invalid_argument('WORLD_POSITION_REQUIRED', {
            field = 'bundle.world_position',
        })
    end

    local slot1 = ensure_slot1_context(
        state,
        player_ref.value,
        player_save_scope.value,
        request_id,
        input
    )
    if not slot1.ok then
        return slot1
    end
    if slot1.value.player_save_scope ~= player_save_scope.value then
        return fail(
            'SAVE_OWNER_MISMATCH',
            'PLAYER_SAVE_SCOPE_MISMATCH',
            {
                expected = player_save_scope.value,
                actual = slot1.value.player_save_scope,
            },
            false
        )
    end

    local slot2 = SlotPayloadUtil.load_slot_state(
        state.coordinator,
        state.save_invoke,
        player_ref.value,
        2,
        request_id .. '_load2'
    )
    if not slot2.ok then
        return slot2
    end

    -- Slot 2 is shared among world-owned sections only for system 12 offline.
    -- Merge replaces world_* sections; never whole-slot overwrite of foreign keys.
    local merged_slot2 = SlotPayloadUtil.merge_sections(slot2.value.payload, {
        world_metadata = bundle.world_metadata,
        world_position = bundle.world_position,
        world_discovered_locations = bundle.world_discovered_locations,
        world_flags = bundle.world_flags,
        world_event_receipts = bundle.world_event_receipts,
        world_interactable_states = bundle.world_interactable_states,
    })
    if not merged_slot2.ok then
        return merged_slot2
    end

    local command_id = raw_get(input, 'command_id') or (request_id .. '_ckpt')
    local reason = raw_get(input, 'reason') or 'WORLD_CRITICAL_CHECKPOINT'
    local landing_receipt_id = raw_get(input, 'landing_receipt_id')
        or (bundle.world_position and bundle.world_position.last_landing_receipt_id)
    local dirty_slots = {
        {
            slot_id = 2,
            expected_revision = slot2.value.expected_revision,
            payload = merged_slot2.value,
        },
    }

    local recovery_row = nil
    local recovery_rows = nil
    local preallocated_checkpoint = nil
    local recovery_transaction_id = nil

    if reason == 'TRAVERSAL_LANDING_CRITICAL' then
        if type_value(landing_receipt_id) ~= 'string' or landing_receipt_id == '' then
            return invalid_argument('LANDING_RECEIPT_REQUIRED', {
                field = 'landing_receipt_id',
            })
        end
        local checkpoint = state.coordinator:allocate_checkpoint_id('checkpoint')
        if not checkpoint.ok then
            return checkpoint
        end
        preallocated_checkpoint = checkpoint.value

        local recovery_tx = state.coordinator:allocate_transaction_id('recovery')
        if not recovery_tx.ok then
            return recovery_tx
        end
        recovery_transaction_id = recovery_tx.value

        local landing_command_id = raw_get(input, 'landing_command_id')
            or raw_get(input, 'active_segment_command_id')
            or command_id
        local built = RecoveryJournal.build_traversal_landing_row({
            transaction_id = recovery_transaction_id,
            business_receipt_id = landing_receipt_id,
            target_checkpoint_id = preallocated_checkpoint,
            command_id = landing_command_id,
            outcome_digest = raw_get(input, 'outcome_digest'),
            state = 'COMMITTED',
            retry_count = 0,
        })
        if not built.ok then
            return built
        end

        local slot5 = SlotPayloadUtil.load_slot_state(
            state.coordinator,
            state.save_invoke,
            player_ref.value,
            5,
            request_id .. '_load5'
        )
        if not slot5.ok then
            return slot5
        end

        local existing = slot5.value.payload
            and slot5.value.payload.save_recovery_transactions
        local upserted = RecoveryJournal.upsert_row(existing, built.value)
        if not upserted.ok then
            return upserted
        end
        recovery_row = upserted.value.row
        recovery_rows = upserted.value.rows

        local merged_slot5 = SlotPayloadUtil.merge_sections(slot5.value.payload, {
            save_recovery_transactions = recovery_rows,
        })
        if not merged_slot5.ok then
            return merged_slot5
        end
        dirty_slots[#dirty_slots + 1] = {
            slot_id = 5,
            expected_revision = slot5.value.expected_revision,
            payload = merged_slot5.value,
        }
    end

    local save_input = {
        player_ref = player_ref.value,
        player_save_scope = player_save_scope.value,
        command_id = command_id,
        request_id = request_id,
        base_slot1_revision = slot1.value.base_slot1_revision,
        base_manifest = slot1.value.base_manifest,
        player_profile = slot1.value.player_profile,
        settings_profile = slot1.value.settings_profile,
        content_version = raw_get(input, 'content_version') or 'content-v1',
        dirty_slots = dirty_slots,
    }
    if preallocated_checkpoint ~= nil then
        save_input.checkpoint_id = preallocated_checkpoint
    end
    local saved = state.save_checkpoint:save(save_input, state.save_invoke)
    if not saved.ok then
        return saved
    end

    local advanced = saved.value.status == 'COMMITTED' and 1 or 0
    local slot5_revision = nil
    if #dirty_slots > 1 then
        slot5_revision = dirty_slots[2].expected_revision + advanced
    end
    return result_ok({
        status = saved.value.status,
        checkpoint_id = saved.value.checkpoint_id,
        transaction_id = saved.value.manifest_transaction_id,
        data_transaction_id = saved.value.data_transaction_id,
        recovery_transaction_id = recovery_transaction_id,
        slot2_revision = slot2.value.expected_revision + advanced,
        slot5_revision = slot5_revision,
        slot1_revision = saved.value.slot1_revision,
        manifest = saved.value.manifest,
        bundle = bundle,
        last_landing_receipt_id = landing_receipt_id
            or (bundle.world_position
                and bundle.world_position.last_landing_receipt_id),
        recovery_row = recovery_row,
        recovery_rows = recovery_rows,
        created_save = slot1.value.created_now == true,
        reason = reason,
    })
end

function WorldSaveBridge.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid_argument('OPTIONS_REQUIRED')
    end
    local store = raw_get(options, 'store')
    local coordinator = raw_get(options, 'coordinator')
    local save_invoke = raw_get(options, 'save_invoke')
    local auto_create_save = raw_get(options, 'auto_create_save')
    if auto_create_save == nil then
        auto_create_save = true
    end
    local default_save_seed = raw_get(options, 'default_save_seed')
        or DEFAULT_SAVE_SEED

    if type_value(store) ~= 'table'
        or type_value(store.export_save_bundle) ~= 'function'
    then
        return invalid_argument('STORE_REQUIRED', { field = 'store' })
    end
    if type_value(coordinator) ~= 'table'
        or type_value(coordinator.write_slots) ~= 'function'
        or type_value(coordinator.load_slot) ~= 'function'
    then
        return invalid_argument('SAVE_COORDINATOR_REQUIRED', {
            field = 'coordinator',
        })
    end
    if type_value(save_invoke) ~= 'function' then
        return invalid_argument('SAVE_INVOKE_REQUIRED', {
            field = 'save_invoke',
        })
    end
    if not is_safe_integer(default_save_seed, 1, 2147483646) then
        return invalid_argument('DEFAULT_SAVE_SEED_INVALID', {
            field = 'default_save_seed',
        })
    end

    local create_new_save = raw_get(options, 'create_new_save')
    if create_new_save == nil then
        local bound = CreateNewSave.bind({ coordinator = coordinator })
        if not bound.ok then
            return bound
        end
        create_new_save = bound.value
    end
    local save_checkpoint = raw_get(options, 'save_checkpoint')
    if save_checkpoint == nil then
        local bound = SaveCheckpoint.bind({ coordinator = coordinator })
        if not bound.ok then
            return bound
        end
        save_checkpoint = bound.value
    end

    local bridge = set_metatable({}, Bridge)
    STATES[bridge] = {
        store = store,
        coordinator = coordinator,
        save_invoke = save_invoke,
        create_new_save = create_new_save,
        save_checkpoint = save_checkpoint,
        auto_create_save = auto_create_save == true,
        default_save_seed = default_save_seed,
    }
    return result_ok(bridge)
end

function WorldSaveBridge.is_authority(value)
    return STATES[value] ~= nil
end

return WorldSaveBridge
