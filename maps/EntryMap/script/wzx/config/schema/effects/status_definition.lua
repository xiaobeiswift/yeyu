local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.effects.validation'

local StatusDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_copy_string_array = Validation.copy_string_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string
local validation_sorted_unique_strings = Validation.sorted_unique_strings

local SCHEMA = 'StatusDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    name_key = true,
    description_template_key = true,
    polarity = true,
    tags = true,
    stacking_mode = true,
    max_stacks = true,
    max_instances_per_actor = true,
    base_duration = true,
    max_duration = true,
    duration_unit = true,
    refresh_policy = true,
    magnitude_policy = true,
    source_scope = true,
    dispel_category = true,
    dispel_priority = true,
    control_tags = true,
    immunity_tags_required_absent = true,
    absorb_priority = true,
    remove_on_down = true,
    requires_hit_roll = true,
    base_hit_chance_bp = true,
    persist_through_phase = true,
    visibility = true,
    deprecated = true,
}
local POLARITIES = {
    BUFF = true,
    DEBUFF = true,
    NEUTRAL = true,
}
local STACKING_MODES = {
    REPLACE = true,
    REFRESH = true,
    ADD_STACK = true,
    INDEPENDENT = true,
    KEEP_STRONGER = true,
}
local DURATION_UNITS = {
    OWNER_ACTIONS = true,
    GLOBAL_ACTIONS = true,
    SOURCE_ACTIONS = true,
    UNTIL_COMBAT_END = true,
}
local REFRESH_POLICIES = {
    RESET_TO_BASE = true,
    KEEP_LONGER = true,
    ADD_DURATION_CLAMPED = true,
    NO_REFRESH = true,
}
local MAGNITUDE_POLICIES = {
    SNAPSHOT_NEW = true,
    KEEP_OLD = true,
    KEEP_MAX = true,
    ADD_CLAMPED = true,
}
local SOURCE_SCOPES = {
    ANY_SOURCE = true,
    PER_SOURCE_ACTOR = true,
    PER_SOURCE_DEFINITION = true,
}
local DISPEL_CATEGORIES = {
    NONE = true,
    MAGICAL = true,
    PHYSICAL = true,
    ANY = true,
    UNDISPELLABLE = true,
}
local VISIBILITIES = {
    PUBLIC = true,
    HIDDEN = true,
    DEBUG = true,
}
local CONTROL_TAGS = {
    STUN = true,
    SILENCE = true,
    DISARM = true,
    ROOT = true,
    TAUNT = true,
}

local function validate_tag_array(field, value, allowed)
    local err = validation_sorted_unique_strings(SCHEMA, field, value)
    if err ~= nil then
        return err
    end
    if allowed == nil then
        return nil
    end
    local index
    for index = 1, #value do
        local tag = value[index]
        if allowed[tag] ~= true then
            return validation_invalid(SCHEMA, field, 'ENUM_INVALID', {
                index = index,
                value = tag,
            })
        end
    end
    return nil
end

function StatusDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local tags = raw_get(value, 'tags')
    if tags == nil then
        tags = {}
    end
    local control_tags = raw_get(value, 'control_tags')
    if control_tags == nil then
        control_tags = {}
    end
    local immunity_tags = raw_get(value, 'immunity_tags_required_absent')
    if immunity_tags == nil then
        immunity_tags = {}
    end
    local max_stacks = raw_get(value, 'max_stacks')
    if max_stacks == nil then
        max_stacks = 1
    end
    local max_instances = raw_get(value, 'max_instances_per_actor')
    if max_instances == nil then
        max_instances = 1
    end
    local max_duration = raw_get(value, 'max_duration')
    if max_duration == nil then
        max_duration = 999
    end
    local absorb_priority = raw_get(value, 'absorb_priority')
    if absorb_priority == nil then
        absorb_priority = 0
    end
    local remove_on_down = raw_get(value, 'remove_on_down')
    if remove_on_down == nil then
        remove_on_down = true
    end
    local requires_hit_roll = raw_get(value, 'requires_hit_roll')
    if requires_hit_roll == nil then
        requires_hit_roll = false
    end
    local base_hit_chance_bp = raw_get(value, 'base_hit_chance_bp')
    if base_hit_chance_bp == nil then
        base_hit_chance_bp = 10000
    end
    local persist_through_phase = raw_get(value, 'persist_through_phase')
    if persist_through_phase == nil then
        persist_through_phase = false
    end
    local visibility = raw_get(value, 'visibility')
    if visibility == nil then
        visibility = 'PUBLIC'
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local source_scope = raw_get(value, 'source_scope')
    if source_scope == nil then
        source_scope = 'ANY_SOURCE'
    end
    local magnitude_policy = raw_get(value, 'magnitude_policy')
    if magnitude_policy == nil then
        magnitude_policy = 'SNAPSHOT_NEW'
    end
    local dispel_category = raw_get(value, 'dispel_category')
    if dispel_category == nil then
        dispel_category = 'ANY'
    end
    local dispel_priority = raw_get(value, 'dispel_priority')
    if dispel_priority == nil then
        dispel_priority = 0
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'status_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1, 1),
        validation_non_empty_string(SCHEMA, 'name_key', raw_get(value, 'name_key')),
        validation_non_empty_string(
            SCHEMA,
            'description_template_key',
            raw_get(value, 'description_template_key')
        ),
        validation_enum(SCHEMA, 'polarity', raw_get(value, 'polarity'), POLARITIES),
        validation_enum(
            SCHEMA,
            'stacking_mode',
            raw_get(value, 'stacking_mode'),
            STACKING_MODES
        ),
        validation_integer(SCHEMA, 'max_stacks', max_stacks, 1, 99),
        validation_integer(SCHEMA, 'max_instances_per_actor', max_instances, 1, 128),
        validation_integer(SCHEMA, 'base_duration', raw_get(value, 'base_duration'), 0, 999, true),
        validation_integer(SCHEMA, 'max_duration', max_duration, 1, 999),
        validation_enum(
            SCHEMA,
            'duration_unit',
            raw_get(value, 'duration_unit'),
            DURATION_UNITS
        ),
        validation_enum(
            SCHEMA,
            'refresh_policy',
            raw_get(value, 'refresh_policy'),
            REFRESH_POLICIES
        ),
        validation_enum(SCHEMA, 'magnitude_policy', magnitude_policy, MAGNITUDE_POLICIES),
        validation_enum(SCHEMA, 'source_scope', source_scope, SOURCE_SCOPES),
        validation_enum(SCHEMA, 'dispel_category', dispel_category, DISPEL_CATEGORIES),
        validation_integer(SCHEMA, 'dispel_priority', dispel_priority, -1000, 1000),
        validation_integer(SCHEMA, 'absorb_priority', absorb_priority, -1000, 1000),
        validation_boolean(SCHEMA, 'remove_on_down', remove_on_down),
        validation_boolean(SCHEMA, 'requires_hit_roll', requires_hit_roll),
        validation_integer(SCHEMA, 'base_hit_chance_bp', base_hit_chance_bp, 0, 10000),
        validation_boolean(SCHEMA, 'persist_through_phase', persist_through_phase),
        validation_enum(SCHEMA, 'visibility', visibility, VISIBILITIES),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    err = validate_tag_array('tags', tags, nil)
    if err ~= nil then
        return err
    end
    err = validate_tag_array('control_tags', control_tags, CONTROL_TAGS)
    if err ~= nil then
        return err
    end
    err = validate_tag_array('immunity_tags_required_absent', immunity_tags, nil)
    if err ~= nil then
        return err
    end

    local stacking_mode = raw_get(value, 'stacking_mode')
    local duration_unit = raw_get(value, 'duration_unit')
    local base_duration = raw_get(value, 'base_duration')
    if duration_unit == 'UNTIL_COMBAT_END' then
        if base_duration ~= nil then
            return validation_invalid(
                SCHEMA,
                'base_duration',
                'DURATION_MUST_BE_ABSENT_FOR_UNTIL_COMBAT_END'
            )
        end
    else
        if base_duration == nil then
            return validation_invalid(
                SCHEMA,
                'base_duration',
                'DURATION_REQUIRED_FOR_UNIT'
            )
        end
        if base_duration > max_duration then
            return validation_invalid(
                SCHEMA,
                'base_duration',
                'BASE_DURATION_EXCEEDS_MAX'
            )
        end
    end

    if stacking_mode == 'INDEPENDENT' and max_instances < 1 then
        return validation_invalid(
            SCHEMA,
            'max_instances_per_actor',
            'INDEPENDENT_REQUIRES_INSTANCE_CAP'
        )
    end
    if stacking_mode ~= 'INDEPENDENT' and max_instances ~= 1 then
        return validation_invalid(
            SCHEMA,
            'max_instances_per_actor',
            'NON_INDEPENDENT_MUST_HAVE_ONE_INSTANCE_CAP'
        )
    end
    if stacking_mode == 'REFRESH' and max_stacks ~= 1 then
        return validation_invalid(
            SCHEMA,
            'max_stacks',
            'REFRESH_MODE_REQUIRES_MAX_STACKS_ONE'
        )
    end
    if stacking_mode == 'ADD_STACK' and max_stacks < 2 then
        return validation_invalid(
            SCHEMA,
            'max_stacks',
            'ADD_STACK_REQUIRES_MAX_STACKS_AT_LEAST_TWO'
        )
    end

    local has_shield = false
    local tag_index
    for tag_index = 1, #tags do
        if tags[tag_index] == 'SHIELD' then
            has_shield = true
            break
        end
        if tags[tag_index] == 'UNDISPELLABLE' and dispel_category ~= 'UNDISPELLABLE' then
            return validation_invalid(
                SCHEMA,
                'dispel_category',
                'UNDISPELLABLE_TAG_REQUIRES_CATEGORY'
            )
        end
    end
    if has_shield and stacking_mode == 'INDEPENDENT' and max_instances > 8 then
        return validation_invalid(
            SCHEMA,
            'max_instances_per_actor',
            'SHIELD_INSTANCE_CAP_TOO_HIGH'
        )
    end

    return result_ok({
        id = raw_get(value, 'id'),
        schema_version = 1,
        name_key = raw_get(value, 'name_key'),
        description_template_key = raw_get(value, 'description_template_key'),
        polarity = raw_get(value, 'polarity'),
        tags = validation_copy_string_array(tags),
        stacking_mode = stacking_mode,
        max_stacks = max_stacks,
        max_instances_per_actor = max_instances,
        base_duration = base_duration,
        max_duration = max_duration,
        duration_unit = duration_unit,
        refresh_policy = raw_get(value, 'refresh_policy'),
        magnitude_policy = magnitude_policy,
        source_scope = source_scope,
        dispel_category = dispel_category,
        dispel_priority = dispel_priority,
        control_tags = validation_copy_string_array(control_tags),
        immunity_tags_required_absent = validation_copy_string_array(immunity_tags),
        absorb_priority = absorb_priority,
        remove_on_down = remove_on_down,
        requires_hit_roll = requires_hit_roll,
        base_hit_chance_bp = base_hit_chance_bp,
        persist_through_phase = persist_through_phase,
        visibility = visibility,
        deprecated = deprecated,
    })
end

return StatusDefinition
