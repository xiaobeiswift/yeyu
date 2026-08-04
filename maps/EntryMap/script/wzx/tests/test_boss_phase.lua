local Harness = require 'wzx.tests.harness'
local EncounterCatalog = require 'wzx.config.schema.encounter.catalog'
local BossPhase = require 'wzx.domain.encounter.boss_phase'
local EncounterRun = require 'wzx.domain.encounter.encounter_run'
local CombatAggregate = require 'wzx.domain.combat.combat_aggregate'

local case = Harness.case
local assert = Harness.assert

local function formula_basic()
    return {
        id = 'formula_enemy_basic',
        formula_version = 1,
        base_hp = 100,
        hp_per_level = 0,
        hp_per_constitution = 0,
        base_attack = 5,
        attack_per_level = 0,
        attack_per_strength = 0,
        attack_per_inner_power_milli = 0,
        base_defense = 0,
        defense_per_level = 0,
        defense_per_constitution = 0,
        base_speed = 50,
        speed_per_agility = 0,
        base_accuracy = 7000,
        accuracy_per_agility = 0,
        base_evasion = 0,
        evasion_per_agility = 0,
        base_max_qi = 100,
        max_qi_per_inner_power = 0,
        effect_accuracy_per_inner_power = 0,
        effect_resistance_per_constitution = 0,
    }
end

local function rank_multipliers()
    return {
        NORMAL = 10000,
        ELITE = 12000,
        BOSS = 10000,
        SUMMON = 8000,
        MECHANIC_OBJECT = 10000,
    }
end

local function basic_move(move_id, flat_damage)
    return {
        move_id = move_id,
        move_type = 'BASIC',
        qi_cost = 0,
        action_cooldown = 0,
        on_hit_qi_gain = 5,
        damage = {
            damage_type = 'PHYSICAL',
            attack_ratio_bp = 0,
            flat_damage = flat_damage or 1,
            hit_mode = 'UNMISSABLE',
            variance_min_bp = 10000,
            variance_max_bp = 10000,
            can_crit = false,
            can_block = false,
            minimum_damage = 1,
        },
    }
end

local function active_move(move_id, flat_damage)
    local move = basic_move(move_id, flat_damage)
    move.move_type = 'ACTIVE'
    move.qi_cost = 0
    return move
end

local function boss_catalog(mutate)
    local source = {
        enemy_stat_profiles = {
            {
                id = 'statprof_boss',
                schema_version = 1,
                rules_version = 1,
                base_primary = {
                    strength = 10,
                    constitution = 10,
                    agility = 4,
                    inner_power = 4,
                },
                growth_per_level_milli = {
                    strength = 0,
                    constitution = 0,
                    agility = 0,
                    inner_power = 0,
                },
                formula = formula_basic(),
                flat_combat_contributions = {},
                rank_multiplier_bp = rank_multipliers(),
                level_min = 1,
                level_max = 50,
                initial_qi = 0,
            },
        },
        enemy_move_sets = {
            {
                id = 'moveset_boss',
                schema_version = 1,
                rules_version = 1,
                basic_move = basic_move('move_boss_claw', 1),
                active_moves = {
                    active_move('move_boss_enrage_slam', 3),
                },
            },
        },
        enemy_definitions = {
            {
                id = 'enemy_river_boss',
                schema_version = 1,
                rules_version = 1,
                enemy_class = 'BOSS',
                display_name_key = 'enemy.river_boss.name',
                description_key = 'enemy.river_boss.desc',
                stat_profile_id = 'statprof_boss',
                move_set_id = 'moveset_boss',
                ai_profile_id = 'ai_boss_phase1',
                default_tags = { 'boss', 'human' },
                model_asset_id = 'asset_model_boss',
                portrait_asset_id = 'asset_portrait_boss',
            },
        },
        wave_definitions = {
            {
                id = 'wave_boss_1',
                schema_version = 1,
                rules_version = 1,
                wave_index = 1,
                spawn_rows = {
                    {
                        spawn_id = 'spawn_river_boss',
                        enemy_id = 'enemy_river_boss',
                        level = 10,
                        position_index = 4,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 1,
                    },
                },
                presentation_cue_id = 'cue_boss_wave',
            },
        },
        boss_phase_definitions = {
            {
                id = 'bossphase_river_1',
                schema_version = 1,
                rules_version = 1,
                phase_index = 1,
                trigger = 'HP_AT_OR_BELOW_BP',
                trigger_value = 10000,
                presentation_cue_id = 'cue_phase_1',
            },
            {
                id = 'bossphase_river_2',
                schema_version = 1,
                rules_version = 1,
                phase_index = 2,
                trigger = 'HP_AT_OR_BELOW_BP',
                trigger_value = 7000,
                add_move_ids = { 'move_boss_enrage_slam' },
                ai_profile_override_id = 'ai_boss_phase2',
                presentation_cue_id = 'cue_phase_2',
                mechanic_flag_updates = {
                    { flag_key = 'phase2', flag_value = 1 },
                },
            },
            {
                id = 'bossphase_river_3',
                schema_version = 1,
                rules_version = 1,
                phase_index = 3,
                trigger = 'HP_AT_OR_BELOW_BP',
                trigger_value = 3000,
                ai_profile_override_id = 'ai_boss_phase3',
                presentation_cue_id = 'cue_phase_3',
            },
        },
        boss_controller_definitions = {
            {
                id = 'bossctl_river',
                schema_version = 1,
                rules_version = 1,
                boss_spawn_id = 'spawn_river_boss',
                phase_ids = {
                    'bossphase_river_1',
                    'bossphase_river_2',
                    'bossphase_river_3',
                },
                enrage_action_index = 50,
                boss_bar_style_id = 'bossbar_river',
            },
        },
        encounter_definitions = {
            {
                id = 'encounter_river_boss',
                schema_version = 1,
                rules_version = 1,
                encounter_type = 'BOSS',
                name_key = 'encounter.river_boss.name',
                description_key = 'encounter.river_boss.desc',
                area_id = 'area_wutan',
                location_id = 'loc_river_01',
                wave_ids = { 'wave_boss_1' },
                boss_controller_id = 'bossctl_river',
                seed_policy = 'FIXED',
                fixed_seed = 7,
                first_clear_reward_bundle_id = 'reward_boss_first',
                completion_fact_id = 'fact_river_boss_cleared',
            },
        },
    }
    if mutate ~= nil then
        mutate(source)
    end
    return EncounterCatalog.seal(source)
