local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local SaveStore = require 'wzx.application.ports.save_store'

local SaveCoordinator = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_derived = RuntimeId.validate_derived

local Coordinator = {}
Coordinator.__index = Coordinator
Coordinator.__newindex = function()
    error_value('save coordinator is read-only', 2)
end
Coordinator.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local TRANSACTION_COUNTER = 0

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.save.coordinator_' .. string.lower(code),
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

local function invoke_port(invoke, operation_name, request)
    if type_value(invoke) ~= 'function' then
        return invalid_argument('INVOKE_REQUIRED', { field = 'invoke' })
    end
    local completion = invoke(operation_name, request)
    if type_value(completion) ~= 'table'
        or type_value(completion.ok) ~= 'boolean'
    then
        return fail(
            'PORT_ADAPTER_FAILED',
            'INVOKE_RESULT_ENVELOPE_INVALID',
            { operation = operation_name },
            false
        )
    end
    return completion
end

local function build_context(request_id, correlation_id, attempt, idempotency_key)
    local context = {
        request_id = request_id,
        correlation_id = correlation_id,
        attempt = attempt,
    }
    if idempotency_key ~= nil then
        context.idempotency_key = idempotency_key
    end
    return context
end

function Coordinator:allocate_transaction_id(prefix)
    local state = STATES[self]
    if state == nil then
        return invalid_argument('COORDINATOR_AUTHORITY_REQUIRED')
    end
    prefix = prefix or 'tx'
    local checked = validate_component(prefix, 'prefix')
    if not checked.ok then
        return invalid_argument('TRANSACTION_PREFIX_INVALID', {
            field = 'prefix',
        })
    end
    state.counter = state.counter + 1
    local value = checked.value .. '_' .. tostring(state.counter)
    local validated = validate_component(value, 'transaction_id')
    if not validated.ok then
        return invalid_argument('TRANSACTION_ID_INVALID', {
            field = 'transaction_id',
            value = value,
        })
    end
    return result_ok(validated.value)
end

function Coordinator:allocate_checkpoint_id(prefix)
    local state = STATES[self]
    if state == nil then
        return invalid_argument('COORDINATOR_AUTHORITY_REQUIRED')
    end
    prefix = prefix or 'checkpoint'
    local checked = validate_component(prefix, 'prefix')
    if not checked.ok then
        return invalid_argument('CHECKPOINT_PREFIX_INVALID', {
            field = 'prefix',
        })
    end
    state.checkpoint_counter = state.checkpoint_counter + 1
    local value = checked.value .. ':' .. tostring(state.checkpoint_counter)
    local validated = validate_derived(value, 'checkpoint_id')
    if not validated.ok then
        return invalid_argument('CHECKPOINT_ID_INVALID', {
            field = 'checkpoint_id',
            value = value,
        })
    end
    return result_ok(validated.value)
end

function Coordinator:build_envelope(options)
    return SaveEnvelope.build(options)
end

local function sort_slot_writes(slot_writes)
    local copy = {}
    local index
    for index = 1, #slot_writes do
        copy[index] = slot_writes[index]
    end
    table.sort(copy, function(left, right)
        return left.slot_id < right.slot_id
    end)
    return copy
end

