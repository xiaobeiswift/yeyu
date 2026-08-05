local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.economy.validation'

local LootGroup = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_content_id = Validation.content_id
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'LootGroup'
local MAX_NO_DROP = 1000000
local FIELDS = {
    id = true,
    schema_version = true,
    mode = true,
    roll_count = true,
    no_drop_weight = true,
    duplicate_policy = true,
    deprecated = true,
}
local MODES = {
    WEIGHTED_ONE = true,
    INDEPENDENT_EACH = true,
    GUARANTEED_ALL = true,
}
local DUPLICATE_POLICIES = {
    ALLOW = true,
    MERGE = true,
    REROLL_UNIQUE = true,
}

function LootGroup.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end

    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local mode = raw_get(value, 'mode')
    local duplicate_policy = raw_get(value, 'duplicate_policy')
    if duplicate_policy == nil then
        duplicate_policy = 'ALLOW'
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local no_drop_weight = raw_get(value, 'no_drop_weight')
    if no_drop_weight == nil then
        no_drop_weight = 0
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'lootgroup_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1, 1),
        validation_enum(SCHEMA, 'mode', mode, MODES),
        validation_integer(SCHEMA, 'roll_count', raw_get(value, 'roll_count'), 1, 100),
        validation_integer(SCHEMA, 'no_drop_weight', no_drop_weight, 0, MAX_NO_DROP),
        validation_enum(SCHEMA, 'duplicate_policy', duplicate_policy, DUPLICATE_POLICIES)
    )
    if err ~= nil then
        return err
    end

    if type_value(deprecated) ~= 'boolean' then
        return validation_invalid(SCHEMA, 'deprecated', 'BOOLEAN_REQUIRED')
    end

    if mode ~= 'WEIGHTED_ONE' and no_drop_weight ~= 0 then
        return validation_invalid(
            SCHEMA,
            'no_drop_weight',
            'NO_DROP_WEIGHT_ONLY_FOR_WEIGHTED_ONE'
        )
    end

    return result_ok({
        id = raw_get(value, 'id'),
        schema_version = 1,
        mode = mode,
        roll_count = raw_get(value, 'roll_count'),
        no_drop_weight = no_drop_weight,
        duplicate_policy = duplicate_policy,
        deprecated = deprecated,
    })
end

return LootGroup
