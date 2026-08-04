local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local LightnessTraversalProfile = require 'wzx.domain.contracts.lightness_traversal_profile'
local MartialAggregate = require 'wzx.domain.martial.martial_aggregate'
local MartialErrorCodes = require 'wzx.domain.martial.error_codes'

local LightnessProfileDeriver = {}
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_content = RuntimeId.validate_content

local GROUND_PRESENTATION = 'traversal_presentation_ground'
local PROFILE_HASH_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'source_martial_id', type = 'STRING' },
    { name = 'source_martial_level', type = 'INTEGER' },
    { name = 'rules_version', type = 'INTEGER' },
    { name = 'presentation_profile_id', type = 'STRING' },
    { name = 'range_query_radius_cells', type = 'INTEGER' },
    { name = 'capabilities_digest', type = 'STRING' },
}
local CAPABILITY_HASH_FIELDS = {
    { name = 'capability_id', type = 'STRING' },
    { name = 'rank', type = 'INTEGER' },
    { name = 'jump_range_cells', type = 'INTEGER' },
    { name = 'water_range_cells', type = 'INTEGER' },
    { name = 'max_rise_levels', type = 'INTEGER' },
    { name = 'max_drop_levels', type = 'INTEGER' },
    { name = 'max_route_cost', type = 'INTEGER' },
    { name = 'movement_speed_bp', type = 'INTEGER' },
    { name = 'previous_digest', type = 'STRING' },
}
local ZERO_DIGEST = string.rep('0', 64)

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.martial.' .. string.lower(code),
        false,
        details
    )
end

local function copy_capability(spec)
    return {
        capability_id = spec.capability_id,
        rank = spec.rank,
        jump_range_cells = spec.jump_range_cells,
        water_range_cells = spec.water_range_cells,
        max_rise_levels = spec.max_rise_levels,
        max_drop_levels = spec.max_drop_levels,
        max_route_cost = spec.max_route_cost,
        movement_speed_bp = spec.movement_speed_bp,
    }
end

local function capabilities_digest(specs)
    local previous = ZERO_DIGEST
    local index
    for index = 1, #specs do
        local spec = specs[index]
        local derived = CanonicalReceiptHashV1.derive(
            'lightness_capability',
            CAPABILITY_HASH_FIELDS,
            {
                capability_id = spec.capability_id,
                rank = spec.rank,
                jump_range_cells = spec.jump_range_cells,
                water_range_cells = spec.water_range_cells,
                max_rise_levels = spec.max_rise_levels,
                max_drop_levels = spec.max_drop_levels,
                max_route_cost = spec.max_route_cost,
                movement_speed_bp = spec.movement_speed_bp,
                previous_digest = previous,
            }
        )
        if not derived.ok then
            return derived
        end
        previous = derived.value.digest
    end
    return result_ok(previous)
end

