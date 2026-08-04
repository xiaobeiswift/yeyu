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
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'

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
}
