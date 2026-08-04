-- Application facade for system 12 world position/discovery/flags.

local Result = require 'wzx.domain.common.result'
local WorldState = require 'wzx.domain.world.world_state'
local WorldErrorCodes = require 'wzx.domain.world.error_codes'

local WorldService = {}
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
    error_value('world service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

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

local function is_world_store(value)
    return type_value(value) == 'table'
        and type_value(value.get_state) == 'function'
        and type_value(value.replace_state) == 'function'
end

local function is_economy_service(value)
    return type_value(value) == 'table'
        and type_value(value.prepare_reward) == 'function'
        and type_value(value.grant_prepared_reward) == 'function'
end

function WorldService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    local world_store = raw_get(options, 'world_store')
    local economy_service = raw_get(options, 'economy_service')
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_location) ~= 'function'
    then
        return invalid('WORLD_CATALOG_REQUIRED', { field = 'catalog' })
    end
    if world_store ~= nil and not is_world_store(world_store) then
        return invalid('WORLD_STORE_INVALID', { field = 'world_store' })
    end
    if economy_service ~= nil and not is_economy_service(economy_service) then
        return invalid('ECONOMY_SERVICE_INVALID', { field = 'economy_service' })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        world_store = world_store,
        economy_service = economy_service,
        state = WorldState.empty(),
    }
    return result_ok(view)
end

function WorldService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

local function load_state(state)
    if state.world_store == nil then
        return result_ok(state.state)
    end
    local loaded = state.world_store:get_state()
    if not loaded.ok then
        return loaded
    end
    state.state = loaded.value
    return result_ok(state.state)
end

local function persist_state(state)
    if state.world_store == nil then
        return result_ok({ persisted = false })
    end
    local saved = state.world_store:replace_state(state.state)
    if not saved.ok then
        return saved
    end
    return result_ok({ persisted = true })
end

