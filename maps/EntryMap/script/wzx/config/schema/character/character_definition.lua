local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.character.validation'

local CharacterDefinition = {}

local SCHEMA = 'CharacterDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    display_name_key = true,
    description_key = true,
    role = true,
    level_curve_id = true,
    formula_set_id = true,
    base_primary = true,
    growth_per_level_milli = true,
    weapon_aptitudes = true,
    default_talent_ids = true,
    initial_qi = true,
    model_asset_id = true,
    portrait_asset_id = true,
    tags = true,
    deprecated = true,
}
local ROLES = {
    PROTAGONIST = true,
    COMPANION = true,
    ENEMY_TEMPLATE = true,
}
local PRIMARY_KEYS = {
    'strength',
    'constitution',
    'agility',
    'inner_power',
}
local WEAPON_APTITUDE_KEYS = {
    'UNARMED',
    'SWORD',
    'BLADE',
    'STAFF',
}

local function copy_array(value)
    local copy = {}
    local index
    for index = 1, #value do
        copy[index] = value[index]
    end
    return copy
end

local function copy_map(value, keys)
    local copy = {}
    local index
    for index = 1, #keys do
        local key = keys[index]
        copy[key] = value[key]
    end
    return copy
end

function CharacterDefinition.validate(value)
    local err = Validation.no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    err = Validation.first(
        Validation.content_id(SCHEMA, 'id', value.id, 'char_'),
        Validation.integer(SCHEMA, 'schema_version', value.schema_version, 1),
        Validation.non_empty_string(SCHEMA, 'display_name_key', value.display_name_key),
        Validation.non_empty_string(SCHEMA, 'description_key', value.description_key),
        Validation.enum(SCHEMA, 'role', value.role, ROLES),
        Validation.content_id(SCHEMA, 'level_curve_id', value.level_curve_id, 'curve_level_'),
        Validation.content_id(SCHEMA, 'formula_set_id', value.formula_set_id),
        Validation.exact_integer_map(
            SCHEMA,
            'base_primary',
            value.base_primary,
            PRIMARY_KEYS,
            0,
            9999
        ),
        Validation.exact_integer_map(
            SCHEMA,
            'growth_per_level_milli',
            value.growth_per_level_milli,
            PRIMARY_KEYS,
            0,
            100000
        ),
        Validation.exact_integer_map(
            SCHEMA,
            'weapon_aptitudes',
            value.weapon_aptitudes,
            WEAPON_APTITUDE_KEYS,
            0,
            10000
        ),
        Validation.sorted_unique_content_ids(
            SCHEMA,
            'default_talent_ids',
            value.default_talent_ids,
            'talent_',
            true
        ),
        Validation.integer(SCHEMA, 'initial_qi', value.initial_qi, 0, 2000, true),
        Validation.content_id(SCHEMA, 'model_asset_id', value.model_asset_id),
        Validation.content_id(SCHEMA, 'portrait_asset_id', value.portrait_asset_id),
        Validation.sorted_unique_strings(SCHEMA, 'tags', value.tags, true),
        Validation.boolean(SCHEMA, 'deprecated', value.deprecated, true)
    )
    if err ~= nil then
        return err
    end
    return Result.ok({
        id = value.id,
        schema_version = value.schema_version,
        display_name_key = value.display_name_key,
        description_key = value.description_key,
        role = value.role,
        level_curve_id = value.level_curve_id,
        formula_set_id = value.formula_set_id,
        base_primary = copy_map(value.base_primary, PRIMARY_KEYS),
        growth_per_level_milli = copy_map(
            value.growth_per_level_milli,
            PRIMARY_KEYS
        ),
        weapon_aptitudes = copy_map(value.weapon_aptitudes, WEAPON_APTITUDE_KEYS),
        default_talent_ids = copy_array(value.default_talent_ids or {}),
        initial_qi = value.initial_qi or 0,
        model_asset_id = value.model_asset_id,
        portrait_asset_id = value.portrait_asset_id,
        tags = copy_array(value.tags or {}),
        deprecated = value.deprecated == true,
    })
end

return CharacterDefinition
