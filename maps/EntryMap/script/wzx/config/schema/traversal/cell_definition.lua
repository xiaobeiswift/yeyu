local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.traversal.validation'

local CellDefinition = {}
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

local SCHEMA = 'TraversalCellDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    grid_id = true,
    x = true,
    y = true,
    layer = true,
    height_level = true,
    surface_type = true,
    blocked = true,
    landing_safety = true,
    safe_marker_id = true,
    reveal_state = true,
    world_anchor_cm_x = true,
    world_anchor_cm_y = true,
    world_anchor_cm_z = true,
}
local SURFACE_TYPES = {
    GROUND = true,
    WATER = true,
    HAZARD = true,
    VOID = true,
}
local LANDING_SAFETY = {
    SAFE_GROUND = true,
    UNSAFE = true,
    NONE = true,
}
local REVEAL_STATES = {
    REVEALED = true,
    HIDDEN = true,
}

function CellDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local blocked = raw_get(value, 'blocked')
    if blocked == nil then
        blocked = false
    end
    local reveal_state = raw_get(value, 'reveal_state')
    if reveal_state == nil then
        reveal_state = 'REVEALED'
    end
    local world_x = raw_get(value, 'world_anchor_cm_x')
    if world_x == nil then
        world_x = 0
    end
    local world_y = raw_get(value, 'world_anchor_cm_y')
    if world_y == nil then
        world_y = 0
    end
    local world_z = raw_get(value, 'world_anchor_cm_z')
    if world_z == nil then
        world_z = 0
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'traversal_cell_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_content_id(SCHEMA, 'grid_id', value.grid_id, 'traversal_grid_'),
        validation_integer(SCHEMA, 'x', value.x, -100000, 100000),
        validation_integer(SCHEMA, 'y', value.y, -100000, 100000),
        validation_integer(SCHEMA, 'layer', value.layer, 0, 64),
        validation_integer(SCHEMA, 'height_level', value.height_level, -64, 64),
        validation_enum(SCHEMA, 'surface_type', value.surface_type, SURFACE_TYPES),
        validation_boolean(SCHEMA, 'blocked', blocked),
        validation_enum(SCHEMA, 'landing_safety', value.landing_safety, LANDING_SAFETY),
        validation_content_id(
            SCHEMA,
            'safe_marker_id',
            value.safe_marker_id,
            'marker_',
            true
        ),
        validation_enum(SCHEMA, 'reveal_state', reveal_state, REVEAL_STATES),
        validation_integer(SCHEMA, 'world_anchor_cm_x', world_x, -100000000, 100000000),
        validation_integer(SCHEMA, 'world_anchor_cm_y', world_y, -100000000, 100000000),
        validation_integer(SCHEMA, 'world_anchor_cm_z', world_z, -100000000, 100000000)
    )
    if err ~= nil then
        return err
    end

    if value.landing_safety == 'SAFE_GROUND' then
        if value.surface_type ~= 'GROUND' then
            return validation_invalid(SCHEMA, 'landing_safety', 'SAFE_GROUND_REQUIRES_GROUND')
        end
        if value.safe_marker_id == nil then
            return validation_invalid(SCHEMA, 'safe_marker_id', 'SAFE_MARKER_REQUIRED')
        end
    end
    if value.surface_type == 'WATER' and value.landing_safety == 'SAFE_GROUND' then
        return validation_invalid(SCHEMA, 'landing_safety', 'WATER_CANNOT_BE_SAFE_GROUND')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        grid_id = value.grid_id,
        x = value.x,
        y = value.y,
        layer = value.layer,
        height_level = value.height_level,
        surface_type = value.surface_type,
        blocked = blocked,
        landing_safety = value.landing_safety,
        safe_marker_id = value.safe_marker_id,
        reveal_state = reveal_state,
        world_anchor_cm_x = world_x,
        world_anchor_cm_y = world_y,
        world_anchor_cm_z = world_z,
    })
end

return CellDefinition