function Service:bootstrap_position(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    local bootstrapped = WorldState.bootstrap_position(
        loaded.value,
        state.catalog,
        input
    )
    if not bootstrapped.ok then
        return bootstrapped
    end
    local persisted = persist_state(state)
    if not persisted.ok then
        return persisted
    end
    bootstrapped.value.persisted = persisted.value.persisted
    return bootstrapped
end

function Service:enter_location(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    local entered = WorldState.enter_location(loaded.value, state.catalog, input)
    if not entered.ok then
        return entered
    end
    local persisted = persist_state(state)
    if not persisted.ok then
        return persisted
    end
    entered.value.persisted = persisted.value.persisted
    return entered
end

function Service:discover_location(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    local discovered = WorldState.discover_location(
        loaded.value,
        state.catalog,
        input
    )
    if not discovered.ok then
        return discovered
    end
    local persisted = persist_state(state)
    if not persisted.ok then
        return persisted
    end
    discovered.value.persisted = persisted.value.persisted
    return discovered
end

function Service:set_flag(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    local set = WorldState.set_flag(loaded.value, state.catalog, input)
    if not set.ok then
        return set
    end
    local persisted = persist_state(state)
    if not persisted.ok then
        return persisted
    end
    set.value.persisted = persisted.value.persisted
    return set
end

function Service:get_position()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    return WorldState.get_position(loaded.value)
end

function Service:get_flag(flag_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    return WorldState.get_flag(loaded.value, state.catalog, flag_id)
end

function Service:is_discovered(location_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    return WorldState.is_discovered(loaded.value, location_id)
end

function Service:list_discovered()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    return WorldState.list_discovered(loaded.value)
end

local function grant_interactable_reward(
    economy_service,
    reward_id,
    source_type,
    occurrence_id,
    purpose_ref,
    receipt_id,
    input
)
    local prepared = economy_service:prepare_reward({
        reward_id = reward_id,
        source_type = source_type,
        source_ref = reward_id,
        source_occurrence_id = occurrence_id,
        overflow_policy = raw_get(input, 'overflow_policy'),
    })
    if not prepared.ok then
        return fail(
            WorldErrorCodes.WORLD_REWARD_GRANT_FAILED,
            'PREPARE_REWARD_FAILED',
            {
                cause_code = prepared.error and prepared.error.code or 'UNKNOWN',
                reward_id = reward_id,
            },
            prepared.error and prepared.error.retryable == true
        )
    end

    local granted = economy_service:grant_prepared_reward({
        prepared = prepared.value,
        receipt_id = receipt_id,
        purpose_type = source_type,
        purpose_ref = purpose_ref,
        player_save_scope = raw_get(input, 'player_save_scope'),
        player_ref = raw_get(input, 'player_ref'),
        request_id = raw_get(input, 'request_id'),
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
    if not granted.ok then
        return fail(
            WorldErrorCodes.WORLD_REWARD_GRANT_FAILED,
            'GRANT_REWARD_FAILED',
            {
                cause_code = granted.error and granted.error.code or 'UNKNOWN',
                reward_id = reward_id,
                receipt_id = receipt_id,
            },
            granted.error and granted.error.retryable == true
        )
    end

    return result_ok({
        status = granted.value.status or 'COMMITTED',
        already_committed = granted.value.already_committed == true,
        receipt_id = granted.value.receipt_id,
        reward_id = reward_id,
        source_type = source_type,
        source_occurrence_id = occurrence_id,
        economy_revision = granted.value.economy_revision,
        save = granted.value.save,
    })
end

function Service:open_chest(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end

    local interactable_id = raw_get(input, 'interactable_id')
    local open_receipt_id = raw_get(input, 'open_receipt_id')
    local interactable = state.catalog:require_interactable(interactable_id)
    if not interactable.ok then
        return interactable
    end
    interactable = interactable.value

    local current = WorldState.get_interactable_state(
        loaded.value,
        state.catalog,
        interactable.id
    )
    if not current.ok then
        return current
    end

    local reward_result = {
        status = 'SKIPPED',
        reason = 'NO_REWARD',
    }
    local terminal_state = 'OPENED'
    local needs_reward = interactable.interactable_type == 'CHEST'
        and interactable.action_ref_id ~= nil
    local already_terminal = current.value.state == 'OPENED'
        or current.value.state == 'REWARD_PENDING'

    if needs_reward and not already_terminal then
        if state.economy_service == nil then
            return fail(
                WorldErrorCodes.WORLD_REWARD_SERVICE_REQUIRED,
                'ECONOMY_SERVICE_REQUIRED_FOR_CHEST',
                {
                    interactable_id = interactable.id,
                    reward_id = interactable.action_ref_id,
                },
                false
            )
        end
        local granted = grant_interactable_reward(
            state.economy_service,
            interactable.action_ref_id,
            'CHEST_OPEN',
            interactable.id,
            interactable.id,
            open_receipt_id,
            input
        )
        if not granted.ok then
            return granted
        end
        reward_result = granted.value
        if reward_result.status == 'PENDING' then
            terminal_state = 'REWARD_PENDING'
        end
    elseif already_terminal and needs_reward then
        reward_result = {
            status = 'SKIPPED',
            reason = 'ALREADY_OPENED',
            reward_id = interactable.action_ref_id,
        }
        terminal_state = current.value.state
    end

    local domain_input = {}
    local key
    local value
    for key, value in pairs(input) do
        domain_input[key] = value
    end
    domain_input.terminal_state = terminal_state
    domain_input.reward_receipt_id = open_receipt_id

    local opened = WorldState.open_chest(loaded.value, state.catalog, domain_input)
    if not opened.ok then
        return opened
    end

    local persisted = persist_state(state)
    if not persisted.ok then
        return persisted
    end
    opened.value.persisted = persisted.value.persisted
    opened.value.reward = reward_result
    return opened
end

function Service:resolve_search(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end

    local interactable_id = raw_get(input, 'interactable_id')
    local search_receipt_id = raw_get(input, 'search_receipt_id')
    local interactable = state.catalog:require_interactable(interactable_id)
    if not interactable.ok then
        return interactable
    end
    interactable = interactable.value

    local current = WorldState.get_interactable_state(
        loaded.value,
        state.catalog,
        interactable.id
    )
    if not current.ok then
        return current
    end

    local reward_result = {
        status = 'SKIPPED',
        reason = 'NO_REWARD',
    }
    local needs_reward = interactable.interactable_type == 'SEARCH'
        and interactable.result_type == 'REWARD'
        and interactable.result_ref_id ~= nil
    local already_terminal = current.value.state == 'COMPLETED'
        or current.value.state == 'REWARD_PENDING'

    if needs_reward and not already_terminal then
        if state.economy_service == nil then
            return fail(
                WorldErrorCodes.WORLD_REWARD_SERVICE_REQUIRED,
                'ECONOMY_SERVICE_REQUIRED_FOR_SEARCH_REWARD',
                {
                    interactable_id = interactable.id,
                    reward_id = interactable.result_ref_id,
                },
                false
            )
        end
        local granted = grant_interactable_reward(
            state.economy_service,
            interactable.result_ref_id,
            'SEARCH_REWARD',
            interactable.id,
            interactable.id,
            search_receipt_id,
            input
        )
        if not granted.ok then
            return granted
        end
        reward_result = granted.value
    elseif already_terminal and needs_reward then
        reward_result = {
            status = 'SKIPPED',
            reason = 'ALREADY_RESOLVED',
            reward_id = interactable.result_ref_id,
        }
    end

    local resolved = WorldState.resolve_search(loaded.value, state.catalog, input)
    if not resolved.ok then
        return resolved
    end
    local persisted = persist_state(state)
    if not persisted.ok then
        return persisted
    end
    resolved.value.persisted = persisted.value.persisted
    resolved.value.reward = reward_result
    return resolved
end

function Service:get_interactable_state(interactable_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    return WorldState.get_interactable_state(
        loaded.value,
        state.catalog,
        interactable_id
    )
end

return WorldService
