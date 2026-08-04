local Catalog = require 'wzx.config.schema.character.catalog'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local CharacterAggregate = require 'wzx.domain.character.character_aggregate'
local ErrorCodes = require 'wzx.domain.character.error_codes'
local LevelRewardPlanDigest = require 'wzx.domain.character.level_reward_plan_digest'
local Progression = require 'wzx.domain.character.progression'

local CharacterRules = {}
local error_value = error
local set_metatable = setmetatable
local get_metatable = getmetatable
local is_catalog_authority = Catalog.is_authority
local resolve_catalog_character = Catalog.resolve_character
local validate_catalog_owned_talents = Catalog.validate_owned_talents
local aggregate_create_owned = CharacterAggregate.create_owned
local aggregate_grant_experience = CharacterAggregate.grant_experience
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

-- The config composition boundary binds the canonical catalog once. This
-- read-only pure-rules object is an internal dependency of future repository,
-- receipt, reward, and save-aware use cases; it is not a complete write service.
function CharacterRules.bind(catalog)
    if not is_catalog_authority(catalog) then
        return invalid_authority('CATALOG_AUTHORITY_REQUIRED')
    end
    local rules = set_metatable({}, Rules)
    STATES[rules] = {
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
    }
    return result_ok(rules)
end

return CharacterRules
