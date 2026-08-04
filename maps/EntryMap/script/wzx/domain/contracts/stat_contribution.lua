local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.domain.contracts.validation'

local StatContribution = {}
local result_ok = Result.ok
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_sorted_unique_strings = Validation.sorted_unique_strings
local validation_source_reference = Validation.source_reference
local validation_stable_order_key = Validation.stable_order_key

local CONTRACT = 'StatContributionV1'
local ALLOWED_FIELDS = {
    source_type = true,
    source_id = true,
    target_stat = true,
    operation = true,
    value = true,
    priority = true,
    condition_tags = true,
    stable_order_key = true,
}
local SOURCE_TYPES = {
    CHARACTER = true,
    LEVEL = true,
    TALENT = true,
    EQUIPMENT = true,
    MARTIAL = true,
    PROGRESSION = true,
    FORMATION = true,
    ENCOUNTER = true,
}
local OPERATIONS = {
    ADD_FLAT = true,
    ADD_BP = true,
    MULTIPLY_BP = true,
    SET_MIN = true,
    SET_MAX = true,
}
local TARGET_STATS = {
    max_hp = true,
    attack = true,
    defense = true,
    speed = true,
    accuracy = true,
    evasion = true,
    crit_chance_bp = true,
    crit_damage_bp = true,
    crit_resist_bp = true,
    block_chance_bp = true,
    block_reduction_bp = true,
    damage_bonus_bp = true,
    damage_reduction_bp = true,
    healing_bonus_bp = true,
    healing_received_bp = true,
    max_qi = true,
    initial_qi = true,
    qi_gain_bp = true,
    effect_accuracy = true,
    effect_resistance = true,
}

function StatContribution.validate(value)
    local err = validation_no_unknown_fields(CONTRACT, value, ALLOWED_FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_enum(CONTRACT, 'source_type', value.source_type, SOURCE_TYPES),
        validation_source_reference(CONTRACT, 'source_id', value.source_id),
        validation_enum(CONTRACT, 'target_stat', value.target_stat, TARGET_STATS),
        validation_enum(CONTRACT, 'operation', value.operation, OPERATIONS),
        validation_integer(
            CONTRACT,
            'value',
            value.value,
            -1000000000,
            1000000000
        ),
        validation_integer(CONTRACT, 'priority', value.priority, -1000, 1000),
        validation_sorted_unique_strings(
            CONTRACT,
            'condition_tags',
            value.condition_tags
        ),
        validation_stable_order_key(
            CONTRACT,
            'stable_order_key',
            value.stable_order_key
        )
    )
    if err ~= nil then
        return err
    end
    return result_ok(value)
end

return StatContribution
