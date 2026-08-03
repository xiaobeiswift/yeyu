local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Validation = require 'wzx.domain.contracts.validation'

local CombatantSnapshot = {}

local CONTRACT = 'CombatantSnapshotV1'
local FIELDS = {
    actor_id = true,
    definition_id = true,
    side = true,
    position_index = true,
    level = true,
    tags = true,
    stats = true,
    martial_loadout = true,
    initial_status_ids = true,
    ai_profile_id = true,
    source_revision = true,
    source_hash = true,
}
local SIDES = {
    ATTACKER = true,
    DEFENDER = true,
}
local STAT_RANGES = {
    max_hp = { 1, 2000000000 },
    attack = { 1, 10000000 },
    defense = { 0, 10000000 },
    speed = { 1, 100000 },
    accuracy = { 0, 10000 },
    evasion = { 0, 10000 },
    crit_chance_bp = { 0, 7500 },
    crit_damage_bp = { 10000, 30000 },
    crit_resist_bp = { 0, 7500 },
    block_chance_bp = { 0, 7500 },
    block_reduction_bp = { 0, 8000 },
    damage_bonus_bp = { -9000, 50000 },
    damage_reduction_bp = { -50000, 9000 },
    healing_bonus_bp = { -9000, 50000 },
    healing_received_bp = { -9000, 50000 },
    max_qi = { 100, 2000 },
    initial_qi = { 0, 2000 },
    qi_gain_bp = { 0, 50000 },
    effect_accuracy = { 0, 10000 },
    effect_resistance = { 0, 10000 },
}

local function validate_definition_id(value)
    local character = RuntimeId.validate_content(value, 'char_', 'definition_id')
    if character.ok then
        return nil
    end
    local enemy = RuntimeId.validate_content(value, 'enemy_', 'definition_id')
    if enemy.ok then
        return nil
    end
    return Validation.invalid(CONTRACT, 'definition_id', 'CHARACTER_OR_ENEMY_ID_REQUIRED')
end

local function validate_stats(stats)
    local err = Validation.no_unknown_fields(CONTRACT, stats, STAT_RANGES)
    if err ~= nil then
        return err
    end
    local stat_names = {
        'max_hp', 'attack', 'defense', 'speed', 'accuracy', 'evasion',
        'crit_chance_bp', 'crit_damage_bp', 'crit_resist_bp',
        'block_chance_bp', 'block_reduction_bp', 'damage_bonus_bp',
        'damage_reduction_bp', 'healing_bonus_bp', 'healing_received_bp',
        'max_qi', 'initial_qi', 'qi_gain_bp', 'effect_accuracy',
        'effect_resistance',
    }
    local index
    for index = 1, #stat_names do
        local name = stat_names[index]
        local range = STAT_RANGES[name]
        err = Validation.integer(CONTRACT, 'stats.' .. name, stats[name], range[1], range[2])
        if err ~= nil then
            return err
        end
    end
    if stats.initial_qi > stats.max_qi then
        return Validation.invalid(CONTRACT, 'stats.initial_qi', 'INITIAL_QI_EXCEEDS_MAX_QI')
    end
    return nil
end

function CombatantSnapshot.validate(value, expected_side)
    local err = Validation.no_unknown_fields(CONTRACT, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.identifier(CONTRACT, 'actor_id', value.actor_id),
        validate_definition_id(value.definition_id),
        Validation.enum(CONTRACT, 'side', value.side, SIDES),
        Validation.integer(CONTRACT, 'position_index', value.position_index, 0, 8),
        Validation.integer(CONTRACT, 'level', value.level, 1, 100),
        Validation.sorted_unique_strings(CONTRACT, 'tags', value.tags),
        validate_stats(value.stats),
        Validation.serializable(CONTRACT, 'martial_loadout', value.martial_loadout, 5),
        Validation.sorted_unique_strings(CONTRACT, 'initial_status_ids', value.initial_status_ids),
        Validation.identifier(CONTRACT, 'ai_profile_id', value.ai_profile_id, 'ai_'),
        Validation.integer(CONTRACT, 'source_revision', value.source_revision, 0),
        Validation.hash(CONTRACT, 'source_hash', value.source_hash)
    )
    if err ~= nil then
        return err
    end
    if type(value.martial_loadout) ~= 'table' then
        return Validation.invalid(CONTRACT, 'martial_loadout', 'TABLE_REQUIRED')
    end
    local index
    for index = 1, #value.initial_status_ids do
        err = Validation.identifier(
            CONTRACT,
            'initial_status_ids',
            value.initial_status_ids[index],
            'status_'
        )
        if err ~= nil then
            return err
        end
    end
    if expected_side ~= nil and value.side ~= expected_side then
        return Validation.invalid(CONTRACT, 'side', 'FORMATION_SIDE_MISMATCH', {
            expected = expected_side,
        })
    end
    return Result.ok(value)
end

return CombatantSnapshot
