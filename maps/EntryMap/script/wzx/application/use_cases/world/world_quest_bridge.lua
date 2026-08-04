-- Application relay: world durable facts → quest fact consumer.
-- World never mutates quest state directly.

local Result = require 'wzx.domain.common.result'
local WorldErrorCodes = require 'wzx.domain.world.error_codes'

local WorldQuestBridge = {}
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
        'error.world.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(WorldErrorCodes.WORLD_ARGUMENT_INVALID, reason, details, false)
end

local function is_fact_consumer(value)
    return type_value(value) == 'table'
        and type_value(value.consume_fact) == 'function'
end

local function relay_one(fact_consumer, event)
    if event == nil then
        return result_ok({
            delivered = false,
            skipped = true,
            reason = 'NO_EVENT',
        })
    end
    if type_value(event) ~= 'table' or get_metatable(event) ~= nil then
        return invalid('EVENT_INVALID')
    end
    local consumed = fact_consumer:consume_fact(event)
    if not consumed.ok then
        return fail(
            WorldErrorCodes.WORLD_BUILD_INVALID,
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

function WorldQuestBridge.relay_discovery(fact_consumer, discover_result)
    if not is_fact_consumer(fact_consumer) then
        return invalid('FACT_CONSUMER_REQUIRED', { field = 'fact_consumer' })
    end
    if type_value(discover_result) ~= 'table' or get_metatable(discover_result) ~= nil then
        return invalid('DISCOVER_RESULT_REQUIRED')
    end
    return relay_one(fact_consumer, raw_get(discover_result, 'discovery_event'))
end

function WorldQuestBridge.relay_flag(fact_consumer, flag_result)
    if not is_fact_consumer(fact_consumer) then
        return invalid('FACT_CONSUMER_REQUIRED', { field = 'fact_consumer' })
    end
    if type_value(flag_result) ~= 'table' or get_metatable(flag_result) ~= nil then
        return invalid('FLAG_RESULT_REQUIRED')
    end
    return relay_one(fact_consumer, raw_get(flag_result, 'flag_event'))
end

function WorldQuestBridge.discover_and_relay(world_service, quest_service, input)
    if type_value(world_service) ~= 'table'
        or type_value(world_service.discover_location) ~= 'function'
    then
        return invalid('WORLD_SERVICE_REQUIRED')
    end
    if not is_fact_consumer(quest_service) then
        return invalid('QUEST_SERVICE_REQUIRED')
    end

    local discovered = world_service:discover_location(input)
    if not discovered.ok then
        return discovered
    end
    local relayed = WorldQuestBridge.relay_discovery(quest_service, discovered.value)
    if not relayed.ok then
        return relayed
    end
    return result_ok({
        discover = discovered.value,
        quest_relay = relayed.value,
    })
end

return WorldQuestBridge
