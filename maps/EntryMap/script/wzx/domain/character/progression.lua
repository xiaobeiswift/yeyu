local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local ErrorCodes = require 'wzx.domain.character.error_codes'

local Progression = {}
local is_dense_array = Ordered.is_dense_array
local sorted_string_keys = Ordered.sorted_string_keys
local result_err = Result.err
local result_ok = Result.ok
local validate_content_id = RuntimeId.validate_content
local is_integer = TableShape.is_integer
local get_metatable = getmetatable
local math_floor = math.floor
local raw_get = rawget
local tostring_value = tostring
local type_value = type

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_LEVEL_REWARD_REFS = 64
local REWARD_ROW_FIELDS = {
    reached_level = true,
    reward_ref = true,
}
local CURVE_FIELDS = {
    id = true,
    level_cap = true,
    experience_cap = true,
    cumulative_exp_by_level = true,
    level_reward_refs = true,
}

local function curve_failure(field, reason, details)
    details = details or {}
    details.field = field
    details.reason = reason
    return result_err(
        ErrorCodes.CHARACTER_LEVEL_CURVE_INVALID,
        'error.character.level_curve_invalid',
        false,
        details
    )
end

local function argument_failure(field, reason, details)
    details = details or {}
    details.field = field
    details.reason = reason
    return result_err(
        ErrorCodes.CHARACTER_ARGUMENT_INVALID,
        'error.character.argument_invalid',
        false,
        details
    )
end

local function validate_reward_rows(rows, level_cap)
    if rows == nil then
        return result_ok(true)
    end
    if type_value(rows) ~= 'table'
        or get_metatable(rows) ~= nil
        or not is_dense_array(rows)
    then
        return curve_failure('level_reward_refs', 'DENSE_ARRAY_REQUIRED')
    end
    if #rows > MAX_LEVEL_REWARD_REFS then
        return curve_failure(
            'level_reward_refs',
            'REWARD_REF_COUNT_LIMIT_EXCEEDED',
            {
                actual = #rows,
                maximum = MAX_LEVEL_REWARD_REFS,
            }
        )
    end

    local previous_level
    local index
    for index = 1, #rows do
        local row = raw_get(rows, index)
        local row_path = 'level_reward_refs.' .. tostring_value(index)
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return curve_failure(row_path, 'PLAIN_ROW_REQUIRED')
        end
        local keys = sorted_string_keys(row)
        if not keys.ok then
            return curve_failure(row_path, 'STRING_FIELDS_REQUIRED')
        end
        local key_index
        for key_index = 1, #keys.value do
            local key = keys.value[key_index]
            if not REWARD_ROW_FIELDS[key] then
                return curve_failure(
                    row_path .. '.' .. key,
                    'UNKNOWN_FIELD'
                )
            end
        end

        local reached_level = raw_get(row, 'reached_level')
        if not is_integer(reached_level, 2, level_cap) then
            return curve_failure(
                row_path .. '.reached_level',
                'INTEGER_OUT_OF_RANGE',
                { minimum = 2, maximum = level_cap }
            )
        end
        local reward_ref = raw_get(row, 'reward_ref')
        local checked_reward = validate_content_id(
            reward_ref,
            'reward_',
            row_path .. '.reward_ref'
        )
        if not checked_reward.ok then
            return curve_failure(
                row_path .. '.reward_ref',
                'REWARD_REF_INVALID',
                { cause_code = checked_reward.error.code }
            )
        end
        if previous_level ~= nil and previous_level >= reached_level then
            return curve_failure(
                row_path .. '.reached_level',
                'STRICT_ASCENDING_REACHED_LEVEL_REQUIRED'
            )
        end
        previous_level = reached_level
    end
    return result_ok(true)
end

