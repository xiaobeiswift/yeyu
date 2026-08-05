local Harness = require 'wzx.tests.harness'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local EncounterCatalog = require 'wzx.config.schema.encounter.catalog'
local EncounterService = require 'wzx.application.use_cases.encounter.encounter_service'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'
local FakeEconomyStore = require 'wzx.adapters.fake.economy.fake_economy_store'
local CombatAggregate = require 'wzx.domain.combat.combat_aggregate'
local LootCatalog = require 'wzx.config.schema.economy.loot_catalog'
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
            {
                id = 'currency_true_qi',
                schema_version = 1,
                category = 'PROGRESSION',
                balance_cap = 1000,
                source_policy_id = 'currpolicy_true_qi_source',
                sink_policy_id = 'currpolicy_true_qi_sink',
                name_key = 'currency.true_qi.name',
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
                    leaf(2, 'CURRENCY', 'currency_true_qi', 3),
                },
            },
            {
                id = 'reward_ambush_repeat',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 10),
                },
            },
            {
                id = 'reward_loot_copper_25',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 25),
                },
            },
            {
                id = 'reward_loot_qi_2',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_true_qi', 2),
                },
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function build_loot_catalog()
    local built = LootCatalog.build({
        loot_tables = {
            {
                id = 'loot_ambush_first',
                schema_version = 1,
                roll_count = 1,
                guaranteed_reward_id = 'reward_loot_copper_25',
                group_ids = { 'lootgroup_ambush_first' },
                config_version = 1,
            },
            {
                id = 'loot_ambush_repeat',
                schema_version = 1,
                roll_count = 1,
                guaranteed_reward_id = 'reward_loot_qi_2',
                group_ids = { 'lootgroup_ambush_repeat' },
                config_version = 1,
            },
        },
        loot_groups = {
            {
                id = 'lootgroup_ambush_first',
                schema_version = 1,
                mode = 'GUARANTEED_ALL',
                roll_count = 1,
            },
            {
                id = 'lootgroup_ambush_repeat',
                schema_version = 1,
                mode = 'GUARANTEED_ALL',
                roll_count = 1,
            },
        },
        loot_entries = {
            {
                group_id = 'lootgroup_ambush_first',
                entry_order = 1,
                reward_id = 'reward_loot_qi_2',
            },
            {
                group_id = 'lootgroup_ambush_repeat',
                entry_order = 1,
                reward_id = 'reward_loot_copper_25',
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function build_encounter_catalog(overrides)
    overrides = overrides or {}
    local encounter_def = {
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
    }
    -- false means "explicitly clear optional field" (Lua cannot store nil keys).
    local key
    local value
    for key, value in pairs(overrides) do
        if value == false then
            encounter_def[key] = nil
        else
            encounter_def[key] = value
        end
    end

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
            encounter_def,
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

local function bind_stack(options)
    options = options or {}
    local store = FakeEconomyStore.new()
    assert.equal(store.ok, true)
    local economy_opts = {
        currency_catalog = build_currency_catalog(),
        reward_catalog = build_reward_catalog(),
        store = store.value,
    }
    if options.with_loot_catalog == true then
        economy_opts.loot_catalog = build_loot_catalog()
    end
    local economy = EconomyService.bind(economy_opts)
    assert.equal(economy.ok, true)
    local encounter = EncounterService.bind({
        catalog = build_encounter_catalog(options.encounter_overrides),
        economy_service = economy.value,
    })
    assert.equal(encounter.ok, true)
    return encounter.value, economy.value
end

--- Economy facade that only exposes prepare_reward / grant_prepared_reward
--- so encounter settle can assert fail-closed when loot is configured.
local function wrap_economy_without_prepare_loot(economy)
    return {
        prepare_reward = function(_, input)
            return economy:prepare_reward(input)
        end,
        grant_prepared_reward = function(_, input)
            return economy:grant_prepared_reward(input)
        end,
        get_balance = function(_, currency_id)
            return economy:get_balance(currency_id)
        end,
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

local function win_run(service, overrides)
    overrides = overrides or {}
    local prepared = service:prepare({
        encounter_id = 'encounter_road_ambush',
        run_id = overrides.run_id or 'run_settle_01',
        start_receipt_id = overrides.start_receipt_id or 'start_receipt_settle_01',
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
    assert.equal(recorded.value.terminal, true)
    return run
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

return {
    case('first clear victory grants first reward bundle through economy', function()
        local service, economy = bind_stack()
        local run = win_run(service)
        local receipt = make_settlement_receipt('first_clear')
        local settled = service:settle(run, {
            settlement_receipt_id = receipt,
        })
        assert.equal(settled.ok, true, 'settle first clear')
        assert.equal(settled.value.state, 'COMPLETED')
        assert.equal(settled.value.plan.is_first_clear, true)
        assert.equal(settled.value.plan.reward_bundle_id, 'reward_ambush_first')
        assert.equal(settled.value.reward.status, 'COMMITTED')
        assert.equal(settled.value.reward.already_committed, false)
        assert.equal(settled.value.reward.source_type, 'ENCOUNTER_FIRST_CLEAR')
        assert.equal(settled.value.reward.source_occurrence_id, 'fc_encounter_road_ambush')
        assert.equal(settled.value.reward.receipt_id, receipt)

        local copper = economy:get_balance('currency_copper')
        assert.equal(copper.ok, true)
        assert.equal(copper.value.balance, 50)
        local qi = economy:get_balance('currency_true_qi')
        assert.equal(qi.ok, true)
        assert.equal(qi.value.balance, 3)
    end),

    case('repeat victory grants repeat bundle and is receipt-idempotent', function()
        local service, economy = bind_stack()
        local run = win_run(service, {
            run_id = 'run_settle_repeat',
            start_receipt_id = 'start_receipt_settle_repeat',
            first_clear_already = true,
        })
        local receipt = make_settlement_receipt('repeat_clear')
        local settled = service:settle(run, {
            settlement_receipt_id = receipt,
        })
        assert.equal(settled.ok, true)
        assert.equal(settled.value.plan.is_first_clear, false)
        assert.equal(settled.value.plan.reward_bundle_id, 'reward_ambush_repeat')
        assert.equal(settled.value.reward.source_type, 'ENCOUNTER_REPEAT')
        assert.equal(settled.value.reward.source_occurrence_id, 'run_settle_repeat')

        local copper = economy:get_balance('currency_copper')
        assert.equal(copper.value.balance, 10)

        local replay = service:settle(run, {
            settlement_receipt_id = receipt,
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.idempotent, true)
        copper = economy:get_balance('currency_copper')
        assert.equal(copper.value.balance, 10)
    end),

    case('second first-clear of same encounter rejects source reuse', function()
        local service, economy = bind_stack()
        local first = win_run(service, {
            run_id = 'run_fc_a',
            start_receipt_id = 'start_fc_a',
        })
        local settled_a = service:settle(first, {
            settlement_receipt_id = make_settlement_receipt('fc_a'),
        })
        assert.equal(settled_a.ok, true)
        assert.equal(economy:get_balance('currency_copper').value.balance, 50)

        local second = win_run(service, {
            run_id = 'run_fc_b',
            start_receipt_id = 'start_fc_b',
            first_clear_already = false,
        })
        local settled_b = service:settle(second, {
            settlement_receipt_id = make_settlement_receipt('fc_b'),
        })
        assert.equal(settled_b.ok, false)
        assert.equal(
            settled_b.error.code,
            EncounterErrorCodes.ENCOUNTER_REWARD_GRANT_FAILED
        )
        assert.equal(settled_b.error.details.cause_code, 'ECONOMY_SOURCE_ALREADY_GRANTED')
        -- Balance must not increase after rejected second first-clear.
        assert.equal(economy:get_balance('currency_copper').value.balance, 50)
    end),

    case('abandon settles without granting rewards', function()
        local service, economy = bind_stack()
        local prepared = service:prepare({
            encounter_id = 'encounter_road_ambush',
            run_id = 'run_abandon',
            start_receipt_id = 'start_abandon',
            attacker_members = { hero_combatant() },
        })
        assert.equal(prepared.ok, true)
        local run = prepared.value
        service:activate_combat(run)
        local abandoned = service:abandon(run, 'PLAYER_QUIT')
        assert.equal(abandoned.ok, true)
        local settled = service:settle(run, {
            settlement_receipt_id = make_settlement_receipt('abandon'),
        })
        assert.equal(settled.ok, true)
        assert.equal(settled.value.state, 'ABANDONED')
        assert.equal(settled.value.plan.is_victory, false)
        assert.equal(settled.value.reward.status, 'SKIPPED')
        assert.equal(settled.value.reward.reason, 'NOT_VICTORY')
        assert.equal(economy:get_balance('currency_copper').value.balance, 0)
    end),

    case('victory with reward requires bound economy service', function()
        local bare = EncounterService.bind({
            catalog = build_encounter_catalog(),
        })
        assert.equal(bare.ok, true)
        local run = win_run(bare.value, {
            run_id = 'run_no_economy',
            start_receipt_id = 'start_no_economy',
        })
        local settled = bare.value:settle(run, {
            settlement_receipt_id = make_settlement_receipt('no_economy'),
        })
        assert.equal(settled.ok, false)
        assert.equal(
            settled.error.code,
            EncounterErrorCodes.ENCOUNTER_REWARD_SERVICE_REQUIRED
        )
    end),

    case('loot table settlement grants deterministic currency and is receipt-idempotent', function()
        local service, economy = bind_stack({
            with_loot_catalog = true,
            encounter_overrides = {
                -- Prefer loot over bundle; bundle remains present but unused.
                first_clear_loot_table_id = 'loot_ambush_first',
                first_clear_reward_bundle_id = 'reward_ambush_first',
                repeat_loot_table_id = 'loot_ambush_repeat',
                repeat_reward_bundle_id = 'reward_ambush_repeat',
            },
        })
        local run = win_run(service, {
            run_id = 'run_loot_first',
            start_receipt_id = 'start_loot_first',
        })
        local receipt = make_settlement_receipt('loot_first')
        local settled = service:settle(run, {
            settlement_receipt_id = receipt,
        })
        assert.equal(settled.ok, true, 'settle loot first clear')
        assert.equal(settled.value.plan.is_first_clear, true)
        assert.equal(settled.value.plan.loot_table_id, 'loot_ambush_first')
        assert.equal(settled.value.plan.reward_bundle_id, 'reward_ambush_first')
        assert.equal(settled.value.plan.root_seed, 11)
        assert.equal(settled.value.reward.status, 'COMMITTED')
        assert.equal(settled.value.reward.loot_table_id, 'loot_ambush_first')
        assert.equal(settled.value.reward.source_type, 'ENCOUNTER_FIRST_CLEAR')
        assert.equal(settled.value.reward.source_occurrence_id, 'fc_encounter_road_ambush')
        -- guaranteed copper 25 + group qi 2
        local copper = economy:get_balance('currency_copper')
        assert.equal(copper.ok, true)
        assert.equal(copper.value.balance, 25)
        local qi = economy:get_balance('currency_true_qi')
        assert.equal(qi.ok, true)
        assert.equal(qi.value.balance, 2)

        local replay = service:settle(run, {
            settlement_receipt_id = receipt,
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.idempotent, true)
        copper = economy:get_balance('currency_copper')
        assert.equal(copper.value.balance, 25)
        qi = economy:get_balance('currency_true_qi')
        assert.equal(qi.value.balance, 2)
    end),

    case('loot-only settlement is seed-reproducible across independent runs', function()
        local service, economy = bind_stack({
            with_loot_catalog = true,
            encounter_overrides = {
                first_clear_loot_table_id = 'loot_ambush_first',
                first_clear_reward_bundle_id = false,
                repeat_loot_table_id = 'loot_ambush_repeat',
                repeat_reward_bundle_id = false,
            },
        })
        local first = win_run(service, {
            run_id = 'run_loot_seed_a',
            start_receipt_id = 'start_loot_seed_a',
            first_clear_already = true,
        })
        local settled_a = service:settle(first, {
            settlement_receipt_id = make_settlement_receipt('loot_seed_a'),
        })
        assert.equal(settled_a.ok, true)
        assert.equal(settled_a.value.plan.loot_table_id, 'loot_ambush_repeat')
        assert.equal(settled_a.value.plan.reward_bundle_id, nil)
        -- repeat loot: guaranteed qi 2 + group copper 25
        assert.equal(economy:get_balance('currency_copper').value.balance, 25)
        assert.equal(economy:get_balance('currency_true_qi').value.balance, 2)

        local second = win_run(service, {
            run_id = 'run_loot_seed_b',
            start_receipt_id = 'start_loot_seed_b',
            first_clear_already = true,
        })
        local settled_b = service:settle(second, {
            settlement_receipt_id = make_settlement_receipt('loot_seed_b'),
        })
        assert.equal(settled_b.ok, true)
        -- Same fixed seed + independent occurrence → same roll quantities, stacked.
        assert.equal(economy:get_balance('currency_copper').value.balance, 50)
        assert.equal(economy:get_balance('currency_true_qi').value.balance, 4)
    end),

    case('loot configured but economy lacks prepare_loot fails closed without bundle fallback', function()
        local store = FakeEconomyStore.new()
        assert.equal(store.ok, true)
        local full_economy = EconomyService.bind({
            currency_catalog = build_currency_catalog(),
            reward_catalog = build_reward_catalog(),
            loot_catalog = build_loot_catalog(),
            store = store.value,
        })
        assert.equal(full_economy.ok, true)
        local limited = wrap_economy_without_prepare_loot(full_economy.value)
        local encounter = EncounterService.bind({
            catalog = build_encounter_catalog({
                first_clear_loot_table_id = 'loot_ambush_first',
                first_clear_reward_bundle_id = 'reward_ambush_first',
            }),
            economy_service = limited,
        })
        assert.equal(encounter.ok, true)
        local run = win_run(encounter.value, {
            run_id = 'run_loot_no_api',
            start_receipt_id = 'start_loot_no_api',
        })
        local settled = encounter.value:settle(run, {
            settlement_receipt_id = make_settlement_receipt('loot_no_api'),
        })
        assert.equal(settled.ok, false)
        assert.equal(
            settled.error.code,
            EncounterErrorCodes.ENCOUNTER_REWARD_GRANT_FAILED
        )
        assert.equal(settled.error.details.reason, 'PREPARE_LOOT_UNSUPPORTED')
        assert.equal(settled.error.details.loot_table_id, 'loot_ambush_first')
        -- Must not have granted the fixed bundle as silent fallback.
        local copper = limited:get_balance('currency_copper')
        assert.equal(copper.ok, true)
        assert.equal(copper.value.balance, 0)
    end),
}
