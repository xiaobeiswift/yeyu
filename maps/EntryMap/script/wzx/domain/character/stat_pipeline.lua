local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local Attributes = require 'wzx.domain.character.attributes'
local ContributionSet = require 'wzx.domain.character.contribution_set'
local ErrorCodes = require 'wzx.domain.character.error_codes'

local StatPipeline = {}

local MAX_SAFE_INTEGER = 9007199254740991
local REQUEST_FIELDS = {
    level = true,
    base_primary = true,
    growth_per_level_milli = true,
    formula = true,
    initial_qi = true,
    contributions = true,
    context_tags = true,
}
local FORMULA_FIELDS = {
    id = true,
    formula_version = true,
    base_hp = true,
    hp_per_level = true,
    hp_per_constitution = true,
    base_attack = true,
    attack_per_level = true,
    attack_per_strength = true,
    attack_per_inner_power_milli = true,
    base_defense = true,
    defense_per_level = true,
    defense_per_constitution = true,
    base_speed = true,
    speed_per_agility = true,
    base_accuracy = true,
    accuracy_per_agility = true,
    base_evasion = true,
    evasion_per_agility = true,
    base_max_qi = true,
    max_qi_per_inner_power = true,
    effect_accuracy_per_inner_power = true,
    effect_resistance_per_constitution = true,
}
local COEFFICIENT_KEYS = {
    'base_hp',
    'hp_per_level',
    'hp_per_constitution',
    'base_attack',
    'attack_per_level',
    'attack_per_strength',
    'attack_per_inner_power_milli',
    'base_defense',
    'defense_per_level',
    'defense_per_constitution',
    'base_speed',
    'speed_per_agility',
    'base_accuracy',
    'accuracy_per_agility',
    'base_evasion',
    'evasion_per_agility',
    'base_max_qi',
    'max_qi_per_inner_power',
    'effect_accuracy_per_inner_power',
    'effect_resistance_per_constitution',
}
local STAT_ORDER = {
    'max_hp',
    'attack',
    'defense',
    'speed',
    'accuracy',
    'evasion',
    'crit_chance_bp',
    'crit_damage_bp',
    'crit_resist_bp',
    'block_chance_bp',
    'block_reduction_bp',
    'damage_bonus_bp',
    'damage_reduction_bp',
    'healing_bonus_bp',
    'healing_received_bp',
    'max_qi',
    'initial_qi',
    'qi_gain_bp',
    'effect_accuracy',
    'effect_resistance',
}
local HARD_RANGES = {
    max_hp = { 1, 2000000000 },
    attack = { 1, 10000000 },
    defense = { 0, 10000000 },
    speed = { 1, 100000 },
    accuracy = { 0, 10000 },
    evasion = { 0, 10000 },
    crit_chance_bp = { 0, 7500 },
    crit_damage_bp = { 10000, 30000 },
    crit_resist_bp = { 0, 7500 },
    block_chance_bp = { 0, 7500 },
    block_reduction_bp = { 0, 8000 },
    damage_bonus_bp = { -9000, 50000 },
    damage_reduction_bp = { -50000, 9000 },
    healing_bonus_bp = { -9000, 50000 },
    healing_received_bp = { -9000, 50000 },
    max_qi = { 100, 2000 },
    initial_qi = { 0, 2000 },
    qi_gain_bp = { 0, 50000 },
    effect_accuracy = { 0, 10000 },
    effect_resistance = { 0, 10000 },
}

local function failure(code, message_key, reason, details)
    details = details or {}
    details.reason = reason
    return Result.err(code, message_key, false, details)
end

local function argument_failure(reason, details)
    return failure(
        ErrorCodes.CHARACTER_ARGUMENT_INVALID,
        'error.character.argument_invalid',
        reason,
        details
    )
end

local function formula_failure(reason, details)
    return failure(
        ErrorCodes.CHARACTER_FORMULA_INVALID,
        'error.character.formula_invalid',
        reason,
        details
    )
end

local function build_failure(reason, details)
    return failure(
        ErrorCodes.CHARACTER_BUILD_INVALID,
        'error.character.build_invalid',
        reason,
        details
    )
