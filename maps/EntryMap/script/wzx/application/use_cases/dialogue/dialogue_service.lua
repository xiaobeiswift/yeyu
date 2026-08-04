-- Application facade for system 13 dialogue sessions + durable facts.

local Result = require 'wzx.domain.common.result'
local DialogueSession = require 'wzx.domain.dialogue.dialogue_session'
local DialogueErrorCodes = require 'wzx.domain.dialogue.error_codes'

local DialogueService = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('dialogue service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

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

local function is_dialogue_store(value)
    return type_value(value) == 'table'
        and type_value(value.get_facts) == 'function'
        and type_value(value.replace_facts) == 'function'
end

function DialogueService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    local dialogue_store = raw_get(options, 'dialogue_store')
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_dialogue) ~= 'function'
    then
        return invalid('DIALOGUE_CATALOG_REQUIRED', { field = 'catalog' })
    end
    if dialogue_store ~= nil and not is_dialogue_store(dialogue_store) then
        return invalid('DIALOGUE_STORE_INVALID', { field = 'dialogue_store' })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        dialogue_store = dialogue_store,
        facts = DialogueSession.empty(),
    }
    return result_ok(view)
end

function DialogueService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

local function load_facts(state)
    if state.dialogue_store == nil then
        return result_ok(state.facts)
    end
    local loaded = state.dialogue_store:get_facts()
    if not loaded.ok then
        return loaded
    end
    state.facts = loaded.value
    return result_ok(state.facts)
end

local function persist_facts(state)
    if state.dialogue_store == nil then
        return result_ok({ persisted = false })
    end
    local saved = state.dialogue_store:replace_facts(state.facts)
    if not saved.ok then
        return saved
    end
    return result_ok({ persisted = true })
end

function Service:start(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local facts = load_facts(state)
    if not facts.ok then
        return facts
    end
    local started = DialogueSession.start(facts.value, state.catalog, input)
    if not started.ok then
        return started
    end
    local persisted = persist_facts(state)
    if not persisted.ok then
        return persisted
    end
    started.value.persisted = persisted.value.persisted
    return started
end

function Service:advance(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local facts = load_facts(state)
    if not facts.ok then
        return facts
    end
    local advanced = DialogueSession.advance(facts.value, state.catalog, input)
    if not advanced.ok then
        return advanced
    end
    local persisted = persist_facts(state)
    if not persisted.ok then
        return persisted
    end
    advanced.value.persisted = persisted.value.persisted
    return advanced
end

function Service:choose(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local facts = load_facts(state)
    if not facts.ok then
        return facts
    end
    local chosen = DialogueSession.choose(facts.value, state.catalog, input)
    if not chosen.ok then
        return chosen
    end
    local persisted = persist_facts(state)
    if not persisted.ok then
        return persisted
    end
    chosen.value.persisted = persisted.value.persisted
    return chosen
end

function Service:complete(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local facts = load_facts(state)
    if not facts.ok then
        return facts
    end
    local completed = DialogueSession.complete(facts.value, state.catalog, input)
    if not completed.ok then
        return completed
    end
    local persisted = persist_facts(state)
    if not persisted.ok then
        return persisted
    end
    completed.value.persisted = persisted.value.persisted
    return completed
end

function Service:cancel(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local facts = load_facts(state)
    if not facts.ok then
        return facts
    end
    local cancelled = DialogueSession.cancel(facts.value, input)
    if not cancelled.ok then
        return cancelled
    end
    local persisted = persist_facts(state)
    if not persisted.ok then
        return persisted
    end
    cancelled.value.persisted = persisted.value.persisted
    return cancelled
end

function Service:get_active()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local facts = load_facts(state)
    if not facts.ok then
        return facts
    end
    return DialogueSession.get_active(facts.value)
end

function Service:get_memory(memory_key)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local facts = load_facts(state)
    if not facts.ok then
        return facts
    end
    return DialogueSession.get_memory(facts.value, memory_key)
end

return DialogueService
