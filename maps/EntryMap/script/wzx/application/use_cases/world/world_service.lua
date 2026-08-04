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

function WorldService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    local world_store = raw_get(options, 'world_store')
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_location) ~= 'function'
    then
        return invalid('WORLD_CATALOG_REQUIRED', { field = 'catalog' })
    end
    if world_store ~= nil and not is_world_store(world_store) then
        return invalid('WORLD_STORE_INVALID', { field = 'world_store' })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        world_store = world_store,
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

function Service:open_chest(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
    end
    local opened = WorldState.open_chest(loaded.value, state.catalog, input)
    if not opened.ok then
        return opened
    end
    local persisted = persist_state(state)
    if not persisted.ok then
        return persisted
    end
    opened.value.persisted = persisted.value.persisted
    return opened
end

function Service:resolve_search(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_state(state)
    if not loaded.ok then
        return loaded
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
