local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.character.validation'

local LevelCurve = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local tostring_value = tostring
local type_value = type
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'LevelCurve'
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_LEVEL_REWARD_REFS = 64
local FIELDS = {
    id = true,
    level_cap = true,
    experience_cap = true,
    cumulative_exp_by_level = true,
    level_reward_refs = true,
}
local REWARD_ROW_FIELDS = {
    reached_level = true,
    reward_ref = true,
}

local function copy_array(value)
    local copy = {}
    local index
    for index = 1, #value do
        copy[index] = raw_get(value, index)
    end
    return copy
end

local function copy_reward_rows(value)
    local copy = {}
    local index
    for index = 1, #value do
        local row = raw_get(value, index)
        copy[index] = {
            reached_level = raw_get(row, 'reached_level'),
            reward_ref = raw_get(row, 'reward_ref'),
        }
    end
    return copy
end

local function validate_cumulative_experience(value, level_cap)
    local err = validation_dense_array(SCHEMA, 'cumulative_exp_by_level', value)
    if err ~= nil then
        return err
    end
    if #value ~= level_cap then
        return validation_invalid(
            SCHEMA,
            'cumulative_exp_by_level',
            'LEVEL_COUNT_MISMATCH',
            {
                actual = #value,
                expected = level_cap,
            }
        )
    end

    local previous
    local index
    for index = 1, #value do
        err = validation_integer(
            SCHEMA,
            'cumulative_exp_by_level[' .. tostring_value(index) .. ']',
            raw_get(value, index),
            0,
            MAX_SAFE_INTEGER
        )
        if err ~= nil then
            return err
        end
        if index == 1 and raw_get(value, index) ~= 0 then
            return validation_invalid(
                SCHEMA,
                'cumulative_exp_by_level[1]',
                'FIRST_LEVEL_EXPERIENCE_MUST_BE_ZERO'
            )
        end
        if previous ~= nil and previous >= raw_get(value, index) then
            return validation_invalid(
                SCHEMA,
                'cumulative_exp_by_level',
                'STRICT_ASCENDING_ORDER_REQUIRED',
                { index = index }
            )
        end
        previous = raw_get(value, index)
    end
    return nil
end

local function validate_reward_refs(value, level_cap)
    local err = validation_dense_array(SCHEMA, 'level_reward_refs', value, true)
    if err ~= nil or value == nil then
        return err
    end
    if #value > MAX_LEVEL_REWARD_REFS then
        return validation_invalid(
            SCHEMA,
            'level_reward_refs',
            'REWARD_REF_COUNT_LIMIT_EXCEEDED',
            {
                actual = #value,
                maximum = MAX_LEVEL_REWARD_REFS,
            }
        )
    end

    local previous_level
    local index
    for index = 1, #value do
        local row = raw_get(value, index)
        local path = 'level_reward_refs[' .. tostring_value(index) .. ']'
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return validation_invalid(SCHEMA, path, 'TABLE_REQUIRED')
        end
        err = validation_no_unknown_fields(SCHEMA, row, REWARD_ROW_FIELDS)
        if err ~= nil then
            local nested_field = err.error.details.field
            if nested_field == '$' then
                nested_field = path
            else
                nested_field = path .. '.' .. nested_field
            end
            return validation_invalid(
                SCHEMA,
                nested_field,
                err.error.details.reason
            )
        end
        err = validation_integer(
            SCHEMA,
            path .. '.reached_level',
            raw_get(row, 'reached_level'),
            2,
            level_cap
        )
        if err ~= nil then
            return err
        end
        err = validation_content_id(
            SCHEMA,
            path .. '.reward_ref',
            raw_get(row, 'reward_ref'),
            'reward_'
        )
        if err ~= nil then
            return err
        end
        if previous_level ~= nil
            and previous_level >= raw_get(row, 'reached_level')
        then
            return validation_invalid(
                SCHEMA,
                'level_reward_refs',
                'STRICT_ASCENDING_REACHED_LEVEL_REQUIRED',
                { index = index }
            )
        end
        previous_level = raw_get(row, 'reached_level')
    end
    return nil
end

function LevelCurve.validate(value)
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'curve_level_'),
        validation_integer(SCHEMA, 'level_cap', value.level_cap, 1, 100)
    )
    if err ~= nil then
        return err
    end

    err = validate_cumulative_experience(value.cumulative_exp_by_level, value.level_cap)
    if err ~= nil then
        return err
    end
    err = validation_integer(
        SCHEMA,
        'experience_cap',
        value.experience_cap,
        value.cumulative_exp_by_level[value.level_cap],
        MAX_SAFE_INTEGER
    )
    if err ~= nil then
        return err
    end
    err = validate_reward_refs(value.level_reward_refs, value.level_cap)
    if err ~= nil then
        return err
    end
    local normalized = {
        id = value.id,
        level_cap = value.level_cap,
        experience_cap = value.experience_cap,
        cumulative_exp_by_level = copy_array(value.cumulative_exp_by_level),
        level_reward_refs = copy_reward_rows(value.level_reward_refs or {}),
    }
    return result_ok(normalized)
end

LevelCurve.MAX_LEVEL_REWARD_REFS = MAX_LEVEL_REWARD_REFS

return LevelCurve
