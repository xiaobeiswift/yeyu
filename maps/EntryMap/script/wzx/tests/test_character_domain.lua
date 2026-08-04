local Harness = require 'wzx.tests.harness'
local AttributeFormulaSet = require 'wzx.config.schema.character.attribute_formula_set'
local CharacterDefinition = require 'wzx.config.schema.character.character_definition'
local LevelCurve = require 'wzx.config.schema.character.level_curve'
local TalentDefinition = require 'wzx.config.schema.character.talent_definition'
local Ordered = require 'wzx.domain.common.ordered'
local LevelRewardPlanDigest = require 'wzx.domain.character.level_reward_plan_digest'
local Progression = require 'wzx.domain.character.progression'
local StatPipeline = require 'wzx.domain.character.stat_pipeline'

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

local function character_definition()
    return {
        id = 'char_hero',
        schema_version = 1,
        definition_version = 1,
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
            'talent_brave',
            'talent_calm',
        },
        initial_qi = 100,
        model_asset_id = 'model_hero',
        portrait_asset_id = 'portrait_hero',
        tags = {
            'hero',
            'human',
        },
        deprecated = false,
    }
end

local function level_curve()
    return {
        id = 'curve_level_story',
        level_cap = 4,
        experience_cap = 1000,
        cumulative_exp_by_level = {
            0,
            100,
            250,
            500,
        },
        level_reward_refs = {
            {
                reached_level = 2,
                reward_ref = 'reward_level_two',
            },
            {
                reached_level = 3,
                reward_ref = 'reward_level_three',
            },
        },
    }
end

