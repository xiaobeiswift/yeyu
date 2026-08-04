local Harness = require 'wzx.tests.harness'
local CharacterRules = require 'wzx.application.character.character_rules'
local Catalog = require 'wzx.config.schema.character.catalog'
local ConfigValidation = require 'wzx.config.schema.character.validation'
local ContractValidation = require 'wzx.domain.contracts.validation'
local CharacterAggregate = require 'wzx.domain.character.character_aggregate'
local LevelRewardPlanDigest = require 'wzx.domain.character.level_reward_plan_digest'
local Progression = require 'wzx.domain.character.progression'
local Result = require 'wzx.domain.common.result'

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

local function formula_set(id)
    return {
        id = id or 'formula_story_v1',
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

local function level_curve(id)
    return {
        id = id or 'curve_level_story',
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

local function contribution(talent_suffix)
    return {
        source_type = 'TALENT',
        source_id = 'talent:' .. talent_suffix,
        target_stat = 'attack',
        operation = 'ADD_FLAT',
        value = 5,
        priority = 0,
        condition_tags = {},
        stable_order_key = 'catalog:talent:' .. talent_suffix .. ':attack',
    }
end

local function talent_definition(id, exclusive_group, deprecated)
    local suffix = id:sub(#'talent_' + 1)
    return {
        id = id,
        schema_version = 1,
        name_key = 'talent.' .. suffix .. '.name',
        description_key = 'talent.' .. suffix .. '.description',
        unlock_rule_id = 'rule_talent_' .. suffix,
        contributions = {
            contribution(suffix),
        },
        combat_hook_ids = {
            'hook_talent_' .. suffix,
        },
        exclusive_group = exclusive_group,
        tags = {
            suffix,
        },
        deprecated = deprecated == true,
    }
end

local function character_definition(id)
    return {
        id = id or 'char_hero',
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
            'talent_alpha',
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

local function catalog_source()
    return {
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
            talent_definition('talent_alpha'),
            talent_definition('talent_beta'),
        },
    }
end

local function aggregate_state()
    return {
        character_id = 'char_hero',
        definition_version = 3,
        level = 2,
        experience = 100,
        awakening_rank = 0,
        unlocked_talent_ids = {
            'talent_alpha',
        },
        created_receipt_id = 'creation:character:1',
        revision = 7,
    }
end

local function build_catalog(source)
    local built = Catalog.build(source or catalog_source())
    assert.equal(built.ok, true)
    return built.value
end

local function bind_rules(source)
    local catalog = build_catalog(source)
    local bound = CharacterRules.bind(catalog)
    assert.equal(bound.ok, true)
    return bound.value, catalog
end

local function definition_facts()
    local definition = character_definition()
    return {
        id = definition.id,
        definition_version = definition.definition_version,
        role = definition.role,
        level_curve_id = definition.level_curve_id,
        default_talent_ids = deep_copy(definition.default_talent_ids),
        deprecated = definition.deprecated,
    }
end

local function hostile_metatable()
    return {
        __index = function()
            error('hostile __index must not be invoked')
        end,
        __newindex = function()
            error('hostile __newindex must not be invoked')
        end,
        __len = function()
            error('hostile __len must not be invoked')
        end,
        __metatable = 'locked-hostile-metatable',
    }
end

return {
    case('character catalog materializes defaults and is an isolated read-only authority', function()
        local source = catalog_source()
        local second = character_definition('char_alpha')
        second.default_talent_ids = nil
        second.initial_qi = nil
        second.tags = nil
        second.deprecated = nil
        source.character_definitions[#source.character_definitions + 1] = second

        local built = Catalog.build(source)
        assert.equal(built.ok, true)
        local catalog = built.value
        assert.equal(getmetatable(catalog), false)
        assert.equal(catalog:contains('character_definitions', 'char_hero'), true)
        assert.equal(catalog:contains('character_definitions', 'char_missing'), false)

        local defaulted = catalog:get('character_definitions', 'char_alpha')
        assert.equal(defaulted.ok, true)
        assert.deep_equal(defaulted.value.default_talent_ids, {})
        assert.equal(defaulted.value.initial_qi, 0)
        assert.deep_equal(defaulted.value.tags, {})
        assert.equal(defaulted.value.deprecated, false)
        assert.equal(defaulted.value.definition_version, 3)

        source.character_definitions[1].base_primary.strength = 999
        source.level_curves[1].cumulative_exp_by_level[2] = 999
        source.level_curves[1].level_reward_refs[1].reward_ref = 'reward_changed'
        source.talent_definitions[1].contributions[1].value = 999
        assert.equal(
            catalog:get('character_definitions', 'char_hero').value.base_primary.strength,
            10
        )
        assert.equal(
            catalog:get('level_curves', 'curve_level_story')
                .value.cumulative_exp_by_level[2],
            100
        )
        assert.equal(
            catalog:get('level_curves', 'curve_level_story')
                .value.level_reward_refs[1].reward_ref,
            'reward_level_two'
        )
        assert.equal(
            catalog:get('talent_definitions', 'talent_alpha')
                .value.contributions[1].value,
            5
        )

        local fetched = catalog:get('character_definitions', 'char_hero').value
        fetched.base_primary.strength = 777
        local fetched_curve = catalog:get('level_curves', 'curve_level_story').value
        fetched_curve.level_reward_refs[1].reward_ref = 'reward_fetched_changed'
        local listed = catalog:list('character_definitions')
        assert.equal(listed.ok, true)
        assert.equal(listed.value[1].id, 'char_alpha')
        assert.equal(listed.value[2].id, 'char_hero')
        listed.value[2].base_primary.strength = 666
        assert.equal(
            catalog:get('character_definitions', 'char_hero').value.base_primary.strength,
            10
        )
        local listed_curves = catalog:list('level_curves')
        assert.equal(listed_curves.ok, true)
        listed_curves.value[1].level_reward_refs[1].reward_ref = 'reward_list_changed'
        assert.equal(
            catalog:get('level_curves', 'curve_level_story')
                .value.level_reward_refs[1].reward_ref,
            'reward_level_two'
        )

        assert.throws(function()
            catalog.get = function()
                return nil
            end
        end, 'character catalog is read-only')
        assert.throws(function()
            catalog.registries = {}
        end, 'character catalog is read-only')
        assert.equal(catalog:get('character_definitions', 'char_hero').ok, true)

        local invalid_collection = catalog:get('characters', 'char_hero')
        assert.error_code(invalid_collection, 'INVALID_ARGUMENT')
        assert.equal(catalog:contains('characters', 'char_hero'), false)
    end),

    case('character catalog requires exact dense collections and explicit definition versions', function()
        local unknown = catalog_source()
        unknown.unexpected = {}
        assert.error_reason(Catalog.build(unknown), 'UNKNOWN_FIELD')

        local missing = catalog_source()
        missing.formula_sets = nil
        assert.error_reason(Catalog.build(missing), 'DENSE_ARRAY_REQUIRED')

        local sparse = catalog_source()
        sparse.talent_definitions[3] = sparse.talent_definitions[2]
        sparse.talent_definitions[2] = nil
        assert.error_reason(Catalog.build(sparse), 'DENSE_ARRAY_REQUIRED')

        local version_missing = catalog_source()
        version_missing.character_definitions[1].definition_version = nil
        assert.error_reason(Catalog.build(version_missing), 'INTEGER_OUT_OF_RANGE')

        local duplicate = catalog_source()
        duplicate.character_definitions[2] = character_definition()
        assert.error_code(Catalog.build(duplicate), 'REGISTRY_DUPLICATE')
    end),

    case('character catalog validators retain captured schema authorities', function()
        local originals = {
            boolean = ConfigValidation.boolean,
            bytewise_string_less = ConfigValidation.bytewise_string_less,
            content_id = ConfigValidation.content_id,
            dense_array = ConfigValidation.dense_array,
            enum = ConfigValidation.enum,
            error_summary = ConfigValidation.error_summary,
            exact_integer_map = ConfigValidation.exact_integer_map,
            first = ConfigValidation.first,
            integer = ConfigValidation.integer,
            invalid = ConfigValidation.invalid,
            no_unknown_fields = ConfigValidation.no_unknown_fields,
            non_empty_string = ConfigValidation.non_empty_string,
            sorted_unique_content_ids =
                ConfigValidation.sorted_unique_content_ids,
            sorted_unique_strings = ConfigValidation.sorted_unique_strings,
        }
        ConfigValidation.boolean = function()
            return nil
        end
        ConfigValidation.bytewise_string_less = function()
            return true
        end
        ConfigValidation.content_id = function()
            return nil
        end
        ConfigValidation.dense_array = function()
            return nil
        end
        ConfigValidation.enum = function()
            return nil
        end
        ConfigValidation.error_summary = function()
            return {}
        end
        ConfigValidation.exact_integer_map = function()
            return nil
        end
        ConfigValidation.first = function()
            return nil
        end
        ConfigValidation.integer = function()
            return nil
        end
        ConfigValidation.invalid = function()
            return nil
        end
        ConfigValidation.no_unknown_fields = function()
            return nil
        end
        ConfigValidation.non_empty_string = function()
            return nil
        end
        ConfigValidation.sorted_unique_content_ids = function()
            return nil
        end
        ConfigValidation.sorted_unique_strings = function()
            return nil
        end
        local original_contract_enum = ContractValidation.enum
        ContractValidation.enum = function()
            return nil
        end

        local invalid_id_source = catalog_source()
        invalid_id_source.level_curves[1].id = 'evil'
        local invalid_id = Catalog.build(invalid_id_source)
        local invalid_reward_source = catalog_source()
        invalid_reward_source.level_curves[1]
            .level_reward_refs[1].reward_ref = 'evil'
        local invalid_reward = Catalog.build(invalid_reward_source)
        local invalid_character_source = catalog_source()
        invalid_character_source.character_definitions[1].role = 'FORGED_ROLE'
        local invalid_character = Catalog.build(invalid_character_source)
        local invalid_formula_source = catalog_source()
        invalid_formula_source.formula_sets[1].formula_version = 'evil'
        local invalid_formula = Catalog.build(invalid_formula_source)
        local invalid_talent_source = catalog_source()
        invalid_talent_source.talent_definitions[1].schema_version = 'evil'
        local invalid_talent = Catalog.build(invalid_talent_source)
        local invalid_contribution_source = catalog_source()
        invalid_contribution_source.talent_definitions[1]
            .contributions[1].operation = 'FORGED_OPERATION'
        local invalid_contribution = Catalog.build(invalid_contribution_source)

        local key
        local original
        for key, original in pairs(originals) do
            ConfigValidation[key] = original
        end
        ContractValidation.enum = original_contract_enum
        assert.error_reason(invalid_id, 'CONTENT_ID_INVALID')
        assert.error_reason(invalid_reward, 'CONTENT_ID_INVALID')
        assert.error_reason(invalid_character, 'ENUM_VALUE_INVALID')
        assert.error_reason(invalid_formula, 'INTEGER_OUT_OF_RANGE')
        assert.error_reason(invalid_talent, 'INTEGER_OUT_OF_RANGE')
        assert.error_reason(invalid_contribution, 'STAT_CONTRIBUTION_INVALID')
    end),

    case('catalog projections retain captured registry result authority', function()
        local rules = bind_rules()
        local state = aggregate_state()
        state.level = 1
        state.experience = 0
        local original_ok = Result.ok
        local original_err = Result.err
        local monkeypatch_calls = 0
        Result.ok = function(value)
            monkeypatch_calls = monkeypatch_calls + 1
            if type(value) == 'table'
                and type(value.level_reward_refs) == 'table'
                and type(value.level_reward_refs[1]) == 'table'
            then
                value.level_reward_refs[1].reward_ref = 'reward_forged'
            end
            return original_ok(value)
        end
        Result.err = function(...)
            monkeypatch_calls = monkeypatch_calls + 1
            return original_err(...)
        end
        local call_ok, built, invalid_built, planned = pcall(function()
            local valid_catalog = Catalog.build(catalog_source())
            local invalid_source = catalog_source()
            invalid_source.character_definitions[1].role = 'FORGED_ROLE'
            local rejected_catalog = Catalog.build(invalid_source)
            return valid_catalog,
                rejected_catalog,
                rules:plan_experience_grant(state, 100)
        end)
        Result.ok = original_ok
        Result.err = original_err

        assert.equal(call_ok, true)
        assert.equal(built.ok, true)
        assert.error_reason(invalid_built, 'ENUM_VALUE_INVALID')
        assert.equal(planned.ok, true)
        assert.equal(monkeypatch_calls, 0)
        assert.equal(
            planned.value.reached_level_rewards[1].reward_ref,
            'reward_level_two'
        )
    end),

    case('catalog authority creation retains captured builtin protections', function()
        local source = catalog_source()
        local original_setmetatable = _G.setmetatable
        local original_type = _G.type
        local original_error = _G.error
        local protected_call = pcall
        local monkeypatch_calls = 0
        local function forbidden_patch()
            monkeypatch_calls = monkeypatch_calls + 1
            original_error('captured catalog builtin authority was bypassed')
        end

        _G.setmetatable = forbidden_patch
        _G.type = forbidden_patch
        _G.error = forbidden_patch
        local call_ok, built, resolved, listed, write_ok = protected_call(function()
            local catalog = Catalog.build(source)
            local get_result = catalog.value:get('character_definitions', 'char_hero')
            local list_result = catalog.value:list('character_definitions')
            local mutation_ok = protected_call(function()
                catalog.value.shadow = true
            end)
            return catalog, get_result, list_result, mutation_ok
        end)
        _G.setmetatable = original_setmetatable
        _G.type = original_type
        _G.error = original_error

        assert.equal(call_ok, true)
        assert.equal(built.ok, true)
        assert.equal(Catalog.is_authority(built.value), true)
        assert.equal(resolved.value.id, 'char_hero')
        assert.equal(listed.value[1].id, 'char_hero')
        assert.equal(write_ok, false)
        assert.equal(monkeypatch_calls, 0)
    end),

    case('character rules binding retains captured builtin protections', function()
        local catalog = Catalog.build(catalog_source())
        assert.equal(catalog.ok, true)
        local forged = {
            plan_experience_grant = function()
                return {
                    ok = true,
                    value = {
                        reward_ref_count = 64,
                        reward_plan_digest = string.rep('f', 64),
                    },
                }
            end,
        }
        local original_setmetatable = _G.setmetatable
        local original_error = _G.error
        local protected_call = pcall
        local monkeypatch_calls = 0

        _G.setmetatable = function()
            monkeypatch_calls = monkeypatch_calls + 1
            return forged
        end
        _G.error = function()
            monkeypatch_calls = monkeypatch_calls + 1
        end
        local call_ok, bound, planned, write_ok = protected_call(function()
            local rules = CharacterRules.bind(catalog.value)
            local invalid_plan = rules.value:plan_experience_grant({}, -1)
            local mutation_ok = protected_call(function()
                rules.value.shadow = true
            end)
            return rules, invalid_plan, mutation_ok
        end)
        _G.setmetatable = original_setmetatable
        _G.error = original_error

        assert.equal(call_ok, true)
        assert.equal(bound.ok, true)
        assert.equal(planned.ok, false)
        assert.equal(write_ok, false)
        assert.equal(monkeypatch_calls, 0)
    end),

    case('character catalog rejects every internal character reference break', function()
        local vectors = {
            {
                field = 'level_curve_id',
                value = 'curve_level_missing',
                collection = 'level_curves',
            },
            {
                field = 'formula_set_id',
                value = 'formula_missing',
                collection = 'formula_sets',
            },
            {
                field = 'default_talent_ids',
                value = { 'talent_missing' },
                collection = 'talent_definitions',
            },
        }
        local index
        for index = 1, #vectors do
            local source = catalog_source()
            local vector = vectors[index]
            source.character_definitions[1][vector.field] = vector.value
            local result = Catalog.build(source)
            assert.error_code(result, 'SCHEMA_VALIDATION_FAILED')
            assert.error_reason(result, 'REFERENCE_NOT_FOUND')
            assert.equal(result.error.details.character_id, 'char_hero')
            assert.equal(result.error.details.referenced_collection, vector.collection)
        end
    end),

    case('character catalog enforces default talent exclusivity and deprecation', function()
        local exclusive = catalog_source()
        exclusive.character_definitions[1].default_talent_ids = {
            'talent_alpha',
            'talent_beta',
        }
        exclusive.talent_definitions[1].exclusive_group = 'exclusive_path'
        exclusive.talent_definitions[2].exclusive_group = 'exclusive_path'
        local exclusive_result = Catalog.build(exclusive)
        assert.error_reason(
            exclusive_result,
            'DEFAULT_TALENT_EXCLUSIVE_GROUP_CONFLICT'
        )
        assert.equal(exclusive_result.error.details.talent_id, 'talent_beta')
        assert.equal(exclusive_result.error.details.conflicting_talent_id, 'talent_alpha')

        local deprecated = catalog_source()
        deprecated.talent_definitions[1].deprecated = true
        assert.error_reason(
            Catalog.build(deprecated),
            'DEPRECATED_DEFAULT_TALENT_REFERENCE'
        )

        deprecated.character_definitions[1].deprecated = true
        assert.equal(Catalog.build(deprecated).ok, true)
    end),

    case('character catalog rejects hostile metatables without invoking them', function()
        local hostile_root = catalog_source()
        setmetatable(hostile_root, hostile_metatable())
        assert.error_reason(Catalog.build(hostile_root), 'TABLE_REQUIRED')

        local hostile_collection = catalog_source()
        setmetatable(hostile_collection.level_curves, hostile_metatable())
        assert.error_reason(Catalog.build(hostile_collection), 'DENSE_ARRAY_REQUIRED')

        local hostile_entry = catalog_source()
        setmetatable(hostile_entry.character_definitions[1], hostile_metatable())
        assert.error_reason(Catalog.build(hostile_entry), 'TABLE_REQUIRED')

        local hostile_nested = catalog_source()
        setmetatable(
            hostile_nested.character_definitions[1].base_primary,
            hostile_metatable()
        )
        assert.error_reason(Catalog.build(hostile_nested), 'MAP_REQUIRED')
    end),

    case('owned character creation copies definition defaults at revision zero', function()
        local source = catalog_source()
        source.character_definitions[1].default_talent_ids = {
            'talent_alpha',
            'talent_beta',
        }
        local rules, catalog = bind_rules(source)
        local receipts = {
            'creation1',
            'transaction1:character:1',
            'receipt_character_v1_' .. string.rep('a', 64),
        }
        local index
        for index = 1, #receipts do
            local created = rules:create_owned(
                'char_hero',
                receipts[index]
            )
            assert.equal(created.ok, true)
            assert.deep_equal(created.value, {
                character_id = 'char_hero',
                definition_version = 3,
                level = 1,
                experience = 0,
                awakening_rank = 0,
                unlocked_talent_ids = {
                    'talent_alpha',
                    'talent_beta',
                },
                created_receipt_id = receipts[index],
                revision = 0,
            })
        end

        source.character_definitions[1].default_talent_ids[1] = 'talent_changed'
        local fetched = catalog:get('character_definitions', 'char_hero').value
        fetched.role = 'ENEMY_TEMPLATE'
        fetched.default_talent_ids[1] = 'talent_changed'
        local bypassed = CharacterAggregate.create_owned(fetched, 'creation_bypass')
        assert.error_code(bypassed, 'CHARACTER_ARGUMENT_INVALID')
        assert.error_reason(bypassed, 'UNKNOWN_FIELD')
        local authoritative = rules:create_owned(
            'char_hero',
            'creation_alias_check'
        )
        assert.equal(authoritative.ok, true)
        assert.deep_equal(authoritative.value.unlocked_talent_ids, {
            'talent_alpha',
            'talent_beta',
        })

        local malformed_receipt = rules:create_owned(
            'char_hero',
            'bad::receipt'
        )
        assert.error_code(malformed_receipt, 'CHARACTER_ARGUMENT_INVALID')
        assert.error_reason(malformed_receipt, 'CREATED_RECEIPT_ID_INVALID')

        local deprecated_source = catalog_source()
        deprecated_source.character_definitions[1].deprecated = true
        local deprecated_rules = bind_rules(deprecated_source)
        local rejected = deprecated_rules:create_owned(
            'char_hero',
            'creation2'
        )
        assert.error_code(rejected, 'CHARACTER_ARGUMENT_INVALID')
        assert.error_reason(rejected, 'DEFINITION_DEPRECATED')

        local enemy_source = catalog_source()
        enemy_source.character_definitions[1].role = 'ENEMY_TEMPLATE'
        local enemy_rules = bind_rules(enemy_source)
        local enemy_result = enemy_rules:create_owned(
            'char_hero',
            'creation3'
        )
        assert.error_code(enemy_result, 'CHARACTER_ARGUMENT_INVALID')
        assert.error_reason(enemy_result, 'DEFINITION_NOT_OWNABLE')

        local companion_source = catalog_source()
        companion_source.character_definitions[1].role = 'COMPANION'
        local companion_rules = bind_rules(companion_source)
        assert.equal(
            companion_rules:create_owned(
                'char_hero',
                'creation4'
            ).ok,
            true
        )

        local fake_authority = CharacterRules.bind({})
        assert.error_code(fake_authority, 'INVALID_ARGUMENT')
        assert.error_reason(fake_authority, 'CATALOG_AUTHORITY_REQUIRED')

        assert.throws(function()
            rules.create_owned = function()
                return nil
            end
        end, 'character rules are read-only')
        assert.throws(function()
            catalog.resolve_character = function()
                return nil
            end
        end, 'character catalog is read-only')
        assert.equal(rules:create_owned('char_hero', 'creation5').ok, true)

        rawset(catalog, 'resolve_character', function()
            return {
                ok = true,
                value = {
                    definition_facts = {
                        id = 'char_hero',
                        definition_version = 999,
                        role = 'PLAYABLE',
                        level_curve_id = 'curve_level_story',
                        default_talent_ids = {},
                        deprecated = false,
                    },
                    level_curve = level_curve(),
                },
            }
        end)
        rawset(catalog, 'validate_owned_talents', function()
            return { ok = true, value = true }
        end)
        local rebound = CharacterRules.bind(catalog)
        local shadowed_create = rebound.value:create_owned(
            'char_hero',
            'creation_raw_shadow'
        )
        local shadowed_state = aggregate_state()
        shadowed_state.unlocked_talent_ids = { 'talent_missing' }
        local shadowed_validate = rebound.value:validate(shadowed_state)
        rawset(catalog, 'resolve_character', nil)
        rawset(catalog, 'validate_owned_talents', nil)
        assert.equal(rebound.ok, true)
        assert.equal(shadowed_create.ok, true)
        assert.equal(shadowed_create.value.definition_version, 3)
        assert.error_reason(shadowed_validate, 'TALENT_REFERENCE_NOT_FOUND')

        local original_create_owned = CharacterAggregate.create_owned
        CharacterAggregate.create_owned = function()
            return { ok = true, value = { forged = true } }
        end
        local call_ok, captured_result = pcall(function()
            return rules:create_owned('char_hero', 'bad::receipt')
        end)
        CharacterAggregate.create_owned = original_create_owned
        assert.equal(call_ok, true)
        assert.error_code(captured_result, 'CHARACTER_ARGUMENT_INVALID')
        assert.error_reason(captured_result, 'CREATED_RECEIPT_ID_INVALID')
    end),

    case('aggregate validation binds character, compatible definition version, curve, level and xp', function()
        local definition = definition_facts()
        local curve = level_curve()

        local older = aggregate_state()
        older.definition_version = 1
        assert.equal(CharacterAggregate.validate(older, definition, curve).ok, true)

        local unavailable = aggregate_state()
        unavailable.definition_version = 4
        assert.error_reason(
            CharacterAggregate.validate(unavailable, definition, curve),
            'DEFINITION_VERSION_UNAVAILABLE'
        )

        local wrong_character = aggregate_state()
        wrong_character.character_id = 'char_other'
        assert.error_reason(
            CharacterAggregate.validate(wrong_character, definition, curve),
            'DEFINITION_CHARACTER_MISMATCH'
        )

        local wrong_curve = level_curve('curve_level_other')
        assert.error_reason(
            CharacterAggregate.validate(aggregate_state(), definition, wrong_curve),
            'DEFINITION_CURVE_MISMATCH'
        )

        local mismatched_level = aggregate_state()
        mismatched_level.level = 1
        assert.error_reason(
            CharacterAggregate.validate(mismatched_level, definition, curve),
            'LEVEL_EXPERIENCE_MISMATCH'
        )

        local above_cap = aggregate_state()
        above_cap.level = 5
        assert.error_reason(
            CharacterAggregate.validate(above_cap, definition, curve),
            'LEVEL_ABOVE_CURVE_CAP'
        )

        local capped = aggregate_state()
        capped.level = 4
        capped.experience = curve.experience_cap
        assert.equal(CharacterAggregate.validate(capped, definition, curve).ok, true)
    end),

    case('aggregate validation rejects malformed revisions, receipts and duplicate talents', function()
        local definition = definition_facts()
        local curve = level_curve()

        local invalid_receipts = {
            '',
            123,
            'bad::receipt',
            'bad:',
            'bad receipt',
            string.rep('a', 193),
        }
        local index
        for index = 1, #invalid_receipts do
            local state = aggregate_state()
            state.created_receipt_id = invalid_receipts[index]
            local result = CharacterAggregate.validate(state, definition, curve)
            assert.error_reason(result, 'CREATED_RECEIPT_ID_INVALID')
        end

        local duplicate = aggregate_state()
        duplicate.unlocked_talent_ids = {
            'talent_alpha',
            'talent_alpha',
        }
        assert.error_reason(
            CharacterAggregate.validate(duplicate, definition, curve),
            'STRICT_ASCENDING_ORDER_REQUIRED'
        )

        local unordered = aggregate_state()
        unordered.unlocked_talent_ids = {
            'talent_beta',
            'talent_alpha',
        }
        assert.error_reason(
            CharacterAggregate.validate(unordered, definition, curve),
            'STRICT_ASCENDING_ORDER_REQUIRED'
        )

        local invalid_revision = aggregate_state()
        invalid_revision.revision = -1
        assert.error_reason(
            CharacterAggregate.validate(invalid_revision, definition, curve),
            'REVISION_INVALID'
        )

        local awakening = aggregate_state()
        awakening.awakening_rank = 1
        assert.error_reason(
            CharacterAggregate.validate(awakening, definition, curve),
            'AWAKENING_NOT_AVAILABLE'
        )

        local unknown = aggregate_state()
        unknown.final_attack = 999999
        assert.error_reason(
            CharacterAggregate.validate(unknown, definition, curve),
            'UNKNOWN_FIELD'
        )
    end),

    case('bound rules reject unknown, exclusive, and non-ownable persisted characters', function()
        local rules = bind_rules()
        local unknown_talent = aggregate_state()
        unknown_talent.unlocked_talent_ids = {
            'talent_missing',
        }
        local unknown_before = deep_copy(unknown_talent)
        local unknown_result = rules:validate(unknown_talent)
        assert.error_code(unknown_result, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(unknown_result, 'TALENT_REFERENCE_NOT_FOUND')
        local unknown_grant = rules:grant_experience(unknown_talent, 1)
        assert.error_reason(unknown_grant, 'TALENT_REFERENCE_NOT_FOUND')
        assert.deep_equal(unknown_talent, unknown_before)

        local exclusive_source = catalog_source()
        exclusive_source.talent_definitions[1].exclusive_group = 'exclusive_path'
        exclusive_source.talent_definitions[2].exclusive_group = 'exclusive_path'
        local exclusive_rules = bind_rules(exclusive_source)
        local conflicting = aggregate_state()
        conflicting.unlocked_talent_ids = {
            'talent_alpha',
            'talent_beta',
        }
        local conflict_result = exclusive_rules:validate(conflicting)
        assert.error_code(conflict_result, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(conflict_result, 'TALENT_EXCLUSIVE_GROUP_CONFLICT')

        local enemy_source = catalog_source()
        enemy_source.character_definitions[1].role = 'ENEMY_TEMPLATE'
        local enemy_rules = bind_rules(enemy_source)
        local enemy_result = enemy_rules:validate(aggregate_state())
        assert.error_code(enemy_result, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(enemy_result, 'DEFINITION_NOT_OWNABLE')
        assert.error_reason(
            enemy_rules:grant_experience(aggregate_state(), 1),
            'DEFINITION_NOT_OWNABLE'
        )
    end),

    case('custom names count strict UTF-8 scalar values through the 18 character edge', function()
        local definition = definition_facts()
        local curve = level_curve()
        local cjk = string.char(0xE4, 0xBE, 0xA0)
        local emoji = string.char(0xF0, 0x9F, 0x98, 0x80)
        local valid_names = {
            '',
            string.rep('a', 18),
            string.rep(cjk, 9) .. string.rep(emoji, 9),
        }
        local index
        for index = 1, #valid_names do
            local state = aggregate_state()
            state.custom_name = valid_names[index]
            assert.equal(CharacterAggregate.validate(state, definition, curve).ok, true)
        end

        local invalid_names = {
            {
                value = string.rep(cjk, 19),
                utf8_reason = 'CODEPOINT_LIMIT_EXCEEDED',
            },
            {
                value = string.char(0x80),
                utf8_reason = 'INVALID_LEADING_BYTE',
            },
            {
                value = string.char(0xC0, 0xAF),
                utf8_reason = 'INVALID_LEADING_BYTE',
            },
            {
                value = string.char(0xED, 0xA0, 0x80),
                utf8_reason = 'INVALID_SECOND_BYTE',
            },
            {
                value = string.char(0xF4, 0x90, 0x80, 0x80),
                utf8_reason = 'INVALID_SECOND_BYTE',
            },
            {
                value = string.char(0xE4, 0xBE),
                utf8_reason = 'TRUNCATED_SEQUENCE',
            },
        }
        for index = 1, #invalid_names do
            local state = aggregate_state()
            state.custom_name = invalid_names[index].value
            local result = CharacterAggregate.validate(state, definition, curve)
            assert.error_reason(result, 'CUSTOM_NAME_INVALID')
            assert.equal(result.error.details.utf8_reason, invalid_names[index].utf8_reason)
        end

        local companion = definition_facts()
        companion.role = 'COMPANION'
        local named_companion = aggregate_state()
        named_companion.custom_name = ''
        assert.error_reason(
            CharacterAggregate.validate(named_companion, companion, curve),
            'CUSTOM_NAME_NOT_ALLOWED'
        )
    end),

    case('experience grants cross levels once, retain max-level xp, and isolate state aliases', function()
        local rules, catalog = bind_rules()
        local state = aggregate_state()
        state.level = 1
        state.experience = 0
        state.revision = 2
        local before = deep_copy(state)

        local granted = rules:grant_experience(state, 250)
        assert.equal(granted.ok, true)
        assert.equal(granted.value.experience, 250)
        assert.equal(granted.value.level, 3)
        assert.equal(granted.value.revision, 3)
        assert.deep_equal(state, before)

        granted.value.unlocked_talent_ids[1] = 'talent_changed'
        assert.equal(state.unlocked_talent_ids[1], 'talent_alpha')

        local copied_curve = catalog:get('level_curves', 'curve_level_story').value
        copied_curve.cumulative_exp_by_level[2] = 1
        local authority_probe = aggregate_state()
        authority_probe.level = 1
        authority_probe.experience = 0
        local authority_result = rules:grant_experience(
            authority_probe,
            1
        )
        assert.equal(authority_result.ok, true)
        assert.equal(authority_result.value.level, 1)

        local capped = aggregate_state()
        capped.level = 4
        capped.experience = 500
        local capped_before = deep_copy(capped)
        local capped_result = rules:grant_experience(capped, 10)
        assert.equal(capped_result.ok, true)
        assert.equal(capped_result.value.level, 4)
        assert.equal(capped_result.value.experience, 510)
        assert.equal(capped_result.value.revision, 8)
        assert.deep_equal(capped, capped_before)
    end),

    case('experience writes require the current definition version before planning rewards', function()
        local rules = bind_rules()
        local legacy = aggregate_state()
        legacy.definition_version = 2
        local before = deep_copy(legacy)

        assert.equal(rules:validate(legacy).ok, true)
        local granted = rules:grant_experience(legacy, 100)
        local planned = rules:plan_experience_grant(legacy, 100)
        assert.error_code(granted, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(granted, 'DEFINITION_VERSION_MIGRATION_REQUIRED')
        assert.equal(granted.error.details.state_definition_version, 2)
        assert.equal(granted.error.details.available_definition_version, 3)
        assert.error_code(planned, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(planned, 'DEFINITION_VERSION_MIGRATION_REQUIRED')
        assert.deep_equal(legacy, before)
    end),

    case('experience plans select sparse crossed-level rewards and isolate every output', function()
        local rules = bind_rules()
        local state = aggregate_state()
        state.level = 1
        state.experience = 0
        state.revision = 2
        local before = deep_copy(state)

        local planned = rules:plan_experience_grant(state, 500)
        assert.equal(planned.ok, true)
        assert.equal(planned.value.character_id, 'char_hero')
        assert.equal(planned.value.definition_version, 3)
        assert.equal(planned.value.curve_id, 'curve_level_story')
        assert.equal(planned.value.expected_revision, 2)
        assert.equal(planned.value.old_level, 1)
        assert.equal(planned.value.new_level, 4)
        assert.deep_equal(planned.value.before_state, before)
        assert.equal(planned.value.after_state.level, 4)
        assert.equal(planned.value.after_state.experience, 500)
        assert.equal(planned.value.after_state.revision, 3)
        assert.deep_equal(planned.value.reached_level_rewards, {
            {
                reached_level = 2,
                reward_ref = 'reward_level_two',
            },
            {
                reached_level = 4,
                reward_ref = 'reward_level_four',
            },
        })
        assert.deep_equal(planned.value.reward_refs, {
            'reward_level_two',
            'reward_level_four',
        })
        assert.equal(planned.value.reward_ref_count, 2)
        assert.equal(type(planned.value.reward_plan_digest), 'string')
        assert.equal(#planned.value.reward_plan_digest, 64)
        assert.equal(
            planned.value.reward_plan_digest == LevelRewardPlanDigest.ZERO_DIGEST,
            false
        )
        assert.deep_equal(state, before)

        planned.value.before_state.unlocked_talent_ids[1] = 'talent_before_changed'
        assert.equal(planned.value.after_state.unlocked_talent_ids[1], 'talent_alpha')
        planned.value.after_state.unlocked_talent_ids[1] = 'talent_after_changed'
        planned.value.after_state.experience = 999
        planned.value.reached_level_rewards[1].reward_ref = 'reward_row_changed'
        planned.value.reward_refs[1] = 'reward_ref_changed'
        assert.deep_equal(state, before)

        local repeated = rules:plan_experience_grant(state, 500)
        assert.equal(repeated.ok, true)
        assert.equal(repeated.value.before_state.unlocked_talent_ids[1], 'talent_alpha')
        assert.equal(repeated.value.after_state.unlocked_talent_ids[1], 'talent_alpha')
        assert.equal(repeated.value.after_state.experience, 500)
        assert.equal(
            repeated.value.reached_level_rewards[1].reward_ref,
            'reward_level_two'
        )
        assert.equal(repeated.value.reward_refs[1], 'reward_level_two')
        assert.equal(
            repeated.value.reward_plan_digest,
            planned.value.reward_plan_digest
        )
    end),

    case('experience cap accepts the exact boundary and rejects the whole overflowing grant', function()
        local rules = bind_rules()
        local boundary = aggregate_state()
        boundary.level = 4
        boundary.experience = 999
        local boundary_before = deep_copy(boundary)

        local exact = rules:grant_experience(boundary, 1)
        assert.equal(exact.ok, true)
        assert.equal(exact.value.level, 4)
        assert.equal(exact.value.experience, 1000)
        assert.equal(exact.value.revision, 8)
        assert.deep_equal(boundary, boundary_before)

        local at_cap_before = deep_copy(exact.value)
        local at_cap = rules:grant_experience(exact.value, 1)
        assert.error_code(at_cap, 'CHARACTER_XP_OUT_OF_RANGE')
        assert.error_reason(at_cap, 'EXPERIENCE_CAP_EXCEEDED')
        assert.equal(at_cap.error.details.current_experience, 1000)
        assert.equal(at_cap.error.details.amount, 1)
        assert.equal(at_cap.error.details.experience_cap, 1000)
        assert.deep_equal(exact.value, at_cap_before)

        local crossing = aggregate_state()
        crossing.level = 4
        crossing.experience = 999
        local crossing_before = deep_copy(crossing)
        local rejected = rules:grant_experience(crossing, 2)
        assert.error_code(rejected, 'CHARACTER_XP_OUT_OF_RANGE')
        assert.error_reason(rejected, 'EXPERIENCE_CAP_EXCEEDED')
        assert.deep_equal(crossing, crossing_before)
    end),

    case('experience grant failures preserve state and reject amount and integer overflows', function()
        local rules = bind_rules()
        local invalid_amounts = {
            0,
            1.5,
            CharacterAggregate.MAX_EXPERIENCE_GRANT + 1,
        }
        local index
        for index = 1, #invalid_amounts do
            local state = aggregate_state()
            local before = deep_copy(state)
            local result = rules:grant_experience(
                state,
                invalid_amounts[index]
            )
            assert.error_code(result, 'CHARACTER_XP_OUT_OF_RANGE')
            assert.error_reason(result, 'AMOUNT_OUT_OF_RANGE')
            assert.deep_equal(state, before)
        end

        local short_curve = {
            id = 'curve_level_story',
            level_cap = 2,
            cumulative_exp_by_level = { 0, 1 },
            experience_cap = Progression.MAX_SAFE_INTEGER,
            level_reward_refs = {},
        }
        local short_source = catalog_source()
        short_source.level_curves[1] = short_curve
        local short_rules = bind_rules(short_source)
        local xp_overflow = aggregate_state()
        xp_overflow.level = 2
        xp_overflow.experience = Progression.MAX_SAFE_INTEGER
        local xp_before = deep_copy(xp_overflow)
        local xp_result = short_rules:grant_experience(
            xp_overflow,
            1
        )
        assert.error_code(xp_result, 'CHARACTER_XP_OUT_OF_RANGE')
        assert.error_reason(xp_result, 'SAFE_INTEGER_OVERFLOW')
        assert.deep_equal(xp_overflow, xp_before)

        local revision_overflow = aggregate_state()
        revision_overflow.level = 2
        revision_overflow.experience = 1
        revision_overflow.revision = Progression.MAX_SAFE_INTEGER
        local revision_before = deep_copy(revision_overflow)
        local revision_result = short_rules:grant_experience(
            revision_overflow,
            1
        )
        assert.error_code(revision_result, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(revision_result, 'REVISION_INCREMENT_OVERFLOW')
        assert.deep_equal(revision_overflow, revision_before)

        local wrong_curve = deep_copy(short_curve)
        wrong_curve.id = 'curve_level_wrong'
        local wrong_curve_result = CharacterAggregate.grant_experience(
            aggregate_state(),
            definition_facts(),
            wrong_curve,
            1
        )
        assert.error_code(wrong_curve_result, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(wrong_curve_result, 'DEFINITION_CURVE_MISMATCH')
    end),

    case('experience grants retain captured aggregate and progression authorities', function()
        local original_validate = CharacterAggregate.validate
        local original_validate_curve = Progression.validate_curve
        local original_resolve_level = Progression.resolve_level
        local monkeypatch_calls = 0
        local completed, failure = pcall(function()
            CharacterAggregate.validate = function()
                monkeypatch_calls = monkeypatch_calls + 1
                return {
                    ok = true,
                    value = aggregate_state(),
                }
            end
            Progression.validate_curve = function()
                monkeypatch_calls = monkeypatch_calls + 1
                return { ok = true, value = true }
            end
            Progression.resolve_level = function()
                monkeypatch_calls = monkeypatch_calls + 1
                return { ok = true, value = 99 }
            end

            local mismatched = aggregate_state()
            mismatched.character_id = 'char_other'
            local result = CharacterAggregate.grant_experience(
                mismatched,
                definition_facts(),
                level_curve(),
                1
            )
            assert.error_code(result, 'CHARACTER_BUILD_INVALID')
            assert.error_reason(result, 'DEFINITION_CHARACTER_MISMATCH')
            assert.equal(monkeypatch_calls, 0)
        end)

        CharacterAggregate.validate = original_validate
        Progression.validate_curve = original_validate_curve
        Progression.resolve_level = original_resolve_level
        if not completed then
            error(failure, 0)
        end
        assert.equal(CharacterAggregate.validate, original_validate)
        assert.equal(Progression.validate_curve, original_validate_curve)
        assert.equal(Progression.resolve_level, original_resolve_level)
    end),

    case('character rules plans retain captured aggregate reward and digest authorities', function()
        local rules = bind_rules()
        local original_grant = CharacterAggregate.grant_experience
        local original_collect_rewards = Progression.collect_level_rewards
        local original_derive = LevelRewardPlanDigest.derive
        local monkeypatch_calls = 0
        local completed, failure = pcall(function()
            CharacterAggregate.grant_experience = function()
                monkeypatch_calls = monkeypatch_calls + 1
                return { ok = true, value = { forged = true } }
            end
            Progression.collect_level_rewards = function()
                monkeypatch_calls = monkeypatch_calls + 1
                return { ok = true, value = {} }
            end
            LevelRewardPlanDigest.derive = function()
                monkeypatch_calls = monkeypatch_calls + 1
                return {
                    ok = true,
                    value = {
                        count = 0,
                        digest = LevelRewardPlanDigest.ZERO_DIGEST,
                    },
                }
            end

            local state = aggregate_state()
            state.level = 1
            state.experience = 0
            local planned = rules:plan_experience_grant(state, 500)
            assert.equal(planned.ok, true)
            assert.equal(planned.value.new_level, 4)
            assert.equal(planned.value.reward_ref_count, 2)
            assert.equal(
                planned.value.reward_plan_digest
                    == LevelRewardPlanDigest.ZERO_DIGEST,
                false
            )

            assert.equal(monkeypatch_calls, 0)
        end)

        CharacterAggregate.grant_experience = original_grant
        Progression.collect_level_rewards = original_collect_rewards
        LevelRewardPlanDigest.derive = original_derive
        if not completed then
            error(failure, 0)
        end
        assert.equal(CharacterAggregate.grant_experience, original_grant)
        assert.equal(Progression.collect_level_rewards, original_collect_rewards)
        assert.equal(LevelRewardPlanDigest.derive, original_derive)
    end),

    case('aggregate boundaries reject hostile metatables and return defensive states', function()
        local definition = definition_facts()
        local curve = level_curve()

        local hostile_state = aggregate_state()
        setmetatable(hostile_state, hostile_metatable())
        assert.error_reason(
            CharacterAggregate.validate(hostile_state, definition, curve),
            'TABLE_REQUIRED'
        )

        local hostile_talents = aggregate_state()
        setmetatable(hostile_talents.unlocked_talent_ids, hostile_metatable())
        assert.error_reason(
            CharacterAggregate.validate(hostile_talents, definition, curve),
            'DENSE_ARRAY_REQUIRED'
        )

        local hostile_definition = definition_facts()
        setmetatable(hostile_definition, hostile_metatable())
        assert.error_reason(
            CharacterAggregate.validate(aggregate_state(), hostile_definition, curve),
            'TABLE_REQUIRED'
        )

        local hostile_curve = level_curve()
        setmetatable(hostile_curve, hostile_metatable())
        assert.error_reason(
            CharacterAggregate.validate(aggregate_state(), definition, hostile_curve),
            'TABLE_REQUIRED'
        )

        local source = aggregate_state()
        local validated = CharacterAggregate.validate(source, definition, curve)
        assert.equal(validated.ok, true)
        source.unlocked_talent_ids[1] = 'talent_source_changed'
        assert.equal(validated.value.unlocked_talent_ids[1], 'talent_alpha')
        validated.value.unlocked_talent_ids[1] = 'talent_result_changed'
        assert.equal(source.unlocked_talent_ids[1], 'talent_source_changed')
    end),
}
