local Result = require 'wzx.domain.common.result'
local Ordered = require 'wzx.domain.common.ordered'
local Validation = require 'wzx.config.schema.traversal.validation'

local WaterZoneDefinition = {}
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

local SCHEMA = 'WaterSurfaceZoneDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    grid_id = true,
    cell_ids = true,
    entry_link_ids = true,
    exit_link_ids = true,
    safe_shore_marker_ids = true,
    route_role = true,
    availability_flag_id = true,
}
local ROUTE_ROLES = {
    MAIN_OPTIONAL = true,
    SIDE_ROUTE = true,
    HIDDEN_ROUTE = true,
    TUTORIAL = true,
}

local function copy_sorted_unique(ids, field)
    local err = validation_dense_array(SCHEMA, field, ids, 1, 256)
    if err ~= nil then
        return err, nil
    end
    local copied = {}
    local seen = {}
    local index
    for index = 1, #ids do
        local id = ids[index]
        if type_value(id) ~= 'string' then
            return validation_invalid(SCHEMA, field, 'STRING_ID_REQUIRED', {
                index = index,
            }), nil
        end
        if seen[id] then
            return validation_invalid(SCHEMA, field, 'DUPLICATE_ID', {
                id = id,
            }), nil
        end
        seen[id] = true
        copied[index] = id
    end
    table_sort(copied, bytewise_string_less)
    return nil, copied
end

function WaterZoneDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local route_role = raw_get(value, 'route_role')
    if route_role == nil then
        route_role = 'SIDE_ROUTE'
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'water_zone_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_content_id(SCHEMA, 'grid_id', value.grid_id, 'traversal_grid_'),
        validation_enum(SCHEMA, 'route_role', route_role, ROUTE_ROLES),
        validation_content_id(
            SCHEMA,
            'availability_flag_id',
            value.availability_flag_id,
            'flag_',
            true
        )
    )
    if err ~= nil then
        return err
    end

    local cell_err, cell_ids = copy_sorted_unique(value.cell_ids, 'cell_ids')
    if cell_err ~= nil then
        return cell_err
    end
    local entry_err, entry_link_ids = copy_sorted_unique(value.entry_link_ids, 'entry_link_ids')
    if entry_err ~= nil then
        return entry_err
    end
    local exit_err, exit_link_ids = copy_sorted_unique(value.exit_link_ids, 'exit_link_ids')
    if exit_err ~= nil then
        return exit_err
    end
    local shore_err, safe_shore_marker_ids = copy_sorted_unique(
        value.safe_shore_marker_ids,
        'safe_shore_marker_ids'
    )
    if shore_err ~= nil then
        return shore_err
    end

    local index
    for index = 1, #cell_ids do
        err = validation_content_id(SCHEMA, 'cell_ids', cell_ids[index], 'traversal_cell_')
        if err ~= nil then
            return err
        end
    end
    for index = 1, #entry_link_ids do
        err = validation_content_id(
            SCHEMA,
            'entry_link_ids',
            entry_link_ids[index],
            'traversal_link_'
        )
        if err ~= nil then
            return err
        end
    end
    for index = 1, #exit_link_ids do
        err = validation_content_id(
            SCHEMA,
            'exit_link_ids',
            exit_link_ids[index],
            'traversal_link_'
        )
        if err ~= nil then
            return err
        end
    end
    for index = 1, #safe_shore_marker_ids do
        err = validation_content_id(
            SCHEMA,
            'safe_shore_marker_ids',
            safe_shore_marker_ids[index],
            'marker_'
        )
        if err ~= nil then
            return err
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        grid_id = value.grid_id,
        cell_ids = cell_ids,
        entry_link_ids = entry_link_ids,
        exit_link_ids = exit_link_ids,
        safe_shore_marker_ids = safe_shore_marker_ids,
        route_role = route_role,
        availability_flag_id = value.availability_flag_id,
    })
end

return WaterZoneDefinition
