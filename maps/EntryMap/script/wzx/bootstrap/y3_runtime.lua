local AppFactory = require 'wzx.bootstrap.app_factory'
local ReloadGuard = require 'wzx.bootstrap.reload_guard'
local Result = require 'wzx.domain.common.result'
local TableShape = require 'wzx.domain.common.table_shape'
local UnavailableService = require 'wzx.adapters.unavailable.service'

local Y3Runtime = {}
local active_host = nil
local HOST_STATES = setmetatable({}, { __mode = 'k' })
local Host = {}
local register_host, unregister_host = ReloadGuard.claim_host_registrar()

if type(register_host) ~= 'function' or type(unregister_host) ~= 'function' then
    error('Y3Runtime failed to claim the reload host registrar')
end

local function build_safe_services(reason)
    local services = {}
    local definitions = AppFactory.port_definitions()
    local index
    for index = 1, #definitions do
        local created = UnavailableService.create(definitions[index].spec, reason)
        if not created.ok then
            return created
        end
        services[definitions[index].key] = created.value
    end
    return Result.ok(services)
end

local function make_host(app, generation)
    local host = {}
    HOST_STATES[host] = {
        app = app,
        generation = generation,
        mode = 'FOUNDATION_ONLY',
        stopped = false,
    }
    setmetatable(host, {
        __index = Host,
        __newindex = function()
            error('runtime host is read-only', 2)
        end,
        __metatable = false,
    })
    return host
end

function Host:stop()
    local state = HOST_STATES[self]
    if state == nil then
        return Result.err(
            'BOOTSTRAP_INVALID',
            'error.bootstrap.runtime_host_invalid',
            false
        )
    end
    if state.stopped then
        return Result.ok({ state = 'STOPPED', generation = state.generation })
    end

    local invoked, result = pcall(state.app.stop, state.app)
    if not invoked then
        return Result.err(
            'BOOTSTRAP_INVALID',
            'error.bootstrap.runtime_stop_failed',
            false
        )
    end
    local contract = Result.validate(result)
    if not contract.ok then
        return Result.err(
            'BOOTSTRAP_INVALID',
            'error.bootstrap.runtime_stop_result_invalid',
            false
        )
    end
    if not result.ok then
        return result
    end

    state.stopped = true
    if active_host == self then
        active_host = nil
    end
    unregister_host(self)
    if rawget(_G, 'WZX_RUNTIME_HOST') == self then
        rawset(_G, 'WZX_RUNTIME_HOST', nil)
    end
    return result
end

function Host:get_status()
    local state = HOST_STATES[self]
    if state == nil then
        return {
            state = 'INVALID',
            runtime_mode = 'UNKNOWN',
            platform_adapters_verified = false,
        }
    end
    local status = state.app:get_status()
    status.runtime_mode = state.mode
    status.runtime_generation = state.generation
    status.platform_adapters_verified = false
    return status
end

function Y3Runtime.start(options)
    if options == nil then
        options = {}
    elseif type(options) ~= 'table' then
        return Result.err(
            'BOOTSTRAP_INVALID',
            'error.bootstrap.runtime_options_invalid',
            false
        )
    end
    if active_host ~= nil then
        return Result.ok(active_host)
    end
    if options.release_flags ~= nil
        or options.capabilities ~= nil
        or options.compliance_gates ~= nil
    then
        return Result.err(
            'BOOTSTRAP_INVALID',
            'error.bootstrap.foundation_feature_override_forbidden',
            false
        )
    end
    if options.generation ~= nil
        and not TableShape.is_integer(options.generation, 1)
    then
        return Result.err(
            'BOOTSTRAP_INVALID',
            'error.bootstrap.runtime_generation_invalid',
            false
        )
    end

    local services
    if options.services ~= nil then
        services = Result.ok(options.services)
    else
        services = build_safe_services('Y3_SERVICE_CAPABILITY_NOT_YET_VERIFIED')
    end
    if not services.ok then
        return services
    end

    local created = AppFactory.create(services.value, {
        system_registrars = options.system_registrars,
    })
    if not created.ok then
        return created
    end
    local started = created.value:start()
    if not started.ok then
        return started
    end

    local generation = options.generation or 1
    local host = make_host(created.value, generation)
    local registered = register_host(host, function()
        return Host.stop(host)
    end)
    if not registered.ok then
        created.value:stop()
        return registered
    end
    active_host = host
    return Result.ok(active_host)
end

function Y3Runtime.stop()
    if active_host == nil then
        return Result.ok({ state = 'STOPPED' })
    end
    return active_host:stop()
end

function Y3Runtime.get_active_host()
    return active_host
end

return Y3Runtime
