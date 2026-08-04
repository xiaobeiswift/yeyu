local Result = require 'wzx.domain.common.result'
local CombatAggregate = require 'wzx.domain.combat.combat_aggregate'
local CombatErrorCodes = require 'wzx.domain.combat.error_codes'

local CombatService = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Service = {}
Service.__index = Service

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.combat.' .. string.lower(code),
        false,
        details
    )
end

function CombatService.new(options)
    options = options or {}
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return fail(CombatErrorCodes.COMBAT_ARGUMENT_INVALID, 'OPTIONS_INVALID')
    end
    local service = set_metatable({
        _session = nil,
    }, Service)
    return result_ok(service)
end

function Service:start_session(input)
    local started = CombatAggregate.start(input)
    if not started.ok then
        return started
    end
    self._session = started.value
    local view = CombatAggregate.get_public_view(self._session)
    if not view.ok then
        return view
    end
    return result_ok({
        session = view.value,
        events = self._session.events,
        revision = self._session.revision,
    })
end

function Service:advance(command)
    if self._session == nil then
        return fail(CombatErrorCodes.COMBAT_STATE_INVALID, 'SESSION_REQUIRED')
    end
    command = command or {}
    if raw_get(command, 'command_type') == nil then
        command.command_type = 'ADVANCE'
    end
    if raw_get(command, 'command_id') == nil then
        command.command_id = 'cmd_advance_' .. tostring(self._session.revision + 1)
    end
    command.combat_id = self._session.combat_id
    local applied = CombatAggregate.apply_command(self._session, command)
    if not applied.ok then
        return applied
    end
    local view = CombatAggregate.get_public_view(self._session)
    if not view.ok then
        return view
    end
    return result_ok({
        session = view.value,
        events = applied.value.events,
        finished = applied.value.finished,
        result = applied.value.result,
        revision = self._session.revision,
    })
end

function Service:forfeit(command)
    command = command or {}
    command.command_type = 'FORFEIT'
    if raw_get(command, 'command_id') == nil then
        command.command_id = 'cmd_forfeit'
    end
    return self:advance(command)
end

function Service:get_session()
    if self._session == nil then
        return fail(CombatErrorCodes.COMBAT_STATE_INVALID, 'SESSION_REQUIRED')
    end
    return CombatAggregate.get_public_view(self._session)
end

return CombatService
