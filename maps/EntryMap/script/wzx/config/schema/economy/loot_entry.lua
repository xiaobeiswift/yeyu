local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.economy.validation'

local LootEntry = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_content_id = Validation.content_id
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'LootEntry'
local MAX_WEIGHT = 1000000000
local MAX_CHANCE_BP = 10000
local FIELDS = {
    group_id = true,
    entry_order = true,
    reward_id = true,
    weight = true,
    chance_bp = true,
    min_quantity_multiplier = true,
    max_quantity_multiplier = true,
    condition_set_id = true,
    unique_key = true,
}

function LootEntry.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end

    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local min_mult = raw_get(value, 'min_quantity_multiplier')
    if min_mult == nil then
        min_mult = 1
    end
    local max_mult = raw_get(value, 'max_quantity_multiplier')
    if max_mult == nil then
        max_mult = 1
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'group_id', raw_get(value, 'group_id'), 'lootgroup_'),
        validation_integer(SCHEMA, 'entry_order', raw_get(value, 'entry_order'), 1, 1000),
        validation_content_id(SCHEMA, 'reward_id', raw_get(value, 'reward_id'), 'reward_'),
        validation_integer(SCHEMA, 'weight', raw_get(value, 'weight'), 0, MAX_WEIGHT, true),
        validation_integer(SCHEMA, 'chance_bp', raw_get(value, 'chance_bp'), 0, MAX_CHANCE_BP, true),
        validation_integer(SCHEMA, 'min_quantity_multiplier', min_mult, 1, 1),
        validation_integer(SCHEMA, 'max_quantity_multiplier', max_mult, 1, 1),
        validation_content_id(
            SCHEMA,
            'condition_set_id',
            raw_get(value, 'condition_set_id'),
            'condset_',
            true
        ),
        validation_non_empty_string(
            SCHEMA,
            'unique_key',
            raw_get(value, 'unique_key'),
            true
        )
    )
    if err ~= nil then
        return err
    end

    local unique_key = raw_get(value, 'unique_key')
    if unique_key ~= nil and #unique_key > 64 then
        return validation_invalid(SCHEMA, 'unique_key', 'UNIQUE_KEY_TOO_LONG', {
            max_bytes = 64,
        })
    end

    return result_ok({
        group_id = raw_get(value, 'group_id'),
        entry_order = raw_get(value, 'entry_order'),
        reward_id = raw_get(value, 'reward_id'),
        weight = raw_get(value, 'weight'),
        chance_bp = raw_get(value, 'chance_bp'),
        min_quantity_multiplier = 1,
        max_quantity_multiplier = 1,
        condition_set_id = raw_get(value, 'condition_set_id'),
        unique_key = unique_key,
    })
end

return LootEntry
