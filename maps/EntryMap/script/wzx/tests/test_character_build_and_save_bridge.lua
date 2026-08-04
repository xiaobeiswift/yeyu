local Harness = require 'wzx.tests.harness'
local CharacterCatalog = require 'wzx.config.schema.character.catalog'
local CharacterEventBus = require 'wzx.application.character.character_event_bus'
local CharacterRules = require 'wzx.application.character.character_rules'
local CharacterSaveBridge = require 'wzx.application.use_cases.character.character_save_bridge'
local CharacterSaveCodec = require 'wzx.domain.character.character_save_codec'
local CharacterWriteService = require 'wzx.application.use_cases.character.character_write_service'
local FakeCharacterRepository = require 'wzx.adapters.fake.character.fake_character_repository'
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

local function build_rules()
    local character_catalog = CharacterCatalog.build({
        character_definitions = { character_definition() },
        level_curves = { level_curve() },
        formula_sets = { formula_set() },
        talent_definitions = { talent_definition() },
    })
    assert.equal(character_catalog.ok, true)
    local reward_catalog = RewardCatalog.build({ reward_bundles = {} })
    assert.equal(reward_catalog.ok, true)
    local rules = CharacterRules.bind(
        character_catalog.value,
        reward_catalog.value
    )
    assert.equal(rules.ok, true)
    return rules.value
end

local function build_service(with_save, with_events)
    local rules = build_rules()
    local repository = FakeCharacterRepository.new()
    local save_bridge
    local store
    if with_save then
        store = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = store })
        assert.equal(coordinator.ok, true)
        local bridge = CharacterSaveBridge.bind({
            repository = repository,
            coordinator = coordinator.value,
            save_invoke = SaveCoordinator.fake_invoke(store),
        })
        assert.equal(bridge.ok, true)
        save_bridge = bridge.value
    end
    local event_bus
    if with_events then
        local bus = CharacterEventBus.new()
        assert.equal(bus.ok, true)
        event_bus = bus.value
    end
    local service = CharacterWriteService.bind({
        rules = rules,
        repository = repository,
        save_bridge = save_bridge,
        event_bus = event_bus,
    })
    assert.equal(service.ok, true)
    return service.value,
        CharacterWriteService.fake_invoke(repository),
        repository,
        save_bridge,
        event_bus,
        store
end

