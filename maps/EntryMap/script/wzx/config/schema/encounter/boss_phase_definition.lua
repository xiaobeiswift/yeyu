local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.encounter.validation'

local BossPhaseDefinition = {}
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

local SCHEMA = 'BossPhaseDefinition'
local FLAG_SCHEMA = 'MechanicFlagUpdate'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    phase_index = true,
    trigger = true,
    trigger_value = true,
    trigger_flag_key = true,
    on_enter_effect_bundle_id = true,
    add_move_ids = true,
    remove_move_ids = true,
    ai_profile_override_id = true,
    immunity_profile_override_id = true,
    mechanic_flag_updates = true,
    summon_request_ids = true,
    presentation_cue_id = true,
    persist_once_entered = true,
    deprecated = true,
}
local FLAG_FIELDS = {
    flag_key = true,
    flag_value = true,
}
local TRIGGERS = {
    HP_AT_OR_BELOW_BP = true,
    ACTION_INDEX = true,
    MECHANIC_FLAG = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

local function validate_flag_update(row, index)
    local err = validation_no_unknown_fields(FLAG_SCHEMA, row, FLAG_FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_non_empty_string(FLAG_SCHEMA, 'flag_key', row.flag_key, 64),
        validation_integer(FLAG_SCHEMA, 'flag_value', row.flag_value, 0, 1000000)
    )
    if err ~= nil then
        err.error.details.index = index
        return err
    end
    return nil
end

function BossPhaseDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local add_move_ids = raw_get(value, 'add_move_ids')
    if add_move_ids == nil then
        add_move_ids = {}
    end
    local remove_move_ids = raw_get(value, 'remove_move_ids')
    if remove_move_ids == nil then
        remove_move_ids = {}
    end
    local mechanic_flag_updates = raw_get(value, 'mechanic_flag_updates')
    if mechanic_flag_updates == nil then
        mechanic_flag_updates = {}
    end
    local summon_request_ids = raw_get(value, 'summon_request_ids')
    if summon_request_ids == nil then
        summon_request_ids = {}
    end
    local persist_once_entered = raw_get(value, 'persist_once_entered')
    if persist_once_entered == nil then
        persist_once_entered = true
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'bossphase_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_integer(SCHEMA, 'phase_index', value.phase_index, 1, 32),
        validation_enum(SCHEMA, 'trigger', value.trigger, TRIGGERS),
        validation_integer(SCHEMA, 'trigger_value', value.trigger_value, 0, 10000),
        validation_content_id(
            SCHEMA,
            'on_enter_effect_bundle_id',
            value.on_enter_effect_bundle_id,
            'bundle_',
            true
        ),
        validation_dense_array(SCHEMA, 'add_move_ids', add_move_ids),
        validation_dense_array(SCHEMA, 'remove_move_ids', remove_move_ids),
        validation_content_id(
            SCHEMA,
            'ai_profile_override_id',
            value.ai_profile_override_id,
            'ai_',
            true
        ),
        validation_content_id(
            SCHEMA,
            'immunity_profile_override_id',
            value.immunity_profile_override_id,
            'immunity_',
            true
        ),
        validation_dense_array(SCHEMA, 'mechanic_flag_updates', mechanic_flag_updates),
        validation_dense_array(SCHEMA, 'summon_request_ids', summon_request_ids),
        validation_non_empty_string(SCHEMA, 'presentation_cue_id', value.presentation_cue_id),
        validation_boolean(SCHEMA, 'persist_once_entered', persist_once_entered),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if value.trigger == 'HP_AT_OR_BELOW_BP' then
        err = validation_integer(SCHEMA, 'trigger_value', value.trigger_value, 0, 10000)
        if err ~= nil then
            return err
        end
    elseif value.trigger == 'ACTION_INDEX' then
        err = validation_integer(SCHEMA, 'trigger_value', value.trigger_value, 0, 99)
        if err ~= nil then
            return err
        end
    elseif value.trigger == 'MECHANIC_FLAG' then
        err = validation_non_empty_string(
            SCHEMA,
            'trigger_flag_key',
            value.trigger_flag_key,
            64
        )
        if err ~= nil then
            return err
        end
        err = validation_integer(SCHEMA, 'trigger_value', value.trigger_value, 0, 1000000)
        if err ~= nil then
            return err
        end
    end

    if #add_move_ids > 16 then
        return validation_invalid(SCHEMA, 'add_move_ids', 'MOVE_LIMIT', { maximum = 16 })
    end
    if #remove_move_ids > 16 then
        return validation_invalid(SCHEMA, 'remove_move_ids', 'MOVE_LIMIT', { maximum = 16 })
    end
    if #mechanic_flag_updates > 16 then
        return validation_invalid(SCHEMA, 'mechanic_flag_updates', 'FLAG_LIMIT', {
            maximum = 16,
        })
    end
    if #summon_request_ids > 8 then
        return validation_invalid(SCHEMA, 'summon_request_ids', 'SUMMON_LIMIT', {
            maximum = 8,
        })
    end

    -- Phase 1 is the initial phase: trigger is recorded but already entered at combat start.
    if value.phase_index == 1 and value.trigger ~= 'HP_AT_OR_BELOW_BP' then
        -- Allow any trigger enum for phase 1; runtime treats it as already entered.
    end

    local seen_add = {}
    local index
    for index = 1, #add_move_ids do
        local move_id = add_move_ids[index]
        err = validation_content_id(SCHEMA, 'add_move_ids', move_id, 'move_')
        if err ~= nil then
            return err
        end
        if seen_add[move_id] then
            return validation_invalid(SCHEMA, 'add_move_ids', 'DUPLICATE_MOVE_ID', {
                move_id = move_id,
                index = index,
            })
        end
        seen_add[move_id] = true
    end

    local seen_remove = {}
    for index = 1, #remove_move_ids do
        local move_id = remove_move_ids[index]
        err = validation_content_id(SCHEMA, 'remove_move_ids', move_id, 'move_')
        if err ~= nil then
            return err
        end
        if seen_remove[move_id] then
            return validation_invalid(SCHEMA, 'remove_move_ids', 'DUPLICATE_MOVE_ID', {
                move_id = move_id,
                index = index,
            })
        end
        seen_remove[move_id] = true
    end

    for index = 1, #mechanic_flag_updates do
        err = validate_flag_update(mechanic_flag_updates[index], index)
        if err ~= nil then
            return err
        end
    end

    for index = 1, #summon_request_ids do
        err = validation_content_id(
            SCHEMA,
            'summon_request_ids',
            summon_request_ids[index],
            'summonreq_'
        )
        if err ~= nil then
            return err
        end
    end

    local flag_updates = {}
    for index = 1, #mechanic_flag_updates do
        local row = mechanic_flag_updates[index]
        flag_updates[index] = {
            flag_key = row.flag_key,
            flag_value = row.flag_value,
        }
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        phase_index = value.phase_index,
        trigger = value.trigger,
        trigger_value = value.trigger_value,
        trigger_flag_key = value.trigger_flag_key,
        on_enter_effect_bundle_id = value.on_enter_effect_bundle_id,
        add_move_ids = copy_strings(add_move_ids),
        remove_move_ids = copy_strings(remove_move_ids),
        ai_profile_override_id = value.ai_profile_override_id,
        immunity_profile_override_id = value.immunity_profile_override_id,
        mechanic_flag_updates = flag_updates,
        summon_request_ids = copy_strings(summon_request_ids),
        presentation_cue_id = value.presentation_cue_id,
        persist_once_entered = persist_once_entered,
        deprecated = deprecated,
    })
end

return BossPhaseDefinition
