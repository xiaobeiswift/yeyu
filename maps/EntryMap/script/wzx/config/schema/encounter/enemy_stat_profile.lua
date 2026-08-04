local Result = require 'wzx.domain.common.result'
local Attributes = require 'wzx.domain.character.attributes'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'
local Validation = require 'wzx.config.schema.encounter.validation'

local EnemyStatProfile = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'EnemyStatProfile'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    base_primary = true,
    growth_per_level_milli = true,
    formula = true,
    flat_combat_contributions = true,
    rank_multiplier_bp = true,
    level_min = true,
    level_max = true,
    initial_qi = true,
    deprecated = true,
}
local FORMULA_FIELDS = {
    id = true,
    formula_version = true,
    base_hp = true,
    hp_per_level = true,
    hp_per_constitution = true,
    base_attack = true,
    attack_per_level = true,
    attack_per_strength = true,
    attack_per_inner_power_milli = true,
    base_defense = true,
    defense_per_level = true,
    defense_per_constitution = true,
    base_speed = true,
    speed_per_agility = true,
    base_accuracy = true,
    accuracy_per_agility = true,
    base_evasion = true,
    evasion_per_agility = true,
    base_max_qi = true,
    max_qi_per_inner_power = true,
    effect_accuracy_per_inner_power = true,
    effect_resistance_per_constitution = true,
}
local FORMULA_INTEGER_KEYS = {
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
local RANK_FIELDS = {
    NORMAL = true,
    ELITE = true,
    BOSS = true,
    SUMMON = true,
    MECHANIC_OBJECT = true,
}
local MAX_SAFE = 9007199254740991

local function copy_primary(value)
    return {
        strength = value.strength,
        constitution = value.constitution,
        agility = value.agility,
        inner_power = value.inner_power,
    }
end

local function copy_formula(value)
    local copied = {
        id = value.id,
        formula_version = value.formula_version,
    }
    local index
    for index = 1, #FORMULA_INTEGER_KEYS do
        local key = FORMULA_INTEGER_KEYS[index]
        copied[key] = value[key]
    end
    return copied
end

local function copy_contribution(value)
    local tags = {}
    local index
    for index = 1, #value.condition_tags do
        tags[index] = value.condition_tags[index]
    end
    return {
        source_type = value.source_type,
        source_id = value.source_id,
        target_stat = value.target_stat,
        operation = value.operation,
        value = value.value,
        priority = value.priority,
        condition_tags = tags,
        stable_order_key = value.stable_order_key,
    }
end

local function validate_formula(formula)
    local err = validation_no_unknown_fields(SCHEMA, formula, FORMULA_FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_content_id(SCHEMA, 'formula.id', formula.id, nil),
        validation_integer(SCHEMA, 'formula.formula_version', formula.formula_version, 1)
    )
    if err ~= nil then
        return err
    end
    local index
    for index = 1, #FORMULA_INTEGER_KEYS do
        local key = FORMULA_INTEGER_KEYS[index]
        err = validation_integer(
            SCHEMA,
            'formula.' .. key,
            formula[key],
            -MAX_SAFE,
            MAX_SAFE
        )
        if err ~= nil then
            return err
        end
    end
    return nil
end

local function validate_rank_multiplier_bp(value)
    local err = validation_no_unknown_fields(SCHEMA, value, RANK_FIELDS)
    if err ~= nil then
        return err
    end
    local rank
    for rank in pairs(RANK_FIELDS) do
        err = validation_integer(
            SCHEMA,
            'rank_multiplier_bp.' .. rank,
            value[rank],
            1000,
            50000
        )
        if err ~= nil then
            return err
        end
    end
    return nil
end

function EnemyStatProfile.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local contributions = raw_get(value, 'flat_combat_contributions')
    if contributions == nil then
        contributions = {}
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local initial_qi = raw_get(value, 'initial_qi')
    if initial_qi == nil then
        initial_qi = 0
    end
    local level_min = raw_get(value, 'level_min')
    if level_min == nil then
        level_min = 1
    end
    local level_max = raw_get(value, 'level_max')
    if level_max == nil then
        level_max = 100
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'statprof_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_integer(SCHEMA, 'level_min', level_min, 1, 100),
        validation_integer(SCHEMA, 'level_max', level_max, 1, 100),
        validation_integer(SCHEMA, 'initial_qi', initial_qi, 0, 2000),
        validation_boolean(SCHEMA, 'deprecated', deprecated),
        validation_dense_array(SCHEMA, 'flat_combat_contributions', contributions)
    )
    if err ~= nil then
        return err
    end
    if level_min > level_max then
        return validation_invalid(SCHEMA, 'level_max', 'LEVEL_RANGE_INVALID')
    end

    local primary = Attributes.validate_primary(value.base_primary, 'base_primary')
    if not primary.ok then
        return validation_invalid(SCHEMA, 'base_primary', 'PRIMARY_INVALID', {
            cause_code = primary.error and primary.error.code or 'UNKNOWN',
        })
    end
    local growth = Attributes.validate_growth(value.growth_per_level_milli, 'growth_per_level_milli')
    if not growth.ok then
        return validation_invalid(SCHEMA, 'growth_per_level_milli', 'GROWTH_INVALID', {
            cause_code = growth.error and growth.error.code or 'UNKNOWN',
        })
    end

    err = validate_formula(value.formula)
    if err ~= nil then
        return err
    end
    err = validate_rank_multiplier_bp(value.rank_multiplier_bp)
    if err ~= nil then
        return err
    end

    local copied_contributions = {}
    local index
    for index = 1, #contributions do
        local contribution = contributions[index]
        local validated = StatContribution.validate(contribution)
        if not validated.ok then
            return validation_invalid(SCHEMA, 'flat_combat_contributions', 'CONTRIBUTION_INVALID', {
                index = index,
            })
        end
        if contribution.source_type ~= 'ENCOUNTER' then
            return validation_invalid(
                SCHEMA,
                'flat_combat_contributions.source_type',
                'ENCOUNTER_SOURCE_REQUIRED',
                { index = index }
            )
        end
        copied_contributions[index] = copy_contribution(contribution)
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        base_primary = copy_primary(value.base_primary),
        growth_per_level_milli = copy_primary(value.growth_per_level_milli),
        formula = copy_formula(value.formula),
        flat_combat_contributions = copied_contributions,
        rank_multiplier_bp = {
            NORMAL = value.rank_multiplier_bp.NORMAL,
            ELITE = value.rank_multiplier_bp.ELITE,
            BOSS = value.rank_multiplier_bp.BOSS,
            SUMMON = value.rank_multiplier_bp.SUMMON,
            MECHANIC_OBJECT = value.rank_multiplier_bp.MECHANIC_OBJECT,
        },
        level_min = level_min,
        level_max = level_max,
        initial_qi = initial_qi,
        deprecated = deprecated,
    })
end

return EnemyStatProfile
