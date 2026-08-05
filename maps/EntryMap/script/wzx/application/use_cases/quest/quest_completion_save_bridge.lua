-- Offline multi-slot checkpoint for system 14 quest completion / turn-in.
-- After in-memory owner mutations (inventory consume, economy grant, quest COMPLETED),
-- writes one SaveCheckpoint covering:
--   slot 2 quest sections
--   slot 4 economy balances + inventory stacks (when stores provided)
--   slot 5 economy receipts (when economy store provided)
-- Parent sagas pass skip_save=true to owner services so they do not stage partial
-- cloud writes. Not a full ADR-0002 PREPARED child-receipt recovery saga yet.

local CreateNewSave = require 'wzx.application.use_cases.save.create_new_save'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveCheckpoint = require 'wzx.application.use_cases.save.save_checkpoint'
local SlotPayloadUtil = require 'wzx.application.save.slot_payload_util'

local QuestCompletionSaveBridge = {}
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
    error_value('quest completion save bridge is read-only', 2)
end
Bridge.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local DEFAULT_SAVE_SEED = 1

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.quest.completion_save_bridge_' .. string.lower(code),
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
            'SLOT1_REQUIRED_BEFORE_QUEST_COMPLETION_PERSIST',
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

function Bridge:persist_completion(input)
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
    local request_id = raw_get(input, 'request_id') or 'request_quest_completion_save'

    local quest_bundle = raw_get(input, 'quest_bundle')
    if quest_bundle == nil then
        local exported = state.quest_store:export_save_bundle()
        if not exported.ok then
            return exported
        end
        quest_bundle = exported.value
    end
    if type_value(quest_bundle) ~= 'table'
        or get_metatable(quest_bundle) ~= nil
        or type_value(quest_bundle.quest_metadata) ~= 'table'
    then
        return invalid_argument('QUEST_BUNDLE_INVALID', { field = 'quest_bundle' })
    end

    local economy_bundles = nil
    if state.economy_store ~= nil then
        local exported = state.economy_store:export_save_bundles()
        if not exported.ok then
            return exported
        end
        economy_bundles = exported.value
    end

    local inventory_bundle = nil
    if state.inventory_store ~= nil then
        local exported = state.inventory_store:export_save_bundle()
        if not exported.ok then
            return exported
        end
        inventory_bundle = exported.value
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

    local dirty_slots = {}
    local slot2_expected = nil
    local slot4_expected = nil
    local slot5_expected = nil

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
    slot2_expected = slot2.value.expected_revision
    local merged_slot2 = SlotPayloadUtil.merge_sections(slot2.value.payload, {
        quest_metadata = quest_bundle.quest_metadata,
        quest_runs = quest_bundle.quest_runs,
        quest_objectives = quest_bundle.quest_objectives,
        quest_event_receipts = quest_bundle.quest_event_receipts,
        revealed_hidden_quests = quest_bundle.revealed_hidden_quests,
        tracked_quest_runs = quest_bundle.tracked_quest_runs,
    })
    if not merged_slot2.ok then
        return merged_slot2
    end
    dirty_slots[#dirty_slots + 1] = {
        slot_id = 2,
        expected_revision = slot2_expected,
        payload = merged_slot2.value,
    }

    if economy_bundles ~= nil or inventory_bundle ~= nil then
        local slot4 = SlotPayloadUtil.load_slot_state(
            state.coordinator,
            state.save_invoke,
            player_ref.value,
            4,
            request_id .. '_load4'
        )
        if not slot4.ok then
            return slot4
        end
        slot4_expected = slot4.value.expected_revision
        local section_updates = {}
        if economy_bundles ~= nil then
            section_updates.economy_metadata = economy_bundles.slot4.economy_metadata
            section_updates.currency_balance_rows =
                economy_bundles.slot4.currency_balance_rows
        end
        if inventory_bundle ~= nil then
            section_updates.inventory_metadata = inventory_bundle.inventory_metadata
            section_updates.inventory_stack_rows =
                inventory_bundle.inventory_stack_rows
        end
        local merged_slot4 = SlotPayloadUtil.merge_sections(
            slot4.value.payload,
            section_updates
        )
        if not merged_slot4.ok then
            return merged_slot4
        end
        dirty_slots[#dirty_slots + 1] = {
            slot_id = 4,
            expected_revision = slot4_expected,
            payload = merged_slot4.value,
        }
    end

    if economy_bundles ~= nil then
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
        slot5_expected = slot5.value.expected_revision
        local merged_slot5 = SlotPayloadUtil.merge_sections(slot5.value.payload, {
            economy_receipt_metadata =
                economy_bundles.slot5.economy_receipt_metadata,
            economy_reward_receipts =
                economy_bundles.slot5.economy_reward_receipts,
            economy_source_occurrences =
                economy_bundles.slot5.economy_source_occurrences,
        })
        if not merged_slot5.ok then
            return merged_slot5
        end
        dirty_slots[#dirty_slots + 1] = {
            slot_id = 5,
            expected_revision = slot5_expected,
            payload = merged_slot5.value,
        }
    end

    local command_id = raw_get(input, 'command_id') or (request_id .. '_ckpt')
    local saved = state.save_checkpoint:save({
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
    }, state.save_invoke)
    if not saved.ok then
        return saved
    end

    local advanced = saved.value.status == 'COMMITTED' and 1 or 0
    return result_ok({
        status = saved.value.status,
        checkpoint_id = saved.value.checkpoint_id,
        transaction_id = saved.value.manifest_transaction_id,
        data_transaction_id = saved.value.data_transaction_id,
        slot1_revision = saved.value.slot1_revision,
        slot2_revision = slot2_expected + advanced,
        slot4_revision = slot4_expected ~= nil
            and (slot4_expected + advanced)
            or nil,
        slot5_revision = slot5_expected ~= nil
            and (slot5_expected + advanced)
            or nil,
        manifest = saved.value.manifest,
        quest_bundle = quest_bundle,
        economy_bundles = economy_bundles,
        inventory_bundle = inventory_bundle,
        created_save = slot1.value.created_now == true,
        multi_slot = true,
        dirty_slot_count = #dirty_slots,
    })
