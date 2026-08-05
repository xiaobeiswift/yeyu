local Harness = require 'wzx.tests.harness'
local CharacterCatalog = require 'wzx.config.schema.character.catalog'
local CharacterRules = require 'wzx.application.character.character_rules'
local CharacterSaveBridge = require 'wzx.application.use_cases.character.character_save_bridge'
local CharacterWriteService = require 'wzx.application.use_cases.character.character_write_service'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local EconomySaveBridge = require 'wzx.application.use_cases.economy.economy_save_bridge'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local FakeCharacterRepository = require 'wzx.adapters.fake.character.fake_character_repository'
local FakeEconomyStore = require 'wzx.adapters.fake.economy.fake_economy_store'
local FakeInventoryStore = require 'wzx.adapters.fake.inventory.fake_inventory_store'
local FakeQuestStore = require 'wzx.adapters.fake.quest.fake_quest_store'
local FakeWorldStore = require 'wzx.adapters.fake.world.fake_world_store'
local InventoryService = require 'wzx.application.use_cases.inventory.inventory_service'
local ItemCatalog = require 'wzx.config.schema.inventory.catalog'
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local QuestCatalog = require 'wzx.config.schema.quest.catalog'
local QuestCompletionSaveBridge =
    require 'wzx.application.use_cases.quest.quest_completion_save_bridge'
local QuestSaveBridge = require 'wzx.application.use_cases.quest.quest_save_bridge'
local QuestService = require 'wzx.application.use_cases.quest.quest_service'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'
local WorldCatalog = require 'wzx.config.schema.world.catalog'
local WorldSaveBridge = require 'wzx.application.use_cases.world.world_save_bridge'
local WorldService = require 'wzx.application.use_cases.world.world_service'

local case = Harness.case
local assert = Harness.assert

local function formula_set()
    return {
        id = 'formula_story_v1',
        formula_version = 1,
        base_hp = 100,
        hp_per_level = 24,
        hp_per_constitution = 12,
        base_attack = 10,
        attack_per_level = 3,
        attack_per_strength = 3,
        attack_per_inner_power_milli = 500,
        base_defense = 5,
        defense_per_level = 2,
        defense_per_constitution = 2,
        base_speed = 1000,
        speed_per_agility = 12,
        base_accuracy = 7000,
        accuracy_per_agility = 8,
        base_evasion = 0,
        evasion_per_agility = 5,
        base_max_qi = 1000,
        max_qi_per_inner_power = 2,
        effect_accuracy_per_inner_power = 4,
        effect_resistance_per_constitution = 3,
    }
end

local function level_curve(with_rewards)
    local refs = {}
    if with_rewards then
        refs = {
            {
                reached_level = 2,
                reward_ref = 'reward_level_two',
            },
        }
    end
    return {
        id = 'curve_level_story',
        level_cap = 4,
        cumulative_exp_by_level = { 0, 100, 250, 500 },
        experience_cap = 1000,
        level_reward_refs = refs,
    }
end

local function talent_definition()
    return {
        id = 'talent_focus',
        schema_version = 1,
        name_key = 'talent.focus.name',
        description_key = 'talent.focus.description',
        unlock_rule_id = 'rule_talent_focus',
        contributions = {
            {
                source_type = 'TALENT',
                source_id = 'talent:focus',
                target_stat = 'attack',
                operation = 'ADD_FLAT',
                value = 5,
                priority = 0,
                condition_tags = {},
                stable_order_key = 'catalog:talent:focus:attack',
            },
        },
        combat_hook_ids = { 'hook_talent_focus' },
        exclusive_group = nil,
        tags = { 'focus' },
        deprecated = false,
    }
end

local function character_definition()
    return {
        id = 'char_hero',
        schema_version = 1,
        definition_version = 3,
        display_name_key = 'character.hero.name',
        description_key = 'character.hero.description',
        role = 'PROTAGONIST',
        level_curve_id = 'curve_level_story',
        formula_set_id = 'formula_story_v1',
        base_primary = {
            strength = 10,
            constitution = 20,
            agility = 30,
            inner_power = 40,
        },
        growth_per_level_milli = {
            strength = 1000,
            constitution = 2000,
            agility = 3000,
            inner_power = 4000,
        },
        weapon_aptitudes = {
            UNARMED = 10000,
            SWORD = 8000,
            BLADE = 6000,
            STAFF = 4000,
        },
        default_talent_ids = { 'talent_focus' },
        initial_qi = 100,
        model_asset_id = 'model_hero',
        portrait_asset_id = 'portrait_hero',
        tags = { 'hero', 'human' },
        deprecated = false,
    }
end

local function build_character_rules(options)
    options = options or {}
    local character_catalog = CharacterCatalog.build({
        character_definitions = { character_definition() },
        level_curves = { level_curve(options.with_level_rewards == true) },
        formula_sets = { formula_set() },
        talent_definitions = { talent_definition() },
    })
    assert.equal(character_catalog.ok, true)
    local reward_bundles = options.reward_bundles or {}
    local reward_catalog = RewardCatalog.build({
        reward_bundles = reward_bundles,
    })
    assert.equal(reward_catalog.ok, true)
    local rules = CharacterRules.bind(
        character_catalog.value,
        reward_catalog.value
    )
    assert.equal(rules.ok, true)
    return rules.value, reward_catalog.value
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

