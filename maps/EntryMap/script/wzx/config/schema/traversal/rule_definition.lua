local Result = require 'wzx.domain.common.result'
local Ordered = require 'wzx.domain.common.ordered'
local Validation = require 'wzx.config.schema.traversal.validation'

local RuleDefinition = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'TraversalRuleDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    applies_to_link_types = true,
    required_capability_any = true,
    required_capability_all = true,
    distance_budget_policy = true,
    landing_policy = true,
}
local LINK_TYPES = {
    JUMP_DIRECT = true,
    WATER_ENTER = true,
    WATER_STEP = true,
    WATER_EXIT = true,
}
local CAPABILITIES = {
    JUMP_BASIC = true,
    JUMP_LONG = true,
    JUMP_HIGH = true,
    WATER_WALK = true,
}
local DISTANCE_POLICIES = {
    JUMP_DUAL_LIMIT = true,
    WATER_SESSION_COST = true,
}
local LANDING_POLICIES = {
    SAFE_GROUND = true,
    WATER_SESSION = true,
    SHORE_EXIT = true,
}

local function copy_enum_set(values, field, allowed, minimum)
    if values == nil then
        values = {}
    end
    local err = validation_dense_array(SCHEMA, field, values, minimum or 0, 16)
    if err ~= nil then
        return err, nil
    end
    local copied = {}
    local seen = {}
    local index
    for index = 1, #values do
        local item = values[index]
        if type_value(item) ~= 'string' or allowed[item] ~= true then
            return validation_invalid(SCHEMA, field, 'ENUM_INVALID', {
                index = index,
                value = item,
            }), nil
        end
        if seen[item] then
            return validation_invalid(SCHEMA, field, 'DUPLICATE_ENUM', {
                value = item,
            }), nil
        end
        seen[item] = true
        copied[index] = item
    end
    table_sort(copied, bytewise_string_less)
    return nil, copied
end

function RuleDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'traversal_rule_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_enum(
            SCHEMA,
            'distance_budget_policy',
            value.distance_budget_policy,
            DISTANCE_POLICIES
        ),
        validation_enum(SCHEMA, 'landing_policy', value.landing_policy, LANDING_POLICIES)
    )
    if err ~= nil then
        return err
    end

    local link_err, link_types = copy_enum_set(
        value.applies_to_link_types,
        'applies_to_link_types',
        LINK_TYPES,
        1
    )
    if link_err ~= nil then
        return link_err
    end
    local any_err, required_any = copy_enum_set(
        raw_get(value, 'required_capability_any'),
        'required_capability_any',
        CAPABILITIES,
        0
    )
    if any_err ~= nil then
        return any_err
    end
    local all_err, required_all = copy_enum_set(
        raw_get(value, 'required_capability_all'),
        'required_capability_all',
        CAPABILITIES,
        0
    )
    if all_err ~= nil then
        return all_err
    end
    if #required_any == 0 and #required_all == 0 then
        return validation_invalid(SCHEMA, 'required_capability_any', 'CAPABILITY_REQUIRED')
    end
    if value.distance_budget_policy == 'JUMP_DUAL_LIMIT'
        and value.landing_policy ~= 'SAFE_GROUND'
    then
        return validation_invalid(SCHEMA, 'landing_policy', 'JUMP_REQUIRES_SAFE_GROUND')
    end
    if value.distance_budget_policy == 'WATER_SESSION_COST'
        and value.landing_policy == 'SAFE_GROUND'
    then
        return validation_invalid(SCHEMA, 'landing_policy', 'WATER_POLICY_MISMATCH')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        applies_to_link_types = link_types,
        required_capability_any = required_any,
        required_capability_all = required_all,
        distance_budget_policy = value.distance_budget_policy,
        landing_policy = value.landing_policy,
    })
end

return RuleDefinition
