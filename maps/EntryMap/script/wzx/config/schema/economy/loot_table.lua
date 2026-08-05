local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.economy.validation'

local LootTable = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local tostring_value = tostring
local type_value = type
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'LootTable'
local MAX_GROUP_IDS = 32
local FIELDS = {
    id = true,
    schema_version = true,
    roll_count = true,
    guaranteed_reward_id = true,
    group_ids = true,
    duplicate_policy = true,
    config_version = true,
    deprecated = true,
}
local DUPLICATE_POLICIES = {
    ALLOW = true,
    MERGE = true,
    REROLL_UNIQUE = true,
}

local function copy_group_ids(value)
    local copied = {}
    local index
    for index = 1, #value do
        copied[index] = value[index]
    end
    return copied
end

function LootTable.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end

    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local duplicate_policy = raw_get(value, 'duplicate_policy')
    if duplicate_policy == nil then
        duplicate_policy = 'ALLOW'
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local config_version = raw_get(value, 'config_version')
    if config_version == nil then
        config_version = 1
    end
    local group_ids = raw_get(value, 'group_ids')
    if group_ids == nil then
        group_ids = {}
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'loot_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1, 1),
        validation_integer(SCHEMA, 'roll_count', raw_get(value, 'roll_count'), 0, 100),
        validation_content_id(
            SCHEMA,
            'guaranteed_reward_id',
            raw_get(value, 'guaranteed_reward_id'),
            'reward_',
            true
        ),
        validation_dense_array(SCHEMA, 'group_ids', group_ids),
        validation_enum(SCHEMA, 'duplicate_policy', duplicate_policy, DUPLICATE_POLICIES),
        validation_integer(SCHEMA, 'config_version', config_version, 1, 1000)
    )
    if err ~= nil then
        return err
    end

    if #group_ids > MAX_GROUP_IDS then
        return validation_invalid(SCHEMA, 'group_ids', 'GROUP_ID_LIMIT_EXCEEDED', {
            count = #group_ids,
            max = MAX_GROUP_IDS,
        })
    end

    local seen = {}
    local index
    for index = 1, #group_ids do
        local group_id = group_ids[index]
        local path = 'group_ids[' .. tostring_value(index) .. ']'
        err = validation_content_id(SCHEMA, path, group_id, 'lootgroup_')
        if err ~= nil then
            return err
        end
        if seen[group_id] then
            return validation_invalid(SCHEMA, path, 'DUPLICATE_GROUP_ID', {
                group_id = group_id,
            })
        end
        seen[group_id] = true
    end

    if type_value(deprecated) ~= 'boolean' then
        return validation_invalid(SCHEMA, 'deprecated', 'BOOLEAN_REQUIRED')
    end

    return result_ok({
        id = raw_get(value, 'id'),
        schema_version = 1,
        roll_count = raw_get(value, 'roll_count'),
        guaranteed_reward_id = raw_get(value, 'guaranteed_reward_id'),
        group_ids = copy_group_ids(group_ids),
        duplicate_policy = duplicate_policy,
        config_version = config_version,
        deprecated = deprecated,
    })
end

return LootTable
