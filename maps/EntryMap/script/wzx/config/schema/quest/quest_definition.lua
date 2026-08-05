local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.quest.validation'

local QuestDefinition = {}
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

local SCHEMA = 'QuestDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    definition_version = true,
    rules_version = true,
    category = true,
    chapter_id = true,
    title_key = true,
    summary_key = true,
    visibility_policy = true,
    accept_policy = true,
    accept_ref_id = true,
    prerequisite_quest_id = true,
    first_stage_id = true,
    stage_ids = true,
    reward_policy = true,
    turn_in_npc_id = true,
    reward_id = true,
    abandon_policy = true,
    failure_policy = true,
    journal_sort_order = true,
    deprecated = true,
}
local CATEGORIES = {
    MAIN = true,
    SIDE = true,
    HIDDEN = true,
    TUTORIAL = true,
    BOUNTY = true,
    COMMISSION = true,
}
local VISIBILITY = {
    VISIBLE_WHEN_AVAILABLE = true,
    HIDDEN_UNTIL_ACCEPTED = true,
    HIDDEN_UNTIL_REVEALED = true,
}
local ACCEPT_POLICIES = {
    MANUAL_NPC = true,
    AUTO_EVENT = true,
    AUTO_CONDITION = true,
    BOARD = true,
}
local REWARD_POLICIES = {
    AUTO_ON_COMPLETE = true,
    TURN_IN_NPC = true,
    NO_REWARD = true,
}
local ABANDON_POLICIES = {
    DENY = true,
    ALLOW_RESET_RUN = true,
    ALLOW_KEEP_HISTORY = true,
}
local FAILURE_POLICIES = {
    NO_FAIL = true,
    EXPLICIT_EVENT = true,
    PERIOD_EXPIRE = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

function QuestDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local visibility_policy = raw_get(value, 'visibility_policy')
    if visibility_policy == nil then
        visibility_policy = 'VISIBLE_WHEN_AVAILABLE'
    end
    local accept_policy = raw_get(value, 'accept_policy')
    if accept_policy == nil then
        accept_policy = 'MANUAL_NPC'
    end
    local reward_policy = raw_get(value, 'reward_policy')
    if reward_policy == nil then
        reward_policy = 'AUTO_ON_COMPLETE'
    end
    local abandon_policy = raw_get(value, 'abandon_policy')
    if abandon_policy == nil then
        if value.category == 'MAIN' then
            abandon_policy = 'DENY'
        else
            abandon_policy = 'ALLOW_RESET_RUN'
        end
    end
    local failure_policy = raw_get(value, 'failure_policy')
    if failure_policy == nil then
        failure_policy = 'NO_FAIL'
    end
    local journal_sort_order = raw_get(value, 'journal_sort_order')
    if journal_sort_order == nil then
        journal_sort_order = 1000
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local rules_version = raw_get(value, 'rules_version')
    if rules_version == nil then
        rules_version = 1
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'quest_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'definition_version', value.definition_version, 1),
        validation_integer(SCHEMA, 'rules_version', rules_version, 1),
        validation_enum(SCHEMA, 'category', value.category, CATEGORIES),
        validation_content_id(SCHEMA, 'chapter_id', value.chapter_id, 'chapter_'),
        validation_non_empty_string(SCHEMA, 'title_key', value.title_key),
        validation_non_empty_string(SCHEMA, 'summary_key', value.summary_key),
        validation_enum(SCHEMA, 'visibility_policy', visibility_policy, VISIBILITY),
        validation_enum(SCHEMA, 'accept_policy', accept_policy, ACCEPT_POLICIES),
        validation_content_id(SCHEMA, 'first_stage_id', value.first_stage_id, 'stage_'),
        validation_dense_array(SCHEMA, 'stage_ids', value.stage_ids),
        validation_enum(SCHEMA, 'reward_policy', reward_policy, REWARD_POLICIES),
        validation_content_id(SCHEMA, 'turn_in_npc_id', value.turn_in_npc_id, 'npc_', true),
        validation_content_id(SCHEMA, 'reward_id', value.reward_id, 'reward_', true),
        validation_enum(SCHEMA, 'abandon_policy', abandon_policy, ABANDON_POLICIES),
        validation_enum(SCHEMA, 'failure_policy', failure_policy, FAILURE_POLICIES),
        validation_integer(SCHEMA, 'journal_sort_order', journal_sort_order, 0, 1000000),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if value.accept_ref_id ~= nil then
        err = validation_non_empty_string(SCHEMA, 'accept_ref_id', value.accept_ref_id, 96)
        if err ~= nil then
            return err
        end
    elseif accept_policy == 'MANUAL_NPC' or accept_policy == 'BOARD' then
        return validation_invalid(SCHEMA, 'accept_ref_id', 'ACCEPT_REF_REQUIRED')
    end

    err = validation_content_id(
        SCHEMA,
        'prerequisite_quest_id',
        value.prerequisite_quest_id,
        'quest_',
        true
    )
    if err ~= nil then
        return err
    end
    if value.prerequisite_quest_id ~= nil
        and value.prerequisite_quest_id == value.id
    then
        return validation_invalid(
            SCHEMA,
            'prerequisite_quest_id',
            'PREREQUISITE_SELF_REFERENCE'
        )
    end

    if #value.stage_ids < 1 or #value.stage_ids > 32 then
        return validation_invalid(SCHEMA, 'stage_ids', 'STAGE_COUNT_OUT_OF_RANGE', {
            minimum = 1,
            maximum = 32,
        })
    end

    local seen = {}
    local first_found = false
    local index
    for index = 1, #value.stage_ids do
        local stage_id = value.stage_ids[index]
        err = validation_content_id(SCHEMA, 'stage_ids', stage_id, 'stage_')
        if err ~= nil then
            return err
        end
        if seen[stage_id] then
            return validation_invalid(SCHEMA, 'stage_ids', 'DUPLICATE_STAGE_ID', {
                stage_id = stage_id,
            })
        end
        seen[stage_id] = true
        if stage_id == value.first_stage_id then
            first_found = true
        end
    end
    if not first_found then
        return validation_invalid(SCHEMA, 'first_stage_id', 'FIRST_STAGE_NOT_IN_STAGE_IDS')
    end

    if reward_policy == 'TURN_IN_NPC' and value.turn_in_npc_id == nil then
        return validation_invalid(SCHEMA, 'turn_in_npc_id', 'TURN_IN_NPC_REQUIRED')
    end
    if reward_policy ~= 'NO_REWARD' and value.reward_id == nil then
        return validation_invalid(SCHEMA, 'reward_id', 'REWARD_ID_REQUIRED')
    end
    if accept_policy == 'BOARD' then
        return validation_invalid(SCHEMA, 'accept_policy', 'BOARD_UNSUPPORTED_V1_SLICE')
    end
    if value.category == 'MAIN' and abandon_policy ~= 'DENY' then
        return validation_invalid(SCHEMA, 'abandon_policy', 'MAIN_MUST_DENY_ABANDON')
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        definition_version = value.definition_version,
        rules_version = rules_version,
        category = value.category,
        chapter_id = value.chapter_id,
        title_key = value.title_key,
        summary_key = value.summary_key,
        visibility_policy = visibility_policy,
        accept_policy = accept_policy,
        accept_ref_id = value.accept_ref_id,
        prerequisite_quest_id = value.prerequisite_quest_id,
        first_stage_id = value.first_stage_id,
        stage_ids = copy_strings(value.stage_ids),
        reward_policy = reward_policy,
        turn_in_npc_id = value.turn_in_npc_id,
        reward_id = value.reward_id,
        abandon_policy = abandon_policy,
        failure_policy = failure_policy,
        journal_sort_order = journal_sort_order,
        deprecated = deprecated,
    })
end

return QuestDefinition
