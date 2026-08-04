-- Application relay: settled EncounterCompleted facts → quest fact consumer.
-- Encounter never mutates quest state directly; this bridge only delivers the
-- durable domain event produced after settlement is committed.

local Result = require 'wzx.domain.common.result'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local EncounterQuestBridge = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.encounter.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID, reason, details, false)
end

local function is_fact_consumer(value)
    return type_value(value) == 'table'
        and type_value(value.consume_fact) == 'function'
end

--- Deliver a completion event from a settle result onto a quest-style consumer.
-- @param fact_consumer object with consume_fact(event) → Result
-- @param settle_result the ok value from EncounterService:settle
-- @return ok + { delivered, duplicate?, skipped?, quest? }
function EncounterQuestBridge.relay_completion(fact_consumer, settle_result)
    if not is_fact_consumer(fact_consumer) then
        return invalid('FACT_CONSUMER_REQUIRED', { field = 'fact_consumer' })
    end
    if type_value(settle_result) ~= 'table' or get_metatable(settle_result) ~= nil then
        return invalid('SETTLE_RESULT_REQUIRED', { field = 'settle_result' })
    end

    local event = raw_get(settle_result, 'completion_event')
    if event == nil then
        return result_ok({
            delivered = false,
            skipped = true,
            reason = 'NO_COMPLETION_EVENT',
        })
    end
    if type_value(event) ~= 'table' or get_metatable(event) ~= nil then
        return invalid('COMPLETION_EVENT_INVALID')
    end

    local consumed = fact_consumer:consume_fact(event)
    if not consumed.ok then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'QUEST_FACT_CONSUME_FAILED',
            {
                cause_code = consumed.error and consumed.error.code or 'UNKNOWN',
                event_id = event.event_id,
            },
            consumed.error and consumed.error.retryable == true
        )
    end

    return result_ok({
        delivered = true,
        duplicate = consumed.value.duplicate == true,
        applied = consumed.value.applied == true,
        skipped = false,
        event_id = event.event_id,
        quest = consumed.value,
    })
end

--- Convenience: settle then relay in one call when both services are bound.
-- Does not own encounter authority; caller supplies already-bound services.
function EncounterQuestBridge.settle_and_relay(encounter_service, quest_service, run, input)
    if type_value(encounter_service) ~= 'table'
        or type_value(encounter_service.settle) ~= 'function'
    then
        return invalid('ENCOUNTER_SERVICE_REQUIRED', { field = 'encounter_service' })
    end
    if not is_fact_consumer(quest_service) then
        return invalid('QUEST_SERVICE_REQUIRED', { field = 'quest_service' })
    end

    local settled = encounter_service:settle(run, input)
    if not settled.ok then
        return settled
    end

    local relayed = EncounterQuestBridge.relay_completion(quest_service, settled.value)
    if not relayed.ok then
        return relayed
    end

    return result_ok({
        settle = settled.value,
        quest_relay = relayed.value,
    })
end

return EncounterQuestBridge
