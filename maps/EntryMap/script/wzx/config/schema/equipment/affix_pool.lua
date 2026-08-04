local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.equipment.validation'

local AffixPool = {}
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

local SCHEMA = 'AffixPool'
local ENTRY_SCHEMA = 'AffixPoolEntry'
local FIELDS = {
    id = true,
    schema_version = true,
    entries = true,
}
local ENTRY_FIELDS = {
    entry_order = true,
    affix_id = true,
    tier = true,
    weight = true,
    rarity_min = true,
    rarity_max = true,
}
local RARITIES = {
    COMMON = true,
    FINE = true,
    RARE = true,
    EPIC = true,
    LEGEND = true,
}
local RARITY_RANK = {
    COMMON = 1,
    FINE = 2,
    RARE = 3,
    EPIC = 4,
    LEGEND = 5,
}

local function validate_entry(entry, expected_order)
    local path = 'entries[' .. tostring(expected_order) .. ']'
    local err = validation_no_unknown_fields(ENTRY_SCHEMA, entry, ENTRY_FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_integer(ENTRY_SCHEMA, path .. '.entry_order', raw_get(entry, 'entry_order'), 1, 256),
        validation_content_id(ENTRY_SCHEMA, path .. '.affix_id', raw_get(entry, 'affix_id'), 'affix_'),
        validation_integer(ENTRY_SCHEMA, path .. '.tier', raw_get(entry, 'tier'), 1, 5),
        validation_integer(ENTRY_SCHEMA, path .. '.weight', raw_get(entry, 'weight'), 1, 1000000),
        validation_enum(ENTRY_SCHEMA, path .. '.rarity_min', raw_get(entry, 'rarity_min'), RARITIES),
        validation_enum(ENTRY_SCHEMA, path .. '.rarity_max', raw_get(entry, 'rarity_max'), RARITIES)
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
    if RARITY_RANK[entry.rarity_min] > RARITY_RANK[entry.rarity_max] then
        return validation_invalid(ENTRY_SCHEMA, path, 'RARITY_RANGE_INVALID')
    end
    return result_ok({
        entry_order = entry.entry_order,
        affix_id = entry.affix_id,
        tier = entry.tier,
        weight = entry.weight,
        rarity_min = entry.rarity_min,
        rarity_max = entry.rarity_max,
    })
end

function AffixPool.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'affixpool_'),
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
    local total_weight = 0
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
        total_weight = total_weight + validated.value.weight
        if total_weight > 2000000000 then
            return validation_invalid(SCHEMA, 'entries', 'TOTAL_WEIGHT_OVERFLOW')
        end
        entries[index] = validated.value
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        entries = entries,
    })
end

return AffixPool