end

local function contribution_failure(reason, details)
    return failure(
        ErrorCodes.CHARACTER_CONTRIBUTION_INVALID,
        'error.character.contribution_invalid',
        reason,
        details
    )
end

local function validate_exact_fields(value, allowed, failure_callback)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return failure_callback('TABLE_REQUIRED')
    end
    local keys = Ordered.sorted_string_keys(value)
    if not keys.ok then
        return failure_callback('STRING_FIELDS_REQUIRED')
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        if not allowed[key] then
            return failure_callback('UNKNOWN_FIELD', { field = key })
        end
    end
    return Result.ok(true)
end

local function validate_formula(formula)
    local shape = validate_exact_fields(formula, FORMULA_FIELDS, formula_failure)
    if not shape.ok then
        return shape
    end
    local id_result = RuntimeId.validate_content(formula.id, nil, 'formula.id')
    if not id_result.ok then
        return formula_failure('ID_INVALID', { field = 'id' })
    end
    if not TableShape.is_integer(formula.formula_version, 1, MAX_SAFE_INTEGER) then
        return formula_failure('FORMULA_VERSION_INVALID', { field = 'formula_version' })
    end

    local index
    for index = 1, #COEFFICIENT_KEYS do
        local key = COEFFICIENT_KEYS[index]
        if not TableShape.is_integer(
            formula[key],
            -MAX_SAFE_INTEGER,
            MAX_SAFE_INTEGER
        ) then
            return formula_failure('COEFFICIENT_NOT_SAFE_INTEGER', {
                field = key,
            })
        end
    end
    return Result.ok(true)
end

local function safe_add(left, right)
    if right > 0 and left > MAX_SAFE_INTEGER - right then
        return nil
    end
    if right < 0 and left < -MAX_SAFE_INTEGER - right then
        return nil
    end
    return left + right
end

local function safe_multiply(left, right)
    if left == 0 or right == 0 then
        return 0
    end
    if math.abs(left) > math.floor(MAX_SAFE_INTEGER / math.abs(right)) then
        return nil
    end
    return left * right
end

-- Computes floor(left * right / divisor) without first forming a possibly
-- unsafe product. Quotient/remainder decomposition keeps every intermediate
-- integer within the Lua 5.1 exact-integer envelope or fails closed.
local function safe_multiply_divide_floor(left, right, divisor)
    if not TableShape.is_integer(left, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER)
        or not TableShape.is_integer(right, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER)
        or not TableShape.is_integer(divisor, 1, 10000)
    then
        return nil
    end
    if left == 0 or right == 0 then
        return 0
    end

    local negative = (left < 0) ~= (right < 0)
    local absolute_left = math.abs(left)
    local absolute_right = math.abs(right)
    local left_quotient = math.floor(absolute_left / divisor)
    local left_remainder = absolute_left - left_quotient * divisor
    local right_quotient = math.floor(absolute_right / divisor)
    local right_remainder = absolute_right - right_quotient * divisor

    local quotient_part = safe_multiply(left_quotient, absolute_right)
    local cross_part = safe_multiply(left_remainder, right_quotient)
    local remainder_product = safe_multiply(left_remainder, right_remainder)
    if quotient_part == nil or cross_part == nil or remainder_product == nil then
        return nil
    end
    local remainder_part = math.floor(remainder_product / divisor)
    local total = safe_add(quotient_part, cross_part)
    if total == nil then
        return nil
    end
    total = safe_add(total, remainder_part)
    if total == nil then
        return nil
    end
    if not negative then
        return total
    end

    local has_fraction = remainder_product % divisor ~= 0
    if has_fraction then
        if total == MAX_SAFE_INTEGER then
            return nil
        end
        return -total - 1
    end
    return -total
end

local function checked_sum(target_stat, stage, values)
    local total = 0
    local index
    for index = 1, #values do
        total = safe_add(total, values[index])
        if total == nil then
            return nil, build_failure('INTEGER_OVERFLOW', {
                target_stat = target_stat,
                stage = stage,
            })
        end
    end
    return total
end

