local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.reward.validation'

local RewardBundle = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local tostring_value = tostring
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'RewardBundle'
local MAX_ENTRIES = 64
local MAX_QUANTITY = 1000000000
local FIELDS = {
    id = true,
    schema_version = true,
    overflow_policy = true,
    entries = true,
    deprecated = true,
}
local ENTRY_FIELDS = {
    entry_order = true,
    entry_type = true,
    target_id = true,
    quantity_min = true,
    quantity_max = true,
    scale_rule_id = true,
    condition_set_id = true,
    first_clear_only = true,
    metadata = true,
}
local OVERFLOW_POLICIES = {
    REJECT = true,
    CLAMP_WITH_COMPENSATION = true,
    PENDING = true,
}
local ENTRY_TYPES = {
    CURRENCY = true,
    ITEM = true,
    EQUIPMENT = true,
    CHARACTER_XP = true,
    MARTIAL_XP = true,
    AFFINITY = true,
    UNLOCK_FLAG = true,
    REWARD_BUNDLE = true,
}
local TARGET_PREFIXES = {
    CURRENCY = 'currency_',
    ITEM = 'item_',
    EQUIPMENT = 'equip_',
    CHARACTER_XP = 'char_',
    MARTIAL_XP = 'martial_',
    AFFINITY = 'char_',
    UNLOCK_FLAG = 'flag_',
    REWARD_BUNDLE = 'reward_',
}
local METADATA_FIELDS = {
    owner_type = true,
}

local function copy_metadata(value)
    if value == nil then
        return nil
    end
    return {
        owner_type = raw_get(value, 'owner_type'),
    }
end

local function copy_entry(value)
    return {
        entry_order = raw_get(value, 'entry_order'),
        entry_type = raw_get(value, 'entry_type'),
        target_id = raw_get(value, 'target_id'),
        quantity_min = raw_get(value, 'quantity_min'),
        quantity_max = raw_get(value, 'quantity_max'),
        scale_rule_id = raw_get(value, 'scale_rule_id'),
        condition_set_id = raw_get(value, 'condition_set_id'),
        first_clear_only = raw_get(value, 'first_clear_only'),
        metadata = copy_metadata(raw_get(value, 'metadata')),
    }
end

local function validate_metadata(entry_type, metadata, path)
    if metadata == nil then
        if entry_type == 'UNLOCK_FLAG' then
            return validation_invalid(
                SCHEMA,
                path .. '.metadata',
                'OWNER_TYPE_REQUIRED'
            )
        end
        return nil
    end
    if type_value(metadata) ~= 'table' or get_metatable(metadata) ~= nil then
        return validation_invalid(SCHEMA, path .. '.metadata', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, metadata, METADATA_FIELDS)
    if err ~= nil then
        local nested_field = err.error.details.field
        if nested_field == '$' then
            nested_field = path .. '.metadata'
        else
            nested_field = path .. '.metadata.' .. nested_field
        end
        return validation_invalid(
            SCHEMA,
            nested_field,
            err.error.details.reason
        )
    end
    if entry_type == 'UNLOCK_FLAG' then
        err = validation_non_empty_string(
            SCHEMA,
            path .. '.metadata.owner_type',
            raw_get(metadata, 'owner_type')
        )
        if err ~= nil then
            return err
        end
    elseif raw_get(metadata, 'owner_type') ~= nil then
        return validation_invalid(
            SCHEMA,
            path .. '.metadata.owner_type',
            'OWNER_TYPE_ONLY_FOR_UNLOCK_FLAG'
        )
    end
    return nil
end