-- catalog_lookup(martial_id) -> definition or nil
-- profile_lookup(profile_id) -> lightness profile definition or nil
function LightnessProfileDeriver.derive(
    state,
    world_protagonist_id,
    requested_character_id,
    catalog_lookup,
    profile_lookup,
    expected_revisions
)
    local checked_protagonist = validate_content(
        world_protagonist_id,
        'char_',
        'world_protagonist_id'
    )
    if not checked_protagonist.ok then
        return fail(
            MartialErrorCodes.MARTIAL_ARGUMENT_INVALID,
            'WORLD_PROTAGONIST_ID_INVALID',
            { field = 'world_protagonist_id' }
        )
    end
    if requested_character_id ~= nil
        and requested_character_id ~= world_protagonist_id
    then
        return fail(
            MartialErrorCodes.MARTIAL_TRAVERSAL_PROTAGONIST_REQUIRED,
            'PROTAGONIST_REQUIRED',
            {
                world_protagonist_id = world_protagonist_id,
                requested_character_id = requested_character_id,
            }
        )
    end
    if type_value(catalog_lookup) ~= 'function'
        or type_value(profile_lookup) ~= 'function'
    then
        return fail(
            MartialErrorCodes.MARTIAL_ARGUMENT_INVALID,
            'LOOKUP_FUNCTIONS_REQUIRED'
        )
    end

    local loadout = MartialAggregate.get_loadout(state, world_protagonist_id)
    if not loadout.ok then
        return loadout
    end
    local loadout_revision = loadout.value.revision
    local lightness_id = loadout.value.lightness_martial_id
    local progress_revision = 0
    local source_level = 0
    local capability_specs = {}
    local range_query_radius_cells = 0
    local presentation_profile_id = GROUND_PRESENTATION
    local rules_version = 1
    local source_martial_id = nil

    if lightness_id ~= nil then
        local progress = MartialAggregate.get_progress(
            state,
            world_protagonist_id,
            lightness_id
        )
        if not progress.ok then
            return progress
        end
        if progress.value == nil then
            return fail(
                MartialErrorCodes.MARTIAL_TRAVERSAL_PROFILE_BROKEN,
                'EQUIPPED_LIGHTNESS_NOT_LEARNED',
                {
                    character_id = world_protagonist_id,
                    martial_id = lightness_id,
                }
            )
        end
        progress_revision = progress.value.revision
        source_level = progress.value.level
        source_martial_id = lightness_id

        local martial = catalog_lookup(lightness_id)
        if martial == nil or martial.category ~= 'LIGHTNESS' then
            return fail(
                MartialErrorCodes.MARTIAL_TRAVERSAL_PROFILE_BROKEN,
                'LIGHTNESS_DEFINITION_MISSING',
                { martial_id = lightness_id }
            )
        end
        if martial.lightness_traversal_profile_id == nil then
            return fail(
                MartialErrorCodes.MARTIAL_TRAVERSAL_PROFILE_BROKEN,
                'LIGHTNESS_PROFILE_ID_MISSING',
                { martial_id = lightness_id }
            )
        end
        local profile_def = profile_lookup(martial.lightness_traversal_profile_id)
        if profile_def == nil then
            return fail(
                MartialErrorCodes.MARTIAL_TRAVERSAL_PROFILE_BROKEN,
                'LIGHTNESS_PROFILE_MISSING',
                {
                    martial_id = lightness_id,
                    profile_id = martial.lightness_traversal_profile_id,
                }
            )
        end
        local level_row = profile_def.level_rows[source_level]
        if level_row == nil then
            return fail(
                MartialErrorCodes.MARTIAL_TRAVERSAL_PROFILE_BROKEN,
                'LIGHTNESS_LEVEL_ROW_MISSING',
                {
                    martial_id = lightness_id,
                    level = source_level,
                }
            )
        end
        rules_version = profile_def.rules_version
        range_query_radius_cells = level_row.range_query_radius_cells
        presentation_profile_id = level_row.presentation_profile_override_id
            or profile_def.default_presentation_profile_id
        local index
        for index = 1, #level_row.capability_specs do
            capability_specs[index] = copy_capability(level_row.capability_specs[index])
        end
    end

    if type_value(expected_revisions) == 'table' then
        if expected_revisions.expected_loadout_revision ~= nil
            and expected_revisions.expected_loadout_revision ~= loadout_revision
        then
            return fail(
                MartialErrorCodes.MARTIAL_SOURCE_REVISION_STALE,
                'LOADOUT_REVISION_STALE',
                {
                    expected = expected_revisions.expected_loadout_revision,
                    actual = loadout_revision,
                }
            )
        end
        if expected_revisions.expected_progress_revision ~= nil
            and expected_revisions.expected_progress_revision ~= progress_revision
        then
            return fail(
                MartialErrorCodes.MARTIAL_SOURCE_REVISION_STALE,
                'PROGRESS_REVISION_STALE',
                {
                    expected = expected_revisions.expected_progress_revision,
                    actual = progress_revision,
                }
            )
        end
    end

    local caps_digest = capabilities_digest(capability_specs)
    if not caps_digest.ok then
        return caps_digest
    end
    local hashed = CanonicalReceiptHashV1.derive(
        'lightness_traversal_profile',
        PROFILE_HASH_FIELDS,
        {
            character_id = world_protagonist_id,
            source_martial_id = source_martial_id or '',
            source_martial_level = source_level,
            rules_version = rules_version,
            presentation_profile_id = presentation_profile_id,
            range_query_radius_cells = range_query_radius_cells,
            capabilities_digest = caps_digest.value,
        }
    )
    if not hashed.ok then
        return hashed
    end

    local profile = {
        character_id = world_protagonist_id,
        source_martial_id = source_martial_id,
        source_martial_level = source_level,
        source_loadout_revision = loadout_revision,
        source_progress_revision = progress_revision,
        rules_version = rules_version,
        capability_specs = capability_specs,
        range_query_radius_cells = range_query_radius_cells,
        presentation_profile_id = presentation_profile_id,
        profile_hash = hashed.value.digest,
    }
    local validated = LightnessTraversalProfile.validate(profile)
    if not validated.ok then
        return fail(
            MartialErrorCodes.MARTIAL_TRAVERSAL_PROFILE_BROKEN,
            'PROFILE_VALIDATION_FAILED',
            {
                cause_code = validated.error and validated.error.code or 'UNKNOWN',
            }
        )
    end
    return result_ok(profile)
end

return LightnessProfileDeriver
