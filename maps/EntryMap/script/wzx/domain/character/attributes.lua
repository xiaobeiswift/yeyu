local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local TableShape = require 'wzx.domain.common.table_shape'
local ErrorCodes = require 'wzx.domain.character.error_codes'

local Attributes = {}

local PRIMARY_KEYS = {
    'strength',
    'constitution',
    'agility',
    'inner_power',
}
local PRIMARY_KEY_SET = {
    strength = true,
    constitution = true,
    agility = true,
    inner_power = true,
}
local PRIMARY_MAXIMUM = 9999
local GROWTH_MAXIMUM = 100000

local function failure(field, reason, details)
    details = details or {}
    details.field = field
    details.reason = reason
    return Result.err(
        ErrorCodes.CHARACTER_PRIMARY_ATTRIBUTES_INVALID,
        'error.character.primary_attributes_invalid',
        false,
        details
    )
end

local function validate_exact_integer_map(value, maximum, field)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return failure(field, 'TABLE_REQUIRED')
    end

    local keys = Ordered.sorted_string_keys(value)
    if not keys.ok then
        return failure(field, 'STRING_KEYS_REQUIRED')
    end
    if #keys.value ~= #PRIMARY_KEYS then
        return failure(field, 'EXACT_PRIMARY_KEYS_REQUIRED')
    end

    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        if not PRIMARY_KEY_SET[key] then
            return failure(field .. '.' .. key, 'UNKNOWN_PRIMARY_ATTRIBUTE')
        end
    end
    for index = 1, #PRIMARY_KEYS do
        local key = PRIMARY_KEYS[index]
        if not TableShape.is_integer(value[key], 0, maximum) then
            return failure(field .. '.' .. key, 'INTEGER_OUT_OF_RANGE', {
                minimum = 0,
                maximum = maximum,
            })
        end
    end
    return Result.ok(true)
end

function Attributes.validate_primary(value, field)
    return validate_exact_integer_map(value, PRIMARY_MAXIMUM, field or 'base_primary')
end

function Attributes.validate_growth(value, field)
    return validate_exact_integer_map(
        value,
        GROWTH_MAXIMUM,
        field or 'growth_per_level_milli'
    )
end

function Attributes.from_definition(base_primary, growth_per_level_milli, level)
    local base_result = Attributes.validate_primary(base_primary, 'base_primary')
    if not base_result.ok then
        return base_result
    end
    local growth_result = Attributes.validate_growth(
        growth_per_level_milli,
        'growth_per_level_milli'
    )
    if not growth_result.ok then
        return growth_result
    end
    if not TableShape.is_integer(level, 1, 100) then
        return failure('level', 'INTEGER_OUT_OF_RANGE', {
            minimum = 1,
            maximum = 100,
        })
    end

    local values = {}
    local diagnostics = {}
    local index
    for index = 1, #PRIMARY_KEYS do
        local key = PRIMARY_KEYS[index]
        local growth = math.floor((level - 1) * growth_per_level_milli[key] / 1000)
        local unclamped = base_primary[key] + growth
        local final = unclamped
        if final > PRIMARY_MAXIMUM then
            final = PRIMARY_MAXIMUM
        end
        values[key] = final
        if final ~= unclamped then
            diagnostics[#diagnostics + 1] = {
                code = 'STAT_CLAMPED',
                target_stat = key,
                before = unclamped,
                after = final,
                minimum = 0,
                maximum = PRIMARY_MAXIMUM,
            }
        end
    end

    return Result.ok({
        values = values,
        diagnostics = diagnostics,
    })
end

function Attributes.primary_keys()
    local copy = {}
    local index
    for index = 1, #PRIMARY_KEYS do
        copy[index] = PRIMARY_KEYS[index]
    end
    return copy
end

return Attributes
