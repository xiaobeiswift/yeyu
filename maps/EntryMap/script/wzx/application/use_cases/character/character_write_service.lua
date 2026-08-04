local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CharacterEventBus = require 'wzx.application.character.character_event_bus'
local CharacterReceiptCodec = require 'wzx.domain.character.character_receipt_codec'
local CharacterRepository = require 'wzx.application.ports.character_repository'
local CharacterSaveBridge = require 'wzx.application.use_cases.character.character_save_bridge'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TalentListDigest = require 'wzx.domain.character.talent_list_digest'

local CharacterWriteService = {}
local canonical_derive = CanonicalReceiptHashV1.derive
local derive_transport_key = CharacterReceiptCodec.derive_transport_request_key
local derive_talent_list_digest = TalentListDigest.derive
local error_value = error
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived
local validate_source_reference = RuntimeId.validate_source_reference

local CREATE = 'CREATE_OWNED_CHARACTER'
local EXPERIENCE = 'GRANT_CHARACTER_EXPERIENCE'
local RENAME = 'RENAME_PROTAGONIST'
local ZERO_DIGEST = string.rep('0', 64)
local NO_REWARD_RECEIPT_ID = 'none'
local MAX_EXPERIENCE_GRANT = 1000000000

local CREATE_COMMAND_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'source_type', type = 'STRING' },
    { name = 'source_reference', type = 'STRING' },
}
local CREATE_RESULT_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'already_owned', type = 'BOOLEAN' },
    { name = 'definition_version', type = 'INTEGER' },
    { name = 'level', type = 'INTEGER' },
    { name = 'experience', type = 'INTEGER' },
    { name = 'unlocked_talent_count', type = 'INTEGER' },
    { name = 'unlocked_talent_digest', type = 'STRING' },
    { name = 'created_receipt_id', type = 'STRING' },
    { name = 'character_revision', type = 'INTEGER' },
}
local EXPERIENCE_COMMAND_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'created_receipt_id', type = 'STRING' },
    { name = 'amount', type = 'INTEGER' },
    { name = 'reason', type = 'STRING' },
    { name = 'expected_revision', type = 'INTEGER' },
    { name = 'reward_ref_count', type = 'INTEGER' },
    { name = 'reward_plan_digest', type = 'STRING' },
}
local EXPERIENCE_RESULT_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'amount', type = 'INTEGER' },
    { name = 'reason', type = 'STRING' },
    { name = 'old_experience', type = 'INTEGER' },
    { name = 'new_experience', type = 'INTEGER' },
    { name = 'old_level', type = 'INTEGER' },
    { name = 'new_level', type = 'INTEGER' },
    { name = 'character_revision', type = 'INTEGER' },
    { name = 'reward_status', type = 'STRING' },
    { name = 'reward_receipt_id', type = 'STRING' },
    { name = 'reward_result_digest', type = 'STRING' },
}
local RENAME_COMMAND_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'created_receipt_id', type = 'STRING' },
    { name = 'new_name', type = 'STRING' },
    { name = 'expected_revision', type = 'INTEGER' },
}
local RENAME_RESULT_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'new_name', type = 'STRING' },
    { name = 'character_revision', type = 'INTEGER' },
}

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('character write service is read-only', 2)
end
Service.__metatable = false

local STATES = setmetatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.character.write_' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid_argument(reason, details)
    return fail('INVALID_ARGUMENT', reason, details, false)
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

local function digest(namespace, fields, values)
    local derived = canonical_derive(namespace, fields, values)
    if not derived.ok then
        return nil, derived
    end
    return derived.value.digest, nil
end

local function is_upper_token(value)
    return type_value(value) == 'string'
        and #value >= 1
        and #value <= 64
        and string.match(value, '^[A-Z][A-Z0-9_]*$') ~= nil
end

local function is_sha256(value)
    return type_value(value) == 'string'
        and #value == 64
        and string.match(value, '^[a-f0-9]+$') ~= nil
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

