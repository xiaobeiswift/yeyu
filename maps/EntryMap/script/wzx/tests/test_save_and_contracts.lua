local Harness = require 'wzx.tests.harness'
local CharacterBuildSnapshot = require 'wzx.domain.contracts.character_build_snapshot'
local CombatantSnapshot = require 'wzx.domain.contracts.combatant_snapshot'
local CombatSnapshot = require 'wzx.domain.contracts.combat_snapshot'
local Formation = require 'wzx.domain.contracts.formation'
local LightnessTraversalProfile = require 'wzx.domain.contracts.lightness_traversal_profile'
local RewardEntry = require 'wzx.domain.contracts.reward_entry'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'
local ContractValidation = require 'wzx.domain.contracts.validation'

local case = Harness.case
local assert = Harness.assert
local HASH_A = string.rep('a', 64)

local function slot_one_payload()
    return {
        manifest = {
            content_version = 'content-v1',
            rules_version = 1,
            foundation_contract_version = 1,
        },
        player_profile = {
            player_id = 'player-1',
        },
        settings_profile = {
            music_enabled = true,
        },
    }
end

local function save_envelope(payload)
    return {
        schema_version = 1,
        revision = 0,
        checkpoint_id = 'checkpoint:1',
        content_version = 'content-v1',
        owner_fingerprint = 'owner_v1_' .. HASH_A,
        payload_checksum = HASH_A,
        written_at = 0,
        payload = payload or slot_one_payload(),
    }
end

local function combat_stats()
    return {
        max_hp = 1000,
        attack = 100,
        defense = 50,
        speed = 100,
        accuracy = 8000,
        evasion = 500,
        crit_chance_bp = 1000,
        crit_damage_bp = 15000,
        crit_resist_bp = 0,
        block_chance_bp = 0,
        block_reduction_bp = 0,
        damage_bonus_bp = 0,
        damage_reduction_bp = 0,
        healing_bonus_bp = 0,
        healing_received_bp = 0,
        max_qi = 1000,
        initial_qi = 0,
        qi_gain_bp = 10000,
        effect_accuracy = 1000,
        effect_resistance = 1000,
    }
end

local function combatant(side, actor_id, definition_id, position_index)
    local attacker = side == 'ATTACKER'
    return {
        actor_id = actor_id,
        definition_id = definition_id,
        side = side,
        position_index = position_index,
        level = 10,
        tags = attacker and { 'hero', 'human' } or { 'bandit', 'human' },
        stats = combat_stats(),
        martial_loadout = {
            inner_id = attacker and 'martial_still_water' or 'martial_bandit_breath',
            routine_id = attacker and 'martial_cloud_sword' or 'martial_bandit_blade',
        },
        initial_status_ids = attacker
            and { 'status_guarded', 'status_ready' }
            or { 'status_ready' },
        ai_profile_id = attacker and 'ai_story_player' or 'ai_bandit_melee',
        source_revision = 3,
        source_hash = HASH_A,
    }
end

local function contribution()
    return {
        source_type = 'EQUIPMENT',
        source_id = 'equipment:sword:1',
        target_stat = 'attack',
        operation = 'ADD_FLAT',
        value = 120,
        priority = 10,
        condition_tags = { 'boss', 'night' },
        stable_order_key = '10:equipment:sword:1',
    }
end

local function build(character_id)
    return {
        schema_version = 1,
        character_id = character_id,
        definition_version = 1,
        level = 10,
        awakening_rank = 0,
        talent_entries = {
            { talent_id = 'talent_brave' },
            { talent_id = 'talent_calm' },
        },
        equipment_snapshot = {},
        martial_snapshot = {},
        progression_snapshot = {},
        character_revision = 3,
        rules_version = 1,
        source_hashes = {
            character_definition = HASH_A,
        },
        build_hash = HASH_A,
    }
end

local function formation()
    return {
        party_context = 'PVE_MAIN',
        leader_character_id = 'char_hero',
        member_rows = {
            {
                character_id = 'char_hero',
                position_index = 0,
                entry_order = 1,
                role_tag_override = 'FRONTLINE',
            },
            {
                character_id = 'char_partner',
                position_index = 1,
                entry_order = 2,
                role_tag_override = 'DAMAGE',
            },
        },
        formation_template_id = 'formation_default',
        active_preset_id = 'preset_party_main',
        is_dirty_from_preset = false,
        revision = 2,
    }
end

