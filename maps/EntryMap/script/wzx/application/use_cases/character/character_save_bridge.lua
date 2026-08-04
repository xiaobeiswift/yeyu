local CharacterReceiptCodec = require 'wzx.domain.character.character_receipt_codec'
local CharacterSaveCodec = require 'wzx.domain.character.character_save_codec'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'

local CharacterSaveBridge = {}
local bytewise_string_less = Ordered.bytewise_string_less
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local table_sort = table.sort
local type_value = type
local validate_component = RuntimeId.validate_component

local Bridge = {}
Bridge.__index = Bridge
Bridge.__newindex = function()
    error_value('character save bridge is read-only', 2)
end
Bridge.__metatable = false

local STATES = setmetatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.character.save_bridge_' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid_argument(reason, details)
    return fail('INVALID_ARGUMENT', reason, details, false)
end

local function character_less(left, right)
    return bytewise_string_less(left.character_id, right.character_id)
end

local function talent_less(left, right)
    if left.character_id ~= right.character_id then
        return bytewise_string_less(left.character_id, right.character_id)
    end
    return bytewise_string_less(left.talent_id, right.talent_id)
end

local function receipt_less(left, right)
    return bytewise_string_less(left.receipt_id, right.receipt_id)
end

local function copy_state(state)
    local talent_ids = {}
    local index
    for index = 1, #state.unlocked_talent_ids do
        talent_ids[index] = state.unlocked_talent_ids[index]
    end
    local copied = {
        character_id = state.character_id,
        definition_version = state.definition_version,
        level = state.level,
        experience = state.experience,
        awakening_rank = state.awakening_rank,
        unlocked_talent_ids = talent_ids,
        created_receipt_id = state.created_receipt_id,
        revision = state.revision,
    }
    if state.custom_name ~= nil then
        copied.custom_name = state.custom_name
    end
    return copied
end

local function load_expected_revision(coordinator, save_invoke, player_ref, slot_id, request_id)
    local loaded = coordinator:load_slot({
        player_ref = player_ref,
        slot_id = slot_id,
        request_id = request_id,
        correlation_id = request_id,
    }, save_invoke)
    if loaded.ok then
        return result_ok(loaded.value.revision)
    end
    if loaded.error and loaded.error.code == 'SAVE_NOT_FOUND' then
        return result_ok(0)
    end
    return loaded
end

