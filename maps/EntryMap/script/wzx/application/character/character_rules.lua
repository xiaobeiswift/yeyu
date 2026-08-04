local Catalog = require 'wzx.config.schema.character.catalog'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local CharacterAggregate = require 'wzx.domain.character.character_aggregate'
local ErrorCodes = require 'wzx.domain.character.error_codes'
local LevelRewardPlanDigest = require 'wzx.domain.character.level_reward_plan_digest'
local Progression = require 'wzx.domain.character.progression'
local StatPipeline = require 'wzx.domain.character.stat_pipeline'

local CharacterRules = {}
local error_value = error
local set_metatable = setmetatable
local get_metatable = getmetatable
local is_catalog_authority = Catalog.is_authority
local is_dense_array = Ordered.is_dense_array
local is_reward_catalog_authority = RewardCatalog.is_authority
local resolve_catalog_character = Catalog.resolve_character
local validate_catalog_owned_talents = Catalog.validate_owned_talents
local validate_level_reward = RewardCatalog.validate_as_level_reward
local aggregate_create_owned = CharacterAggregate.create_owned
local aggregate_grant_experience = CharacterAggregate.grant_experience
local aggregate_rename_protagonist = CharacterAggregate.rename_protagonist
local aggregate_validate = CharacterAggregate.validate
local collect_level_rewards = Progression.collect_level_rewards
local derive_level_reward_plan = LevelRewardPlanDigest.derive
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_content_id = RuntimeId.validate_content
local Rules = {}
Rules.__index = Rules
Rules.__newindex = function()
    error_value('character rules are read-only', 2)
end
Rules.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function build_failure(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        ErrorCodes.CHARACTER_BUILD_INVALID,
        'error.character.build_invalid',
        false,
        details
    )
end

local function invalid_authority(reason)
    return result_err(
        'INVALID_ARGUMENT',
        'error.character.rules_authority_invalid',
        false,
        { reason = reason }
    )
end

local function authority_state(self)
    return STATES[self]
end