local function combat_snapshot(kind, control_policy)
    return {
        snapshot_schema_version = 1,
        rules_version = 1,
        combat_kind = kind,
        encounter_id = 'encounter_bridge_bandits',
        attacker_formation = {
            members = {
                combatant('ATTACKER', 'combat001:attacker1', 'char_hero', 0),
            },
        },
        defender_formation = {
            members = {
                combatant('DEFENDER', 'combat001:defender1', 'enemy_bandit', 0),
            },
        },
        environment_spec_id = 'environment_bridge',
        control_policy = control_policy,
        seed = 1,
        action_limit = 99,
        event_budget = 1000,
        source_hashes = {
            encounter = HASH_A,
            formation = HASH_A,
        },
        snapshot_hash = HASH_A,
    }
end

local function jump_capability(capability_id)
    return {
        capability_id = capability_id or 'JUMP_BASIC',
        rank = 1,
        jump_range_cells = 3,
        water_range_cells = 0,
        max_rise_levels = 1,
        max_drop_levels = 2,
        max_route_cost = 5,
        movement_speed_bp = 10000,
    }
end

local function water_capability()
    return {
        capability_id = 'WATER_WALK',
        rank = 1,
        jump_range_cells = 0,
        water_range_cells = 4,
        max_rise_levels = 0,
        max_drop_levels = 0,
        max_route_cost = 0,
        movement_speed_bp = 10000,
    }
end

local function traversal_profile(capabilities)
    return {
        character_id = 'char_hero',
        source_martial_id = 'martial_cloud_step',
        source_martial_level = 5,
        source_loadout_revision = 2,
        source_progress_revision = 3,
        rules_version = 1,
        capability_specs = capabilities,
        range_query_radius_cells = 8,
        presentation_profile_id = 'traversal_presentation_cloud_step',
        profile_hash = HASH_A,
    }
end

