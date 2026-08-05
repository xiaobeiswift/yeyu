-- Offline golden path: play → multi-system checkpoint → LoadGameSave → hydrate → resume.

local Harness = require 'wzx.tests.harness'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
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
local HydrateGameRuntime = require 'wzx.application.use_cases.save.hydrate_game_runtime'
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

local PLAYER = 'player_golden_001'
local SEED = 900001

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

local function level_curve()
    return {
        id = 'curve_level_story',
        level_cap = 4,
        cumulative_exp_by_level = { 0, 100, 250, 500 },
        experience_cap = 1000,
        level_reward_refs = {},
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

local function leaf(order, entry_type, target_id, quantity)
    return {
        entry_order = order,
        entry_type = entry_type,
        target_id = target_id,
        quantity_min = quantity,
        quantity_max = quantity,
    }
end

local function build_catalogs()
    local character_catalog = CharacterCatalog.build({
        character_definitions = { character_definition() },
        level_curves = { level_curve() },
        formula_sets = { formula_set() },
        talent_definitions = { talent_definition() },
    })
    assert.equal(character_catalog.ok, true)

    local reward_catalog = RewardCatalog.build({
        reward_bundles = {
            {
                id = 'reward_quest_golden',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 40),
                },
            },
            {
                id = 'reward_bonus_copper',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 15),
                },
            },
        },
    })
    assert.equal(reward_catalog.ok, true)

    local character_rules = CharacterRules.bind(
        character_catalog.value,
        reward_catalog.value
    )
    assert.equal(character_rules.ok, true)

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

    local item_catalog = ItemCatalog.build({
        item_definitions = {
            {
                id = 'item_herb',
                schema_version = 1,
                category = 'MATERIAL',
                name_key = 'item.herb.name',
                max_stack = 99,
                ownership_cap = 999,
            },
        },
    })
    assert.equal(item_catalog.ok, true)

    local quest_catalog = QuestCatalog.seal({
        objective_definitions = {
            {
                id = 'objective_golden_talk',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_golden_01',
                objective_type = 'TALK',
                target_id = 'dialogue_golden',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'DialogueCompleted',
                description_key = 'obj.golden.desc',
                completed_key = 'obj.golden.done',
            },
        },
        stage_definitions = {
            {
                id = 'stage_golden_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_side_golden',
                objective_ids = { 'objective_golden_talk' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.golden_01',
            },
        },
        quest_definitions = {
            {
                id = 'quest_side_golden',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'SIDE',
                chapter_id = 'chapter_01',
                title_key = 'quest.side_golden.title',
                summary_key = 'quest.side_golden.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_golden',
                first_stage_id = 'stage_golden_01',
                stage_ids = { 'stage_golden_01' },
                reward_policy = 'AUTO_ON_COMPLETE',
                reward_id = 'reward_quest_golden',
                abandon_policy = 'ALLOW_RESET_RUN',
                journal_sort_order = 10,
            },
        },
    })
    assert.equal(quest_catalog.ok, true, tostring(
        quest_catalog.error and quest_catalog.error.details
            and quest_catalog.error.details.reason
    ))

    local world_catalog = WorldCatalog.seal({
        flag_definitions = {
            {
                id = 'flag_golden_bridge',
                schema_version = 1,
                rules_version = 1,
                value_type = 'BOOLEAN',
                default_value = false,
            },
        },
        location_definitions = {
            {
                id = 'location_golden_gate',
                schema_version = 1,
                rules_version = 1,
                area_id = 'area_golden',
                name_key = 'location.golden_gate',
                discovery_marker_id = 'marker_golden_gate',
                safe_return_marker_id = 'marker_golden_gate',
                neighbor_location_ids = { 'location_golden_inn' },
                map_sort_order = 10,
            },
            {
                id = 'location_golden_inn',
                schema_version = 1,
                rules_version = 1,
                area_id = 'area_golden',
                name_key = 'location.golden_inn',
                discovery_marker_id = 'marker_golden_inn',
                safe_return_marker_id = 'marker_golden_inn',
                neighbor_location_ids = { 'location_golden_gate' },
                map_sort_order = 20,
            },
        },
        area_definitions = {
            {
                id = 'area_golden',
                schema_version = 1,
                rules_version = 1,
                area_type = 'TOWN',
                name_key = 'area.golden',
                location_ids = {
                    'location_golden_gate',
                    'location_golden_inn',
                },
                entry_marker_id = 'marker_golden_gate',
            },
        },
        interactable_definitions = {},
    })
    assert.equal(world_catalog.ok, true, tostring(
        world_catalog.error and world_catalog.error.details
            and world_catalog.error.details.reason
    ))

    return {
        character_rules = character_rules.value,
        character_catalog = character_catalog.value,
        reward_catalog = reward_catalog.value,
        currency_catalog = currency_catalog.value,
        item_catalog = item_catalog.value,
        quest_catalog = quest_catalog.value,
        world_catalog = world_catalog.value,
        character_references = {
            character_definition_versions = {
                char_hero = 3,
            },
            talent_ids = { 'talent_focus' },
        },
    }
end

local function bind_play_stack(memory, catalogs)
    local coordinator = SaveCoordinator.bind({ save_store = memory })
    assert.equal(coordinator.ok, true)
    local invoke = SaveCoordinator.fake_invoke(memory)
    local load = LoadGameSave.bind({ coordinator = coordinator.value })
    assert.equal(load.ok, true)
    local hydrate = HydrateGameRuntime.bind({})
    assert.equal(hydrate.ok, true)

    local character_repo = FakeCharacterRepository.new()
    local character_bridge = CharacterSaveBridge.bind({
        repository = character_repo,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(character_bridge.ok, true)
    local character_service = CharacterWriteService.bind({
        rules = catalogs.character_rules,
        repository = character_repo,
        save_bridge = character_bridge.value,
    })
    assert.equal(character_service.ok, true)

    local economy_store = FakeEconomyStore.new()
    assert.equal(economy_store.ok, true)
    local economy_bridge = EconomySaveBridge.bind({
        store = economy_store.value,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(economy_bridge.ok, true)
    local economy_service = EconomyService.bind({
        currency_catalog = catalogs.currency_catalog,
        reward_catalog = catalogs.reward_catalog,
        store = economy_store.value,
        save_bridge = economy_bridge.value,
    })
    assert.equal(economy_service.ok, true)

    local inventory_store = FakeInventoryStore.new()
    assert.equal(inventory_store.ok, true)
    local inventory_service = InventoryService.bind({
        item_catalog = catalogs.item_catalog,
        store = inventory_store.value,
    })
    assert.equal(inventory_service.ok, true)

    local quest_store = FakeQuestStore.new()
    assert.equal(quest_store.ok, true)
    local quest_bridge = QuestSaveBridge.bind({
        store = quest_store.value,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(quest_bridge.ok, true)
    local completion_bridge = QuestCompletionSaveBridge.bind({
        quest_store = quest_store.value,
        economy_store = economy_store.value,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(completion_bridge.ok, true)
    local quest_service = QuestService.bind({
        catalog = catalogs.quest_catalog,
        quest_store = quest_store.value,
        economy_service = economy_service.value,
        save_bridge = quest_bridge.value,
        completion_save_bridge = completion_bridge.value,
        auto_track_main = false,
    })
    assert.equal(quest_service.ok, true)

    local world_store = FakeWorldStore.new()
    assert.equal(world_store.ok, true)
    local world_bridge = WorldSaveBridge.bind({
        store = world_store.value,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(world_bridge.ok, true)
    local world_service = WorldService.bind({
        catalog = catalogs.world_catalog,
        world_store = world_store.value,
        save_bridge = world_bridge.value,
    })
    assert.equal(world_service.ok, true)

    return {
        memory = memory,
        coordinator = coordinator.value,
        invoke = invoke,
        load = load.value,
        hydrate = hydrate.value,
        catalogs = catalogs,
        character_repo = character_repo,
        character_service = character_service.value,
        character_invoke = CharacterWriteService.fake_invoke(character_repo),
        economy_store = economy_store.value,
        economy_service = economy_service.value,
        inventory_store = inventory_store.value,
        inventory_service = inventory_service.value,
        quest_store = quest_store.value,
        quest_service = quest_service.value,
        world_store = world_store.value,
        world_service = world_service.value,
        world_bridge = world_bridge.value,
    }
end

local function bind_resumed_stack(memory, catalogs, hydrated)
    local coordinator = SaveCoordinator.bind({ save_store = memory })
    assert.equal(coordinator.ok, true)
    local invoke = SaveCoordinator.fake_invoke(memory)

    local character_bridge = CharacterSaveBridge.bind({
        repository = hydrated.character_repo,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(character_bridge.ok, true)
    local character_service = CharacterWriteService.bind({
        rules = catalogs.character_rules,
        repository = hydrated.character_repo,
        save_bridge = character_bridge.value,
    })
    assert.equal(character_service.ok, true)

    local economy_bridge = EconomySaveBridge.bind({
        store = hydrated.economy_store,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(economy_bridge.ok, true)
    local economy_service = EconomyService.bind({
        currency_catalog = catalogs.currency_catalog,
        reward_catalog = catalogs.reward_catalog,
        store = hydrated.economy_store,
        save_bridge = economy_bridge.value,
    })
    assert.equal(economy_service.ok, true)

    local quest_bridge = QuestSaveBridge.bind({
        store = hydrated.quest_store,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(quest_bridge.ok, true)
    local quest_service = QuestService.bind({
        catalog = catalogs.quest_catalog,
        quest_store = hydrated.quest_store,
        save_bridge = quest_bridge.value,
        auto_track_main = false,
    })
    assert.equal(quest_service.ok, true)

    local world_bridge = WorldSaveBridge.bind({
        store = hydrated.world_store,
        coordinator = coordinator.value,
        save_invoke = invoke,
        default_save_seed = SEED,
    })
    assert.equal(world_bridge.ok, true)
    local world_service = WorldService.bind({
        catalog = catalogs.world_catalog,
        world_store = hydrated.world_store,
        save_bridge = world_bridge.value,
    })
    assert.equal(world_service.ok, true)

    local load = LoadGameSave.bind({ coordinator = coordinator.value })
    assert.equal(load.ok, true)

    return {
        invoke = invoke,
        load = load.value,
        character_service = character_service.value,
        character_invoke = CharacterWriteService.fake_invoke(hydrated.character_repo),
        economy_service = economy_service.value,
        quest_service = quest_service.value,
        world_service = world_service.value,
        world_bridge = world_bridge.value,
    }
end

local function hydrate_from_load(load_result, catalogs)
    local character_repo = FakeCharacterRepository.new()
    local economy_store = FakeEconomyStore.new()
    assert.equal(economy_store.ok, true)
    local inventory_store = FakeInventoryStore.new()
    assert.equal(inventory_store.ok, true)
    local quest_store = FakeQuestStore.new()
    assert.equal(quest_store.ok, true)
    local world_store = FakeWorldStore.new()
    assert.equal(world_store.ok, true)

    local hydrate = HydrateGameRuntime.bind({})
    assert.equal(hydrate.ok, true)
    local hydrated = hydrate.value:hydrate({
        load_result = load_result,
        player_save_scope = PLAYER,
        targets = {
            quest_store = quest_store.value,
            world_store = world_store.value,
            inventory_store = inventory_store.value,
            economy_store = economy_store.value,
            character_repository = character_repo,
            character_references = catalogs.character_references,
        },
    })
    assert.equal(hydrated.ok, true, tostring(
        hydrated.error and hydrated.error.code
    ) .. ' ' .. tostring(
        hydrated.error and hydrated.error.details
            and hydrated.error.details.reason
    ))

    local by_system = {}
    local index
    for index = 1, #hydrated.value.systems do
        local row = hydrated.value.systems[index]
        by_system[row.system_id] = row.status
    end
    return {
        report = hydrated.value,
        by_system = by_system,
        character_repo = character_repo,
        economy_store = economy_store.value,
        inventory_store = inventory_store.value,
        quest_store = quest_store.value,
        world_store = world_store.value,
    }
end

return {
    case('play save load hydrate resumes character quest world and economy', function()
        local catalogs = build_catalogs()
        local memory = MemorySaveStore.new()
        local play = bind_play_stack(memory, catalogs)

        -- 1) Create protagonist (slots 1/3/5).
        local created = play.character_service:create_owned({
            player_save_scope = PLAYER,
            character_id = 'char_hero',
            receipt_id = 'character:create:golden_hero_001',
            transaction_id = 'character_create_golden_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_side_golden:reward:1',
            request_id = 'request_golden_create',
        }, play.character_invoke)
        assert.equal(created.ok, true, created.error and created.error.code)
        assert.equal(created.value.save.status, 'COMMITTED')

        -- 2) Bootstrap world and discover gate (slot 2 via explicit world bridge).
        assert.equal(play.world_service:bootstrap_position({
            location_id = 'location_golden_gate',
            marker_id = 'marker_golden_gate',
            current_cell_id = 'traversal_cell_golden_gate',
        }).ok, true)
        assert.equal(play.world_service:discover_location({
            location_id = 'location_golden_gate',
            discovery_receipt_id = 'rcpt_golden_discover_gate',
            command_id = 'cmd_golden_discover_gate',
        }).ok, true)
        local world_saved = play.world_bridge:persist_player_world({
            player_save_scope = PLAYER,
            request_id = 'request_golden_world_save',
            command_id = 'cmd_golden_world_ckpt',
            reason = 'WORLD_CRITICAL_CHECKPOINT',
        })
        assert.equal(world_saved.ok, true, world_saved.error and world_saved.error.code)
        assert.equal(world_saved.value.status, 'COMMITTED')

        -- 3) Accept quest (slot 2 quest sections).
        local accepted = play.quest_service:accept({
            quest_id = 'quest_side_golden',
            run_id = 'qrun_golden',
            accept_receipt_id = 'rcpt_golden_accept',
            command_id = 'cmd_golden_accept',
            player_save_scope = PLAYER,
            request_id = 'request_golden_accept',
        })
        assert.equal(accepted.ok, true, accepted.error and accepted.error.code)
        assert.equal(accepted.value.save.status, 'COMMITTED')

        -- 4) Talk fact then complete with multi-slot reward checkpoint.
        assert.equal(play.quest_service:consume_fact({
            event_id = 'evt_golden_talk',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_golden',
            revision = 1,
            payload = { dialogue_id = 'dialogue_golden' },
        }).ok, true)

        local completed = play.quest_service:complete({
            run_id = 'qrun_golden',
            completion_receipt_id = 'rcpt_golden_complete',
            reward_receipt_id = 'rcpt_golden_reward',
            command_id = 'cmd_golden_complete',
            player_save_scope = PLAYER,
            request_id = 'request_golden_complete',
        })
        assert.equal(completed.ok, true, completed.error and completed.error.code)
        assert.equal(completed.value.run.status, 'COMPLETED')
        assert.equal(completed.value.save.status, 'COMMITTED')
        assert.equal(play.economy_service:get_balance('currency_copper').value.balance, 40)

        -- 5) Load envelopes from cloud authority.
        local loaded = play.load:load({
            player_ref = PLAYER,
            session_instance_id = 'session_golden_1',
            request_id = 'request_load_golden_1',
        }, play.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.writable, true)
        assert.equal(loaded.value.loaded_envelopes[2] ~= nil, true)
        assert.equal(loaded.value.loaded_envelopes[3] ~= nil, true)
        assert.equal(loaded.value.loaded_envelopes[4] ~= nil, true)
        assert.equal(loaded.value.loaded_envelopes[5] ~= nil, true)

        -- 6) Hydrate fresh runtime stores from load result.
        local fresh = hydrate_from_load(loaded.value, catalogs)
        assert.equal(fresh.by_system.character, 'HYDRATED')
        assert.equal(fresh.by_system.quest, 'HYDRATED')
        assert.equal(fresh.by_system.world, 'HYDRATED')
        assert.equal(fresh.by_system.economy, 'HYDRATED')
        assert.equal(fresh.by_system.inventory, 'SKIPPED')

        local resumed = bind_resumed_stack(memory, catalogs, fresh)

        local detail = resumed.character_service:get_character_detail({
            player_save_scope = PLAYER,
            character_id = 'char_hero',
            request_id = 'request_golden_detail',
            view_context = { 'PVE' },
        }, resumed.character_invoke)
        assert.equal(detail.ok, true, detail.error and detail.error.code)
        assert.equal(detail.value.level, 1)
        assert.equal(detail.value.experience, 0)
        assert.equal(detail.value.unlocked_talent_ids[1], 'talent_focus')

        local run = resumed.quest_service:get_run('qrun_golden')
        assert.equal(run.ok, true)
        assert.equal(run.value.run.status, 'COMPLETED')
        assert.equal(run.value.run.reward_receipt_id, 'rcpt_golden_reward')

        local position = resumed.world_service:get_position()
        assert.equal(position.ok, true)
        assert.equal(position.value.location_id, 'location_golden_gate')
        assert.equal(
            resumed.world_service:is_discovered('location_golden_gate').value,
            true
        )

        local balance = resumed.economy_service:get_balance('currency_copper')
        assert.equal(balance.ok, true)
        assert.equal(balance.value.balance, 40)

        -- 7) Continue play on hydrated runtime and checkpoint again.
        assert.equal(resumed.world_service:enter_location({
            location_id = 'location_golden_inn',
            marker_id = 'marker_golden_inn',
            current_cell_id = 'traversal_cell_golden_inn',
        }).ok, true)
        assert.equal(resumed.world_service:discover_location({
            location_id = 'location_golden_inn',
            discovery_receipt_id = 'rcpt_golden_discover_inn',
            command_id = 'cmd_golden_discover_inn',
        }).ok, true)
        local world_again = resumed.world_bridge:persist_player_world({
            player_save_scope = PLAYER,
            request_id = 'request_golden_world_save_2',
            command_id = 'cmd_golden_world_ckpt_2',
            reason = 'WORLD_CRITICAL_CHECKPOINT',
        })
        assert.equal(world_again.ok, true, world_again.error and world_again.error.code)
        assert.equal(world_again.value.status, 'COMMITTED')

        local prepared = resumed.economy_service:prepare_reward({
            reward_id = 'reward_bonus_copper',
            source_type = 'QUEST',
            source_ref = 'reward_bonus_copper',
            source_occurrence_id = 'quest_bonus_golden_001',
        })
        assert.equal(prepared.ok, true)
        local receipt = CanonicalReceiptHashV1.derive('economy_bonus_receipt', {
            { name = 'label', type = 'STRING' },
        }, { label = 'golden_bonus' })
        assert.equal(receipt.ok, true)
        local granted = resumed.economy_service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = receipt.value.receipt_id,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_bonus_golden',
            player_save_scope = PLAYER,
            request_id = 'request_golden_bonus_grant',
        })
        assert.equal(granted.ok, true, granted.error and granted.error.code)
        assert.equal(granted.value.save.status, 'COMMITTED')
        assert.equal(
            resumed.economy_service:get_balance('currency_copper').value.balance,
            55
        )

        -- 8) Second load+hydrate proves continued writes re-enter READY consistently.
        local reloaded = resumed.load:load({
            player_ref = PLAYER,
            session_instance_id = 'session_golden_2',
            request_id = 'request_load_golden_2',
        }, resumed.invoke)
        assert.equal(reloaded.ok, true, reloaded.error and reloaded.error.code)
        assert.equal(reloaded.value.mode, 'READY')

        local again = hydrate_from_load(reloaded.value, catalogs)
        assert.equal(again.by_system.character, 'HYDRATED')
        assert.equal(again.by_system.quest, 'HYDRATED')
        assert.equal(again.by_system.world, 'HYDRATED')
        assert.equal(again.by_system.economy, 'HYDRATED')

        local final_world = WorldService.bind({
            catalog = catalogs.world_catalog,
            world_store = again.world_store,
        })
        assert.equal(final_world.ok, true)
        assert.equal(
            final_world.value:get_position().value.location_id,
            'location_golden_inn'
        )
        assert.equal(
            final_world.value:is_discovered('location_golden_inn').value,
            true
        )

        local final_economy = EconomyService.bind({
            currency_catalog = catalogs.currency_catalog,
            reward_catalog = catalogs.reward_catalog,
            store = again.economy_store,
        })
        assert.equal(final_economy.ok, true)
        assert.equal(
            final_economy.value:get_balance('currency_copper').value.balance,
            55
        )

        local final_quest = QuestService.bind({
            catalog = catalogs.quest_catalog,
            quest_store = again.quest_store,
            auto_track_main = false,
        })
        assert.equal(final_quest.ok, true)
        assert.equal(
            final_quest.value:get_run('qrun_golden').value.run.status,
            'COMPLETED'
        )
    end),

    case('hydrate rejects non-ready load results', function()
        local hydrate = HydrateGameRuntime.bind({})
        assert.equal(hydrate.ok, true)
        local rejected = hydrate.value:hydrate({
            load_result = {
                mode = 'CONFIRMED_ABSENT',
                writable = false,
                loaded_envelopes = {},
            },
            player_save_scope = PLAYER,
            targets = {},
        })
        assert.equal(rejected.ok, false)
        assert.equal(rejected.error.code, 'SAVE_SESSION_INVALID')
        assert.equal(rejected.error.details.reason, 'LOAD_NOT_READY')
    end),
}
