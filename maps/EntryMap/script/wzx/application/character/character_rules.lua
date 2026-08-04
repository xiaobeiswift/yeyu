local Catalog = require 'wzx.config.schema.character.catalog'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local CharacterAggregate = require 'wzx.domain.character.character_aggregate'
local ErrorCodes = require 'wzx.domain.character.error_codes'
local LevelRewardPlanDigest = require 'wzx.domain.character.level_reward_plan_digest'
local Progression = require 'wzx.domain.character.progression'
local StatPipeline = require 'wzx.domain.character.stat_pipeline'
local TalentListDigest = require 'wzx.domain.character.talent_list_digest'
local CharacterBuildSnapshot = require 'wzx.domain.contracts.character_build_snapshot'
local CombatantSnapshot = require 'wzx.domain.contracts.combatant_snapshot'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'

local CharacterRules = {}
local error_value = error
local set_metatable = setmetatable
local get_metatable = getmetatable
local bytewise_string_less = Ordered.bytewise_string_less
local canonical_derive = CanonicalReceiptHashV1.derive
local is_catalog_authority = Catalog.is_authority
local is_dense_array = Ordered.is_dense_array
local is_reward_catalog_authority = RewardCatalog.is_authority
local math_floor = math.floor
local resolve_catalog_character = Catalog.resolve_character
local table_sort = table.sort
local validate_catalog_owned_talents = Catalog.validate_owned_talents
local validate_level_reward = RewardCatalog.validate_as_level_reward
local aggregate_create_owned = CharacterAggregate.create_owned
local aggregate_grant_experience = CharacterAggregate.grant_experience
local aggregate_rename_protagonist = CharacterAggregate.rename_protagonist
local aggregate_validate = CharacterAggregate.validate
local collect_level_rewards = Progression.collect_level_rewards
local derive_level_reward_plan = LevelRewardPlanDigest.derive
local derive_talent_list_digest = TalentListDigest.derive
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_content_id = RuntimeId.validate_content
local validate_derived_id = RuntimeId.validate_derived
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

