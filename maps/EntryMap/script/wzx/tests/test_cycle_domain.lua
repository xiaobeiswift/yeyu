local Harness = require 'wzx.tests.harness'
local CycleCalculator = require 'wzx.domain.cycle.cycle_calculator'
local CycleDefinition = require 'wzx.domain.cycle.cycle_definition'
local CycleErrorCodes = require 'wzx.domain.cycle.error_codes'

local case = Harness.case
local assert = Harness.assert

local SECONDS_PER_DAY = 86400
local SECONDS_PER_WEEK = 7 * SECONDS_PER_DAY

local function day_def(overrides)
    local raw = {
        cycle_def_id = 'cycle_server_day',
        definition_version = 1,
        kind = 'SERVER_DAY',
        timezone_offset_seconds = 0,
        reset_offset_seconds = 0,
        deprecated = false,
    }
    if overrides ~= nil then
        local key
        local value
        for key, value in pairs(overrides) do
            raw[key] = value
        end
    end
    return raw
end

local function week_def(overrides)
    local raw = day_def({
        cycle_def_id = 'cycle_server_week',
        kind = 'SERVER_WEEK',
        week_start = 1,
    })
    if overrides ~= nil then
        local key
        local value
        for key, value in pairs(overrides) do
            raw[key] = value
        end
    end
    return raw
end

local function event_def(overrides)
    local raw = {
        cycle_def_id = 'cycle_event_spring',
        definition_version = 1,
        kind = 'EVENT',
        timezone_offset_seconds = 0,
        reset_offset_seconds = 0,
        event_start_at = 1 * SECONDS_PER_DAY,
        event_end_at = 4 * SECONDS_PER_DAY,
        deprecated = false,
    }
    if overrides ~= nil then
        local key
        local value
        for key, value in pairs(overrides) do
            raw[key] = value
        end
    end
    return raw
end

