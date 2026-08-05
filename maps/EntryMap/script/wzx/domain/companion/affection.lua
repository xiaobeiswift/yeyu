-- Pure domain affection points / rank / gift delta rules for system 02.
-- Compatible with Lua 5.1 and Y3 Lua 5.4 common subset; no y3 / time / random.

local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local CompanionErrorCodes = require 'wzx.domain.companion.error_codes'

local CompanionAffection = {}
local get_metatable = getmetatable
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_POINTS = 10000
-- Six-rank chapter-1 freeze: rank index 0..5.
local RANK_THRESHOLDS = { 0, 500, 1500, 3000, 5500, 8500 }

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.companion.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(CompanionErrorCodes.COMPANION_ARGUMENT_INVALID, reason, details)
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

local function copy_string_list(rows)
    if rows == nil then
        return {}
    end
    local copied = {}
    local index
    for index = 1, #rows do
        copied[index] = rows[index]
    end
    return copied
end

local function copy_affection_result(result)
    if result == nil then
        return nil
    end
    local crossed = {}
    local index
    if type_value(result.crossed_ranks) == 'table' then
        for index = 1, #result.crossed_ranks do
            crossed[index] = result.crossed_ranks[index]
        end
    end
    return {
        previous_points = result.previous_points,
        new_points = result.new_points,
        previous_rank = result.previous_rank,
        new_rank = result.new_rank,
        applied_delta = result.applied_delta,
        crossed_ranks = crossed,
        idempotent = result.idempotent == true,
    }
end

local function copy_entry(entry)
    return {
        companion_id = entry.companion_id,
        discovery_state = entry.discovery_state,
        availability_state = entry.availability_state,
        availability_reason_id = entry.availability_reason_id,
        recruitment_source_type = entry.recruitment_source_type,
        recruitment_source_ref = entry.recruitment_source_ref,
        recruited_receipt_id = entry.recruited_receipt_id,
        affection_points = entry.affection_points,
        affection_rank = entry.affection_rank,
        resolved_event_ids = copy_string_list(entry.resolved_event_ids),
        claimed_rank_rewards = copy_string_list(entry.claimed_rank_rewards),
        revision = entry.revision,
        last_affection_receipt_id = entry.last_affection_receipt_id,
        last_affection_result = copy_affection_result(entry.last_affection_result),
    }
end

local function validate_entry_shape(entry)
    if type_value(entry) ~= 'table' or get_metatable(entry) ~= nil then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'ENTRY_TABLE_REQUIRED',
            { field = 'entry' }
        )
    end
    local companion_id = raw_get(entry, 'companion_id')
    local checked = validate_content(companion_id, 'char_', 'companion_id')
    if not checked.ok then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'COMPANION_ID_INVALID',
            { field = 'companion_id' }
        )
    end
    if not is_safe_integer(raw_get(entry, 'affection_points'), 0, MAX_POINTS) then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'AFFECTION_POINTS_INVALID',
            { field = 'affection_points' }
        )
    end
    if not is_safe_integer(raw_get(entry, 'affection_rank'), 0, 5) then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'AFFECTION_RANK_INVALID',
            { field = 'affection_rank' }
        )
    end
    if not is_safe_integer(raw_get(entry, 'revision'), 0, MAX_SAFE_INTEGER) then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'REVISION_INVALID',
            { field = 'revision' }
        )
    end
    return result_ok(true)
end

function CompanionAffection.resolve_rank(points)
    if not is_safe_integer(points, 0, MAX_POINTS) then
        return fail(
            CompanionErrorCodes.COMPANION_AFFECTION_INVALID,
            'POINTS_OUT_OF_RANGE',
            { field = 'points', points = points }
        )
    end
    local rank = 0
    local index
    for index = 1, #RANK_THRESHOLDS do
        if points >= RANK_THRESHOLDS[index] then
            rank = index - 1
        else
            break
        end
    end
    return result_ok(rank)
end

local function rank_floor(rank)
    return RANK_THRESHOLDS[rank + 1]
end

