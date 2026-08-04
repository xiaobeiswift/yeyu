local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local Rules = require 'wzx.domain.combat.rules'
local CombatErrorCodes = require 'wzx.domain.combat.error_codes'

local Timeline = {}
local bytewise_string_less = Ordered.bytewise_string_less
local math_ceil = math.ceil
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type

local function fail(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        CombatErrorCodes.COMBAT_STATE_INVALID,
        'error.combat.state_invalid',
        false,
        details
    )
end

local function is_ready_candidate(actor)
    return actor.alive_state == 'ALIVE' and type_value(actor.speed) == 'number' and actor.speed >= 1
end

local function ticks_to_ready(actor)
    local remaining = Rules.GAUGE_THRESHOLD - actor.gauge
    if remaining <= 0 then
        return 0
    end
    local speed = math_max(1, actor.speed)
    return math_ceil(remaining / speed)
end

local function preferred_first(left_side, right_side, preferred)
    if left_side == preferred and right_side ~= preferred then
        return true
    end
    if right_side == preferred and left_side ~= preferred then
        return false
    end
    return nil
end

function Timeline.select_next_actor(state)
    if type_value(state) ~= 'table' or type_value(state.actors) ~= 'table' then
        return fail('STATE_REQUIRED')
    end

    local candidates = {}
    local actor_id
    local actor
    for actor_id, actor in raw_next, state.actors do
        if is_ready_candidate(actor) then
            candidates[#candidates + 1] = actor
        end
    end
    if #candidates == 0 then
        return fail('NO_LIVING_ACTORS')
    end

    local min_delta = nil
    local index
    for index = 1, #candidates do
        local delta = ticks_to_ready(candidates[index])
        if min_delta == nil or delta < min_delta then
            min_delta = delta
        end
    end

    if min_delta > 0 then
        for index = 1, #candidates do
            actor = candidates[index]
            local gain = actor.speed * min_delta
            actor.gauge = math_min(Rules.GAUGE_THRESHOLD, actor.gauge + gain)
        end
        state.current_tick = state.current_tick + min_delta
    end

    local ready = {}
    for index = 1, #candidates do
        actor = candidates[index]
        if actor.gauge >= Rules.GAUGE_THRESHOLD then
            ready[#ready + 1] = actor
        end
    end
    if #ready == 0 then
        return fail('NO_READY_ACTOR_AFTER_TICK')
    end

    local preferred = state.tie_preferred_side
    table_sort(ready, function(left, right)
        local pref = preferred_first(left.side, right.side, preferred)
        if pref ~= nil then
            return pref
        end
        if left.position_index ~= right.position_index then
            return left.position_index < right.position_index
        end
        return bytewise_string_less(left.actor_id, right.actor_id)
    end)

    return result_ok({
        actor = ready[1],
        delta = min_delta,
    })
end

function Timeline.consume_action_gauge(actor)
    actor.gauge = actor.gauge - Rules.GAUGE_THRESHOLD
    if actor.gauge < 0 then
        actor.gauge = 0
    end
    -- keep fractional remainder semantics via integer only; floor already ensured by threshold math
    actor.gauge = math_floor(actor.gauge)
end

return Timeline