local function resolve_for_state(self, state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return build_failure('TABLE_REQUIRED', { field = 'state' })
    end
    local character_id = raw_get(state, 'character_id')
    local checked_id = validate_content_id(
        character_id,
        'char_',
        'state.character_id'
    )
    if not checked_id.ok then
        return build_failure('CHARACTER_ID_INVALID', {
            field = 'state.character_id',
        })
    end
    local authority = authority_state(self)
    if authority == nil then
        return invalid_authority('RULES_AUTHORITY_REQUIRED')
    end
    return authority.resolve_character(character_id)
end

local function validate_resolved_state(self, state)
    local resolved = resolve_for_state(self, state)
    if not resolved.ok then
        return resolved
    end
    local validated = aggregate_validate(
        state,
        resolved.value.definition_facts,
        resolved.value.level_curve
    )
    if not validated.ok then
        return validated
    end

    local authority = authority_state(self)
    local talents = authority.validate_owned_talents(
        validated.value.character_id,
        validated.value.unlocked_talent_ids
    )
    if not talents.ok then
        return talents
    end
    return result_ok({
        state = validated.value,
        definition_facts = resolved.value.definition_facts,
        level_curve = resolved.value.level_curve,
    })
end

function Rules:create_owned(character_id, created_receipt_id)
    local authority = authority_state(self)
    if authority == nil then
        return invalid_authority('RULES_AUTHORITY_REQUIRED')
    end
    local resolved = authority.resolve_character(character_id)
    if not resolved.ok then
        return resolved
    end
    return aggregate_create_owned(
        resolved.value.definition_facts,
        created_receipt_id
    )
end

function Rules:validate(state)
    local validated = validate_resolved_state(self, state)
    if not validated.ok then
        return validated
    end
    return result_ok(validated.value.state)
end

local function plan_experience_grant(self, state, amount)
    local validated = validate_resolved_state(self, state)
    if not validated.ok then
        return validated
    end
    local granted = aggregate_grant_experience(
        validated.value.state,
        validated.value.definition_facts,
        validated.value.level_curve,
        amount
    )
    if not granted.ok then
        return granted
    end

    local before_state = validated.value.state
    local after_state = granted.value
    local rewards = collect_level_rewards(
        validated.value.level_curve,
        before_state.level,
        after_state.level
    )
    if not rewards.ok then
        return rewards
    end

    -- When a sealed RewardCatalog is bound, every planned level reward must
    -- resolve and expand without CHARACTER_XP leaves. Unbound rules remain a
    -- pure offline planner and must not be used for production grant paths.
    local authority = authority_state(self)
    if authority ~= nil and authority.reward_catalog ~= nil then
        local reward_index
        for reward_index = 1, #rewards.value do
            local safe = validate_level_reward(
                authority.reward_catalog,
                rewards.value[reward_index].reward_ref
            )
            if not safe.ok then
                return safe
            end
        end
    end

    local proof = derive_level_reward_plan({
        character_id = before_state.character_id,
        definition_version = validated.value.definition_facts.definition_version,
        curve_id = validated.value.level_curve.id,
        expected_revision = before_state.revision,
        old_level = before_state.level,
        new_level = after_state.level,
        rewards = rewards.value,
    })
    if not proof.ok then
        return proof
    end
    local reward_refs = {}
    local index
    for index = 1, #rewards.value do
        reward_refs[index] = rewards.value[index].reward_ref
    end
    return result_ok({
        character_id = before_state.character_id,
        definition_version = validated.value.definition_facts.definition_version,
        curve_id = validated.value.level_curve.id,
        expected_revision = before_state.revision,
        old_level = before_state.level,
        new_level = after_state.level,
        before_state = before_state,
        after_state = after_state,
        reached_level_rewards = rewards.value,
        reward_refs = reward_refs,
        reward_ref_count = proof.value.count,
        reward_plan_digest = proof.value.digest,
        reward_catalog_bound = authority ~= nil
            and authority.reward_catalog ~= nil,
    })
end

function Rules:plan_experience_grant(state, amount)
    return plan_experience_grant(self, state, amount)
end

function Rules:grant_experience(state, amount)
    local planned = plan_experience_grant(self, state, amount)
    if not planned.ok then
        return planned
    end
    return result_ok(planned.value.after_state)
end

function Rules:plan_rename(state, new_name)
    local validated = validate_resolved_state(self, state)
    if not validated.ok then
        return validated
    end
    local renamed = aggregate_rename_protagonist(
        validated.value.state,
        validated.value.definition_facts,
        validated.value.level_curve,
        new_name
    )
    if not renamed.ok then
        return renamed
    end
    return result_ok({
        character_id = validated.value.state.character_id,
        expected_revision = validated.value.state.revision,
        before_state = validated.value.state,
        after_state = renamed.value,
        new_name = new_name,
        role = validated.value.definition_facts.role,
    })
end

local function collect_talent_contributions(catalog, talent_ids)
    local contributions = {}
    local index
    for index = 1, #talent_ids do
        local talent_id = talent_ids[index]
        local talent_result = catalog:get('talent_definitions', talent_id)
        if not talent_result.ok then
            return talent_result
        end
        local talent = talent_result.value
        local contribution_index
        for contribution_index = 1, #talent.contributions do
            contributions[#contributions + 1] = talent.contributions[contribution_index]
        end
    end
    return result_ok(contributions)
end

function Rules:get_detail(state, view_context)
    local validated = validate_resolved_state(self, state)
    if not validated.ok then
        return validated
    end
    local authority = authority_state(self)
    if authority == nil or authority.catalog == nil then
        return invalid_authority('RULES_AUTHORITY_REQUIRED')
    end

    local context_tags = {}
    if view_context ~= nil then
        if type_value(view_context) ~= 'table'
            or get_metatable(view_context) ~= nil
            or not is_dense_array(view_context)
        then
            return build_failure('VIEW_CONTEXT_INVALID', {
                field = 'view_context',
            })
        end
        local index
        for index = 1, #view_context do
            if type_value(view_context[index]) ~= 'string'
                or view_context[index] == ''
            then
                return build_failure('VIEW_CONTEXT_TAG_INVALID', {
                    field = 'view_context',
                    index = index,
                })
            end
            context_tags[index] = view_context[index]
        end
    end

    local character_id = validated.value.state.character_id
    local definition_result = authority.catalog:get(
        'character_definitions',
        character_id
    )
    if not definition_result.ok then
        return definition_result
    end
    local definition = definition_result.value
    local formula_result = authority.catalog:get(
        'formula_sets',
        definition.formula_set_id
    )
    if not formula_result.ok then
        return formula_result
    end

    local contributions = collect_talent_contributions(
        authority.catalog,
        validated.value.state.unlocked_talent_ids
    )
    if not contributions.ok then
        return contributions
    end

    local pipeline = StatPipeline.calculate({
        level = validated.value.state.level,
        base_primary = definition.base_primary,
        growth_per_level_milli = definition.growth_per_level_milli,
        formula = formula_result.value,
        initial_qi = definition.initial_qi,
        contributions = contributions.value,
        context_tags = context_tags,
    })
    if not pipeline.ok then
        return pipeline
    end

    local talent_ids = {}
    local talent_index
    for talent_index = 1, #validated.value.state.unlocked_talent_ids do
        talent_ids[talent_index] =
            validated.value.state.unlocked_talent_ids[talent_index]
    end

    return result_ok({
        character_id = character_id,
        definition_version = validated.value.state.definition_version,
        role = definition.role,
        level = validated.value.state.level,
        experience = validated.value.state.experience,
        awakening_rank = validated.value.state.awakening_rank,
        custom_name = validated.value.state.custom_name,
        unlocked_talent_ids = talent_ids,
        created_receipt_id = validated.value.state.created_receipt_id,
        revision = validated.value.state.revision,
        character_save_revision = nil,
        display_name_key = definition.display_name_key,
        primary_attributes = pipeline.value.primary,
        combat_stats = pipeline.value.stats,
        breakdown = pipeline.value.breakdown,
        diagnostics = pipeline.value.diagnostics,
        formula_id = formula_result.value.id,
        formula_version = formula_result.value.formula_version,
        view_context = context_tags,
        source_revisions = {
            character_revision = validated.value.state.revision,
            definition_version = definition.definition_version,
            formula_version = formula_result.value.formula_version,
        },
    })
end

-- The config composition boundary binds the canonical catalogs once. This
-- read-only pure-rules object is an internal dependency of future repository,
-- receipt, reward, and save-aware use cases; it is not a complete write service.
-- reward_catalog is optional: when present, experience plans must resolve every
-- level reward_ref against the sealed RewardCatalog and reject CHARACTER_XP leaves.
function CharacterRules.bind(catalog, reward_catalog)
    if not is_catalog_authority(catalog) then
        return invalid_authority('CATALOG_AUTHORITY_REQUIRED')
    end
    if reward_catalog ~= nil and not is_reward_catalog_authority(reward_catalog) then
        return invalid_authority('REWARD_CATALOG_AUTHORITY_REQUIRED')
    end
    local rules = set_metatable({}, Rules)
    STATES[rules] = {
        catalog = catalog,
        resolve_character = function(character_id)
            return resolve_catalog_character(catalog, character_id)
        end,
        validate_owned_talents = function(character_id, talent_ids)
            return validate_catalog_owned_talents(
                catalog,
                character_id,
                talent_ids
            )
        end,
        reward_catalog = reward_catalog,
    }
    return result_ok(rules)
end

return CharacterRules