local function checked_linear(target_stat, terms)
    local values = {}
    local index
    for index = 1, #terms do
        local term = terms[index]
        local product
        if term[3] ~= nil then
            product = safe_multiply_divide_floor(term[1], term[2], term[3])
        else
            product = safe_multiply(term[1], term[2])
        end
        if product == nil then
            return nil, build_failure('INTEGER_OVERFLOW', {
                target_stat = target_stat,
                stage = 'BASE_FORMULA',
            })
        end
        values[index] = product
    end
    return checked_sum(target_stat, 'BASE_FORMULA', values)
end

local function calculate_base_stats(level, primary, formula, initial_qi)
    local stats = {}
    local err

    stats.max_hp, err = checked_linear('max_hp', {
        { formula.base_hp, 1 },
        { formula.hp_per_level, level },
        { formula.hp_per_constitution, primary.constitution },
    })
    if err ~= nil then return nil, err end

    stats.attack, err = checked_linear('attack', {
        { formula.base_attack, 1 },
        { formula.attack_per_level, level },
        { formula.attack_per_strength, primary.strength },
        { formula.attack_per_inner_power_milli, primary.inner_power, 1000 },
    })
    if err ~= nil then return nil, err end

    stats.defense, err = checked_linear('defense', {
        { formula.base_defense, 1 },
        { formula.defense_per_level, level },
        { formula.defense_per_constitution, primary.constitution },
    })
    if err ~= nil then return nil, err end

    stats.speed, err = checked_linear('speed', {
        { formula.base_speed, 1 },
        { formula.speed_per_agility, primary.agility },
    })
    if err ~= nil then return nil, err end

    stats.accuracy, err = checked_linear('accuracy', {
        { formula.base_accuracy, 1 },
        { formula.accuracy_per_agility, primary.agility },
    })
    if err ~= nil then return nil, err end

    stats.evasion, err = checked_linear('evasion', {
        { formula.base_evasion, 1 },
        { formula.evasion_per_agility, primary.agility },
    })
    if err ~= nil then return nil, err end

    stats.max_qi, err = checked_linear('max_qi', {
        { formula.base_max_qi, 1 },
        { formula.max_qi_per_inner_power, primary.inner_power },
    })
    if err ~= nil then return nil, err end

    stats.effect_accuracy, err = checked_linear('effect_accuracy', {
        { formula.effect_accuracy_per_inner_power, primary.inner_power },
    })
    if err ~= nil then return nil, err end

    stats.effect_resistance, err = checked_linear('effect_resistance', {
        { formula.effect_resistance_per_constitution, primary.constitution },
    })
    if err ~= nil then return nil, err end

    -- These are the neutral values needed to complete CombatantStatBlock. The
    -- formula set owns only the nine derived formulas specified by System 01.
    stats.crit_chance_bp = 0
    stats.crit_damage_bp = 15000
    stats.crit_resist_bp = 0
    stats.block_chance_bp = 0
    stats.block_reduction_bp = 2500
    stats.damage_bonus_bp = 0
    stats.damage_reduction_bp = 0
    stats.healing_bonus_bp = 0
    stats.healing_received_bp = 0
    stats.initial_qi = initial_qi
    stats.qi_gain_bp = 10000
    return stats
end

local function copy_contribution(value)
    local tags = {}
    local index
    for index = 1, #value.condition_tags do
        tags[index] = value.condition_tags[index]
    end
    return {
        source_type = value.source_type,
        source_id = value.source_id,
        target_stat = value.target_stat,
        operation = value.operation,
        value = value.value,
        priority = value.priority,
        condition_tags = tags,
        stable_order_key = value.stable_order_key,
    }
end

