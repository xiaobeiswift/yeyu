local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.traversal.validation'

local LinkDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_content_id = Validation.content_id
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'TraversalLinkDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    grid_id = true,
    from_cell_id = true,
    to_cell_id = true,
    link_type = true,
    horizontal_cost = true,
    rise_levels = true,
    drop_levels = true,
    source_type = true,
    water_zone_id = true,
}
local LINK_TYPES = {
    JUMP_DIRECT = true,
    WATER_ENTER = true,
    WATER_STEP = true,
    WATER_EXIT = true,
    BLOCK = true,
}
local SOURCE_TYPES = {
    BAKED = true,
    MANUAL_OVERRIDE = true,
}

function LinkDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local rise = raw_get(value, 'rise_levels')
    if rise == nil then
        rise = 0
    end
    local drop = raw_get(value, 'drop_levels')
    if drop == nil then
        drop = 0
    end
    local source_type = raw_get(value, 'source_type')
    if source_type == nil then
        source_type = 'BAKED'
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'traversal_link_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_content_id(SCHEMA, 'grid_id', value.grid_id, 'traversal_grid_'),
        validation_content_id(SCHEMA, 'from_cell_id', value.from_cell_id, 'traversal_cell_'),
        validation_content_id(SCHEMA, 'to_cell_id', value.to_cell_id, 'traversal_cell_'),
        validation_enum(SCHEMA, 'link_type', value.link_type, LINK_TYPES),
        validation_integer(SCHEMA, 'horizontal_cost', value.horizontal_cost, 0, 100000),
        validation_integer(SCHEMA, 'rise_levels', rise, 0, 64),
        validation_integer(SCHEMA, 'drop_levels', drop, 0, 64),
        validation_enum(SCHEMA, 'source_type', source_type, SOURCE_TYPES),
        validation_content_id(
            SCHEMA,
            'water_zone_id',
            value.water_zone_id,
            'water_zone_',
            true
        )
    )
    if err ~= nil then
        return err
    end

    if value.from_cell_id == value.to_cell_id then
        return validation_invalid(SCHEMA, 'to_cell_id', 'SELF_LINK_FORBIDDEN')
    end
    if value.link_type == 'BLOCK' then
        return result_ok({
            id = value.id,
            schema_version = value.schema_version,
            grid_id = value.grid_id,
            from_cell_id = value.from_cell_id,
            to_cell_id = value.to_cell_id,
            link_type = value.link_type,
            horizontal_cost = value.horizontal_cost,
            rise_levels = rise,
            drop_levels = drop,
            source_type = source_type,
            water_zone_id = value.water_zone_id,
        })
    end
    if value.horizontal_cost < 1 then
        return validation_invalid(SCHEMA, 'horizontal_cost', 'POSITIVE_COST_REQUIRED')
    end
    if (
        value.link_type == 'WATER_ENTER'
        or value.link_type == 'WATER_STEP'
        or value.link_type == 'WATER_EXIT'
    ) and value.water_zone_id == nil then
        return validation_invalid(SCHEMA, 'water_zone_id', 'WATER_ZONE_REQUIRED')
    end
    if value.link_type == 'JUMP_DIRECT' and value.water_zone_id ~= nil then
        return validation_invalid(SCHEMA, 'water_zone_id', 'JUMP_MUST_NOT_REFERENCE_ZONE')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        grid_id = value.grid_id,
        from_cell_id = value.from_cell_id,
        to_cell_id = value.to_cell_id,
        link_type = value.link_type,
        horizontal_cost = value.horizontal_cost,
        rise_levels = rise,
        drop_levels = drop,
        source_type = source_type,
        water_zone_id = value.water_zone_id,
    })
end

return LinkDefinition
