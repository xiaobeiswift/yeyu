local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.domain.contracts.validation'
local CombatantSnapshot = require 'wzx.domain.contracts.combatant_snapshot'

local CombatSnapshot = {}

local CONTRACT = 'CombatSnapshotV1'
local FIELDS = {
    snapshot_schema_version = true,
    rules_version = true,
    combat_kind = true,
    encounter_id = true,
    attacker_formation = true,
    defender_formation = true,
    environment_spec_id = true,
    control_policy = true,
    seed = true,
    action_limit = true,
    event_budget = true,
    source_hashes = true,
    snapshot_hash = true,
}
local KINDS = {
    PVE_STORY = true,
    PVE_ENCOUNTER = true,
    PVE_BOSS = true,
    ARENA_PRACTICE = true,
    ARENA_RANKED = true,
}
local CONTROL_POLICIES = {
    MANUAL_ULTIMATE = true,
    AUTO_ALL = true,
}

local FORMATION_FIELDS = { members = true }

local function validate_side(name, side, expected_side)
    local err = Validation.no_unknown_fields(CONTRACT, side, FORMATION_FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.dense_array(CONTRACT, name .. '.members', side.members, 1, 4)
    if err ~= nil then
        return err
    end
    local actor_ids = {}
    local previous_position = -1
    local index
    for index = 1, #side.members do
        local member = side.members[index]
        local validated = CombatantSnapshot.validate(member, expected_side)
        if not validated.ok then
            return Validation.invalid(CONTRACT, name .. '.members', 'COMBATANT_INVALID', {
                index = index,
                cause = validated.error,
            })
        end
        if actor_ids[member.actor_id] or member.position_index <= previous_position then
            return Validation.invalid(CONTRACT, name .. '.members', 'ACTOR_OR_POSITION_ORDER_INVALID', {
                index = index,
            })
        end
        actor_ids[member.actor_id] = true
        previous_position = member.position_index
    end
    return nil
end

function CombatSnapshot.validate(value, maximum_event_budget)
    local err = Validation.no_unknown_fields(CONTRACT, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.integer(CONTRACT, 'snapshot_schema_version', value.snapshot_schema_version, 1),
        Validation.integer(CONTRACT, 'rules_version', value.rules_version, 1),
        Validation.enum(CONTRACT, 'combat_kind', value.combat_kind, KINDS),
        Validation.identifier(CONTRACT, 'encounter_id', value.encounter_id, 'encounter_'),
        validate_side('attacker_formation', value.attacker_formation, 'ATTACKER'),
        validate_side('defender_formation', value.defender_formation, 'DEFENDER'),
        Validation.identifier(CONTRACT, 'environment_spec_id', value.environment_spec_id, 'environment_', true),
        Validation.enum(CONTRACT, 'control_policy', value.control_policy, CONTROL_POLICIES),
        Validation.integer(CONTRACT, 'seed', value.seed, 1, 2147483646),
        Validation.integer(CONTRACT, 'action_limit', value.action_limit, 1, 99),
        Validation.integer(CONTRACT, 'event_budget', value.event_budget, 1, maximum_event_budget or 100000),
        Validation.hash_map(CONTRACT, 'source_hashes', value.source_hashes),
        Validation.hash(CONTRACT, 'snapshot_hash', value.snapshot_hash)
    )
    if err ~= nil then
        return err
    end
    if (value.combat_kind == 'ARENA_PRACTICE' or value.combat_kind == 'ARENA_RANKED')
        and value.control_policy ~= 'AUTO_ALL'
    then
        return Validation.invalid(CONTRACT, 'control_policy', 'ARENA_REQUIRES_AUTO_ALL')
    end
    local attacker_ids = {}
    local index
    for index = 1, #value.attacker_formation.members do
        attacker_ids[value.attacker_formation.members[index].actor_id] = true
    end
    for index = 1, #value.defender_formation.members do
        if attacker_ids[value.defender_formation.members[index].actor_id] then
            return Validation.invalid(CONTRACT, 'defender_formation.members', 'ACTOR_ID_NOT_COMBAT_UNIQUE', {
                index = index,
            })
        end
    end
    return Result.ok(value)
end

return CombatSnapshot
