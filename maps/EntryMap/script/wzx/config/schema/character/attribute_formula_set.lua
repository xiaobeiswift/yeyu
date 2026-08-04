local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.character.validation'

local AttributeFormulaSet = {}
local raw_get = rawget
local result_ok = Result.ok
local validation_content_id = Validation.content_id
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'AttributeFormulaSet'
local COEFFICIENT_FIELDS = {
    'base_hp',
    'hp_per_level',
    'hp_per_constitution',
    'base_attack',
    'attack_per_level',
    'attack_per_strength',
    'attack_per_inner_power_milli',
    'base_defense',
    'defense_per_level',
    'defense_per_constitution',
    'base_speed',
    'speed_per_agility',
    'base_accuracy',
    'accuracy_per_agility',
    'base_evasion',
    'evasion_per_agility',
    'base_max_qi',
    'max_qi_per_inner_power',
    'effect_accuracy_per_inner_power',
    'effect_resistance_per_constitution',
}
local FIELDS = {
    id = true,
    formula_version = true,
}
local index
for index = 1, #COEFFICIENT_FIELDS do
    FIELDS[COEFFICIENT_FIELDS[index]] = true
end

function AttributeFormulaSet.validate(value)
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id),
        validation_integer(SCHEMA, 'formula_version', value.formula_version, 1)
    )
    if err ~= nil then
        return err
    end

    for index = 1, #COEFFICIENT_FIELDS do
        local field = raw_get(COEFFICIENT_FIELDS, index)
        err = validation_integer(SCHEMA, field, raw_get(value, field))
        if err ~= nil then
            return err
        end
    end
    local normalized = {
        id = value.id,
        formula_version = value.formula_version,
    }
    for index = 1, #COEFFICIENT_FIELDS do
        local field = raw_get(COEFFICIENT_FIELDS, index)
        normalized[field] = raw_get(value, field)
    end
    return result_ok(normalized)
end

return AttributeFormulaSet
