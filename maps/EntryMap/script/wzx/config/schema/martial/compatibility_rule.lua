local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.martial.validation'

local CompatibilityRule = {}
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
local validation_sorted_unique_content_ids = Validation.sorted_unique_content_ids
local validation_sorted_unique_strings = Validation.sorted_unique_strings

local SCHEMA = 'MartialCompatibilityRule'
local FIELDS = {
    id = true,
    schema_version = true,
    minimum_character_level = true,
    required_character_tags = true,
    forbidden_character_tags = true,
    minimum_weapon_aptitude = true,
    exclusive_martial_ids = true,
    exclusive_groups = true,
    required_faction_id = true,
    equip_faction_required = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function CompatibilityRule.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local min_level = raw_get(value, 'minimum_character_level')
    if min_level == nil then
        min_level = 1
    end
    local required_tags = raw_get(value, 'required_character_tags')
    if required_tags == nil then
        required_tags = {}
    end
    local forbidden_tags = raw_get(value, 'forbidden_character_tags')
    if forbidden_tags == nil then
        forbidden_tags = {}
    end
    local min_aptitude = raw_get(value, 'minimum_weapon_aptitude')
    if min_aptitude == nil then
        min_aptitude = 0
    end
    local exclusive_martial_ids = raw_get(value, 'exclusive_martial_ids')
    if exclusive_martial_ids == nil then
        exclusive_martial_ids = {}
    end
    local exclusive_groups = raw_get(value, 'exclusive_groups')
    if exclusive_groups == nil then
        exclusive_groups = {}
    end
    local equip_faction_required = raw_get(value, 'equip_faction_required')
    if equip_faction_required == nil then
        equip_faction_required = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'martial_compat_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_integer(SCHEMA, 'minimum_character_level', min_level, 1, 100),
        validation_dense_array(SCHEMA, 'required_character_tags', required_tags),
        validation_sorted_unique_strings(SCHEMA, 'required_character_tags', required_tags),
        validation_dense_array(SCHEMA, 'forbidden_character_tags', forbidden_tags),
        validation_sorted_unique_strings(SCHEMA, 'forbidden_character_tags', forbidden_tags),
        validation_integer(SCHEMA, 'minimum_weapon_aptitude', min_aptitude, 0, 100),
        validation_dense_array(SCHEMA, 'exclusive_martial_ids', exclusive_martial_ids),
        validation_sorted_unique_content_ids(
            SCHEMA,
            'exclusive_martial_ids',
            exclusive_martial_ids,
            'martial_'
        ),
        validation_dense_array(SCHEMA, 'exclusive_groups', exclusive_groups),
        validation_sorted_unique_strings(SCHEMA, 'exclusive_groups', exclusive_groups),
        validation_content_id(
            SCHEMA,
            'required_faction_id',
            raw_get(value, 'required_faction_id'),
            'faction_',
            true
        ),
        validation_boolean(SCHEMA, 'equip_faction_required', equip_faction_required)
    )
    if err ~= nil then
        return err
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        minimum_character_level = min_level,
        required_character_tags = copy_strings(required_tags),
        forbidden_character_tags = copy_strings(forbidden_tags),
        minimum_weapon_aptitude = min_aptitude,
        exclusive_martial_ids = copy_strings(exclusive_martial_ids),
        exclusive_groups = copy_strings(exclusive_groups),
        required_faction_id = value.required_faction_id,
        equip_faction_required = equip_faction_required,
    })
end

return CompatibilityRule
