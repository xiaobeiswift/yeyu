local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.world.validation'

local WorldFlagDefinition = {}
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

local SCHEMA = 'WorldFlagDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    value_type = true,
    default_value = true,
    description_key = true,
    deprecated = true,
}
local VALUE_TYPES = {
    BOOLEAN = true,
    INTEGER = true,
    STRING = true,
}

function WorldFlagDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local value_type = raw_get(value, 'value_type')
    if value_type == nil then
        value_type = 'BOOLEAN'
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'flag_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_enum(SCHEMA, 'value_type', value_type, VALUE_TYPES),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    local default_value = raw_get(value, 'default_value')
    if default_value == nil then
        if value_type == 'BOOLEAN' then
            default_value = false
        elseif value_type == 'INTEGER' then
            default_value = 0
        else
            default_value = ''
        end
    end

    if value_type == 'BOOLEAN' then
        if type_value(default_value) ~= 'boolean' then
            return validation_invalid(SCHEMA, 'default_value', 'BOOLEAN_REQUIRED')
        end
    elseif value_type == 'INTEGER' then
        err = validation_integer(SCHEMA, 'default_value', default_value, -1000000, 1000000)
        if err ~= nil then
            return err
        end
    else
        if type_value(default_value) ~= 'string' or #default_value > 64 then
            return validation_invalid(SCHEMA, 'default_value', 'STRING_REQUIRED')
        end
    end

    if value.description_key ~= nil then
        err = Validation.non_empty_string(SCHEMA, 'description_key', value.description_key)
        if err ~= nil then
            return err
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        value_type = value_type,
        default_value = default_value,
        description_key = value.description_key,
        deprecated = deprecated,
    })
end

return WorldFlagDefinition
