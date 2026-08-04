local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.encounter.validation'

local EncounterDefinition = {}
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

local SCHEMA = 'EncounterDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    encounter_type = true,
    name_key = true,
    description_key = true,
    area_id = true,
    location_id = true,
    start_interaction_id = true,
    access_rule_id = true,
    party_constraint_id = true,
    wave_ids = true,
    boss_controller_id = true,
    mechanic_ids = true,
    victory_condition_ids = true,
    failure_condition_ids = true,
    environment_spec_id = true,
    seed_policy = true,
    fixed_seed = true,
    retry_policy_id = true,
    first_clear_reward_bundle_id = true,
    repeat_reward_bundle_id = true,
    world_result_set_id = true,
    completion_fact_id = true,
    combat_kind = true,
    action_limit = true,
    event_budget = true,
    deprecated = true,
}
local ENCOUNTER_TYPES = {
    STORY = true,
    NORMAL = true,
    ELITE = true,
    BOSS = true,
    WAVE = true,
    CONDITION = true,
    DUNGEON = true,
    BOUNTY = true,
    TUTORIAL = true,
}
local SEED_POLICIES = {
    FIXED = true,
    DERIVE_FROM_RUN_RECEIPT = true,
    SERVER_GRANTED = true,
}
local COMBAT_KINDS = {
    PVE_STORY = true,
    PVE_ENCOUNTER = true,
    PVE_BOSS = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function EncounterDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local mechanic_ids = raw_get(value, 'mechanic_ids')
    if mechanic_ids == nil then
        mechanic_ids = {}
    end
    local victory_condition_ids = raw_get(value, 'victory_condition_ids')
    if victory_condition_ids == nil then
        victory_condition_ids = { 'cond_side_defeated_defender' }
    end
    local failure_condition_ids = raw_get(value, 'failure_condition_ids')
    if failure_condition_ids == nil then
        failure_condition_ids = { 'cond_side_defeated_attacker', 'cond_action_timeout' }
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local combat_kind = raw_get(value, 'combat_kind')
    if combat_kind == nil then
        if value.encounter_type == 'BOSS' then
            combat_kind = 'PVE_BOSS'
        elseif value.encounter_type == 'STORY' or value.encounter_type == 'TUTORIAL' then
            combat_kind = 'PVE_STORY'
        else
            combat_kind = 'PVE_ENCOUNTER'
        end
    end
    local action_limit = raw_get(value, 'action_limit')
    if action_limit == nil then
        action_limit = 99
    end
    local event_budget = raw_get(value, 'event_budget')
    if event_budget == nil then
        event_budget = 10000
    end
    local access_rule_id = raw_get(value, 'access_rule_id')
    if access_rule_id == nil then
        access_rule_id = 'access_open'
    end
    local party_constraint_id = raw_get(value, 'party_constraint_id')
    if party_constraint_id == nil then
        party_constraint_id = 'party_default'
    end
    local retry_policy_id = raw_get(value, 'retry_policy_id')
    if retry_policy_id == nil then
        retry_policy_id = 'retry_story_default'
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'encounter_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_enum(SCHEMA, 'encounter_type', value.encounter_type, ENCOUNTER_TYPES),
        validation_non_empty_string(SCHEMA, 'name_key', value.name_key),
        validation_non_empty_string(SCHEMA, 'description_key', value.description_key),
        validation_content_id(SCHEMA, 'area_id', value.area_id, 'area_'),
        validation_content_id(SCHEMA, 'location_id', value.location_id, 'loc_'),
        validation_content_id(
            SCHEMA,
            'start_interaction_id',
            value.start_interaction_id,
            'interact_',
            true
        ),
        validation_content_id(SCHEMA, 'access_rule_id', access_rule_id, 'access_'),
        validation_content_id(SCHEMA, 'party_constraint_id', party_constraint_id, 'party_'),
        validation_dense_array(SCHEMA, 'wave_ids', value.wave_ids),
        validation_content_id(
            SCHEMA,
            'boss_controller_id',
            value.boss_controller_id,
            'bossctl_',
            true
        ),
        validation_dense_array(SCHEMA, 'mechanic_ids', mechanic_ids),
        validation_dense_array(SCHEMA, 'victory_condition_ids', victory_condition_ids),
        validation_dense_array(SCHEMA, 'failure_condition_ids', failure_condition_ids),
        validation_content_id(
            SCHEMA,
            'environment_spec_id',
            value.environment_spec_id,
            'environment_',
            true
        ),
        validation_enum(SCHEMA, 'seed_policy', value.seed_policy, SEED_POLICIES),
        validation_integer(SCHEMA, 'fixed_seed', value.fixed_seed, 1, 2147483646, true),
        validation_content_id(SCHEMA, 'retry_policy_id', retry_policy_id, 'retry_'),
        validation_content_id(
            SCHEMA,
            'first_clear_reward_bundle_id',
            value.first_clear_reward_bundle_id,
            'reward_',
            true
        ),
        validation_content_id(
            SCHEMA,
            'repeat_reward_bundle_id',
            value.repeat_reward_bundle_id,
            'reward_',
            true
        ),
        validation_content_id(
            SCHEMA,
            'world_result_set_id',
            value.world_result_set_id,
            'worldset_',
            true
        ),
        validation_content_id(SCHEMA, 'completion_fact_id', value.completion_fact_id, 'fact_'),
        validation_enum(SCHEMA, 'combat_kind', combat_kind, COMBAT_KINDS),
        validation_integer(SCHEMA, 'action_limit', action_limit, 1, 99),
        validation_integer(SCHEMA, 'event_budget', event_budget, 1, 100000),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if #value.wave_ids < 1 or #value.wave_ids > 20 then
        return validation_invalid(SCHEMA, 'wave_ids', 'WAVE_COUNT_OUT_OF_RANGE', {
            minimum = 1,
            maximum = 20,
        })
    end
    if #victory_condition_ids < 1 then
        return validation_invalid(SCHEMA, 'victory_condition_ids', 'VICTORY_REQUIRED')
    end
    if #failure_condition_ids < 1 then
        return validation_invalid(SCHEMA, 'failure_condition_ids', 'FAILURE_REQUIRED')
    end
    if value.encounter_type == 'BOSS' and value.boss_controller_id == nil then
        return validation_invalid(SCHEMA, 'boss_controller_id', 'BOSS_CONTROLLER_REQUIRED')
    end
    if value.seed_policy == 'FIXED' then
        err = validation_integer(SCHEMA, 'fixed_seed', value.fixed_seed, 1, 2147483646)
        if err ~= nil then
            return err
        end
    end
    if value.seed_policy == 'SERVER_GRANTED' then
        return validation_invalid(SCHEMA, 'seed_policy', 'SERVER_GRANTED_UNSUPPORTED_V1')
    end

    local seen_waves = {}
    local index
    for index = 1, #value.wave_ids do
        local wave_id = value.wave_ids[index]
        err = validation_content_id(SCHEMA, 'wave_ids', wave_id, 'wave_')
        if err ~= nil then
            return err
        end
        if seen_waves[wave_id] then
            return validation_invalid(SCHEMA, 'wave_ids', 'DUPLICATE_WAVE_ID', {
                index = index,
                wave_id = wave_id,
            })
        end
        seen_waves[wave_id] = true
    end

    for index = 1, #mechanic_ids do
        err = validation_content_id(SCHEMA, 'mechanic_ids', mechanic_ids[index], 'mech_')
        if err ~= nil then
            return err
        end
    end
    for index = 1, #victory_condition_ids do
        err = validation_content_id(
            SCHEMA,
            'victory_condition_ids',
            victory_condition_ids[index],
            'cond_'
        )
        if err ~= nil then
            return err
        end
    end
    for index = 1, #failure_condition_ids do
        err = validation_content_id(
            SCHEMA,
            'failure_condition_ids',
            failure_condition_ids[index],
            'cond_'
        )
        if err ~= nil then
            return err
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        encounter_type = value.encounter_type,
        name_key = value.name_key,
        description_key = value.description_key,
        area_id = value.area_id,
        location_id = value.location_id,
        start_interaction_id = value.start_interaction_id,
        access_rule_id = access_rule_id,
        party_constraint_id = party_constraint_id,
        wave_ids = copy_strings(value.wave_ids),
        boss_controller_id = value.boss_controller_id,
        mechanic_ids = copy_strings(mechanic_ids),
        victory_condition_ids = copy_strings(victory_condition_ids),
        failure_condition_ids = copy_strings(failure_condition_ids),
        environment_spec_id = value.environment_spec_id,
        seed_policy = value.seed_policy,
        fixed_seed = value.fixed_seed,
        retry_policy_id = retry_policy_id,
        first_clear_reward_bundle_id = value.first_clear_reward_bundle_id,
        repeat_reward_bundle_id = value.repeat_reward_bundle_id,
        world_result_set_id = value.world_result_set_id,
        completion_fact_id = value.completion_fact_id,
        combat_kind = combat_kind,
        action_limit = action_limit,
        event_budget = event_budget,
        deprecated = deprecated,
    })
end

EncounterDefinition.ENCOUNTER_TYPES = ENCOUNTER_TYPES
EncounterDefinition.SEED_POLICIES = SEED_POLICIES

return EncounterDefinition
