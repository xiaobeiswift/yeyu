local Result = require 'wzx.domain.common.result'

local ReloadGuard = {}
-- The single lifecycle authority is held strongly until an explicit successful
-- stop. A weak key could disappear without decrementing the guard's count and
-- permanently turn a collected host into a phantom authority.
local REGISTERED_HOSTS = {}
local registered_host_count = 0
local registrar_claimed = false

local function blocked(message_key, details)
    return Result.err('RELOAD_BLOCKED', message_key, false, details)
end

-- The registrar is claimed once by Y3Runtime and retained only in its private
-- closure. Public callers can ask the guard to stop a host, but cannot make an
-- arbitrary table authoritative after the runtime has claimed registration.
function ReloadGuard.claim_host_registrar()
    if registrar_claimed then
        return nil, nil
    end
    registrar_claimed = true

    local function register(host, stop_capability)
        if type(host) ~= 'table' or type(stop_capability) ~= 'function' then
            return blocked('error.bootstrap.runtime_authority_invalid')
        end
        if REGISTERED_HOSTS[host] ~= nil then
            return Result.ok(false)
        end
        if registered_host_count ~= 0 then
            return blocked('error.bootstrap.runtime_authority_conflict')
        end
        REGISTERED_HOSTS[host] = stop_capability
        registered_host_count = registered_host_count + 1
        return Result.ok(true)
    end

    local function unregister(host)
        if REGISTERED_HOSTS[host] == nil then
            return Result.ok(false)
        end
        REGISTERED_HOSTS[host] = nil
        registered_host_count = registered_host_count - 1
        return Result.ok(true)
    end

    return register, unregister
end

function ReloadGuard.stop_previous(previous)
    if previous == nil then
        if registered_host_count ~= 0 then
            return blocked('error.bootstrap.previous_runtime_reference_missing')
        end
        return Result.ok(false)
    end
    if type(previous) ~= 'table' then
        return blocked('error.bootstrap.previous_runtime_invalid')
    end

    local stop_capability = REGISTERED_HOSTS[previous]
    if type(stop_capability) ~= 'function' then
        return blocked('error.bootstrap.previous_runtime_unregistered')
    end

    local stopped_ok, stopped_result = pcall(stop_capability)
    if not stopped_ok then
        return blocked('error.bootstrap.previous_runtime_stop_failed')
    end
    local contract = Result.validate(stopped_result)
    if not contract.ok or not stopped_result.ok then
        return blocked(
            'error.bootstrap.previous_runtime_stop_rejected',
            { cause = type(stopped_result) == 'table' and stopped_result.error or nil }
        )
    end
    if REGISTERED_HOSTS[previous] ~= nil then
        REGISTERED_HOSTS[previous] = nil
        registered_host_count = registered_host_count - 1
    end
    return Result.ok(true)
end

return ReloadGuard