local function build_shared_stack(options)
    options = options or {}
    local memory = MemorySaveStore.new()
    local coordinator = SaveCoordinator.bind({ save_store = memory })
    assert.equal(coordinator.ok, true)
    local invoke = SaveCoordinator.fake_invoke(memory)

    local reward_bundles = {
        {
            id = 'reward_quest_copper',
            schema_version = 1,
            entries = {
                leaf(1, 'CURRENCY', 'currency_copper', 30),
            },
        },
    }
    if options.with_level_rewards then
        reward_bundles[#reward_bundles + 1] = {
            id = 'reward_level_two',
            schema_version = 1,
            entries = {
                leaf(1, 'CURRENCY', 'currency_copper', 50),
            },
        }
    end

    local character_rules, reward_catalog = build_character_rules({
        with_level_rewards = options.with_level_rewards == true,
        reward_bundles = reward_bundles,
    })

    local currency_catalog = CurrencyCatalog.build({
        currency_definitions = {
            {
                id = 'currency_copper',
                schema_version = 1,
                category = 'SOFT',
                balance_cap = 100000,
                source_policy_id = 'currpolicy_copper_source',
                sink_policy_id = 'currpolicy_copper_sink',
                name_key = 'currency.copper.name',
            },
        },
    })
    assert.equal(currency_catalog.ok, true)
    local economy_store = FakeEconomyStore.new()
    assert.equal(economy_store.ok, true)
    local economy_bridge = EconomySaveBridge.bind({
        store = economy_store.value,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = 777001,
    })
    assert.equal(economy_bridge.ok, true)
    local economy_service = EconomyService.bind({
        currency_catalog = currency_catalog.value,
        reward_catalog = reward_catalog,
        store = economy_store.value,
        save_bridge = economy_bridge.value,
    })
    assert.equal(economy_service.ok, true)

    local character_repo = FakeCharacterRepository.new()
    local character_bridge = CharacterSaveBridge.bind({
        repository = character_repo,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = 777001,
    })
    assert.equal(character_bridge.ok, true)
    local character_service = CharacterWriteService.bind({
        rules = character_rules,
        repository = character_repo,
        save_bridge = character_bridge.value,
        economy_service = options.bind_economy_to_character == true
            and economy_service.value
            or nil,
    })
    assert.equal(character_service.ok, true)

    local load = LoadGameSave.bind({ coordinator = coordinator.value })
    assert.equal(load.ok, true)

    return {
        memory = memory,
        invoke = invoke,
        character_service = character_service.value,
        character_repo_invoke = CharacterWriteService.fake_invoke(character_repo),
        economy_service = economy_service.value,
        load = load.value,
    }
end