local function copy_sorted_tags(tags)
    local copied = {}
    local index
    for index = 1, #tags do
        copied[index] = tags[index]
    end
    table_sort(copied, bytewise_string_less)
    local unique = {}
    local previous
    for index = 1, #copied do
        if previous == nil or previous ~= copied[index] then
            unique[#unique + 1] = copied[index]
            previous = copied[index]
        end
    end
    return unique
end

local function validate_external_contributions(contributions, field_name)
    if contributions == nil then
        return result_ok({})
    end
    if type_value(contributions) ~= 'table'
        or get_metatable(contributions) ~= nil
        or not is_dense_array(contributions)
    then
        return build_failure('DENSE_ARRAY_REQUIRED', { field = field_name })
    end
    local copied = {}
    local index
    for index = 1, #contributions do
        local validated = StatContribution.validate(contributions[index])
        if not validated.ok then
            return result_err(
                ErrorCodes.CHARACTER_CONTRIBUTION_INVALID,
                'error.character.contribution_invalid',
                false,
                {
                    reason = 'EXTERNAL_CONTRIBUTION_INVALID',
                    field = field_name,
                    index = index,
                    cause_code = validated.error.code,
                }
            )
        end
        copied[index] = validated.value
    end
    return result_ok(copied)
end

function Rules:build_combatant_snapshot(state, options)
    options = options or {}
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return build_failure('TABLE_REQUIRED', { field = 'options' })
    end

    local validated = validate_resolved_state(self, state)
    if not validated.ok then
        return validated
    end
    local authority = authority_state(self)
    if authority == nil or authority.catalog == nil then
        return invalid_authority('RULES_AUTHORITY_REQUIRED')
    end

    local rules_version = raw_get(options, 'rules_version')
    if rules_version == nil then
        rules_version = 1
    end
    if type_value(rules_version) ~= 'number'
        or rules_version ~= math_floor(rules_version)
        or rules_version < 1
    then
        return build_failure('RULES_VERSION_INVALID', {
            field = 'options.rules_version',
        })
    end

    local side = raw_get(options, 'side') or 'ATTACKER'
    local position_index = raw_get(options, 'position_index')
    if position_index == nil then
        position_index = 0
    end
    local actor_id = raw_get(options, 'actor_id')
    if actor_id == nil then
        actor_id = 'actor:' .. validated.value.state.character_id
    end
    local actor_checked = validate_derived_id(actor_id, 'actor_id')
    if not actor_checked.ok then
        return build_failure('ACTOR_ID_INVALID', { field = 'options.actor_id' })
    end
    local ai_profile_id = raw_get(options, 'ai_profile_id') or 'ai_default'
    local ai_checked = validate_content_id(
        ai_profile_id,
        'ai_',
        'ai_profile_id'
    )
    if not ai_checked.ok then
        return build_failure('AI_PROFILE_ID_INVALID', {
            field = 'options.ai_profile_id',
        })
    end

    local context_tags = {}
    if raw_get(options, 'view_context') ~= nil then
        if type_value(options.view_context) ~= 'table'
            or get_metatable(options.view_context) ~= nil
            or not is_dense_array(options.view_context)
        then
            return build_failure('VIEW_CONTEXT_INVALID', {
                field = 'options.view_context',
            })
        end
        local index
        for index = 1, #options.view_context do
            context_tags[index] = options.view_context[index]
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

    local talent_contributions = collect_talent_contributions(
        authority.catalog,
        validated.value.state.unlocked_talent_ids
    )
    if not talent_contributions.ok then
        return talent_contributions
    end
    local equipment_contributions = validate_external_contributions(
        raw_get(options, 'equipment_contributions'),
        'options.equipment_contributions'
    )
    if not equipment_contributions.ok then
        return equipment_contributions
    end
    local martial_contributions = validate_external_contributions(
        raw_get(options, 'martial_contributions'),
        'options.martial_contributions'
    )
    if not martial_contributions.ok then
        return martial_contributions
    end
    local progression_contributions = validate_external_contributions(
        raw_get(options, 'progression_contributions'),
        'options.progression_contributions'
    )
    if not progression_contributions.ok then
        return progression_contributions
    end

    local contributions = {}
    local index
    for index = 1, #talent_contributions.value do
        contributions[#contributions + 1] = talent_contributions.value[index]
    end
    for index = 1, #equipment_contributions.value do
        contributions[#contributions + 1] = equipment_contributions.value[index]
    end
    for index = 1, #martial_contributions.value do
        contributions[#contributions + 1] = martial_contributions.value[index]
    end
    for index = 1, #progression_contributions.value do
        contributions[#contributions + 1] = progression_contributions.value[index]
    end

    local pipeline = StatPipeline.calculate({
        level = validated.value.state.level,
        base_primary = definition.base_primary,
        growth_per_level_milli = definition.growth_per_level_milli,
        formula = formula_result.value,
        initial_qi = definition.initial_qi,
        contributions = contributions,
        context_tags = context_tags,
    })
    if not pipeline.ok then
        return pipeline
    end

    local talent_ids = {}
    for index = 1, #validated.value.state.unlocked_talent_ids do
        talent_ids[index] = validated.value.state.unlocked_talent_ids[index]
    end
    local talent_proof = derive_talent_list_digest(talent_ids)
    if not talent_proof.ok then
        return talent_proof
    end

    local definition_hash = canonical_derive(
        'character_definition_source',
        {
            { name = 'character_id', type = 'STRING' },
            { name = 'definition_version', type = 'INTEGER' },
            { name = 'formula_version', type = 'INTEGER' },
        },
        {
            character_id = character_id,
            definition_version = definition.definition_version,
            formula_version = formula_result.value.formula_version,
        }
    )
    if not definition_hash.ok then
        return definition_hash
    end

    local talent_entries = {}
    for index = 1, #talent_ids do
        talent_entries[index] = { talent_id = talent_ids[index] }
    end

    local equipment_snapshot = raw_get(options, 'equipment_snapshot') or {}
    local martial_snapshot = raw_get(options, 'martial_snapshot') or {}
    local progression_snapshot = raw_get(options, 'progression_snapshot') or {}
    if type_value(equipment_snapshot) ~= 'table'
        or type_value(martial_snapshot) ~= 'table'
        or type_value(progression_snapshot) ~= 'table'
    then
        return build_failure('SNAPSHOT_TABLE_REQUIRED', {
            field = 'options.*_snapshot',
        })
    end

    local empty_source = string.rep('0', 64)
    local equipment_hash = empty_source
    local martial_hash = empty_source
    local progression_hash = empty_source
    if #equipment_contributions.value > 0 then
        local derived = canonical_derive(
            'character_equipment_source',
            {
                { name = 'contribution_count', type = 'INTEGER' },
                { name = 'character_id', type = 'STRING' },
            },
            {
                contribution_count = #equipment_contributions.value,
                character_id = character_id,
            }
        )
        if not derived.ok then
            return derived
        end
        equipment_hash = derived.value.digest
    end
    if #martial_contributions.value > 0 then
        local derived = canonical_derive(
            'character_martial_source',
            {
                { name = 'contribution_count', type = 'INTEGER' },
                { name = 'character_id', type = 'STRING' },
            },
            {
                contribution_count = #martial_contributions.value,
                character_id = character_id,
            }
        )
        if not derived.ok then
            return derived
        end
        martial_hash = derived.value.digest
    end
    if #progression_contributions.value > 0 then
        local derived = canonical_derive(
            'character_progression_source',
            {
                { name = 'contribution_count', type = 'INTEGER' },
                { name = 'character_id', type = 'STRING' },
            },
            {
                contribution_count = #progression_contributions.value,
                character_id = character_id,
            }
        )
        if not derived.ok then
            return derived
        end
        progression_hash = derived.value.digest
    end

    local build_hash = canonical_derive(
        'character_build_snapshot',
        {
            { name = 'character_id', type = 'STRING' },
            { name = 'definition_version', type = 'INTEGER' },
            { name = 'level', type = 'INTEGER' },
            { name = 'character_revision', type = 'INTEGER' },
            { name = 'rules_version', type = 'INTEGER' },
            { name = 'talent_digest', type = 'STRING' },
            { name = 'definition_hash', type = 'STRING' },
            { name = 'equipment_hash', type = 'STRING' },
            { name = 'martial_hash', type = 'STRING' },
            { name = 'progression_hash', type = 'STRING' },
        },
        {
            character_id = character_id,
            definition_version = definition.definition_version,
            level = validated.value.state.level,
            character_revision = validated.value.state.revision,
            rules_version = rules_version,
            talent_digest = talent_proof.value.digest,
            definition_hash = definition_hash.value.digest,
            equipment_hash = equipment_hash,
            martial_hash = martial_hash,
            progression_hash = progression_hash,
        }
    )
    if not build_hash.ok then
        return build_hash
    end

    local build_snapshot = {
        schema_version = 1,
        character_id = character_id,
        definition_version = definition.definition_version,
        level = validated.value.state.level,
        awakening_rank = validated.value.state.awakening_rank,
        talent_entries = talent_entries,
        equipment_snapshot = equipment_snapshot,
        martial_snapshot = martial_snapshot,
        progression_snapshot = progression_snapshot,
        character_revision = validated.value.state.revision,
        rules_version = rules_version,
        source_hashes = {
            character_definition = definition_hash.value.digest,
            talents = talent_proof.value.digest,
            equipment = equipment_hash,
            martial = martial_hash,
            progression = progression_hash,
        },
        build_hash = build_hash.value.digest,
    }
    local build_validated = CharacterBuildSnapshot.validate(build_snapshot)
    if not build_validated.ok then
        return build_validated
    end

    local tags = copy_sorted_tags(definition.tags or {})
    local martial_loadout = raw_get(options, 'martial_loadout') or {}
    local initial_status_ids = raw_get(options, 'initial_status_ids') or {}
    if type_value(martial_loadout) ~= 'table'
        or type_value(initial_status_ids) ~= 'table'
        or get_metatable(initial_status_ids) ~= nil
        or not is_dense_array(initial_status_ids)
    then
        return build_failure('COMBATANT_OPTIONS_INVALID', {
            field = 'options.martial_loadout|initial_status_ids',
        })
    end
    local statuses = copy_sorted_tags(initial_status_ids)

    local combatant = {
        actor_id = actor_id,
        definition_id = character_id,
        side = side,
        position_index = position_index,
        level = validated.value.state.level,
        tags = tags,
        stats = pipeline.value.stats,
        martial_loadout = martial_loadout,
        initial_status_ids = statuses,
        ai_profile_id = ai_profile_id,
        source_revision = validated.value.state.revision,
        source_hash = build_hash.value.digest,
    }
    local combatant_validated = CombatantSnapshot.validate(combatant)
    if not combatant_validated.ok then
        return combatant_validated
    end

    return result_ok({
        build_snapshot = build_validated.value,
        combatant_snapshot = combatant_validated.value,
        primary_attributes = pipeline.value.primary,
        breakdown = pipeline.value.breakdown,
        diagnostics = pipeline.value.diagnostics,
        source_hash = build_hash.value.digest,
        rules_version = rules_version,
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
