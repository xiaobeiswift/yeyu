local Harness = require 'wzx.tests.harness'
local CharacterRules = require 'wzx.application.character.character_rules'
local Catalog = require 'wzx.config.schema.character.catalog'
local CharacterAggregate = require 'wzx.domain.character.character_aggregate'
local Progression = require 'wzx.domain.character.progression'

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
        level_reward_refs = {},
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
            catalog:get('talent_definitions', 'talent_alpha')
                .value.contributions[1].value,
            5
        )

        local fetched = catalog:get('character_definitions', 'char_hero').value
        fetched.base_primary.strength = 777
        local listed = catalog:list('character_definitions')
        assert.equal(listed.ok, true)
        assert.equal(listed.value[1].id, 'char_alpha')
        assert.equal(listed.value[2].id, 'char_hero')
        listed.value[2].base_primary.strength = 666
        assert.equal(
            catalog:get('character_definitions', 'char_hero').value.base_primary.strength,
            10
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
        capped.experience = Progression.MAX_SAFE_INTEGER
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

    case('experience grants cross levels once, retain capped xp, and isolate state aliases', function()
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
        local capped_result = rules:grant_experience(capped, 10)
        assert.equal(capped_result.ok, true)
        assert.equal(capped_result.value.level, 4)
        assert.equal(capped_result.value.experience, 510)
        assert.equal(capped_result.value.revision, 8)
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

    case('experience grants retain their captured aggregate validation authority', function()
        local original_validate = CharacterAggregate.validate
        local monkeypatch_calls = 0
        local completed, failure = pcall(function()
            CharacterAggregate.validate = function()
                monkeypatch_calls = monkeypatch_calls + 1
                return {
                    ok = true,
                    value = aggregate_state(),
                }
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
        if not completed then
            error(failure, 0)
        end
        assert.equal(CharacterAggregate.validate, original_validate)
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