local function append_stage(stages, stage, value_after, details)
    local row = details or {}
    row.stage = stage
    row.value_after = value_after
    stages[#stages + 1] = row
end

local function select_constraint(rows, operation, target_stat)
    local selected
    local selected_priority
    local count_at_priority = 0
    local index
    for index = 1, #rows do
        local row = rows[index]
        if row.operation == operation then
            if selected_priority == nil or row.priority > selected_priority then
                selected = row
                selected_priority = row.priority
                count_at_priority = 1
            elseif row.priority == selected_priority then
                count_at_priority = count_at_priority + 1
            end
        end
    end
    if count_at_priority > 1 then
        return nil, contribution_failure('AMBIGUOUS_HIGHEST_PRIORITY_CONSTRAINT', {
            target_stat = target_stat,
            operation = operation,
            priority = selected_priority,
        })
    end
    return selected
end

local function evaluate_stat(target_stat, base_value, rows, hard_minimum, hard_maximum)
    local stages = {}
    append_stage(stages, 'BASE', base_value)

    local value = base_value
    local flat_values = {}
    local add_bp_values = {}
    local index
    for index = 1, #rows do
        local row = rows[index]
        if row.operation == 'ADD_FLAT' then
            flat_values[#flat_values + 1] = row.value
        elseif row.operation == 'ADD_BP' then
            add_bp_values[#add_bp_values + 1] = row.value
        end
    end

    local flat_total, flat_error = checked_sum(target_stat, 'ADD_FLAT', flat_values)
    if flat_error ~= nil then return nil, flat_error end
    value = safe_add(value, flat_total)
    if value == nil then
        return nil, build_failure('INTEGER_OVERFLOW', {
            target_stat = target_stat,
            stage = 'ADD_FLAT',
        })
    end
    append_stage(stages, 'ADD_FLAT', value, { total = flat_total })

    local add_bp_total, add_bp_error = checked_sum(target_stat, 'ADD_BP', add_bp_values)
    if add_bp_error ~= nil then return nil, add_bp_error end
    local factor = safe_add(10000, add_bp_total)
    if factor == nil then
        return nil, build_failure('INTEGER_OVERFLOW', {
            target_stat = target_stat,
            stage = 'ADD_BP',
        })
    end
    if factor < 0 then factor = 0 end
    local multiplied = safe_multiply_divide_floor(value, factor, 10000)
    if multiplied == nil then
        return nil, build_failure('INTEGER_OVERFLOW', {
            target_stat = target_stat,
            stage = 'ADD_BP',
        })
    end
    value = multiplied
    append_stage(stages, 'ADD_BP', value, {
        basis_points = add_bp_total,
        factor_basis_points = factor,
    })

    for index = 1, #rows do
        local row = rows[index]
        if row.operation == 'MULTIPLY_BP' then
            multiplied = safe_multiply_divide_floor(value, row.value, 10000)
            if multiplied == nil then
                return nil, build_failure('INTEGER_OVERFLOW', {
                    target_stat = target_stat,
                    stage = 'MULTIPLY_BP',
                    stable_order_key = row.stable_order_key,
                })
            end
            value = multiplied
            append_stage(stages, 'MULTIPLY_BP', value, {
                multiplier_bp = row.value,
                stable_order_key = row.stable_order_key,
            })
        end
    end

    local set_min, min_error = select_constraint(rows, 'SET_MIN', target_stat)
    if min_error ~= nil then return nil, min_error end
    local set_max, max_error = select_constraint(rows, 'SET_MAX', target_stat)
    if max_error ~= nil then return nil, max_error end
    local constraint_minimum = set_min and set_min.value or nil
    local constraint_maximum = set_max and set_max.value or nil
    if constraint_minimum ~= nil
        and constraint_maximum ~= nil
        and constraint_minimum > constraint_maximum
    then
        return nil, build_failure('STAT_CONSTRAINT_CONFLICT', {
            target_stat = target_stat,
            minimum = constraint_minimum,
            maximum = constraint_maximum,
        })
    end
    if constraint_minimum ~= nil and value < constraint_minimum then
        value = constraint_minimum
    end
    if constraint_maximum ~= nil and value > constraint_maximum then
        value = constraint_maximum
    end
    append_stage(stages, 'SET_MIN_MAX', value, {
        minimum = constraint_minimum,
        maximum = constraint_maximum,
        minimum_stable_order_key = set_min and set_min.stable_order_key or nil,
        maximum_stable_order_key = set_max and set_max.stable_order_key or nil,
    })

    local before_hard_clamp = value
    if value < hard_minimum then value = hard_minimum end
    if value > hard_maximum then value = hard_maximum end
    append_stage(stages, 'HARD_CLAMP', value, {
        before = before_hard_clamp,
        minimum = hard_minimum,
        maximum = hard_maximum,
    })

    local copied_rows = {}
    for index = 1, #rows do
        copied_rows[index] = copy_contribution(rows[index])
    end
    return {
        target_stat = target_stat,
        base_value = base_value,
        contributions = copied_rows,
        stages = stages,
        constraint_minimum = constraint_minimum,
        constraint_maximum = constraint_maximum,
        constraint_minimum_stable_order_key =
            set_min and set_min.stable_order_key or nil,
        constraint_maximum_stable_order_key =
            set_max and set_max.stable_order_key or nil,
        pre_hard_clamp_value = before_hard_clamp,
        final_value = value,
    }
end

function StatPipeline.calculate(request)
    local request_shape = validate_exact_fields(request, REQUEST_FIELDS, argument_failure)
    if not request_shape.ok then
        return request_shape
    end
    if not TableShape.is_integer(request.level, 1, 100) then
        return argument_failure('LEVEL_OUT_OF_RANGE', {
            field = 'level',
            minimum = 1,
            maximum = 100,
        })
    end
    if not TableShape.is_integer(request.initial_qi, 0, 2000) then
        return argument_failure('INITIAL_QI_OUT_OF_RANGE', {
            field = 'initial_qi',
            minimum = 0,
            maximum = 2000,
        })
    end
    local formula_result = validate_formula(request.formula)
    if not formula_result.ok then
        return formula_result
    end

    local primary_result = Attributes.from_definition(
        request.base_primary,
        request.growth_per_level_milli,
        request.level
    )
    if not primary_result.ok then
        return primary_result
    end
    local contribution_result = ContributionSet.prepare(
        request.contributions,
        request.context_tags
    )
    if not contribution_result.ok then
        return contribution_result
    end

    local base_stats, base_error = calculate_base_stats(
        request.level,
        primary_result.value.values,
        request.formula,
        request.initial_qi
    )
    if base_error ~= nil then
        return base_error
    end

    local rows_by_stat = {}
    local index
    for index = 1, #STAT_ORDER do
        rows_by_stat[STAT_ORDER[index]] = {}
    end
    local applicable = contribution_result.value.applicable
    for index = 1, #applicable do
        local contribution = applicable[index]
        local rows = rows_by_stat[contribution.target_stat]
        rows[#rows + 1] = contribution
    end

    local stats = {}
    local breakdown_rows = {}
    local diagnostics = {}
    for index = 1, #primary_result.value.diagnostics do
        diagnostics[#diagnostics + 1] = primary_result.value.diagnostics[index]
    end

    for index = 1, #STAT_ORDER do
        local target_stat = STAT_ORDER[index]
        local range = HARD_RANGES[target_stat]
        local hard_maximum = range[2]
        if target_stat == 'initial_qi' then
            hard_maximum = stats.max_qi
        end
        local row, row_error = evaluate_stat(
            target_stat,
            base_stats[target_stat],
            rows_by_stat[target_stat],
            range[1],
            hard_maximum
        )
        if row_error ~= nil then
            return row_error
        end
        stats[target_stat] = row.final_value
        breakdown_rows[index] = row
        if row.pre_hard_clamp_value ~= row.final_value then
            diagnostics[#diagnostics + 1] = {
                code = 'STAT_CLAMPED',
                target_stat = target_stat,
                before = row.pre_hard_clamp_value,
                after = row.final_value,
                minimum = range[1],
                maximum = hard_maximum,
            }
        end
    end

    return Result.ok({
        primary = primary_result.value.values,
        stats = stats,
        breakdown = {
            formula_id = request.formula.id,
            formula_version = request.formula.formula_version,
            context_tags = contribution_result.value.context_tags,
            stat_rows = breakdown_rows,
        },
        diagnostics = diagnostics,
        applied_contribution_count = #applicable,
        input_contribution_count = #contribution_result.value.all,
    })
end

function StatPipeline.stat_order()
    local copy = {}
    local index
    for index = 1, #STAT_ORDER do
        copy[index] = STAT_ORDER[index]
    end
    return copy
end

return StatPipeline