local function level_reward_plan()
    return {
        character_id = 'char_hero',
        definition_version = 7,
        curve_id = 'curve_level_story',
        expected_revision = 11,
        old_level = 1,
        new_level = 3,
        rewards = {
            {
                reached_level = 2,
                reward_ref = 'reward_level_two',
            },
            {
                reached_level = 3,
                reward_ref = 'reward_level_three',
            },
        },
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

local function contribution(operation, value, stable_order_key, options)
    options = options or {}
    return {
        source_type = options.source_type or 'TALENT',
        source_id = options.source_id or 'talent:test',
        target_stat = options.target_stat or 'attack',
        operation = operation,
        value = value,
        priority = options.priority or 0,
        condition_tags = options.condition_tags or {},
        stable_order_key = stable_order_key,
    }
end

local function talent_definition()
    return {
        id = 'talent_brave',
        schema_version = 1,
        name_key = 'talent.brave.name',
        description_key = 'talent.brave.description',
        unlock_rule_id = 'rule_talent_brave',
        contributions = {
            contribution('ADD_FLAT', 5, 'schema:talent:brave:attack'),
        },
        combat_hook_ids = {
            'hook_talent_brave',
        },
        exclusive_group = 'exclusive_brave',
        tags = {
            'brave',
            'protagonist',
        },
        deprecated = false,
    }
end

local function pipeline_request(contributions, context_tags)
    return {
        level = 5,
        base_primary = {
            strength = 10,
            constitution = 20,
            agility = 30,
            inner_power = 40,
        },
        growth_per_level_milli = {
            strength = 0,
            constitution = 0,
            agility = 0,
            inner_power = 0,
        },
        formula = formula_set(),
        initial_qi = 100,
        contributions = contributions or {},
        context_tags = context_tags or {},
    }
end

local function find_stat_row(result, target_stat)
    local rows = result.value.breakdown.stat_rows
    local index
    for index = 1, #rows do
        if rows[index].target_stat == target_stat then
            return rows[index]
        end
    end
    return nil
end

local function find_diagnostic(result, code, target_stat)
    local diagnostics = result.value.diagnostics
    local index
    for index = 1, #diagnostics do
        local diagnostic = diagnostics[index]
        if diagnostic.code == code and diagnostic.target_stat == target_stat then
            return diagnostic
        end
    end
    return nil
end

local function all_permutations(values)
    local output = {}
    local selected = {}
    local used = {}

    local function visit(depth)
        if depth > #values then
            local row = {}
            local index
            for index = 1, #values do
                row[index] = selected[index]
            end
            output[#output + 1] = row
            return
        end

        local index
        for index = 1, #values do
            if not used[index] then
                used[index] = true
                selected[depth] = values[index]
                visit(depth + 1)
                selected[depth] = nil
                used[index] = nil
            end
        end
    end

    visit(1)
    return output
end

return {
    case('all four character schemas accept complete definitions', function()
        assert.equal(CharacterDefinition.validate(character_definition()).ok, true)
        assert.equal(LevelCurve.validate(level_curve()).ok, true)
        assert.equal(AttributeFormulaSet.validate(formula_set()).ok, true)
        assert.equal(TalentDefinition.validate(talent_definition()).ok, true)
    end),

    case('schema results materialize defaults and isolate validated definitions', function()
        local character_source = character_definition()
        character_source.default_talent_ids = nil
        character_source.initial_qi = nil
        character_source.tags = nil
        character_source.deprecated = nil
        local character_result = CharacterDefinition.validate(character_source)
        assert.equal(character_result.ok, true)
        assert.deep_equal(character_result.value.default_talent_ids, {})
        assert.equal(character_result.value.initial_qi, 0)
        assert.deep_equal(character_result.value.tags, {})
        assert.equal(character_result.value.deprecated, false)
        character_source.base_primary.strength = 999
        assert.equal(character_result.value.base_primary.strength, 10)

        local curve_source = level_curve()
        local curve_result = LevelCurve.validate(curve_source)
        assert.equal(curve_result.ok, true)
        curve_source.cumulative_exp_by_level[2] = 999
        curve_source.level_reward_refs[1].reached_level = 4
        curve_source.level_reward_refs[1].reward_ref = 'reward_changed'
        assert.equal(curve_result.value.cumulative_exp_by_level[2], 100)
        assert.deep_equal(curve_result.value.level_reward_refs[1], {
            reached_level = 2,
            reward_ref = 'reward_level_two',
        })

        local curve_without_rewards = level_curve()
        curve_without_rewards.level_reward_refs = nil
        local curve_without_rewards_result = LevelCurve.validate(
            curve_without_rewards
        )
        assert.equal(curve_without_rewards_result.ok, true)
        assert.deep_equal(curve_without_rewards_result.value.level_reward_refs, {})

        local formula_source = formula_set()
        local formula_result = AttributeFormulaSet.validate(formula_source)
        assert.equal(formula_result.ok, true)
        formula_source.base_hp = 999
        assert.equal(formula_result.value.base_hp, 100)

        local talent_source = talent_definition()
        local talent_result = TalentDefinition.validate(talent_source)
        assert.equal(talent_result.ok, true)
        talent_source.contributions[1].value = 999
        talent_source.combat_hook_ids[1] = 'hook_changed'
        assert.equal(talent_result.value.contributions[1].value, 5)
        assert.equal(talent_result.value.combat_hook_ids[1], 'hook_talent_brave')
    end),

    case('all four character schemas reject unknown top-level fields', function()
        local fixtures = {
            {
                validator = CharacterDefinition,
                value = character_definition(),
            },
            {
                validator = LevelCurve,
                value = level_curve(),
            },
            {
                validator = AttributeFormulaSet,
                value = formula_set(),
            },
            {
                validator = TalentDefinition,
                value = talent_definition(),
            },
        }
        local index
        for index = 1, #fixtures do
            local value = fixtures[index].value
            value.unexpected_field = true
            local result = fixtures[index].validator.validate(value)
            assert.error_code(result, 'SCHEMA_VALIDATION_FAILED')
            assert.error_reason(result, 'UNKNOWN_FIELD')
            assert.equal(result.error.details.field, 'unexpected_field')
        end
    end),

    case('character schema requires exact four-key primary growth and weapon maps', function()
        local vectors = {
            {
                field = 'base_primary',
                missing = 'inner_power',
                unknown = 'luck',
            },
            {
                field = 'growth_per_level_milli',
                missing = 'agility',
                unknown = 'spirit',
            },
            {
                field = 'weapon_aptitudes',
                missing = 'STAFF',
                unknown = 'FIST',
            },
        }
        local index
        for index = 1, #vectors do
            local vector = vectors[index]
            local missing = character_definition()
            missing[vector.field][vector.missing] = nil
            local missing_result = CharacterDefinition.validate(missing)
            assert.error_code(missing_result, 'SCHEMA_VALIDATION_FAILED')
            assert.error_reason(missing_result, 'MAP_KEY_REQUIRED')

            local extra = character_definition()
            extra[vector.field][vector.unknown] = 1
            local extra_result = CharacterDefinition.validate(extra)
            assert.error_code(extra_result, 'SCHEMA_VALIDATION_FAILED')
            assert.error_reason(extra_result, 'UNKNOWN_MAP_KEY')
        end
    end),

    case('level curve schema enforces cap, zero origin, length, order, and safe bounds', function()
        local single_level = level_curve()
        single_level.level_cap = 1
        single_level.experience_cap = 0
        single_level.cumulative_exp_by_level = { 0 }
        single_level.level_reward_refs = {}
        assert.equal(LevelCurve.validate(single_level).ok, true)

        local safe_maximum = level_curve()
        safe_maximum.level_cap = 3
        safe_maximum.experience_cap = Progression.MAX_SAFE_INTEGER
        safe_maximum.cumulative_exp_by_level = {
            0,
            1,
            Progression.MAX_SAFE_INTEGER,
        }
        assert.equal(LevelCurve.validate(safe_maximum).ok, true)

        local cap_invalid = level_curve()
        cap_invalid.level_cap = 0
        assert.error_reason(LevelCurve.validate(cap_invalid), 'INTEGER_OUT_OF_RANGE')

        local length_invalid = level_curve()
        length_invalid.cumulative_exp_by_level = { 0, 100, 250 }
        assert.error_reason(LevelCurve.validate(length_invalid), 'LEVEL_COUNT_MISMATCH')

        local origin_invalid = level_curve()
        origin_invalid.cumulative_exp_by_level[1] = 1
        assert.error_reason(
            LevelCurve.validate(origin_invalid),
            'FIRST_LEVEL_EXPERIENCE_MUST_BE_ZERO'
        )

        local order_invalid = level_curve()
        order_invalid.cumulative_exp_by_level[3] = 100
        assert.error_reason(
            LevelCurve.validate(order_invalid),
            'STRICT_ASCENDING_ORDER_REQUIRED'
        )

        local range_invalid = level_curve()
        range_invalid.cumulative_exp_by_level[4] = Progression.MAX_SAFE_INTEGER + 1
        assert.error_reason(LevelCurve.validate(range_invalid), 'INTEGER_OUT_OF_RANGE')

        local missing_experience_cap = level_curve()
        missing_experience_cap.experience_cap = nil
        assert.error_reason(
            LevelCurve.validate(missing_experience_cap),
            'INTEGER_OUT_OF_RANGE'
        )

        local experience_cap_below_last_threshold = level_curve()
        experience_cap_below_last_threshold.experience_cap = 499
        assert.error_reason(
            LevelCurve.validate(experience_cap_below_last_threshold),
            'INTEGER_OUT_OF_RANGE'
        )

        local experience_cap_above_safe_integer = level_curve()
        experience_cap_above_safe_integer.experience_cap =
            Progression.MAX_SAFE_INTEGER + 1
        assert.error_reason(
            LevelCurve.validate(experience_cap_above_safe_integer),
            'INTEGER_OUT_OF_RANGE'
        )
    end),

    case('level curve schema enforces structured canonical reward mappings', function()
        assert.equal(LevelCurve.MAX_LEVEL_REWARD_REFS, 64)

        local legacy_strings = level_curve()
        legacy_strings.level_reward_refs = { 'reward_level_two' }
        assert.error_reason(LevelCurve.validate(legacy_strings), 'TABLE_REQUIRED')

        local sparse = level_curve()
        sparse.level_reward_refs = {
            [1] = {
                reached_level = 2,
                reward_ref = 'reward_level_two',
            },
            [3] = {
                reached_level = 3,
                reward_ref = 'reward_level_three',
            },
        }
        assert.error_reason(LevelCurve.validate(sparse), 'DENSE_ARRAY_REQUIRED')

        local missing_level = level_curve()
        missing_level.level_reward_refs[1].reached_level = nil
        assert.error_reason(LevelCurve.validate(missing_level), 'INTEGER_OUT_OF_RANGE')

        local missing_reward = level_curve()
        missing_reward.level_reward_refs[1].reward_ref = nil
        assert.error_reason(LevelCurve.validate(missing_reward), 'CONTENT_ID_INVALID')

        local unknown_field = level_curve()
        unknown_field.level_reward_refs[1].unexpected = true
        local unknown_result = LevelCurve.validate(unknown_field)
        assert.error_reason(unknown_result, 'UNKNOWN_FIELD')
        assert.equal(
            unknown_result.error.details.field,
            'level_reward_refs[1].unexpected'
        )

        local non_string_field = level_curve()
        non_string_field.level_reward_refs[1][1] = true
        local non_string_result = LevelCurve.validate(non_string_field)
        assert.error_reason(non_string_result, 'STRING_FIELD_KEYS_REQUIRED')
        assert.equal(
            non_string_result.error.details.field,
            'level_reward_refs[1]'
        )

        local invalid_reward_id = level_curve()
        invalid_reward_id.level_reward_refs[1].reward_ref = 'item_level_two'
        assert.error_reason(
            LevelCurve.validate(invalid_reward_id),
            'CONTENT_ID_INVALID'
        )

        local below_level_range = level_curve()
        below_level_range.level_reward_refs[1].reached_level = 1
        assert.error_reason(
            LevelCurve.validate(below_level_range),
            'INTEGER_OUT_OF_RANGE'
        )

        local above_level_range = level_curve()
        above_level_range.level_reward_refs[2].reached_level = 5
        assert.error_reason(
            LevelCurve.validate(above_level_range),
            'INTEGER_OUT_OF_RANGE'
        )

        local duplicate_level = level_curve()
        duplicate_level.level_reward_refs[2].reached_level = 2
        assert.error_reason(
            LevelCurve.validate(duplicate_level),
            'STRICT_ASCENDING_REACHED_LEVEL_REQUIRED'
        )

        local reversed_levels = level_curve()
        reversed_levels.level_reward_refs[1].reached_level = 3
        reversed_levels.level_reward_refs[2].reached_level = 2
        assert.error_reason(
            LevelCurve.validate(reversed_levels),
            'STRICT_ASCENDING_REACHED_LEVEL_REQUIRED'
        )

        local hostile_metatable = {
            __index = function()
                error('hostile reward __index must not be invoked')
            end,
            __len = function()
                error('hostile reward __len must not be invoked')
            end,
            __metatable = 'locked-hostile-reward-metatable',
        }
        local hostile_rows = level_curve()
        setmetatable(hostile_rows.level_reward_refs, hostile_metatable)
        assert.error_reason(
            LevelCurve.validate(hostile_rows),
            'DENSE_ARRAY_REQUIRED'
        )

        local hostile_row = level_curve()
        setmetatable(hostile_row.level_reward_refs[1], hostile_metatable)
        assert.error_reason(LevelCurve.validate(hostile_row), 'TABLE_REQUIRED')

        local maximum = level_curve()
        maximum.level_cap = 100
        maximum.experience_cap = 99
        maximum.cumulative_exp_by_level = {}
        maximum.level_reward_refs = {}
        local index
        for index = 1, 100 do
            maximum.cumulative_exp_by_level[index] = index - 1
        end
        for index = 1, LevelCurve.MAX_LEVEL_REWARD_REFS do
            maximum.level_reward_refs[index] = {
                reached_level = index + 1,
                reward_ref = 'reward_level_' .. tostring(index + 1),
            }
        end
        assert.equal(LevelCurve.validate(maximum).ok, true)

        local over_limit = deep_copy(maximum)
        over_limit.level_reward_refs[65] = {
            reached_level = 66,
            reward_ref = 'reward_level_66',
        }
        assert.error_reason(
            LevelCurve.validate(over_limit),
            'REWARD_REF_COUNT_LIMIT_EXCEEDED'
        )
    end),

    case('talent schema validates canonical contributions, uniqueness, and stable order', function()
        local valid = talent_definition()
        valid.contributions = {
            contribution('ADD_FLAT', 5, 'schema:talent:a', { priority = 10 }),
            contribution('ADD_BP', 500, 'schema:talent:b', { priority = 10 }),
        }
        assert.equal(TalentDefinition.validate(valid).ok, true)

        local malformed = talent_definition()
        malformed.contributions[1].operation = 'UNKNOWN_OPERATION'
        assert.error_reason(
            TalentDefinition.validate(malformed),
            'STAT_CONTRIBUTION_INVALID'
        )

        local duplicate = talent_definition()
        duplicate.contributions = {
            contribution('ADD_FLAT', 5, 'schema:talent:duplicate'),
            contribution('ADD_BP', 500, 'schema:talent:duplicate'),
        }
        assert.error_reason(
            TalentDefinition.validate(duplicate),
            'STABLE_ORDER_KEY_DUPLICATE'
        )

        local unordered = talent_definition()
        unordered.contributions = {
            contribution('ADD_FLAT', 5, 'schema:talent:z', { priority = 20 }),
            contribution('ADD_BP', 500, 'schema:talent:a', { priority = 10 }),
        }
        assert.error_reason(
            TalentDefinition.validate(unordered),
            'CONTRIBUTIONS_NOT_STRICTLY_ORDERED'
        )

        local foreign_source = talent_definition()
        foreign_source.contributions[1].source_type = 'EQUIPMENT'
        local foreign_source_result = TalentDefinition.validate(foreign_source)
        assert.error_code(foreign_source_result, 'SCHEMA_VALIDATION_FAILED')

        local multiplier_boundaries = {
            -1,
            50001,
        }
        local index
        for index = 1, #multiplier_boundaries do
            local multiplier_invalid = talent_definition()
            multiplier_invalid.contributions[1].operation = 'MULTIPLY_BP'
            multiplier_invalid.contributions[1].value = multiplier_boundaries[index]
            local multiplier_result = TalentDefinition.validate(multiplier_invalid)
            assert.error_code(multiplier_result, 'SCHEMA_VALIDATION_FAILED')
        end
    end),

    case('progression resolves every threshold edge and rejects unsafe experience', function()
        local curve = {
            level_cap = 4,
            experience_cap = Progression.MAX_SAFE_INTEGER,
            cumulative_exp_by_level = {
                0,
                100,
                250,
                500,
            },
        }
        local vectors = {
            { experience = 0, level = 1 },
            { experience = 99, level = 1 },
            { experience = 100, level = 2 },
            { experience = 249, level = 2 },
            { experience = 250, level = 3 },
            { experience = 499, level = 3 },
            { experience = 500, level = 4 },
            { experience = Progression.MAX_SAFE_INTEGER, level = 4 },
        }
        local index
        for index = 1, #vectors do
            local result = Progression.resolve_level(curve, vectors[index].experience)
            assert.equal(result.ok, true)
            assert.equal(result.value, vectors[index].level)
        end

        local invalid_values = {
            -1,
            1.5,
            Progression.MAX_SAFE_INTEGER + 1,
        }
        for index = 1, #invalid_values do
            local result = Progression.resolve_level(curve, invalid_values[index])
            assert.error_code(result, 'CHARACTER_XP_OUT_OF_RANGE')
        end

        local bounded_curve = level_curve()
        assert.error_code(
            Progression.resolve_level(bounded_curve, 1001),
            'CHARACTER_XP_OUT_OF_RANGE'
        )
    end),

    case('progression selects reward rows for the canonical crossed-level interval', function()
        local curve = level_curve()
        local before = deep_copy(curve)
        local rewards = Progression.collect_level_rewards(curve, 1, 3)
        assert.equal(rewards.ok, true)
        assert.deep_equal(rewards.value, {
            {
                reached_level = 2,
                reward_ref = 'reward_level_two',
            },
            {
                reached_level = 3,
                reward_ref = 'reward_level_three',
            },
        })
        assert.deep_equal(curve, before)

        rewards.value[1].reached_level = 99
        rewards.value[1].reward_ref = 'reward_changed'
        assert.deep_equal(curve, before)
        local collected_again = Progression.collect_level_rewards(curve, 1, 3)
        assert.deep_equal(collected_again.value, {
            {
                reached_level = 2,
                reward_ref = 'reward_level_two',
            },
            {
                reached_level = 3,
                reward_ref = 'reward_level_three',
            },
        })

        local refs = Progression.collect_level_reward_refs(curve, 1, 3)
        assert.equal(refs.ok, true)
        assert.deep_equal(refs.value, {
            'reward_level_two',
            'reward_level_three',
        })

        assert.deep_equal(
            Progression.collect_level_rewards(curve, 3, 4).value,
            {}
        )
        assert.deep_equal(
            Progression.collect_level_rewards(curve, 4, 4).value,
            {}
        )

        local no_rewards = level_curve()
        no_rewards.level_reward_refs = nil
        assert.deep_equal(
            Progression.collect_level_rewards(no_rewards, 1, 4).value,
            {}
        )
    end),

    case('progression reward collection rejects invalid curves and transitions', function()
        local curve = level_curve()
        local reversed = Progression.collect_level_rewards(curve, 3, 2)
        assert.error_code(reversed, 'CHARACTER_ARGUMENT_INVALID')
        assert.error_reason(reversed, 'LEVEL_TRANSITION_REVERSED')

        local invalid_transitions = {
            { old_level = 0, new_level = 2, field = 'old_level' },
            { old_level = 1.5, new_level = 2, field = 'old_level' },
            { old_level = 1, new_level = 5, field = 'new_level' },
            { old_level = 1, new_level = 2.5, field = 'new_level' },
        }
        local index
        for index = 1, #invalid_transitions do
            local vector = invalid_transitions[index]
            local result = Progression.collect_level_rewards(
                curve,
                vector.old_level,
                vector.new_level
            )
            assert.error_code(result, 'CHARACTER_ARGUMENT_INVALID')
            assert.error_reason(result, 'INTEGER_OUT_OF_RANGE')
            assert.equal(result.error.details.field, vector.field)
        end

        local legacy_curve = level_curve()
        legacy_curve.level_reward_refs = { 'reward_level_two' }
        local legacy_result = Progression.collect_level_rewards(
            legacy_curve,
            1,
            2
        )
        assert.error_code(legacy_result, 'CHARACTER_LEVEL_CURVE_INVALID')
        assert.error_reason(legacy_result, 'PLAIN_ROW_REQUIRED')

        local sparse_curve = level_curve()
        sparse_curve.level_reward_refs[3] =
            sparse_curve.level_reward_refs[2]
        sparse_curve.level_reward_refs[2] = nil
        local sparse_result = Progression.collect_level_reward_refs(
            sparse_curve,
            1,
            3
        )
        assert.error_code(sparse_result, 'CHARACTER_LEVEL_CURVE_INVALID')
        assert.error_reason(sparse_result, 'DENSE_ARRAY_REQUIRED')
    end),

    case('level reward plan digest is deterministic, contextual, and reserves zero for empty plans', function()
        local plan = level_reward_plan()
        local before = deep_copy(plan)
        local first = LevelRewardPlanDigest.derive(plan)
        local second = LevelRewardPlanDigest.derive(deep_copy(plan))
        assert.equal(first.ok, true)
        assert.equal(second.ok, true)
        assert.equal(first.value.count, 2)
        assert.equal(#first.value.digest, 64)
        assert.not_nil(string.match(first.value.digest, '^[a-f0-9]+$'))
        assert.equal(
            first.value.digest,
            'f370a196f7277d372ec9618fed25baba1bb76e285ce9168f04ee2c564360ad4d'
        )
        assert.equal(first.value.digest, second.value.digest)
        assert.equal(
            first.value.digest == LevelRewardPlanDigest.ZERO_DIGEST,
            false
        )
        assert.deep_equal(plan, before)

        local changed_reward = level_reward_plan()
        changed_reward.rewards[1].reward_ref = 'reward_level_two_variant'
        local changed_reward_result = LevelRewardPlanDigest.derive(changed_reward)
        assert.equal(changed_reward_result.ok, true)
        assert.equal(changed_reward_result.value.digest == first.value.digest, false)

        local changed_revision = level_reward_plan()
        changed_revision.expected_revision = 12
        local changed_revision_result = LevelRewardPlanDigest.derive(
            changed_revision
        )
        assert.equal(changed_revision_result.ok, true)
        assert.equal(changed_revision_result.value.digest == first.value.digest, false)

        local changed_character = level_reward_plan()
        changed_character.character_id = 'char_rival'
        local changed_character_result = LevelRewardPlanDigest.derive(
            changed_character
        )
        assert.equal(changed_character_result.ok, true)
        assert.equal(
            changed_character_result.value.digest == first.value.digest,
            false
        )

        local changed_definition = level_reward_plan()
        changed_definition.definition_version = 8
        local changed_definition_result = LevelRewardPlanDigest.derive(
            changed_definition
        )
        assert.equal(changed_definition_result.ok, true)
        assert.equal(
            changed_definition_result.value.digest == first.value.digest,
            false
        )

        local changed_curve = level_reward_plan()
        changed_curve.curve_id = 'curve_level_challenge'
        local changed_curve_result = LevelRewardPlanDigest.derive(changed_curve)
        assert.equal(changed_curve_result.ok, true)
        assert.equal(changed_curve_result.value.digest == first.value.digest, false)

        local changed_interval = level_reward_plan()
        changed_interval.new_level = 4
        local changed_interval_result = LevelRewardPlanDigest.derive(
            changed_interval
        )
        assert.equal(changed_interval_result.ok, true)
        assert.equal(
            changed_interval_result.value.digest == first.value.digest,
            false
        )

        local empty = level_reward_plan()
        empty.old_level = 3
        empty.new_level = 3
        empty.rewards = {}
        local empty_result = LevelRewardPlanDigest.derive(empty)
        assert.equal(empty_result.ok, true)
        assert.equal(empty_result.value.count, 0)
        assert.equal(
            empty_result.value.digest,
            LevelRewardPlanDigest.ZERO_DIGEST
        )
        assert.equal(LevelRewardPlanDigest.ZERO_DIGEST, string.rep('0', 64))
    end),

    case('level reward plan digest rejects non-exact and hostile shapes', function()
        local function assert_plan_invalid(plan, reason)
            local result = LevelRewardPlanDigest.derive(plan)
            assert.error_code(result, 'CHARACTER_REWARD_PLAN_INVALID')
            if reason ~= nil then
                assert.error_reason(result, reason)
            end
            return result
        end

        local unknown_plan_field = level_reward_plan()
        unknown_plan_field.unexpected = true
        assert_plan_invalid(unknown_plan_field, 'UNKNOWN_FIELD')

        local missing_plan_field = level_reward_plan()
        missing_plan_field.expected_revision = nil
        assert_plan_invalid(missing_plan_field, 'FIELD_REQUIRED')

        local unknown_row_field = level_reward_plan()
        unknown_row_field.rewards[1].unexpected = true
        assert_plan_invalid(unknown_row_field, 'UNKNOWN_FIELD')

        local missing_row_field = level_reward_plan()
        missing_row_field.rewards[1].reward_ref = nil
        assert_plan_invalid(missing_row_field, 'FIELD_REQUIRED')

        local legacy_row = level_reward_plan()
        legacy_row.rewards = { 'reward_level_two' }
        assert_plan_invalid(legacy_row, 'PLAIN_TABLE_REQUIRED')

        local non_string_row_field = level_reward_plan()
        non_string_row_field.rewards[1][1] = true
        assert_plan_invalid(non_string_row_field, 'STRING_FIELDS_REQUIRED')

        local invalid_reward_ref = level_reward_plan()
        invalid_reward_ref.rewards[1].reward_ref = 'item_level_two'
        assert_plan_invalid(invalid_reward_ref, 'REWARD_REF_INVALID')

        local sparse_rewards = level_reward_plan()
        sparse_rewards.rewards[3] = sparse_rewards.rewards[2]
        sparse_rewards.rewards[2] = nil
        assert_plan_invalid(
            sparse_rewards,
            'PLAIN_DENSE_REWARD_ARRAY_REQUIRED'
        )

        local hostile_metatable = {
            __index = function()
                error('hostile digest __index must not be invoked')
            end,
            __len = function()
                error('hostile digest __len must not be invoked')
            end,
            __pairs = function()
                error('hostile digest __pairs must not be invoked')
            end,
            __metatable = 'locked-hostile-digest-metatable',
        }

        local hostile_plan = level_reward_plan()
        setmetatable(hostile_plan, hostile_metatable)
        assert_plan_invalid(hostile_plan, 'PLAIN_TABLE_REQUIRED')

        local hostile_rewards = level_reward_plan()
        setmetatable(hostile_rewards.rewards, hostile_metatable)
        assert_plan_invalid(
            hostile_rewards,
            'PLAIN_DENSE_REWARD_ARRAY_REQUIRED'
        )

        local hostile_row = level_reward_plan()
        setmetatable(hostile_row.rewards[1], hostile_metatable)
        assert_plan_invalid(hostile_row, 'PLAIN_TABLE_REQUIRED')
    end),

    case('level reward plan digest enforces transition bounds, strict order, and 64 rows', function()
        assert.equal(LevelRewardPlanDigest.MAX_REWARD_REFS, 64)

        local safe_maximum = level_reward_plan()
        safe_maximum.definition_version = Progression.MAX_SAFE_INTEGER
        safe_maximum.expected_revision = Progression.MAX_SAFE_INTEGER
        safe_maximum.old_level = 99
        safe_maximum.new_level = 100
        safe_maximum.rewards = {
            { reached_level = 100, reward_ref = 'reward_level_100' },
        }
        assert.equal(LevelRewardPlanDigest.derive(safe_maximum).ok, true)

        local definition_overflow = deep_copy(safe_maximum)
        definition_overflow.definition_version = Progression.MAX_SAFE_INTEGER + 1
        assert.error_reason(
            LevelRewardPlanDigest.derive(definition_overflow),
            'DEFINITION_VERSION_INVALID'
        )

        local revision_overflow = deep_copy(safe_maximum)
        revision_overflow.expected_revision = Progression.MAX_SAFE_INTEGER + 1
        assert.error_reason(
            LevelRewardPlanDigest.derive(revision_overflow),
            'EXPECTED_REVISION_INVALID'
        )

        local level_cap = deep_copy(safe_maximum)
        level_cap.old_level = 100
        level_cap.new_level = 100
        level_cap.rewards = {}
        assert.equal(LevelRewardPlanDigest.derive(level_cap).ok, true)

        local above_level_cap = deep_copy(level_cap)
        above_level_cap.new_level = 101
        assert.error_reason(
            LevelRewardPlanDigest.derive(above_level_cap),
            'NEW_LEVEL_INVALID'
        )

        local at_old_level = level_reward_plan()
        at_old_level.rewards[1].reached_level = 1
        local at_old_result = LevelRewardPlanDigest.derive(at_old_level)
        assert.error_code(at_old_result, 'CHARACTER_REWARD_PLAN_INVALID')
        assert.error_reason(at_old_result, 'REACHED_LEVEL_OUTSIDE_TRANSITION')

        local above_new_level = level_reward_plan()
        above_new_level.rewards[2].reached_level = 4
        local above_new_result = LevelRewardPlanDigest.derive(above_new_level)
        assert.error_code(above_new_result, 'CHARACTER_REWARD_PLAN_INVALID')
        assert.error_reason(
            above_new_result,
            'REACHED_LEVEL_OUTSIDE_TRANSITION'
        )

        local duplicate = level_reward_plan()
        duplicate.rewards[2].reached_level = 2
        local duplicate_result = LevelRewardPlanDigest.derive(duplicate)
        assert.error_code(duplicate_result, 'CHARACTER_REWARD_PLAN_INVALID')
        assert.error_reason(
            duplicate_result,
            'STRICT_ASCENDING_REACHED_LEVEL_REQUIRED'
        )

        local reversed = level_reward_plan()
        reversed.rewards[1].reached_level = 3
        reversed.rewards[2].reached_level = 2
        local reversed_result = LevelRewardPlanDigest.derive(reversed)
        assert.error_code(reversed_result, 'CHARACTER_REWARD_PLAN_INVALID')
        assert.error_reason(
            reversed_result,
            'STRICT_ASCENDING_REACHED_LEVEL_REQUIRED'
        )

        local maximum = level_reward_plan()
        maximum.new_level = 65
        maximum.rewards = {}
        local index
        for index = 1, LevelRewardPlanDigest.MAX_REWARD_REFS do
            maximum.rewards[index] = {
                reached_level = index + 1,
                reward_ref = 'reward_level_' .. tostring(index + 1),
            }
        end
        local maximum_result = LevelRewardPlanDigest.derive(maximum)
        assert.equal(maximum_result.ok, true)
        assert.equal(maximum_result.value.count, 64)
        assert.equal(#maximum_result.value.digest, 64)

        local over_limit = deep_copy(maximum)
        over_limit.new_level = 66
        over_limit.rewards[65] = {
            reached_level = 66,
            reward_ref = 'reward_level_66',
        }
        local over_limit_result = LevelRewardPlanDigest.derive(over_limit)
        assert.error_code(over_limit_result, 'CHARACTER_REWARD_PLAN_INVALID')
        assert.error_reason(
            over_limit_result,
            'REWARD_REF_COUNT_LIMIT_EXCEEDED'
        )
    end),

    case('stat pipeline computes the complete documented base formula block', function()
        local result = StatPipeline.calculate(pipeline_request())
        assert.equal(result.ok, true)
        assert.deep_equal(result.value.primary, {
            strength = 10,
            constitution = 20,
            agility = 30,
            inner_power = 40,
        })
        assert.deep_equal(result.value.stats, {
            max_hp = 460,
            attack = 75,
            defense = 55,
            speed = 1360,
            accuracy = 7240,
            evasion = 150,
            crit_chance_bp = 0,
            crit_damage_bp = 15000,
            crit_resist_bp = 0,
            block_chance_bp = 0,
            block_reduction_bp = 2500,
            damage_bonus_bp = 0,
            damage_reduction_bp = 0,
            healing_bonus_bp = 0,
            healing_received_bp = 0,
            max_qi = 1080,
            initial_qi = 100,
            qi_gain_bp = 10000,
            effect_accuracy = 160,
            effect_resistance = 60,
        })
        assert.equal(result.value.applied_contribution_count, 0)
    end),

    case('primary growth floors per level and reports the 9999 hard clamp', function()
        local request = pipeline_request()
        request.level = 3
        request.base_primary.strength = 9998
        request.base_primary.agility = 10
        request.growth_per_level_milli.strength = 1000
        request.growth_per_level_milli.agility = 750

        local result = StatPipeline.calculate(request)
        assert.equal(result.ok, true)
        assert.equal(result.value.primary.strength, 9999)
        assert.equal(result.value.primary.agility, 11)

        local diagnostic = find_diagnostic(result, 'STAT_CLAMPED', 'strength')
        assert.not_nil(diagnostic)
        assert.equal(diagnostic.before, 10000)
        assert.equal(diagnostic.after, 9999)
        assert.equal(diagnostic.maximum, 9999)
    end),

    case('stat contribution condition tags use all-tags matching', function()
        local rows = {
            contribution('ADD_FLAT', 10, 'condition:always'),
            contribution('ADD_FLAT', 20, 'condition:night:pve', {
                condition_tags = { 'NIGHT', 'PVE' },
            }),
            contribution('ADD_FLAT', 40, 'condition:night:raid', {
                condition_tags = { 'NIGHT', 'RAID' },
            }),
        }

        local full_context = StatPipeline.calculate(
            pipeline_request(rows, { 'NIGHT', 'PVE' })
        )
        assert.equal(full_context.ok, true)
        assert.equal(full_context.value.stats.attack, 105)
        assert.equal(full_context.value.applied_contribution_count, 2)

        local partial_context = StatPipeline.calculate(
            pipeline_request(rows, { 'NIGHT' })
        )
        assert.equal(partial_context.ok, true)
        assert.equal(partial_context.value.stats.attack, 85)
        assert.equal(partial_context.value.applied_contribution_count, 1)
    end),

    case('character ordering uses canonical byte order instead of process locale', function()
        assert.equal(Ordered.bytewise_string_less('A:a', 'a:a'), true)
        assert.equal(Ordered.bytewise_string_less('a:a', 'A:a'), false)

        local rows = {
            contribution('ADD_FLAT', 1, 'locale:flat', {
                target_stat = 'crit_chance_bp',
            }),
            contribution('MULTIPLY_BP', 40005, 'a:a', {
                target_stat = 'crit_chance_bp',
            }),
            contribution('MULTIPLY_BP', 2500, 'A:a', {
                target_stat = 'crit_chance_bp',
            }),
        }
        local result = StatPipeline.calculate(pipeline_request(rows, { 'A', 'a' }))
        assert.equal(result.ok, true)
        assert.equal(result.value.stats.crit_chance_bp, 0)

        local crit = find_stat_row(result, 'crit_chance_bp')
        assert.equal(crit.stages[4].stable_order_key, 'A:a')
        assert.equal(crit.stages[5].stable_order_key, 'a:a')

        local reversed = StatPipeline.calculate(pipeline_request({}, { 'a', 'A' }))
        assert.error_code(reversed, 'CHARACTER_CONTRIBUTION_INVALID')
        assert.error_reason(reversed, 'CONTEXT_TAGS_STRICT_ASCENDING_REQUIRED')
    end),

    case('stat pipeline applies flat then additive basis points then multiply with floor', function()
        local rows = {
            contribution('MULTIPLY_BP', 12500, 'operation:multiply', {
                priority = -20,
            }),
            contribution('ADD_BP', 3333, 'operation:add_bp', {
                priority = -10,
            }),
            contribution('ADD_FLAT', 2, 'operation:add_flat', {
                priority = 100,
            }),
        }
        local result = StatPipeline.calculate(pipeline_request(rows))
        assert.equal(result.ok, true)
        assert.equal(result.value.stats.attack, 127)

        local attack = find_stat_row(result, 'attack')
        assert.not_nil(attack)
        assert.equal(attack.stages[1].stage, 'BASE')
        assert.equal(attack.stages[1].value_after, 75)
        assert.equal(attack.stages[2].stage, 'ADD_FLAT')
        assert.equal(attack.stages[2].value_after, 77)
        assert.equal(attack.stages[3].stage, 'ADD_BP')
        assert.equal(attack.stages[3].value_after, 102)
        assert.equal(attack.stages[4].stage, 'MULTIPLY_BP')
        assert.equal(attack.stages[4].value_after, 127)
    end),

    case('negative contribution stages use mathematical floor instead of truncation', function()
        local rows = {
            contribution('ADD_FLAT', -1, 'negative:flat', {
                target_stat = 'damage_bonus_bp',
            }),
            contribution('ADD_BP', 5000, 'negative:add_bp', {
                target_stat = 'damage_bonus_bp',
            }),
            contribution('MULTIPLY_BP', 5000, 'negative:multiply', {
                target_stat = 'damage_bonus_bp',
            }),
            contribution('ADD_BP', -3333, 'negative:add_bp:value', {
                target_stat = 'attack',
            }),
        }
        local result = StatPipeline.calculate(pipeline_request(rows))
        assert.equal(result.ok, true)
        assert.equal(result.value.stats.damage_bonus_bp, -1)
        assert.equal(result.value.stats.attack, 50)

        local damage_bonus = find_stat_row(result, 'damage_bonus_bp')
        assert.not_nil(damage_bonus)
        assert.equal(damage_bonus.stages[2].value_after, -1)
        assert.equal(damage_bonus.stages[3].value_after, -2)
        assert.equal(damage_bonus.stages[4].value_after, -1)
    end),

    case('hard stat caps clamp safely and emit an exact diagnostic', function()
        local rows = {
            contribution('ADD_FLAT', 1000000000, 'clamp:attack'),
        }
        local result = StatPipeline.calculate(pipeline_request(rows))
        assert.equal(result.ok, true)
        assert.equal(result.value.stats.attack, 10000000)

        local attack = find_stat_row(result, 'attack')
        assert.not_nil(attack)
        assert.equal(attack.pre_hard_clamp_value, 1000000075)
        assert.equal(attack.final_value, 10000000)

        local diagnostic = find_diagnostic(result, 'STAT_CLAMPED', 'attack')
        assert.not_nil(diagnostic)
        assert.equal(diagnostic.before, 1000000075)
        assert.equal(diagnostic.after, 10000000)
        assert.equal(diagnostic.maximum, 10000000)
    end),

    case('lowered max qi dynamically clamps initial qi and records the effective cap', function()
        local rows = {
            contribution('SET_MAX', 500, 'qi:max', {
                target_stat = 'max_qi',
            }),
        }
        local request = pipeline_request(rows)
        request.initial_qi = 1000
        local result = StatPipeline.calculate(request)
        assert.equal(result.ok, true)
        assert.equal(result.value.stats.max_qi, 500)
        assert.equal(result.value.stats.initial_qi, 500)

        local diagnostic = find_diagnostic(result, 'STAT_CLAMPED', 'initial_qi')
        assert.not_nil(diagnostic)
        assert.equal(diagnostic.before, 1000)
        assert.equal(diagnostic.after, 500)
        assert.equal(diagnostic.maximum, 500)
    end),

    case('stat pipeline rejects duplicate order keys and out-of-range multipliers', function()
        local duplicate_key = {
            contribution('ADD_FLAT', 1, 'duplicate:order:key'),
            contribution('ADD_BP', 100, 'duplicate:order:key'),
        }
        local duplicate_result = StatPipeline.calculate(pipeline_request(duplicate_key))
        assert.error_code(duplicate_result, 'CHARACTER_CONTRIBUTION_INVALID')
        assert.error_reason(duplicate_result, 'DUPLICATE_STABLE_ORDER_KEY')

        local invalid_multipliers = {
            -1,
            50001,
        }
        local index
        for index = 1, #invalid_multipliers do
            local rows = {
                contribution(
                    'MULTIPLY_BP',
                    invalid_multipliers[index],
                    'invalid:multiplier:' .. tostring(index)
                ),
            }
            local result = StatPipeline.calculate(pipeline_request(rows))
            assert.error_code(result, 'CHARACTER_CONTRIBUTION_INVALID')
            assert.error_reason(result, 'MULTIPLIER_OUT_OF_RANGE')
        end
    end),

    case('safe multiply-divide survives a raw 2^53 product before hard clamp', function()
        local rows = {
            contribution('ADD_FLAT', 1000000000, 'safe:large:flat'),
            contribution('ADD_BP', 1000000000, 'safe:large:add_bp'),
        }
        local result = StatPipeline.calculate(pipeline_request(rows))
        assert.equal(result.ok, true)
        assert.equal(result.value.stats.attack, 10000000)

        local attack = find_stat_row(result, 'attack')
        assert.not_nil(attack)
        assert.equal(attack.pre_hard_clamp_value, 100001007500075)
        assert.equal(attack.final_value, 10000000)
    end),

    case('formula bounds and true safe-integer overflow fail closed', function()
        local invalid_formula = pipeline_request()
        invalid_formula.formula.base_attack = Progression.MAX_SAFE_INTEGER + 1
        local formula_result = StatPipeline.calculate(invalid_formula)
        assert.error_code(formula_result, 'CHARACTER_FORMULA_INVALID')
        assert.error_reason(formula_result, 'COEFFICIENT_NOT_SAFE_INTEGER')

        local formula_overflow = pipeline_request()
        formula_overflow.formula.base_attack = Progression.MAX_SAFE_INTEGER
        formula_overflow.formula.attack_per_level = 1
        formula_overflow.formula.attack_per_strength = 0
        formula_overflow.formula.attack_per_inner_power_milli = 0
        local formula_overflow_result = StatPipeline.calculate(formula_overflow)
        assert.error_code(formula_overflow_result, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(formula_overflow_result, 'INTEGER_OVERFLOW')
        assert.equal(formula_overflow_result.error.details.target_stat, 'attack')
        assert.equal(formula_overflow_result.error.details.stage, 'BASE_FORMULA')

        local rows = {}
        local index
        for index = 1, 21 do
            rows[index] = contribution(
                'MULTIPLY_BP',
                50000,
                string.format('overflow:multiply:%02d', index)
            )
        end
        local overflow = pipeline_request(rows)
        local overflow_result = StatPipeline.calculate(overflow)
        assert.error_code(overflow_result, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(overflow_result, 'INTEGER_OVERFLOW')
        assert.equal(overflow_result.error.details.target_stat, 'attack')
        assert.equal(overflow_result.error.details.stage, 'MULTIPLY_BP')
        assert.equal(
            overflow_result.error.details.stable_order_key,
            'overflow:multiply:21'
        )
    end),

    case('schema and domain entry points reject hostile metatable inputs', function()
        local hostile_metatable = {
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

        local schema_value = character_definition()
        setmetatable(schema_value, hostile_metatable)
        local schema_result = CharacterDefinition.validate(schema_value)
        assert.error_code(schema_result, 'SCHEMA_VALIDATION_FAILED')
        assert.error_reason(schema_result, 'TABLE_REQUIRED')

        local curve = {
            level_cap = 2,
            cumulative_exp_by_level = { 0, 100 },
        }
        setmetatable(curve, hostile_metatable)
        local curve_result = Progression.resolve_level(curve, 100)
        assert.error_code(curve_result, 'CHARACTER_LEVEL_CURVE_INVALID')
        assert.error_reason(curve_result, 'TABLE_REQUIRED')

        local request = pipeline_request()
        setmetatable(request, hostile_metatable)
        local request_result = StatPipeline.calculate(request)
        assert.error_code(request_result, 'CHARACTER_ARGUMENT_INVALID')
        assert.error_reason(request_result, 'TABLE_REQUIRED')

        local formula_request = pipeline_request()
        setmetatable(formula_request.formula, hostile_metatable)
        local formula_metatable_result = StatPipeline.calculate(formula_request)
        assert.error_code(formula_metatable_result, 'CHARACTER_FORMULA_INVALID')
        assert.error_reason(formula_metatable_result, 'TABLE_REQUIRED')

        local contribution_request = pipeline_request({
            contribution('ADD_FLAT', 1, 'hostile:contribution'),
        })
        setmetatable(contribution_request.contributions[1], hostile_metatable)
        local contribution_result = StatPipeline.calculate(contribution_request)
        assert.error_code(contribution_result, 'CHARACTER_CONTRIBUTION_INVALID')
        assert.error_reason(contribution_result, 'CANONICAL_CONTRIBUTION_INVALID')

        local nested_request = pipeline_request({
            contribution('ADD_FLAT', 1, 'hostile:condition_tags'),
        })
        setmetatable(
            nested_request.contributions[1].condition_tags,
            hostile_metatable
        )
        local nested_result = StatPipeline.calculate(nested_request)
        assert.error_code(nested_result, 'CHARACTER_CONTRIBUTION_INVALID')
        assert.error_reason(nested_result, 'CANONICAL_CONTRIBUTION_INVALID')

        local talent = talent_definition()
        setmetatable(talent.contributions[1].condition_tags, hostile_metatable)
        local talent_result = TalentDefinition.validate(talent)
        assert.error_code(talent_result, 'SCHEMA_VALIDATION_FAILED')
        assert.error_reason(talent_result, 'STAT_CONTRIBUTION_INVALID')
    end),

    case('invalid contribution errors do not retain caller table aliases', function()
        local hostile_value = { mutable = true }
        local row = contribution('ADD_FLAT', 1, 'alias:invalid')
        row.source_type = hostile_value
        local result = StatPipeline.calculate(pipeline_request({ row }))
        assert.error_code(result, 'CHARACTER_CONTRIBUTION_INVALID')
        assert.error_reason(result, 'CANONICAL_CONTRIBUTION_INVALID')
        assert.is_nil(result.error.details.cause.details.actual)

        result.error.details.cause.details.reason = 'CHANGED'
        assert.equal(hostile_value.mutable, true)
    end),

    case('set constraints reject conflicts and ambiguous highest priorities', function()
        local conflict = {
            contribution('SET_MIN', 100, 'constraint:min'),
            contribution('SET_MAX', 90, 'constraint:max'),
        }
        local conflict_result = StatPipeline.calculate(pipeline_request(conflict))
        assert.error_code(conflict_result, 'CHARACTER_BUILD_INVALID')
        assert.error_reason(conflict_result, 'STAT_CONSTRAINT_CONFLICT')

        local operations = {
            'SET_MIN',
            'SET_MAX',
        }
        local index
        for index = 1, #operations do
            local operation = operations[index]
            local rows = {
                contribution(operation, 80, 'ambiguous:a:' .. tostring(index), {
                    priority = 10,
                }),
                contribution(operation, 90, 'ambiguous:b:' .. tostring(index), {
                    priority = 10,
                }),
                contribution(operation, 70, 'ambiguous:lower:' .. tostring(index), {
                    priority = 9,
                }),
            }
            local result = StatPipeline.calculate(pipeline_request(rows))
            assert.error_code(result, 'CHARACTER_CONTRIBUTION_INVALID')
            assert.error_reason(result, 'AMBIGUOUS_HIGHEST_PRIORITY_CONSTRAINT')
            assert.equal(result.error.details.operation, operation)
            assert.equal(result.error.details.priority, 10)
        end
    end),

    case('all contribution input permutations are deterministic and inputs stay immutable', function()
        local rows = {
            contribution('ADD_FLAT', 2, 'permutation:flat', { priority = 30 }),
            contribution('ADD_BP', 3333, 'permutation:add_bp', { priority = -10 }),
            contribution('MULTIPLY_BP', 12500, 'permutation:multiply', {
                priority = 0,
            }),
            contribution('SET_MIN', 100, 'permutation:min', { priority = 10 }),
            contribution('SET_MAX', 200, 'permutation:max', { priority = 10 }),
        }
        local permutations = all_permutations(rows)
        assert.equal(#permutations, 120)

        local expected
        local index
        for index = 1, #permutations do
            local request = pipeline_request(permutations[index], { 'PVE' })
            local before = deep_copy(request)
            local result = StatPipeline.calculate(request)
            assert.equal(result.ok, true)
            assert.deep_equal(request, before, 'stat pipeline mutated permutation #' .. tostring(index))
            if expected == nil then
                expected = deep_copy(result.value)
            else
                assert.deep_equal(
                    result.value,
                    expected,
                    'permutation changed result #' .. tostring(index)
                )
            end
        end
    end),
}
