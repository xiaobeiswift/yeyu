-- CycleDefinition normalization and invariants (system 17 pure domain).
-- No Y3, no wall-clock, no math.random.

local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local CycleErrorCodes = require 'wzx.domain.cycle.error_codes'

local CycleDefinition = {}
local get_metatable = getmetatable
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_content = RuntimeId.validate_content

local MAX_SAFE_INTEGER = 9007199254740991
local MIN_TIMEZONE_OFFSET = -43200
local MAX_TIMEZONE_OFFSET = 50400
local MAX_RESET_OFFSET = 86399

local KINDS = {
    SERVER_DAY = true,
    SERVER_WEEK = true,
    EVENT = true,
    SEASON = true,
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.cycle.' .. string.lower(code),
        false,
        details
    )
end

local function invalid_definition(reason, details)
    return fail(CycleErrorCodes.CYCLE_DEFINITION_INVALID, reason, details)
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

--- Normalize and validate a raw CycleDefinition table.
--- @return Result{ok=true,value=def}|Result{ok=false,error=...}
function CycleDefinition.normalize(raw)
    if type_value(raw) ~= 'table' or get_metatable(raw) ~= nil then
        return invalid_definition('TABLE_REQUIRED', { field = 'raw' })
    end

    local cycle_def_id = raw_get(raw, 'cycle_def_id')
    local id_check = validate_content(cycle_def_id, 'cycle_', 'cycle_def_id')
    if not id_check.ok then
        return invalid_definition('CYCLE_DEF_ID_INVALID', {
            field = 'cycle_def_id',
            value = cycle_def_id,
        })
    end

    local definition_version = raw_get(raw, 'definition_version')
    if not is_safe_integer(definition_version, 1, MAX_SAFE_INTEGER) then
        return invalid_definition('DEFINITION_VERSION_INVALID', {
            field = 'definition_version',
            value = definition_version,
        })
    end

    local kind = raw_get(raw, 'kind')
    if type_value(kind) ~= 'string' or KINDS[kind] ~= true then
        return invalid_definition('KIND_INVALID', {
            field = 'kind',
            value = kind,
        })
    end

    local timezone_offset_seconds = raw_get(raw, 'timezone_offset_seconds')
    if not is_safe_integer(
        timezone_offset_seconds,
        MIN_TIMEZONE_OFFSET,
        MAX_TIMEZONE_OFFSET
    ) then
        return invalid_definition('TIMEZONE_OFFSET_INVALID', {
            field = 'timezone_offset_seconds',
            value = timezone_offset_seconds,
        })
    end

    local reset_offset_seconds = raw_get(raw, 'reset_offset_seconds')
    if not is_safe_integer(reset_offset_seconds, 0, MAX_RESET_OFFSET) then
        return invalid_definition('RESET_OFFSET_INVALID', {
            field = 'reset_offset_seconds',
            value = reset_offset_seconds,
        })
    end

    local deprecated = raw_get(raw, 'deprecated')
    if type_value(deprecated) ~= 'boolean' then
        return invalid_definition('DEPRECATED_INVALID', {
            field = 'deprecated',
            value = deprecated,
        })
    end

    local grace_seconds = raw_get(raw, 'grace_seconds')
    if grace_seconds == nil then
        grace_seconds = 0
    end
    if not is_safe_integer(grace_seconds, 0, MAX_SAFE_INTEGER) then
        return invalid_definition('GRACE_SECONDS_INVALID', {
            field = 'grace_seconds',
            value = grace_seconds,
        })
    end

    local week_start = raw_get(raw, 'week_start')
    local event_start_at = raw_get(raw, 'event_start_at')
    local event_end_at = raw_get(raw, 'event_end_at')
    local parent_cycle_def_id = raw_get(raw, 'parent_cycle_def_id')

    if kind == 'SERVER_WEEK' then
        if not is_safe_integer(week_start, 1, 7) then
            return invalid_definition('WEEK_START_REQUIRED', {
                field = 'week_start',
                value = week_start,
            })
        end
    elseif week_start ~= nil then
        if not is_safe_integer(week_start, 1, 7) then
            return invalid_definition('WEEK_START_INVALID', {
                field = 'week_start',
                value = week_start,
            })
        end
    end

    if kind == 'EVENT' or kind == 'SEASON' then
        if not is_safe_integer(event_start_at, 0, MAX_SAFE_INTEGER) then
            return invalid_definition('EVENT_START_AT_REQUIRED', {
                field = 'event_start_at',
                value = event_start_at,
            })
        end
        if not is_safe_integer(event_end_at, 0, MAX_SAFE_INTEGER) then
            return invalid_definition('EVENT_END_AT_REQUIRED', {
                field = 'event_end_at',
                value = event_end_at,
            })
        end
        if event_end_at <= event_start_at then
            return invalid_definition('EVENT_WINDOW_INVALID', {
                field = 'event_end_at',
                event_start_at = event_start_at,
                event_end_at = event_end_at,
            })
        end
    else
        if event_start_at ~= nil or event_end_at ~= nil then
            if event_start_at ~= nil
                and not is_safe_integer(event_start_at, 0, MAX_SAFE_INTEGER)
            then
                return invalid_definition('EVENT_START_AT_INVALID', {
                    field = 'event_start_at',
                    value = event_start_at,
                })
            end
            if event_end_at ~= nil
                and not is_safe_integer(event_end_at, 0, MAX_SAFE_INTEGER)
            then
                return invalid_definition('EVENT_END_AT_INVALID', {
                    field = 'event_end_at',
                    value = event_end_at,
                })
            end
            if event_start_at ~= nil
                and event_end_at ~= nil
                and event_end_at <= event_start_at
            then
                return invalid_definition('EVENT_WINDOW_INVALID', {
                    field = 'event_end_at',
                    event_start_at = event_start_at,
                    event_end_at = event_end_at,
                })
            end
        end
    end

    if parent_cycle_def_id ~= nil then
        local parent_check = validate_content(
            parent_cycle_def_id,
            'cycle_',
            'parent_cycle_def_id'
        )
        if not parent_check.ok then
            return invalid_definition('PARENT_CYCLE_DEF_ID_INVALID', {
                field = 'parent_cycle_def_id',
                value = parent_cycle_def_id,
            })
        end
        if parent_cycle_def_id == cycle_def_id then
            return invalid_definition('PARENT_CYCLE_SELF_REFERENCE', {
                field = 'parent_cycle_def_id',
                value = parent_cycle_def_id,
            })
        end
    end

    local def = {
        cycle_def_id = cycle_def_id,
        definition_version = definition_version,
        kind = kind,
        timezone_offset_seconds = timezone_offset_seconds,
        reset_offset_seconds = reset_offset_seconds,
        grace_seconds = grace_seconds,
        deprecated = deprecated,
    }

    if week_start ~= nil then
        def.week_start = week_start
    end
    if event_start_at ~= nil then
        def.event_start_at = event_start_at
    end
    if event_end_at ~= nil then
        def.event_end_at = event_end_at
    end
    if parent_cycle_def_id ~= nil then
        def.parent_cycle_def_id = parent_cycle_def_id
    end

    return result_ok(def)
end

return CycleDefinition
