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
        cumulative_exp_by_level = {
            0,
            100,
            250,
            500,
        },
        experience_cap = 1000,
        level_reward_refs = {
            {
                reached_level = 2,
                reward_ref = 'reward_level_two',
            },
            {
                reached_level = 4,
                reward_ref = 'reward_level_four',
            },
        },
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
        combat_hook_ids = {
            'hook_talent_focus',
        },
        exclusive_group = nil,
        tags = {
            'focus',
        },
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
        default_talent_ids = {
            'talent_focus',
        },
        initial_qi = 100,
        model_asset_id = 'model_hero',
        portrait_asset_id = 'portrait_hero',
        tags = {
            'hero',
        },
        deprecated = false,
    }
end

local function reward_source()
    return {
        reward_bundles = {
            {
                id = 'reward_level_two',
                schema_version = 1,
                entries = {
                    {
                        entry_order = 1,
                        entry_type = 'CURRENCY',
                        target_id = 'currency_copper',
                        quantity_min = 50,
                        quantity_max = 50,
                    },
                },
            },
            {
                id = 'reward_level_four',
                schema_version = 1,
                entries = {
                    {
                        entry_order = 1,
                        entry_type = 'ITEM',
                        target_id = 'item_iron_ore',
                        quantity_min = 1,
                        quantity_max = 1,
                    },
                },
            },
        },
    }
end

local function build_service(options)
    options = options or {}
    local character_catalog = CharacterCatalog.build({
        character_definitions = { character_definition() },
        level_curves = { level_curve() },
        formula_sets = { formula_set() },
        talent_definitions = { talent_definition() },
    })
    assert.equal(character_catalog.ok, true)

    local reward_catalog = nil
    if options.bind_reward ~= false then
        local built_reward = RewardCatalog.build(reward_source())
        assert.equal(built_reward.ok, true)
        reward_catalog = built_reward.value
    end

    local rules = CharacterRules.bind(character_catalog.value, reward_catalog)
    assert.equal(rules.ok, true)

    local repository = FakeCharacterRepository.new(options.repository or {})
    local service = CharacterWriteService.bind({
        rules = rules.value,
        repository = repository,
    })
    assert.equal(service.ok, true)
    local invoke = CharacterWriteService.fake_invoke(repository)
    return service.value, invoke, repository
end

