local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Codec = require 'wzx.domain.common.canonical_value_codec_v1'
local Sha256 = require 'wzx.domain.common.sha256'
local StatPipeline = require 'wzx.domain.character.stat_pipeline'
local CombatantSnapshot = require 'wzx.domain.contracts.combatant_snapshot'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local EnemyBuilder = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local RANK_STATS = {
    'max_hp',
    'attack',
    'defense',
}

local SOURCE_HASH_SPECS = {
    { name = 'enemy_id', type = Codec.TYPE_STRING },
    { name = 'level', type = Codec.TYPE_INTEGER },
    { name = 'enemy_class', type = Codec.TYPE_STRING },
    { name = 'stat_profile_id', type = Codec.TYPE_STRING },
    { name = 'move_set_id', type = Codec.TYPE_STRING },
    { name = 'rules_version', type = Codec.TYPE_INTEGER },
    { name = 'build_variant_id', type = Codec.TYPE_STRING },
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.encounter.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID, reason, details)
end

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

local function copy_move(move)
    local copied = {
        move_id = move.move_id,
        move_type = move.move_type,
        qi_cost = move.qi_cost,
        action_cooldown = move.action_cooldown,
        initial_cooldown = move.initial_cooldown,
        on_hit_qi_gain = move.on_hit_qi_gain,
        effect_bundle_id = move.effect_bundle_id,
    }
    if move.damage ~= nil then
        copied.damage = {
            damage_type = move.damage.damage_type,
            attack_ratio_bp = move.damage.attack_ratio_bp,
            flat_damage = move.damage.flat_damage,
            hit_mode = move.damage.hit_mode,
            variance_min_bp = move.damage.variance_min_bp,
            variance_max_bp = move.damage.variance_max_bp,
            can_crit = move.damage.can_crit,
            can_block = move.damage.can_block,
            minimum_damage = move.damage.minimum_damage,
        }
    end
    return copied
end

local function build_martial_loadout(move_set)
    local active = {}
    local index
    for index = 1, #move_set.active_moves do
        active[index] = copy_move(move_set.active_moves[index])
    end
    return {
        basic_move = copy_move(move_set.basic_move),
        active_moves = active,
    }
end

local function append_rank_contributions(contributions, enemy, profile)
    local multiplier = profile.rank_multiplier_bp[enemy.enemy_class]
    if multiplier == nil then
        return fail(
            EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
            'RANK_MULTIPLIER_MISSING',
            { enemy_class = enemy.enemy_class }
        )
    end
    if multiplier == 10000 then
        return result_ok(contributions)
    end
    local index
    for index = 1, #RANK_STATS do
        local target_stat = RANK_STATS[index]
        contributions[#contributions + 1] = {
            source_type = 'ENCOUNTER',
            source_id = enemy.id .. ':rank:' .. enemy.enemy_class,
            target_stat = target_stat,
            operation = 'MULTIPLY_BP',
            value = multiplier,
            priority = 100,
            condition_tags = {},
            stable_order_key = enemy.id .. ':rank:' .. target_stat,
        }
    end
    return result_ok(contributions)
end

local function compute_source_hash(values)
    local encoded = Codec.encode('enemy_build_v1', SOURCE_HASH_SPECS, values)
    if not encoded.ok then
        return encoded
    end
    local digest, hash_error = Sha256.hex(encoded.value)
    if digest == nil then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'SOURCE_HASH_FAILED',
            { reason = hash_error }
        )
    end
    return result_ok(digest)
end