return {
    case('save envelope accepts exactly three serializable payload levels', function()
        local valid = save_envelope({ first = { second = { value = 1 } } })
        assert.equal(SaveEnvelope.validate(valid).ok, true)

        local too_deep = save_envelope({ first = { second = { third = { value = 1 } } } })
        local validated = SaveEnvelope.validate(too_deep)
        assert.error_code(validated, 'SAVE_ENVELOPE_INVALID')
        assert.error_reason(validated, 'PAYLOAD_INVALID')
        assert.equal(
            validated.error.details.cause.details.reason,
            'MAXIMUM_TABLE_DEPTH_EXCEEDED'
        )

        local cycle = {}
        cycle.self = cycle
        validated = SaveEnvelope.validate(save_envelope(cycle))
        assert.error_reason(validated, 'PAYLOAD_INVALID')
        assert.equal(validated.error.details.cause.details.reason, 'TABLE_CYCLE_DETECTED')

        validated = SaveEnvelope.validate(save_envelope('scalar-payload'))
        assert.error_reason(validated, 'TABLE_REQUIRED')
    end),

    case('slot one requires manifest, player profile, and settings only', function()
        local payload = slot_one_payload()
        assert.equal(SaveEnvelope.validate_slot_one_payload(payload).ok, true)
        assert.equal(SaveEnvelope.validate(save_envelope(payload)).ok, true)

        payload.settings_profile = nil
        assert.error_reason(
            SaveEnvelope.validate_slot_one_payload(payload),
            'SECTION_TABLE_REQUIRED'
        )

        payload = slot_one_payload()
        payload.unowned_section = {}
        assert.error_reason(
            SaveEnvelope.validate_slot_one_payload(payload),
            'UNKNOWN_SLOT_ONE_SECTION'
        )
    end),

    case('save envelope rejects malformed metadata and returns isolated copies', function()
        local envelope = save_envelope()
        envelope.payload_checksum = 'ABC'
        assert.error_reason(SaveEnvelope.validate(envelope), 'SHA256_HEX_REQUIRED')

        envelope = save_envelope()
        envelope.owner_fingerprint = 'owner-fingerprint-v1'
        assert.error_reason(
            SaveEnvelope.validate(envelope),
            'OWNER_FINGERPRINT_V1_REQUIRED'
        )

        envelope = save_envelope()
        envelope.unexpected = true
        assert.error_reason(SaveEnvelope.validate(envelope), 'UNKNOWN_FIELD')

        envelope = save_envelope()
        local copied = SaveEnvelope.copy(envelope)
        assert.equal(copied.ok, true)
        assert.truthy(copied.value ~= envelope)
        assert.truthy(copied.value.payload ~= envelope.payload)
        copied.value.payload.player_profile.player_id = 'changed'
        assert.equal(envelope.payload.player_profile.player_id, 'player-1')
    end),

    case('stat contributions enforce enums, ranges, and stable tag order', function()
        assert.equal(StatContribution.validate(contribution()).ok, true)

        local invalid = contribution()
        invalid.source_type = 'UNKNOWN'
        assert.error_reason(StatContribution.validate(invalid), 'ENUM_VALUE_INVALID')

        invalid = contribution()
        invalid.value = 1000000001
        assert.error_reason(StatContribution.validate(invalid), 'INTEGER_OUT_OF_RANGE')

        invalid = contribution()
        invalid.condition_tags = { 'night', 'boss' }
        assert.error_reason(
            StatContribution.validate(invalid),
            'STRICT_ASCENDING_ORDER_REQUIRED'
        )

        invalid = contribution()
        invalid.unknown = true
        assert.error_reason(StatContribution.validate(invalid), 'UNKNOWN_FIELD')

        local source_320 = string.rep('a', 96)
            .. ':' .. string.rep('b', 96)
            .. ':' .. string.rep('c', 96)
            .. ':' .. string.rep('d', 29)
        local stable_512 = string.rep('a', 96)
            .. ':' .. string.rep('b', 96)
            .. ':' .. string.rep('c', 96)
            .. ':' .. string.rep('d', 96)
            .. ':' .. string.rep('e', 96)
            .. ':' .. string.rep('f', 27)
        local boundary = contribution()
        boundary.source_id = source_320
        boundary.stable_order_key = stable_512
        assert.equal(StatContribution.validate(boundary).ok, true)

        boundary.source_id = source_320 .. 'd'
        assert.error_reason(StatContribution.validate(boundary), 'SOURCE_REFERENCE_INVALID')
        boundary.source_id = source_320
        boundary.stable_order_key = stable_512 .. 'f'
        assert.error_reason(StatContribution.validate(boundary), 'STABLE_ORDER_KEY_INVALID')

        boundary = contribution()
        boundary.source_id = string.rep('a', 65)
        assert.equal(StatContribution.validate(boundary).ok, true)
        boundary.source_id = string.rep('a', 96)
        assert.equal(StatContribution.validate(boundary).ok, true)
        boundary.source_id = string.rep('a', 97)
        assert.error_reason(StatContribution.validate(boundary), 'SOURCE_REFERENCE_INVALID')
        boundary.source_id = 'foo:-bar'
        assert.error_reason(StatContribution.validate(boundary), 'SOURCE_REFERENCE_INVALID')
    end),

    case('character builds and formations enforce identity and membership basics', function()
        assert.equal(CharacterBuildSnapshot.validate(build('char_hero')).ok, true)
        assert.equal(Formation.validate(formation()).ok, true)

        local invalid_build = build('char_hero')
        invalid_build.talent_entries = {
            { talent_id = 'talent_calm' },
            { talent_id = 'talent_brave' },
        }
        assert.error_reason(
            CharacterBuildSnapshot.validate(invalid_build),
            'TALENT_ORDER_INVALID'
        )

        invalid_build = build('char_hero')
        invalid_build.equipment_snapshot = 'equipment_scalar'
        assert.error_reason(
            CharacterBuildSnapshot.validate(invalid_build),
            'TABLE_REQUIRED'
        )

        invalid_build = build('char_hero')
        invalid_build.martial_snapshot = false
        assert.error_reason(
            CharacterBuildSnapshot.validate(invalid_build),
            'TABLE_REQUIRED'
        )

        invalid_build = build('char_hero')
        invalid_build.progression_snapshot = 7
        assert.error_reason(
            CharacterBuildSnapshot.validate(invalid_build),
            'TABLE_REQUIRED'
        )

        invalid_build = build('char_hero')
        invalid_build.talent_entries[1].rank = 1
        assert.error_reason(
            CharacterBuildSnapshot.validate(invalid_build),
            'UNKNOWN_FIELD'
        )

        invalid_build = build('char_hero')
        invalid_build.source_hashes.character_definition = 'ABC'
        assert.error_reason(
            CharacterBuildSnapshot.validate(invalid_build),
            'SHA256_HEX_REQUIRED'
        )

        local invalid = formation()
        invalid.member_rows[2].position_index = 0
        assert.error_reason(Formation.validate(invalid), 'DUPLICATE_CHARACTER_OR_POSITION')

        invalid = formation()
        invalid.leader_character_id = 'char_missing'
        assert.error_reason(Formation.validate(invalid), 'LEADER_NOT_IN_FORMATION')
    end),

    case('formation combat input is ordered and carries validated builds', function()
        local input = {
            party_context = 'PVE_MAIN',
            formation_revision = 2,
            constraint_id = 'constraint_standard',
            formation_template_id = 'formation_default',
            leader_character_id = 'char_hero',
            member_snapshots = {
                { position_index = 0, build_snapshot = build('char_hero') },
                { position_index = 1, build_snapshot = build('char_partner') },
            },
            formation_contributions = { contribution() },
            source_revision_map = { character = 3, formation = 2 },
            rules_version = 1,
            normalized_hash_input = HASH_A,
        }
        assert.equal(Formation.validate_combat_input(input).ok, true)

        local second_contribution = contribution()
        second_contribution.source_id = 'equipment:sword:2'
        second_contribution.priority = 11
        second_contribution.stable_order_key = '11:equipment:sword:2'
        input.formation_contributions = { contribution(), second_contribution }
        assert.equal(Formation.validate_combat_input(input).ok, true)

        second_contribution.priority = 9
        assert.error_reason(
            Formation.validate_combat_input(input),
            'CONTRIBUTION_ORDER_INVALID'
        )

        second_contribution.priority = 11
        second_contribution.stable_order_key = input.formation_contributions[1].stable_order_key
        assert.error_reason(
            Formation.validate_combat_input(input),
            'CONTRIBUTION_STABLE_ORDER_KEY_DUPLICATE'
        )

        input.formation_contributions = { contribution() }
        input.source_revision_map.character = -1
        assert.error_reason(
            Formation.validate_combat_input(input),
            'NON_NEGATIVE_INTEGER_REQUIRED'
        )
        input.source_revision_map.character = 3

        input.member_snapshots[1], input.member_snapshots[2]
            = input.member_snapshots[2], input.member_snapshots[1]
        assert.error_reason(
            Formation.validate_combat_input(input),
            'MEMBER_ORDER_INVALID'
        )
    end),

    case('arena combat snapshots require full automation', function()
        local snapshot = combat_snapshot('PVE_STORY', 'MANUAL_ULTIMATE')
        assert.equal(
            CombatantSnapshot.validate(snapshot.attacker_formation.members[1], 'ATTACKER').ok,
            true
        )
        assert.equal(
            CombatSnapshot.validate(snapshot).ok,
            true
        )
        assert.equal(
            CombatSnapshot.validate(combat_snapshot('ARENA_RANKED', 'AUTO_ALL')).ok,
            true
        )

        local manual_arena = combat_snapshot('ARENA_PRACTICE', 'MANUAL_ULTIMATE')
        assert.error_reason(
            CombatSnapshot.validate(manual_arena),
            'ARENA_REQUIRES_AUTO_ALL'
        )

        local over_limit = combat_snapshot('PVE_BOSS', 'AUTO_ALL')
        over_limit.action_limit = 100
        assert.error_reason(CombatSnapshot.validate(over_limit), 'INTEGER_OUT_OF_RANGE')

        local over_budget = combat_snapshot('PVE_BOSS', 'AUTO_ALL')
        over_budget.event_budget = 101
        assert.error_reason(CombatSnapshot.validate(over_budget, 100), 'INTEGER_OUT_OF_RANGE')

        local invalid_hash = combat_snapshot('PVE_BOSS', 'AUTO_ALL')
        invalid_hash.source_hashes.encounter = 'ABC'
        assert.error_reason(
            CombatSnapshot.validate(invalid_hash),
            'SHA256_HEX_REQUIRED'
        )

        invalid_hash = combat_snapshot('PVE_BOSS', 'AUTO_ALL')
        invalid_hash.source_hashes = 'not-a-map'
        assert.error_reason(CombatSnapshot.validate(invalid_hash), 'MAP_REQUIRED')

        local wrong_side = combat_snapshot('PVE_STORY', 'AUTO_ALL')
        wrong_side.attacker_formation.members[1].side = 'DEFENDER'
        assert.error_reason(CombatSnapshot.validate(wrong_side), 'COMBATANT_INVALID')

        local duplicate_actor = combat_snapshot('PVE_STORY', 'AUTO_ALL')
        duplicate_actor.defender_formation.members[1].actor_id =
            duplicate_actor.attacker_formation.members[1].actor_id
        assert.error_reason(
            CombatSnapshot.validate(duplicate_actor),
            'ACTOR_ID_NOT_COMBAT_UNIQUE'
        )
    end),

    case('reward entries enforce character and unlock metadata requirements', function()
        local currency = {
            entry_type = 'CURRENCY',
            target_id = 'currency_copper',
            quantity = 100,
            metadata = {},
            entry_order = 1,
        }
        assert.equal(RewardEntry.validate(currency).ok, true)

        local experience = {
            entry_type = 'CHARACTER_XP',
            target_id = 'char_hero',
            quantity = 10,
            metadata = {},
            entry_order = 1,
        }
        assert.error_reason(RewardEntry.validate(experience), 'CHARACTER_TARGET_REQUIRED')
        experience.target_character_id = 'char_hero'
        assert.equal(RewardEntry.validate(experience).ok, true)
        experience.target_character_id = 'char_other'
        assert.error_reason(
            RewardEntry.validate(experience),
            'CHARACTER_TARGET_MISMATCH'
        )
        experience.target_character_id = 'char_hero'

        local affinity = {
            entry_type = 'AFFINITY',
            target_id = 'char_partner',
            target_character_id = 'char_other',
            quantity = 1,
            metadata = {},
            entry_order = 2,
        }
        assert.error_reason(
            RewardEntry.validate(affinity),
            'CHARACTER_TARGET_MISMATCH'
        )

        local unlock = {
            entry_type = 'UNLOCK_FLAG',
            target_id = 'flag_bridge_open',
            quantity = 1,
            metadata = {},
            entry_order = 1,
        }
        assert.error_reason(RewardEntry.validate(unlock), 'OWNER_TYPE_REQUIRED')
        unlock.metadata.owner_type = 'world'
        assert.equal(RewardEntry.validate(unlock).ok, true)

        currency.metadata = { nested = {} }
        assert.error_reason(RewardEntry.validate(currency), 'SCALAR_REQUIRED')
    end),

    case('reward entry types enforce exact target prefixes and 96-byte IDs', function()
        local entries = {
            {
                entry_type = 'CURRENCY',
                target_id = 'currency_copper',
            },
            {
                entry_type = 'ITEM',
                target_id = 'item_medicinal_herb',
            },
            {
                entry_type = 'EQUIPMENT',
                target_id = 'equip_iron_sword',
            },
            {
                entry_type = 'CHARACTER_XP',
                target_id = 'char_hero',
                target_character_id = 'char_hero',
            },
            {
                entry_type = 'MARTIAL_XP',
                target_id = 'martial_cloud_step',
                target_character_id = 'char_hero',
            },
            {
                entry_type = 'AFFINITY',
                target_id = 'char_partner',
                target_character_id = 'char_partner',
            },
            {
                entry_type = 'UNLOCK_FLAG',
                target_id = 'flag_bridge_open',
                metadata = { owner_type = 'world' },
            },
        }
        local index
        for index = 1, #entries do
            local entry = entries[index]
            entry.quantity = 1
            entry.metadata = entry.metadata or {}
            entry.entry_order = index
            assert.equal(RewardEntry.validate(entry).ok, true)
        end

        local mismatch = {
            entry_type = 'ITEM',
            target_id = 'currency_copper',
            quantity = 1,
            metadata = {},
            entry_order = 1,
        }
        assert.error_reason(RewardEntry.validate(mismatch), 'TARGET_ID_PREFIX_INVALID')

        local boundary = {
            entry_type = 'ITEM',
            target_id = 'item_' .. string.rep('a', 91),
            quantity = 1,
            metadata = {},
            entry_order = 1,
        }
        assert.equal(#boundary.target_id, 96)
        assert.equal(RewardEntry.validate(boundary).ok, true)
        boundary.target_id = boundary.target_id .. 'a'
        assert.error_reason(RewardEntry.validate(boundary), 'TARGET_ID_PREFIX_INVALID')
    end),

    case('reward entries retain captured validation authorities', function()
        local original_result_ok = Result.ok
        local original_validate_content = RuntimeId.validate_content
        local original_enum = ContractValidation.enum
        local original_first = ContractValidation.first
        local original_flat_map = ContractValidation.flat_map
        local original_identifier = ContractValidation.identifier
        local original_integer = ContractValidation.integer
        local original_invalid = ContractValidation.invalid
        local original_no_unknown_fields = ContractValidation.no_unknown_fields
        local monkeypatch_calls = 0
        local function forbidden_patch()
            monkeypatch_calls = monkeypatch_calls + 1
            error('captured reward authority was bypassed')
        end

        Result.ok = forbidden_patch
        RuntimeId.validate_content = forbidden_patch
        ContractValidation.enum = forbidden_patch
        ContractValidation.first = forbidden_patch
        ContractValidation.flat_map = forbidden_patch
        ContractValidation.identifier = forbidden_patch
        ContractValidation.integer = forbidden_patch
        ContractValidation.invalid = forbidden_patch
        ContractValidation.no_unknown_fields = forbidden_patch

        local call_ok, valid, mismatch, unknown = pcall(function()
            local entry = {
                entry_type = 'CHARACTER_XP',
                target_id = 'char_hero',
                target_character_id = 'char_hero',
                quantity = 10,
                metadata = {},
                entry_order = 1,
            }
            local valid_result = RewardEntry.validate(entry)
            entry.target_character_id = 'char_other'
            local mismatch_result = RewardEntry.validate(entry)
            entry.target_character_id = 'char_hero'
            entry.unexpected = true
            return valid_result, mismatch_result, RewardEntry.validate(entry)
        end)

        Result.ok = original_result_ok
        RuntimeId.validate_content = original_validate_content
        ContractValidation.enum = original_enum
        ContractValidation.first = original_first
        ContractValidation.flat_map = original_flat_map
        ContractValidation.identifier = original_identifier
        ContractValidation.integer = original_integer
        ContractValidation.invalid = original_invalid
        ContractValidation.no_unknown_fields = original_no_unknown_fields

        assert.equal(call_ok, true)
        assert.equal(valid.ok, true)
        assert.error_reason(mismatch, 'CHARACTER_TARGET_MISMATCH')
        assert.error_reason(unknown, 'UNKNOWN_FIELD')
        assert.equal(monkeypatch_calls, 0)
    end),

    case('lightness capabilities require canonical order and jump dependencies', function()
        local basic = jump_capability('JUMP_BASIC')
        local long = jump_capability('JUMP_LONG')
        long.jump_range_cells = 5
        local profile = traversal_profile({ basic, long, water_capability() })
        assert.equal(LightnessTraversalProfile.validate(profile).ok, true)

        profile.range_query_radius_cells = 4
        assert.error_reason(
            LightnessTraversalProfile.validate(profile),
            'QUERY_RADIUS_TOO_SMALL'
        )

        profile = traversal_profile({ jump_capability('JUMP_LONG') })
        assert.error_reason(
            LightnessTraversalProfile.validate(profile),
            'JUMP_BASIC_DEPENDENCY_MISSING'
        )

        profile = traversal_profile({ water_capability(), jump_capability('JUMP_BASIC') })
        assert.error_reason(
            LightnessTraversalProfile.validate(profile),
            'CAPABILITY_ORDER_INVALID'
        )

        profile = traversal_profile({
            jump_capability('JUMP_BASIC'),
            jump_capability('JUMP_BASIC'),
        })
        assert.error_reason(
            LightnessTraversalProfile.validate(profile),
            'CAPABILITY_ORDER_INVALID'
        )
    end),

    case('jump and water-walk capability fields cannot leak into each other', function()
        local water = water_capability()
        water.jump_range_cells = 1
        assert.error_reason(
            LightnessTraversalProfile.validate(traversal_profile({ water })),
            'WATER_WALK_FIELDS_INVALID'
        )

        local jump = jump_capability('JUMP_BASIC')
        jump.water_range_cells = 1
        assert.error_reason(
            LightnessTraversalProfile.validate(traversal_profile({ jump })),
            'JUMP_FIELDS_INVALID'
        )

        local empty = traversal_profile({})
        empty.source_martial_id = nil
        empty.source_martial_level = 0
        assert.equal(LightnessTraversalProfile.validate(empty).ok, true)

        empty.capability_specs = { jump_capability('JUMP_BASIC') }
        assert.error_reason(
            LightnessTraversalProfile.validate(empty),
            'EMPTY_MARTIAL_MUST_HAVE_NO_CAPABILITIES'
        )
    end),
}
