-- Application relay: durable traversal facts → quest fact consumer.
-- Traversal never mutates quest state directly.

local Result = require 'wzx.domain.common.result'
local TraversalErrorCodes = require 'wzx.domain.traversal.error_codes'

local TraversalQuestBridge = {}
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
        'error.traversal.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(TraversalErrorCodes.TRAVERSAL_ARGUMENT_INVALID, reason, details, false)
end

local function is_fact_consumer(value)
    return type_value(value) == 'table'
        and type_value(value.consume_fact) == 'function'
end

local function is_domain_event(event)
    return type_value(event) == 'table'
        and type_value(event.event_id) == 'string'
        and type_value(event.event_type) == 'string'
        and type_value(event.payload) == 'table'
end

local function relay_one(fact_consumer, event)
    if event == nil then
        return result_ok({
            delivered = false,
            skipped = true,
            reason = 'NO_EVENT',
        })
    end
    if not is_domain_event(event) then
        return result_ok({
            delivered = false,
            skipped = true,
            reason = 'NOT_DOMAIN_EVENT',
            event_type = type_value(event) == 'table' and event.event_type or nil,
        })
    end
    local consumed = fact_consumer:consume_fact(event)
    if not consumed.ok then
        return fail(
            TraversalErrorCodes.TRAVERSAL_BUILD_INVALID,
            'QUEST_FACT_CONSUME_FAILED',
            {
                cause_code = consumed.error and consumed.error.code or 'UNKNOWN',
                event_id = event.event_id,
                event_type = event.event_type,
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
        event_type = event.event_type,
        quest = consumed.value,
    })
end

function TraversalQuestBridge.relay_complete(fact_consumer, complete_result)
    if not is_fact_consumer(fact_consumer) then
        return invalid('FACT_CONSUMER_REQUIRED', { field = 'fact_consumer' })
    end
    if type_value(complete_result) ~= 'table' or get_metatable(complete_result) ~= nil then
        return invalid('COMPLETE_RESULT_REQUIRED')
    end

    local events = raw_get(complete_result, 'domain_events')
        or raw_get(complete_result, 'events')
        or {}
    if type_value(events) ~= 'table' then
        return invalid('EVENTS_INVALID')
    end

    local relays = {}
    local delivered = 0
    local applied = 0
    local index
    for index = 1, #events do
        local relayed = relay_one(fact_consumer, events[index])
        if not relayed.ok then
            return relayed
        end
        relays[index] = relayed.value
        if relayed.value.delivered then
            delivered = delivered + 1
        end
        if relayed.value.applied then
            applied = applied + 1
        end
    end

    return result_ok({
        delivered_count = delivered,
        applied_count = applied,
        event_count = #events,
        relays = relays,
    })
end

function TraversalQuestBridge.complete_and_relay(traversal_service, quest_service, input)
    if type_value(traversal_service) ~= 'table'
        or type_value(traversal_service.complete_segment) ~= 'function'
    then
        return invalid('TRAVERSAL_SERVICE_REQUIRED')
    end
    if not is_fact_consumer(quest_service) then
        return invalid('QUEST_SERVICE_REQUIRED')
    end

    local completed = traversal_service:complete_segment(input)
    if not completed.ok then
        return completed
    end
    local relayed = TraversalQuestBridge.relay_complete(quest_service, completed.value)
    if not relayed.ok then
        return relayed
    end
    return result_ok({
        complete = completed.value,
        quest_relay = relayed.value,
    })
end

return TraversalQuestBridge
