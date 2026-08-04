local Harness = require 'wzx.tests.harness'
local CombatAggregate = require 'wzx.domain.combat.combat_aggregate'
local MartialLoadoutRuntime = require 'wzx.domain.combat.martial_loadout_runtime'
local EffectCatalog = require 'wzx.config.schema.effects.catalog'
local StatusCollection = require 'wzx.domain.effects.status_collection'

local case = Harness.case
local assert = Harness.assert
local HASH_A = string.rep('a', 64)

local function stats(overrides)
    local value = {
        max_hp = 100,
        attack = 40,
        defense = 5,
        speed = 100,
        accuracy = 8000,
        evasion = 0,
        crit_chance_bp = 0,
        crit_damage_bp = 15000,
        crit_resist_bp = 0,
        block_chance_bp = 0,
        block_reduction_bp = 5000,
        damage_bonus_bp = 0,
        damage_reduction_bp = 0,
        healing_bonus_bp = 0,
        healing_received_bp = 0,
        max_qi = 100,
        initial_qi = 0,
        qi_gain_bp = 10000,
        effect_accuracy = 0,
        effect_resistance = 0,
    }
    if overrides ~= nil then
        local key
        local item
        for key, item in pairs(overrides) do
            value[key] = item
        end
    end
    return value
end

local function unmissable_damage(ratio_bp)
    return {
        damage_type = 'PHYSICAL',
        attack_ratio_bp = ratio_bp or 10000,
        flat_damage = 0,
        hit_mode = 'UNMISSABLE',
        variance_min_bp = 10000,
        variance_max_bp = 10000,
        can_crit = false,
        can_block = false,
        minimum_damage = 1,
    }
end

local function basic_loadout(overrides)
    overrides = overrides or {}
    return {
        basic_move = {
            move_id = overrides.move_id or 'move_basic_slash',
            qi_cost = overrides.qi_cost or 0,
            action_cooldown = overrides.action_cooldown or 0,
            on_hit_qi_gain = overrides.on_hit_qi_gain or 5,
            move_type = 'BASIC',
            damage = overrides.damage or unmissable_damage(10000),
            effect_bundle_id = overrides.effect_bundle_id,
        },
        active_moves = overrides.active_moves or {},
    }
end

local function combatant(side, actor_id, definition_id, position_index, overrides)
    overrides = overrides or {}
    return {
        actor_id = actor_id,
        definition_id = definition_id,
        side = side,
        position_index = position_index,
        level = 5,
        tags = side == 'ATTACKER' and { 'hero', 'human' } or { 'bandit', 'human' },
        stats = stats(overrides.stats),
        martial_loadout = overrides.martial_loadout or basic_loadout(),
        initial_status_ids = {},
        ai_profile_id = side == 'ATTACKER' and 'ai_story_player' or 'ai_bandit_melee',
        source_revision = 1,
        source_hash = HASH_A,
    }
end

local function snapshot(overrides)
    overrides = overrides or {}
    return {
        snapshot_schema_version = 1,
        rules_version = 1,
        combat_kind = overrides.combat_kind or 'PVE_ENCOUNTER',
        encounter_id = 'encounter_martial_bridge',
        attacker_formation = {
            members = overrides.attackers or {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 200, attack = 50, max_hp = 120, initial_qi = 50 },
                }),
            },
        },
        defender_formation = {
            members = overrides.defenders or {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 50, attack = 10, max_hp = 80, defense = 0 },
                }),
            },
        },
        environment_spec_id = nil,
        control_policy = overrides.control_policy or 'AUTO_ALL',
        seed = overrides.seed or 7,
        action_limit = overrides.action_limit or 99,
        event_budget = overrides.event_budget or 10000,
        source_hashes = {
            attacker = HASH_A,
            defender = HASH_A,
        },
        snapshot_hash = HASH_A,
    }
end

local function start_combat(overrides, effect_catalog)
    local input = {
        combat_id = 'cbt_martial',
        snapshot = snapshot(overrides),
    }
    if effect_catalog ~= nil then
        input.effect_catalog = effect_catalog
    end
    local started = CombatAggregate.start(input)
    assert.equal(started.ok, true, started.error and started.error.code or 'start combat')
    return started.value
end

local function advance(state, command_id)
    local advanced = CombatAggregate.apply_command(state, {
        command_id = command_id or 'cmd_advance',
        command_type = 'ADVANCE',
    })
    assert.equal(advanced.ok, true, advanced.error and advanced.error.code or 'advance')
    return advanced.value
end

local function first_move_selected(events, actor_id)
    local index
    for index = 1, #events do
        local event = events[index]
        if event.event_type == 'MoveSelected' then
            if actor_id == nil or event.payload.actor_id == actor_id then
                return event
            end
        end
    end
    return nil
end

local function has_event(events, event_type)
    local index
    for index = 1, #events do
        if events[index].event_type == event_type then
            return true
        end
    end
    return false
end

