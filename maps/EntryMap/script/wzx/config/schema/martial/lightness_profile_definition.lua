local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.martial.validation'

local LightnessProfileDefinition = {}
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

local SCHEMA = 'LightnessTraversalProfileDefinition'
local LEVEL_SCHEMA = 'LightnessTraversalLevelRow'
local CAP_SCHEMA = 'TraversalCapabilitySpec'
local FIELDS = {
    id = true,
    schema_version = true,
    source_martial_id = true,
    rules_version = true,
    default_presentation_profile_id = true,
    level_rows = true,
    deprecated = true,
}
local LEVEL_FIELDS = {
    level = true,
    capability_specs = true,
    range_query_radius_cells = true,
    presentation_profile_override_id = true,
}
local CAP_FIELDS = {
    capability_id = true,
    rank = true,
    jump_range_cells = true,
    water_range_cells = true,
    max_rise_levels = true,
    max_drop_levels = true,
    max_route_cost = true,
    movement_speed_bp = true,
}
local CAPABILITY_ORDER = {
    JUMP_BASIC = 1,
    JUMP_LONG = 2,
    JUMP_HIGH = 3,
    WATER_WALK = 4,
}
local CAPABILITIES = {
    JUMP_BASIC = true,
    JUMP_LONG = true,
    JUMP_HIGH = true,
    WATER_WALK = true,
}

local function copy_capability(value)
    return {
        capability_id = value.capability_id,
        rank = value.rank,
        jump_range_cells = value.jump_range_cells,
        water_range_cells = value.water_range_cells,
        max_rise_levels = value.max_rise_levels,
        max_drop_levels = value.max_drop_levels,
        max_route_cost = value.max_route_cost,
        movement_speed_bp = value.movement_speed_bp,
    }
end

local function validate_capability(spec, index, path)
    local err = validation_no_unknown_fields(CAP_SCHEMA, spec, CAP_FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_enum(CAP_SCHEMA, path .. '.capability_id', raw_get(spec, 'capability_id'), CAPABILITIES),
        validation_integer(CAP_SCHEMA, path .. '.rank', raw_get(spec, 'rank'), 1),
        validation_integer(CAP_SCHEMA, path .. '.jump_range_cells', raw_get(spec, 'jump_range_cells'), 0),
        validation_integer(CAP_SCHEMA, path .. '.water_range_cells', raw_get(spec, 'water_range_cells'), 0),
        validation_integer(CAP_SCHEMA, path .. '.max_rise_levels', raw_get(spec, 'max_rise_levels'), 0),
        validation_integer(CAP_SCHEMA, path .. '.max_drop_levels', raw_get(spec, 'max_drop_levels'), 0),
        validation_integer(CAP_SCHEMA, path .. '.max_route_cost', raw_get(spec, 'max_route_cost'), 0),
        validation_integer(
            CAP_SCHEMA,
            path .. '.movement_speed_bp',
            raw_get(spec, 'movement_speed_bp'),
            1,
            100000
        )
    )
    if err ~= nil then
        return err
    end
    local capability_id = spec.capability_id
    if capability_id == 'WATER_WALK' then
        if spec.water_range_cells < 1
            or spec.jump_range_cells ~= 0
            or spec.max_rise_levels ~= 0
            or spec.max_drop_levels ~= 0
            or spec.max_route_cost ~= 0
        then
            return validation_invalid(CAP_SCHEMA, path, 'WATER_WALK_FIELDS_INVALID', {
                index = index,
            })
        end
    elseif spec.jump_range_cells < 1
        or spec.max_route_cost < 1
        or spec.water_range_cells ~= 0
    then
        return validation_invalid(CAP_SCHEMA, path, 'JUMP_FIELDS_INVALID', {
            index = index,
        })
    end
    return nil
end

