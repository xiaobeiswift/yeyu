-- Build durable dialogue domain facts (system 13 → quest/world consumers).

local DomainEvent = require 'wzx.domain.common.domain_event'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Sha256 = require 'wzx.domain.common.sha256'
local DialogueErrorCodes = require 'wzx.domain.dialogue.error_codes'

local DialogueEvents = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local SOURCE_SYSTEM = '13'

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.dialogue.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(DialogueErrorCodes.DIALOGUE_ARGUMENT_INVALID, reason, details)
end

local function hash_event_id(namespace, key)
    local digest, digest_error = Sha256.hex(namespace .. '|' .. key)
    if digest == nil then
        return fail(
            DialogueErrorCodes.DIALOGUE_BUILD_INVALID,
            'EVENT_ID_HASH_FAILED',
            { reason = digest_error }
        )
    end
    return result_ok(digest)
end

local function finalize(event)
    local validated = DomainEvent.validate(event)
    if not validated.ok then
        return fail(
            DialogueErrorCodes.DIALOGUE_BUILD_INVALID,
            'DOMAIN_EVENT_INVALID',
            {
                cause_code = validated.error and validated.error.code or 'UNKNOWN',
                cause_reason = validated.error
                    and validated.error.details
                    and validated.error.details.reason,
            }
        )
    end
    return DomainEvent.copy(event)
end

function DialogueEvents.build_choice_committed(session, choice, receipt_id)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(choice) ~= 'table' or get_metatable(choice) ~= nil then
        return invalid('CHOICE_REQUIRED')
    end
    local receipt_check = RuntimeId.validate_derived(receipt_id, 'receipt_id')
    if not receipt_check.ok then
        return invalid('RECEIPT_INVALID')
    end

    local digest = hash_event_id('DialogueChoiceCommitted', receipt_id)
    if not digest.ok then
        return digest
    end

    local payload = {
        session_id = session.session_id,
        dialogue_id = session.dialogue_id,
        node_id = session.current_node_id,
        choice_id = choice.id,
        receipt_id = receipt_id,
    }
    if choice.choice_memory_key ~= nil then
        payload.memory_key = choice.choice_memory_key
        payload.memory_value = choice.choice_memory_value
    end

    local event = {
        event_id = 'dlg:choice:' .. digest.value,
        event_type = 'DialogueChoiceCommitted',
        schema_version = 1,
        aggregate_id = session.session_id,
        revision = session.session_revision or 0,
        payload = payload,
        source_system = SOURCE_SYSTEM,
        causation_id = receipt_id,
    }
    return finalize(event)
end

function DialogueEvents.build_completed(session, receipt_id)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    local receipt_check = RuntimeId.validate_derived(receipt_id, 'receipt_id')
    if not receipt_check.ok then
        return invalid('RECEIPT_INVALID')
    end

    local digest = hash_event_id('DialogueCompleted', receipt_id)
    if not digest.ok then
        return digest
    end

    local payload = {
        session_id = session.session_id,
        dialogue_id = session.dialogue_id,
        npc_id = session.npc_id,
        end_reason = session.end_reason or 'COMPLETED',
        receipt_id = receipt_id,
    }
    if session.completion_key ~= nil then
        payload.completion_key = session.completion_key
    end
    if session.completion_key ~= nil then
        -- quest TALK targets dialogue_id; keep both for consumers.
        payload.dialogue_id = session.dialogue_id
    end

    local event = {
        event_id = 'dlg:done:' .. digest.value,
        event_type = 'DialogueCompleted',
        schema_version = 1,
        aggregate_id = session.session_id,
        revision = session.session_revision or 0,
        payload = payload,
        source_system = SOURCE_SYSTEM,
        causation_id = receipt_id,
    }
    return finalize(event)
end

DialogueEvents.SOURCE_SYSTEM = SOURCE_SYSTEM

return DialogueEvents