--- Build a DEFENDER CombatantSnapshot from catalog authority.
-- @param catalog sealed EncounterCatalog
-- @param input {
--   enemy_id, level, actor_id, position_index,
--   initial_status_ids?, build_variant_id?, source_revision?,
--   side? (default DEFENDER)
-- }
function EnemyBuilder.build_combatant(catalog, input)
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_enemy) ~= 'function'
    then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local enemy_id = raw_get(input, 'enemy_id')
    local level = raw_get(input, 'level')
    local actor_id = raw_get(input, 'actor_id')
    local position_index = raw_get(input, 'position_index')
    local side = raw_get(input, 'side') or 'DEFENDER'
    local initial_status_ids = raw_get(input, 'initial_status_ids') or {}
    local build_variant_id = raw_get(input, 'build_variant_id')
    local source_revision = raw_get(input, 'source_revision')
    if source_revision == nil then
        source_revision = 1
    end

    local actor_check = RuntimeId.validate_derived(actor_id, 'actor_id')
    if not actor_check.ok then
        return invalid('ACTOR_ID_INVALID', { field = 'actor_id' })
    end
    if type_value(level) ~= 'number' or level < 1 or level > 100 or level ~= math.floor(level) then
        return invalid('LEVEL_OUT_OF_RANGE', { level = level })
    end
    if type_value(position_index) ~= 'number'
        or position_index < 0
        or position_index > 8
        or position_index ~= math.floor(position_index)
    then
        return invalid('POSITION_OUT_OF_RANGE', { position_index = position_index })
    end
    if side ~= 'DEFENDER' and side ~= 'ATTACKER' then
        return invalid('SIDE_INVALID', { side = side })
    end
    if type_value(initial_status_ids) ~= 'table' or get_metatable(initial_status_ids) ~= nil then
        return invalid('INITIAL_STATUS_IDS_INVALID')
    end

    local enemy = catalog:require_enemy(enemy_id)
    if not enemy.ok then
        return enemy
    end
    enemy = enemy.value
    if enemy.deprecated then
        return fail(
            EncounterErrorCodes.ENCOUNTER_DEPRECATED,
            'ENEMY_DEPRECATED',
            { enemy_id = enemy_id }
        )
    end

    local profile = catalog:require_stat_profile(enemy.stat_profile_id)
    if not profile.ok then
        return profile
    end
    profile = profile.value
    if level < profile.level_min or level > profile.level_max then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'LEVEL_OUT_OF_PROFILE_RANGE',
            {
                enemy_id = enemy_id,
                level = level,
                level_min = profile.level_min,
                level_max = profile.level_max,
            }
        )
    end

    local move_set = catalog:require_move_set(enemy.move_set_id)
    if not move_set.ok then
        return move_set
    end
    move_set = move_set.value

    local contributions = {}
    local index
    for index = 1, #profile.flat_combat_contributions do
        local source = profile.flat_combat_contributions[index]
        contributions[#contributions + 1] = {
            source_type = source.source_type,
            source_id = source.source_id,
            target_stat = source.target_stat,
            operation = source.operation,
            value = source.value,
            priority = source.priority,
            condition_tags = copy_strings(source.condition_tags),
            stable_order_key = source.stable_order_key,
        }
    end
    local ranked = append_rank_contributions(contributions, enemy, profile)
    if not ranked.ok then
        return ranked
    end

    local calculated = StatPipeline.calculate({
        level = level,
        base_primary = profile.base_primary,
        growth_per_level_milli = profile.growth_per_level_milli,
        formula = profile.formula,
        initial_qi = profile.initial_qi,
        contributions = contributions,
        context_tags = {},
    })
    if not calculated.ok then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'STAT_PIPELINE_FAILED',
            {
                enemy_id = enemy_id,
                cause_code = calculated.error and calculated.error.code or 'UNKNOWN',
            }
        )
    end

    local variant_token = build_variant_id
    if variant_token == nil or variant_token == '' then
        variant_token = 'none'
    end
    local source_hash = compute_source_hash({
        enemy_id = enemy.id,
        level = level,
        enemy_class = enemy.enemy_class,
        stat_profile_id = enemy.stat_profile_id,
        move_set_id = enemy.move_set_id,
        rules_version = enemy.rules_version,
        build_variant_id = variant_token,
    })
    if not source_hash.ok then
        return source_hash
    end

    local member = {
        actor_id = actor_id,
        definition_id = enemy.id,
        side = side,
        position_index = position_index,
        level = level,
        tags = copy_strings(enemy.default_tags),
        stats = calculated.value.stats,
        martial_loadout = build_martial_loadout(move_set),
        initial_status_ids = copy_strings(initial_status_ids),
        ai_profile_id = enemy.ai_profile_id,
        source_revision = source_revision,
        source_hash = source_hash.value,
    }

    local validated = CombatantSnapshot.validate(member, side)
    if not validated.ok then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'COMBATANT_SNAPSHOT_INVALID',
            {
                enemy_id = enemy_id,
                cause_code = validated.error and validated.error.code or 'UNKNOWN',
            }
        )
    end

    return result_ok({
        combatant = member,
        enemy = enemy,
        primary = calculated.value.primary,
        diagnostics = calculated.value.diagnostics,
    })
end

--- Build defender formation members for one wave.
-- Members are sorted by position_index ascending for CombatSnapshot.
function EnemyBuilder.build_wave_defenders(catalog, wave, options)
    options = options or {}
    if type_value(wave) ~= 'table' or get_metatable(wave) ~= nil then
        return invalid('WAVE_REQUIRED')
    end
    local run_id = raw_get(options, 'run_id') or 'run'
    local run_check = RuntimeId.validate_derived(run_id, 'run_id')
    if not run_check.ok then
        return invalid('RUN_ID_INVALID')
    end

    local rows = {}
    local index
    for index = 1, #wave.spawn_rows do
        rows[index] = wave.spawn_rows[index]
    end
    table.sort(rows, function(left, right)
        if left.position_index ~= right.position_index then
            return left.position_index < right.position_index
        end
        return left.spawn_order < right.spawn_order
    end)

    local members = {}
    for index = 1, #rows do
        local row = rows[index]
        local actor_id = run_id .. ':' .. row.spawn_id
        local built = EnemyBuilder.build_combatant(catalog, {
            enemy_id = row.enemy_id,
            level = row.level,
            actor_id = actor_id,
            position_index = row.position_index,
            initial_status_ids = row.initial_status_ids,
            build_variant_id = row.build_variant_id,
            source_revision = options.source_revision or 1,
            side = 'DEFENDER',
        })
        if not built.ok then
            return built
        end
        members[#members + 1] = built.value.combatant
    end

    return result_ok({
        members = members,
        wave_id = wave.id,
        wave_index = wave.wave_index,
    })
end

return EnemyBuilder