local function count_events(events, event_type)
    local count = 0
    local index
    for index = 1, #events do
        if events[index].event_type == event_type then
            count = count + 1
        end
    end
    return count
end

local function build_min_effect_catalog()
    local built = EffectCatalog.build({
        status_definitions = {
            {
                id = 'status_bleed',
                schema_version = 1,
                name_key = 'status.bleed.name',
                description_template_key = 'status.bleed.desc',
                polarity = 'DEBUFF',
                tags = { 'DOT' },
                stacking_mode = 'ADD_STACK',
                max_stacks = 5,
                base_duration = 3,
                duration_unit = 'OWNER_ACTIONS',
                refresh_policy = 'RESET_TO_BASE',
                dispel_category = 'MAGICAL',
                dispel_priority = 10,
            },
        },
        effect_bundles = {
            {
                id = 'effect_apply_bleed',
                schema_version = 1,
                nodes = {
                    {
                        node_id = 'apply',
                        operation = 'APPLY_STATUS',
                        status_id = 'status_bleed',
                        stacks = 1,
                        chance_bp = 10000,
                    },
                },
            },
        },
        status_triggers = {},
    })
    assert.equal(built.ok, true, built.error and built.error.code or 'catalog')
    return built.value
end

return {
    case('normalize prefers basic_move and keeps legacy basic_attack', function()
        local legacy = MartialLoadoutRuntime.normalize({
            basic_attack = {
                move_id = 'move_legacy_basic',
                qi_cost = 0,
                action_cooldown = 0,
                on_hit_qi_gain = 7,
                damage = unmissable_damage(5000),
            },
        })
        assert.equal(legacy.basic_move.move_id, 'move_legacy_basic')
        assert.equal(legacy.basic_move.move_type, 'BASIC')
        assert.equal(legacy.basic_move.on_hit_qi_gain, 7)
        assert.equal(#legacy.active_moves, 0)

        local modern = MartialLoadoutRuntime.normalize({
            basic_move = {
                move_id = 'move_modern_basic',
                qi_cost = 0,
                damage = unmissable_damage(10000),
            },
            basic_attack = {
                move_id = 'move_should_not_win',
                qi_cost = 0,
                damage = unmissable_damage(10000),
            },
            active_moves = {
                {
                    move_id = 'move_zeta',
                    qi_cost = 20,
                    action_cooldown = 2,
                    move_type = 'ACTIVE',
                    damage = unmissable_damage(12000),
                },
                {
                    move_id = 'move_alpha',
                    qi_cost = 10,
                    action_cooldown = 1,
                    effect_bundle_id = 'effect_apply_bleed',
                },
            },
        })
        assert.equal(modern.basic_move.move_id, 'move_modern_basic')
        assert.equal(#modern.active_moves, 2)
        -- active_moves sorted by move_id
        assert.equal(modern.active_moves[1].move_id, 'move_alpha')
        assert.equal(modern.active_moves[2].move_id, 'move_zeta')
        assert.equal(modern.active_moves[1].effect_bundle_id, 'effect_apply_bleed')
        assert.equal(modern.active_moves[1].damage, nil)
        assert.not_nil(modern.active_moves[2].damage)
    end),

    case('same seed combat with active loadout is deterministic', function()
        local loadout = basic_loadout({
            active_moves = {
                {
                    move_id = 'move_power_strike',
                    qi_cost = 20,
                    action_cooldown = 2,
                    move_type = 'ACTIVE',
                    damage = unmissable_damage(15000),
                },
            },
        })
        local overrides = {
            seed = 42,
            action_limit = 20,
            attackers = {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 200, attack = 40, max_hp = 100, initial_qi = 50 },
                    martial_loadout = loadout,
                }),
            },
            defenders = {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 40, attack = 5, max_hp = 200, defense = 0 },
                }),
            },
        }
        local a = start_combat(overrides)
        local b = start_combat(overrides)
        local ra = advance(a, 'cmd1')
        local rb = advance(b, 'cmd1')
        assert.equal(ra.result.outcome, rb.result.outcome)
        assert.equal(ra.result.event_hash, rb.result.event_hash)
        assert.equal(ra.result.prng_draw_count, rb.result.prng_draw_count)
        assert.equal(#a.events, #b.events)
        local index
        for index = 1, #a.events do
            assert.equal(a.events[index].event_type, b.events[index].event_type)
        end
    end),

    case('ACTIVE move preferred over BASIC when qi and cooldown allow', function()
        local state = start_combat({
            seed = 3,
            action_limit = 4,
            attackers = {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 300, attack = 30, max_hp = 100, initial_qi = 40 },
                    martial_loadout = basic_loadout({
                        move_id = 'move_basic_only',
                        active_moves = {
                            {
                                move_id = 'move_active_finisher',
                                qi_cost = 15,
                                action_cooldown = 3,
                                move_type = 'ACTIVE',
                                damage = unmissable_damage(20000),
                            },
                        },
                    }),
                }),
            },
            defenders = {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 10, attack = 1, max_hp = 500, defense = 0 },
                }),
            },
        })
        advance(state, 'cmd_active')
        local selected = first_move_selected(state.events, 'atk1')
        assert.not_nil(selected)
        assert.equal(selected.payload.move_id, 'move_active_finisher')
        assert.equal(selected.payload.move_type, 'ACTIVE')
        assert.equal(selected.payload.qi_cost, 15)
    end),

    case('falls back to BASIC when ACTIVE qi is insufficient', function()
        local state = start_combat({
            seed = 5,
            action_limit = 2,
            attackers = {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 300, attack = 30, max_hp = 100, initial_qi = 5 },
                    martial_loadout = basic_loadout({
                        move_id = 'move_basic_fallback',
                        active_moves = {
                            {
                                move_id = 'move_expensive_skill',
                                qi_cost = 50,
                                action_cooldown = 1,
                                move_type = 'ACTIVE',
                                damage = unmissable_damage(30000),
                            },
                        },
                    }),
                }),
            },
            defenders = {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 10, attack = 1, max_hp = 500, defense = 0 },
                }),
            },
        })
        advance(state, 'cmd_fallback')
        local selected = first_move_selected(state.events, 'atk1')
        assert.not_nil(selected)
        assert.equal(selected.payload.move_id, 'move_basic_fallback')
        assert.equal(selected.payload.move_type, 'BASIC')
    end),

    case('effect_catalog APPLY_STATUS attaches status on effect runtime', function()
        local catalog = build_min_effect_catalog()
        local state = start_combat({
            seed = 11,
            action_limit = 2,
            attackers = {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 300, attack = 20, max_hp = 100, initial_qi = 30 },
                    martial_loadout = basic_loadout({
                        move_id = 'move_basic_plain',
                        active_moves = {
                            {
                                move_id = 'move_bleed_blade',
                                qi_cost = 10,
                                action_cooldown = 2,
                                move_type = 'ACTIVE',
                                damage = unmissable_damage(5000),
                                effect_bundle_id = 'effect_apply_bleed',
                            },
                        },
                    }),
                }),
            },
            defenders = {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 10, attack = 1, max_hp = 200, defense = 0 },
                }),
            },
        }, catalog)

        assert.not_nil(state.effect_runtime)
        advance(state, 'cmd_effect')

        local selected = first_move_selected(state.events, 'atk1')
        assert.not_nil(selected)
        assert.equal(selected.payload.move_id, 'move_bleed_blade')
        assert.equal(has_event(state.events, 'EffectBundleResolved'), true)
        assert.equal(has_event(state.events, 'StatusApplied'), true)
        assert.equal(
            StatusCollection.owner_has_status(state.effect_runtime, 'def1', 'status_bleed', 1),
            true
        )
    end),

    case('effect_bundle_id without catalog is ignored without crash', function()
        local state = start_combat({
            seed = 13,
            action_limit = 2,
            attackers = {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 300, attack = 40, max_hp = 100, initial_qi = 30 },
                    martial_loadout = basic_loadout({
                        active_moves = {
                            {
                                move_id = 'move_with_orphan_bundle',
                                qi_cost = 5,
                                action_cooldown = 1,
                                move_type = 'ACTIVE',
                                damage = unmissable_damage(10000),
                                effect_bundle_id = 'effect_apply_bleed',
                            },
                        },
                    }),
                }),
            },
            defenders = {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 10, attack = 1, max_hp = 40, defense = 0 },
                }),
            },
        })
        assert.equal(state.effect_catalog, nil)
        local result = advance(state, 'cmd_no_catalog')
        assert.equal(result.finished, true)
        assert.equal(has_event(state.events, 'MoveSelected'), true)
        assert.equal(has_event(state.events, 'EffectBundleResolved'), false)
        assert.equal(has_event(state.events, 'StatusApplied'), false)
        assert.equal(count_events(state.events, 'DamageApplied') >= 1, true)
    end),

    case('legacy basic_attack shape still drives AUTO combat', function()
        local state = start_combat({
            seed = 17,
            action_limit = 10,
            attackers = {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 250, attack = 60, max_hp = 100 },
                    martial_loadout = {
                        basic_attack = {
                            move_id = 'move_legacy_auto',
                            qi_cost = 0,
                            action_cooldown = 0,
                            on_hit_qi_gain = 5,
                            damage = unmissable_damage(10000),
                        },
                    },
                }),
            },
            defenders = {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 20, attack = 5, max_hp = 50, defense = 0 },
                }),
            },
        })
        local result = advance(state, 'cmd_legacy')
        assert.equal(result.finished, true)
        local selected = first_move_selected(state.events, 'atk1')
        assert.not_nil(selected)
        assert.equal(selected.payload.move_id, 'move_legacy_auto')
        assert.equal(result.result.outcome, 'ATTACKER_WIN')
    end),
}
