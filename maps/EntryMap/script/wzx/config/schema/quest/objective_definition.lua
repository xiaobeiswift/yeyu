local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.quest.validation'

local ObjectiveDefinition = {}
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
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'ObjectiveDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    stage_id = true,
    objective_type = true,
    target_id = true,
    target_tag = true,
    required_count = true,
    progress_semantics = true,
    event_type = true,
    optional = true,
    hidden_until_progress = true,
    include_pre_accept = true,
    guide_ref_id = true,
    description_key = true,
    completed_key = true,
    deprecated = true,
}
local OBJECTIVE_TYPES = {
    TALK = true,
    COMPLETE_ENCOUNTER = true,
    DEFEAT_ENEMY = true,
    REACH_LOCATION = true,
    ACQUIRE_ITEM = true,
    OWN_ITEM = true,
    OPEN_CHEST = true,
    SEARCH_POINT = true,
}
local PROGRESS_SEMANTICS = {
    ACCUMULATE_AFTER_ACCEPT = true,
    CURRENT_SNAPSHOT = true,
    DELIVER_AT_TURN_IN = true,
    ONCE_FACT = true,
}
local EVENT_TYPES = {
    EncounterCompleted = true,
    DialogueCompleted = true,
    LocationDiscovered = true,
    ItemGranted = true,
    ChestOpened = true,
    SearchPointResolved = true,
}
local TARGET_PREFIX = {
    COMPLETE_ENCOUNTER = 'encounter_',
    DEFEAT_ENEMY = 'enemy_',
    TALK = 'dialogue_',
    REACH_LOCATION = 'location_',
    ACQUIRE_ITEM = 'item_',
    OWN_ITEM = 'item_',
    OPEN_CHEST = 'interact_',
    SEARCH_POINT = 'interact_',
}

function ObjectiveDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local optional = raw_get(value, 'optional')
    if optional == nil then
        optional = false
    end
    local hidden_until_progress = raw_get(value, 'hidden_until_progress')
    if hidden_until_progress == nil then
        hidden_until_progress = false
    end
    local include_pre_accept = raw_get(value, 'include_pre_accept')
    if include_pre_accept == nil then
        include_pre_accept = false
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local required_count = raw_get(value, 'required_count')
    if required_count == nil then
        required_count = 1
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'objective_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_content_id(SCHEMA, 'stage_id', value.stage_id, 'stage_'),
        validation_enum(SCHEMA, 'objective_type', value.objective_type, OBJECTIVE_TYPES),
        validation_integer(SCHEMA, 'required_count', required_count, 1, 2000000000),
        validation_enum(
            SCHEMA,
            'progress_semantics',
            value.progress_semantics,
            PROGRESS_SEMANTICS
        ),
        validation_boolean(SCHEMA, 'optional', optional),
        validation_boolean(SCHEMA, 'hidden_until_progress', hidden_until_progress),
        validation_boolean(SCHEMA, 'include_pre_accept', include_pre_accept),
        validation_non_empty_string(SCHEMA, 'description_key', value.description_key),
        validation_non_empty_string(SCHEMA, 'completed_key', value.completed_key),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if value.event_type ~= nil then
        err = validation_enum(SCHEMA, 'event_type', value.event_type, EVENT_TYPES)
        if err ~= nil then
            return err
        end
    end
    if value.target_tag ~= nil then
        err = validation_non_empty_string(SCHEMA, 'target_tag', value.target_tag, 64)
        if err ~= nil then
            return err
        end
    end
    if value.guide_ref_id ~= nil then
        err = validation_non_empty_string(SCHEMA, 'guide_ref_id', value.guide_ref_id, 96)
        if err ~= nil then
            return err
        end
    end
    if value.target_id ~= nil then
        local prefix = TARGET_PREFIX[value.objective_type]
        if prefix == nil then
            return validation_invalid(SCHEMA, 'target_id', 'TARGET_PREFIX_UNKNOWN')
        end
        err = validation_content_id(SCHEMA, 'target_id', value.target_id, prefix)
        if err ~= nil then
            return err
        end
    end

    if value.progress_semantics ~= 'CURRENT_SNAPSHOT' and include_pre_accept then
        return validation_invalid(SCHEMA, 'include_pre_accept', 'ONLY_SNAPSHOT_ALLOWS_PRE_ACCEPT')
    end

    if value.objective_type == 'COMPLETE_ENCOUNTER'
        or value.objective_type == 'TALK'
        or value.objective_type == 'REACH_LOCATION'
        or value.objective_type == 'OPEN_CHEST'
        or value.objective_type == 'SEARCH_POINT'
    then
        if value.progress_semantics ~= 'ONCE_FACT'
            and value.progress_semantics ~= 'ACCUMULATE_AFTER_ACCEPT'
        then
            return validation_invalid(
                SCHEMA,
                'progress_semantics',
                'SEMANTICS_MISMATCH_FOR_TYPE'
            )
        end
        if value.event_type == nil then
            return validation_invalid(SCHEMA, 'event_type', 'EVENT_TYPE_REQUIRED')
        end
    end

    if value.objective_type == 'COMPLETE_ENCOUNTER'
        and value.event_type ~= 'EncounterCompleted'
    then
        return validation_invalid(SCHEMA, 'event_type', 'ENCOUNTER_EVENT_REQUIRED')
    end
    if value.objective_type == 'DEFEAT_ENEMY' then
        if value.progress_semantics ~= 'ACCUMULATE_AFTER_ACCEPT' then
            return validation_invalid(
                SCHEMA,
                'progress_semantics',
                'DEFEAT_REQUIRES_ACCUMULATE'
            )
        end
        if value.event_type ~= 'EncounterCompleted' then
            return validation_invalid(SCHEMA, 'event_type', 'ENCOUNTER_EVENT_REQUIRED')
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        stage_id = value.stage_id,
        objective_type = value.objective_type,
        target_id = value.target_id,
        target_tag = value.target_tag,
        required_count = required_count,
        progress_semantics = value.progress_semantics,
        event_type = value.event_type,
        optional = optional,
        hidden_until_progress = hidden_until_progress,
        include_pre_accept = include_pre_accept,
        guide_ref_id = value.guide_ref_id,
        description_key = value.description_key,
        completed_key = value.completed_key,
        deprecated = deprecated,
    })
end

return ObjectiveDefinition
