local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.world.validation'

local AreaDefinition = {}
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
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'AreaDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    area_type = true,
    name_key = true,
    location_ids = true,
    entry_marker_id = true,
    is_public_exploration = true,
    deprecated = true,
}
local AREA_TYPES = {
    TOWN = true,
    WILDERNESS = true,
    FACTION = true,
    DUNGEON = true,
    BATTLE = true,
    UTILITY = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function AreaDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local is_public = raw_get(value, 'is_public_exploration')
    if is_public == nil then
        is_public = true
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'area_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_enum(SCHEMA, 'area_type', value.area_type, AREA_TYPES),
        validation_non_empty_string(SCHEMA, 'name_key', value.name_key),
        validation_dense_array(SCHEMA, 'location_ids', value.location_ids),
        validation_content_id(SCHEMA, 'entry_marker_id', value.entry_marker_id, 'marker_', true),
        validation_boolean(SCHEMA, 'is_public_exploration', is_public),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if #value.location_ids < 1 or #value.location_ids > 64 then
        return validation_invalid(SCHEMA, 'location_ids', 'LOCATION_COUNT_OUT_OF_RANGE', {
            count = #value.location_ids,
        })
    end
    local index
    local seen = {}
    for index = 1, #value.location_ids do
        local location_id = value.location_ids[index]
        err = validation_content_id(SCHEMA, 'location_ids', location_id, 'location_')
        if err ~= nil then
            return err
        end
        if seen[location_id] then
            return validation_invalid(SCHEMA, 'location_ids', 'DUPLICATE_LOCATION_ID', {
                location_id = location_id,
            })
        end
        seen[location_id] = true
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        area_type = value.area_type,
        name_key = value.name_key,
        location_ids = copy_strings(value.location_ids),
        entry_marker_id = value.entry_marker_id,
        is_public_exploration = is_public,
        deprecated = deprecated,
    })
end

return AreaDefinition