local function validate_curve(curve)
    if type_value(curve) ~= 'table' or get_metatable(curve) ~= nil then
        return curve_failure('$', 'TABLE_REQUIRED')
    end
    local curve_keys = sorted_string_keys(curve)
    if not curve_keys.ok then
        return curve_failure('$', 'STRING_FIELDS_REQUIRED')
    end
    local curve_key_index
    for curve_key_index = 1, #curve_keys.value do
        local curve_key = curve_keys.value[curve_key_index]
        if not CURVE_FIELDS[curve_key] then
            return curve_failure(curve_key, 'UNKNOWN_FIELD')
        end
    end
    if not is_integer(curve.level_cap, 1, 100) then
        return curve_failure('level_cap', 'INTEGER_OUT_OF_RANGE', {
            minimum = 1,
            maximum = 100,
        })
    end

    local thresholds = curve.cumulative_exp_by_level
    if type_value(thresholds) ~= 'table'
        or get_metatable(thresholds) ~= nil
        or not is_dense_array(thresholds)
    then
        return curve_failure('cumulative_exp_by_level', 'DENSE_ARRAY_REQUIRED')
    end
    if #thresholds ~= curve.level_cap then
        return curve_failure('cumulative_exp_by_level', 'LEVEL_CAP_LENGTH_MISMATCH', {
            expected = curve.level_cap,
            actual = #thresholds,
        })
    end

    local previous
    local index
    for index = 1, #thresholds do
        local threshold = thresholds[index]
        if not is_integer(threshold, 0, MAX_SAFE_INTEGER) then
            return curve_failure(
                'cumulative_exp_by_level.' .. tostring_value(index),
                'INTEGER_OUT_OF_RANGE',
                { minimum = 0, maximum = MAX_SAFE_INTEGER }
            )
        end
        if index == 1 and threshold ~= 0 then
            return curve_failure('cumulative_exp_by_level.1', 'LEVEL_ONE_MUST_START_AT_ZERO')
        end
        if previous ~= nil and threshold <= previous then
            return curve_failure(
                'cumulative_exp_by_level.' .. tostring_value(index),
                'STRICT_ASCENDING_ORDER_REQUIRED'
            )
        end
        previous = threshold
    end
    if not is_integer(curve.experience_cap, previous, MAX_SAFE_INTEGER) then
        return curve_failure('experience_cap', 'INTEGER_OUT_OF_RANGE', {
            minimum = previous,
            maximum = MAX_SAFE_INTEGER,
        })
    end
    return validate_reward_rows(curve.level_reward_refs, curve.level_cap)
end

Progression.validate_curve = validate_curve

function Progression.resolve_level(curve, experience)
    local curve_result = validate_curve(curve)
    if not curve_result.ok then
        return curve_result
    end
    if not is_integer(experience, 0, curve.experience_cap) then
        return result_err(
            ErrorCodes.CHARACTER_XP_OUT_OF_RANGE,
            'error.character.xp_out_of_range',
            false,
            {
                field = 'experience',
                minimum = 0,
                maximum = curve.experience_cap,
            }
        )
    end

    local thresholds = curve.cumulative_exp_by_level
    local low = 1
    local high = #thresholds
    local resolved = 1
    while low <= high do
        local middle = math_floor((low + high) / 2)
        if thresholds[middle] <= experience then
            resolved = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return result_ok(resolved)
end

local function collect_level_rewards(curve, old_level, new_level)
    local curve_result = validate_curve(curve)
    if not curve_result.ok then
        return curve_result
    end
    if not is_integer(old_level, 1, curve.level_cap) then
        return argument_failure('old_level', 'INTEGER_OUT_OF_RANGE', {
            minimum = 1,
            maximum = curve.level_cap,
        })
    end
    if not is_integer(new_level, 1, curve.level_cap) then
        return argument_failure('new_level', 'INTEGER_OUT_OF_RANGE', {
            minimum = 1,
            maximum = curve.level_cap,
        })
    end
    if new_level < old_level then
        return argument_failure(
            'new_level',
            'LEVEL_TRANSITION_REVERSED',
            { old_level = old_level, new_level = new_level }
        )
    end

    local collected = {}
    local rows = curve.level_reward_refs or {}
    local index
    for index = 1, #rows do
        local row = raw_get(rows, index)
        local reached_level = raw_get(row, 'reached_level')
        if reached_level > old_level and reached_level <= new_level then
            collected[#collected + 1] = {
                reached_level = reached_level,
                reward_ref = raw_get(row, 'reward_ref'),
            }
        end
    end
    return result_ok(collected)
end

function Progression.collect_level_rewards(curve, old_level, new_level)
    return collect_level_rewards(curve, old_level, new_level)
end

function Progression.collect_level_reward_refs(curve, old_level, new_level)
    local collected = collect_level_rewards(curve, old_level, new_level)
    if not collected.ok then
        return collected
    end
    local refs = {}
    local index
    for index = 1, #collected.value do
        refs[index] = collected.value[index].reward_ref
    end
    return result_ok(refs)
end

Progression.MAX_SAFE_INTEGER = MAX_SAFE_INTEGER
Progression.MAX_LEVEL_REWARD_REFS = MAX_LEVEL_REWARD_REFS

return Progression