local function collect_crossed_ranks(previous_rank, new_rank)
    local crossed = {}
    if new_rank <= previous_rank then
        return crossed
    end
    local rank
    for rank = previous_rank + 1, new_rank do
        crossed[#crossed + 1] = rank
    end
    return crossed
end

function CompanionAffection.apply_delta(entry, final_delta, receipt_id)
    local validated = validate_entry_shape(entry)
    if not validated.ok then
        return validated
    end
    if not is_safe_integer(final_delta, -MAX_POINTS, MAX_POINTS) then
        return fail(
            CompanionErrorCodes.COMPANION_AFFECTION_INVALID,
            'FINAL_DELTA_OUT_OF_RANGE',
            { field = 'final_delta', final_delta = final_delta }
        )
    end
    local checked_receipt = validate_derived(receipt_id, 'receipt_id')
    if not checked_receipt.ok then
        return fail(
            CompanionErrorCodes.COMPANION_AFFECTION_INVALID,
            'RECEIPT_ID_INVALID',
            { field = 'receipt_id' }
        )
    end

    if entry.last_affection_receipt_id == receipt_id
        and entry.last_affection_result ~= nil
    then
        local cached = copy_affection_result(entry.last_affection_result)
        cached.idempotent = true
        return result_ok({
            entry = copy_entry(entry),
            previous_points = cached.previous_points,
            new_points = cached.new_points,
            previous_rank = cached.previous_rank,
            new_rank = cached.new_rank,
            applied_delta = cached.applied_delta,
            crossed_ranks = cached.crossed_ranks,
            idempotent = true,
        })
    end

    local previous_points = entry.affection_points
    local previous_rank = entry.affection_rank
    -- Prefer persisted rank as floor authority when consistent; re-resolve if stale.
    local resolved_prev = CompanionAffection.resolve_rank(previous_points)
    if not resolved_prev.ok then
        return resolved_prev
    end
    if previous_rank ~= resolved_prev.value then
        previous_rank = resolved_prev.value
    end

    local tentative = previous_points + final_delta
    if tentative < 0 then
        tentative = 0
    elseif tentative > MAX_POINTS then
        tentative = MAX_POINTS
    end

    -- Chapter-1: negative deltas must not drop below current rank threshold.
    if final_delta < 0 then
        local floor_points = rank_floor(previous_rank)
        if tentative < floor_points then
            tentative = floor_points
        end
    end

    local new_points = tentative
    local resolved_new = CompanionAffection.resolve_rank(new_points)
    if not resolved_new.ok then
        return resolved_new
    end
    local new_rank = resolved_new.value
    local applied_delta = new_points - previous_points
    local crossed_ranks = collect_crossed_ranks(previous_rank, new_rank)

    local next_entry = copy_entry(entry)
    next_entry.affection_points = new_points
    next_entry.affection_rank = new_rank
    if new_points ~= previous_points or new_rank ~= previous_rank then
        next_entry.revision = entry.revision + 1
    end

    local outcome = {
        previous_points = previous_points,
        new_points = new_points,
        previous_rank = previous_rank,
        new_rank = new_rank,
        applied_delta = applied_delta,
        crossed_ranks = crossed_ranks,
        idempotent = false,
    }
    next_entry.last_affection_receipt_id = receipt_id
    next_entry.last_affection_result = copy_affection_result(outcome)

    return result_ok({
        entry = next_entry,
        previous_points = previous_points,
        new_points = new_points,
        previous_rank = previous_rank,
        new_rank = new_rank,
        applied_delta = applied_delta,
        crossed_ranks = crossed_ranks,
        idempotent = false,
    })
end

function CompanionAffection.compute_gift_delta(
    base_value,
    quantity,
    preference_multiplier_bp,
    context_multiplier_bp
)
    if not is_safe_integer(base_value, 0, MAX_POINTS) then
        return fail(
            CompanionErrorCodes.COMPANION_AFFECTION_INVALID,
            'BASE_VALUE_INVALID',
            { field = 'base_value', base_value = base_value }
        )
    end
    if not is_safe_integer(quantity, 1, 999) then
        return fail(
            CompanionErrorCodes.COMPANION_AFFECTION_INVALID,
            'QUANTITY_INVALID',
            { field = 'quantity', quantity = quantity }
        )
    end
    if not is_safe_integer(preference_multiplier_bp, 0, 30000) then
        return fail(
            CompanionErrorCodes.COMPANION_AFFECTION_INVALID,
            'PREFERENCE_MULTIPLIER_INVALID',
            {
                field = 'preference_multiplier_bp',
                preference_multiplier_bp = preference_multiplier_bp,
            }
        )
    end
    if not is_safe_integer(context_multiplier_bp, 0, 30000) then
        return fail(
            CompanionErrorCodes.COMPANION_AFFECTION_INVALID,
            'CONTEXT_MULTIPLIER_INVALID',
            {
                field = 'context_multiplier_bp',
                context_multiplier_bp = context_multiplier_bp,
            }
        )
    end

    local base_total = base_value * quantity
    local after_preference = math_floor(base_total * preference_multiplier_bp / 10000)
    local final_delta = math_floor(after_preference * context_multiplier_bp / 10000)
    if final_delta < 0 then
        final_delta = 0
    elseif final_delta > MAX_POINTS then
        final_delta = MAX_POINTS
    end
    return result_ok(final_delta)
end

CompanionAffection.MAX_POINTS = MAX_POINTS
CompanionAffection.RANK_THRESHOLDS = RANK_THRESHOLDS

return CompanionAffection