local function validate_common_identity(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED', { field = 'input' })
    end

    local scope = validate_component(
        raw_get(input, 'player_save_scope'),
        'player_save_scope'
    )
    if not scope.ok then
        return invalid_argument('PLAYER_SAVE_SCOPE_INVALID', {
            field = 'player_save_scope',
        })
    end

    local character_id = validate_content(
        raw_get(input, 'character_id'),
        'char_',
        'character_id'
    )
    if not character_id.ok then
        return invalid_argument('CHARACTER_ID_INVALID', {
            field = 'character_id',
        })
    end

    local receipt_id = validate_derived(
        raw_get(input, 'receipt_id'),
        'receipt_id'
    )
    if not receipt_id.ok then
        return invalid_argument('RECEIPT_ID_INVALID', {
            field = 'receipt_id',
        })
    end

    local transaction_id = validate_derived(
        raw_get(input, 'transaction_id'),
        'transaction_id'
    )
    if not transaction_id.ok then
        return invalid_argument('TRANSACTION_ID_INVALID', {
            field = 'transaction_id',
        })
    end

    local request_id = validate_component(
        raw_get(input, 'request_id') or 'request_character_write',
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

    local attempt = raw_get(input, 'attempt')
    if attempt == nil then
        attempt = 1
    end
    if not is_safe_integer(attempt, 1, 1000000) then
        return invalid_argument('ATTEMPT_INVALID', { field = 'attempt' })
    end

    local transport = derive_transport_key(receipt_id.value)
    if not transport.ok then
        return transport
    end

    if transport.value == transaction_id.value
        or transport.value == receipt_id.value
        or receipt_id.value == transaction_id.value
    then
        return invalid_argument('PRIMARY_IDENTITY_REUSE_FORBIDDEN', {
            receipt_id = receipt_id.value,
            transaction_id = transaction_id.value,
        })
    end

    return result_ok({
        player_save_scope = scope.value,
        character_id = character_id.value,
        receipt_id = receipt_id.value,
        transaction_id = transaction_id.value,
        request_id = request_id.value,
        correlation_id = correlation_id.value,
        attempt = attempt,
        transport_key = transport.value,
    })
end

local function build_context(identity)
    return {
        request_id = identity.request_id,
        correlation_id = identity.correlation_id,
        attempt = identity.attempt,
        idempotency_key = identity.transport_key,
    }
end

local function build_load_request(identity)
    return {
        context = {
            request_id = identity.request_id,
            correlation_id = identity.correlation_id,
            attempt = identity.attempt,
        },
        player_save_scope = identity.player_save_scope,
        character_id = identity.character_id,
    }
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

local function query_proof_from_commit(commit_request)
    return {
        player_save_scope = commit_request.player_save_scope,
        original_request_key = commit_request.context.idempotency_key,
        receipt_id = commit_request.receipt_id,
        transaction_id = commit_request.transaction_id,
        operation_type = commit_request.operation_type,
        command_digest = commit_request.command_digest,
        expected_result_digest = commit_request.result_digest,
        expected_character_save_revision =
            commit_request.expected_character_save_revision,
        command = {
            character_id = commit_request.command.character_id,
            source_type = commit_request.command.source_type,
            source_reference = commit_request.command.source_reference,
            created_receipt_id = commit_request.command.created_receipt_id,
            amount = commit_request.command.amount,
            reason = commit_request.command.reason,
            expected_revision = commit_request.command.expected_revision,
            reward_ref_count = commit_request.command.reward_ref_count,
            reward_plan_digest = commit_request.command.reward_plan_digest,
            new_name = commit_request.command.new_name,
        },
    }
end

local function maybe_persist_save(self, player_save_scope, request_id, correlation_id)
    local state = STATES[self]
    if state == nil or state.save_bridge == nil then
        return result_ok({ status = 'SKIPPED' })
    end
    return state.save_bridge:persist_player_characters({
        player_save_scope = player_save_scope,
        player_ref = player_save_scope,
        request_id = request_id,
        correlation_id = correlation_id,
    })
end

local function append_event(events, published)
    if not published.ok then
        events[#events + 1] = {
            ok = false,
            error = published.error,
        }
        return
    end
    events[#events + 1] = {
        ok = true,
        accepted = published.value.accepted,
        duplicate = published.value.duplicate,
        event_id = published.value.event_id,
        event_type = published.value.event
            and published.value.event.event_type
            or nil,
    }
end

local function emit_committed_events(self, commit_request, completion, plan)
    local state = STATES[self]
    local events = {}
    if state == nil or state.event_bus == nil then
        return events
    end
    local bus = state.event_bus
    local result = completion.value.result
    local correlation_id = commit_request.context.correlation_id
    local receipt_id = commit_request.receipt_id
    local operation = commit_request.operation_type

    if operation == CREATE then
        append_event(events, bus:publish_character_owned({
            character_id = result.character_id,
            source_type = commit_request.command.source_type,
            source_reference = commit_request.command.source_reference,
            receipt_id = receipt_id,
            already_owned = result.already_owned,
            revision = result.character_revision,
            correlation_id = correlation_id,
        }))
        if result.already_owned ~= true
            and completion.value
            and type_value(commit_request.after_state) == 'table'
        then
            local talent_ids = commit_request.after_state.unlocked_talent_ids or {}
            local index
            for index = 1, #talent_ids do
                append_event(events, bus:publish_talent_unlocked({
                    character_id = result.character_id,
                    talent_id = talent_ids[index],
                    source_reference = commit_request.command.source_reference,
                    receipt_id = receipt_id,
                    revision = result.character_revision,
                    correlation_id = correlation_id,
                }))
            end
        end
    elseif operation == EXPERIENCE then
        append_event(events, bus:publish_experience_granted({
            character_id = result.character_id,
            amount = result.amount,
            old_experience = result.old_experience,
            new_experience = result.new_experience,
            reason = result.reason,
            receipt_id = receipt_id,
            revision = result.character_revision,
            correlation_id = correlation_id,
        }))
        if result.new_level ~= result.old_level then
            local unlocked_refs = {}
            if plan ~= nil and type_value(plan.reward_refs) == 'table' then
                local index
                for index = 1, #plan.reward_refs do
                    unlocked_refs[index] = plan.reward_refs[index]
                end
            end
            append_event(events, bus:publish_level_changed({
                character_id = result.character_id,
                old_level = result.old_level,
                new_level = result.new_level,
                unlocked_refs = unlocked_refs,
                receipt_id = receipt_id,
                revision = result.character_revision,
                correlation_id = correlation_id,
            }))
        end
    elseif operation == RENAME then
        append_event(events, bus:publish_renamed({
            character_id = result.character_id,
            new_name = result.new_name,
            receipt_id = receipt_id,
            revision = result.character_revision,
            correlation_id = correlation_id,
        }))
    end
    return events
end

local function finalize_write(
    self,
    commit_request,
    completion,
    player_save_scope,
    plan
)
    local pending = {
        query_proof = query_proof_from_commit(commit_request),
        operation_type = commit_request.operation_type,
        receipt_id = commit_request.receipt_id,
        transaction_id = commit_request.transaction_id,
        result_digest = commit_request.result_digest,
        command_digest = commit_request.command_digest,
    }

    if not completion.ok then
        local code = completion.error and completion.error.code or nil
        if code == 'PLATFORM_RESULT_UNKNOWN' then
            return result_ok({
                status = 'UNKNOWN',
                pending = pending,
                error = completion.error,
                save = { status = 'SKIPPED' },
                events = {},
            })
        end
        return completion
    end

    local save_result = maybe_persist_save(
        self,
        player_save_scope,
        commit_request.context.request_id,
        commit_request.context.correlation_id
    )
    local save_payload
    if not save_result.ok then
        save_payload = {
            status = 'FAILED',
            error = save_result.error,
        }
    else
        save_payload = save_result.value
    end

    local events = emit_committed_events(
        self,
        commit_request,
        completion,
        plan
    )

    return result_ok({
        status = 'COMMITTED',
        pending = pending,
        value = completion.value,
        result = completion.value.result,
        character_save_revision = completion.value.character_save_revision,
        receipt_save_revision = completion.value.receipt_save_revision,
        save = save_payload,
        events = events,
    })
end

local function load_character(self, identity, invoke)
    local load_request = build_load_request(identity)
    local loaded = invoke_port(invoke, 'load_character', load_request)
    if not loaded.ok then
        return loaded
    end
    local value = loaded.value
    if type_value(value) ~= 'table' then
        return fail(
            'PORT_RESULT_INVALID',
            'LOAD_VALUE_INVALID',
            nil,
            false
        )
    end
    if value.status == 'READ_ONLY_ISOLATED' then
        return fail('SAVE_READ_ONLY', 'CHARACTER_READ_ONLY_ISOLATED', {
            character_id = identity.character_id,
            player_save_scope = identity.player_save_scope,
            issue_codes = value.issue_codes,
        }, false)
    end
    return result_ok(value)
end

local function build_create_insert(identity, created_state, source_type, source_reference)
    local talent_proof = derive_talent_list_digest(created_state.unlocked_talent_ids)
    if not talent_proof.ok then
        return talent_proof
    end
    local command = {
        character_id = identity.character_id,
        source_type = source_type,
        source_reference = source_reference,
    }
    local result = {
        operation_type = CREATE,
        character_id = created_state.character_id,
        already_owned = false,
        definition_version = created_state.definition_version,
        level = created_state.level,
        experience = created_state.experience,
        unlocked_talent_count = talent_proof.value.count,
        unlocked_talent_digest = talent_proof.value.digest,
        created_receipt_id = created_state.created_receipt_id,
        character_revision = created_state.revision,
    }
    local command_digest, command_error = digest(
        'character_create_owned_command',
        CREATE_COMMAND_FIELDS,
        command
    )
    if command_error then
        return command_error
    end
    local result_digest, result_error = digest(
        'character_create_owned_result',
        CREATE_RESULT_FIELDS,
        {
            character_id = result.character_id,
            already_owned = result.already_owned,
            definition_version = result.definition_version,
            level = result.level,
            experience = result.experience,
            unlocked_talent_count = result.unlocked_talent_count,
            unlocked_talent_digest = result.unlocked_talent_digest,
            created_receipt_id = result.created_receipt_id,
            character_revision = result.character_revision,
        }
    )
    if result_error then
        return result_error
    end
    return result_ok({
        context = build_context(identity),
        player_save_scope = identity.player_save_scope,
        operation_type = CREATE,
        receipt_id = identity.receipt_id,
        transaction_id = identity.transaction_id,
        command_digest = command_digest,
        expected_character_save_revision = 0,
        change_type = 'INSERT',
        command = command,
        after_state = copy_state(created_state),
        result_digest = result_digest,
        result = result,
    })
end

local function build_create_already_owned(
    identity,
    before_state,
    character_save_revision,
    source_type,
    source_reference
)
    local talent_proof = derive_talent_list_digest(before_state.unlocked_talent_ids)
    if not talent_proof.ok then
        return talent_proof
    end
    local command = {
        character_id = identity.character_id,
        source_type = source_type,
        source_reference = source_reference,
    }
    local result = {
        operation_type = CREATE,
        character_id = before_state.character_id,
        already_owned = true,
        definition_version = before_state.definition_version,
        level = before_state.level,
        experience = before_state.experience,
        unlocked_talent_count = talent_proof.value.count,
        unlocked_talent_digest = talent_proof.value.digest,
        created_receipt_id = before_state.created_receipt_id,
        character_revision = before_state.revision,
    }
    local command_digest, command_error = digest(
        'character_create_owned_command',
        CREATE_COMMAND_FIELDS,
        command
    )
    if command_error then
        return command_error
    end
    local result_digest, result_error = digest(
        'character_create_owned_result',
        CREATE_RESULT_FIELDS,
        {
            character_id = result.character_id,
            already_owned = result.already_owned,
            definition_version = result.definition_version,
            level = result.level,
            experience = result.experience,
            unlocked_talent_count = result.unlocked_talent_count,
            unlocked_talent_digest = result.unlocked_talent_digest,
            created_receipt_id = result.created_receipt_id,
            character_revision = result.character_revision,
        }
    )
    if result_error then
        return result_error
    end
    return result_ok({
        context = build_context(identity),
        player_save_scope = identity.player_save_scope,
        operation_type = CREATE,
        receipt_id = identity.receipt_id,
        transaction_id = identity.transaction_id,
        command_digest = command_digest,
        expected_character_save_revision = character_save_revision,
        change_type = 'NO_CHANGE',
        command = command,
        before_state = copy_state(before_state),
        result_digest = result_digest,
        result = result,
    })
end

function Service:create_owned(input, invoke)
    local identity = validate_common_identity(input)
    if not identity.ok then
        return identity
    end
    identity = identity.value

    if not is_upper_token(raw_get(input, 'source_type')) then
        return invalid_argument('SOURCE_TYPE_INVALID', { field = 'source_type' })
    end
    local source_reference = validate_source_reference(
        raw_get(input, 'source_reference'),
        'source_reference'
    )
    if not source_reference.ok then
        return invalid_argument('SOURCE_REFERENCE_INVALID', {
            field = 'source_reference',
            cause_code = source_reference.error.code,
        })
    end

    local state = STATES[self]
    if state == nil then
        return invalid_argument('SERVICE_AUTHORITY_REQUIRED')
    end

    local loaded = load_character(self, identity, invoke)
    if not loaded.ok then
        return loaded
    end

    local commit_request
    if loaded.value.status == 'FOUND' then
        local built = build_create_already_owned(
            identity,
            loaded.value.state,
            loaded.value.character_save_revision,
            input.source_type,
            source_reference.value
        )
        if not built.ok then
            return built
        end
        commit_request = built.value
    elseif loaded.value.status == 'NOT_FOUND' then
        local created = state.rules:create_owned(
            identity.character_id,
            identity.receipt_id
        )
        if not created.ok then
            return created
        end
        local built = build_create_insert(
            identity,
            created.value,
            input.source_type,
            source_reference.value
        )
        if not built.ok then
            return built
        end
        -- INSERT must start from the observed save revision of an empty scope.
        built.value.expected_character_save_revision =
            loaded.value.character_save_revision or 0
        commit_request = built.value
    else
        return fail(
            'PORT_RESULT_INVALID',
            'LOAD_STATUS_UNSUPPORTED',
            { status = loaded.value.status },
            false
        )
    end

    local committed = invoke_port(
        invoke,
        'commit_character_transaction',
        commit_request
    )
    return finalize_write(
        self,
        commit_request,
        committed,
        identity.player_save_scope,
        nil
    )
end

local function build_experience_commit(identity, planned, reason, settlement, save_revision)
    local command = {
        character_id = planned.character_id,
        created_receipt_id = planned.before_state.created_receipt_id,
        amount = planned.after_state.experience - planned.before_state.experience,
        reason = reason,
        expected_revision = planned.expected_revision,
        reward_ref_count = planned.reward_ref_count,
        reward_plan_digest = planned.reward_plan_digest,
    }

    local reward_status = 'NOT_REQUIRED'
    local reward_receipt_id = NO_REWARD_RECEIPT_ID
    local reward_result_digest = ZERO_DIGEST
    if planned.reward_ref_count > 0 then
        reward_status = 'COMMITTED'
        reward_receipt_id = settlement.reward_receipt_id
        reward_result_digest = settlement.reward_result_digest
    end

    local result = {
        operation_type = EXPERIENCE,
        character_id = planned.character_id,
        amount = command.amount,
        reason = reason,
        old_experience = planned.before_state.experience,
        new_experience = planned.after_state.experience,
        old_level = planned.old_level,
        new_level = planned.new_level,
        character_revision = planned.after_state.revision,
        reward_status = reward_status,
        reward_receipt_id = reward_receipt_id,
        reward_result_digest = reward_result_digest,
    }

    local command_digest, command_error = digest(
        'character_grant_experience_command',
        EXPERIENCE_COMMAND_FIELDS,
        command
    )
    if command_error then
        return command_error
    end
    local result_digest, result_error = digest(
        'character_grant_experience_result',
        EXPERIENCE_RESULT_FIELDS,
        {
            character_id = result.character_id,
            amount = result.amount,
            reason = result.reason,
            old_experience = result.old_experience,
            new_experience = result.new_experience,
            old_level = result.old_level,
            new_level = result.new_level,
            character_revision = result.character_revision,
            reward_status = result.reward_status,
            reward_receipt_id = result.reward_receipt_id,
            reward_result_digest = result.reward_result_digest,
        }
    )
    if result_error then
        return result_error
    end

    return result_ok({
        context = build_context(identity),
        player_save_scope = identity.player_save_scope,
        operation_type = EXPERIENCE,
        receipt_id = identity.receipt_id,
        transaction_id = identity.transaction_id,
        command_digest = command_digest,
        expected_character_save_revision = save_revision,
        change_type = 'UPDATE',
        command = command,
        before_state = copy_state(planned.before_state),
        after_state = copy_state(planned.after_state),
        result_digest = result_digest,
        result = result,
    })
end

local function reward_receipt_identity_forbidden(
    reward_receipt_id,
    reward_result_digest,
    identity,
    planned
)
    return reward_receipt_id == identity.receipt_id
        or reward_receipt_id == identity.transaction_id
        or reward_receipt_id == identity.transport_key
        or reward_receipt_id == planned.before_state.created_receipt_id
        or reward_receipt_id == planned.reward_plan_digest
        or reward_receipt_id == reward_result_digest
end

local function validate_external_reward_settlement(settlement, planned, identity)
    if type_value(settlement) ~= 'table' or get_metatable(settlement) ~= nil then
        return fail(
            'REWARD_SETTLEMENT_REQUIRED',
            'REWARD_SETTLEMENT_REQUIRED',
            {
                reward_ref_count = planned.reward_ref_count,
                reward_refs = planned.reward_refs,
            },
            false
        )
    end

    local reward_receipt = validate_derived(
        raw_get(settlement, 'reward_receipt_id'),
        'reward_receipt_id'
    )
    if not reward_receipt.ok then
        return invalid_argument('REWARD_RECEIPT_ID_INVALID', {
            field = 'reward_settlement.reward_receipt_id',
        })
    end
    if not is_sha256(raw_get(settlement, 'reward_result_digest'))
        or raw_get(settlement, 'reward_result_digest') == ZERO_DIGEST
    then
        return invalid_argument('REWARD_RESULT_DIGEST_INVALID', {
            field = 'reward_settlement.reward_result_digest',
        })
    end

    local reward_receipt_id = reward_receipt.value
    local reward_result_digest = settlement.reward_result_digest
    if reward_receipt_identity_forbidden(
        reward_receipt_id,
        reward_result_digest,
        identity,
        planned
    ) then
        return invalid_argument('REWARD_RECEIPT_IDENTITY_REUSE_FORBIDDEN', {
            field = 'reward_settlement.reward_receipt_id',
        })
    end

    return result_ok({
        reward_receipt_id = reward_receipt_id,
        reward_result_digest = reward_result_digest,
        auto_settled = false,
        grants = {},
    })
end

-- Grant each planned level reward through the bound EconomyService.
-- Occurrence/receipt identities bind only to the experience receipt + ordinal so
-- retries of the same command remain idempotent; a changed plan under the same
-- ordinal fails closed with ECONOMY_RECEIPT_CONFLICT instead of double-paying.
local function settle_level_rewards_via_economy(self, identity, planned, input)
    local state = STATES[self]
    local economy = state and state.economy_service or nil
    if economy == nil then
        return fail(
            'REWARD_SETTLEMENT_REQUIRED',
            'REWARD_SETTLEMENT_REQUIRED',
            {
                reward_ref_count = planned.reward_ref_count,
                reward_refs = planned.reward_refs,
            },
            false
        )
    end

    local rewards = planned.reached_level_rewards
    if type_value(rewards) ~= 'table' or not is_dense_array(rewards) then
        return fail(
            'REWARD_SETTLEMENT_REQUIRED',
            'LEVEL_REWARD_ROWS_INVALID',
            { reward_ref_count = planned.reward_ref_count },
            false
        )
    end
    if #rewards ~= planned.reward_ref_count then
        return fail(
            'REWARD_SETTLEMENT_REQUIRED',
            'LEVEL_REWARD_COUNT_MISMATCH',
            {
                reward_ref_count = planned.reward_ref_count,
                row_count = #rewards,
            },
            false
        )
    end

    local grants = {}
    local chain_digest = ZERO_DIGEST
    local index
    for index = 1, #rewards do
        local row = rewards[index]
        local reward_ref = row.reward_ref
        local reached_level = row.reached_level

        local occurrence_proof = canonical_derive(
            'character_level_reward_occurrence',
            {
                { name = 'experience_receipt_id', type = 'STRING' },
                { name = 'ordinal', type = 'INTEGER' },
            },
            {
                experience_receipt_id = identity.receipt_id,
                ordinal = index,
            }
        )
        if not occurrence_proof.ok then
            return occurrence_proof
        end

        local grant_proof = canonical_derive(
            'character_level_reward_grant',
            {
                { name = 'experience_receipt_id', type = 'STRING' },
                { name = 'ordinal', type = 'INTEGER' },
            },
            {
                experience_receipt_id = identity.receipt_id,
                ordinal = index,
            }
        )
        if not grant_proof.ok then
            return grant_proof
        end

        local grant_receipt_id = grant_proof.value.receipt_id
        if grant_receipt_id == identity.receipt_id
            or grant_receipt_id == identity.transaction_id
            or grant_receipt_id == identity.transport_key
            or grant_receipt_id == planned.before_state.created_receipt_id
            or grant_receipt_id == planned.reward_plan_digest
        then
            return invalid_argument('REWARD_RECEIPT_IDENTITY_REUSE_FORBIDDEN', {
                field = 'auto_reward_settlement.receipt_id',
                ordinal = index,
            })
        end

        local prepared = economy:prepare_reward({
            reward_id = reward_ref,
            source_type = 'LEVEL_REWARD',
            source_ref = reward_ref,
            source_occurrence_id = occurrence_proof.value.digest,
        })
        if not prepared.ok then
            return prepared
        end

        local granted = economy:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = grant_receipt_id,
            purpose_type = 'LEVEL_REWARD',
            purpose_ref = reward_ref,
            player_save_scope = identity.player_save_scope,
            -- request_id is a component; leave command_id unset so the economy
            -- save bridge derives a component checkpoint id from it.
            request_id = identity.request_id,
            save_seed = raw_get(input, 'save_seed'),
            content_version = raw_get(input, 'content_version'),
        })
        if not granted.ok then
            return granted
        end
        if granted.value.status ~= 'COMMITTED'
            or type_value(granted.value.result_hash) ~= 'string'
            or not is_sha256(granted.value.result_hash)
            or granted.value.result_hash == ZERO_DIGEST
        then
            return fail(
                'REWARD_SETTLEMENT_REQUIRED',
                'ECONOMY_GRANT_NOT_COMMITTED',
                {
                    reward_ref = reward_ref,
                    ordinal = index,
                    status = granted.value and granted.value.status,
                },
                false
            )
        end

        grants[index] = {
            reward_ref = reward_ref,
            reached_level = reached_level,
            receipt_id = granted.value.receipt_id,
            result_hash = granted.value.result_hash,
            already_committed = granted.value.already_committed == true,
            economy_revision = granted.value.economy_revision,
            source_occurrence_id = granted.value.source_occurrence_id,
            save = granted.value.save,
        }

        local chain = canonical_derive(
            'character_level_reward_chain',
            {
                { name = 'previous_digest', type = 'STRING' },
                { name = 'ordinal', type = 'INTEGER' },
                { name = 'reward_ref', type = 'STRING' },
                { name = 'grant_receipt_id', type = 'STRING' },
                { name = 'result_hash', type = 'STRING' },
            },
            {
                previous_digest = chain_digest,
                ordinal = index,
                reward_ref = reward_ref,
                grant_receipt_id = granted.value.receipt_id,
                result_hash = granted.value.result_hash,
            }
        )
        if not chain.ok then
            return chain
        end
        chain_digest = chain.value.digest
    end

    local settlement_receipt_id
    local settlement_result_digest
    if #grants == 1 then
        settlement_receipt_id = grants[1].receipt_id
        settlement_result_digest = grants[1].result_hash
    else
        local aggregate = canonical_derive(
            'character_level_reward_settlement',
            {
                { name = 'experience_receipt_id', type = 'STRING' },
                { name = 'grant_count', type = 'INTEGER' },
                { name = 'chain_digest', type = 'STRING' },
            },
            {
                experience_receipt_id = identity.receipt_id,
                grant_count = #grants,
                chain_digest = chain_digest,
            }
        )
        if not aggregate.ok then
            return aggregate
        end
        settlement_receipt_id = aggregate.value.receipt_id
        settlement_result_digest = chain_digest
    end

    if reward_receipt_identity_forbidden(
        settlement_receipt_id,
        settlement_result_digest,
        identity,
        planned
    ) then
        return invalid_argument('REWARD_RECEIPT_IDENTITY_REUSE_FORBIDDEN', {
            field = 'auto_reward_settlement.settlement_receipt_id',
        })
    end

    return result_ok({
        reward_receipt_id = settlement_receipt_id,
        reward_result_digest = settlement_result_digest,
        auto_settled = true,
        grants = grants,
    })