end

local function hero_member(flat_damage)
    return {
        actor_id = 'hero_main',
        definition_id = 'char_hero',
        side = 'ATTACKER',
        position_index = 4,
        level = 10,
        tags = { 'hero' },
        stats = {
            max_hp = 500,
            attack = 40,
            defense = 0,
            speed = 200,
            accuracy = 9000,
            evasion = 0,
            crit_chance_bp = 0,
            crit_damage_bp = 15000,
            crit_resist_bp = 0,
            block_chance_bp = 0,
            block_reduction_bp = 0,
            damage_bonus_bp = 0,
            damage_reduction_bp = 0,
            healing_bonus_bp = 0,
            healing_received_bp = 0,
            max_qi = 100,
            initial_qi = 0,
            qi_gain_bp = 10000,
            effect_accuracy = 0,
            effect_resistance = 0,
        },
        martial_loadout = {
            basic_move = basic_move('move_hero_slash', flat_damage or 40),
            active_moves = {},
        },
        initial_status_ids = {},
        ai_profile_id = 'ai_hero',
        source_revision = 1,
        source_hash = string.rep('b', 64),
    }
end

return {
    case('catalog seals boss controller and sequential phases', function()
        local sealed = boss_catalog()
        assert.equal(sealed.ok, true, 'catalog seal')
        local controller = sealed.value:require_boss_controller('bossctl_river')
        assert.equal(controller.ok, true)
        assert.equal(#controller.value.phase_ids, 3)
        local phase2 = sealed.value:require_boss_phase('bossphase_river_2')
        assert.equal(phase2.ok, true)
        assert.equal(phase2.value.trigger_value, 7000)
    end),

    case('catalog rejects non-decreasing hp thresholds', function()
        local sealed = boss_catalog(function(source)
            source.boss_phase_definitions[3].trigger_value = 8000
        end)
        assert.equal(sealed.ok, false)
        assert.equal(sealed.error.details.reason, 'HP_THRESHOLD_NOT_DECREASING')
    end),

    case('catalog rejects boss encounter without controller', function()
        local sealed = boss_catalog(function(source)
            source.encounter_definitions[1].boss_controller_id = nil
        end)
        assert.equal(sealed.ok, false)
    end),

    case('pure runtime enters next phase once at threshold', function()
        local sealed = boss_catalog()
        assert.equal(sealed.ok, true)
        local runtime = sealed.value:build_boss_runtime(
            'bossctl_river',
            'run:spawn_river_boss',
            {}
        )
        assert.equal(runtime.ok, true)
        runtime = runtime.value
        assert.equal(runtime.current_phase_index, 1)

        local miss = BossPhase.try_enter_next(runtime, {
            current_hp = 80,
            max_hp = 100,
            boss_alive = true,
            action_index = 1,
        })
        assert.equal(miss.ok, true)
        assert.equal(miss.value.entered, false)
        assert.equal(runtime.current_phase_index, 1)

        local hit = BossPhase.try_enter_next(runtime, {
            current_hp = 70,
            max_hp = 100,
            boss_alive = true,
            action_index = 2,
        })
        assert.equal(hit.ok, true)
        assert.equal(hit.value.entered, true)
        assert.equal(hit.value.phase_index, 2)
        assert.equal(runtime.current_phase_index, 2)
        assert.equal(runtime.mechanic_flags.phase2, 1)

        local again = BossPhase.try_enter_next(runtime, {
            current_hp = 60,
            max_hp = 100,
            boss_alive = true,
            action_index = 3,
        })
        assert.equal(again.ok, true)
        assert.equal(again.value.entered, false)
        assert.equal(runtime.current_phase_index, 2)
    end),

    case('multi-threshold damage enters only one phase per evaluate', function()
        local sealed = boss_catalog()
        assert.equal(sealed.ok, true)
        local runtime = sealed.value:build_boss_runtime(
            'bossctl_river',
            'run:spawn_river_boss',
            {}
        )
        assert.equal(runtime.ok, true)
        runtime = runtime.value

        local first = BossPhase.try_enter_next(runtime, {
            current_hp = 20,
            max_hp = 100,
            boss_alive = true,
            action_index = 1,
        })
        assert.equal(first.ok, true)
        assert.equal(first.value.entered, true)
        assert.equal(first.value.phase_index, 2)
        assert.equal(runtime.current_phase_index, 2)

        local second = BossPhase.try_enter_next(runtime, {
            current_hp = 20,
            max_hp = 100,
            boss_alive = true,
            action_index = 1,
        })
        assert.equal(second.ok, true)
        assert.equal(second.value.entered, true)
        assert.equal(second.value.phase_index, 3)
        assert.equal(runtime.current_phase_index, 3)
    end),

    case('healing does not roll back entered phase', function()
        local sealed = boss_catalog()
        assert.equal(sealed.ok, true)
        local runtime = sealed.value:build_boss_runtime(
            'bossctl_river',
            'run:spawn_river_boss',
            {}
        )
        assert.equal(runtime.ok, true)
        runtime = runtime.value
        BossPhase.try_enter_next(runtime, {
            current_hp = 50,
            max_hp = 100,
            boss_alive = true,
            action_index = 1,
        })
        assert.equal(runtime.current_phase_index, 2)
        BossPhase.try_enter_next(runtime, {
            current_hp = 100,
            max_hp = 100,
            boss_alive = true,
            action_index = 2,
        })
        assert.equal(runtime.current_phase_index, 2)
        assert.equal(runtime.entered_phase_indexes[2], true)
    end),

    case('combat emits phase enter events and upgrades moves', function()
        local sealed = boss_catalog()
        assert.equal(sealed.ok, true)
        local catalog = sealed.value
        local prepared = EncounterRun.prepare(catalog, {
            encounter_id = 'encounter_river_boss',
            run_id = 'run_boss_01',
            start_receipt_id = 'rcpt_boss_01',
            attacker_members = { hero_member(40) },
            party_revision = 1,
            first_clear_already = false,
        })
        assert.equal(prepared.ok, true, 'prepare')
        local run = prepared.value
        assert.truthy(run.boss_runtime)
        assert.equal(run.boss_runtime.current_phase_index, 1)

        local activated = EncounterRun.activate_combat(run)
        assert.equal(activated.ok, true)
        local started = CombatAggregate.start({
            combat_id = run.combat_id,
            snapshot = run.combat_snapshot,
            boss_runtime = run.boss_runtime,
        })
        assert.equal(started.ok, true, 'combat start')
        local state = started.value

        local phase_events = 0
        local index
        for index = 1, #state.events do
            if state.events[index].event_type == 'BossPhaseEntered' then
                phase_events = phase_events + 1
            end
        end
        assert.equal(phase_events, 1)

        local advanced = CombatAggregate.apply_command(state, {
            command_id = 'cmd_advance_1',
            command_type = 'ADVANCE',
            combat_id = run.combat_id,
        })
        assert.equal(advanced.ok, true, 'advance')
        assert.equal(advanced.value.finished, true)
        assert.equal(advanced.value.result.outcome, 'ATTACKER_WIN')

        local entered = {}
        for index = 1, #state.events do
            local event = state.events[index]
            if event.event_type == 'BossPhaseEntered' then
                entered[#entered + 1] = event.payload.phase_index
            end
        end
        assert.equal(#entered >= 2, true, 'expected multi phase enter')
        assert.equal(entered[1], 1)
        assert.equal(state.boss_runtime.current_phase_index, 3)

        local view = CombatAggregate.get_public_view(state)
        assert.equal(view.ok, true)
        assert.equal(view.value.boss.current_phase_index, 3)
        assert.equal(view.value.boss.enraged, false)
    end),

    case('same seed boss combat is deterministic including phase events', function()
        local sealed = boss_catalog()
        assert.equal(sealed.ok, true)
        local catalog = sealed.value

        local function run_once()
            local prepared = EncounterRun.prepare(catalog, {
                encounter_id = 'encounter_river_boss',
                run_id = 'run_boss_det',
                start_receipt_id = 'rcpt_boss_det',
                attacker_members = { hero_member(40) },
                party_revision = 1,
            })
            assert.equal(prepared.ok, true)
            local run = prepared.value
            EncounterRun.activate_combat(run)
            local started = CombatAggregate.start({
                combat_id = run.combat_id,
                snapshot = run.combat_snapshot,
                boss_runtime = run.boss_runtime,
            })
            assert.equal(started.ok, true)
            local state = started.value
            local advanced = CombatAggregate.apply_command(state, {
                command_id = 'cmd_det',
                command_type = 'ADVANCE',
                combat_id = run.combat_id,
            })
            assert.equal(advanced.ok, true)
            local trace = {}
            local index
            for index = 1, #state.events do
                local event = state.events[index]
                if event.event_type == 'BossPhaseEntered' then
                    trace[#trace + 1] = event.payload.phase_id
                end
            end
            return advanced.value.result.event_hash, table.concat(trace, ',')
        end

        local hash_a, trace_a = run_once()
        local hash_b, trace_b = run_once()
        assert.equal(hash_a, hash_b)
        assert.equal(trace_a, trace_b)
    end),

    case('action-index phase and enrage fire at safe boundary', function()
        local sealed = boss_catalog(function(source)
            source.boss_phase_definitions = {
                {
                    id = 'bossphase_river_1',
                    schema_version = 1,
                    rules_version = 1,
                    phase_index = 1,
                    trigger = 'HP_AT_OR_BELOW_BP',
                    trigger_value = 10000,
                    presentation_cue_id = 'cue_phase_1',
                },
                {
                    id = 'bossphase_river_2',
                    schema_version = 1,
                    rules_version = 1,
                    phase_index = 2,
                    trigger = 'ACTION_INDEX',
                    trigger_value = 2,
                    presentation_cue_id = 'cue_phase_action',
                },
            }
            source.boss_controller_definitions[1].phase_ids = {
                'bossphase_river_1',
                'bossphase_river_2',
            }
            source.boss_controller_definitions[1].enrage_action_index = 2
        end)
        assert.equal(sealed.ok, true, 'action phase catalog')
        local catalog = sealed.value
        local hero = hero_member(5)
        hero.stats.attack = 1

        local prepared = EncounterRun.prepare(catalog, {
            encounter_id = 'encounter_river_boss',
            run_id = 'run_boss_action',
            start_receipt_id = 'rcpt_boss_action',
            attacker_members = { hero },
            party_revision = 1,
        })
        assert.equal(prepared.ok, true)
        local run = prepared.value
        EncounterRun.activate_combat(run)
        local started = CombatAggregate.start({
            combat_id = run.combat_id,
            snapshot = run.combat_snapshot,
            boss_runtime = run.boss_runtime,
        })
        assert.equal(started.ok, true)
        local state = started.value
        local advanced = CombatAggregate.apply_command(state, {
            command_id = 'cmd_action_phase',
            command_type = 'ADVANCE',
            combat_id = run.combat_id,
        })
        assert.equal(advanced.ok, true)

        local saw_phase2 = false
        local saw_enrage = false
        local index
        for index = 1, #state.events do
            local event = state.events[index]
            if event.event_type == 'BossPhaseEntered' and event.payload.phase_index == 2 then
                saw_phase2 = true
            end
            if event.event_type == 'BossEnraged' then
                saw_enrage = true
            end
        end
        assert.equal(saw_phase2, true)
        assert.equal(saw_enrage, true)
        assert.equal(state.boss_runtime.enraged, true)
    end),
}