function Bridge:snapshot_from_repository(player_save_scope)
    local state = STATES[self]
    if state == nil then
        return invalid_argument('BRIDGE_AUTHORITY_REQUIRED')
    end
    local repository = state.repository
    if type_value(repository.get_authority_snapshot) ~= 'function' then
        return fail(
            'REPOSITORY_SNAPSHOT_UNSUPPORTED',
            'GET_AUTHORITY_SNAPSHOT_REQUIRED',
            nil,
            false
        )
    end
    local authority = repository:get_authority_snapshot()
    local player = authority.players and authority.players[player_save_scope]
    if player == nil then
        return result_ok({
            revision = 0,
            character_states = {},
            talent_unlock_rows = {},
            character_save_revision = 0,
            receipt_save_revision = 0,
            receipt_rows = {},
        })
    end

    local states = {}
    local character_id
    local character_state
    for character_id, character_state in pairs(player.characters or {}) do
        states[#states + 1] = copy_state(character_state)
    end
    table_sort(states, character_less)

    local talent_rows = {}
    local index
    for index = 1, #states do
        local row = states[index]
        local talent_index
        for talent_index = 1, #row.unlocked_talent_ids do
            talent_rows[#talent_rows + 1] = {
                character_id = row.character_id,
                talent_id = row.unlocked_talent_ids[talent_index],
                unlocked_revision = 0,
            }
        end
    end
    table_sort(talent_rows, talent_less)

    local receipt_rows = {}
    local receipt_id
    local transaction
    for receipt_id, transaction in pairs(authority.receipts or {}) do
        if transaction.player_save_scope == player_save_scope
            and transaction.status == 'COMMITTED'
        then
            local changed = transaction.expected_character_save_revision
                ~= transaction.character_save_revision
            receipt_rows[#receipt_rows + 1] = {
                receipt_id = transaction.receipt_id,
                transaction_id = transaction.transaction_id,
                operation_type = transaction.operation_type,
                payload_hash = transaction.command_digest,
                expected_result_digest = transaction.result_digest,
                transport_request_key = transaction.request_key,
                status = 'COMMITTED',
                expected_character_save_revision =
                    transaction.expected_character_save_revision,
                target_character_save_revision =
                    transaction.character_save_revision,
                character_state_changed = changed,
                receipt_revision = transaction.receipt_save_revision,
                result_schema_version = 1,
                result_digest = transaction.result_digest,
                result_ref = 'character_result:' .. transaction.receipt_id,
            }
        end
    end
    table_sort(receipt_rows, receipt_less)

    return result_ok({
        revision = player.character_save_revision or 0,
        character_states = states,
        talent_unlock_rows = talent_rows,
        character_save_revision = player.character_save_revision or 0,
        receipt_save_revision = player.receipt_save_revision or 0,
        receipt_rows = receipt_rows,
    })
end

function Bridge:persist_player_characters(input)
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

    local snapshot = self:snapshot_from_repository(player_save_scope.value)
    if not snapshot.ok then
        return snapshot
    end

    local character_bundle = state.codec:encode_current({
        revision = snapshot.value.revision,
        character_states = snapshot.value.character_states,
        talent_unlock_rows = snapshot.value.talent_unlock_rows,
    })
    if not character_bundle.ok then
        return character_bundle
    end

    local receipt_bundle = state.receipt_codec:validate_current({
        character_operation_metadata = {
            schema_version = 1,
            revision = snapshot.value.receipt_save_revision,
        },
        character_operation_receipts = snapshot.value.receipt_rows,
    })
    if not receipt_bundle.ok then
        return receipt_bundle
    end

    local slot3_expected = load_expected_revision(
        state.coordinator,
        state.save_invoke,
        player_ref.value,
        3,
        (raw_get(input, 'request_id') or 'request_character_save') .. '_load3'
    )
    if not slot3_expected.ok then
        return slot3_expected
    end
    local slot5_expected = load_expected_revision(
        state.coordinator,
        state.save_invoke,
        player_ref.value,
        5,
        (raw_get(input, 'request_id') or 'request_character_save') .. '_load5'
    )
    if not slot5_expected.ok then
        return slot5_expected
    end

    local transaction_id = raw_get(input, 'transaction_id')
    if transaction_id == nil then
        local allocated = state.coordinator:allocate_transaction_id('chartx')
        if not allocated.ok then
            return allocated
        end
        transaction_id = allocated.value
    end
    local checkpoint_id = raw_get(input, 'checkpoint_id')
    if checkpoint_id == nil then
        local allocated = state.coordinator:allocate_checkpoint_id(
            'charcheckpoint'
        )
        if not allocated.ok then
            return allocated
        end
        checkpoint_id = allocated.value
    end

    local written = state.coordinator:write_slots({
        player_ref = player_ref.value,
        checkpoint_id = checkpoint_id,
        transaction_id = transaction_id,
        request_id = raw_get(input, 'request_id') or 'request_character_save',
        correlation_id = raw_get(input, 'correlation_id')
            or 'correlation_character_save',
        content_version = raw_get(input, 'content_version') or 'content-v1',
        slot_writes = {
            {
                slot_id = 3,
                expected_revision = slot3_expected.value,
                payload = character_bundle.value,
            },
            {
                slot_id = 5,
                expected_revision = slot5_expected.value,
                payload = receipt_bundle.value,
            },
        },
    }, state.save_invoke)

    if not written.ok then
        return written
    end

    local advanced = written.value.status == 'COMMITTED' and 1 or 0
    return result_ok({
        status = written.value.status,
        checkpoint_id = checkpoint_id,
        transaction_id = transaction_id,
        character_save_revision = snapshot.value.character_save_revision,
        receipt_save_revision = snapshot.value.receipt_save_revision,
        envelope_revision = slot3_expected.value + advanced,
        receipt_envelope_revision = slot5_expected.value + advanced,
        slot_results = written.value.slot_results,
        pending = written.value.pending,
        bundle = character_bundle.value,
        receipt_bundle = receipt_bundle.value,
        error = written.value.error,
    })
end

function CharacterSaveBridge.bind(options)
    if type_value(options) ~= 'table' or getmetatable(options) ~= nil then
        return invalid_argument('OPTIONS_REQUIRED')
    end
    local repository = raw_get(options, 'repository')
    local coordinator = raw_get(options, 'coordinator')
    local save_invoke = raw_get(options, 'save_invoke')
    local codec = raw_get(options, 'codec')
    local receipt_codec = raw_get(options, 'receipt_codec')

    if type_value(repository) ~= 'table' then
        return invalid_argument('REPOSITORY_REQUIRED', {
            field = 'repository',
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
    if codec == nil then
        local bound = CharacterSaveCodec.bind({
            limits_version = 1,
            max_character_rows = 64,
            max_talent_rows = 512,
        })
        if not bound.ok then
            return bound
        end
        codec = bound.value
    elseif not CharacterSaveCodec.is_authority(codec) then
        return invalid_argument('CODEC_AUTHORITY_REQUIRED', {
            field = 'codec',
        })
    end
    if receipt_codec == nil then
        local bound = CharacterReceiptCodec.bind({
            max_receipt_rows = 256,
        })
        if not bound.ok then
            return bound
        end
        receipt_codec = bound.value
    end

    local bridge = set_metatable({}, Bridge)
    STATES[bridge] = {
        repository = repository,
        coordinator = coordinator,
        save_invoke = save_invoke,
        codec = codec,
        receipt_codec = receipt_codec,
    }
    return result_ok(bridge)
end

function CharacterSaveBridge.is_authority(value)
    return STATES[value] ~= nil
end

return CharacterSaveBridge
