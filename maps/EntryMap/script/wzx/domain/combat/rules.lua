-- Frozen first-chapter combat rule set constants.

local Rules = {}

Rules.RULES_VERSION = 1
Rules.GAUGE_THRESHOLD = 1000000
Rules.ACTION_LIMIT = 99
Rules.BASE_HIT_BP = 8000
Rules.MIN_HIT_BP = 2000
Rules.MAX_HIT_BP = 9800
Rules.DEFENSE_SCALE = 20
Rules.DEFAULT_VARIANCE_MIN_BP = 9500
Rules.DEFAULT_VARIANCE_MAX_BP = 10500
Rules.MAX_CRIT_CHANCE_BP = 7500
Rules.MAX_BLOCK_CHANCE_BP = 7500
Rules.MUTUAL_DOWN_OUTCOME = 'DEFENDER_WIN'
Rules.EVENT_SCHEMA_VERSION = 1

function Rules.tie_preferred_side(seed)
    if seed % 2 == 1 then
        return 'ATTACKER'
    end
    return 'DEFENDER'
end

function Rules.default_damage_spec()
    return {
        damage_type = 'PHYSICAL',
        attack_ratio_bp = 10000,
        flat_damage = 0,
        hit_mode = 'NORMAL',
        hit_bonus_bp = 0,
        penetration_flat = 0,
        penetration_bp = 0,
        damage_bonus_bp = 0,
        variance_min_bp = 10000,
        variance_max_bp = 10000,
        can_crit = true,
        crit_bonus_bp = 0,
        crit_damage_bonus_bp = 0,
        can_block = true,
        minimum_damage = 1,
    }
end

return Rules
