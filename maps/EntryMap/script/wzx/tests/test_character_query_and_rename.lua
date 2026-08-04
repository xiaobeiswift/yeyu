local Harness = require 'wzx.tests.harness'
local CharacterCatalog = require 'wzx.config.schema.character.catalog'
local CharacterRules = require 'wzx.application.character.character_rules'
local CharacterWriteService = require 'wzx.application.use_cases.character.character_write_service'
local FakeCharacterRepository = require 'wzx.adapters.fake.character.fake_character_repository'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'

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
        tags = { 'hero' },
        deprecated = false,
    }
end

local function build_service()
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
    local repository = FakeCharacterRepository.new()
    local service = CharacterWriteService.bind({
        rules = rules.value,
        repository = repository,
    })
    assert.equal(service.ok, true)
    return service.value, CharacterWriteService.fake_invoke(repository), repository
end

return {
    case('get character detail returns primary and combat stats', function()
        local service, invoke = build_service()
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

        local detail = service:get_character_detail({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            request_id = 'request_detail_1',
            view_context = { 'PVE' },
        }, invoke)
        assert.equal(detail.ok, true, detail.error and detail.error.code)
        assert.equal(detail.value.character_id, 'char_hero')
        assert.equal(detail.value.level, 1)
        assert.equal(detail.value.experience, 0)
        assert.equal(detail.value.role, 'PROTAGONIST')
        assert.equal(detail.value.primary_attributes.strength, 10)
        assert.not_nil(detail.value.combat_stats.attack)
        -- base 10 + level*3 + strength*3 + floor(inner*500/1000) + talent 5
        assert.equal(detail.value.combat_stats.attack, 10 + 3 + 30 + 20 + 5)
        assert.equal(detail.value.unlocked_talent_ids[1], 'talent_focus')
        assert.equal(detail.value.character_save_revision, 1)
        assert.equal(detail.value.formula_id, 'formula_story_v1')
        assert.deep_equal(detail.value.view_context, { 'PVE' })
    end),

    case('rename protagonist commits and detail reflects the name', function()
        local service, invoke = build_service()
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

        local renamed = service:rename_protagonist({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            new_name = 'MistWalker',
            receipt_id = 'character:rename:hero_receipt_001',
            transaction_id = 'character_rename_hero_tx_001',
            request_id = 'request_rename_1',
        }, invoke)
        assert.equal(renamed.ok, true, renamed.error and renamed.error.code)
        assert.equal(renamed.value.status, 'COMMITTED')
        assert.equal(renamed.value.result.new_name, 'MistWalker')
        assert.equal(renamed.value.result.character_revision, 1)
        assert.equal(renamed.value.character_save_revision, 2)

        local detail = service:get_character_detail({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            request_id = 'request_detail_2',
        }, invoke)
        assert.equal(detail.ok, true)
        assert.equal(detail.value.custom_name, 'MistWalker')
        assert.equal(detail.value.revision, 1)
    end),

    case('rename rejects empty name and unchanged name', function()
        local service, invoke = build_service()
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

        local empty = service:rename_protagonist({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            new_name = '',
            receipt_id = 'character:rename:hero_empty_001',
            transaction_id = 'character_rename_empty_tx_001',
            request_id = 'request_rename_empty',
        }, invoke)
        assert.equal(empty.ok, false)
        assert.equal(empty.error.code, 'CHARACTER_NAME_INVALID')

        local first = service:rename_protagonist({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            new_name = 'MistWalker',
            receipt_id = 'character:rename:hero_receipt_001',
            transaction_id = 'character_rename_hero_tx_001',
            request_id = 'request_rename_1',
        }, invoke)
        assert.equal(first.ok, true)

        local same = service:rename_protagonist({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            new_name = 'MistWalker',
            receipt_id = 'character:rename:hero_receipt_002',
            transaction_id = 'character_rename_hero_tx_002',
            request_id = 'request_rename_2',
        }, invoke)
        assert.equal(same.ok, false)
        assert.equal(same.error.code, 'CHARACTER_NAME_INVALID')
        assert.equal(same.error.details.reason, 'NAME_UNCHANGED')
    end),

    case('get detail rejects missing character', function()
        local service, invoke = build_service()
        local missing = service:get_character_detail({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            request_id = 'request_detail_missing',
        }, invoke)
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'CHARACTER_NOT_OWNED')
    end),
}
