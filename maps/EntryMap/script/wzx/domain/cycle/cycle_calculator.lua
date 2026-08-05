-- Trusted period calculator (system 17 pure domain).
-- Converts CycleDefinition + trusted server UTC seconds into a Period.
-- Does not read wall-clock, y3.*, or math.random.

local DecimalInteger = require 'wzx.domain.common.decimal_integer'
local Result = require 'wzx.domain.common.result'
local CycleDefinition = require 'wzx.domain.cycle.cycle_definition'
local CycleErrorCodes = require 'wzx.domain.cycle.error_codes'

local CycleCalculator = {}
local decimal_encode = DecimalInteger.encode
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local MAX_SAFE_INTEGER = 9007199254740991
local SECONDS_PER_DAY = 86400
local SECONDS_PER_WEEK = 7 * SECONDS_PER_DAY
-- day_number 0 (normalized epoch day) is Thursday when Mon=1..Sun=7 (Unix epoch).
local EPOCH_WEEKDAY = 4

local TRUST_STATES = {
    LIVE = true,
    CACHED = true,
    UNAVAILABLE = true,
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

local function invalid_argument(reason, details)
    return fail(CycleErrorCodes.CYCLE_ARGUMENT_INVALID, reason, details)
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

local function compose_cycle_id(cycle_def_id, cycle_number)
    local encoded = decimal_encode(cycle_number)
    if encoded == nil then
        return nil
    end
    return cycle_def_id .. ':' .. encoded
end

local function day_period_bounds(day_number, timezone_offset_seconds, reset_offset_seconds)
    local starts_at = day_number * SECONDS_PER_DAY
        - timezone_offset_seconds
        + reset_offset_seconds
    local ends_at = starts_at + SECONDS_PER_DAY
    return starts_at, ends_at
end

local function week_origin_day(day_number, week_start)
    -- weekday of day_number: Mon=1 .. Sun=7
    local weekday = (day_number + EPOCH_WEEKDAY - 1) % 7 + 1
    local offset = (weekday - week_start + 7) % 7
    return day_number - offset
end

local function build_period(definition, cycle_number, starts_at, ends_at, server_time_utc, trust_state)
    if not is_safe_integer(starts_at, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER)
        or not is_safe_integer(ends_at, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER)
        or ends_at <= starts_at
    then
        return fail(CycleErrorCodes.CYCLE_TIME_INVALID, 'PERIOD_BOUNDS_INVALID', {
            starts_at = starts_at,
            ends_at = ends_at,
        })
    end
    if not is_safe_integer(cycle_number, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER) then
        return fail(CycleErrorCodes.CYCLE_TIME_INVALID, 'CYCLE_NUMBER_OUT_OF_RANGE', {
            cycle_number = cycle_number,
        })
    end

    local cycle_id = compose_cycle_id(definition.cycle_def_id, cycle_number)
    if cycle_id == nil then
        return fail(CycleErrorCodes.CYCLE_TIME_INVALID, 'CYCLE_ID_ENCODE_FAILED', {
            cycle_number = cycle_number,
        })
    end

    return result_ok({
        cycle_def_id = definition.cycle_def_id,
        definition_version = definition.definition_version,
        cycle_id = cycle_id,
        cycle_number = cycle_number,
        starts_at = starts_at,
        ends_at = ends_at,
        observed_server_time = server_time_utc,
        trust_state = trust_state,
    })
end

--- Compute the trusted Period for a definition at a given server UTC second.
--- trust_state must be LIVE | CACHED | UNAVAILABLE; UNAVAILABLE is rejected.
function CycleCalculator.compute_period(definition, server_time_utc, trust_state)
    local normalized = CycleDefinition.normalize(definition)
    if not normalized.ok then
        return normalized
    end
    definition = normalized.value

    if type_value(trust_state) ~= 'string' or TRUST_STATES[trust_state] ~= true then
        return invalid_argument('TRUST_STATE_INVALID', {
            field = 'trust_state',
            value = trust_state,
        })
    end
    if trust_state == 'UNAVAILABLE' then
        return fail(CycleErrorCodes.CYCLE_TRUST_UNAVAILABLE, 'TRUST_STATE_UNAVAILABLE', {
            field = 'trust_state',
            trust_state = trust_state,
        })
    end

    -- Non-negative safe integer (0 allowed); reject NaN / non-integer / out of range.
    if not is_safe_integer(server_time_utc, 0, MAX_SAFE_INTEGER) then
        return fail(CycleErrorCodes.CYCLE_TIME_INVALID, 'SERVER_TIME_INVALID', {
            field = 'server_time_utc',
            value = server_time_utc,
        })
    end

    local kind = definition.kind
    local tz = definition.timezone_offset_seconds
    local reset = definition.reset_offset_seconds

    if kind == 'SERVER_DAY' then
        local normalized_time = server_time_utc + tz - reset
        local cycle_number = math_floor(normalized_time / SECONDS_PER_DAY)
        local starts_at, ends_at = day_period_bounds(cycle_number, tz, reset)
        return build_period(
            definition,
            cycle_number,
            starts_at,
            ends_at,
            server_time_utc,
            trust_state
        )
    end

    if kind == 'SERVER_WEEK' then
        local week_start = raw_get(definition, 'week_start')
        local normalized_time = server_time_utc + tz - reset
        local day_number = math_floor(normalized_time / SECONDS_PER_DAY)
        local origin_day = week_origin_day(day_number, week_start)
        local cycle_number = math_floor(origin_day / 7)
        local starts_at = origin_day * SECONDS_PER_DAY - tz + reset
        local ends_at = starts_at + SECONDS_PER_WEEK
        return build_period(
            definition,
            cycle_number,
            starts_at,
            ends_at,
            server_time_utc,
            trust_state
        )
    end

    if kind == 'EVENT' or kind == 'SEASON' then
        local event_start_at = definition.event_start_at
        local event_end_at = definition.event_end_at
        if server_time_utc < event_start_at or server_time_utc >= event_end_at then
            return fail(
                CycleErrorCodes.CYCLE_OUTSIDE_EVENT_WINDOW,
                'OUTSIDE_EVENT_WINDOW',
                {
                    server_time_utc = server_time_utc,
                    event_start_at = event_start_at,
                    event_end_at = event_end_at,
                }
            )
        end
        -- Single-period window: always cycle_number 0 while inside [start, end).
        local cycle_number = 0
        return build_period(
            definition,
            cycle_number,
            event_start_at,
            event_end_at,
            server_time_utc,
            trust_state
        )
    end

    return invalid_argument('KIND_UNSUPPORTED', { kind = kind })
end

--- Integer comparison of cycle numbers. Returns Result with -1 / 0 / 1.
--- Must not compare cycle_id strings for ordering.
function CycleCalculator.compare_cycle_numbers(a, b)
    if not is_safe_integer(a, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER) then
        return invalid_argument('CYCLE_NUMBER_A_INVALID', {
            field = 'a',
            value = a,
        })
    end
    if not is_safe_integer(b, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER) then
        return invalid_argument('CYCLE_NUMBER_B_INVALID', {
            field = 'b',
            value = b,
        })
    end
    if a < b then
        return result_ok(-1)
    end
    if a > b then
        return result_ok(1)
    end
    return result_ok(0)
end

return CycleCalculator