end

local function resolve_reward_settlement(self, input, planned, identity)
    if planned.reward_ref_count == 0 then
        if raw_get(input, 'reward_settlement') ~= nil then
            return invalid_argument(
                'REWARD_SETTLEMENT_FORBIDDEN_WHEN_EMPTY',
                { field = 'reward_settlement' }
            )
        end
        return result_ok(nil)
    end

    -- Explicit external proof remains supported for offline fakes and recovery
    -- injection. When omitted, a bound EconomyService settles currency leaves.
    local settlement = raw_get(input, 'reward_settlement')
    if settlement ~= nil then
        return validate_external_reward_settlement(
            settlement,
            planned,
            identity
        )
    end

    return settle_level_rewards_via_economy(self, identity, planned, input)
end

function Service:grant_experience(input, invoke)
    local identity = validate_common_identity(input)
    if not identity.ok then
        return identity
    end
    identity = identity.value

    if not is_safe_integer(raw_get(input, 'amount'), 1, MAX_EXPERIENCE_GRANT) then
        return invalid_argument('AMOUNT_INVALID', { field = 'amount' })
    end
    if not is_upper_token(raw_get(input, 'reason')) then
        return invalid_argument('REASON_INVALID', { field = 'reason' })
    end

    local state = STATES[self]
    if state == nil then
        return invalid_argument('SERVICE_AUTHORITY_REQUIRED')
    end

    local loaded = load_character(self, identity, invoke)
    if not loaded.ok then
        return loaded
    end
    if loaded.value.status ~= 'FOUND' then
        return fail('CHARACTER_NOT_OWNED', 'CHARACTER_NOT_FOUND', {
            character_id = identity.character_id,
            player_save_scope = identity.player_save_scope,
            status = loaded.value.status,
        }, false)
    end

    local planned = state.rules:plan_experience_grant(
        loaded.value.state,
        input.amount
    )
    if not planned.ok then
        return planned
    end

    local settlement = resolve_reward_settlement(
        self,
        input,
        planned.value,
        identity
    )
    if not settlement.ok then
        return settlement
    end

    local commit_request = build_experience_commit(
        identity,
        planned.value,
        input.reason,
        settlement.value,
        loaded.value.character_save_revision
    )
    if not commit_request.ok then
        return commit_request
    end

    local committed = invoke_port(
        invoke,
        'commit_character_transaction',
        commit_request.value
    )
    local finalized = finalize_write(
        self,
        commit_request.value,
        committed,
        identity.player_save_scope,
        planned.value
    )
    if not finalized.ok then
        return finalized
    end
    if finalized.value.status == 'COMMITTED'
        or finalized.value.status == 'UNKNOWN'
    then
        finalized.value.plan = {
            old_level = planned.value.old_level,
            new_level = planned.value.new_level,
            reward_ref_count = planned.value.reward_ref_count,
            reward_refs = planned.value.reward_refs,
            reward_plan_digest = planned.value.reward_plan_digest,
            reward_catalog_bound = planned.value.reward_catalog_bound,
        }
        if settlement.value ~= nil then
            finalized.value.reward_settlement = {
                reward_receipt_id = settlement.value.reward_receipt_id,
                reward_result_digest = settlement.value.reward_result_digest,
                auto_settled = settlement.value.auto_settled == true,
                grants = settlement.value.grants or {},
            }
        end
    end
    return finalized
