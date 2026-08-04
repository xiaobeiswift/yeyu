local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.encounter.validation'

local EnemyMoveSet = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'EnemyMoveSet'
local MOVE_SCHEMA = 'EnemyMoveSpec'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    basic_move = true,
    active_moves = true,
    deprecated = true,
}
local MOVE_FIELDS = {
    move_id = true,
    move_type = true,
    qi_cost = true,
    action_cooldown = true,
    initial_cooldown = true,
    on_hit_qi_gain = true,
    effect_bundle_id = true,
    damage = true,
}
local DAMAGE_FIELDS = {
    damage_type = true,
    attack_ratio_bp = true,
    flat_damage = true,
    hit_mode = true,
    variance_min_bp = true,
    variance_max_bp = true,
    can_crit = true,
    can_block = true,
    minimum_damage = true,
}
local DAMAGE_TYPES = {
    PHYSICAL = true,
    INTERNAL = true,
    TRUE = true,
}
local HIT_MODES = {
    NORMAL = true,
    UNMISSABLE = true,
}
local MOVE_TYPES = {
    BASIC = true,
    ACTIVE = true,
}

local function copy_damage(damage)
    return {
        damage_type = damage.damage_type,
        attack_ratio_bp = damage.attack_ratio_bp,
        flat_damage = damage.flat_damage,
        hit_mode = damage.hit_mode,
        variance_min_bp = damage.variance_min_bp,
        variance_max_bp = damage.variance_max_bp,
        can_crit = damage.can_crit,
        can_block = damage.can_block,
        minimum_damage = damage.minimum_damage,
    }
end

local function validate_damage(damage)
    local err = validation_no_unknown_fields(MOVE_SCHEMA, damage, DAMAGE_FIELDS)
    if err ~= nil then
        return err
    end
    return validation_first(
        validation_enum(MOVE_SCHEMA, 'damage.damage_type', damage.damage_type, DAMAGE_TYPES),
        validation_integer(MOVE_SCHEMA, 'damage.attack_ratio_bp', damage.attack_ratio_bp, 0, 50000),
        validation_integer(MOVE_SCHEMA, 'damage.flat_damage', damage.flat_damage, 0, 10000000),
        validation_enum(MOVE_SCHEMA, 'damage.hit_mode', damage.hit_mode, HIT_MODES),
        validation_integer(MOVE_SCHEMA, 'damage.variance_min_bp', damage.variance_min_bp, 1, 20000),
        validation_integer(MOVE_SCHEMA, 'damage.variance_max_bp', damage.variance_max_bp, 1, 20000),
        validation_boolean(MOVE_SCHEMA, 'damage.can_crit', damage.can_crit),
        validation_boolean(MOVE_SCHEMA, 'damage.can_block', damage.can_block),
        validation_integer(MOVE_SCHEMA, 'damage.minimum_damage', damage.minimum_damage, 0, 1000000)
    )
end

local function validate_move(move, expected_type, require_damage)
    local err = validation_no_unknown_fields(MOVE_SCHEMA, move, MOVE_FIELDS)
    if err ~= nil then
        return err
    end
    local qi_cost = raw_get(move, 'qi_cost')
    if qi_cost == nil then
        qi_cost = 0
    end
    local action_cooldown = raw_get(move, 'action_cooldown')
    if action_cooldown == nil then
        action_cooldown = 0
    end
    local initial_cooldown = raw_get(move, 'initial_cooldown')
    if initial_cooldown == nil then
        initial_cooldown = 0
    end
    local on_hit_qi_gain = raw_get(move, 'on_hit_qi_gain')
    if on_hit_qi_gain == nil then
        on_hit_qi_gain = expected_type == 'BASIC' and 5 or 0
    end
    local move_type = raw_get(move, 'move_type')
    if move_type == nil then
        move_type = expected_type
    end
    err = validation_first(
        validation_content_id(MOVE_SCHEMA, 'move_id', move.move_id, 'move_'),
        validation_enum(MOVE_SCHEMA, 'move_type', move_type, MOVE_TYPES),
        validation_integer(MOVE_SCHEMA, 'qi_cost', qi_cost, 0, 2000),
        validation_integer(MOVE_SCHEMA, 'action_cooldown', action_cooldown, 0, 99),
        validation_integer(MOVE_SCHEMA, 'initial_cooldown', initial_cooldown, 0, 99),
        validation_integer(MOVE_SCHEMA, 'on_hit_qi_gain', on_hit_qi_gain, 0, 2000),
        validation_content_id(
            MOVE_SCHEMA,
            'effect_bundle_id',
            move.effect_bundle_id,
            'effect_',
            true
        )
    )
    if err ~= nil then
        return err
    end
    if move_type ~= expected_type then
        return validation_invalid(MOVE_SCHEMA, 'move_type', 'MOVE_TYPE_MISMATCH', {
            expected = expected_type,
        })
    end
    if require_damage then
        if type_value(move.damage) ~= 'table' then
            return validation_invalid(MOVE_SCHEMA, 'damage', 'TABLE_REQUIRED')
        end
        err = validate_damage(move.damage)
        if err ~= nil then
            return err
        end
        if move.damage.variance_min_bp > move.damage.variance_max_bp then
            return validation_invalid(MOVE_SCHEMA, 'damage.variance_max_bp', 'VARIANCE_RANGE_INVALID')
        end
    elseif move.damage ~= nil then
        err = validate_damage(move.damage)
        if err ~= nil then
            return err
        end
    end
    return result_ok({
        move_id = move.move_id,
        move_type = move_type,
        qi_cost = qi_cost,
        action_cooldown = action_cooldown,
        initial_cooldown = initial_cooldown,
        on_hit_qi_gain = on_hit_qi_gain,
        effect_bundle_id = move.effect_bundle_id,
        damage = move.damage ~= nil and copy_damage(move.damage) or nil,
    })
end

function EnemyMoveSet.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local active_moves = raw_get(value, 'active_moves')
    if active_moves == nil then
        active_moves = {}
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', value.id, 'moveset_'),
        validation_integer(SCHEMA, 'schema_version', value.schema_version, 1),
        validation_integer(SCHEMA, 'rules_version', value.rules_version, 1),
        validation_boolean(SCHEMA, 'deprecated', deprecated),
        validation_dense_array(SCHEMA, 'active_moves', active_moves)
    )
    if err ~= nil then
        return err
    end
    if #active_moves > 8 then
        return validation_invalid(SCHEMA, 'active_moves', 'ACTIVE_MOVE_LIMIT', {
            maximum = 8,
        })
    end

    local basic = validate_move(value.basic_move, 'BASIC', true)
    if not basic.ok then
        return basic
    end

    local copied_active = {}
    local seen = {}
    seen[basic.value.move_id] = true
    local index
    for index = 1, #active_moves do
        local active = validate_move(active_moves[index], 'ACTIVE', false)
        if not active.ok then
            return active
        end
        if seen[active.value.move_id] then
            return validation_invalid(SCHEMA, 'active_moves', 'DUPLICATE_MOVE_ID', {
                index = index,
                move_id = active.value.move_id,
            })
        end
        seen[active.value.move_id] = true
        copied_active[index] = active.value
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        basic_move = basic.value,
        active_moves = copied_active,
        deprecated = deprecated,
    })
end

return EnemyMoveSet
