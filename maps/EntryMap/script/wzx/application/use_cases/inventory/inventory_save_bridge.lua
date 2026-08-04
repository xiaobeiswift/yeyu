local CreateNewSave = require 'wzx.application.use_cases.save.create_new_save'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveCheckpoint = require 'wzx.application.use_cases.save.save_checkpoint'
local SlotPayloadUtil = require 'wzx.application.save.slot_payload_util'

local InventorySaveBridge = {}
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
    error_value('inventory save bridge is read-only', 2)
end
Bridge.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local DEFAULT_SAVE_SEED = 1

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.inventory.save_bridge_' .. string.lower(code),
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
            'SLOT1_REQUIRED_BEFORE_INVENTORY_PERSIST',
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

function Bridge:persist_player_inventory(input)
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
    local request_id = raw_get(input, 'request_id') or 'request_inventory_save'

    local bundle = state.store:export_save_bundle()
    if not bundle.ok then
        return bundle
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

    local merged_slot4 = SlotPayloadUtil.merge_sections(slot4.value.payload, {
        inventory_metadata = bundle.value.inventory_metadata,
        inventory_stack_rows = bundle.value.inventory_stack_rows,
    })
    if not merged_slot4.ok then
        return merged_slot4
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
        dirty_slots = {
            {
                slot_id = 4,
                expected_revision = slot4.value.expected_revision,
                payload = merged_slot4.value,
            },
        },
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
        slot4_revision = slot4.value.expected_revision + advanced,
        slot1_revision = saved.value.slot1_revision,
        manifest = saved.value.manifest,
        inventory_bundle = bundle.value,
        created_save = slot1.value.created_now == true,
    })
end

function InventorySaveBridge.bind(options)
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

function InventorySaveBridge.is_authority(value)
    return STATES[value] ~= nil
end

return InventorySaveBridge