return {
    case('character write uses checkpoint and reloads ready with slot 3 data', function()
        local stack = build_shared_stack()
        local created = stack.character_service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_001',
            transaction_id = 'character_create_hero_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
            request_id = 'request_create_1',
        }, stack.character_repo_invoke)
        assert.equal(created.ok, true, created.error and created.error.code)
        assert.equal(created.value.save.status, 'COMMITTED')
        assert.equal(created.value.save.created_save, true)
        assert.equal(created.value.save.slot1_revision >= 2, true)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_char_1',
            request_id = 'request_load_char_1',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.writable, true)
        assert.equal(loaded.value.loaded_envelopes[3] ~= nil, true)
        assert.equal(
            loaded.value.loaded_envelopes[3].payload.character_rows[1].character_id,
            'char_hero'
        )
        assert.equal(loaded.value.loaded_envelopes[5] ~= nil, true)
        assert.equal(
            #loaded.value.loaded_envelopes[5].payload.character_operation_receipts,
            1
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_3_revision,
            loaded.value.loaded_envelopes[3].revision
        )
    end),

    case('economy grant uses checkpoint and reloads ready with slot 4 balances', function()
        local stack = build_shared_stack()
        local prepared = stack.economy_service:prepare_reward({
            reward_id = 'reward_quest_copper',
            source_type = 'QUEST',
            source_ref = 'reward_quest_copper',
            source_occurrence_id = 'quest_run_reload_001',
        })
        assert.equal(prepared.ok, true)

        local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
        local receipt = CanonicalReceiptHashV1.derive('economy_test_receipt', {
            { name = 'label', type = 'STRING' },
        }, { label = 'reload_grant' })
        assert.equal(receipt.ok, true)

        local granted = stack.economy_service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = receipt.value.receipt_id,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_reload',
            player_save_scope = 'player001',
            request_id = 'request_economy_grant_1',
        })
        assert.equal(granted.ok, true, granted.error and granted.error.code)
        assert.equal(granted.value.save.status, 'COMMITTED')
        assert.equal(granted.value.save.created_save, true)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_eco_1',
            request_id = 'request_load_eco_1',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.loaded_envelopes[4] ~= nil, true)
        assert.equal(
            loaded.value.loaded_envelopes[4].payload.currency_balance_rows[1].balance,
            30
        )
        assert.equal(
            loaded.value.loaded_envelopes[5].payload.economy_reward_receipts ~= nil,
            true
        )
        assert.equal(
            #loaded.value.loaded_envelopes[5].payload.economy_reward_receipts,
            1
        )
    end),

    case('character then economy share slot 5 sections without clobbering', function()
        local stack = build_shared_stack()
        local created = stack.character_service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_001',
            transaction_id = 'character_create_hero_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
            request_id = 'request_create_shared_1',
        }, stack.character_repo_invoke)
        assert.equal(created.ok, true, created.error and created.error.code)

        local prepared = stack.economy_service:prepare_reward({
            reward_id = 'reward_quest_copper',
            source_type = 'QUEST',
            source_ref = 'reward_quest_copper',
            source_occurrence_id = 'quest_run_shared_001',
        })
        assert.equal(prepared.ok, true)
        local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
        local receipt = CanonicalReceiptHashV1.derive('economy_test_receipt', {
            { name = 'label', type = 'STRING' },
        }, { label = 'shared_grant' })
        assert.equal(receipt.ok, true)
        local granted = stack.economy_service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = receipt.value.receipt_id,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_shared',
            player_save_scope = 'player001',
            request_id = 'request_economy_shared_1',
        })
        assert.equal(granted.ok, true, granted.error and granted.error.code)
        assert.equal(granted.value.save.created_save, false)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_shared_1',
            request_id = 'request_load_shared_1',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        local slot5 = loaded.value.loaded_envelopes[5].payload
        assert.equal(#slot5.character_operation_receipts, 1)
        assert.equal(#slot5.economy_reward_receipts, 1)
        assert.equal(
            loaded.value.loaded_envelopes[3].payload.character_rows[1].character_id,
            'char_hero'
        )
        assert.equal(
            loaded.value.loaded_envelopes[4].payload.currency_balance_rows[1].balance,
            30
        )
    end),

    case('economy spend after grant reloads reduced balance through checkpoint', function()
        local stack = build_shared_stack()
        local prepared = stack.economy_service:prepare_reward({
            reward_id = 'reward_quest_copper',
            source_type = 'QUEST',
            source_ref = 'reward_quest_copper',
            source_occurrence_id = 'quest_run_spend_fund_001',
        })
        assert.equal(prepared.ok, true)
        local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
        local fund_receipt = CanonicalReceiptHashV1.derive('economy_test_receipt', {
            { name = 'label', type = 'STRING' },
        }, { label = 'spend_fund' })
        assert.equal(fund_receipt.ok, true)
        local funded = stack.economy_service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = fund_receipt.value.receipt_id,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_spend_fund',
            player_save_scope = 'player001',
            request_id = 'request_economy_spend_fund',
        })
        assert.equal(funded.ok, true, funded.error and funded.error.code)

        local spend_receipt = CanonicalReceiptHashV1.derive('economy_test_receipt', {
            { name = 'label', type = 'STRING' },
        }, { label = 'spend_once' })
        assert.equal(spend_receipt.ok, true)
        local spent = stack.economy_service:spend_resources({
            costs = {
                { currency_id = 'currency_copper', amount = 12 },
            },
            purpose_type = 'SHOP_PURCHASE',
            purpose_ref = 'shop_reload_item',
            receipt_id = spend_receipt.value.receipt_id,
            source_occurrence_id = 'shop_buy_reload_001',
            player_save_scope = 'player001',
            request_id = 'request_economy_spend_1',
        })
        assert.equal(spent.ok, true, spent.error and spent.error.code)
        assert.equal(spent.value.save.status, 'COMMITTED')
        assert.equal(spent.value.already_committed, false)

        local live = stack.economy_service:get_balance('currency_copper')
        assert.equal(live.ok, true)
        assert.equal(live.value.balance, 18)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_spend_1',
            request_id = 'request_load_spend_1',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(
            loaded.value.loaded_envelopes[4].payload.currency_balance_rows[1].balance,
            18
        )
        assert.equal(
            #loaded.value.loaded_envelopes[5].payload.economy_reward_receipts,
            2
        )
    end),

    case('level-up auto-settles currency then reloads slot 3/4/5 consistently', function()
        local stack = build_shared_stack({
            with_level_rewards = true,
            bind_economy_to_character = true,
        })

        local created = stack.character_service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_001',
            transaction_id = 'character_create_hero_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
            request_id = 'request_create_level_1',
        }, stack.character_repo_invoke)
        assert.equal(created.ok, true, created.error and created.error.code)
        assert.equal(created.value.save.status, 'COMMITTED')

        local granted = stack.character_service:grant_experience({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            amount = 100,
            reason = 'QUEST_REWARD',
            receipt_id = 'character:experience:hero_level_auto_001',
            transaction_id = 'character_experience_level_auto_tx_001',
            request_id = 'request_xp_level_auto_1',
        }, stack.character_repo_invoke)
        assert.equal(granted.ok, true, granted.error and granted.error.code)
        assert.equal(granted.value.status, 'COMMITTED')
        assert.equal(granted.value.result.old_level, 1)
        assert.equal(granted.value.result.new_level, 2)
        assert.equal(granted.value.result.reward_status, 'COMMITTED')
        assert.equal(granted.value.reward_settlement.auto_settled, true)
        assert.equal(#granted.value.reward_settlement.grants, 1)
        assert.equal(granted.value.save.status, 'COMMITTED')

        local live_balance = stack.economy_service:get_balance('currency_copper')
        assert.equal(live_balance.ok, true)
        assert.equal(live_balance.value.balance, 50)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_level_reward_1',
            request_id = 'request_load_level_reward_1',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.writable, true)

        local character_row = loaded.value.loaded_envelopes[3].payload.character_rows[1]
        assert.equal(character_row.character_id, 'char_hero')
        assert.equal(character_row.level, 2)
        assert.equal(character_row.experience, 100)

        local balance_rows =
            loaded.value.loaded_envelopes[4].payload.currency_balance_rows
        assert.equal(#balance_rows, 1)
        assert.equal(balance_rows[1].currency_id, 'currency_copper')
        assert.equal(balance_rows[1].balance, 50)

        local slot5 = loaded.value.loaded_envelopes[5].payload
        assert.equal(#slot5.character_operation_receipts >= 2, true)
        assert.equal(#slot5.economy_reward_receipts, 1)
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_3_revision,
            loaded.value.loaded_envelopes[3].revision
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_4_revision,
            loaded.value.loaded_envelopes[4].revision
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_5_revision,
            loaded.value.loaded_envelopes[5].revision
        )
    end),

    case('quest then world share slot 2 sections without clobbering', function()
        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)
        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)

        local quest_catalog = QuestCatalog.seal({
            objective_definitions = {
                {
                    id = 'objective_share_talk',
                    schema_version = 1,
                    rules_version = 1,
                    stage_id = 'stage_share_01',
                    objective_type = 'TALK',
                    target_id = 'dialogue_share_help',
                    required_count = 1,
                    progress_semantics = 'ONCE_FACT',
                    event_type = 'DialogueCompleted',
                    description_key = 'obj.share.desc',
                    completed_key = 'obj.share.done',
                },
            },
            stage_definitions = {
                {
                    id = 'stage_share_01',
                    schema_version = 1,
                    rules_version = 1,
                    quest_id = 'quest_side_share_slot2',
                    objective_ids = { 'objective_share_talk' },
                    completion_mode = 'ALL',
                    journal_text_key = 'stage.share_01',
                },
            },
            quest_definitions = {
                {
                    id = 'quest_side_share_slot2',
                    schema_version = 1,
                    definition_version = 1,
                    rules_version = 1,
                    category = 'SIDE',
                    chapter_id = 'chapter_01',
                    title_key = 'quest.side_share.title',
                    summary_key = 'quest.side_share.summary',
                    accept_policy = 'MANUAL_NPC',
                    accept_ref_id = 'npc_share',
                    first_stage_id = 'stage_share_01',
                    stage_ids = { 'stage_share_01' },
                    reward_policy = 'NO_REWARD',
                    abandon_policy = 'ALLOW_RESET_RUN',
                    journal_sort_order = 50,
                },
            },
        })
        assert.equal(quest_catalog.ok, true, tostring(
            quest_catalog.error and quest_catalog.error.details
                and quest_catalog.error.details.reason
        ))

        local world_catalog = WorldCatalog.seal({
            flag_definitions = {},
            location_definitions = {
                {
                    id = 'location_share_gate',
                    schema_version = 1,
                    rules_version = 1,
                    area_id = 'area_share_town',
                    name_key = 'location.share_gate',
                    discovery_marker_id = 'marker_share_gate',
                    safe_return_marker_id = 'marker_share_gate',
                    map_sort_order = 10,
                },
            },
            area_definitions = {
                {
                    id = 'area_share_town',
                    schema_version = 1,
                    rules_version = 1,
                    area_type = 'TOWN',
                    name_key = 'area.share_town',
                    location_ids = { 'location_share_gate' },
                    entry_marker_id = 'marker_share_gate',
                },
            },
            interactable_definitions = {},
        })
        assert.equal(world_catalog.ok, true)

        local quest_store = FakeQuestStore.new()
        assert.equal(quest_store.ok, true)
        local world_store = FakeWorldStore.new()
        assert.equal(world_store.ok, true)

        local quest_bridge = QuestSaveBridge.bind({
            store = quest_store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 142001,
        })
        assert.equal(quest_bridge.ok, true)
        local world_bridge = WorldSaveBridge.bind({
            store = world_store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 142001,
        })
        assert.equal(world_bridge.ok, true)

        local quest = QuestService.bind({
            catalog = quest_catalog.value,
            quest_store = quest_store.value,
            save_bridge = quest_bridge.value,
            auto_track_main = false,
        })
        assert.equal(quest.ok, true)
        local world = WorldService.bind({
            catalog = world_catalog.value,
            world_store = world_store.value,
            save_bridge = world_bridge.value,
        })
        assert.equal(world.ok, true)

        -- 1) Quest owns slot-2 quest_* sections first.
        local accepted = quest.value:accept({
            quest_id = 'quest_side_share_slot2',
            run_id = 'qrun_share_slot2',
            accept_receipt_id = 'rcpt_share_slot2',
            command_id = 'cmd_share_accept',
            player_save_scope = 'player_share_slot2',
            request_id = 'request_share_quest_accept',
        })
        assert.equal(accepted.ok, true, tostring(accepted.error and accepted.error.code))
        assert.equal(accepted.value.save.status, 'COMMITTED')
        assert.equal(accepted.value.save.created_save, true)
        assert.equal(accepted.value.save.slot2_revision, 1)

        -- 2) World merges world_* into the same slot without wiping quest sections.
        assert.equal(world.value:bootstrap_position({
            location_id = 'location_share_gate',
            marker_id = 'marker_share_gate',
            current_cell_id = 'traversal_cell_share_gate',
        }).ok, true)
        assert.equal(world.value:discover_location({
            location_id = 'location_share_gate',
            discovery_receipt_id = 'rcpt_share_discover',
            command_id = 'cmd_share_discover',
        }).ok, true)

        local world_saved = world_bridge.value:persist_player_world({
            player_save_scope = 'player_share_slot2',
            request_id = 'request_share_world_save',
            command_id = 'cmd_share_world_ckpt',
            reason = 'WORLD_CRITICAL_CHECKPOINT',
        })
        assert.equal(world_saved.ok, true, tostring(world_saved.error and world_saved.error.code))
        assert.equal(world_saved.value.status, 'COMMITTED')
        assert.equal(world_saved.value.created_save, false)
        assert.equal(world_saved.value.slot2_revision, 2)

        local loaded = load.value:load({
            player_ref = 'player_share_slot2',
            session_instance_id = 'session_share_slot2',
            request_id = 'request_load_share_slot2',
        }, invoke)
        assert.equal(loaded.ok, true, tostring(loaded.error and loaded.error.code))
        assert.equal(loaded.value.mode, 'READY')
        local payload = loaded.value.loaded_envelopes[2].payload

        assert.equal(payload.quest_runs ~= nil, true)
        assert.equal(#payload.quest_runs, 1)
        assert.equal(payload.quest_runs[1].run_id, 'qrun_share_slot2')
        assert.equal(payload.quest_runs[1].status, 'ACTIVE')
        assert.equal(payload.quest_metadata.session_revision >= 1, true)

        assert.equal(payload.world_position ~= nil, true)
        assert.equal(payload.world_position.location_id, 'location_share_gate')
        assert.equal(payload.world_position.current_marker_id, 'marker_share_gate')
        assert.equal(#payload.world_discovered_locations, 1)
        assert.equal(
            payload.world_discovered_locations[1].location_id,
            'location_share_gate'
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_2_revision,
            loaded.value.loaded_envelopes[2].revision
        )

        -- 3) Quest write again must not clobber world_* sections.
        local tracked = quest.value:track({
            run_id = 'qrun_share_slot2',
            tracking_position = 1,
            command_id = 'cmd_share_track',
            player_save_scope = 'player_share_slot2',
            request_id = 'request_share_track',
        })
        assert.equal(tracked.ok, true)
        assert.equal(tracked.value.save.status, 'COMMITTED')
        assert.equal(tracked.value.save.slot2_revision, 3)

        local reloaded = load.value:load({
            player_ref = 'player_share_slot2',
            session_instance_id = 'session_share_slot2_b',
            request_id = 'request_load_share_slot2_b',
        }, invoke)
        assert.equal(reloaded.ok, true)
        local payload2 = reloaded.value.loaded_envelopes[2].payload
        assert.equal(#payload2.quest_runs, 1)
        assert.equal(#payload2.tracked_quest_runs, 1)
        assert.equal(payload2.tracked_quest_runs[1].run_id, 'qrun_share_slot2')
        assert.equal(payload2.world_position.location_id, 'location_share_gate')
        assert.equal(#payload2.world_discovered_locations, 1)

        -- 4) Hydrate fresh stores from reloaded slot-2 payload and resume.
        local fresh_quest_store = FakeQuestStore.new()
        assert.equal(fresh_quest_store.ok, true)
        local imported_quest = fresh_quest_store.value:import_save_bundle({
            quest_metadata = payload2.quest_metadata,
            quest_runs = payload2.quest_runs,
            quest_objectives = payload2.quest_objectives,
            quest_event_receipts = payload2.quest_event_receipts,
            revealed_hidden_quests = payload2.revealed_hidden_quests,
            tracked_quest_runs = payload2.tracked_quest_runs,
        })
        assert.equal(imported_quest.ok, true)

        local fresh_world_store = FakeWorldStore.new()
        assert.equal(fresh_world_store.ok, true)
        local imported_world = fresh_world_store.value:import_save_bundle({
            world_metadata = payload2.world_metadata,
            world_position = payload2.world_position,
            world_discovered_locations = payload2.world_discovered_locations,
            world_flags = payload2.world_flags,
            world_event_receipts = payload2.world_event_receipts,
            world_interactable_states = payload2.world_interactable_states,
        })
        assert.equal(imported_world.ok, true)

        local resumed_quest = QuestService.bind({
            catalog = quest_catalog.value,
            quest_store = fresh_quest_store.value,
        })
        assert.equal(resumed_quest.ok, true)
        local run = resumed_quest.value:get_run('qrun_share_slot2')
        assert.equal(run.ok, true)
        assert.equal(run.value.run.status, 'ACTIVE')
        assert.equal(#resumed_quest.value:get_tracked().value.tracked, 1)

        local resumed_world = WorldService.bind({
            catalog = world_catalog.value,
            world_store = fresh_world_store.value,
        })
        assert.equal(resumed_world.ok, true)
        local position = resumed_world.value:get_position()
        assert.equal(position.ok, true)
        assert.equal(position.value.location_id, 'location_share_gate')
        assert.equal(
            resumed_world.value:is_discovered('location_share_gate').value,
            true
        )
    end),

    case('quest complete multi-slot checkpoint writes slots 2/4/5 once', function()
        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)
        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)

        local quest_catalog = QuestCatalog.seal({
            objective_definitions = {
                {
                    id = 'objective_complete_multi_talk',
                    schema_version = 1,
                    rules_version = 1,
                    stage_id = 'stage_complete_multi_01',
                    objective_type = 'TALK',
                    target_id = 'dialogue_complete_multi',
                    required_count = 1,
                    progress_semantics = 'ONCE_FACT',
                    event_type = 'DialogueCompleted',
                    description_key = 'obj.complete_multi.desc',
                    completed_key = 'obj.complete_multi.done',
                },
            },
            stage_definitions = {
                {
                    id = 'stage_complete_multi_01',
                    schema_version = 1,
                    rules_version = 1,
                    quest_id = 'quest_side_complete_multi',
                    objective_ids = { 'objective_complete_multi_talk' },
                    completion_mode = 'ALL',
                    journal_text_key = 'stage.complete_multi_01',
                },
            },
            quest_definitions = {
                {
                    id = 'quest_side_complete_multi',
                    schema_version = 1,
                    definition_version = 1,
                    rules_version = 1,
                    category = 'SIDE',
                    chapter_id = 'chapter_01',
                    title_key = 'quest.side_complete_multi.title',
                    summary_key = 'quest.side_complete_multi.summary',
                    accept_policy = 'MANUAL_NPC',
                    accept_ref_id = 'npc_complete_multi',
                    first_stage_id = 'stage_complete_multi_01',
                    stage_ids = { 'stage_complete_multi_01' },
                    reward_policy = 'AUTO_ON_COMPLETE',
                    reward_id = 'reward_quest_complete_multi',
                    abandon_policy = 'ALLOW_RESET_RUN',
                    journal_sort_order = 40,
                },
            },
        })
        assert.equal(quest_catalog.ok, true, tostring(
            quest_catalog.error and quest_catalog.error.details
                and quest_catalog.error.details.reason
        ))

        local currency_catalog = CurrencyCatalog.build({
            currency_definitions = {
                {
                    id = 'currency_copper',
                    schema_version = 1,
                    category = 'SOFT',
                    balance_cap = 100000,
                    source_policy_id = 'currpolicy_copper_source',
                    sink_policy_id = 'currpolicy_copper_sink',
                    name_key = 'currency.copper.name',
                },
            },
        })
        assert.equal(currency_catalog.ok, true)
        local reward_catalog = RewardCatalog.build({
            reward_bundles = {
                {
                    id = 'reward_quest_complete_multi',
                    schema_version = 1,
                    entries = {
                        {
                            entry_order = 1,
                            entry_type = 'CURRENCY',
                            target_id = 'currency_copper',
                            quantity_min = 40,
                            quantity_max = 40,
                        },
                    },
                },
            },
        })
        assert.equal(reward_catalog.ok, true)

        local quest_store = FakeQuestStore.new()
        assert.equal(quest_store.ok, true)
        local economy_store = FakeEconomyStore.new()
        assert.equal(economy_store.ok, true)

        -- Economy intentionally has no save_bridge: completion bridge owns cloud write.
        local economy = EconomyService.bind({
            currency_catalog = currency_catalog.value,
            reward_catalog = reward_catalog.value,
            store = economy_store.value,
        })
        assert.equal(economy.ok, true)

        local completion_bridge = QuestCompletionSaveBridge.bind({
            quest_store = quest_store.value,
            economy_store = economy_store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 143001,
        })
        assert.equal(completion_bridge.ok, true)

        local quest = QuestService.bind({
            catalog = quest_catalog.value,
            quest_store = quest_store.value,
            economy_service = economy.value,
            completion_save_bridge = completion_bridge.value,
            auto_track_main = false,
        })
        assert.equal(quest.ok, true)

        assert.equal(quest.value:accept({
            quest_id = 'quest_side_complete_multi',
            run_id = 'qrun_complete_multi',
            accept_receipt_id = 'rcpt_accept_complete_multi',
            command_id = 'cmd_accept_complete_multi',
        }).ok, true)
        assert.equal(quest.value:consume_fact({
            event_id = 'evt_complete_multi_talk',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_complete_multi',
            revision = 1,
            payload = { dialogue_id = 'dialogue_complete_multi' },
        }).ok, true)

        local completed = quest.value:complete({
            run_id = 'qrun_complete_multi',
            completion_receipt_id = 'rcpt_complete_multi',
            reward_receipt_id = 'rcpt_reward_complete_multi',
            command_id = 'cmd_complete_multi',
            player_save_scope = 'player_complete_multi',
            request_id = 'request_complete_multi',
        })
        assert.equal(completed.ok, true, tostring(completed.error and completed.error.code))
        assert.equal(completed.value.run.status, 'COMPLETED')
        assert.equal(completed.value.reward.status, 'COMMITTED')
        assert.equal(completed.value.reward.save.status, 'SKIPPED')
        assert.equal(completed.value.reward.save.reason, 'SKIP_SAVE')
        assert.equal(completed.value.save.status, 'COMMITTED')
        assert.equal(completed.value.save.multi_slot, true)
        assert.equal(completed.value.save.dirty_slot_count, 3)
        assert.equal(completed.value.save.created_save, true)
        assert.equal(completed.value.save.slot2_revision, 1)
        assert.equal(completed.value.save.slot4_revision, 1)
        assert.equal(completed.value.save.slot5_revision, 1)

        local balance = economy.value:get_balance('currency_copper')
        assert.equal(balance.ok, true)
        assert.equal(balance.value.balance, 40)

        local loaded = load.value:load({
            player_ref = 'player_complete_multi',
            session_instance_id = 'session_complete_multi',
            request_id = 'request_load_complete_multi',
        }, invoke)
        assert.equal(loaded.ok, true, tostring(loaded.error and loaded.error.code))
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.writable, true)

        local slot2 = loaded.value.loaded_envelopes[2].payload
        assert.equal(#slot2.quest_runs, 1)
        assert.equal(slot2.quest_runs[1].run_id, 'qrun_complete_multi')
        assert.equal(slot2.quest_runs[1].status, 'COMPLETED')
        assert.equal(
            slot2.quest_runs[1].reward_receipt_id,
            'rcpt_reward_complete_multi'
        )

        local slot4 = loaded.value.loaded_envelopes[4].payload
        assert.equal(#slot4.currency_balance_rows, 1)
        assert.equal(slot4.currency_balance_rows[1].currency_id, 'currency_copper')
        assert.equal(slot4.currency_balance_rows[1].balance, 40)

        local slot5 = loaded.value.loaded_envelopes[5].payload
        assert.equal(#slot5.economy_reward_receipts, 1)
        assert.equal(
            slot5.economy_reward_receipts[1].receipt_id,
            'rcpt_reward_complete_multi'
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_2_revision,
            loaded.value.loaded_envelopes[2].revision
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_4_revision,
            loaded.value.loaded_envelopes[4].revision
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_5_revision,
            loaded.value.loaded_envelopes[5].revision
        )
        -- One multi-slot data checkpoint: all three dirty slots share the same
        -- checkpoint_id in the committed envelopes.
        assert.equal(
            loaded.value.loaded_envelopes[2].checkpoint_id,
            loaded.value.loaded_envelopes[4].checkpoint_id
        )
        assert.equal(
            loaded.value.loaded_envelopes[4].checkpoint_id,
            loaded.value.loaded_envelopes[5].checkpoint_id
        )
    end),

    case('deliver item + reward multi-slot checkpoint writes inventory and currency', function()
        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)
        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)

        local quest_catalog = QuestCatalog.seal({
            objective_definitions = {
                {
                    id = 'objective_deliver_multi_ore',
                    schema_version = 1,
                    rules_version = 1,
                    stage_id = 'stage_deliver_multi_01',
                    objective_type = 'DELIVER_ITEM',
                    target_id = 'item_iron_ore',
                    required_count = 3,
                    progress_semantics = 'DELIVER_AT_TURN_IN',
                    description_key = 'obj.deliver_multi.desc',
                    completed_key = 'obj.deliver_multi.done',
                },
            },
            stage_definitions = {
                {
                    id = 'stage_deliver_multi_01',
                    schema_version = 1,
                    rules_version = 1,
                    quest_id = 'quest_side_deliver_multi',
                    objective_ids = { 'objective_deliver_multi_ore' },
                    completion_mode = 'ALL',
                    journal_text_key = 'stage.deliver_multi_01',
                },
            },
            quest_definitions = {
                {
                    id = 'quest_side_deliver_multi',
                    schema_version = 1,
                    definition_version = 1,
                    rules_version = 1,
                    category = 'SIDE',
                    chapter_id = 'chapter_01',
                    title_key = 'quest.side_deliver_multi.title',
                    summary_key = 'quest.side_deliver_multi.summary',
                    accept_policy = 'MANUAL_NPC',
                    accept_ref_id = 'npc_deliver_multi',
                    first_stage_id = 'stage_deliver_multi_01',
                    stage_ids = { 'stage_deliver_multi_01' },
                    reward_policy = 'AUTO_ON_COMPLETE',
                    reward_id = 'reward_quest_deliver_multi',
                    abandon_policy = 'ALLOW_RESET_RUN',
                    journal_sort_order = 45,
                },
            },
        })
        assert.equal(quest_catalog.ok, true, tostring(
            quest_catalog.error and quest_catalog.error.details
                and quest_catalog.error.details.reason
        ))

        local item_catalog = ItemCatalog.build({
            item_definitions = {
                {
                    id = 'item_iron_ore',
                    schema_version = 1,
                    category = 'MATERIAL',
                    name_key = 'item.iron_ore.name',
                    max_stack = 99,
                    ownership_cap = 999,
                    rarity = 'COMMON',
                },
                {
                    id = 'item_herb_token',
                    schema_version = 1,
                    category = 'MATERIAL',
                    name_key = 'item.herb_token.name',
                    max_stack = 20,
                    ownership_cap = 99,
                    rarity = 'COMMON',
                },
            },
        })
        assert.equal(item_catalog.ok, true)

        local currency_catalog = CurrencyCatalog.build({
            currency_definitions = {
                {
                    id = 'currency_copper',
                    schema_version = 1,
                    category = 'SOFT',
                    balance_cap = 100000,
                    source_policy_id = 'currpolicy_copper_source',
                    sink_policy_id = 'currpolicy_copper_sink',
                    name_key = 'currency.copper.name',
                },
            },
        })
        assert.equal(currency_catalog.ok, true)
        local reward_catalog = RewardCatalog.build({
            reward_bundles = {
                {
                    id = 'reward_quest_deliver_multi',
                    schema_version = 1,
                    entries = {
                        {
                            entry_order = 1,
                            entry_type = 'CURRENCY',
                            target_id = 'currency_copper',
                            quantity_min = 25,
                            quantity_max = 25,
                        },
                        {
                            entry_order = 2,
                            entry_type = 'ITEM',
                            target_id = 'item_herb_token',
                            quantity_min = 1,
                            quantity_max = 1,
                        },
                    },
                },
            },
        })
        assert.equal(reward_catalog.ok, true)

        local quest_store = FakeQuestStore.new()
        assert.equal(quest_store.ok, true)
        local economy_store = FakeEconomyStore.new()
        assert.equal(economy_store.ok, true)
        local inventory_store = FakeInventoryStore.new({ capacity_limit = 40 })
        assert.equal(inventory_store.ok, true)

        local inventory = InventoryService.bind({
            item_catalog = item_catalog.value,
            store = inventory_store.value,
        })
        assert.equal(inventory.ok, true)
        local economy = EconomyService.bind({
            currency_catalog = currency_catalog.value,
            reward_catalog = reward_catalog.value,
            store = economy_store.value,
            inventory_service = inventory.value,
        })
        assert.equal(economy.ok, true)

        local completion_bridge = QuestCompletionSaveBridge.bind({
            quest_store = quest_store.value,
            economy_store = economy_store.value,
            inventory_store = inventory_store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 144001,
        })
        assert.equal(completion_bridge.ok, true)

        local quest = QuestService.bind({
            catalog = quest_catalog.value,
            quest_store = quest_store.value,
            economy_service = economy.value,
            inventory_service = inventory.value,
            completion_save_bridge = completion_bridge.value,
            auto_track_main = false,
        })
        assert.equal(quest.ok, true)

        assert.equal(quest.value:accept({
            quest_id = 'quest_side_deliver_multi',
            run_id = 'qrun_deliver_multi',
            accept_receipt_id = 'rcpt_accept_deliver_multi',
            command_id = 'cmd_accept_deliver_multi',
        }).ok, true)

        -- Seed 5 ore: deliver costs 3, leave 2; reward adds 1 herb token.
        assert.equal(inventory.value:grant_items({
            items = { { item_id = 'item_iron_ore', amount = 5 } },
        }).ok, true)
        local ready = quest.value:refresh_snapshot_objectives({
            run_id = 'qrun_deliver_multi',
        })
        assert.equal(ready.ok, true)
        assert.equal(ready.value.run.status, 'READY_TO_TURN_IN')

        local completed = quest.value:complete({
            run_id = 'qrun_deliver_multi',
            completion_receipt_id = 'rcpt_complete_deliver_multi',
            reward_receipt_id = 'rcpt_reward_deliver_multi',
            command_id = 'cmd_complete_deliver_multi',
            player_save_scope = 'player_deliver_multi',
            request_id = 'request_deliver_multi',
        })
        assert.equal(completed.ok, true, tostring(completed.error and completed.error.code))
        assert.equal(completed.value.run.status, 'COMPLETED')
        assert.equal(completed.value.delivery.status, 'COMMITTED')
        assert.equal(completed.value.delivery.save.status, 'SKIPPED')
        assert.equal(completed.value.delivery.save.reason, 'SKIP_SAVE')
        assert.equal(completed.value.reward.status, 'COMMITTED')
        assert.equal(completed.value.reward.save.status, 'SKIPPED')
        assert.equal(completed.value.reward.save.reason, 'SKIP_SAVE')
        assert.equal(completed.value.save.status, 'COMMITTED')
        assert.equal(completed.value.save.multi_slot, true)
        assert.equal(completed.value.save.dirty_slot_count, 3)
        assert.equal(completed.value.save.slot2_revision, 1)
        assert.equal(completed.value.save.slot4_revision, 1)
        assert.equal(completed.value.save.slot5_revision, 1)

        local ore_live = inventory.value:get_count('item_iron_ore')
        assert.equal(ore_live.ok, true)
        assert.equal(ore_live.value.count, 2)
        local herb_live = inventory.value:get_count('item_herb_token')
        assert.equal(herb_live.ok, true)
        assert.equal(herb_live.value.count, 1)
        local copper_live = economy.value:get_balance('currency_copper')
        assert.equal(copper_live.ok, true)
        assert.equal(copper_live.value.balance, 25)

        local loaded = load.value:load({
            player_ref = 'player_deliver_multi',
            session_instance_id = 'session_deliver_multi',
            request_id = 'request_load_deliver_multi',
        }, invoke)
        assert.equal(loaded.ok, true, tostring(loaded.error and loaded.error.code))
        assert.equal(loaded.value.mode, 'READY')

        local slot2 = loaded.value.loaded_envelopes[2].payload
        assert.equal(slot2.quest_runs[1].status, 'COMPLETED')
        assert.equal(
            slot2.quest_runs[1].reward_receipt_id,
            'rcpt_reward_deliver_multi'
        )

        local slot4 = loaded.value.loaded_envelopes[4].payload
        assert.equal(slot4.currency_balance_rows[1].balance, 25)
        local stacks = {}
        local index
        for index = 1, #slot4.inventory_stack_rows do
            local row = slot4.inventory_stack_rows[index]
            stacks[row.item_id] = row.count
        end
        assert.equal(stacks.item_iron_ore, 2)
        assert.equal(stacks.item_herb_token, 1)

        local slot5 = loaded.value.loaded_envelopes[5].payload
        assert.equal(#slot5.economy_reward_receipts, 1)
        assert.equal(
            slot5.economy_reward_receipts[1].receipt_id,
            'rcpt_reward_deliver_multi'
        )
        assert.equal(
            loaded.value.loaded_envelopes[2].checkpoint_id,
            loaded.value.loaded_envelopes[4].checkpoint_id
        )
        assert.equal(
            loaded.value.loaded_envelopes[4].checkpoint_id,
            loaded.value.loaded_envelopes[5].checkpoint_id
        )

        -- Hydrate inventory from slot 4 and confirm resumed counts.
        local fresh_inv_store = FakeInventoryStore.new({ capacity_limit = 40 })
        assert.equal(fresh_inv_store.ok, true)
        assert.equal(fresh_inv_store.value:import_save_bundle({
            inventory_metadata = slot4.inventory_metadata,
            inventory_stack_rows = slot4.inventory_stack_rows,
        }).ok, true)
        local resumed_inv = InventoryService.bind({
            item_catalog = item_catalog.value,
            store = fresh_inv_store.value,
        })
        assert.equal(resumed_inv.ok, true)
        assert.equal(resumed_inv.value:get_count('item_iron_ore').value.count, 2)
        assert.equal(resumed_inv.value:get_count('item_herb_token').value.count, 1)
    end),
}