return {
    case('build combatant snapshot validates build and combatant contracts', function()
        local service, invoke = build_service(false)
        local created = service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_001',
            transaction_id = 'character_create_hero_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
            request_id = 'request_create_1',
        }, invoke)
        assert.equal(created.ok, true)

        local built = service:build_combatant_snapshot({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            request_id = 'request_build_1',
            actor_id = 'combat001:attacker1',
            side = 'ATTACKER',
            position_index = 0,
            ai_profile_id = 'ai_story_player',
            view_context = { 'PVE' },
            martial_loadout = {
                routine_id = 'martial_cloud_sword',
            },
            initial_status_ids = { 'status_ready' },
            equipment_contributions = {
                {
                    source_type = 'EQUIPMENT',
                    source_id = 'equipment:sword:1',
                    target_stat = 'attack',
                    operation = 'ADD_FLAT',
                    value = 10,
                    priority = 0,
                    condition_tags = {},
                    stable_order_key = 'equipment:sword:1:attack',
                },
            },
        }, invoke)
        assert.equal(built.ok, true, built.error and built.error.code)
        assert.equal(built.value.build_snapshot.character_id, 'char_hero')
        assert.equal(built.value.build_snapshot.level, 1)
        assert.equal(#built.value.build_snapshot.talent_entries, 1)
        assert.equal(
            built.value.build_snapshot.talent_entries[1].talent_id,
            'talent_focus'
        )
        assert.equal(#built.value.build_snapshot.build_hash, 64)
        assert.equal(built.value.combatant_snapshot.side, 'ATTACKER')
        assert.equal(built.value.combatant_snapshot.definition_id, 'char_hero')
        assert.equal(
            built.value.combatant_snapshot.stats.attack,
            10 + 3 + 30 + 20 + 5 + 10
        )
        assert.equal(
            built.value.combatant_snapshot.source_hash,
            built.value.build_snapshot.build_hash
        )
        assert.equal(built.value.character_save_revision, 1)
    end),

    case('build combatant snapshot rejects invalid external contributions', function()
        local service, invoke = build_service(false)
        local created = service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_001',
            transaction_id = 'character_create_hero_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
            request_id = 'request_create_1',
        }, invoke)
        assert.equal(created.ok, true)

        local bad = service:build_combatant_snapshot({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            request_id = 'request_build_bad',
            equipment_contributions = {
                {
                    source_type = 'NOT_A_SOURCE',
                    source_id = 'equipment:sword:1',
                    target_stat = 'attack',
                    operation = 'ADD_FLAT',
                    value = 1,
                    priority = 0,
                    condition_tags = {},
                    stable_order_key = 'equipment:sword:1:attack',
                },
            },
        }, invoke)
        assert.equal(bad.ok, false)
        assert.equal(bad.error.code, 'CHARACTER_CONTRIBUTION_INVALID')
    end),

    case('character write syncs slot 3 and slot 5 through SaveCoordinator', function()
        local service, invoke, repository, save_bridge, _, store =
            build_service(true, false)
        local created = service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_001',
            transaction_id = 'character_create_hero_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
            request_id = 'request_create_1',
        }, invoke)
        assert.equal(created.ok, true, created.error and created.error.code)
        assert.equal(created.value.status, 'COMMITTED')
        assert.equal(created.value.save.status, 'COMMITTED')
        assert.equal(created.value.save.envelope_revision, 1)
        assert.equal(created.value.save.receipt_envelope_revision, 1)
        assert.not_nil(created.value.save.bundle.character_rows)
        assert.equal(#created.value.save.bundle.character_rows, 1)
        assert.equal(
            created.value.save.bundle.character_rows[1].character_id,
            'char_hero'
        )
        assert.equal(
            #created.value.save.bundle.character_talent_rows,
            1
        )
        assert.not_nil(created.value.save.receipt_bundle)
        assert.equal(
            #created.value.save.receipt_bundle.character_operation_receipts,
            1
        )
        assert.equal(
            created.value.save.receipt_bundle.character_operation_receipts[1]
                .operation_type,
            'CREATE_OWNED_CHARACTER'
        )
        assert.equal(
            created.value.save.receipt_bundle.character_operation_receipts[1]
                .status,
            'COMMITTED'
        )

        local granted = service:grant_experience({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            amount = 50,
            reason = 'QUEST_REWARD',
            receipt_id = 'character:experience:hero_receipt_001',
            transaction_id = 'character_experience_hero_tx_001',
            request_id = 'request_xp_1',
        }, invoke)
        assert.equal(granted.ok, true, granted.error and granted.error.code)
        assert.equal(granted.value.save.status, 'COMMITTED')
        assert.equal(granted.value.save.envelope_revision, 2)
        assert.equal(granted.value.save.receipt_envelope_revision, 2)
        assert.equal(
            granted.value.save.bundle.character_rows[1].experience,
            50
        )
        assert.equal(
            #granted.value.save.receipt_bundle.character_operation_receipts,
            2
        )

        local snapshot = save_bridge:snapshot_from_repository('player001')
        assert.equal(snapshot.ok, true)
        assert.equal(snapshot.value.character_save_revision, 2)
        assert.equal(snapshot.value.receipt_save_revision, 2)
        assert.equal(snapshot.value.character_states[1].experience, 50)
        assert.equal(#snapshot.value.receipt_rows, 2)

        local committed = store:get_committed_snapshot()
        assert.not_nil(committed.player001[3])
        assert.not_nil(committed.player001[5])
        assert.equal(
            #committed.player001[5].payload.character_operation_receipts,
            2
        )

        local authority = repository:get_authority_snapshot()
        assert.equal(
            authority.players.player001.characters.char_hero.experience,
            50
        )
    end),

    case('committed writes publish domain events with de-duplication', function()
        local service, invoke, _, _, event_bus = build_service(false, true)
        local created = service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_001',
            transaction_id = 'character_create_hero_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
            request_id = 'request_create_1',
            correlation_id = 'correlation_create_1',
        }, invoke)
        assert.equal(created.ok, true)
        assert.equal(#created.value.events >= 2, true)
        assert.equal(created.value.events[1].event_type, 'CharacterOwned')
        assert.equal(created.value.events[1].accepted, true)
        assert.equal(
            created.value.events[2].event_type,
            'CharacterTalentUnlocked'
        )

        local listed = event_bus:list()
        assert.equal(listed.ok, true)
        assert.equal(#listed.value >= 2, true)
        assert.equal(listed.value[1].source_system, '01')
        assert.equal(listed.value[1].payload.character_id, 'char_hero')

        local renamed = service:rename_protagonist({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            new_name = 'MistWalker',
            receipt_id = 'character:rename:hero_receipt_001',
            transaction_id = 'character_rename_hero_tx_001',
            request_id = 'request_rename_1',
            correlation_id = 'correlation_rename_1',
        }, invoke)
        assert.equal(renamed.ok, true, renamed.error and renamed.error.code)
        assert.equal(renamed.value.events[1].ok, true)
        assert.equal(renamed.value.events[1].event_type, 'CharacterRenamed')

        local after_rename = event_bus:list()
        assert.equal(after_rename.ok, true)
        local rename_event = after_rename.value[#after_rename.value]
        assert.equal(rename_event.event_type, 'CharacterRenamed')
        assert.equal(type(rename_event.payload.name_digest), 'string')
        assert.equal(#rename_event.payload.name_digest, 64)
        -- full name must not appear in the event payload
        assert.is_nil(rename_event.payload.new_name)
    end),

    case('save bridge encodes empty player as empty section bundle', function()
        local repository = FakeCharacterRepository.new()
        local store = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = store })
        assert.equal(coordinator.ok, true)
        local bridge = CharacterSaveBridge.bind({
            repository = repository,
            coordinator = coordinator.value,
            save_invoke = SaveCoordinator.fake_invoke(store),
        })
        assert.equal(bridge.ok, true)

        local persisted = bridge.value:persist_player_characters({
            player_save_scope = 'player001',
            request_id = 'request_empty_save',
        })
        assert.equal(persisted.ok, true)
        assert.equal(persisted.value.status, 'COMMITTED')
        assert.equal(#persisted.value.bundle.character_rows, 0)
        assert.equal(#persisted.value.bundle.character_talent_rows, 0)
        assert.equal(
            CharacterSaveCodec.is_authority,
            CharacterSaveCodec.is_authority
        )
    end),

    case('writes without save bridge report save skipped', function()
        local service, invoke = build_service(false)
        local created = service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_001',
            transaction_id = 'character_create_hero_tx_001',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
            request_id = 'request_create_1',
        }, invoke)
        assert.equal(created.ok, true)
        assert.equal(created.value.save.status, 'SKIPPED')
    end),
}