return {
    case('normalize accepts valid SERVER_DAY and fills grace default', function()
        local result = CycleDefinition.normalize(day_def())
        assert.equal(result.ok, true)
        assert.equal(result.value.cycle_def_id, 'cycle_server_day')
        assert.equal(result.value.grace_seconds, 0)
        assert.equal(result.value.kind, 'SERVER_DAY')
        assert.equal(result.value.deprecated, false)
    end),

    case('normalize rejects illegal definitions', function()
        local missing_id = CycleDefinition.normalize({
            definition_version = 1,
            kind = 'SERVER_DAY',
            timezone_offset_seconds = 0,
            reset_offset_seconds = 0,
            deprecated = false,
        })
        assert.equal(missing_id.ok, false)
        assert.equal(missing_id.error.code, CycleErrorCodes.CYCLE_DEFINITION_INVALID)

        local bad_kind = CycleDefinition.normalize(day_def({ kind = 'MONTHLY' }))
        assert.equal(bad_kind.ok, false)
        assert.equal(bad_kind.error.code, CycleErrorCodes.CYCLE_DEFINITION_INVALID)

        local week_without_start = CycleDefinition.normalize(day_def({
            cycle_def_id = 'cycle_week_bad',
            kind = 'SERVER_WEEK',
        }))
        assert.equal(week_without_start.ok, false)
        assert.error_reason(week_without_start, 'WEEK_START_REQUIRED')

        local event_bad_window = CycleDefinition.normalize(event_def({
            event_start_at = 100,
            event_end_at = 100,
        }))
        assert.equal(event_bad_window.ok, false)
        assert.error_reason(event_bad_window, 'EVENT_WINDOW_INVALID')

        local bad_tz = CycleDefinition.normalize(day_def({
            timezone_offset_seconds = 999999,
        }))
        assert.equal(bad_tz.ok, false)
        assert.error_reason(bad_tz, 'TIMEZONE_OFFSET_INVALID')

        local bad_reset = CycleDefinition.normalize(day_def({
            reset_offset_seconds = 86400,
        }))
        assert.equal(bad_reset.ok, false)
        assert.error_reason(bad_reset, 'RESET_OFFSET_INVALID')

        local bad_prefix = CycleDefinition.normalize(day_def({
            cycle_def_id = 'daily_main',
        }))
        assert.equal(bad_prefix.ok, false)
        assert.error_reason(bad_prefix, 'CYCLE_DEF_ID_INVALID')

        local self_parent = CycleDefinition.normalize(day_def({
            parent_cycle_def_id = 'cycle_server_day',
        }))
        assert.equal(self_parent.ok, false)
        assert.error_reason(self_parent, 'PARENT_CYCLE_SELF_REFERENCE')
    end),

    case('SERVER_DAY boundaries flip cycle_number around reset', function()
        local def = day_def({ reset_offset_seconds = 18000 })
        local before = CycleCalculator.compute_period(def, 104399, 'LIVE')
        local after = CycleCalculator.compute_period(def, 104400, 'LIVE')
        assert.equal(before.ok, true)
        assert.equal(after.ok, true)
        assert.equal(before.value.cycle_number, 0)
        assert.equal(after.value.cycle_number, 1)
        assert.equal(before.value.cycle_id, 'cycle_server_day:0')
        assert.equal(after.value.cycle_id, 'cycle_server_day:1')
        assert.equal(before.value.ends_at, after.value.starts_at)
        assert.equal(after.value.starts_at, 104400)
        assert.equal(after.value.ends_at, 104400 + SECONDS_PER_DAY)
        assert.equal(before.value.observed_server_time, 104399)
        assert.equal(before.value.trust_state, 'LIVE')
        assert.equal(before.value.definition_version, 1)
    end),

    case('SERVER_DAY respects timezone and reset offsets', function()
        -- UTC+8, reset at local 00:00 → UTC 16:00 previous calendar day when offset=+28800
        local def = day_def({
            timezone_offset_seconds = 28800,
            reset_offset_seconds = 0,
        })
        local t_boundary = SECONDS_PER_DAY - 28800 -- 57600
        local before = CycleCalculator.compute_period(def, t_boundary - 1, 'CACHED')
        local after = CycleCalculator.compute_period(def, t_boundary, 'CACHED')
        assert.equal(before.ok, true)
        assert.equal(after.ok, true)
        assert.equal(before.value.cycle_number, 0)
        assert.equal(after.value.cycle_number, 1)
        assert.equal(after.value.starts_at, t_boundary)
        assert.equal(after.value.ends_at, t_boundary + SECONDS_PER_DAY)
        assert.equal(after.value.trust_state, 'CACHED')

        local with_reset = day_def({
            timezone_offset_seconds = 28800,
            reset_offset_seconds = 3600,
        })
        -- normalized = t + 28800 - 3600 = t + 25200
        -- cycle flips when t + 25200 = 86400 → t = 61200
        local flip = 61200
        local p0 = CycleCalculator.compute_period(with_reset, flip - 1, 'LIVE')
        local p1 = CycleCalculator.compute_period(with_reset, flip, 'LIVE')
        assert.equal(p0.ok, true)
        assert.equal(p1.ok, true)
        assert.equal(p0.value.cycle_number, 0)
        assert.equal(p1.value.cycle_number, 1)
        assert.equal(p1.value.starts_at, flip)
    end),

    case('SERVER_WEEK aligns to week_start and spans seven days', function()
        -- day_number 4 = 1970-01-05 Monday when Mon=1
        local monday = 4 * SECONDS_PER_DAY
        local def = week_def({ week_start = 1 })
        local on_monday = CycleCalculator.compute_period(def, monday, 'LIVE')
        assert.equal(on_monday.ok, true)
        assert.equal(on_monday.value.cycle_number, 0)
        assert.equal(on_monday.value.starts_at, monday)
        assert.equal(on_monday.value.ends_at, monday + SECONDS_PER_WEEK)
        assert.equal(on_monday.value.cycle_id, 'cycle_server_week:0')

        local sunday_before = monday - 1
        local prev = CycleCalculator.compute_period(def, sunday_before, 'LIVE')
        assert.equal(prev.ok, true)
        assert.equal(prev.value.ends_at, monday)
        assert.truthy(prev.value.cycle_number < on_monday.value.cycle_number)

        local next_monday = monday + SECONDS_PER_WEEK
        local next_week = CycleCalculator.compute_period(def, next_monday, 'LIVE')
        assert.equal(next_week.ok, true)
        assert.equal(next_week.value.cycle_number, 1)
        assert.equal(next_week.value.starts_at, next_monday)

        -- Thursday-start weeks: day_number 0 is Thursday
        local thu_def = week_def({
            cycle_def_id = 'cycle_week_thu',
            week_start = 4,
        })
        local at_epoch = CycleCalculator.compute_period(thu_def, 0, 'LIVE')
        assert.equal(at_epoch.ok, true)
        assert.equal(at_epoch.value.cycle_number, 0)
        assert.equal(at_epoch.value.starts_at, 0)
        assert.equal(at_epoch.value.ends_at, SECONDS_PER_WEEK)

        local next_thu = SECONDS_PER_WEEK
        local next_thu_period = CycleCalculator.compute_period(thu_def, next_thu, 'LIVE')
        assert.equal(next_thu_period.ok, true)
        assert.equal(next_thu_period.value.cycle_number, 1)
    end),

    case('EVENT window is half-open and single-period', function()
        local def = event_def()
        local start_at = 1 * SECONDS_PER_DAY
        local end_at = 4 * SECONDS_PER_DAY

        local inside_start = CycleCalculator.compute_period(def, start_at, 'LIVE')
        assert.equal(inside_start.ok, true)
        assert.equal(inside_start.value.cycle_number, 0)
        assert.equal(inside_start.value.cycle_id, 'cycle_event_spring:0')
        assert.equal(inside_start.value.starts_at, start_at)
        assert.equal(inside_start.value.ends_at, end_at)

        local inside_end = CycleCalculator.compute_period(def, end_at - 1, 'LIVE')
        assert.equal(inside_end.ok, true)
        assert.equal(inside_end.value.cycle_number, 0)

        local before = CycleCalculator.compute_period(def, start_at - 1, 'LIVE')
        assert.equal(before.ok, false)
        assert.equal(before.error.code, CycleErrorCodes.CYCLE_OUTSIDE_EVENT_WINDOW)

        local at_end = CycleCalculator.compute_period(def, end_at, 'LIVE')
        assert.equal(at_end.ok, false)
        assert.equal(at_end.error.code, CycleErrorCodes.CYCLE_OUTSIDE_EVENT_WINDOW)

        local season = event_def({
            cycle_def_id = 'cycle_season_1',
            kind = 'SEASON',
            event_start_at = 10,
            event_end_at = 20,
        })
        local season_ok = CycleCalculator.compute_period(season, 15, 'LIVE')
        assert.equal(season_ok.ok, true)
        assert.equal(season_ok.value.cycle_id, 'cycle_season_1:0')
        local season_out = CycleCalculator.compute_period(season, 20, 'LIVE')
        assert.equal(season_out.ok, false)
        assert.equal(season_out.error.code, CycleErrorCodes.CYCLE_OUTSIDE_EVENT_WINDOW)
    end),

    case('UNAVAILABLE trust rejects without computing', function()
        local def = day_def()
        local result = CycleCalculator.compute_period(def, SECONDS_PER_DAY, 'UNAVAILABLE')
        assert.equal(result.ok, false)
        assert.equal(result.error.code, CycleErrorCodes.CYCLE_TRUST_UNAVAILABLE)
        assert.error_reason(result, 'TRUST_STATE_UNAVAILABLE')
    end),

    case('invalid server_time and trust_state are rejected', function()
        local def = day_def()
        local nan = CycleCalculator.compute_period(def, 0 / 0, 'LIVE')
        assert.equal(nan.ok, false)
        assert.equal(nan.error.code, CycleErrorCodes.CYCLE_TIME_INVALID)

        local fractional = CycleCalculator.compute_period(def, 1.5, 'LIVE')
        assert.equal(fractional.ok, false)
        assert.equal(fractional.error.code, CycleErrorCodes.CYCLE_TIME_INVALID)

        local negative = CycleCalculator.compute_period(def, -1, 'LIVE')
        assert.equal(negative.ok, false)
        assert.equal(negative.error.code, CycleErrorCodes.CYCLE_TIME_INVALID)

        local bad_trust = CycleCalculator.compute_period(def, 0, 'STALE')
        assert.equal(bad_trust.ok, false)
        assert.equal(bad_trust.error.code, CycleErrorCodes.CYCLE_ARGUMENT_INVALID)
    end),

    case('compare_cycle_numbers is integer ordered', function()
        local lt = CycleCalculator.compare_cycle_numbers(3, 10)
        local eq = CycleCalculator.compare_cycle_numbers(7, 7)
        local gt = CycleCalculator.compare_cycle_numbers(12, 4)
        assert.equal(lt.ok, true)
        assert.equal(lt.value, -1)
        assert.equal(eq.ok, true)
        assert.equal(eq.value, 0)
        assert.equal(gt.ok, true)
        assert.equal(gt.value, 1)

        local bad = CycleCalculator.compare_cycle_numbers('3', 3)
        assert.equal(bad.ok, false)
        assert.equal(bad.error.code, CycleErrorCodes.CYCLE_ARGUMENT_INVALID)

        local nan = CycleCalculator.compare_cycle_numbers(0 / 0, 1)
        assert.equal(nan.ok, false)
        assert.equal(nan.error.code, CycleErrorCodes.CYCLE_ARGUMENT_INVALID)
    end),

    case('identical inputs yield identical Period (determinism)', function()
        local def = day_def({
            timezone_offset_seconds = 28800,
            reset_offset_seconds = 7200,
            definition_version = 2,
            grace_seconds = 60,
            parent_cycle_def_id = 'cycle_season_parent',
        })
        local t = 123456789
        local a = CycleCalculator.compute_period(def, t, 'LIVE')
        local b = CycleCalculator.compute_period(def, t, 'LIVE')
        assert.equal(a.ok, true)
        assert.equal(b.ok, true)
        assert.deep_equal(a.value, b.value)

        local week = week_def({
            week_start = 7,
            timezone_offset_seconds = -3600,
            reset_offset_seconds = 100,
        })
        local w1 = CycleCalculator.compute_period(week, 999999, 'CACHED')
        local w2 = CycleCalculator.compute_period(week, 999999, 'CACHED')
        assert.equal(w1.ok, true)
        assert.deep_equal(w1.value, w2.value)
        assert.equal(w1.value.ends_at - w1.value.starts_at, SECONDS_PER_WEEK)
    end),

    case('cycle_id uses decimal encoding without scientific notation', function()
        local def = day_def()
        -- Large but safe day number via large timestamp
        local t = 100000 * SECONDS_PER_DAY
        local result = CycleCalculator.compute_period(def, t, 'LIVE')
        assert.equal(result.ok, true)
        assert.equal(result.value.cycle_number, 100000)
        assert.equal(result.value.cycle_id, 'cycle_server_day:100000')
        local suffix = result.value.cycle_id:match(':(%d+)$')
        assert.equal(suffix, '100000')
        assert.falsy(suffix:find('[eE%.]', 1))
    end),
}