function Coordinator:write_slots(input, invoke)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED', { field = 'input' })
    end
    local player_ref = validate_component(
        raw_get(input, 'player_ref'),
        'player_ref'
    )
    if not player_ref.ok then
        return invalid_argument('PLAYER_REF_INVALID', { field = 'player_ref' })
    end
    local checkpoint_id = validate_derived(
        raw_get(input, 'checkpoint_id'),
        'checkpoint_id'
    )
    if not checkpoint_id.ok then
        return invalid_argument('CHECKPOINT_ID_INVALID', {
            field = 'checkpoint_id',
        })
    end
    local transaction_id = validate_component(
        raw_get(input, 'transaction_id'),
        'transaction_id'
    )
    if not transaction_id.ok then
        return invalid_argument('TRANSACTION_ID_INVALID', {
            field = 'transaction_id',
        })
    end
    local request_id = validate_component(
        raw_get(input, 'request_id') or 'request_save_write',
        'request_id'
    )
    if not request_id.ok then
        return invalid_argument('REQUEST_ID_INVALID', { field = 'request_id' })
    end
    local correlation_id = validate_component(
        raw_get(input, 'correlation_id') or request_id.value,
        'correlation_id'
    )
    if not correlation_id.ok then
        return invalid_argument('CORRELATION_ID_INVALID', {
            field = 'correlation_id',
        })
    end
    local attempt = raw_get(input, 'attempt') or 1
    if not is_safe_integer(attempt, 1, 1000000) then
        return invalid_argument('ATTEMPT_INVALID', { field = 'attempt' })
    end

    local slot_writes = raw_get(input, 'slot_writes')
    if type_value(slot_writes) ~= 'table'
        or get_metatable(slot_writes) ~= nil
        or #slot_writes < 1
    then
        return invalid_argument('SLOT_WRITES_REQUIRED', {
            field = 'slot_writes',
        })
    end

    local prepared = {}
    local index
    for index = 1, #slot_writes do
        local row = slot_writes[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return invalid_argument('SLOT_WRITE_TABLE_REQUIRED', {
                field = 'slot_writes[' .. tostring(index) .. ']',
            })
        end
        if not is_safe_integer(row.slot_id, 1, 319) then
            return invalid_argument('SLOT_ID_INVALID', {
                field = 'slot_writes[' .. tostring(index) .. '].slot_id',
            })
        end
        if not is_safe_integer(row.expected_revision, 0, 9007199254740990) then
            return invalid_argument('EXPECTED_REVISION_INVALID', {
                field = 'slot_writes['
                    .. tostring(index)
                    .. '].expected_revision',
            })
        end
        local envelope = SaveEnvelope.build({
            player_save_scope = player_ref.value,
            revision = row.expected_revision + 1,
            checkpoint_id = checkpoint_id.value,
            content_version = raw_get(input, 'content_version') or 'content-v1',
            payload = row.payload,
            written_at = raw_get(input, 'written_at'),
            schema_version = row.schema_version or 1,
        })
        if not envelope.ok then
            return envelope
        end
        prepared[#prepared + 1] = {
            slot_id = row.slot_id,
            expected_revision = row.expected_revision,
            envelope = envelope.value,
        }
    end

    prepared = sort_slot_writes(prepared)
    local previous_slot = 0
    for index = 1, #prepared do
        if prepared[index].slot_id <= previous_slot then
            return invalid_argument('SLOT_IDS_MUST_BE_UNIQUE_ASCENDING', {
                field = 'slot_writes',
                slot_id = prepared[index].slot_id,
            })
        end
        previous_slot = prepared[index].slot_id
    end

    local staged = {}
    for index = 1, #prepared do
        local row = prepared[index]
        local stage_key = transaction_id.value
            .. '_stage_'
            .. tostring(row.slot_id)
        local stage_request = {
            context = build_context(
                request_id.value,
                correlation_id.value,
                attempt,
                stage_key
            ),
            player_ref = player_ref.value,
            slot_id = row.slot_id,
            expected_revision = row.expected_revision,
            checkpoint_id = checkpoint_id.value,
            payload_checksum = row.envelope.payload_checksum,
            dto = row.envelope,
        }
        local staged_result = invoke_port(invoke, 'stage_slot', stage_request)
        if not staged_result.ok then
            if staged_result.error
                and staged_result.error.code == 'PLATFORM_RESULT_UNKNOWN'
            then
                return result_ok({
                    status = 'UNKNOWN',
                    phase = 'STAGE',
                    pending = {
                        player_ref = player_ref.value,
                        checkpoint_id = checkpoint_id.value,
                        transaction_id = transaction_id.value,
                        prepared = prepared,
                        staged = staged,
                        failed_slot_id = row.slot_id,
                    },
                    error = staged_result.error,
                })
            end
            return staged_result
        end
        staged[#staged + 1] = {
            slot_id = row.slot_id,
            target_revision = row.envelope.revision,
            checkpoint_id = checkpoint_id.value,
            payload_checksum = row.envelope.payload_checksum,
        }
    end

    local commit_key = transaction_id.value .. '_commit'
    local commit_request = {
        context = build_context(
            request_id.value,
            correlation_id.value,
            attempt,
            commit_key
        ),
        player_ref = player_ref.value,
        commit_entries = staged,
    }
    local committed = invoke_port(invoke, 'commit', commit_request)
    if not committed.ok then
        if committed.error
            and committed.error.code == 'PLATFORM_RESULT_UNKNOWN'
        then
            return result_ok({
                status = 'UNKNOWN',
                phase = 'COMMIT',
                pending = {
                    player_ref = player_ref.value,
                    checkpoint_id = checkpoint_id.value,
                    transaction_id = transaction_id.value,
                    prepared = prepared,
                    staged = staged,
                },
                error = committed.error,
            })
        end
        return committed
    end

    return result_ok({
        status = 'COMMITTED',
        checkpoint_id = checkpoint_id.value,
        transaction_id = transaction_id.value,
        slot_results = committed.value.slot_results,
        value = committed.value,
        pending = {
            player_ref = player_ref.value,
            checkpoint_id = checkpoint_id.value,
            transaction_id = transaction_id.value,
            prepared = prepared,
            staged = staged,
        },
    })
end

function Coordinator:load_slot(input, invoke)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED', { field = 'input' })
    end
    local player_ref = validate_component(
        raw_get(input, 'player_ref'),
        'player_ref'
    )
    if not player_ref.ok then
        return invalid_argument('PLAYER_REF_INVALID', { field = 'player_ref' })
    end
    if not is_safe_integer(raw_get(input, 'slot_id'), 1, 319) then
        return invalid_argument('SLOT_ID_INVALID', { field = 'slot_id' })
    end
    local request_id = validate_component(
        raw_get(input, 'request_id') or 'request_save_load',
        'request_id'
    )
    if not request_id.ok then
        return invalid_argument('REQUEST_ID_INVALID', { field = 'request_id' })
    end
    local correlation_id = validate_component(
        raw_get(input, 'correlation_id') or request_id.value,
        'correlation_id'
    )
    if not correlation_id.ok then
        return invalid_argument('CORRELATION_ID_INVALID', {
            field = 'correlation_id',
        })
    end
    local request = {
        context = build_context(
            request_id.value,
            correlation_id.value,
            1
        ),
        player_ref = player_ref.value,
        slot_id = input.slot_id,
    }
    return invoke_port(invoke, 'load_slot', request)
end

-- Reconcile an UNKNOWN write by loading each staged slot and comparing
-- revision/checkpoint/checksum. Never re-stages or re-commits blindly.
function Coordinator:reconcile_write(pending, invoke, context_input)
    if type_value(pending) ~= 'table'
        or get_metatable(pending) ~= nil
        or type_value(raw_get(pending, 'staged')) ~= 'table'
    then
        return invalid_argument('PENDING_REQUIRED', { field = 'pending' })
    end
    local request_id = 'request_save_reconcile'
    local correlation_id = request_id
    if type_value(context_input) == 'table' then
        if raw_get(context_input, 'request_id') ~= nil then
            local checked = validate_component(
                context_input.request_id,
                'request_id'
            )
            if not checked.ok then
                return invalid_argument('REQUEST_ID_INVALID', {
                    field = 'request_id',
                })
            end
            request_id = checked.value
        end
        if raw_get(context_input, 'correlation_id') ~= nil then
            local checked = validate_component(
                context_input.correlation_id,
                'correlation_id'
            )
            if not checked.ok then
                return invalid_argument('CORRELATION_ID_INVALID', {
                    field = 'correlation_id',
                })
            end
            correlation_id = checked.value
        end
    end

    local confirmed = {}
    local index
    for index = 1, #pending.staged do
        local entry = pending.staged[index]
        local loaded = self:load_slot({
            player_ref = pending.player_ref,
            slot_id = entry.slot_id,
            request_id = request_id,
            correlation_id = correlation_id,
        }, invoke)
        if not loaded.ok then
            if loaded.error and loaded.error.code == 'SAVE_NOT_FOUND' then
                return fail(
                    'PLATFORM_RESULT_UNKNOWN',
                    'SLOT_NOT_YET_VISIBLE',
                    {
                        slot_id = entry.slot_id,
                        checkpoint_id = pending.checkpoint_id,
                        transaction_id = pending.transaction_id,
                        recovery = 'QUERY_OR_RECONCILE',
                    },
                    true
                )
            end
            return loaded
        end
        local value = loaded.value
        if value.revision ~= entry.target_revision
            or value.checkpoint_id ~= entry.checkpoint_id
            or value.payload_checksum ~= entry.payload_checksum
        then
            return fail(
                'PLATFORM_RESULT_UNKNOWN',
                'SLOT_PROOF_MISMATCH',
                {
                    slot_id = entry.slot_id,
                    expected_revision = entry.target_revision,
                    actual_revision = value.revision,
                    expected_checkpoint_id = entry.checkpoint_id,
                    actual_checkpoint_id = value.checkpoint_id,
                    recovery = 'QUERY_OR_RECONCILE',
                },
                true
            )
        end
        confirmed[index] = {
            slot_id = entry.slot_id,
            status = 'CONFIRMED',
            target_revision = entry.target_revision,
            checkpoint_id = entry.checkpoint_id,
            payload_checksum = entry.payload_checksum,
        }
    end

    return result_ok({
        status = 'COMMITTED',
        reconciled = true,
        checkpoint_id = pending.checkpoint_id,
        transaction_id = pending.transaction_id,
        slot_results = confirmed,
    })
end

function SaveCoordinator.fake_invoke(repository)
    if type_value(repository) ~= 'table' then
        return nil, invalid_argument('REPOSITORY_REQUIRED')
    end
    return function(operation_name, request)
        local completion
        local completion_count = 0
        local method = repository[operation_name]
        if type_value(method) ~= 'function' then
            return fail(
                'PORT_OPERATION_UNKNOWN',
                'OPERATION_MISSING',
                { operation = operation_name },
                false
            )
        end
        local admission = method(repository, request, function(result)
            completion_count = completion_count + 1
            completion = result
        end)
        if type_value(admission) ~= 'table' or admission.ok ~= true then
            return admission
        end
        if admission.value == nil or admission.value.accepted ~= true then
            return fail(
                'PORT_ADAPTER_FAILED',
                'ADMISSION_NOT_ACCEPTED',
                { operation = operation_name },
                false
            )
        end
        if completion_count ~= 0 then
            return fail(
                'PORT_ADAPTER_CALLBACK_INLINE',
                'INLINE_CALLBACK_FORBIDDEN',
                { operation = operation_name },
                false
            )
        end
        if type_value(repository.tick) ~= 'function' then
            return fail(
                'PORT_ADAPTER_FAILED',
                'TICK_REQUIRED_FOR_FAKE_INVOKE',
                { operation = operation_name },
                false
            )
        end
        local ticked = repository:tick(0)
        if not ticked.ok then
            return ticked
        end
        if completion_count ~= 1 or completion == nil then
            return fail(
                'PLATFORM_RESULT_UNKNOWN',
                'COMPLETION_NOT_DELIVERED',
                { operation = operation_name },
                true
            )
        end
        return completion
    end
end

function SaveCoordinator.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid_argument('OPTIONS_REQUIRED')
    end
    local save_store = raw_get(options, 'save_store')
    if type_value(save_store) ~= 'table' then
        return invalid_argument('SAVE_STORE_REQUIRED', {
            field = 'save_store',
        })
    end
    if type_value(save_store.get_contract) == 'function' then
        local contract = save_store:get_contract()
        if contract ~= SaveStore then
            return invalid_argument('SAVE_STORE_CONTRACT_MISMATCH', {
                field = 'save_store',
            })
        end
    end
    local coordinator = set_metatable({}, Coordinator)
    STATES[coordinator] = {
        save_store = save_store,
        counter = 0,
        checkpoint_counter = 0,
    }
    return result_ok(coordinator)
end

return SaveCoordinator
