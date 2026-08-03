local FeatureFlags = require 'wzx.config.feature_flags'
local FoundationSchema = require 'wzx.config.schema.foundation'
local Result = require 'wzx.domain.common.result'
local PortContract = require 'wzx.application.ports.port_contract'

local SaveStore = require 'wzx.application.ports.save_store'
local ClockService = require 'wzx.application.ports.clock_service'
local RankService = require 'wzx.application.ports.rank_service'
local OpenArchiveService = require 'wzx.application.ports.open_archive_service'
local PlatformStore = require 'wzx.application.ports.platform_store'
local GachaService = require 'wzx.application.ports.gacha_service'

local AppFactory = {}
local App = {}
local APP_STATES = setmetatable({}, { __mode = 'k' })

local PORTS = {
    { key = 'save_store', spec = SaveStore },
    { key = 'clock_service', spec = ClockService },
    { key = 'rank_service', spec = RankService },
    { key = 'open_archive_service', spec = OpenArchiveService },
    { key = 'platform_store', spec = PlatformStore },
    { key = 'gacha_service', spec = GachaService },
}

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err('BOOTSTRAP_INVALID', 'error.bootstrap.invalid', false, details)
end

local function copy_flags(flags)
    local copy = {}
    local key
    local value
    for key, value in pairs(flags) do
        copy[key] = value
    end
    return copy
end

local function read_only_facade(target, label, cache)
    local facade

    if type(target) ~= 'table' then
        return target
    end
    cache = cache or setmetatable({}, { __mode = 'k' })
    if cache[target] ~= nil then
        return cache[target]
    end
    facade = {}
    cache[target] = facade
    return setmetatable(facade, {
        __index = function(_, key)
            local value = target[key]
            if type(value) == 'table' then
                return read_only_facade(
                    value,
                    label .. '.' .. tostring(key),
                    cache
                )
            end
            if type(value) == 'function' then
                return function(_, ...)
                    return value(target, ...)
                end
            end
            return value
        end,
        __newindex = function()
            error(label .. ' is read-only', 2)
        end,
        __metatable = false,
    })
end

local APP_METATABLE = {
    __index = function(app, key)
        local method = App[key]
        local state
        if method ~= nil then
            return method
        end
        state = APP_STATES[app]
        if state == nil then
            return nil
        end
        if key == 'services' then
            return state.services_view
        end
        if key == 'schemas' then
            return state.schemas_view
        end
        return nil
    end,
    __newindex = function()
        error('application instance is read-only', 2)
    end,
    __metatable = false,
}

function App:start()
    local state = APP_STATES[self]
    if state.state == 'STOPPED' then
        return invalid('STOPPED_APP_CANNOT_RESTART')
    end
    if state.state == 'RUNNING' then
        return Result.ok(self:get_status())
    end
    state.state = 'RUNNING'
    state.generation = state.generation + 1
    return Result.ok(self:get_status())
end

function App:stop()
    local state = APP_STATES[self]
    if state.state == 'STOPPED' then
        return Result.ok(self:get_status())
    end
    state.state = 'STOPPED'
    return Result.ok(self:get_status())
end

function App:get_status()
    local state = APP_STATES[self]
    return {
        state = state.state,
        generation = state.generation,
        foundation_contract_version = self.schemas.versions.FOUNDATION_CONTRACT_VERSION,
        feature_flags = copy_flags(state.feature_flags),
        gameplay_systems_registered = self.schemas.registrar_count,
    }
end

function AppFactory.create(dependencies, options)
    if type(dependencies) ~= 'table' then
        return invalid('DEPENDENCIES_TABLE_REQUIRED')
    end
    if options == nil then
        options = {}
    elseif type(options) ~= 'table' then
        return invalid('OPTIONS_TABLE_REQUIRED')
    end

    local services = {}
    local index
    for index = 1, #PORTS do
        local definition = PORTS[index]
        local implementation = dependencies[definition.key]
        local checked = PortContract.validate_implementation(
            definition.spec,
            implementation
        )
        if not checked.ok then
            return invalid('PORT_IMPLEMENTATION_INVALID', {
                port_key = definition.key,
                cause = checked.error,
            })
        end
        local guarded = PortContract.guard_implementation(
            definition.spec,
            implementation
        )
        if not guarded.ok then
            return invalid('PORT_IMPLEMENTATION_GUARD_FAILED', {
                port_key = definition.key,
                cause = guarded.error,
            })
        end
        services[definition.key] = guarded.value
    end

    local schemas = FoundationSchema.create({
        registrars = options.system_registrars or {},
    })
    if not schemas.ok then
        return invalid('FOUNDATION_SCHEMA_CREATION_FAILED', { cause = schemas.error })
    end

    local release_flags = options.release_flags or FeatureFlags.safe_defaults()
    local feature_flags = FeatureFlags.resolve(
        release_flags,
        options.capabilities or {},
        options.compliance_gates or {}
    )
    if not feature_flags.ok then
        return invalid('FEATURE_FLAG_RESOLUTION_FAILED', { cause = feature_flags.error })
    end

    local app = {}
    APP_STATES[app] = {
        state = 'CREATED',
        generation = 0,
        feature_flags = copy_flags(feature_flags.value),
        services_view = read_only_facade(services, 'application services'),
        schemas_view = read_only_facade(schemas.value, 'application schemas'),
    }
    setmetatable(app, APP_METATABLE)
    return Result.ok(app)
end

function AppFactory.port_definitions()
    local copy = {}
    local index
    for index = 1, #PORTS do
        copy[index] = {
            key = PORTS[index].key,
            spec = PORTS[index].spec,
        }
    end
    return copy
end

return AppFactory
