local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.equipment.validation'

local AffixDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string
local validation_sorted_unique_strings = Validation.sorted_unique_strings

local SCHEMA = 'AffixDefinition'
local TIER_SCHEMA = 'AffixTier'
local FIELDS = {
    id = true,
    schema_version = true,
    stat_id = true,
    value_mode = true,
    exclusive_group = true,
    allowed_slots = true,
    allowed_routes = true,
    tiers = true,
    public_snapshot_allowed = true,
}
local TIER_FIELDS = {
    tier = true,
    min_value = true,
    max_value = true,
    step = true,
}
local VALUE_MODES = {
    FLAT = true,
    RATE_BP = true,
}
local SLOTS = {
    WEAPON = true,
    HEAD = true,
    BODY = true,
    ACCESSORY = true,
}
local ROUTES = {
    UNARMED = true,
    SWORD = true,
    BLADE = true,
    STAFF = true,
    NONE = true,
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

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

local function validate_slot_list(field, values)
    local err = validation_dense_array(SCHEMA, field, values)
    if err ~= nil then
        return err
    end
    err = validation_sorted_unique_strings(SCHEMA, field, values)
    if err ~= nil then
        return err
    end
    if #values < 1 then
        return validation_invalid(SCHEMA, field, 'AT_LEAST_ONE_REQUIRED')
    end
    local index
    for index = 1, #values do
        if SLOTS[values[index]] ~= true then
            return validation_invalid(SCHEMA, field, 'ENUM_INVALID', { index = index })
        end
    end
    return nil
end

local function validate_route_list(field, values)
    local err = validation_dense_array(SCHEMA, field, values)
    if err ~= nil then
        return err
    end
    err = validation_sorted_unique_strings(SCHEMA, field, values)
    if err ~= nil then
        return err
    end
    if #values < 1 then
        return validation_invalid(SCHEMA, field, 'AT_LEAST_ONE_REQUIRED')
    end
    local index
    for index = 1, #values do
        if ROUTES[values[index]] ~= true then
            return validation_invalid(SCHEMA, field, 'ENUM_INVALID', { index = index })
        end
    end
    return nil
end

local function validate_tier(row, expected_tier)
    local path = 'tiers[' .. tostring(expected_tier) .. ']'
    local err = validation_no_unknown_fields(TIER_SCHEMA, row, TIER_FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_integer(TIER_SCHEMA, path .. '.tier', raw_get(row, 'tier'), 1, 5),
        validation_integer(TIER_SCHEMA, path .. '.min_value', raw_get(row, 'min_value'), -999999, 999999),
        validation_integer(TIER_SCHEMA, path .. '.max_value', raw_get(row, 'max_value'), -999999, 999999),
        validation_integer(TIER_SCHEMA, path .. '.step', raw_get(row, 'step'), 1, 999999)
    )
    if err ~= nil then
        return err
    end
    if row.tier ~= expected_tier then
        return validation_invalid(TIER_SCHEMA, path .. '.tier', 'TIER_SEQUENCE_INVALID', {
            expected = expected_tier,
            actual = row.tier,
        })
    end
    if row.min_value > row.max_value then
        return validation_invalid(TIER_SCHEMA, path, 'MIN_GREATER_THAN_MAX')
    end
    local span = row.max_value - row.min_value
    if span % row.step ~= 0 then
        return validation_invalid(TIER_SCHEMA, path, 'STEP_DOES_NOT_DIVIDE_RANGE')
    end
    return result_ok({
        tier = row.tier,
        min_value = row.min_value,
        max_value = row.max_value,
        step = row.step,
    })
end

function AffixDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local exclusive_group = raw_get(value, 'exclusive_group')
    local public_snapshot_allowed = raw_get(value, 'public_snapshot_allowed')
    if public_snapshot_allowed == nil then
        public_snapshot_allowed = true
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'affix_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_enum(SCHEMA, 'stat_id', raw_get(value, 'stat_id'), TARGET_STATS),
        validation_enum(SCHEMA, 'value_mode', raw_get(value, 'value_mode'), VALUE_MODES),
        validation_dense_array(SCHEMA, 'tiers', raw_get(value, 'tiers')),
        validation_boolean(SCHEMA, 'public_snapshot_allowed', public_snapshot_allowed)
    )
    if err ~= nil then
        return err
    end

    if exclusive_group ~= nil then
        err = validation_non_empty_string(SCHEMA, 'exclusive_group', exclusive_group)
        if err ~= nil then
            return err
        end
    end

    err = validate_slot_list('allowed_slots', raw_get(value, 'allowed_slots'))
    if err ~= nil then
        return err
    end
    err = validate_route_list('allowed_routes', raw_get(value, 'allowed_routes'))
    if err ~= nil then
        return err
    end

    if #value.tiers < 1 or #value.tiers > 5 then
        return validation_invalid(SCHEMA, 'tiers', 'TIER_COUNT_OUT_OF_RANGE', {
            count = #value.tiers,
        })
    end

    local tiers = {}
    local index
    for index = 1, #value.tiers do
        local row = value.tiers[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return validation_invalid(SCHEMA, 'tiers[' .. tostring(index) .. ']', 'TABLE_REQUIRED')
        end
        local validated = validate_tier(row, index)
        if not validated.ok then
            return validated
        end
        tiers[index] = validated.value
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        stat_id = value.stat_id,
        value_mode = value.value_mode,
        exclusive_group = exclusive_group,
        allowed_slots = copy_strings(value.allowed_slots),
        allowed_routes = copy_strings(value.allowed_routes),
        tiers = tiers,
        public_snapshot_allowed = public_snapshot_allowed,
    })
end

return AffixDefinition
