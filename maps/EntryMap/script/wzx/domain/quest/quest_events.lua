-- Durable quest domain facts (system 14).

local DomainEvent = require 'wzx.domain.common.domain_event'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Sha256 = require 'wzx.domain.common.sha256'
local QuestErrorCodes = require 'wzx.domain.quest.error_codes'

local QuestEvents = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local SOURCE_SYSTEM = '14'

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.quest.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(QuestErrorCodes.QUEST_ARGUMENT_INVALID, reason, details)
end

local function hash_event_id(namespace, key)
    local digest, digest_error = Sha256.hex(namespace .. '|' .. key)
    if digest == nil then
        return fail(
            QuestErrorCodes.QUEST_ARGUMENT_INVALID,
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
            QuestErrorCodes.QUEST_ARGUMENT_INVALID,
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

function QuestEvents.build_completed(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local run_id = raw_get(input, 'run_id')
    local quest_id = raw_get(input, 'quest_id')
    local completion_receipt_id = raw_get(input, 'completion_receipt_id')
        or raw_get(input, 'receipt_id')
    local reward_receipt_id = raw_get(input, 'reward_receipt_id')
    local reward_state = raw_get(input, 'reward_state') or 'NOT_REQUIRED'
    local revision = raw_get(input, 'revision') or 1

    local run_check = RuntimeId.validate_derived(run_id, 'run_id')
    if not run_check.ok then
        return invalid('RUN_ID_INVALID')
    end
    local quest_check = RuntimeId.validate_content(quest_id, 'quest_', 'quest_id')
    if not quest_check.ok then
        return invalid('QUEST_ID_INVALID')
    end
    local receipt_check = RuntimeId.validate_derived(
        completion_receipt_id,
        'completion_receipt_id'
    )
    if not receipt_check.ok then
        return invalid('COMPLETION_RECEIPT_INVALID')
    end
    if reward_receipt_id ~= nil then
        local reward_check = RuntimeId.validate_derived(
            reward_receipt_id,
            'reward_receipt_id'
        )
        if not reward_check.ok then
            return invalid('REWARD_RECEIPT_INVALID')
        end
    end
    if type_value(reward_state) ~= 'string' or reward_state == '' then
        return invalid('REWARD_STATE_INVALID')
    end
    if type_value(revision) ~= 'number'
        or revision ~= math.floor(revision)
        or revision < 1
    then
        return invalid('REVISION_INVALID')
    end

    local digest = hash_event_id('QuestCompleted', completion_receipt_id)
    if not digest.ok then
        return digest
    end

    local payload = {
        quest_id = quest_id,
        run_id = run_id,
        receipt_id = completion_receipt_id,
        reward_state = reward_state,
    }
    if reward_receipt_id ~= nil then
        payload.reward_receipt_id = reward_receipt_id
    end

    return finalize({
        event_id = 'quest:completed:' .. digest.value,
        event_type = 'QuestCompleted',
        schema_version = 1,
        aggregate_id = run_id,
        revision = revision,
        source_system = SOURCE_SYSTEM,
        source_occurrence_id = completion_receipt_id,
        payload = payload,
    })
end

return QuestEvents
