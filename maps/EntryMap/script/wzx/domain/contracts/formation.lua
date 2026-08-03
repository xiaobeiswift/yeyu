local CharacterBuildSnapshot = require 'wzx.domain.contracts.character_build_snapshot'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'
local Validation = require 'wzx.domain.contracts.validation'

local Formation = {}

local CONTEXTS = {
    PVE_MAIN = true,
    PVE_ALT = true,
    ARENA_DEFENSE = true,
}
local ROLE_TAGS = {
    FRONTLINE = true,
    DAMAGE = true,
    SUPPORT = true,
}

local MEMBER_FIELDS = {
    character_id = true,
    position_index = true,
    entry_order = true,
    role_tag_override = true,
}

local FORMATION_FIELDS = {
    party_context = true,
    leader_character_id = true,
    member_rows = true,
    formation_template_id = true,
    active_preset_id = true,
    is_dirty_from_preset = true,
    revision = true,
}

local COMBAT_INPUT_FIELDS = {
    party_context = true,
    formation_revision = true,
    constraint_id = true,
    formation_template_id = true,
    leader_character_id = true,
    member_snapshots = true,
    formation_contributions = true,
    source_revision_map = true,
    rules_version = true,
    normalized_hash_input = true,
}

local COMBAT_MEMBER_FIELDS = {
    position_index = true,
    build_snapshot = true,
}

local function validate_member(member, index)
    local contract = 'FormationMemberV1'
    local err = Validation.no_unknown_fields(contract, member, MEMBER_FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.identifier(contract, 'character_id', member.character_id, 'char_'),
        Validation.integer(contract, 'position_index', member.position_index, 0, 8),
        Validation.integer(contract, 'entry_order', member.entry_order, 1),
        Validation.enum(contract, 'role_tag_override', member.role_tag_override, ROLE_TAGS, true)
    )
    if err ~= nil then
        err.error.details.index = index
        return err
    end
    return nil
end

function Formation.validate(value)
    local contract = 'FormationV1'
    local err = Validation.no_unknown_fields(contract, value, FORMATION_FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.enum(contract, 'party_context', value.party_context, CONTEXTS),
        Validation.identifier(contract, 'leader_character_id', value.leader_character_id, 'char_'),
        Validation.dense_array(contract, 'member_rows', value.member_rows, 1, 4),
        Validation.identifier(contract, 'formation_template_id', value.formation_template_id, 'formation_', true),
        Validation.identifier(contract, 'active_preset_id', value.active_preset_id, 'preset_party_', true),
        Validation.boolean(contract, 'is_dirty_from_preset', value.is_dirty_from_preset),
        Validation.integer(contract, 'revision', value.revision, 0)
    )
    if err ~= nil then
        return err
    end

    local character_ids = {}
    local positions = {}
    local leader_found = false
    local index
    for index = 1, #value.member_rows do
        local member = value.member_rows[index]
        err = validate_member(member, index)
        if err ~= nil then
            return err
        end
        if character_ids[member.character_id] or positions[member.position_index] then
            return Validation.invalid(contract, 'member_rows', 'DUPLICATE_CHARACTER_OR_POSITION', {
                index = index,
            })
        end
        character_ids[member.character_id] = true
        positions[member.position_index] = true
        if member.character_id == value.leader_character_id then
            leader_found = true
        end
    end
    if not leader_found then
        return Validation.invalid(contract, 'leader_character_id', 'LEADER_NOT_IN_FORMATION')
    end
    return Result.ok(value)
end

function Formation.validate_combat_input(value)
    local contract = 'FormationCombatInputV1'
    local err = Validation.no_unknown_fields(contract, value, COMBAT_INPUT_FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.enum(contract, 'party_context', value.party_context, CONTEXTS),
        Validation.integer(contract, 'formation_revision', value.formation_revision, 0),
        Validation.identifier(contract, 'constraint_id', value.constraint_id, 'constraint_'),
        Validation.identifier(contract, 'formation_template_id', value.formation_template_id, 'formation_', true),
        Validation.identifier(contract, 'leader_character_id', value.leader_character_id, 'char_'),
        Validation.dense_array(contract, 'member_snapshots', value.member_snapshots, 1, 4),
        Validation.dense_array(contract, 'formation_contributions', value.formation_contributions, 0),
        Validation.non_negative_integer_map(contract, 'source_revision_map', value.source_revision_map),
        Validation.integer(contract, 'rules_version', value.rules_version, 1),
        Validation.hash(contract, 'normalized_hash_input', value.normalized_hash_input)
    )
    if err ~= nil then
        return err
    end

    local leader_found = false
    local previous_position = -1
    local previous_character = ''
    local character_ids = {}
    local positions = {}
    local index
    for index = 1, #value.member_snapshots do
        local member = value.member_snapshots[index]
        err = Validation.no_unknown_fields(contract, member, COMBAT_MEMBER_FIELDS)
        if err ~= nil then
            err.error.details.index = index
            return err
        end
        err = Validation.integer(contract, 'member_snapshots.position_index', member.position_index, 0, 8)
        if err ~= nil then
            return err
        end
        local build = member.build_snapshot
        local validated = CharacterBuildSnapshot.validate(build)
        if not validated.ok then
            return Validation.invalid(contract, 'member_snapshots', 'CHARACTER_BUILD_INVALID', {
                index = index,
                cause = validated.error,
            })
        end
        if positions[member.position_index] or character_ids[build.character_id] then
            return Validation.invalid(contract, 'member_snapshots', 'DUPLICATE_CHARACTER_OR_POSITION', {
                index = index,
            })
        end
        positions[member.position_index] = true
        character_ids[build.character_id] = true
        if member.position_index < previous_position
            or (member.position_index == previous_position and build.character_id <= previous_character)
        then
            return Validation.invalid(contract, 'member_snapshots', 'MEMBER_ORDER_INVALID', { index = index })
        end
        previous_position = member.position_index
        previous_character = build.character_id
        if build.character_id == value.leader_character_id then
            leader_found = true
        end
    end
    if not leader_found then
        return Validation.invalid(contract, 'leader_character_id', 'LEADER_NOT_IN_COMBAT_INPUT')
    end
    local seen_stable_order_keys = {}
    local previous_priority = nil
    local previous_stable_order_key = nil
    for index = 1, #value.formation_contributions do
        local contribution = value.formation_contributions[index]
        local validated = StatContribution.validate(contribution)
        if not validated.ok then
            return Validation.invalid(contract, 'formation_contributions', 'CONTRIBUTION_INVALID', {
                index = index,
                cause = validated.error,
            })
        end
        if seen_stable_order_keys[contribution.stable_order_key] then
            return Validation.invalid(
                contract,
                'formation_contributions',
                'CONTRIBUTION_STABLE_ORDER_KEY_DUPLICATE',
                { index = index, stable_order_key = contribution.stable_order_key }
            )
        end
        if previous_priority ~= nil
            and (contribution.priority < previous_priority
                or (contribution.priority == previous_priority
                    and contribution.stable_order_key <= previous_stable_order_key))
        then
            return Validation.invalid(
                contract,
                'formation_contributions',
                'CONTRIBUTION_ORDER_INVALID',
                { index = index }
            )
        end
        seen_stable_order_keys[contribution.stable_order_key] = true
        previous_priority = contribution.priority
        previous_stable_order_key = contribution.stable_order_key
    end
    return Result.ok(value)
end

Formation.is_dense_array = Ordered.is_dense_array

return Formation
