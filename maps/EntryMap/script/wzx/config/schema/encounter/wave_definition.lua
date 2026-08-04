local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.encounter.validation'

local WaveDefinition = {}
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
local validation_sorted_unique_strings = Validation.sorted_unique_strings

local SCHEMA = 'EncounterWaveDefinition'
local SPAWN_SCHEMA = 'SpawnRow'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    wave_index = true,
    spawn_rows = true,
    entry_condition_id = true,
    on_enter_effect_bundle_id = true,
    on_clear_effect_bundle_id = true,
    between_wave_policy = true,
    between_wave_value = true,
    presentation_cue_id = true,
    deprecated = true,
}
local SPAWN_FIELDS = {
    spawn_id = true,
    enemy_id = true,
    level = true,
    position_index = true,
    build_variant_id = true,
    initial_status_ids = true,
    counts_for_victory = true,
    summon_limit_group = true,
    spawn_order = true,
}
local BETWEEN_POLICIES = {
    CONTINUE_STATE = true,
    RESET_QI = true,
    HEAL_PERCENT = true,
    CUSTOM_EFFECT = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

local function validate_spawn_row(row, index)
    local err = validation_no_unknown_fields(SPAWN_SCHEMA, row, SPAWN_FIELDS)
    if err ~= nil then
        return err
    end
    local initial_status_ids = raw_get(row, 'initial_status_ids')
    if initial_status_ids == nil then
        initial_status_ids = {}
    end
    local counts_for_victory = raw_get(row, 'counts_for_victory')
    if counts_for_victory == nil then
        counts_for_victory = true
    end
    err = validation_first(
        validation_content_id(SPAWN_SCHEMA, 'spawn_id', row.spawn_id, 'spawn_'),
        validation_content_id(SPAWN_SCHEMA, 'enemy_id', row.enemy_id, 'enemy_'),
        validation_integer(SPAWN_SCHEMA, 'level', row.level, 1, 100),
        validation_integer(SPAWN_SCHEMA, 'position_index', row.position_index, 0, 8),
        validation_content_id(
            SPAWN_SCHEMA,
            'build_variant_id',
            row.build_variant_id,
            'buildvar_',
            true
        ),
        validation_sorted_unique_strings(SPAWN_SCHEMA, 'initial_status_ids', initial_status_ids),
        validation_boolean(SPAWN_SCHEMA, 'counts_for_victory', counts_for_victory),
        validation_content_id(
            SPAWN_SCHEMA,
            'summon_limit_group',
            row.summon_limit_group,
            'summongrp_',
            true
        ),
        validation_integer(SPAWN_SCHEMA, 'spawn_order', row.spawn_order, 1, 64)
    )
    if err ~= nil then
        return err
    end
    local status_index
    for status_index = 1, #initial_status_ids do
        err = validation_content_id(
            SPAWN_SCHEMA,
            'initial_status_ids',
            initial_status_ids[status_index],
            'status_'
        )
        if err ~= nil then
            return err
        end
    end
    if #initial_status_ids > 8 then
        return validation_invalid(SPAWN_SCHEMA, 'initial_status_ids', 'STATUS_LIMIT', {
            index = index,
            maximum = 8,
        })
    end
    return result_ok({
        spawn_id = row.spawn_id,
        enemy_id = row.enemy_id,
        level = row.level,
        position_index = row.position_index,
        build_variant_id = row.build_variant_id,
        initial_status_ids = copy_strings(initial_status_ids),
        counts_for_victory = counts_for_victory,
        summon_limit_group = row.summon_limit_group,
        spawn_order = row.spawn_order,
    })
end

function WaveDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local between_wave_policy = raw_get(value, 'between_wave_policy')
    if between_wave_policy == nil then
        between_wave_policy = 'CONTINUE_STATE'
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local presentation_cue_id = raw_get(value, 'presentation_cue_id')
    if presentation_cue_id == nil then
        presentation_cue_id = 'cue_wave_default'
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'wave_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_integer(SCHEMA, 'wave_index', value.wave_index, 1, 20),
        validation_dense_array(SCHEMA, 'spawn_rows', value.spawn_rows),
        validation_content_id(
            SCHEMA,
            'entry_condition_id',
            value.entry_condition_id,
            'cond_',
            true
        ),
        validation_content_id(
            SCHEMA,
            'on_enter_effect_bundle_id',
            value.on_enter_effect_bundle_id,
            'effect_',
            true
        ),
        validation_content_id(
            SCHEMA,
            'on_clear_effect_bundle_id',
            value.on_clear_effect_bundle_id,
            'effect_',
            true
        ),
        validation_enum(SCHEMA, 'between_wave_policy', between_wave_policy, BETWEEN_POLICIES),
        validation_integer(
            SCHEMA,
            'between_wave_value',
            value.between_wave_value,
            0,
            10000,
            true
        ),
        validation_content_id(SCHEMA, 'presentation_cue_id', presentation_cue_id, 'cue_'),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end
    if #value.spawn_rows < 1 or #value.spawn_rows > 4 then
        return validation_invalid(SCHEMA, 'spawn_rows', 'SPAWN_COUNT_OUT_OF_RANGE', {
            minimum = 1,
            maximum = 4,
        })
    end
    if between_wave_policy == 'HEAL_PERCENT' then
        err = validation_integer(SCHEMA, 'between_wave_value', value.between_wave_value, 0, 10000)
        if err ~= nil then
            return err
        end
    end

    local copied_rows = {}
    local positions = {}
    local spawn_ids = {}
    local victory_count = 0
    local index
    for index = 1, #value.spawn_rows do
        local validated = validate_spawn_row(value.spawn_rows[index], index)
        if not validated.ok then
            return validated
        end
        local row = validated.value
        if positions[row.position_index] then
            return validation_invalid(SCHEMA, 'spawn_rows.position_index', 'DUPLICATE_POSITION', {
                index = index,
                position_index = row.position_index,
            })
        end
        if spawn_ids[row.spawn_id] then
            return validation_invalid(SCHEMA, 'spawn_rows.spawn_id', 'DUPLICATE_SPAWN_ID', {
                index = index,
                spawn_id = row.spawn_id,
            })
        end
        positions[row.position_index] = true
        spawn_ids[row.spawn_id] = true
        if row.counts_for_victory then
            victory_count = victory_count + 1
        end
        copied_rows[index] = row
    end
    if victory_count < 1 then
        return validation_invalid(SCHEMA, 'spawn_rows', 'VICTORY_SPAWN_REQUIRED')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        wave_index = value.wave_index,
        spawn_rows = copied_rows,
        entry_condition_id = value.entry_condition_id,
        on_enter_effect_bundle_id = value.on_enter_effect_bundle_id,
        on_clear_effect_bundle_id = value.on_clear_effect_bundle_id,
        between_wave_policy = between_wave_policy,
        between_wave_value = value.between_wave_value,
        presentation_cue_id = presentation_cue_id,
        deprecated = deprecated,
    })
end

return WaveDefinition