local function validate_entry(entry, index)
    local path = 'entries[' .. tostring_value(index) .. ']'
    if type_value(entry) ~= 'table' or get_metatable(entry) ~= nil then
        return validation_invalid(SCHEMA, path, 'TABLE_REQUIRED')
    end

    local err = validation_no_unknown_fields(SCHEMA, entry, ENTRY_FIELDS)
    if err ~= nil then
        local nested_field = err.error.details.field
        if nested_field == '$' then
            nested_field = path
        else
            nested_field = path .. '.' .. nested_field
        end
        return validation_invalid(
            SCHEMA,
            nested_field,
            err.error.details.reason
        )
    end

    local entry_type = raw_get(entry, 'entry_type')
    local quantity_min = raw_get(entry, 'quantity_min')
    local quantity_max = raw_get(entry, 'quantity_max')
    err = validation_first(
        validation_integer(SCHEMA, path .. '.entry_order', raw_get(entry, 'entry_order'), 1, MAX_ENTRIES),
        validation_enum(SCHEMA, path .. '.entry_type', entry_type, ENTRY_TYPES),
        validation_integer(SCHEMA, path .. '.quantity_min', quantity_min, 1, MAX_QUANTITY),
        validation_integer(SCHEMA, path .. '.quantity_max', quantity_max, 1, MAX_QUANTITY),
        validation_boolean(
            SCHEMA,
            path .. '.first_clear_only',
            raw_get(entry, 'first_clear_only'),
            true
        ),
        validation_content_id(
            SCHEMA,
            path .. '.scale_rule_id',
            raw_get(entry, 'scale_rule_id'),
            'scale_',
            true
        ),
        validation_content_id(
            SCHEMA,
            path .. '.condition_set_id',
            raw_get(entry, 'condition_set_id'),
            'condset_',
            true
        )
    )
    if err ~= nil then
        return err
    end

    if quantity_min > quantity_max then
        return validation_invalid(
            SCHEMA,
            path .. '.quantity_min',
            'QUANTITY_MIN_EXCEEDS_MAX',
            {
                quantity_min = quantity_min,
                quantity_max = quantity_max,
            }
        )
    end

    local prefix = raw_get(TARGET_PREFIXES, entry_type)
    err = validation_content_id(
        SCHEMA,
        path .. '.target_id',
        raw_get(entry, 'target_id'),
        prefix
    )
    if err ~= nil then
        return err
    end

    if entry_type == 'REWARD_BUNDLE' then
        if quantity_min ~= 1 or quantity_max ~= 1 then
            return validation_invalid(
                SCHEMA,
                path .. '.quantity_min',
                'NESTED_BUNDLE_QUANTITY_MUST_BE_ONE',
                {
                    quantity_min = quantity_min,
                    quantity_max = quantity_max,
                }
            )
        end
        if raw_get(entry, 'scale_rule_id') ~= nil then
            return validation_invalid(
                SCHEMA,
                path .. '.scale_rule_id',
                'NESTED_BUNDLE_SCALE_FORBIDDEN'
            )
        end
    end

    err = validate_metadata(entry_type, raw_get(entry, 'metadata'), path)
    if err ~= nil then
        return err
    end
    return nil
end

local function validate_entries(value)
    local err = validation_dense_array(SCHEMA, 'entries', value)
    if err ~= nil then
        return err
    end
    if #value == 0 then
        return validation_invalid(SCHEMA, 'entries', 'ENTRIES_REQUIRED')
    end
    if #value > MAX_ENTRIES then
        return validation_invalid(SCHEMA, 'entries', 'ENTRY_COUNT_LIMIT_EXCEEDED', {
            actual = #value,
            maximum = MAX_ENTRIES,
        })
    end

    local index
    for index = 1, #value do
        local entry = raw_get(value, index)
        err = validate_entry(entry, index)
        if err ~= nil then
            return err
        end
        if raw_get(entry, 'entry_order') ~= index then
            return validation_invalid(
                SCHEMA,
                'entries[' .. tostring_value(index) .. '].entry_order',
                'ENTRY_ORDER_MUST_BE_DENSE',
                {
                    expected = index,
                    actual = raw_get(entry, 'entry_order'),
                }
            )
        end
    end
    return nil
end

function RewardBundle.validate(value)
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'reward_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1, 1),
        validation_enum(
            SCHEMA,
            'overflow_policy',
            value.overflow_policy,
            OVERFLOW_POLICIES,
            true
        ),
        validation_boolean(SCHEMA, 'deprecated', value.deprecated, true)
    )
    if err ~= nil then
        return err
    end

    err = validate_entries(value.entries)
    if err ~= nil then
        return err
    end

    local entries = {}
    local index
    for index = 1, #value.entries do
        local entry = copy_entry(value.entries[index])
        if entry.first_clear_only == nil then
            entry.first_clear_only = false
        end
        entries[index] = entry
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        overflow_policy = value.overflow_policy or 'REJECT',
        entries = entries,
        deprecated = value.deprecated == true,
    })
end

return RewardBundle
