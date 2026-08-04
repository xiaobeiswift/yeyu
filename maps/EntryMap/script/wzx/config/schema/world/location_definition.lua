local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.world.validation'

local LocationDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'LocationDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    area_id = true,
    name_key = true,
    discovery_marker_id = true,
    safe_return_marker_id = true,
    neighbor_location_ids = true,
    map_sort_order = true,
    discoverable = true,
    deprecated = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function LocationDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local discoverable = raw_get(value, 'discoverable')
    if discoverable == nil then
        discoverable = true
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local neighbors = raw_get(value, 'neighbor_location_ids')
    if neighbors == nil then
        neighbors = {}
    end
    local map_sort_order = raw_get(value, 'map_sort_order')
    if map_sort_order == nil then
        map_sort_order = 0
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'location_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_content_id(SCHEMA, 'area_id', value.area_id, 'area_'),
        validation_non_empty_string(SCHEMA, 'name_key', value.name_key),
        validation_content_id(
            SCHEMA,
            'discovery_marker_id',
            value.discovery_marker_id,
            'marker_',
            true
        ),
        validation_content_id(
            SCHEMA,
            'safe_return_marker_id',
            value.safe_return_marker_id,
            'marker_',
            true
        ),
        validation_dense_array(SCHEMA, 'neighbor_location_ids', neighbors),
        validation_integer(SCHEMA, 'map_sort_order', map_sort_order, 0, 1000000),
        validation_boolean(SCHEMA, 'discoverable', discoverable),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    local index
    local seen = {}
    for index = 1, #neighbors do
        local neighbor_id = neighbors[index]
        err = validation_content_id(SCHEMA, 'neighbor_location_ids', neighbor_id, 'location_')
        if err ~= nil then
            return err
        end
        if neighbor_id == value.id then
            return validation_invalid(SCHEMA, 'neighbor_location_ids', 'SELF_NEIGHBOR')
        end
        if seen[neighbor_id] then
            return validation_invalid(SCHEMA, 'neighbor_location_ids', 'DUPLICATE_NEIGHBOR', {
                neighbor_id = neighbor_id,
            })
        end
        seen[neighbor_id] = true
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        area_id = value.area_id,
        name_key = value.name_key,
        discovery_marker_id = value.discovery_marker_id,
        safe_return_marker_id = value.safe_return_marker_id,
        neighbor_location_ids = copy_strings(neighbors),
        map_sort_order = map_sort_order,
        discoverable = discoverable,
        deprecated = deprecated,
    })
end

return LocationDefinition
