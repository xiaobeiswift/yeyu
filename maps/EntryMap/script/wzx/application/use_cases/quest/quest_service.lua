-- Application facade for system 14 quest runs + optional economy reward grant.

local Result = require 'wzx.domain.common.result'
local QuestSession = require 'wzx.domain.quest.quest_session'
local QuestErrorCodes = require 'wzx.domain.quest.error_codes'

local QuestService = {}
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
    error_value('quest service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.quest.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(QuestErrorCodes.QUEST_ARGUMENT_INVALID, reason, details, false)
end

local function is_economy_service(value)
    return type_value(value) == 'table'
        and type_value(value.prepare_reward) == 'function'
        and type_value(value.grant_prepared_reward) == 'function'
end

local function is_quest_store(value)
    return type_value(value) == 'table'
        and type_value(value.get_session) == 'function'
        and type_value(value.replace_session) == 'function'
end

function QuestService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    local quest_store = raw_get(options, 'quest_store')
    local economy_service = raw_get(options, 'economy_service')
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_quest) ~= 'function'
    then
        return invalid('QUEST_CATALOG_REQUIRED', { field = 'catalog' })
    end
    if quest_store ~= nil and not is_quest_store(quest_store) then
        return invalid('QUEST_STORE_INVALID', { field = 'quest_store' })
    end
    if economy_service ~= nil and not is_economy_service(economy_service) then
        return invalid('ECONOMY_SERVICE_INVALID', { field = 'economy_service' })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        quest_store = quest_store,
        economy_service = economy_service,
        session = QuestSession.empty(),
    }
    return result_ok(view)
end

function QuestService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

local function load_session(state)
    if state.quest_store == nil then
        return result_ok(state.session)
    end
    local loaded = state.quest_store:get_session()
    if not loaded.ok then
        return loaded
    end
    state.session = loaded.value
    return result_ok(state.session)
end

local function persist_session(state)
    if state.quest_store == nil then
        return result_ok({ persisted = false })
    end
    local saved = state.quest_store:replace_session(state.session)
    if not saved.ok then
        return saved
    end
    return result_ok({ persisted = true })
end

function Service:accept(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    local accepted = QuestSession.accept(session.value, state.catalog, input)
    if not accepted.ok then
        return accepted
    end
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    accepted.value.persisted = persisted.value.persisted
    return accepted
end

function Service:consume_fact(event)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    local consumed = QuestSession.consume_fact(session.value, state.catalog, event)
    if not consumed.ok then
        return consumed
    end
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    consumed.value.persisted = persisted.value.persisted
    return consumed
end

local function grant_quest_reward(economy_service, run, input)
    local prepared = economy_service:prepare_reward({
        reward_id = run.reward_id,
        source_type = 'QUEST_COMPLETION',
        source_ref = run.quest_id,
        source_occurrence_id = run.run_id,
        overflow_policy = raw_get(input, 'overflow_policy'),
    })
    if not prepared.ok then
        return fail(
            QuestErrorCodes.QUEST_REWARD_FAILED,
            'PREPARE_REWARD_FAILED',
            {
                cause_code = prepared.error and prepared.error.code or 'UNKNOWN',
                reward_id = run.reward_id,
            },
            prepared.error and prepared.error.retryable == true
        )
    end
    local granted = economy_service:grant_prepared_reward({
        prepared = prepared.value,
        receipt_id = raw_get(input, 'completion_receipt_id'),
        purpose_type = 'QUEST_COMPLETION',
        purpose_ref = run.quest_id,
        player_save_scope = raw_get(input, 'player_save_scope'),
        player_ref = raw_get(input, 'player_ref'),
        request_id = raw_get(input, 'request_id'),
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
    if not granted.ok then
        return fail(
            QuestErrorCodes.QUEST_REWARD_FAILED,
            'GRANT_REWARD_FAILED',
            {
                cause_code = granted.error and granted.error.code or 'UNKNOWN',
                reward_id = run.reward_id,
            },
            granted.error and granted.error.retryable == true
        )
    end
    return result_ok({
        status = granted.value.status or 'COMMITTED',
        already_committed = granted.value.already_committed == true,
        receipt_id = granted.value.receipt_id,
        reward_id = run.reward_id,
    })
end

function Service:complete(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end

    local completed = QuestSession.complete(session.value, state.catalog, input)
    if not completed.ok then
        return completed
    end

    local reward_result = nil
    if completed.value.already_completed ~= true
        and completed.value.reward_policy ~= 'NO_REWARD'
        and completed.value.reward_id ~= nil
    then
        if state.economy_service == nil then
            return fail(
                QuestErrorCodes.QUEST_REWARD_REQUIRED,
                'ECONOMY_SERVICE_REQUIRED',
                { reward_id = completed.value.reward_id },
                false
            )
        end
        reward_result = grant_quest_reward(
            state.economy_service,
            completed.value.run,
            input
        )
        if not reward_result.ok then
            return reward_result
        end
        reward_result = reward_result.value
    end

    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    completed.value.reward = reward_result
    completed.value.persisted = persisted.value.persisted
    return completed
end

function Service:abandon(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    local abandoned = QuestSession.abandon(session.value, input)
    if not abandoned.ok then
        return abandoned
    end
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    abandoned.value.persisted = persisted.value.persisted
    return abandoned
end

function Service:get_run(run_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    return QuestSession.get_run(session.value, run_id)
end

function Service:get_journal()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    return QuestSession.get_journal(session.value, state.catalog)
end

return QuestService
