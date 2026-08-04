local Harness = require 'wzx.tests.harness'
local CharacterRules = require 'wzx.application.character.character_rules'
local CharacterCatalog = require 'wzx.config.schema.character.catalog'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'
local RewardBundle = require 'wzx.config.schema.reward.reward_bundle'

local case = Harness.case
local assert = Harness.assert

local function deep_copy(value, seen)
    if type(value) ~= 'table' then
        return value
    end
    seen = seen or {}
    if seen[value] ~= nil then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    local key
    for key in pairs(value) do
        copy[deep_copy(key, seen)] = deep_copy(value[key], seen)
    end
    return copy
end

local function leaf_entry(order, entry_type, target_id, quantity)
    quantity = quantity or 1
    local entry = {
        entry_order = order,
        entry_type = entry_type,
        target_id = target_id,
        quantity_min = quantity,
        quantity_max = quantity,
    }
    if entry_type == 'UNLOCK_FLAG' then
        entry.metadata = { owner_type = 'WORLD' }
    end
    return entry
end

local function reward_bundle(id, entries)
    return {
        id = id,
        schema_version = 1,
        entries = entries,
    }
end

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

local function build_character_catalog()
    local built = CharacterCatalog.build({
        character_definitions = {
            character_definition(),
        },
        level_curves = {
            level_curve(),
        },
        formula_sets = {
            formula_set(),
        },
        talent_definitions = {
            talent_definition(),
        },
    })
    assert.equal(built.ok, true, 'character catalog should build')
    return built.value
end

local function valid_reward_source()
    return {
        reward_bundles = {
            reward_bundle('reward_level_two', {
                leaf_entry(1, 'CURRENCY', 'currency_copper', 50),
                leaf_entry(2, 'ITEM', 'item_healing_salve', 1),
            }),
            reward_bundle('reward_level_four', {
                leaf_entry(1, 'CURRENCY', 'currency_copper', 100),
                {
                    entry_order = 2,
                    entry_type = 'REWARD_BUNDLE',
                    target_id = 'reward_nested_leaf',
                    quantity_min = 1,
                    quantity_max = 1,
                },
            }),
            reward_bundle('reward_nested_leaf', {
                leaf_entry(1, 'ITEM', 'item_iron_ore', 2),
            }),
            reward_bundle('reward_with_xp', {
                leaf_entry(1, 'CHARACTER_XP', 'char_hero', 10),
            }),
        },
    }
end