return {
    case('create owned inserts once and replays as already owned', function()
        local service, invoke, repository = build_service()

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
        assert.equal(created.ok, true, created.error and created.error.code)
        assert.equal(created.value.status, 'COMMITTED')
        assert.equal(created.value.result.already_owned, false)
        assert.equal(created.value.result.level, 1)
        assert.equal(created.value.result.experience, 0)
        assert.equal(created.value.character_save_revision, 1)
        assert.equal(
            repository:get_apply_count('character:create:hero_receipt_001'),
            1
        )

        local again = service:create_owned({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            receipt_id = 'character:create:hero_receipt_002',
            transaction_id = 'character_create_hero_tx_002',
            source_type = 'QUEST',
            source_reference = 'quest_main_002:reward:1',
            request_id = 'request_create_2',
            correlation_id = 'correlation_create_2',
        }, invoke)
        assert.equal(again.ok, true, again.error and again.error.code)
        assert.equal(again.value.status, 'COMMITTED')
        assert.equal(again.value.result.already_owned, true)
        assert.equal(again.value.result.created_receipt_id,
            'character:create:hero_receipt_001')
        assert.equal(again.value.character_save_revision, 1)
        assert.equal(
            repository:get_apply_count('character:create:hero_receipt_002'),
            1
        )
    end),

    case('grant experience without level rewards commits and can be queried', function()
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

        -- 50 XP stays at level 1 (threshold 100), so reward plan is empty.
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
        assert.equal(granted.value.status, 'COMMITTED')
        assert.equal(granted.value.result.old_experience, 0)
        assert.equal(granted.value.result.new_experience, 50)
        assert.equal(granted.value.result.old_level, 1)
        assert.equal(granted.value.result.new_level, 1)
        assert.equal(granted.value.result.reward_status, 'NOT_REQUIRED')
        assert.equal(granted.value.plan.reward_ref_count, 0)
        assert.equal(granted.value.character_save_revision, 2)

        local queried = service:query_transaction(
            granted.value.pending,
            invoke,
            { request_id = 'request_query_1' }
        )
        assert.equal(queried.ok, true)
        assert.equal(queried.value.status, 'COMMITTED')
        assert.equal(queried.value.value.result.new_experience, 50)
    end),

    case('level-up with rewards requires settlement and accepts external proof', function()
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

        local missing = service:grant_experience({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            amount = 100,
            reason = 'QUEST_REWARD',
            receipt_id = 'character:experience:hero_level_001',
            transaction_id = 'character_experience_level_tx_001',
            request_id = 'request_xp_level_1',
        }, invoke)
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'REWARD_SETTLEMENT_REQUIRED')
        assert.equal(missing.error.details.reward_ref_count, 1)
        assert.equal(missing.error.details.reward_refs[1], 'reward_level_two')

        local granted = service:grant_experience({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            amount = 100,
            reason = 'QUEST_REWARD',
            receipt_id = 'character:experience:hero_level_001',
            transaction_id = 'character_experience_level_tx_001',
            request_id = 'request_xp_level_1',
            reward_settlement = {
                reward_receipt_id = 'character:level_reward:hero_level_001',
                reward_result_digest = string.rep('a', 64),
            },
        }, invoke)
        assert.equal(granted.ok, true, granted.error and granted.error.code)
        assert.equal(granted.value.status, 'COMMITTED')
        assert.equal(granted.value.result.old_level, 1)
        assert.equal(granted.value.result.new_level, 2)
        assert.equal(granted.value.result.reward_status, 'COMMITTED')
        assert.equal(
            granted.value.result.reward_receipt_id,
            'character:level_reward:hero_level_001'
        )
        assert.equal(granted.value.plan.reward_ref_count, 1)
        assert.equal(granted.value.plan.reward_catalog_bound, true)
    end),

    case('unknown completion reconciles by query without re-commit', function()
        local service, invoke, repository = build_service({
            repository = {
                commit_faults = {
                    {
                        receipt_id = 'character:experience:hero_unknown_001',
                        mode = 'COMMIT_THEN_UNKNOWN',
                    },
                },
            },
        })
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

        local unknown = service:grant_experience({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            amount = 50,
            reason = 'QUEST_REWARD',
            receipt_id = 'character:experience:hero_unknown_001',
            transaction_id = 'character_experience_unknown_tx_001',
            request_id = 'request_xp_unknown',
        }, invoke)
        assert.equal(unknown.ok, true, unknown.error and unknown.error.code)
        assert.equal(unknown.value.status, 'UNKNOWN')
        assert.not_nil(unknown.value.pending)

        local reconciled = service:reconcile_unknown(
            unknown.value.pending,
            invoke,
            { request_id = 'request_reconcile_1' }
        )
        assert.equal(reconciled.ok, true, reconciled.error and reconciled.error.code)
        assert.equal(reconciled.value.status, 'COMMITTED')
        assert.equal(reconciled.value.reconciled, true)
        assert.equal(reconciled.value.result.new_experience, 50)
        assert.equal(
            repository:get_apply_count('character:experience:hero_unknown_001'),
            1
        )
    end),

    case('grant rejects missing character and reward identity reuse', function()
        local service, invoke = build_service()
        local missing = service:grant_experience({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            amount = 10,
            reason = 'QUEST_REWARD',
            receipt_id = 'character:experience:missing_001',
            transaction_id = 'character_experience_missing_tx_001',
            request_id = 'request_missing',
        }, invoke)
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'CHARACTER_NOT_OWNED')

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

        local reused = service:grant_experience({
            player_save_scope = 'player001',
            character_id = 'char_hero',
            amount = 100,
            reason = 'QUEST_REWARD',
            receipt_id = 'character:experience:hero_level_001',
            transaction_id = 'character_experience_level_tx_001',
            request_id = 'request_xp_level_1',
            reward_settlement = {
                reward_receipt_id = 'character:experience:hero_level_001',
                reward_result_digest = string.rep('a', 64),
            },
        }, invoke)
        assert.equal(reused.ok, false)
        assert.equal(reused.error.details.reason, 'REWARD_RECEIPT_IDENTITY_REUSE_FORBIDDEN')
    end),

    case('pending proofs query without re-planning or re-applying', function()
        local service, invoke, repository = build_service()
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
        assert.equal(created.value.status, 'COMMITTED')

        local create_query = service:query_transaction(
            created.value.pending,
            invoke,
            { request_id = 'request_create_query' }
        )
        assert.equal(create_query.ok, true)
        assert.equal(create_query.value.status, 'COMMITTED')
        assert.equal(create_query.value.value.result.already_owned, false)
        assert.equal(
            repository:get_apply_count('character:create:hero_receipt_001'),
            1
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
        assert.equal(granted.ok, true)

        local grant_query = service:query_transaction(
            granted.value.pending,
            invoke,
            { request_id = 'request_xp_query' }
        )
        assert.equal(grant_query.ok, true)
        assert.equal(grant_query.value.status, 'COMMITTED')
        assert.equal(grant_query.value.value.result.new_experience, 50)
        assert.equal(
            repository:get_apply_count('character:experience:hero_receipt_001'),
            1
        )
    end),
}
