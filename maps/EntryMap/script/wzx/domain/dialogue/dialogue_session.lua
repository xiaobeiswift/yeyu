-- Offline dialogue session authority for system 13.
-- Owns one active session, memories, completed facts, and event receipts.

local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local DialogueErrorCodes = require 'wzx.domain.dialogue.error_codes'
local DialogueEvents = require 'wzx.domain.dialogue.dialogue_events'

local DialogueSession = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_derived = RuntimeId.validate_derived

local MAX_VISITED = 1000
local OPEN = {
    PRESENTING = true,
    WAITING_ADVANCE = true,
    WAITING_CHOICE = true,
    ENDING = true,
}
local TERMINAL = {
    ENDED = true,
    CANCELLED = true,
    FAILED = true,
}

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

function DialogueSession.empty()
    return {
        facts_revision = 0,
        active_session = nil,
        memories = {},
        completed = {},
        event_receipts = {},
        command_receipts = {},
    }
end

local function copy_session(session)
    if session == nil then
        return nil
    end
    return {
        session_id = session.session_id,
        dialogue_id = session.dialogue_id,
        graph_version = session.graph_version,
        rules_version = session.rules_version,
        npc_id = session.npc_id,
        current_node_id = session.current_node_id,
        state = session.state,
        session_revision = session.session_revision,
        visited_node_count = session.visited_node_count,
        start_receipt_id = session.start_receipt_id,
        completion_receipt_id = session.completion_receipt_id,
        completion_key = session.completion_key,
        end_reason = session.end_reason,
        interrupt_policy = session.interrupt_policy,
        save_policy = session.save_policy,
        last_choice_id = session.last_choice_id,
        last_choice_receipt_id = session.last_choice_receipt_id,
    }
end

local function public_node_view(node, choices)
    local view = {
        node_id = node.id,
        node_type = node.node_type,
        text_key = node.text_key,
        speaker_id = node.speaker_id,
        expression_id = node.expression_id,
        skippable = node.skippable,
        end_reason = node.end_reason,
    }
    if choices ~= nil then
        local listed = {}
        local index
        for index = 1, #choices do
            listed[index] = {
                choice_id = choices[index].id,
                entry_order = choices[index].entry_order,
                text_key = choices[index].text_key,
            }
        end
        view.choices = listed
    end
    return view
end

local function apply_memory(facts, key, value)
    if key == nil then
        return
    end
    facts.memories[key] = value
end

local function enter_node(facts, catalog, session, node_id)
    if session.visited_node_count >= MAX_VISITED then
        return fail(DialogueErrorCodes.DIALOGUE_LOOP_GUARD, 'VISITED_LIMIT', {
            visited_node_count = session.visited_node_count,
        })
    end
    local node = catalog:require_node(node_id)
    if not node.ok then
        return node
    end
    node = node.value
    session.current_node_id = node.id
    session.visited_node_count = session.visited_node_count + 1
    session.session_revision = session.session_revision + 1
    apply_memory(facts, node.memory_key, node.memory_value)

    if node.node_type == 'LINE' or node.node_type == 'NARRATION' then
        session.state = 'WAITING_ADVANCE'
        return result_ok({
            session = copy_session(session),
            node = public_node_view(node),
            ended = false,
        })
    end

    if node.node_type == 'CHOICE' then
        local choices = catalog:list_choices_for_set(session.dialogue_id, node.choice_set_id)
        if not choices.ok then
            return choices
        end
        if #choices.value < 1 then
            return fail(
                DialogueErrorCodes.DIALOGUE_CONFIG_BROKEN,
                'CHOICE_SET_EMPTY',
                { choice_set_id = node.choice_set_id }
            )
        end
        session.state = 'WAITING_CHOICE'
        return result_ok({
            session = copy_session(session),
            node = public_node_view(node, choices.value),
            ended = false,
        })
    end

    if node.node_type == 'END' then
        session.state = 'ENDING'
        session.end_reason = node.end_reason or 'COMPLETED'
        return result_ok({
            session = copy_session(session),
            node = public_node_view(node),
            ended = false,
            ready_to_complete = true,
        })
    end

    return fail(
        DialogueErrorCodes.DIALOGUE_CONFIG_BROKEN,
        'NODE_TYPE_UNSUPPORTED',
        { node_type = node.node_type }
    )
end

