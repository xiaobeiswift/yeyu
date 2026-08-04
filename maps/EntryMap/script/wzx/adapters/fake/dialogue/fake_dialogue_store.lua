local DialogueSession = require 'wzx.domain.dialogue.dialogue_session'
local DialogueSaveCodec = require 'wzx.domain.dialogue.dialogue_save_codec'
local Result = require 'wzx.domain.common.result'

local FakeDialogueStore = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Store = {}
Store.__index = Store
Store.__newindex = function()
    error_value('fake dialogue store is read-only', 2)
end
Store.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'INVALID_ARGUMENT',
        'error.dialogue.fake_store_invalid',
        false,
        details
    )
end

local function copy_map(source)
    local out = {}
    local key
    local value
    for key, value in raw_next, source do
        if type_value(value) == 'table' then
            local nested = {}
            local nested_key
            local nested_value
            for nested_key, nested_value in raw_next, value do
                nested[nested_key] = nested_value
            end
            out[key] = nested
        else
            out[key] = value
        end
    end
    return out
end

local function copy_session(session)
    if session == nil then
        return nil
    end
    local out = {}
    local key
    local value
    for key, value in raw_next, session do
        out[key] = value
    end
    return out
end

-- Runtime copy keeps active session + command receipts; codec only covers durable slot-2.
local function copy_facts(facts)
    if type_value(facts) ~= 'table' or get_metatable(facts) ~= nil then
        return invalid('FACTS_TABLE_REQUIRED')
    end
    return result_ok({
        facts_revision = facts.facts_revision or 0,
        active_session = copy_session(facts.active_session),
        memories = copy_map(facts.memories or {}),
        completed = copy_map(facts.completed or {}),
        event_receipts = copy_map(facts.event_receipts or {}),
        command_receipts = copy_map(facts.command_receipts or {}),
    })
end

function FakeDialogueStore.new(options)
    options = options or {}
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED')
    end
    local seed = raw_get(options, 'facts')
    local facts
    if seed == nil then
        facts = DialogueSession.empty()
    else
        local copied = copy_facts(seed)
        if not copied.ok then
            return copied
        end
        facts = copied.value
    end
    local view = set_metatable({}, Store)
    STATES[view] = {
        facts = facts,
    }
    return result_ok(view)
end

function Store:get_facts()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return copy_facts(state.facts)
end

function Store:replace_facts(facts)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local copied = copy_facts(facts)
    if not copied.ok then
        return copied
    end
    state.facts = copied.value
    return result_ok(true)
end

function Store:encode_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return DialogueSaveCodec.encode(state.facts)
end

return FakeDialogueStore
