local Catalog = require 'wzx.config.schema.character.catalog'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local CharacterAggregate = require 'wzx.domain.character.character_aggregate'
local ErrorCodes = require 'wzx.domain.character.error_codes'

local CharacterRules = {}
local is_catalog_authority = Catalog.is_authority
local aggregate_create_owned = CharacterAggregate.create_owned
local aggregate_grant_experience = CharacterAggregate.grant_experience
local aggregate_validate = CharacterAggregate.validate
local Rules = {}
Rules.__index = Rules
Rules.__newindex = function()
    error('character rules are read-only', 2)
end
Rules.__metatable = false

local STATES = setmetatable({}, { __mode = 'k' })

local function build_failure(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err(
        ErrorCodes.CHARACTER_BUILD_INVALID,
        'error.character.build_invalid',
        false,
        details
    )
end

local function invalid_authority(reason)
    return Result.err(
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
    if type(state) ~= 'table' or getmetatable(state) ~= nil then
        return build_failure('TABLE_REQUIRED', { field = 'state' })
    end
    local character_id = rawget(state, 'character_id')
    local checked_id = RuntimeId.validate_content(
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
    return Result.ok({
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
    return Result.ok(validated.value.state)
end

function Rules:grant_experience(state, amount)
    local validated = validate_resolved_state(self, state)
    if not validated.ok then
        return validated
    end
    return aggregate_grant_experience(
        validated.value.state,
        validated.value.definition_facts,
        validated.value.level_curve,
        amount
    )
end

-- The config composition boundary binds the canonical catalog once. This
-- read-only pure-rules object is an internal dependency of future repository,
-- receipt, reward, and save-aware use cases; it is not a complete write service.
function CharacterRules.bind(catalog)
    if not is_catalog_authority(catalog) then
        return invalid_authority('CATALOG_AUTHORITY_REQUIRED')
    end
    local resolve_method = catalog.resolve_character
    local validate_talents_method = catalog.validate_owned_talents
    local rules = setmetatable({}, Rules)
    STATES[rules] = {
        resolve_character = function(character_id)
            return resolve_method(catalog, character_id)
        end,
        validate_owned_talents = function(character_id, talent_ids)
            return validate_talents_method(catalog, character_id, talent_ids)
        end,
    }
    return Result.ok(rules)
end

return CharacterRules