end

function QuestCompletionSaveBridge.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid_argument('OPTIONS_REQUIRED')
    end
    local quest_store = raw_get(options, 'quest_store')
    local economy_store = raw_get(options, 'economy_store')
    local inventory_store = raw_get(options, 'inventory_store')
    local coordinator = raw_get(options, 'coordinator')
    local save_invoke = raw_get(options, 'save_invoke')
    local auto_create_save = raw_get(options, 'auto_create_save')
    if auto_create_save == nil then
        auto_create_save = true
    end
    local default_save_seed = raw_get(options, 'default_save_seed')
        or DEFAULT_SAVE_SEED

    if type_value(quest_store) ~= 'table'
        or type_value(quest_store.export_save_bundle) ~= 'function'
    then
        return invalid_argument('QUEST_STORE_REQUIRED', { field = 'quest_store' })
    end
    if economy_store ~= nil
        and (
            type_value(economy_store) ~= 'table'
            or type_value(economy_store.export_save_bundles) ~= 'function'
        )
    then
        return invalid_argument('ECONOMY_STORE_INVALID', {
            field = 'economy_store',
        })
    end
    if inventory_store ~= nil
        and (
            type_value(inventory_store) ~= 'table'
            or type_value(inventory_store.export_save_bundle) ~= 'function'
        )
    then
        return invalid_argument('INVENTORY_STORE_INVALID', {
            field = 'inventory_store',
        })
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
        quest_store = quest_store,
        economy_store = economy_store,
        inventory_store = inventory_store,
        coordinator = coordinator,
        save_invoke = save_invoke,
        create_new_save = create_new_save,
        save_checkpoint = save_checkpoint,
        auto_create_save = auto_create_save == true,
        default_save_seed = default_save_seed,
    }
    return result_ok(bridge)
end

function QuestCompletionSaveBridge.is_authority(value)
    return STATES[value] ~= nil
end

return QuestCompletionSaveBridge
