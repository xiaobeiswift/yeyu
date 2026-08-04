local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.character.validation'

local LevelCurve = {}

local SCHEMA = 'LevelCurve'
local MAX_SAFE_INTEGER = 9007199254740991
local FIELDS = {
    id = true,
    level_cap = true,
    cumulative_exp_by_level = true,
    level_reward_refs = true,
}

local function copy_array(value)
    local copy = {}
    local index
    for index = 1, #value do
        copy[index] = value[index]
    end
    return copy
end

local function validate_cumulative_experience(value, level_cap)
    local err = Validation.dense_array(SCHEMA, 'cumulative_exp_by_level', value)
    if err ~= nil then
        return err
    end
    if #value ~= level_cap then
        return Validation.invalid(
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
        err = Validation.integer(
            SCHEMA,
            'cumulative_exp_by_level[' .. tostring(index) .. ']',
            value[index],
            0,
            MAX_SAFE_INTEGER
        )
        if err ~= nil then
            return err
        end
        if index == 1 and value[index] ~= 0 then
            return Validation.invalid(
                SCHEMA,
                'cumulative_exp_by_level[1]',
                'FIRST_LEVEL_EXPERIENCE_MUST_BE_ZERO'
            )
        end
        if previous ~= nil and previous >= value[index] then
            return Validation.invalid(
                SCHEMA,
                'cumulative_exp_by_level',
                'STRICT_ASCENDING_ORDER_REQUIRED',
                { index = index }
            )
        end
        previous = value[index]
    end
    return nil
end

local function validate_reward_refs(value)
    local err = Validation.dense_array(SCHEMA, 'level_reward_refs', value, true)
    if err ~= nil or value == nil then
        return err
    end

    local index
    for index = 1, #value do
        err = Validation.content_id(
            SCHEMA,
            'level_reward_refs[' .. tostring(index) .. ']',
            value[index],
            'reward_'
        )
        if err ~= nil then
            return err
        end
    end
    return nil
end

function LevelCurve.validate(value)
    local err = Validation.no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    err = Validation.first(
        Validation.content_id(SCHEMA, 'id', value.id, 'curve_level_'),
        Validation.integer(SCHEMA, 'level_cap', value.level_cap, 1, 100)
    )
    if err ~= nil then
        return err
    end

    err = validate_cumulative_experience(value.cumulative_exp_by_level, value.level_cap)
    if err ~= nil then
        return err
    end
    err = validate_reward_refs(value.level_reward_refs)
    if err ~= nil then
        return err
    end
    local normalized = {
        id = value.id,
        level_cap = value.level_cap,
        cumulative_exp_by_level = copy_array(value.cumulative_exp_by_level),
    }
    if value.level_reward_refs ~= nil then
        normalized.level_reward_refs = copy_array(value.level_reward_refs)
    end
    return Result.ok(normalized)
end

return LevelCurve
