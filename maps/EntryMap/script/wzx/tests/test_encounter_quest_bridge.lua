local Harness = require 'wzx.tests.harness'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local DomainEvent = require 'wzx.domain.common.domain_event'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local EncounterCatalog = require 'wzx.config.schema.encounter.catalog'
local EncounterService = require 'wzx.application.use_cases.encounter.encounter_service'
local EncounterQuestBridge = require 'wzx.application.use_cases.encounter.encounter_quest_bridge'
local EncounterCompletedEvent = require 'wzx.domain.encounter.encounter_completed_event'
local QuestCatalog = require 'wzx.config.schema.quest.catalog'
local QuestService = require 'wzx.application.use_cases.quest.quest_service'
local FakeEconomyStore = require 'wzx.adapters.fake.economy.fake_economy_store'
local FakeQuestStore = require 'wzx.adapters.fake.quest.fake_quest_store'
local CombatAggregate = require 'wzx.domain.combat.combat_aggregate'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'

local case = Harness.case
local assert = Harness.assert

local function formula_basic()
    return {
        id = 'formula_enemy_basic',
        formula_version = 1,
        base_hp = 40,
        hp_per_level = 8,
        hp_per_constitution = 4,
        base_attack = 8,
        attack_per_level = 2,
        attack_per_strength = 1,
        attack_per_inner_power_milli = 0,
        base_defense = 2,
        defense_per_level = 1,
        defense_per_constitution = 1,
        base_speed = 80,
        speed_per_agility = 2,
        base_accuracy = 7000,
        accuracy_per_agility = 20,
        base_evasion = 0,
        evasion_per_agility = 5,
        base_max_qi = 100,
        max_qi_per_inner_power = 0,
        effect_accuracy_per_inner_power = 0,
        effect_resistance_per_constitution = 5,
    }
end

local function basic_move(move_id)
    return {
        move_id = move_id,
        move_type = 'BASIC',
        qi_cost = 0,
        action_cooldown = 0,
        on_hit_qi_gain = 5,
        damage = {
            damage_type = 'PHYSICAL',
            attack_ratio_bp = 10000,
            flat_damage = 0,
            hit_mode = 'UNMISSABLE',
            variance_min_bp = 10000,
            variance_max_bp = 10000,
            can_crit = false,
            can_block = false,
            minimum_damage = 1,
        },
    }
end

local function leaf(order, entry_type, target_id, quantity)
    return {
        entry_order = order,
        entry_type = entry_type,
        target_id = target_id,
        quantity_min = quantity,
        quantity_max = quantity,
    }
end

