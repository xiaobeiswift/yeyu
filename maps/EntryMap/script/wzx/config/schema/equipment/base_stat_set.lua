local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.equipment.validation'

local BaseStatSet = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'BaseStatSet'
local ENTRY_SCHEMA = 'BaseStatEntry'
local FIELDS = {
    id = true,
    schema_version = true,
    entries = true,
}
local ENTRY_FIELDS = {
    entry_order = true,
    stat_id = true,
    flat_value = true,
    rate_basis_points = true,
}

-- Reuse StatContribution target_stat whitelist via a probe table.
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

local function validate_entry(entry, expected_order)
    local path = 'entries[' .. tostring(expected_order) .. ']'
    local err = validation_no_unknown_fields(ENTRY_SCHEMA, entry, ENTRY_FIELDS)
    if err ~= nil then
        return err
    end
    local flat_value = raw_get(entry, 'flat_value')
    if flat_value == nil then
        flat_value = 0
    end
    local rate_bp = raw_get(entry, 'rate_basis_points')
    if rate_bp == nil then
        rate_bp = 0
    end
    err = validation_first(
        validation_integer(ENTRY_SCHEMA, path .. '.entry_order', raw_get(entry, 'entry_order'), 1, 64),
        validation_enum(ENTRY_SCHEMA, path .. '.stat_id', raw_get(entry, 'stat_id'), TARGET_STATS),
        validation_integer(ENTRY_SCHEMA, path .. '.flat_value', flat_value, 0, 999999),
        validation_integer(ENTRY_SCHEMA, path .. '.rate_basis_points', rate_bp, -5000, 50000)
    )
    if err ~= nil then
        return err
    end
    if entry.entry_order ~= expected_order then
        return validation_invalid(ENTRY_SCHEMA, path .. '.entry_order', 'ENTRY_ORDER_SEQUENCE_INVALID', {
            expected = expected_order,
            actual = entry.entry_order,
        })
    end
    if flat_value == 0 and rate_bp == 0 then
        return validation_invalid(ENTRY_SCHEMA, path, 'EMPTY_STAT_ENTRY')
    end
    return result_ok({
        entry_order = entry.entry_order,
        stat_id = entry.stat_id,
        flat_value = flat_value,
        rate_basis_points = rate_bp,
    })
end

function BaseStatSet.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'equipstat_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_dense_array(SCHEMA, 'entries', raw_get(value, 'entries'))
    )
    if err ~= nil then
        return err
    end
    if #value.entries < 1 then
        return validation_invalid(SCHEMA, 'entries', 'AT_LEAST_ONE_ENTRY_REQUIRED')
    end

    local entries = {}
    local seen_stats = {}
    local index
    for index = 1, #value.entries do
        local entry = value.entries[index]
        if type_value(entry) ~= 'table' or get_metatable(entry) ~= nil then
            return validation_invalid(SCHEMA, 'entries[' .. tostring(index) .. ']', 'TABLE_REQUIRED')
        end
        local validated = validate_entry(entry, index)
        if not validated.ok then
            return validated
        end
        if seen_stats[validated.value.stat_id] then
            return validation_invalid(SCHEMA, 'entries', 'DUPLICATE_STAT_ID', {
                stat_id = validated.value.stat_id,
            })
        end
        seen_stats[validated.value.stat_id] = true
        entries[index] = validated.value
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        entries = entries,
    })
end

return BaseStatSet
