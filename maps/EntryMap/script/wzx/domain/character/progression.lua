local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local TableShape = require 'wzx.domain.common.table_shape'
local ErrorCodes = require 'wzx.domain.character.error_codes'

local Progression = {}

local MAX_SAFE_INTEGER = 9007199254740991

local function curve_failure(field, reason, details)
    details = details or {}
    details.field = field
    details.reason = reason
    return Result.err(
        ErrorCodes.CHARACTER_LEVEL_CURVE_INVALID,
        'error.character.level_curve_invalid',
        false,
        details
    )
end

function Progression.validate_curve(curve)
    if type(curve) ~= 'table' or getmetatable(curve) ~= nil then
        return curve_failure('$', 'TABLE_REQUIRED')
    end
    if not TableShape.is_integer(curve.level_cap, 1, 100) then
        return curve_failure('level_cap', 'INTEGER_OUT_OF_RANGE', {
            minimum = 1,
            maximum = 100,
        })
    end

    local thresholds = curve.cumulative_exp_by_level
    if getmetatable(thresholds) ~= nil or not Ordered.is_dense_array(thresholds) then
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
        if not TableShape.is_integer(threshold, 0, MAX_SAFE_INTEGER) then
            return curve_failure(
                'cumulative_exp_by_level.' .. tostring(index),
                'INTEGER_OUT_OF_RANGE',
                { minimum = 0, maximum = MAX_SAFE_INTEGER }
            )
        end
        if index == 1 and threshold ~= 0 then
            return curve_failure('cumulative_exp_by_level.1', 'LEVEL_ONE_MUST_START_AT_ZERO')
        end
        if previous ~= nil and threshold <= previous then
            return curve_failure(
                'cumulative_exp_by_level.' .. tostring(index),
                'STRICT_ASCENDING_ORDER_REQUIRED'
            )
        end
        previous = threshold
    end
    return Result.ok(true)
end

function Progression.resolve_level(curve, experience)
    local curve_result = Progression.validate_curve(curve)
    if not curve_result.ok then
        return curve_result
    end
    if not TableShape.is_integer(experience, 0, MAX_SAFE_INTEGER) then
        return Result.err(
            ErrorCodes.CHARACTER_XP_OUT_OF_RANGE,
            'error.character.xp_out_of_range',
            false,
            {
                field = 'experience',
                minimum = 0,
                maximum = MAX_SAFE_INTEGER,
            }
        )
    end

    local thresholds = curve.cumulative_exp_by_level
    local low = 1
    local high = #thresholds
    local resolved = 1
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if thresholds[middle] <= experience then
            resolved = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return Result.ok(resolved)
end

Progression.MAX_SAFE_INTEGER = MAX_SAFE_INTEGER

return Progression
