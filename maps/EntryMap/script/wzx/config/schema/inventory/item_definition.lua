local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.inventory.validation'

local ItemDefinition = {}
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

local SCHEMA = 'ItemDefinition'
local MAX_STACK = 999999
local MAX_OWNERSHIP_CAP = 2000000000
local FIELDS = {
    id = true,
    schema_version = true,
    category = true,
    name_key = true,
    description_key = true,
    icon_id = true,
    rarity = true,
    max_stack = true,
    capacity_policy = true,
    bind_policy = true,
    discard_policy = true,
    ownership_cap = true,
    sort_group = true,
    sort_order = true,
    deprecated = true,
}
-- EQUIPMENT is owned by system 08 instances; stack inventory rejects it.
local CATEGORIES = {
    CONSUMABLE = true,
    MATERIAL = true,
    QUEST = true,
    TOKEN = true,
    MISC = true,
}
local RARITIES = {
    COMMON = true,
    FINE = true,
    RARE = true,
    EPIC = true,
    LEGEND = true,
}
local CAPACITY_POLICIES = {
    NORMAL = true,
    KEY_ITEM_FREE = true,
}
local DISCARD_POLICIES = {
    DENY = true,
    CONFIRM = true,
    ALLOW = true,
}

local function copy_definition(value)
    local copied = {
        id = raw_get(value, 'id'),
        schema_version = raw_get(value, 'schema_version'),
        category = raw_get(value, 'category'),
        name_key = raw_get(value, 'name_key'),
        rarity = raw_get(value, 'rarity'),
        max_stack = raw_get(value, 'max_stack'),
        capacity_policy = raw_get(value, 'capacity_policy'),
        bind_policy = raw_get(value, 'bind_policy'),
        discard_policy = raw_get(value, 'discard_policy'),
        ownership_cap = raw_get(value, 'ownership_cap'),
        sort_group = raw_get(value, 'sort_group'),
        sort_order = raw_get(value, 'sort_order'),
        deprecated = raw_get(value, 'deprecated'),
    }
    if raw_get(value, 'description_key') ~= nil then
        copied.description_key = raw_get(value, 'description_key')
    end
    if raw_get(value, 'icon_id') ~= nil then
        copied.icon_id = raw_get(value, 'icon_id')
    end
    return copied
end

function ItemDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end

    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local category = raw_get(value, 'category')
    local capacity_policy = raw_get(value, 'capacity_policy')
    if capacity_policy == nil then
        if category == 'QUEST' then
            capacity_policy = 'KEY_ITEM_FREE'
        else
            capacity_policy = 'NORMAL'
        end
    end
    local bind_policy = raw_get(value, 'bind_policy')
    if bind_policy == nil then
        bind_policy = 'ACCOUNT_BOUND'
    end
    local discard_policy = raw_get(value, 'discard_policy')
    if discard_policy == nil then
        if category == 'QUEST' then
            discard_policy = 'DENY'
        else
            discard_policy = 'ALLOW'
        end
    end
    local ownership_cap = raw_get(value, 'ownership_cap')
    if ownership_cap == nil then
        ownership_cap = 999999
    end
    local sort_group = raw_get(value, 'sort_group')
    if sort_group == nil then
        sort_group = 100
    end
    local sort_order = raw_get(value, 'sort_order')
    if sort_order == nil then
        sort_order = 100
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local rarity = raw_get(value, 'rarity')
    if rarity == nil then
        rarity = 'COMMON'
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'item_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1, 1),
        validation_enum(SCHEMA, 'category', category, CATEGORIES),
        validation_non_empty_string(SCHEMA, 'name_key', raw_get(value, 'name_key')),
        validation_enum(SCHEMA, 'rarity', rarity, RARITIES),
        validation_integer(SCHEMA, 'max_stack', raw_get(value, 'max_stack'), 1, MAX_STACK),
        validation_enum(SCHEMA, 'capacity_policy', capacity_policy, CAPACITY_POLICIES),
        validation_enum(SCHEMA, 'discard_policy', discard_policy, DISCARD_POLICIES),
        validation_integer(SCHEMA, 'ownership_cap', ownership_cap, 1, MAX_OWNERSHIP_CAP),
        validation_integer(SCHEMA, 'sort_group', sort_group, 0, 10000),
        validation_integer(SCHEMA, 'sort_order', sort_order, 0, 1000000),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if bind_policy ~= 'ACCOUNT_BOUND' then
        return validation_invalid(SCHEMA, 'bind_policy', 'BIND_POLICY_MUST_BE_ACCOUNT_BOUND')
    end
    if category == 'QUEST' and discard_policy ~= 'DENY' then
        return validation_invalid(SCHEMA, 'discard_policy', 'QUEST_MUST_DENY_DISCARD')
    end
    if category == 'QUEST' and capacity_policy ~= 'KEY_ITEM_FREE' then
        return validation_invalid(
            SCHEMA,
            'capacity_policy',
            'QUEST_MUST_BE_KEY_ITEM_FREE'
        )
    end
    if ownership_cap < raw_get(value, 'max_stack') then
        return validation_invalid(
            SCHEMA,
            'ownership_cap',
            'OWNERSHIP_CAP_BELOW_MAX_STACK'
        )
    end
    if raw_get(value, 'description_key') ~= nil then
        err = validation_non_empty_string(
            SCHEMA,
            'description_key',
            raw_get(value, 'description_key')
        )
        if err ~= nil then
            return err
        end
    end
    if raw_get(value, 'icon_id') ~= nil then
        err = validation_non_empty_string(SCHEMA, 'icon_id', raw_get(value, 'icon_id'))
        if err ~= nil then
            return err
        end
    end

    local normalized = copy_definition(value)
    normalized.capacity_policy = capacity_policy
    normalized.bind_policy = bind_policy
    normalized.discard_policy = discard_policy
    normalized.ownership_cap = ownership_cap
    normalized.sort_group = sort_group
    normalized.sort_order = sort_order
    normalized.deprecated = deprecated
    normalized.rarity = rarity
    return result_ok(normalized)
end

return ItemDefinition
