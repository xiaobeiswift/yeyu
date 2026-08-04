local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.character.validation'

local AttributeFormulaSet = {}

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
    local err = Validation.no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    err = Validation.first(
        Validation.content_id(SCHEMA, 'id', value.id),
        Validation.integer(SCHEMA, 'formula_version', value.formula_version, 1)
    )
    if err ~= nil then
        return err
    end

    for index = 1, #COEFFICIENT_FIELDS do
        local field = COEFFICIENT_FIELDS[index]
        err = Validation.integer(SCHEMA, field, value[field])
        if err ~= nil then
            return err
        end
    end
    local normalized = {
        id = value.id,
        formula_version = value.formula_version,
    }
    for index = 1, #COEFFICIENT_FIELDS do
        local field = COEFFICIENT_FIELDS[index]
        normalized[field] = value[field]
    end
    return Result.ok(normalized)
end

return AttributeFormulaSet