function DialogueSession.start(facts, catalog, input)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_REQUIRED')
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require_dialogue) ~= 'function' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local session_id = raw_get(input, 'session_id')
    local dialogue_id = raw_get(input, 'dialogue_id')
    local start_receipt_id = raw_get(input, 'start_receipt_id')
    local command_id = raw_get(input, 'command_id')
    local npc_id = raw_get(input, 'npc_id')

    local session_check = validate_derived(session_id, 'session_id')
    if not session_check.ok then
        return invalid('SESSION_ID_INVALID')
    end
    local receipt_check = validate_derived(start_receipt_id, 'start_receipt_id')
    if not receipt_check.ok then
        return invalid('START_RECEIPT_INVALID')
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = facts.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'START' then
            return result_ok({
                session = copy_session(facts.active_session),
                already_started = true,
                command_replay = true,
            })
        end
    end

    if facts.active_session ~= nil and OPEN[facts.active_session.state] then
        return fail(DialogueErrorCodes.DIALOGUE_BUSY, 'ACTIVE_SESSION_EXISTS', {
            session_id = facts.active_session.session_id,
        })
    end

    local dialogue = catalog:require_dialogue(dialogue_id)
    if not dialogue.ok then
        return dialogue
    end
    dialogue = dialogue.value

    if npc_id == nil then
        npc_id = dialogue.default_npc_id
    end

    local session = {
        session_id = session_id,
        dialogue_id = dialogue.id,
        graph_version = dialogue.graph_version,
        rules_version = dialogue.rules_version,
        npc_id = npc_id,
        current_node_id = nil,
        state = 'PRESENTING',
        session_revision = 0,
        visited_node_count = 0,
        start_receipt_id = start_receipt_id,
        completion_receipt_id = nil,
        completion_key = dialogue.completion_key,
        end_reason = nil,
        interrupt_policy = dialogue.interrupt_policy,
        save_policy = dialogue.save_policy,
        last_choice_id = nil,
        last_choice_receipt_id = nil,
    }
    facts.active_session = session
    local entered = enter_node(facts, catalog, session, dialogue.start_node_id)
    if not entered.ok then
        facts.active_session = nil
        return entered
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        facts.command_receipts[command_id] = {
            command_id = command_id,
            session_id = session_id,
            kind = 'START',
        }
    end
    facts.facts_revision = facts.facts_revision + 1
    entered.value.already_started = false
    return entered
end

function DialogueSession.advance(facts, catalog, input)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local session = facts.active_session
    if session == nil or not OPEN[session.state] then
        return fail(DialogueErrorCodes.DIALOGUE_NOT_ACTIVE, 'NO_ACTIVE_SESSION')
    end

    local session_id = raw_get(input, 'session_id')
    local expected_revision = raw_get(input, 'expected_revision')
    local node_id = raw_get(input, 'node_id')
    if session_id ~= session.session_id then
        return fail(DialogueErrorCodes.DIALOGUE_STATE_MISMATCH, 'SESSION_ID_MISMATCH', {
            expected = session.session_id,
            actual = session_id,
        })
    end
    if expected_revision ~= nil and expected_revision ~= session.session_revision then
        return fail(DialogueErrorCodes.DIALOGUE_STATE_MISMATCH, 'REVISION_MISMATCH', {
            expected = session.session_revision,
            actual = expected_revision,
        })
    end
    if node_id ~= nil and node_id ~= session.current_node_id then
        return fail(DialogueErrorCodes.DIALOGUE_STATE_MISMATCH, 'NODE_MISMATCH', {
            expected = session.current_node_id,
            actual = node_id,
        })
    end
    if session.state ~= 'WAITING_ADVANCE' then
        return fail(DialogueErrorCodes.DIALOGUE_PHASE_INVALID, 'WAITING_ADVANCE_REQUIRED', {
            state = session.state,
        })
    end

    local node = catalog:require_node(session.current_node_id)
    if not node.ok then
        return node
    end
    node = node.value
    if node.next_node_id == nil then
        return fail(
            DialogueErrorCodes.DIALOGUE_CONFIG_BROKEN,
            'NEXT_NODE_MISSING',
            { node_id = node.id }
        )
    end

    local entered = enter_node(facts, catalog, session, node.next_node_id)
    if not entered.ok then
        return entered
    end
    facts.facts_revision = facts.facts_revision + 1
    return entered
end

