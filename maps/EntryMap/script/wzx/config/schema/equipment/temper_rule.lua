local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.equipment.validation'

local TemperRule = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'TemperRule'
local FIELDS = {
    id = true,
    schema_version = true,
    reroll_mode = true,
    copper_cost_base = true,
    material_item_id = true,
    material_count = true,
    cost_growth_bp_per_ordinal = true,
    max_roll_ordinal_for_cost = true,
    allow_same_result = true,
}
local REROLL_MODES = {
    ONE_SLOT = true,
}

function TemperRule.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local reroll_mode = raw_get(value, 'reroll_mode')
    if reroll_mode == nil then
        reroll_mode = 'ONE_SLOT'
    end
    local material_item_id = raw_get(value, 'material_item_id')
    local material_count = raw_get(value, 'material_count')
    if material_count == nil then
        material_count = 0
    end
    local cost_growth = raw_get(value, 'cost_growth_bp_per_ordinal')
    if cost_growth == nil then
        cost_growth = 0
    end
    local max_ordinal = raw_get(value, 'max_roll_ordinal_for_cost')
    if max_ordinal == nil then
        max_ordinal = 0
    end
    local allow_same_result = raw_get(value, 'allow_same_result')
    if allow_same_result == nil then
        allow_same_result = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'temper_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_enum(SCHEMA, 'reroll_mode', reroll_mode, REROLL_MODES),
        validation_integer(SCHEMA, 'copper_cost_base', raw_get(value, 'copper_cost_base'), 0, 2000000000),
        validation_content_id(SCHEMA, 'material_item_id', material_item_id, 'item_', true),
        validation_integer(SCHEMA, 'material_count', material_count, 0, 9999),
        validation_integer(SCHEMA, 'cost_growth_bp_per_ordinal', cost_growth, 0, 10000),
        validation_integer(SCHEMA, 'max_roll_ordinal_for_cost', max_ordinal, 0, 1000),
        validation_boolean(SCHEMA, 'allow_same_result', allow_same_result)
    )
    if err ~= nil then
        return err
    end
    if material_item_id == nil and material_count ~= 0 then
        return validation_invalid(SCHEMA, 'material_count', 'MATERIAL_COUNT_MUST_BE_ZERO')
    end
    if material_item_id ~= nil and material_count < 1 then
        return validation_invalid(SCHEMA, 'material_count', 'MATERIAL_COUNT_REQUIRED')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        reroll_mode = reroll_mode,
        copper_cost_base = value.copper_cost_base,
        material_item_id = material_item_id,
        material_count = material_count,
        cost_growth_bp_per_ordinal = cost_growth,
        max_roll_ordinal_for_cost = max_ordinal,
        allow_same_result = allow_same_result,
    })
end

return TemperRule
