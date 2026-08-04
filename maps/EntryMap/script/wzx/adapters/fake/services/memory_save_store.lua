local PortContract = require 'wzx.application.ports.port_contract'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local SaveStore = require 'wzx.application.ports.save_store'
local ScriptedPort = require 'wzx.adapters.fake.scripted_port'
local TableShape = require 'wzx.domain.common.table_shape'

local MemorySaveStore = {}
local raw_get = rawget
local type_value = type

local function copy_envelope(envelope)
    local copied = TableShape.deep_copy_serializable(envelope, 4, '$')
    if not copied.ok then
        error('memory save store failed to copy envelope')
    end
    return copied.value
end

function MemorySaveStore.new()
    local committed = {}
    local staged = {}

    local function player_table(map, player_ref)
        local bucket = map[player_ref]
        if bucket == nil then
            bucket = {}
            map[player_ref] = bucket
        end
        return bucket
    end

    local function load_handler(request)
        local bucket = committed[request.player_ref]
        local envelope = bucket and bucket[request.slot_id] or nil
        if envelope == nil then
            return ScriptedPort.failure('SAVE_NOT_FOUND', {
                player_ref = request.player_ref,
                slot_id = request.slot_id,
                reason = 'SLOT_ABSENT',
            }, false)
        end
        local value = {
            player_ref = request.player_ref,
            slot_id = request.slot_id,
            dto = copy_envelope(envelope),
            revision = envelope.revision,
            checkpoint_id = envelope.checkpoint_id,
            payload_checksum = envelope.payload_checksum,
        }
        return ScriptedPort.success(value)
    end

    local function stage_handler(request)
        local request_key = request.context and request.context.idempotency_key
        local bucket = player_table(committed, request.player_ref)
        local current = bucket[request.slot_id]
        local current_revision = current and current.revision or 0
        if current_revision ~= request.expected_revision then
            return ScriptedPort.failure('SAVE_REVISION_CONFLICT', {
                player_ref = request.player_ref,
                slot_id = request.slot_id,
                expected_revision = request.expected_revision,
                actual_revision = current_revision,
                request_key = request_key,
            }, false)
        end
        local validated = SaveEnvelope.validate(request.dto)
        if not validated.ok then
            return ScriptedPort.failure('PORT_REQUEST_INVALID', {
                field = 'dto',
                reason = 'SAVE_ENVELOPE_REQUIRED',
                request_key = request_key,
            }, false)
        end
        local stage_bucket = player_table(staged, request.player_ref)
        stage_bucket[request.slot_id] = copy_envelope(request.dto)
        return ScriptedPort.success({
            player_ref = request.player_ref,
            slot_id = request.slot_id,
            revision = request.dto.revision,
            checkpoint_id = request.dto.checkpoint_id,
            payload_checksum = request.dto.payload_checksum,
            request_key = request_key,
        })
    end

    local function commit_handler(request)
        local request_key = request.context and request.context.idempotency_key
        local stage_bucket = staged[request.player_ref] or {}
        local commit_bucket = player_table(committed, request.player_ref)
        local slot_results = {}
        local index
        for index = 1, #request.commit_entries do
            local entry = request.commit_entries[index]
            local staged_envelope = stage_bucket[entry.slot_id]
            if staged_envelope == nil then
                return ScriptedPort.failure('PORT_REQUEST_INVALID', {
                    field = 'commit_entries',
                    reason = 'STAGED_SLOT_MISSING',
                    slot_id = entry.slot_id,
                    request_key = request_key,
                }, false)
            end
            if staged_envelope.revision ~= entry.target_revision
                or staged_envelope.checkpoint_id ~= entry.checkpoint_id
                or staged_envelope.payload_checksum ~= entry.payload_checksum
            then
                return ScriptedPort.failure('PORT_REQUEST_INVALID', {
                    field = 'commit_entries',
                    reason = 'STAGED_SLOT_MISMATCH',
                    slot_id = entry.slot_id,
                    request_key = request_key,
                }, false)
            end
            commit_bucket[entry.slot_id] = copy_envelope(staged_envelope)
            stage_bucket[entry.slot_id] = nil
            slot_results[index] = {
                slot_id = entry.slot_id,
                status = 'CONFIRMED',
                target_revision = entry.target_revision,
                checkpoint_id = entry.checkpoint_id,
                payload_checksum = entry.payload_checksum,
            }
        end
        return ScriptedPort.success({
            player_ref = request.player_ref,
            status = 'CONFIRMED',
            slot_results = slot_results,
            request_key = request_key,
        })
    end

    local fake = ScriptedPort.new(SaveStore, {
        default_steps = {
            load_slot = load_handler,
            stage_slot = stage_handler,
            commit = commit_handler,
            upload = function(request)
                return ScriptedPort.success({
                    player_ref = request.player_ref,
                    status = 'CONFIRMED',
                    request_key = request.context.idempotency_key,
                })
            end,
            read_integer = function(request)
                return ScriptedPort.failure('SAVE_NOT_FOUND', {
                    player_ref = request.player_ref,
                    slot_id = request.slot_id,
                }, false)
            end,
            compare_and_add_integer = function(request)
                return ScriptedPort.failure('PLATFORM_UNAVAILABLE', {
                    reason = 'INTEGER_SLOTS_DISABLED_IN_MEMORY_STORE',
                }, true)
            end,
            compare_and_set_integer = function(request)
                return ScriptedPort.failure('PLATFORM_UNAVAILABLE', {
                    reason = 'INTEGER_SLOTS_DISABLED_IN_MEMORY_STORE',
                }, true)
            end,
            query_integer_request = function(request)
                return ScriptedPort.success({
                    player_ref = request.player_ref,
                    slot_id = request.slot_id,
                    original_idempotency_key = request.original_idempotency_key,
                    status = 'NOT_FOUND',
                })
            end,
        },
    })

    function fake:get_committed_snapshot()
        local snapshot = {}
        local player_ref
        local player_bucket
        for player_ref, player_bucket in pairs(committed) do
            local slots = {}
            local slot_id
            local envelope
            for slot_id, envelope in pairs(player_bucket) do
                slots[slot_id] = copy_envelope(envelope)
            end
            snapshot[player_ref] = slots
        end
        return snapshot
    end

    return fake
end

return MemorySaveStore