function DialogueSession.choose(facts, catalog, input)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local session = facts.active_session
    if session == nil or not OPEN[session.state] then
        return fail(DialogueErrorCodes.DIALOGUE_NOT_ACTIVE, 'NO_ACTIVE_SESSION')
    end

    local session_id = raw_get(input, 'session_id')
    local choice_id = raw_get(input, 'choice_id')
    local choice_receipt_id = raw_get(input, 'choice_receipt_id')
    local expected_revision = raw_get(input, 'expected_revision')
    local command_id = raw_get(input, 'command_id')

    if session_id ~= session.session_id then
        return fail(DialogueErrorCodes.DIALOGUE_STATE_MISMATCH, 'SESSION_ID_MISMATCH')
    end
    if expected_revision ~= nil and expected_revision ~= session.session_revision then
        return fail(DialogueErrorCodes.DIALOGUE_STATE_MISMATCH, 'REVISION_MISMATCH', {
            expected = session.session_revision,
            actual = expected_revision,
        })
    end
    if session.state ~= 'WAITING_CHOICE' then
        return fail(DialogueErrorCodes.DIALOGUE_PHASE_INVALID, 'WAITING_CHOICE_REQUIRED', {
            state = session.state,
        })
    end

    local receipt_check = validate_derived(choice_receipt_id, 'choice_receipt_id')
    if not receipt_check.ok then
        return invalid('CHOICE_RECEIPT_INVALID')
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = facts.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'CHOICE' then
            return result_ok({
                session = copy_session(session),
                already_chosen = true,
                command_replay = true,
                choice_event = nil,
            })
        end
    end

    if session.last_choice_receipt_id == choice_receipt_id then
        return result_ok({
            session = copy_session(session),
            already_chosen = true,
            choice_event = nil,
        })
    end

    local choice = catalog:require_choice(choice_id)
    if not choice.ok then
        return choice
    end
    choice = choice.value

    local node = catalog:require_node(session.current_node_id)
    if not node.ok then
        return node
    end
    node = node.value
    if choice.dialogue_id ~= session.dialogue_id
        or choice.choice_set_id ~= node.choice_set_id
    then
        return fail(DialogueErrorCodes.DIALOGUE_CHOICE_STALE, 'CHOICE_NOT_IN_SET', {
            choice_id = choice_id,
            choice_set_id = node.choice_set_id,
        })
    end

    local choice_event = DialogueEvents.build_choice_committed(
        session,
        choice,
        choice_receipt_id
    )
    if not choice_event.ok then
        return choice_event
    end
    if facts.event_receipts[choice_event.value.event_id] ~= nil then
        return fail(
            DialogueErrorCodes.DIALOGUE_RECEIPT_CONFLICT,
            'CHOICE_EVENT_ALREADY_USED',
            { event_id = choice_event.value.event_id }
        )
    end

    apply_memory(facts, choice.choice_memory_key, choice.choice_memory_value)
    session.last_choice_id = choice.id
    session.last_choice_receipt_id = choice_receipt_id
    facts.event_receipts[choice_event.value.event_id] = {
        event_id = choice_event.value.event_id,
        event_type = choice_event.value.event_type,
        receipt_id = choice_receipt_id,
    }

    local entered = enter_node(facts, catalog, session, choice.next_node_id)
    if not entered.ok then
        return entered
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        facts.command_receipts[command_id] = {
            command_id = command_id,
            session_id = session.session_id,
            kind = 'CHOICE',
            choice_id = choice.id,
        }
    end
    facts.facts_revision = facts.facts_revision + 1
    entered.value.choice_event = choice_event.value
    entered.value.already_chosen = false
    return entered
end

