local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.economy.validation'

local CurrencyDefinition = {}
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

local SCHEMA = 'CurrencyDefinition'
local MAX_BALANCE_CAP = 2000000000
local FIELDS = {
    id = true,
    schema_version = true,
    category = true,
    balance_cap = true,
    overflow_policy = true,
    display_precision = true,
    source_policy_id = true,
    sink_policy_id = true,
    negative_allowed = true,
    name_key = true,
    icon_id = true,
    deprecated = true,
}
local CATEGORIES = {
    SOFT = true,
    PROGRESSION = true,
    FACTION = true,
    PREMIUM_TEST = true,
    PREMIUM_PLATFORM = true,
}
local OVERFLOW_POLICIES = {
    REJECT = true,
    CLAMP_WITH_COMPENSATION = true,
    PENDING = true,
}

local function copy_definition(value)
    local copied = {
        id = raw_get(value, 'id'),
        schema_version = raw_get(value, 'schema_version'),
        category = raw_get(value, 'category'),
        balance_cap = raw_get(value, 'balance_cap'),
        overflow_policy = raw_get(value, 'overflow_policy'),
        display_precision = raw_get(value, 'display_precision'),
        source_policy_id = raw_get(value, 'source_policy_id'),
        sink_policy_id = raw_get(value, 'sink_policy_id'),
        negative_allowed = raw_get(value, 'negative_allowed'),
        name_key = raw_get(value, 'name_key'),
        deprecated = raw_get(value, 'deprecated'),
    }
    if raw_get(value, 'icon_id') ~= nil then
        copied.icon_id = raw_get(value, 'icon_id')
    end
    return copied
end

function CurrencyDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end

    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local overflow_policy = raw_get(value, 'overflow_policy')
    if overflow_policy == nil then
        overflow_policy = 'REJECT'
    end
    local display_precision = raw_get(value, 'display_precision')
    if display_precision == nil then
        display_precision = 0
    end
    local negative_allowed = raw_get(value, 'negative_allowed')
    if negative_allowed == nil then
        negative_allowed = false
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'currency_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1, 1),
        validation_enum(SCHEMA, 'category', raw_get(value, 'category'), CATEGORIES),
        validation_integer(SCHEMA, 'balance_cap', raw_get(value, 'balance_cap'), 1, MAX_BALANCE_CAP),
        validation_enum(SCHEMA, 'overflow_policy', overflow_policy, OVERFLOW_POLICIES),
        validation_integer(SCHEMA, 'display_precision', display_precision, 0, 0),
        validation_content_id(
            SCHEMA,
            'source_policy_id',
            raw_get(value, 'source_policy_id'),
            'currpolicy_'
        ),
        validation_content_id(
            SCHEMA,
            'sink_policy_id',
            raw_get(value, 'sink_policy_id'),
            'currpolicy_'
        ),
        validation_boolean(SCHEMA, 'negative_allowed', negative_allowed),
        validation_non_empty_string(SCHEMA, 'name_key', raw_get(value, 'name_key')),
        validation_content_id(
            SCHEMA,
            'icon_id',
            raw_get(value, 'icon_id'),
            'icon_',
            true
        ),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if negative_allowed ~= false then
        return validation_invalid(SCHEMA, 'negative_allowed', 'NEGATIVE_NOT_ALLOWED_IN_V1')
    end
    if display_precision ~= 0 then
        return validation_invalid(SCHEMA, 'display_precision', 'DISPLAY_PRECISION_MUST_BE_ZERO')
    end
    -- V1 keeps clamp compensation disabled until a generator proves no overflow loops.
    if overflow_policy == 'CLAMP_WITH_COMPENSATION' then
        return validation_invalid(
            SCHEMA,
            'overflow_policy',
            'CLAMP_WITH_COMPENSATION_DISABLED_IN_V1'
        )
    end

    local normalized = copy_definition(value)
    normalized.overflow_policy = overflow_policy
    normalized.display_precision = display_precision
    normalized.negative_allowed = false
    normalized.deprecated = deprecated
    return result_ok(normalized)
end

return CurrencyDefinition
