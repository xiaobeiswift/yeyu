local Harness = require 'wzx.tests.harness'
local AttributeFormulaSet = require 'wzx.config.schema.character.attribute_formula_set'
local CharacterDefinition = require 'wzx.config.schema.character.character_definition'
local LevelCurve = require 'wzx.config.schema.character.level_curve'
local TalentDefinition = require 'wzx.config.schema.character.talent_definition'
local Ordered = require 'wzx.domain.common.ordered'
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
        cumulative_exp_by_level = {
            0,
            100,
            250,
            500,
        },
        level_reward_refs = {
            'reward_level_two',
            'reward_level_three',
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
        assert.equal(curve_result.value.cumulative_exp_by_level[2], 100)

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
        single_level.cumulative_exp_by_level = { 0 }
        assert.equal(LevelCurve.validate(single_level).ok, true)

        local safe_maximum = level_curve()
        safe_maximum.level_cap = 3
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