local function build_currency_catalog()
    local built = CurrencyCatalog.build({
        currency_definitions = {
            {
                id = 'currency_copper',
                schema_version = 1,
                category = 'SOFT',
                balance_cap = 10000,
                source_policy_id = 'currpolicy_copper_source',
                sink_policy_id = 'currpolicy_copper_sink',
                name_key = 'currency.copper.name',
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function build_reward_catalog()
    local built = RewardCatalog.build({
        reward_bundles = {
            {
                id = 'reward_ambush_first',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 50),
                },
            },
            {
                id = 'reward_ambush_repeat',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 10),
                },
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function build_encounter_catalog()
    local sealed = EncounterCatalog.seal({
        enemy_stat_profiles = {
            {
                id = 'statprof_bandit',
                schema_version = 1,
                rules_version = 1,
                base_primary = {
                    strength = 8,
                    constitution = 8,
                    agility = 6,
                    inner_power = 4,
                },
                growth_per_level_milli = {
                    strength = 400,
                    constitution = 400,
                    agility = 300,
                    inner_power = 100,
                },
                formula = formula_basic(),
                flat_combat_contributions = {},
                rank_multiplier_bp = {
                    NORMAL = 10000,
                    ELITE = 12000,
                    BOSS = 15000,
                    SUMMON = 8000,
                    MECHANIC_OBJECT = 10000,
                },
                level_min = 1,
                level_max = 30,
                initial_qi = 0,
            },
        },
        enemy_move_sets = {
            {
                id = 'moveset_bandit_melee',
                schema_version = 1,
                rules_version = 1,
                basic_move = basic_move('move_bandit_slash'),
                active_moves = {},
            },
        },
        enemy_definitions = {
            {
                id = 'enemy_bandit',
                schema_version = 1,
                rules_version = 1,
                enemy_class = 'NORMAL',
                display_name_key = 'enemy.bandit.name',
                description_key = 'enemy.bandit.desc',
                stat_profile_id = 'statprof_bandit',
                move_set_id = 'moveset_bandit_melee',
                ai_profile_id = 'ai_bandit_melee',
                default_tags = { 'bandit', 'human' },
                loot_table_id = 'loot_bandit_basic',
                model_asset_id = 'asset_model_bandit',
                portrait_asset_id = 'asset_portrait_bandit',
            },
        },
        wave_definitions = {
            {
                id = 'wave_road_ambush_1',
                schema_version = 1,
                rules_version = 1,
                wave_index = 1,
                spawn_rows = {
                    {
                        spawn_id = 'spawn_bandit_a',
                        enemy_id = 'enemy_bandit',
                        level = 5,
                        position_index = 0,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 1,
                    },
                    {
                        spawn_id = 'spawn_bandit_b',
                        enemy_id = 'enemy_bandit',
                        level = 5,
                        position_index = 1,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 2,
                    },
                },
                presentation_cue_id = 'cue_wave_ambush',
            },
        },
        encounter_definitions = {
            {
                id = 'encounter_road_ambush',
                schema_version = 1,
                rules_version = 1,
                encounter_type = 'NORMAL',
                name_key = 'encounter.road_ambush.name',
                description_key = 'encounter.road_ambush.desc',
                area_id = 'area_wutan',
                location_id = 'loc_road_01',
                wave_ids = { 'wave_road_ambush_1' },
                seed_policy = 'FIXED',
                fixed_seed = 11,
                first_clear_reward_bundle_id = 'reward_ambush_first',
                repeat_reward_bundle_id = 'reward_ambush_repeat',
                completion_fact_id = 'fact_road_ambush_cleared',
            },
        },
    })
    assert.equal(sealed.ok, true)
    return sealed.value
end

local function build_quest_catalog()
    local sealed = QuestCatalog.seal({
        objective_definitions = {
            {
                id = 'objective_clear_ambush',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_main_01',
                objective_type = 'COMPLETE_ENCOUNTER',
                target_id = 'encounter_road_ambush',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'EncounterCompleted',
                description_key = 'obj.clear_ambush.desc',
                completed_key = 'obj.clear_ambush.done',
            },
            {
                id = 'objective_defeat_bandit',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_main_02',
                objective_type = 'DEFEAT_ENEMY',
                target_id = 'enemy_bandit',
                required_count = 2,
                progress_semantics = 'ACCUMULATE_AFTER_ACCEPT',
                event_type = 'EncounterCompleted',
                description_key = 'obj.defeat_bandit.desc',
                completed_key = 'obj.defeat_bandit.done',
            },
        },
        stage_definitions = {
            {
                id = 'stage_main_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_main_wutan_01',
                objective_ids = { 'objective_clear_ambush' },
                completion_mode = 'ALL',
                next_stage_id = 'stage_main_02',
                journal_text_key = 'stage.main_01',
            },
            {
                id = 'stage_main_02',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_main_wutan_01',
                objective_ids = { 'objective_defeat_bandit' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.main_02',
            },
        },
        quest_definitions = {
            {
                id = 'quest_main_wutan_01',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'MAIN',
                chapter_id = 'chapter_01',
                title_key = 'quest.main_wutan_01.title',
                summary_key = 'quest.main_wutan_01.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_guide_chen',
                first_stage_id = 'stage_main_01',
                stage_ids = { 'stage_main_01', 'stage_main_02' },
                reward_policy = 'NO_REWARD',
                journal_sort_order = 10,
            },
        },
    })
    assert.equal(sealed.ok, true)
    return sealed.value
end

local function hero_combatant()
    return {
        actor_id = 'hero1',
        definition_id = 'char_hero',
        side = 'ATTACKER',
        position_index = 0,
        level = 5,
        tags = { 'hero', 'human' },
        stats = {
            max_hp = 200,
            attack = 80,
            defense = 10,
            speed = 140,
            accuracy = 9000,
            evasion = 0,
            crit_chance_bp = 0,
            crit_damage_bp = 15000,
            crit_resist_bp = 0,
            block_chance_bp = 0,
            block_reduction_bp = 2500,
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
            basic_move = basic_move('move_hero_strike'),
            active_moves = {},
        },
        initial_status_ids = {},
        ai_profile_id = 'ai_story_player',
        source_revision = 1,
        source_hash = string.rep('a', 64),
    }
end

local function auto_finish(snapshot, combat_id)
    local started = CombatAggregate.start({
        combat_id = combat_id,
        snapshot = snapshot,
    })
    assert.equal(started.ok, true)
    local state = started.value
    local guard = 0
    while state.phase == 'RUNNING' or state.phase == 'DECISION_REQUIRED' do
        guard = guard + 1
        assert.equal(guard < 200, true)
        local advanced = CombatAggregate.apply_command(state, {
            combat_id = combat_id,
            command_type = 'ADVANCE',
            command_id = 'cmd_' .. tostring(guard),
        })
        assert.equal(advanced.ok, true)
        if advanced.value.finished then
            break
        end
    end
    return state
end

local function make_settlement_receipt(label)
    local derived = CanonicalReceiptHashV1.derive('encounter_test_settlement', {
        { name = 'label', type = 'STRING' },
    }, {
        label = label,
    })
    assert.equal(derived.ok, true)
    return derived.value.receipt_id
end

local function bind_encounter(first_clear_already)
    local store = FakeEconomyStore.new()
    assert.equal(store.ok, true)
    local economy = EconomyService.bind({
        currency_catalog = build_currency_catalog(),
        reward_catalog = build_reward_catalog(),
        store = store.value,
    })
    assert.equal(economy.ok, true)
    local encounter = EncounterService.bind({
        catalog = build_encounter_catalog(),
        economy_service = economy.value,
    })
    assert.equal(encounter.ok, true)
    return encounter.value
end

local function win_run(service, overrides)
    overrides = overrides or {}
    local prepared = service:prepare({
        encounter_id = 'encounter_road_ambush',
        run_id = overrides.run_id or 'run_bridge_01',
        start_receipt_id = overrides.start_receipt_id or 'start_receipt_bridge_01',
        attacker_members = { hero_combatant() },
        first_clear_already = overrides.first_clear_already == true,
    })
    assert.equal(prepared.ok, true, 'prepare')
    local run = prepared.value
    service:activate_combat(run)
    local combat = auto_finish(run.combat_snapshot, run.combat_id)
    assert.equal(combat.result.outcome, 'ATTACKER_WIN')
    local recorded = service:record_combat_result(run, {
        combat_id = run.combat_id,
        outcome = combat.result.outcome,
        winner_side = combat.result.winner_side,
        finish_reason = combat.result.finish_reason,
        action_count = combat.result.action_count,
        event_hash = combat.result.event_hash,
        snapshot_hash = combat.result.snapshot_hash,
        command_hash = combat.result.command_hash,
        rules_version = combat.result.rules_version,
        survivor_rows = combat.result.survivor_rows,
    })
    assert.equal(recorded.ok, true)
    return run
end

return {
    case('settlement builds validated EncounterCompleted with defeated entries', function()
        local service = bind_encounter()
        local run = win_run(service)
        local receipt = make_settlement_receipt('bridge_event')
        local settled = service:settle(run, { settlement_receipt_id = receipt })
        assert.equal(settled.ok, true, 'settle')
        local event = settled.value.completion_event
        assert.truthy(event)
        assert.equal(event.event_type, 'EncounterCompleted')
        assert.equal(event.source_system, '07')
        assert.equal(event.payload.encounter_id, 'encounter_road_ambush')
        assert.equal(event.payload.settlement_receipt_id, receipt)
        assert.equal(event.payload.result, 'ATTACKER_WIN')
        assert.equal(event.payload.completion_fact_id, 'fact_road_ambush_cleared')
        assert.equal(event.payload.is_first_clear, true)
        assert.equal(#event.payload.defeated_entries, 1)
        assert.equal(event.payload.defeated_entries[1].enemy_id, 'enemy_bandit')
        assert.equal(event.payload.defeated_entries[1].count, 2)
        assert.equal(event.payload.defeated_entries[1].tags[1], 'bandit')

        local validated = DomainEvent.validate(event)
        assert.equal(validated.ok, true, 'domain event envelope')

        local replay = service:settle(run, { settlement_receipt_id = receipt })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.idempotent, true)
        assert.equal(replay.value.completion_event.event_id, event.event_id)
    end),

    case('abandon settle does not publish EncounterCompleted', function()
        local service = bind_encounter()
        local prepared = service:prepare({
            encounter_id = 'encounter_road_ambush',
            run_id = 'run_bridge_abandon',
            start_receipt_id = 'start_bridge_abandon',
            attacker_members = { hero_combatant() },
        })
        assert.equal(prepared.ok, true)
        local run = prepared.value
        service:activate_combat(run)
        service:abandon(run, 'PLAYER_QUIT')
        local settled = service:settle(run, {
            settlement_receipt_id = make_settlement_receipt('bridge_abandon'),
        })
        assert.equal(settled.ok, true)
        assert.equal(settled.value.completion_event, nil)
        local relayed = EncounterQuestBridge.relay_completion(
            { consume_fact = function() end },
            settled.value
        )
        assert.equal(relayed.ok, true)
        assert.equal(relayed.value.skipped, true)
    end),

    case('bridge relays settle event into quest stage advance', function()
        local encounter = bind_encounter()
        local quest_store = FakeQuestStore.new()
        assert.equal(quest_store.ok, true)
        local quest = QuestService.bind({
            catalog = build_quest_catalog(),
            quest_store = quest_store.value,
        })
        assert.equal(quest.ok, true)

        local accepted = quest.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_bridge_01',
            accept_receipt_id = 'rcpt_accept_bridge_01',
            command_id = 'cmd_accept_bridge_01',
        })
        assert.equal(accepted.ok, true)
        assert.equal(accepted.value.run.current_stage_id, 'stage_main_01')

        local run = win_run(encounter, {
            run_id = 'run_bridge_quest_01',
            start_receipt_id = 'start_bridge_quest_01',
        })
        local bundled = EncounterQuestBridge.settle_and_relay(
            encounter,
            quest.value,
            run,
            { settlement_receipt_id = make_settlement_receipt('bridge_quest_01') }
        )
        assert.equal(bundled.ok, true, 'settle_and_relay')
        assert.equal(bundled.value.settle.state, 'COMPLETED')
        assert.equal(bundled.value.quest_relay.delivered, true)
        assert.equal(bundled.value.quest_relay.applied, true)
        assert.equal(bundled.value.quest_relay.duplicate, false)

        local run_view = quest.value:get_run('qrun_bridge_01')
        assert.equal(run_view.ok, true)
        assert.equal(run_view.value.run.current_stage_id, 'stage_main_02')
        assert.equal(run_view.value.run.status, 'ACTIVE')

        -- Same settlement receipt event is delivery-idempotent for quest.
        local again = EncounterQuestBridge.relay_completion(
            quest.value,
            bundled.value.settle
        )
        assert.equal(again.ok, true)
        assert.equal(again.value.duplicate, true)
        assert.equal(again.value.applied, false)

        run_view = quest.value:get_run('qrun_bridge_01')
        assert.equal(run_view.value.run.current_stage_id, 'stage_main_02')
    end),

    case('second victory advances DEFEAT_ENEMY objective to ready', function()
        local encounter = bind_encounter()
        local quest = QuestService.bind({ catalog = build_quest_catalog() })
        assert.equal(quest.ok, true)
        quest.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_bridge_02',
            accept_receipt_id = 'rcpt_accept_bridge_02',
        })

        local first_run = win_run(encounter, {
            run_id = 'run_bridge_q2a',
            start_receipt_id = 'start_bridge_q2a',
        })
        local first = EncounterQuestBridge.settle_and_relay(
            encounter,
            quest.value,
            first_run,
            { settlement_receipt_id = make_settlement_receipt('bridge_q2a') }
        )
        assert.equal(first.ok, true)

        local second_run = win_run(encounter, {
            run_id = 'run_bridge_q2b',
            start_receipt_id = 'start_bridge_q2b',
            first_clear_already = true,
        })
        local second = EncounterQuestBridge.settle_and_relay(
            encounter,
            quest.value,
            second_run,
            { settlement_receipt_id = make_settlement_receipt('bridge_q2b') }
        )
        assert.equal(second.ok, true, 'second settle_and_relay')

        local run_view = quest.value:get_run('qrun_bridge_02')
        assert.equal(run_view.ok, true)
        assert.equal(run_view.value.run.status, 'READY_TO_TURN_IN')
        local index
        for index = 1, #run_view.value.objectives do
            if run_view.value.objectives[index].objective_id == 'objective_defeat_bandit' then
                assert.equal(run_view.value.objectives[index].progress, 2)
                assert.equal(run_view.value.objectives[index].status, 'COMPLETE')
            end
        end
    end),

    case('build_defeated_entries is deterministic and ordered', function()
        local catalog = build_encounter_catalog()
        local entries = EncounterCompletedEvent.build_defeated_entries(catalog, {
            cleared_wave_ids = { 'wave_road_ambush_1' },
        })
        assert.equal(entries.ok, true)
        assert.equal(#entries.value, 1)
        assert.equal(entries.value[1].enemy_id, 'enemy_bandit')
        assert.equal(entries.value[1].count, 2)
    end),
}
