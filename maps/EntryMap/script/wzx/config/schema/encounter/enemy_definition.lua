local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.encounter.validation'

local EnemyDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string
local validation_sorted_unique_strings = Validation.sorted_unique_strings

local SCHEMA = 'EnemyDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    enemy_class = true,
    display_name_key = true,
    description_key = true,
    stat_profile_id = true,
    move_set_id = true,
    ai_profile_id = true,
    default_tags = true,
    immunity_profile_id = true,
    loot_table_id = true,
    model_asset_id = true,
    portrait_asset_id = true,
    deprecated = true,
}
local ENEMY_CLASSES = {
    NORMAL = true,
    ELITE = true,
    BOSS = true,
    SUMMON = true,
    MECHANIC_OBJECT = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function EnemyDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local default_tags = raw_get(value, 'default_tags')
    if default_tags == nil then
        default_tags = {}
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'enemy_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_enum(SCHEMA, 'enemy_class', value.enemy_class, ENEMY_CLASSES),
        validation_non_empty_string(SCHEMA, 'display_name_key', value.display_name_key),
        validation_non_empty_string(SCHEMA, 'description_key', value.description_key),
        validation_content_id(SCHEMA, 'stat_profile_id', value.stat_profile_id, 'statprof_'),
        validation_content_id(SCHEMA, 'move_set_id', value.move_set_id, 'moveset_'),
        validation_content_id(SCHEMA, 'ai_profile_id', value.ai_profile_id, 'ai_'),
        validation_sorted_unique_strings(SCHEMA, 'default_tags', default_tags),
        validation_content_id(
            SCHEMA,
            'immunity_profile_id',
            value.immunity_profile_id,
            'immunity_',
            true
        ),
        validation_content_id(SCHEMA, 'loot_table_id', value.loot_table_id, 'loot_', true),
        validation_content_id(SCHEMA, 'model_asset_id', value.model_asset_id, 'asset_'),
        validation_content_id(SCHEMA, 'portrait_asset_id', value.portrait_asset_id, 'asset_'),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end
    if #default_tags > 16 then
        return validation_invalid(SCHEMA, 'default_tags', 'TAG_LIMIT', { maximum = 16 })
    end
    if value.enemy_class == 'SUMMON' and value.loot_table_id ~= nil then
        return validation_invalid(SCHEMA, 'loot_table_id', 'SUMMON_LOOT_FORBIDDEN')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        enemy_class = value.enemy_class,
        display_name_key = value.display_name_key,
        description_key = value.description_key,
        stat_profile_id = value.stat_profile_id,
        move_set_id = value.move_set_id,
        ai_profile_id = value.ai_profile_id,
        default_tags = copy_strings(default_tags),
        immunity_profile_id = value.immunity_profile_id,
        loot_table_id = value.loot_table_id,
        model_asset_id = value.model_asset_id,
        portrait_asset_id = value.portrait_asset_id,
        deprecated = deprecated,
    })
end

EnemyDefinition.ENEMY_CLASSES = ENEMY_CLASSES

return EnemyDefinition
