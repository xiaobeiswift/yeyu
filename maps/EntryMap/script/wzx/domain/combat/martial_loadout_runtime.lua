-- Normalize CombatantSnapshot.martial_loadout into a combat-ready runtime shape.
-- Compatible with legacy `basic_attack` and preferred `basic_move` + `active_moves`.

local Ordered = require 'wzx.domain.common.ordered'
local Rules = require 'wzx.domain.combat.rules'

local MartialLoadoutRuntime = {}
local bytewise_string_less = Ordered.bytewise_string_less
local raw_get = rawget
local table_sort = table.sort
local type_value = type

local function merge_damage_spec(damage)
    local defaults = Rules.default_damage_spec()
    if type_value(damage) ~= 'table' then
        return defaults
    end
    local merged = {}
    local key
    local value
    for key, value in pairs(defaults) do
        merged[key] = value
    end
    for key, value in pairs(damage) do
        merged[key] = value
    end
    return merged
end

local function copy_optional_damage(damage, required)
    if type_value(damage) ~= 'table' then
        if required then
            return merge_damage_spec(nil)
        end
        return nil
    end
    return merge_damage_spec(damage)
end

local function normalize_move(source, default_move_type, default_move_id, require_damage)
    if type_value(source) ~= 'table' then
        return nil
    end
    local move_type = raw_get(source, 'move_type') or default_move_type
    local move_id = raw_get(source, 'move_id') or default_move_id
    if type_value(move_id) ~= 'string' or move_id == '' then
        move_id = default_move_id
    end
    local qi_cost = raw_get(source, 'qi_cost')
    if qi_cost == nil then
        qi_cost = 0
    end
    local action_cooldown = raw_get(source, 'action_cooldown')
    if action_cooldown == nil then
        action_cooldown = 0
    end
    local initial_cooldown = raw_get(source, 'initial_cooldown')
    if initial_cooldown == nil then
        initial_cooldown = 0
    end
    local effect_bundle_id = raw_get(source, 'effect_bundle_id')
    if type_value(effect_bundle_id) ~= 'string' or effect_bundle_id == '' then
        effect_bundle_id = nil
    end
    local on_hit_qi_gain = raw_get(source, 'on_hit_qi_gain')
    if on_hit_qi_gain == nil and move_type == 'BASIC' then
        on_hit_qi_gain = 10
    end
    return {
        move_id = move_id,
        qi_cost = qi_cost,
        action_cooldown = action_cooldown,
        initial_cooldown = initial_cooldown,
        damage = copy_optional_damage(raw_get(source, 'damage'), require_damage),
        effect_bundle_id = effect_bundle_id,
        move_type = move_type,
        on_hit_qi_gain = on_hit_qi_gain,
    }
end

local function default_basic_move()
    return {
        move_id = 'move_basic_auto',
        qi_cost = 0,
        action_cooldown = 0,
        initial_cooldown = 0,
        damage = Rules.default_damage_spec(),
        effect_bundle_id = nil,
        move_type = 'BASIC',
        on_hit_qi_gain = 10,
    }
end

--- Normalize a combatant martial_loadout table into runtime loadout.
-- @return { basic_move = MoveRuntime, active_moves = MoveRuntime[] }
function MartialLoadoutRuntime.normalize(loadout)
    if type_value(loadout) ~= 'table' then
        loadout = {}
    end

    local basic_source = raw_get(loadout, 'basic_move')
    if type_value(basic_source) ~= 'table' then
        basic_source = raw_get(loadout, 'basic_attack')
    end
    local basic_move = normalize_move(basic_source, 'BASIC', 'move_basic_auto', true)
    if basic_move == nil then
        basic_move = default_basic_move()
    else
        basic_move.move_type = 'BASIC'
        if basic_move.damage == nil then
            basic_move.damage = Rules.default_damage_spec()
        end
    end

    local active_moves = {}
    local active_source = raw_get(loadout, 'active_moves')
    if type_value(active_source) == 'table' then
        local index
        for index = 1, #active_source do
            local move = normalize_move(
                active_source[index],
                'ACTIVE',
                'move_active_' .. tostring(index),
                false
            )
            if move ~= nil then
                move.move_type = 'ACTIVE'
                active_moves[#active_moves + 1] = move
            end
        end
    end
    table_sort(active_moves, function(left, right)
        return bytewise_string_less(left.move_id, right.move_id)
    end)

    return {
        basic_move = basic_move,
        active_moves = active_moves,
    }
end

--- Seed actor.move_cooldowns from initial_cooldown values.
function MartialLoadoutRuntime.apply_initial_cooldowns(actor, loadout)
    if type_value(actor) ~= 'table' or type_value(loadout) ~= 'table' then
        return
    end
    local cooldowns = actor.move_cooldowns
    if type_value(cooldowns) ~= 'table' then
        cooldowns = {}
        actor.move_cooldowns = cooldowns
    end
    local basic = loadout.basic_move
    if basic ~= nil and (basic.initial_cooldown or 0) > 0 then
        cooldowns[basic.move_id] = basic.initial_cooldown
    end
    local index
    for index = 1, #(loadout.active_moves or {}) do
        local move = loadout.active_moves[index]
        if (move.initial_cooldown or 0) > 0 then
            cooldowns[move.move_id] = move.initial_cooldown
        end
    end
end

local function move_available(actor, move)
    if move == nil then
        return false
    end
    local remaining = actor.move_cooldowns[move.move_id] or 0
    if remaining > 0 then
        return false
    end
    if actor.current_qi < (move.qi_cost or 0) then
        return false
    end
    return true
end

--- AUTO action selection: first ready ACTIVE by move_id, else BASIC.
-- @return ok move table, or nil + reason
function MartialLoadoutRuntime.select_auto_move(actor)
    if type_value(actor) ~= 'table' then
        return nil, 'ACTOR_REQUIRED'
    end
    local loadout = actor.martial_loadout
    if type_value(loadout) ~= 'table' then
        return nil, 'LOADOUT_REQUIRED'
    end

    local ready_actives = {}
    local index
    for index = 1, #(loadout.active_moves or {}) do
        local move = loadout.active_moves[index]
        if move_available(actor, move) then
            ready_actives[#ready_actives + 1] = move
        end
    end
    if #ready_actives > 0 then
        table_sort(ready_actives, function(left, right)
            return bytewise_string_less(left.move_id, right.move_id)
        end)
        return ready_actives[1], nil
    end

    local basic = loadout.basic_move
    if move_available(actor, basic) then
        return basic, nil
    end
    if basic == nil then
        return nil, 'NO_MOVE'
    end
    local remaining = actor.move_cooldowns[basic.move_id] or 0
    if remaining > 0 then
        return nil, 'ON_COOLDOWN'
    end
    if actor.current_qi < (basic.qi_cost or 0) then
        return nil, 'QI_INSUFFICIENT'
    end
    return nil, 'NO_MOVE'
end

--- List all move_ids known to this loadout (for diagnostics / cooldown tick).
function MartialLoadoutRuntime.list_move_ids(loadout)
    local ids = {}
    if type_value(loadout) ~= 'table' then
        return ids
    end
    if loadout.basic_move ~= nil then
        ids[#ids + 1] = loadout.basic_move.move_id
    end
    local seen = {}
    if loadout.basic_move ~= nil then
        seen[loadout.basic_move.move_id] = true
    end
    local index
    for index = 1, #(loadout.active_moves or {}) do
        local move_id = loadout.active_moves[index].move_id
        if seen[move_id] ~= true then
            seen[move_id] = true
            ids[#ids + 1] = move_id
        end
    end
    return ids
end

return MartialLoadoutRuntime