end

local function build_rename_commit(identity, planned, save_revision)
    local command = {
        character_id = planned.character_id,
        created_receipt_id = planned.before_state.created_receipt_id,
        new_name = planned.new_name,
        expected_revision = planned.expected_revision,
    }
    local result = {
        operation_type = RENAME,
        character_id = planned.character_id,
        new_name = planned.new_name,
        character_revision = planned.after_state.revision,
    }
    local command_digest, command_error = digest(
        'character_rename_protagonist_command',
        RENAME_COMMAND_FIELDS,
        command
    )
    if command_error then
        return command_error
    end
    local result_digest, result_error = digest(
        'character_rename_protagonist_result',
        RENAME_RESULT_FIELDS,
        {
            character_id = result.character_id,
            new_name = result.new_name,
            character_revision = result.character_revision,
        }
    )
    if result_error then
        return result_error
    end
    return result_ok({
        context = build_context(identity),
        player_save_scope = identity.player_save_scope,
        operation_type = RENAME,
        receipt_id = identity.receipt_id,
        transaction_id = identity.transaction_id,
        command_digest = command_digest,
        expected_character_save_revision = save_revision,
        change_type = 'UPDATE',
        command = command,
        before_state = copy_state(planned.before_state),
        after_state = copy_state(planned.after_state),
        result_digest = result_digest,
        result = result,
    })