local function validate_level_row(row, expected_level)
    local path = 'level_rows[' .. tostring(expected_level) .. ']'
    local err = validation_no_unknown_fields(LEVEL_SCHEMA, row, LEVEL_FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_integer(LEVEL_SCHEMA, path .. '.level', raw_get(row, 'level'), 1, 10),
        validation_dense_array(LEVEL_SCHEMA, path .. '.capability_specs', raw_get(row, 'capability_specs')),
        validation_integer(
            LEVEL_SCHEMA,
            path .. '.range_query_radius_cells',
            raw_get(row, 'range_query_radius_cells'),
            0
        ),
        validation_content_id(
            LEVEL_SCHEMA,
            path .. '.presentation_profile_override_id',
            raw_get(row, 'presentation_profile_override_id'),
            'traversal_presentation_',
            true
        )
    )
    if err ~= nil then
        return err
    end
    if row.level ~= expected_level then
        return validation_invalid(LEVEL_SCHEMA, path .. '.level', 'LEVEL_SEQUENCE_INVALID', {
            expected = expected_level,
            actual = row.level,
        })
    end

    local specs = row.capability_specs
    local seen = {}
    local previous_order = 0
    local maximum_query_radius = 0
    local copied_specs = {}
    local index
    for index = 1, #specs do
        local spec = specs[index]
        if type_value(spec) ~= 'table' or get_metatable(spec) ~= nil then
            return validation_invalid(LEVEL_SCHEMA, path .. '.capability_specs', 'TABLE_REQUIRED', {
                index = index,
            })
        end
        err = validate_capability(spec, index, path .. '.capability_specs[' .. tostring(index) .. ']')
        if err ~= nil then
            return err
        end
        local order = CAPABILITY_ORDER[spec.capability_id]
        if seen[spec.capability_id] or order <= previous_order then
            return validation_invalid(LEVEL_SCHEMA, path .. '.capability_specs', 'CAPABILITY_ORDER_INVALID', {
                index = index,
            })
        end
        seen[spec.capability_id] = true
        previous_order = order
        if spec.jump_range_cells > maximum_query_radius then
            maximum_query_radius = spec.jump_range_cells
        end
        if spec.water_range_cells > maximum_query_radius then
            maximum_query_radius = spec.water_range_cells
        end
        copied_specs[index] = copy_capability(spec)
    end
    if (seen.JUMP_LONG or seen.JUMP_HIGH) and not seen.JUMP_BASIC then
        return validation_invalid(
            LEVEL_SCHEMA,
            path .. '.capability_specs',
            'JUMP_BASIC_DEPENDENCY_MISSING'
        )
    end
    if row.range_query_radius_cells < maximum_query_radius then
        return validation_invalid(
            LEVEL_SCHEMA,
            path .. '.range_query_radius_cells',
            'QUERY_RADIUS_TOO_SMALL',
            { minimum = maximum_query_radius }
        )
    end

    return result_ok({
        level = row.level,
        capability_specs = copied_specs,
        range_query_radius_cells = row.range_query_radius_cells,
        presentation_profile_override_id = row.presentation_profile_override_id,
    })
end

function LightnessProfileDefinition.validate(value)
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
    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'traversal_profile_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_content_id(
            SCHEMA,
            'source_martial_id',
            raw_get(value, 'source_martial_id'),
            'martial_'
        ),
        validation_integer(SCHEMA, 'rules_version', raw_get(value, 'rules_version'), 1),
        validation_content_id(
            SCHEMA,
            'default_presentation_profile_id',
            raw_get(value, 'default_presentation_profile_id'),
            'traversal_presentation_'
        ),
        validation_dense_array(SCHEMA, 'level_rows', raw_get(value, 'level_rows')),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end
    if #value.level_rows ~= 10 then
        return validation_invalid(SCHEMA, 'level_rows', 'EXACTLY_TEN_LEVEL_ROWS_REQUIRED', {
            count = #value.level_rows,
        })
    end

    local level_rows = {}
    local index
    for index = 1, 10 do
        local row = value.level_rows[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return validation_invalid(SCHEMA, 'level_rows[' .. tostring(index) .. ']', 'TABLE_REQUIRED')
        end
        local validated = validate_level_row(row, index)
        if not validated.ok then
            return validated
        end
        level_rows[index] = validated.value
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        source_martial_id = value.source_martial_id,
        rules_version = value.rules_version,
        default_presentation_profile_id = value.default_presentation_profile_id,
        level_rows = level_rows,
        deprecated = deprecated,
    })
end

return LightnessProfileDefinition
