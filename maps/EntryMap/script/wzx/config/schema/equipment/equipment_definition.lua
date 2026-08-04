local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.equipment.validation'

local EquipmentDefinition = {}
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
local validation_sorted_unique_strings = Validation.sorted_unique_strings

local SCHEMA = 'EquipmentDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    item_id = true,
    slot = true,
    weapon_route = true,
    weapon_kind = true,
    rarity = true,
    required_character_level = true,
    allowed_character_tags = true,
    base_stat_set_id = true,
    affix_pool_id = true,
    affix_count_min = true,
    affix_count_max = true,
    enhancement_track_id = true,
    temper_rule_id = true,
    appearance_id = true,
    salvage_reward_id = true,
    trade_policy = true,
    deprecated = true,
}
local SLOTS = {
    WEAPON = true,
    HEAD = true,
    BODY = true,
    ACCESSORY = true,
}
local WEAPON_ROUTES = {
    UNARMED = true,
    SWORD = true,
    BLADE = true,
    STAFF = true,
    NONE = true,
}
local WEAPON_KINDS = {
    FIST_WEAPON = true,
    SWORD_WEAPON = true,
    BLADE_WEAPON = true,
    STAFF_WEAPON = true,
    NONE = true,
}
local RARITIES = {
    COMMON = true,
    FINE = true,
    RARE = true,
    EPIC = true,
    LEGEND = true,
}
local TRADE_POLICIES = {
    BOUND = true,
}
local KIND_TO_ROUTE = {
    FIST_WEAPON = 'UNARMED',
    SWORD_WEAPON = 'SWORD',
    BLADE_WEAPON = 'BLADE',
    STAFF_WEAPON = 'STAFF',
    NONE = 'NONE',
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function EquipmentDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local allowed_character_tags = raw_get(value, 'allowed_character_tags')
    if allowed_character_tags == nil then
        allowed_character_tags = {}
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local trade_policy = raw_get(value, 'trade_policy')
    if trade_policy == nil then
        trade_policy = 'BOUND'
    end
    local affix_count_min = raw_get(value, 'affix_count_min')
    if affix_count_min == nil then
        affix_count_min = 0
    end
    local affix_count_max = raw_get(value, 'affix_count_max')
    if affix_count_max == nil then
        affix_count_max = 0
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'equip_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_content_id(SCHEMA, 'item_id', raw_get(value, 'item_id'), 'item_'),
        validation_enum(SCHEMA, 'slot', raw_get(value, 'slot'), SLOTS),
        validation_enum(SCHEMA, 'weapon_route', raw_get(value, 'weapon_route'), WEAPON_ROUTES),
        validation_enum(SCHEMA, 'weapon_kind', raw_get(value, 'weapon_kind'), WEAPON_KINDS),
        validation_enum(SCHEMA, 'rarity', raw_get(value, 'rarity'), RARITIES),
        validation_integer(
            SCHEMA,
            'required_character_level',
            raw_get(value, 'required_character_level'),
            1,
            100
        ),
        validation_dense_array(SCHEMA, 'allowed_character_tags', allowed_character_tags),
        validation_sorted_unique_strings(SCHEMA, 'allowed_character_tags', allowed_character_tags),
        validation_content_id(SCHEMA, 'base_stat_set_id', raw_get(value, 'base_stat_set_id'), 'equipstat_'),
        validation_content_id(
            SCHEMA,
            'affix_pool_id',
            raw_get(value, 'affix_pool_id'),
            'affixpool_',
            true
        ),
        validation_integer(SCHEMA, 'affix_count_min', affix_count_min, 0, 6),
        validation_integer(SCHEMA, 'affix_count_max', affix_count_max, 0, 6),
        validation_content_id(
            SCHEMA,
            'enhancement_track_id',
            raw_get(value, 'enhancement_track_id'),
            'enhance_'
        ),
        validation_content_id(
            SCHEMA,
            'temper_rule_id',
            raw_get(value, 'temper_rule_id'),
            'temper_',
            true
        ),
        validation_content_id(SCHEMA, 'appearance_id', raw_get(value, 'appearance_id'), 'appearance_'),
        validation_content_id(
            SCHEMA,
            'salvage_reward_id',
            raw_get(value, 'salvage_reward_id'),
            'reward_',
            true
        ),
        validation_enum(SCHEMA, 'trade_policy', trade_policy, TRADE_POLICIES),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    local slot = value.slot
    local weapon_route = value.weapon_route
    local weapon_kind = value.weapon_kind

    if slot == 'WEAPON' then
        if weapon_route == 'NONE' then
            return validation_invalid(SCHEMA, 'weapon_route', 'WEAPON_ROUTE_REQUIRED')
        end
        if weapon_kind == 'NONE' then
            return validation_invalid(SCHEMA, 'weapon_kind', 'WEAPON_KIND_REQUIRED')
        end
    else
        if weapon_route ~= 'NONE' then
            return validation_invalid(SCHEMA, 'weapon_route', 'NON_WEAPON_ROUTE_MUST_BE_NONE')
        end
        if weapon_kind ~= 'NONE' then
            return validation_invalid(SCHEMA, 'weapon_kind', 'NON_WEAPON_KIND_MUST_BE_NONE')
        end
    end

    if KIND_TO_ROUTE[weapon_kind] ~= weapon_route then
        return validation_invalid(SCHEMA, 'weapon_kind', 'WEAPON_KIND_ROUTE_MISMATCH', {
            weapon_kind = weapon_kind,
            weapon_route = weapon_route,
            expected_route = KIND_TO_ROUTE[weapon_kind],
        })
    end

    if affix_count_min > affix_count_max then
        return validation_invalid(SCHEMA, 'affix_count_min', 'AFFIX_COUNT_RANGE_INVALID')
    end
    if affix_count_max > 0 and value.affix_pool_id == nil then
        return validation_invalid(SCHEMA, 'affix_pool_id', 'AFFIX_POOL_REQUIRED_WHEN_COUNT_POSITIVE')
    end
    if affix_count_max == 0 and value.affix_pool_id ~= nil then
        return validation_invalid(SCHEMA, 'affix_pool_id', 'AFFIX_POOL_FORBIDDEN_WHEN_COUNT_ZERO')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        item_id = value.item_id,
        slot = slot,
        weapon_route = weapon_route,
        weapon_kind = weapon_kind,
        rarity = value.rarity,
        required_character_level = value.required_character_level,
        allowed_character_tags = copy_strings(allowed_character_tags),
        base_stat_set_id = value.base_stat_set_id,
        affix_pool_id = value.affix_pool_id,
        affix_count_min = affix_count_min,
        affix_count_max = affix_count_max,
        enhancement_track_id = value.enhancement_track_id,
        temper_rule_id = value.temper_rule_id,
        appearance_id = value.appearance_id,
        salvage_reward_id = value.salvage_reward_id,
        trade_policy = trade_policy,
        deprecated = deprecated,
    })
end

return EquipmentDefinition
