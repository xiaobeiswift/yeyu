local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.domain.contracts.validation'

local LightnessTraversalProfile = {}

local CONTRACT = 'LightnessTraversalProfileV1'
local PROFILE_FIELDS = {
    character_id = true,
    source_martial_id = true,
    source_martial_level = true,
    source_loadout_revision = true,
    source_progress_revision = true,
    rules_version = true,
    capability_specs = true,
    range_query_radius_cells = true,
    presentation_profile_id = true,
    profile_hash = true,
}
local CAPABILITY_FIELDS = {
    capability_id = true,
    rank = true,
    jump_range_cells = true,
    water_range_cells = true,
    max_rise_levels = true,
    max_drop_levels = true,
    max_route_cost = true,
    movement_speed_bp = true,
}
local ORDER = {
    JUMP_BASIC = 1,
    JUMP_LONG = 2,
    JUMP_HIGH = 3,
    WATER_WALK = 4,
}

local function validate_capability(spec, index)
    local err = Validation.no_unknown_fields(CONTRACT, spec, CAPABILITY_FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.enum(CONTRACT, 'capability_specs.capability_id', spec.capability_id, ORDER),
        Validation.integer(CONTRACT, 'capability_specs.rank', spec.rank, 1),
        Validation.integer(CONTRACT, 'capability_specs.jump_range_cells', spec.jump_range_cells, 0),
        Validation.integer(CONTRACT, 'capability_specs.water_range_cells', spec.water_range_cells, 0),
        Validation.integer(CONTRACT, 'capability_specs.max_rise_levels', spec.max_rise_levels, 0),
        Validation.integer(CONTRACT, 'capability_specs.max_drop_levels', spec.max_drop_levels, 0),
        Validation.integer(CONTRACT, 'capability_specs.max_route_cost', spec.max_route_cost, 0),
        Validation.integer(CONTRACT, 'capability_specs.movement_speed_bp', spec.movement_speed_bp, 1, 100000)
    )
    if err ~= nil then
        err.error.details.index = index
        return err
    end
    if spec.capability_id == 'WATER_WALK' then
        if spec.water_range_cells < 1
            or spec.jump_range_cells ~= 0
            or spec.max_rise_levels ~= 0
            or spec.max_drop_levels ~= 0
            or spec.max_route_cost ~= 0
        then
            return Validation.invalid(CONTRACT, 'capability_specs', 'WATER_WALK_FIELDS_INVALID', {
                index = index,
            })
        end
    elseif spec.jump_range_cells < 1
        or spec.max_route_cost < 1
        or spec.water_range_cells ~= 0
    then
        return Validation.invalid(CONTRACT, 'capability_specs', 'JUMP_FIELDS_INVALID', {
            index = index,
        })
    end
    return nil
end

function LightnessTraversalProfile.validate(value)
    local err = Validation.no_unknown_fields(CONTRACT, value, PROFILE_FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.identifier(CONTRACT, 'character_id', value.character_id, 'char_'),
        Validation.identifier(CONTRACT, 'source_martial_id', value.source_martial_id, 'martial_', true),
        Validation.integer(CONTRACT, 'source_martial_level', value.source_martial_level, 0, 10),
        Validation.integer(CONTRACT, 'source_loadout_revision', value.source_loadout_revision, 0),
        Validation.integer(CONTRACT, 'source_progress_revision', value.source_progress_revision, 0),
        Validation.integer(CONTRACT, 'rules_version', value.rules_version, 1),
        Validation.dense_array(CONTRACT, 'capability_specs', value.capability_specs, 0, 4),
        Validation.integer(CONTRACT, 'range_query_radius_cells', value.range_query_radius_cells, 0),
        Validation.identifier(CONTRACT, 'presentation_profile_id', value.presentation_profile_id, 'traversal_presentation_'),
        Validation.hash(CONTRACT, 'profile_hash', value.profile_hash)
    )
    if err ~= nil then
        return err
    end
    if value.source_martial_id == nil then
        if value.source_martial_level ~= 0 or #value.capability_specs ~= 0 then
            return Validation.invalid(CONTRACT, 'source_martial_id', 'EMPTY_MARTIAL_MUST_HAVE_NO_CAPABILITIES')
        end
    elseif value.source_martial_level < 1 then
        return Validation.invalid(CONTRACT, 'source_martial_level', 'LEARNED_MARTIAL_LEVEL_REQUIRED')
    end

    local seen = {}
    local previous_order = 0
    local maximum_query_radius = 0
    local index
    for index = 1, #value.capability_specs do
        local spec = value.capability_specs[index]
        err = validate_capability(spec, index)
        if err ~= nil then
            return err
        end
        local current_order = ORDER[spec.capability_id]
        if seen[spec.capability_id] or current_order <= previous_order then
            return Validation.invalid(CONTRACT, 'capability_specs', 'CAPABILITY_ORDER_INVALID', {
                index = index,
            })
        end
        seen[spec.capability_id] = true
        previous_order = current_order
        if spec.jump_range_cells > maximum_query_radius then
            maximum_query_radius = spec.jump_range_cells
        end
        if spec.water_range_cells > maximum_query_radius then
            maximum_query_radius = spec.water_range_cells
        end
    end
    if (seen.JUMP_LONG or seen.JUMP_HIGH) and not seen.JUMP_BASIC then
        return Validation.invalid(CONTRACT, 'capability_specs', 'JUMP_BASIC_DEPENDENCY_MISSING')
    end
    if value.range_query_radius_cells < maximum_query_radius then
        return Validation.invalid(CONTRACT, 'range_query_radius_cells', 'QUERY_RADIUS_TOO_SMALL', {
            minimum = maximum_query_radius,
        })
    end
    return Result.ok(value)
end

return LightnessTraversalProfile
