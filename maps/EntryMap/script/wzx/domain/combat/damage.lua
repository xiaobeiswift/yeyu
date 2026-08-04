local Result = require 'wzx.domain.common.result'
local Rules = require 'wzx.domain.combat.rules'
local CombatErrorCodes = require 'wzx.domain.combat.error_codes'

local Damage = {}
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local type_value = type

local function fail(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err(
        CombatErrorCodes.COMBAT_ARGUMENT_INVALID,
        'error.combat.argument_invalid',
        false,
        details
    )
end

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

local function roll_bp(prng, chance_bp)
    if chance_bp <= 0 then
        return Result.ok({ success = false, consumed = false, roll = nil })
    end
    if chance_bp >= 10000 then
        return Result.ok({ success = true, consumed = false, roll = nil })
    end
    local rolled = prng:uniform(10000)
    if not rolled.ok then
        return rolled
    end
    return Result.ok({
        success = rolled.value < chance_bp,
        consumed = true,
        roll = rolled.value,
    })
end

local function roll_range_inclusive(prng, minimum, maximum)
    if minimum == maximum then
        return Result.ok({ value = minimum, consumed = false })
    end
    if maximum < minimum then
        return fail('VARIANCE_RANGE_INVALID', {
            minimum = minimum,
            maximum = maximum,
        })
    end
    local span = maximum - minimum + 1
    local rolled = prng:uniform(span)
    if not rolled.ok then
        return rolled
    end
    return Result.ok({
        value = minimum + rolled.value,
        consumed = true,
    })
end

function Damage.resolve_hit(attacker, target, spec, prng)
    if type_value(attacker) ~= 'table' or type_value(target) ~= 'table' or type_value(spec) ~= 'table' then
        return fail('DAMAGE_INPUT_REQUIRED')
    end
    if type_value(prng) ~= 'table' or type_value(prng.uniform) ~= 'function' then
        return fail('PRNG_REQUIRED')
    end

    local diagnostics = {
        hit = true,
        crit = false,
        blocked = false,
        formula_version = 1,
    }

    if spec.hit_mode ~= 'UNMISSABLE' then
        local hit_bp = clamp(
            Rules.BASE_HIT_BP
                + (attacker.accuracy or 0)
                - (target.evasion or 0)
                + (spec.hit_bonus_bp or 0),
            Rules.MIN_HIT_BP,
            Rules.MAX_HIT_BP
        )
        diagnostics.hit_bp = hit_bp
        local hit = roll_bp(prng, hit_bp)
        if not hit.ok then
            return hit
        end
        diagnostics.hit_roll = hit.value.roll
        if not hit.value.success then
            diagnostics.hit = false
            return Result.ok({
                hit = false,
                final_damage = 0,
                diagnostics = diagnostics,
            })
        end
    else
        diagnostics.hit_bp = 10000
    end

    local attack = attacker.attack or 0
    local base = math_max(
        0,
        math_floor(attack * (spec.attack_ratio_bp or 10000) / 10000) + (spec.flat_damage or 0)
    )
    diagnostics.base = base

    local final_damage = base
    if spec.damage_type ~= 'TRUE' then
        local effective_defense = math_floor(
            math_max(0, (target.defense or 0) - (spec.penetration_flat or 0))
                * (10000 - (spec.penetration_bp or 0))
                / 10000
        )
        diagnostics.effective_defense = effective_defense
        final_damage = math_floor(
            base * 10000 / (10000 + effective_defense * Rules.DEFENSE_SCALE)
        )
    end
    diagnostics.after_mitigation = final_damage

    final_damage = math_floor(
        final_damage
            * math_max(0, 10000 + (attacker.damage_bonus_bp or 0) + (spec.damage_bonus_bp or 0))
            / 10000
    )
    diagnostics.after_bonus = final_damage

    final_damage = math_floor(
        final_damage
            * math_max(0, 10000 - (target.damage_reduction_bp or 0))
            / 10000
    )
    diagnostics.after_reduction = final_damage

    local variance_min = spec.variance_min_bp
    if variance_min == nil then
        variance_min = Rules.DEFAULT_VARIANCE_MIN_BP
    end
    local variance_max = spec.variance_max_bp
    if variance_max == nil then
        variance_max = Rules.DEFAULT_VARIANCE_MAX_BP
    end
    local variance = roll_range_inclusive(prng, variance_min, variance_max)
    if not variance.ok then
        return variance
    end
    diagnostics.variance_bp = variance.value.value
    final_damage = math_floor(final_damage * variance.value.value / 10000)
    diagnostics.after_variance = final_damage

    if spec.can_crit ~= false then
        local crit_bp = clamp(
            (attacker.crit_chance_bp or 0)
                - (target.crit_resist_bp or 0)
                + (spec.crit_bonus_bp or 0),
            0,
            Rules.MAX_CRIT_CHANCE_BP
        )
        diagnostics.crit_bp = crit_bp
        local crit = roll_bp(prng, crit_bp)
        if not crit.ok then
            return crit
        end
        diagnostics.crit_roll = crit.value.roll
        if crit.value.success then
            diagnostics.crit = true
            local crit_mult = clamp(
                (attacker.crit_damage_bp or 15000) + (spec.crit_damage_bonus_bp or 0),
                10000,
                30000
            )
            diagnostics.crit_mult_bp = crit_mult
            final_damage = math_floor(final_damage * crit_mult / 10000)
        end
    end
    diagnostics.after_crit = final_damage

    if spec.can_block ~= false then
        local block_bp = clamp(target.block_chance_bp or 0, 0, Rules.MAX_BLOCK_CHANCE_BP)
        diagnostics.block_bp = block_bp
        local blocked = roll_bp(prng, block_bp)
        if not blocked.ok then
            return blocked
        end
        diagnostics.block_roll = blocked.value.roll
        if blocked.value.success then
            diagnostics.blocked = true
            local block_mult = math_max(0, 10000 - (target.block_reduction_bp or 0))
            diagnostics.block_mult_bp = block_mult
            final_damage = math_floor(final_damage * block_mult / 10000)
        end
    end
    diagnostics.after_block = final_damage

    local minimum = spec.minimum_damage
    if minimum == nil then
        minimum = 1
    end
    if base > 0 and final_damage < minimum then
        final_damage = minimum
    end
    diagnostics.final_damage = final_damage

    return Result.ok({
        hit = true,
        final_damage = final_damage,
        diagnostics = diagnostics,
    })
end

return Damage