return {
    case('reward bundle validates leaf entries and defaults', function()
        local result = RewardBundle.validate(reward_bundle('reward_demo', {
            leaf_entry(1, 'CURRENCY', 'currency_copper', 3),
            leaf_entry(2, 'UNLOCK_FLAG', 'flag_story_intro', 1),
        }))
        assert.equal(result.ok, true)
        assert.equal(result.value.overflow_policy, 'REJECT')
        assert.equal(result.value.deprecated, false)
        assert.equal(result.value.entries[1].first_clear_only, false)
        assert.equal(result.value.entries[2].metadata.owner_type, 'WORLD')
    end),

    case('reward bundle rejects bad quantity, order, nesting quantity, and unlock metadata', function()
        local bad_quantity = reward_bundle('reward_demo', {
            {
                entry_order = 1,
                entry_type = 'CURRENCY',
                target_id = 'currency_copper',
                quantity_min = 5,
                quantity_max = 1,
            },
        })
        local quantity_result = RewardBundle.validate(bad_quantity)
        assert.equal(quantity_result.ok, false)
        assert.equal(quantity_result.error.details.reason, 'QUANTITY_MIN_EXCEEDS_MAX')

        local bad_order = reward_bundle('reward_demo', {
            leaf_entry(2, 'CURRENCY', 'currency_copper', 1),
        })
        local order_result = RewardBundle.validate(bad_order)
        assert.equal(order_result.ok, false)
        assert.equal(order_result.error.details.reason, 'ENTRY_ORDER_MUST_BE_DENSE')

        local nested_qty = reward_bundle('reward_demo', {
            {
                entry_order = 1,
                entry_type = 'REWARD_BUNDLE',
                target_id = 'reward_other',
                quantity_min = 2,
                quantity_max = 2,
            },
        })
        local nested_result = RewardBundle.validate(nested_qty)
        assert.equal(nested_result.ok, false)
        assert.equal(
            nested_result.error.details.reason,
            'NESTED_BUNDLE_QUANTITY_MUST_BE_ONE'
        )

        local unlock = reward_bundle('reward_demo', {
            {
                entry_order = 1,
                entry_type = 'UNLOCK_FLAG',
                target_id = 'flag_story_intro',
                quantity_min = 1,
                quantity_max = 1,
            },
        })
        local unlock_result = RewardBundle.validate(unlock)
        assert.equal(unlock_result.ok, false)
        assert.equal(unlock_result.error.details.reason, 'OWNER_TYPE_REQUIRED')
    end),

    case('reward catalog seals, expands one nesting level, and rejects deeper nesting', function()
        local built = RewardCatalog.build(valid_reward_source())
        assert.equal(built.ok, true)
        local catalog = built.value
        assert.equal(RewardCatalog.is_authority(catalog), true)
        assert.equal(catalog:contains('reward_level_four'), true)

        local expanded = catalog:expand_leaves('reward_level_four')
        assert.equal(expanded.ok, true)
        assert.equal(#expanded.value, 2)
        assert.equal(expanded.value[1].entry_type, 'CURRENCY')
        assert.equal(expanded.value[1].target_id, 'currency_copper')
        assert.equal(expanded.value[2].entry_type, 'ITEM')
        assert.equal(expanded.value[2].target_id, 'item_iron_ore')
        assert.equal(expanded.value[2].nested_reward_id, 'reward_nested_leaf')

        local deep_source = valid_reward_source()
        deep_source.reward_bundles[3] = reward_bundle('reward_nested_leaf', {
            {
                entry_order = 1,
                entry_type = 'REWARD_BUNDLE',
                target_id = 'reward_level_two',
                quantity_min = 1,
                quantity_max = 1,
            },
        })
        local deep = RewardCatalog.build(deep_source)
        assert.equal(deep.ok, false)
        assert.equal(deep.error.code, 'REWARD_NESTING_INVALID')
        assert.equal(deep.error.details.reason, 'NESTING_DEPTH_EXCEEDED')

        local self_source = {
            reward_bundles = {
                reward_bundle('reward_self', {
                    {
                        entry_order = 1,
                        entry_type = 'REWARD_BUNDLE',
                        target_id = 'reward_self',
                        quantity_min = 1,
                        quantity_max = 1,
                    },
                }),
            },
        }
        local self_nested = RewardCatalog.build(self_source)
        assert.equal(self_nested.ok, false)
        assert.equal(self_nested.error.details.reason, 'SELF_NESTED_BUNDLE_FORBIDDEN')
    end),

    case('level reward validation forbids CHARACTER_XP leaves and missing refs', function()
        local catalog = RewardCatalog.build(valid_reward_source()).value

        local safe = catalog:validate_as_level_reward('reward_level_two')
        assert.equal(safe.ok, true)
        assert.equal(safe.value.leaf_count, 2)

        local xp = catalog:validate_as_level_reward('reward_with_xp')
        assert.equal(xp.ok, false)
        assert.equal(xp.error.code, 'REWARD_LEVEL_XP_FORBIDDEN')
        assert.equal(xp.error.details.reason, 'LEVEL_REWARD_CHARACTER_XP_FORBIDDEN')

        local missing = catalog:validate_as_level_reward('reward_missing')
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'REWARD_REFERENCE_NOT_FOUND')

        local character_catalog = build_character_catalog()
        local cross = RewardCatalog.validate_character_level_rewards(
            catalog,
            character_catalog
        )
        assert.equal(cross.ok, true)

        local broken_curves = {
            {
                id = 'curve_level_story',
                level_reward_refs = {
                    {
                        reached_level = 2,
                        reward_ref = 'reward_with_xp',
                    },
                },
            },
        }
        local forbidden = catalog:validate_level_curve_refs(broken_curves)
        assert.equal(forbidden.ok, false)
        assert.equal(forbidden.error.code, 'REWARD_LEVEL_XP_FORBIDDEN')
        assert.equal(forbidden.error.details.curve_id, 'curve_level_story')

        local unknown_ref = catalog:validate_level_curve_refs({
            {
                id = 'curve_level_story',
                level_reward_refs = {
                    {
                        reached_level = 2,
                        reward_ref = 'reward_unknown_level',
                    },
                },
            },
        })
        assert.equal(unknown_ref.ok, false)
        assert.equal(unknown_ref.error.code, 'REWARD_REFERENCE_NOT_FOUND')
        assert.equal(
            unknown_ref.error.details.reason,
            'LEVEL_REWARD_REFERENCE_NOT_FOUND'
        )
    end),

    case('reward catalog is sealed against mutation and unknown fields', function()
        local source = valid_reward_source()
        source.extra = true
        local unknown = RewardCatalog.build(source)
        assert.equal(unknown.ok, false)
        assert.equal(unknown.error.details.reason, 'UNKNOWN_FIELD')

        local catalog = RewardCatalog.build(valid_reward_source()).value
        local listed = catalog:list()
        assert.equal(listed.ok, true)
        listed.value[1].id = 'reward_forged'
        local again = catalog:get('reward_level_two')
        assert.equal(again.ok, true)
        assert.equal(again.value.id, 'reward_level_two')

        local forged = setmetatable({}, {
            __index = function()
                return true
            end,
        })
        assert.equal(RewardCatalog.is_authority(forged), false)
    end),

    case('character rules bind reward catalog and reject xp-bearing level plans', function()
        local character_catalog = build_character_catalog()
        local reward_catalog = RewardCatalog.build(valid_reward_source()).value

        local unbound = CharacterRules.bind(character_catalog)
        assert.equal(unbound.ok, true)
        local created = unbound.value:create_owned('char_hero', 'receipt_create_hero')
        assert.equal(created.ok, true)

        local planned = unbound.value:plan_experience_grant(created.value, 100)
        assert.equal(planned.ok, true)
        assert.equal(planned.value.reward_catalog_bound, false)
        assert.equal(planned.value.reward_ref_count, 1)
        assert.equal(planned.value.reward_refs[1], 'reward_level_two')

        local bound = CharacterRules.bind(character_catalog, reward_catalog)
        assert.equal(bound.ok, true)
        local bound_plan = bound.value:plan_experience_grant(created.value, 100)
        assert.equal(bound_plan.ok, true)
        assert.equal(bound_plan.value.reward_catalog_bound, true)
        assert.equal(
            bound_plan.value.reward_plan_digest,
            planned.value.reward_plan_digest
        )

        local xp_source = valid_reward_source()
        xp_source.reward_bundles[1] = reward_bundle('reward_level_two', {
            leaf_entry(1, 'CHARACTER_XP', 'char_hero', 5),
        })
        local xp_catalog = RewardCatalog.build(xp_source).value
        local xp_rules = CharacterRules.bind(character_catalog, xp_catalog)
        assert.equal(xp_rules.ok, true)
        local xp_plan = xp_rules.value:plan_experience_grant(created.value, 100)
        assert.equal(xp_plan.ok, false)
        assert.equal(xp_plan.error.code, 'REWARD_LEVEL_XP_FORBIDDEN')

        local bad_bind = CharacterRules.bind(character_catalog, {})
        assert.equal(bad_bind.ok, false)
        assert.equal(
            bad_bind.error.details.reason,
            'REWARD_CATALOG_AUTHORITY_REQUIRED'
        )
    end),

    case('reward bundle normalize copies are detached from hostile input tables', function()
        local source = reward_bundle('reward_demo', {
            leaf_entry(1, 'CURRENCY', 'currency_copper', 1),
        })
        local validated = RewardBundle.validate(source)
        assert.equal(validated.ok, true)
        source.entries[1].target_id = 'currency_forged'
        source.id = 'reward_forged'
        assert.equal(validated.value.id, 'reward_demo')
        assert.equal(validated.value.entries[1].target_id, 'currency_copper')

        local catalog_source = valid_reward_source()
        local built = RewardCatalog.build(catalog_source)
        assert.equal(built.ok, true)
        catalog_source.reward_bundles[1].id = 'reward_forged'
        catalog_source.reward_bundles[1].entries[1].target_id = 'currency_forged'
        local fetched = built.value:get('reward_level_two')
        assert.equal(fetched.ok, true)
        assert.equal(fetched.value.id, 'reward_level_two')
        assert.equal(fetched.value.entries[1].target_id, 'currency_copper')

        local copied = deep_copy(fetched.value)
        copied.entries[1].target_id = 'currency_mutated'
        local again = built.value:get('reward_level_two')
        assert.equal(again.value.entries[1].target_id, 'currency_copper')
    end),
}