function DialogueSession.complete(facts, catalog, input)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local session = facts.active_session
    if session == nil then
        return fail(DialogueErrorCodes.DIALOGUE_NOT_ACTIVE, 'NO_ACTIVE_SESSION')
    end

    local completion_receipt_id = raw_get(input, 'completion_receipt_id')
    local session_id = raw_get(input, 'session_id')
    local command_id = raw_get(input, 'command_id')

    if session_id ~= nil and session_id ~= session.session_id then
        return fail(DialogueErrorCodes.DIALOGUE_STATE_MISMATCH, 'SESSION_ID_MISMATCH')
    end

    local receipt_check = validate_derived(completion_receipt_id, 'completion_receipt_id')
    if not receipt_check.ok then
        return invalid('COMPLETION_RECEIPT_INVALID')
    end

    if session.state == 'ENDED'
        and session.completion_receipt_id == completion_receipt_id
    then
        return result_ok({
            session = copy_session(session),
            already_completed = true,
            completion_event = nil,
        })
    end

    if session.state ~= 'ENDING' then
        return fail(DialogueErrorCodes.DIALOGUE_PHASE_INVALID, 'ENDING_REQUIRED', {
            state = session.state,
        })
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = facts.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'COMPLETE' then
            return result_ok({
                session = copy_session(session),
                already_completed = true,
                command_replay = true,
                completion_event = nil,
            })
        end
    end

    local completion_event = DialogueEvents.build_completed(session, completion_receipt_id)
    if not completion_event.ok then
        return completion_event
    end
    if facts.event_receipts[completion_event.value.event_id] ~= nil then
        return fail(
            DialogueErrorCodes.DIALOGUE_RECEIPT_CONFLICT,
            'COMPLETION_EVENT_ALREADY_USED',
            { event_id = completion_event.value.event_id }
        )
    end

    session.completion_receipt_id = completion_receipt_id
    session.state = 'ENDED'
    session.session_revision = session.session_revision + 1

    if session.completion_key ~= nil then
        local prior = facts.completed[session.completion_key]
        local count = 1
        if prior ~= nil and type_value(prior.count) == 'number' then
            count = prior.count + 1
        end
        facts.completed[session.completion_key] = {
            completion_key = session.completion_key,
            dialogue_id = session.dialogue_id,
            count = count,
            graph_version = session.graph_version,
        }
    end

    facts.event_receipts[completion_event.value.event_id] = {
        event_id = completion_event.value.event_id,
        event_type = completion_event.value.event_type,
        receipt_id = completion_receipt_id,
    }
    if type_value(command_id) == 'string' and command_id ~= '' then
        facts.command_receipts[command_id] = {
            command_id = command_id,
            session_id = session.session_id,
            kind = 'COMPLETE',
        }
    end
    facts.facts_revision = facts.facts_revision + 1
    -- Clear active lock after end; terminal snapshot remains on returned copy.
    local ended = copy_session(session)
    facts.active_session = nil

    return result_ok({
        session = ended,
        already_completed = false,
        completion_event = completion_event.value,
    })
end

function DialogueSession.cancel(facts, input)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local session = facts.active_session
    if session == nil or not OPEN[session.state] then
        return fail(DialogueErrorCodes.DIALOGUE_NOT_ACTIVE, 'NO_ACTIVE_SESSION')
    end
    if session.interrupt_policy == 'DENY' then
        return fail(DialogueErrorCodes.DIALOGUE_INTERRUPT_DENIED, 'INTERRUPT_DENIED')
    end
    if session.state ~= 'WAITING_ADVANCE' and session.state ~= 'WAITING_CHOICE' then
        return fail(DialogueErrorCodes.DIALOGUE_INTERRUPT_DENIED, 'UNSAFE_NODE', {
            state = session.state,
        })
    end
    if raw_get(input, 'session_id') ~= nil
        and input.session_id ~= session.session_id
    then
        return fail(DialogueErrorCodes.DIALOGUE_STATE_MISMATCH, 'SESSION_ID_MISMATCH')
    end

    session.state = 'CANCELLED'
    session.end_reason = 'CANCELLED'
    session.session_revision = session.session_revision + 1
    facts.facts_revision = facts.facts_revision + 1
    local cancelled = copy_session(session)
    facts.active_session = nil
    return result_ok({
        session = cancelled,
    })
end

function DialogueSession.get_active(facts)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_REQUIRED')
    end
    return result_ok(copy_session(facts.active_session))
end

function DialogueSession.get_memory(facts, memory_key)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_REQUIRED')
    end
    return result_ok(facts.memories[memory_key])
end

function DialogueSession.list_memories(facts)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_REQUIRED')
    end
    local keys = {}
    local key
    for key in raw_next, facts.memories do
        keys[#keys + 1] = key
    end
    table_sort(keys, bytewise_string_less)
    local rows = {}
    local index
    for index = 1, #keys do
        rows[index] = {
            memory_key = keys[index],
            memory_value = facts.memories[keys[index]],
        }
    end
    return result_ok(rows)
end

return DialogueSession