end

function Service:rename_protagonist(input, invoke)
    local identity = validate_common_identity(input)
    if not identity.ok then
        return identity
    end
    identity = identity.value

    local state = STATES[self]
    if state == nil then
        return invalid_argument('SERVICE_AUTHORITY_REQUIRED')
    end

    local loaded = load_character(self, identity, invoke)
    if not loaded.ok then
        return loaded
    end
    if loaded.value.status ~= 'FOUND' then
        return fail('CHARACTER_NOT_OWNED', 'CHARACTER_NOT_FOUND', {
            character_id = identity.character_id,
            player_save_scope = identity.player_save_scope,
            status = loaded.value.status,
        }, false)
    end

    local planned = state.rules:plan_rename(
        loaded.value.state,
        raw_get(input, 'new_name')
    )
    if not planned.ok then
        return planned
    end

    local commit_request = build_rename_commit(
        identity,
        planned.value,
        loaded.value.character_save_revision
    )
    if not commit_request.ok then
        return commit_request
    end

    local committed = invoke_port(
        invoke,
        'commit_character_transaction',
        commit_request.value
    )
    return finalize_write(
        self,
        commit_request.value,
        committed,
        identity.player_save_scope,
        nil
    )
end

function Service:build_combatant_snapshot(input, invoke)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED', { field = 'input' })
    end
    local scope = validate_component(
        raw_get(input, 'player_save_scope'),
        'player_save_scope'
    )
    if not scope.ok then
        return invalid_argument('PLAYER_SAVE_SCOPE_INVALID', {
            field = 'player_save_scope',
        })
    end
    local character_id = validate_content(
        raw_get(input, 'character_id'),
        'char_',
        'character_id'
    )
    if not character_id.ok then
        return invalid_argument('CHARACTER_ID_INVALID', {
            field = 'character_id',
        })
    end
    local request_id = validate_component(
        raw_get(input, 'request_id') or 'request_character_build',
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

    local state = STATES[self]
    if state == nil then
        return invalid_argument('SERVICE_AUTHORITY_REQUIRED')
    end

    local identity = {
        player_save_scope = scope.value,
        character_id = character_id.value,
        request_id = request_id.value,
        correlation_id = correlation_id.value,
        attempt = 1,
    }
    local loaded = load_character(self, identity, invoke)
    if not loaded.ok then
        return loaded
    end
    if loaded.value.status ~= 'FOUND' then
        return fail('CHARACTER_NOT_OWNED', 'CHARACTER_NOT_FOUND', {
            character_id = character_id.value,
            player_save_scope = scope.value,
            status = loaded.value.status,
        }, false)
    end

    local built = state.rules:build_combatant_snapshot(
        loaded.value.state,
        {
            rules_version = raw_get(input, 'rules_version'),
            side = raw_get(input, 'side'),
            position_index = raw_get(input, 'position_index'),
            actor_id = raw_get(input, 'actor_id'),
            ai_profile_id = raw_get(input, 'ai_profile_id'),
            view_context = raw_get(input, 'view_context'),
            equipment_contributions = raw_get(input, 'equipment_contributions'),
            martial_contributions = raw_get(input, 'martial_contributions'),
            progression_contributions = raw_get(
                input,
                'progression_contributions'
            ),
            equipment_snapshot = raw_get(input, 'equipment_snapshot'),
            martial_snapshot = raw_get(input, 'martial_snapshot'),
            progression_snapshot = raw_get(input, 'progression_snapshot'),
            martial_loadout = raw_get(input, 'martial_loadout'),
            initial_status_ids = raw_get(input, 'initial_status_ids'),
        }
    )
    if not built.ok then
        return built
    end
    built.value.character_save_revision = loaded.value.character_save_revision
    return result_ok(built.value)
end

function Service:get_character_detail(input, invoke)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED', { field = 'input' })
    end
    local scope = validate_component(
        raw_get(input, 'player_save_scope'),
        'player_save_scope'
    )
    if not scope.ok then
        return invalid_argument('PLAYER_SAVE_SCOPE_INVALID', {
            field = 'player_save_scope',
        })
    end
    local character_id = validate_content(
        raw_get(input, 'character_id'),
        'char_',
        'character_id'
    )
    if not character_id.ok then
        return invalid_argument('CHARACTER_ID_INVALID', {
            field = 'character_id',
        })
    end
    local request_id = validate_component(
        raw_get(input, 'request_id') or 'request_character_detail',
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

    local state = STATES[self]
    if state == nil then
        return invalid_argument('SERVICE_AUTHORITY_REQUIRED')
    end

    local identity = {
        player_save_scope = scope.value,
        character_id = character_id.value,
        request_id = request_id.value,
        correlation_id = correlation_id.value,
        attempt = 1,
    }
    local loaded = load_character(self, identity, invoke)
    if not loaded.ok then
        return loaded
    end
    if loaded.value.status ~= 'FOUND' then
        return fail('CHARACTER_NOT_OWNED', 'CHARACTER_NOT_FOUND', {
            character_id = character_id.value,
            player_save_scope = scope.value,
            status = loaded.value.status,
        }, false)
    end

    local detail = state.rules:get_detail(
        loaded.value.state,
        raw_get(input, 'view_context')
    )
    if not detail.ok then
        return detail
    end
    detail.value.character_save_revision = loaded.value.character_save_revision
    detail.value.source_revisions.character_save_revision =
        loaded.value.character_save_revision
    return result_ok(detail.value)
end

function Service:query_transaction(pending, invoke, context_input)
    if type_value(pending) ~= 'table'
        or get_metatable(pending) ~= nil
        or type_value(raw_get(pending, 'query_proof')) ~= 'table'
    then
        return invalid_argument('PENDING_QUERY_PROOF_REQUIRED', {
            field = 'pending',
        })
    end

    local proof = pending.query_proof
    local request_id = 'request_character_query'
    local correlation_id = request_id
    local attempt = 1
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
        if raw_get(context_input, 'attempt') ~= nil then
            if not is_safe_integer(context_input.attempt, 1, 1000000) then
                return invalid_argument('ATTEMPT_INVALID', {
                    field = 'attempt',
                })
            end
            attempt = context_input.attempt
        end
    end

    local command = {}
    local source_command = proof.command
    if type_value(source_command) == 'table' then
        local field_name
        local field_value
        field_name, field_value = next(source_command, nil)
        while field_name ~= nil do
            if field_value ~= nil then
                command[field_name] = field_value
            end
            field_name, field_value = next(source_command, field_name)
        end
    end

    local query_request = {
        context = {
            request_id = request_id,
            correlation_id = correlation_id,
            attempt = attempt,
        },
        player_save_scope = proof.player_save_scope,
        original_request_key = proof.original_request_key,
        receipt_id = proof.receipt_id,
        transaction_id = proof.transaction_id,
        operation_type = proof.operation_type,
        command_digest = proof.command_digest,
        expected_result_digest = proof.expected_result_digest,
        expected_character_save_revision =
            proof.expected_character_save_revision,
        command = command,
    }

    local queried = invoke_port(
        invoke,
        'query_character_transaction',
        query_request
    )
    if not queried.ok then
        return queried
    end
    return result_ok({
        status = queried.value.status,
        value = queried.value,
        pending = pending,
    })
end

-- Reconcile an UNKNOWN write. Never re-admits the original commit.
function Service:reconcile_unknown(pending, invoke, context_input)
    local queried = self:query_transaction(pending, invoke, context_input)
    if not queried.ok then
        return queried
    end
    local status = queried.value.status
    if status == 'COMMITTED' then
        return result_ok({
            status = 'COMMITTED',
            pending = pending,
            value = queried.value.value,
            result = queried.value.value.result,
            character_save_revision =
                queried.value.value.character_save_revision,
            receipt_save_revision =
                queried.value.value.receipt_save_revision,
            reconciled = true,
        })
    end
    if status == 'NOT_FOUND'
        or status == 'FAILED_BEFORE_APPLY'
        or status == 'COMPENSATED'
    then
        return fail(
            'TRANSACTION_NOT_COMMITTED',
            'QUERY_TERMINAL_NON_COMMITTED',
            {
                query_status = status,
                receipt_id = pending.receipt_id,
                transaction_id = pending.transaction_id,
            },
            false
        )
    end
    return fail(
        'PLATFORM_RESULT_UNKNOWN',
        'QUERY_STILL_UNKNOWN',
        {
            query_status = status,
            receipt_id = pending.receipt_id,
            transaction_id = pending.transaction_id,
            recovery = 'QUERY_CHARACTER_TRANSACTION',
        },
        true
    )
end

-- Build an offline invoke adapter for ScriptedPort-backed fakes.
-- Completes only after tick; never treats admission as success.
function CharacterWriteService.fake_invoke(repository)
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
        if admission.value == nil
            or admission.value.accepted ~= true
        then
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
                {
                    operation = operation_name,
                    processed_deliveries = ticked.value
                        and ticked.value.processed_deliveries,
                },
                true
            )
        end
        return completion
    end
end

function CharacterWriteService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid_argument('OPTIONS_REQUIRED')
    end
    local rules = raw_get(options, 'rules')
    local repository = raw_get(options, 'repository')
    if type_value(rules) ~= 'table'
        or type_value(rules.create_owned) ~= 'function'
        or type_value(rules.plan_experience_grant) ~= 'function'
        or type_value(rules.plan_rename) ~= 'function'
        or type_value(rules.get_detail) ~= 'function'
        or type_value(rules.build_combatant_snapshot) ~= 'function'
    then
        return invalid_argument('CHARACTER_RULES_REQUIRED', {
            field = 'rules',
        })
    end
    if type_value(repository) ~= 'table' then
        return invalid_argument('REPOSITORY_REQUIRED', {
            field = 'repository',
        })
    end
    if type_value(repository.get_contract) == 'function' then
        local contract = repository:get_contract()
        if contract ~= CharacterRepository then
            return invalid_argument('REPOSITORY_CONTRACT_MISMATCH', {
                field = 'repository',
            })
        end
    end

    local save_bridge = raw_get(options, 'save_bridge')
    if save_bridge ~= nil
        and not CharacterSaveBridge.is_authority(save_bridge)
    then
        return invalid_argument('SAVE_BRIDGE_AUTHORITY_REQUIRED', {
            field = 'save_bridge',
        })
    end
    local event_bus = raw_get(options, 'event_bus')
    if event_bus ~= nil
        and not CharacterEventBus.is_authority(event_bus)
    then
        return invalid_argument('EVENT_BUS_AUTHORITY_REQUIRED', {
            field = 'event_bus',
        })
    end

    local economy_service = raw_get(options, 'economy_service')
    if economy_service ~= nil then
        if type_value(economy_service) ~= 'table'
            or type_value(economy_service.prepare_reward) ~= 'function'
            or type_value(economy_service.grant_prepared_reward) ~= 'function'
        then
            return invalid_argument('ECONOMY_SERVICE_REQUIRED', {
                field = 'economy_service',
            })
        end
    end

    local service = set_metatable({}, Service)
    STATES[service] = {
        rules = rules,
        repository = repository,
        save_bridge = save_bridge,
        event_bus = event_bus,
        economy_service = economy_service,
    }
    return result_ok(service)
end

return CharacterWriteService
