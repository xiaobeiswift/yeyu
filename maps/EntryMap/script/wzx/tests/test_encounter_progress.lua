local Harness = require 'wzx.tests.harness'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local EncounterCatalog = require 'wzx.config.schema.encounter.catalog'
local EncounterProgress = require 'wzx.domain.encounter.encounter_progress'
local EncounterSaveCodec = require 'wzx.domain.encounter.encounter_save_codec'
local EncounterSectionRegistrar = require 'wzx.config.schema.encounter.section_registrar'
local EncounterService = require 'wzx.application.use_cases.encounter.encounter_service'
local FakeEconomyStore = require 'wzx.adapters.fake.economy.fake_economy_store'
local FakeEncounterProgressStore = require 'wzx.adapters.fake.encounter.fake_encounter_progress_store'
local Foundation = require 'wzx.config.schema.foundation'
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

local function make_receipt(label)
    local derived = CanonicalReceiptHashV1.derive('encounter_progress_test', {
        { name = 'label', type = 'STRING' },
    }, { label = label })
    assert.equal(derived.ok, true)
    return derived.value.receipt_id
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

local function build_economy()
    local store = FakeEconomyStore.new()
    assert.equal(store.ok, true)
    local currency = CurrencyCatalog.build({
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
    assert.equal(currency.ok, true)
    local rewards = RewardCatalog.build({
        reward_bundles = {
            {
                id = 'reward_ambush_first',
                schema_version = 1,
                entries = { leaf(1, 'CURRENCY', 'currency_copper', 50) },
            },
            {
                id = 'reward_ambush_repeat',
                schema_version = 1,
                entries = { leaf(1, 'CURRENCY', 'currency_copper', 10) },
            },
        },
    })
    assert.equal(rewards.ok, true)
    local economy = EconomyService.bind({
        currency_catalog = currency.value,
        reward_catalog = rewards.value,
        store = store.value,
    })
    assert.equal(economy.ok, true)
    return economy.value
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

local function win_and_settle(service, run_id, start_receipt, settle_label)
    local prepared = service:prepare({
        encounter_id = 'encounter_road_ambush',
        run_id = run_id,
        start_receipt_id = start_receipt,
        attacker_members = { hero_combatant() },
    })
    assert.equal(prepared.ok, true)
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
    local settled = service:settle(run, {
        settlement_receipt_id = make_receipt(settle_label),
    })
    assert.equal(settled.ok, true, settle_label)
    return prepared.value, settled.value
end

return {
    case('progress mark discovered and victory record are deterministic', function()
        local empty = EncounterProgress.empty()
        local discovered = EncounterProgress.mark_discovered(
            empty,
            'encounter_road_ambush',
            1
        )
        assert.equal(discovered.ok, true)
        assert.equal(discovered.value.changed, true)
        assert.equal(discovered.value.row.discovered, true)
        assert.equal(discovered.value.row.first_clear, false)

        local again = EncounterProgress.mark_discovered(
            discovered.value.snapshot,
            'encounter_road_ambush',
            1
        )
        assert.equal(again.ok, true)
        assert.equal(again.value.changed, false)

        local receipt = make_receipt('victory_1')
        local victory = EncounterProgress.record_victory(discovered.value.snapshot, {
            encounter_id = 'encounter_road_ambush',
            rules_version = 1,
            settlement_receipt_id = receipt,
            run_id = 'run_progress_01',
        })
        assert.equal(victory.ok, true)
        assert.equal(victory.value.first_clear_awarded, true)
        assert.equal(victory.value.row.first_clear, true)
        assert.equal(victory.value.row.completion_count, 1)

        local replay = EncounterProgress.record_victory(victory.value.snapshot, {
            encounter_id = 'encounter_road_ambush',
            rules_version = 1,
            settlement_receipt_id = receipt,
            run_id = 'run_progress_01',
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.already_applied, true)
        assert.equal(replay.value.row.completion_count, 1)
    end),

    case('save codec round-trips progress and settlement rows', function()
        local empty = EncounterProgress.empty()
        local discovered = EncounterProgress.mark_discovered(
            empty,
            'encounter_road_ambush',
            1
        )
        assert.equal(discovered.ok, true)
        local victory = EncounterProgress.record_victory(discovered.value.snapshot, {
            encounter_id = 'encounter_road_ambush',
            rules_version = 1,
            settlement_receipt_id = make_receipt('codec_victory'),
            run_id = 'run_codec_01',
        })
        assert.equal(victory.ok, true)

        local encoded = EncounterSaveCodec.encode(victory.value.snapshot)
        assert.equal(encoded.ok, true)
        assert.equal(#encoded.value.encounter_progress_rows, 1)
        assert.equal(#encoded.value.encounter_settlement_rows, 1)
        assert.equal(
            encoded.value.encounter_progress_rows[1].first_clear,
            true
        )

        local decoded = EncounterSaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true)
        assert.equal(decoded.value.progress_revision, victory.value.snapshot.progress_revision)
        assert.equal(
            decoded.value.rows.encounter_road_ambush.completion_count,
            1
        )
    end),

    case('section registrar installs slot-2 encounter sections', function()
        local created = Foundation.create({
            registrars = { EncounterSectionRegistrar },
        })
        assert.equal(created.ok, true)
        local registry = created.value.section_owners
        local keys = {
            'encounter_metadata',
            'encounter_progress_rows',
            'encounter_settlement_rows',
        }
        local index
        for index = 1, #keys do
            local fetched = registry:get(keys[index])
            assert.equal(fetched.ok, true)
            assert.equal(fetched.value.owner_system, '07')
            assert.equal(fetched.value.slot_id, 2)
            assert.equal(fetched.value.codec_id, 'codec_encounter_save_bundle_v1')
        end
    end),

    case('service uses progress store for first clear then repeat rewards', function()
        local progress = FakeEncounterProgressStore.new()
        assert.equal(progress.ok, true)
        local service = EncounterService.bind({
            catalog = build_encounter_catalog(),
            economy_service = build_economy(),
            progress_store = progress.value,
        })
        assert.equal(service.ok, true)

        local _, first = win_and_settle(
            service.value,
            'run_prog_a',
            'start_prog_a',
            'settle_prog_a'
        )
        assert.equal(first.plan.is_first_clear, true)
        assert.equal(first.plan.reward_bundle_id, 'reward_ambush_first')
        assert.equal(first.progress.status, 'COMMITTED')
        assert.equal(first.progress.first_clear_awarded, true)
        assert.equal(first.reward.status, 'COMMITTED')

        local row = service.value:get_progress('encounter_road_ambush')
        assert.equal(row.ok, true)
        assert.equal(row.value.first_clear, true)
        assert.equal(row.value.completion_count, 1)
        assert.equal(row.value.discovered, true)

        local _, second = win_and_settle(
            service.value,
            'run_prog_b',
            'start_prog_b',
            'settle_prog_b'
        )
        -- Progress store drives first_clear_already; no explicit override needed.
        assert.equal(second.plan.is_first_clear, false)
        assert.equal(second.plan.reward_bundle_id, 'reward_ambush_repeat')
        assert.equal(second.progress.first_clear_awarded, false)
        assert.equal(second.progress.row.completion_count, 2)

        local bundle = progress.value:export_save_bundle()
        assert.equal(bundle.ok, true)
        local reloaded = FakeEncounterProgressStore.new()
        assert.equal(reloaded.ok, true)
        local imported = reloaded.value:import_save_bundle(bundle.value)
        assert.equal(imported.ok, true)
        local reloaded_row = reloaded.value:get_row('encounter_road_ambush')
        assert.equal(reloaded_row.ok, true)
        assert.equal(reloaded_row.value.completion_count, 2)
        assert.equal(reloaded_row.value.first_clear, true)
    end),

    case('settlement progress recording is receipt-idempotent', function()
        local progress = FakeEncounterProgressStore.new()
        assert.equal(progress.ok, true)
        local service = EncounterService.bind({
            catalog = build_encounter_catalog(),
            economy_service = build_economy(),
            progress_store = progress.value,
        })
        assert.equal(service.ok, true)

        local prepared = service.value:prepare({
            encounter_id = 'encounter_road_ambush',
            run_id = 'run_prog_idemp',
            start_receipt_id = 'start_prog_idemp',
            attacker_members = { hero_combatant() },
        })
        assert.equal(prepared.ok, true)
        local run = prepared.value
        service.value:activate_combat(run)
        local combat = auto_finish(run.combat_snapshot, run.combat_id)
        service.value:record_combat_result(run, {
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
        local receipt = make_receipt('settle_idemp')
        local first = service.value:settle(run, { settlement_receipt_id = receipt })
        assert.equal(first.ok, true)
        local second = service.value:settle(run, { settlement_receipt_id = receipt })
        assert.equal(second.ok, true)
        assert.equal(second.value.idempotent, true)

        local row = progress.value:get_row('encounter_road_ambush')
        assert.equal(row.value.completion_count, 1)
    end),
}
