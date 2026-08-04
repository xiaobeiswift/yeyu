-- Application relay: dialogue durable facts → quest fact consumer.
-- Dialogue never mutates quest state directly.

local Result = require 'wzx.domain.common.result'
local DialogueErrorCodes = require 'wzx.domain.dialogue.error_codes'

local DialogueQuestBridge = {}
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
        'error.dialogue.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(DialogueErrorCodes.DIALOGUE_ARGUMENT_INVALID, reason, details, false)
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
            DialogueErrorCodes.DIALOGUE_BUILD_INVALID,
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

function DialogueQuestBridge.relay_choice(fact_consumer, choose_result)
    if not is_fact_consumer(fact_consumer) then
        return invalid('FACT_CONSUMER_REQUIRED', { field = 'fact_consumer' })
    end
    if type_value(choose_result) ~= 'table' or get_metatable(choose_result) ~= nil then
        return invalid('CHOOSE_RESULT_REQUIRED')
    end
    return relay_one(fact_consumer, raw_get(choose_result, 'choice_event'))
end

function DialogueQuestBridge.relay_completion(fact_consumer, complete_result)
    if not is_fact_consumer(fact_consumer) then
        return invalid('FACT_CONSUMER_REQUIRED', { field = 'fact_consumer' })
    end
    if type_value(complete_result) ~= 'table' or get_metatable(complete_result) ~= nil then
        return invalid('COMPLETE_RESULT_REQUIRED')
    end
    return relay_one(fact_consumer, raw_get(complete_result, 'completion_event'))
end

--- Run a linear LINE → ... path and optional choice, then complete and relay.
-- Intended for offline integration tests and simple hosts.
function DialogueQuestBridge.run_to_completion(dialogue_service, quest_service, script)
    if type_value(dialogue_service) ~= 'table'
        or type_value(dialogue_service.start) ~= 'function'
    then
        return invalid('DIALOGUE_SERVICE_REQUIRED')
    end
    if quest_service ~= nil and not is_fact_consumer(quest_service) then
        return invalid('QUEST_SERVICE_INVALID')
    end
    if type_value(script) ~= 'table' or get_metatable(script) ~= nil then
        return invalid('SCRIPT_REQUIRED')
    end

    local started = dialogue_service:start(script.start)
    if not started.ok then
        return started
    end

    local session = started.value.session
    local node = started.value.node
    local choice_events = {}
    local guard = 0
    while node ~= nil and node.node_type ~= 'END' and guard < 64 do
        guard = guard + 1
        if node.node_type == 'LINE' or node.node_type == 'NARRATION' then
            local advanced = dialogue_service:advance({
                session_id = session.session_id,
                expected_revision = session.session_revision,
                node_id = node.node_id,
            })
            if not advanced.ok then
                return advanced
            end
            session = advanced.value.session
            node = advanced.value.node
        elseif node.node_type == 'CHOICE' then
            local choice_id = raw_get(script, 'choice_id')
            if choice_id == nil and node.choices ~= nil and node.choices[1] ~= nil then
                choice_id = node.choices[1].choice_id
            end
            local chosen = dialogue_service:choose({
                session_id = session.session_id,
                expected_revision = session.session_revision,
                choice_id = choice_id,
                choice_receipt_id = raw_get(script, 'choice_receipt_id')
                    or ('rcpt_choice_' .. tostring(guard)),
                command_id = raw_get(script, 'choice_command_id'),
            })
            if not chosen.ok then
                return chosen
            end
            if quest_service ~= nil and chosen.value.choice_event ~= nil then
                local relayed = DialogueQuestBridge.relay_choice(
                    quest_service,
                    chosen.value
                )
                if not relayed.ok then
                    return relayed
                end
                choice_events[#choice_events + 1] = relayed.value
            end
            session = chosen.value.session
            node = chosen.value.node
        else
            return fail(
                DialogueErrorCodes.DIALOGUE_CONFIG_BROKEN,
                'UNSUPPORTED_NODE_IN_SCRIPT',
                { node_type = node.node_type }
            )
        end
    end

    if node == nil or node.node_type ~= 'END' then
        return fail(
            DialogueErrorCodes.DIALOGUE_PHASE_INVALID,
            'END_NODE_NOT_REACHED',
            { state = session and session.state }
        )
    end

    local completed = dialogue_service:complete({
        session_id = session.session_id,
        completion_receipt_id = raw_get(script, 'completion_receipt_id')
            or 'rcpt_dialogue_complete_01',
        command_id = raw_get(script, 'complete_command_id'),
    })
    if not completed.ok then
        return completed
    end

    local completion_relay = nil
    if quest_service ~= nil then
        local relayed = DialogueQuestBridge.relay_completion(
            quest_service,
            completed.value
        )
        if not relayed.ok then
            return relayed
        end
        completion_relay = relayed.value
    end

    return result_ok({
        complete = completed.value,
        choice_relays = choice_events,
        completion_relay = completion_relay,
    })
end

return DialogueQuestBridge
