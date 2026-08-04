local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local EffectErrorCodes = require 'wzx.domain.effects.error_codes'

local CombatRuntime = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_floor = math.floor
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_component = RuntimeId.validate_component

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_ACTORS = 16
local MAX_STATUS_INSTANCES_PER_ACTOR = 128
local MAX_STATUS_INSTANCES_COMBAT = 512
local MAX_NODES_PER_ACTION = 2048
local MAX_NODES_PER_COMBAT = 20000
local MAX_TRIGGER_DEPTH = 16

CombatRuntime.MAX_STATUS_INSTANCES_PER_ACTOR = MAX_STATUS_INSTANCES_PER_ACTOR
CombatRuntime.MAX_STATUS_INSTANCES_COMBAT = MAX_STATUS_INSTANCES_COMBAT
CombatRuntime.MAX_NODES_PER_ACTION = MAX_NODES_PER_ACTION
CombatRuntime.MAX_NODES_PER_COMBAT = MAX_NODES_PER_COMBAT
CombatRuntime.MAX_TRIGGER_DEPTH = MAX_TRIGGER_DEPTH

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.effects.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, reason, details)
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function copy_string_map(source)
    local copied = {}
    if source == nil then
        return copied
    end
    local key
    local value
    for key, value in raw_next, source do
        if type_value(key) == 'string' and value == true then
            copied[key] = true
        end
    end
    return copied
end

local function copy_actor(actor)
    return {
        actor_id = actor.actor_id,
        side_order = actor.side_order,
        position = actor.position,
        alive = actor.alive == true,
        hp = actor.hp,
        max_hp = actor.max_hp,
        qi = actor.qi,
        max_qi = actor.max_qi,
        effect_accuracy = actor.effect_accuracy,
        effect_resistance = actor.effect_resistance,
        immunity_tags = copy_string_map(actor.immunity_tags),
        control_immunity_tags = copy_string_map(actor.control_immunity_tags),
    }
end

local function copy_status(instance)
    local magnitude = {}
    local key
    local value
    if type_value(instance.magnitude_snapshot) == 'table' then
        for key, value in raw_next, instance.magnitude_snapshot do
            magnitude[key] = value
        end
    end
    local counters = {}
    if type_value(instance.trigger_counters) == 'table' then
        for key, value in raw_next, instance.trigger_counters do
            counters[key] = value
        end
    end
    return {
        instance_id = instance.instance_id,
        status_id = instance.status_id,
        owner_actor_id = instance.owner_actor_id,
        source_actor_id = instance.source_actor_id,
        source_definition_id = instance.source_definition_id,
        stack_count = instance.stack_count,
        remaining_duration = instance.remaining_duration,
        duration_unit = instance.duration_unit,
        magnitude_snapshot = magnitude,
        application_sequence = instance.application_sequence,
        trigger_counters = counters,
        suppressed = instance.suppressed == true,
    }
end

local function validate_actor(actor, path)
    if type_value(actor) ~= 'table' or get_metatable(actor) ~= nil then
        return invalid('ACTOR_TABLE_REQUIRED', { field = path })
    end
    local actor_id = raw_get(actor, 'actor_id')
    local id_check = validate_component(actor_id, path .. '.actor_id')
    if not id_check.ok then
        return invalid('ACTOR_ID_INVALID', { field = path .. '.actor_id' })
    end
    if not is_safe_integer(raw_get(actor, 'side_order'), 0, 1) then
        return invalid('SIDE_ORDER_INVALID', { field = path .. '.side_order' })
    end
    if not is_safe_integer(raw_get(actor, 'position'), 1, 9) then
        return invalid('POSITION_INVALID', { field = path .. '.position' })
    end
    if type_value(raw_get(actor, 'alive')) ~= 'boolean' then
        return invalid('ALIVE_REQUIRED', { field = path .. '.alive' })
    end
    if not is_safe_integer(raw_get(actor, 'max_hp'), 1, MAX_SAFE_INTEGER) then
        return invalid('MAX_HP_INVALID', { field = path .. '.max_hp' })
    end
    if not is_safe_integer(raw_get(actor, 'hp'), 0, raw_get(actor, 'max_hp')) then
        return invalid('HP_INVALID', { field = path .. '.hp' })
    end
    if not is_safe_integer(raw_get(actor, 'max_qi'), 0, 9999) then
        return invalid('MAX_QI_INVALID', { field = path .. '.max_qi' })
    end
    if not is_safe_integer(raw_get(actor, 'qi'), 0, raw_get(actor, 'max_qi')) then
        return invalid('QI_INVALID', { field = path .. '.qi' })
    end
    if not is_safe_integer(raw_get(actor, 'effect_accuracy'), -10000, 10000) then
        return invalid('EFFECT_ACCURACY_INVALID', { field = path .. '.effect_accuracy' })
    end
    if not is_safe_integer(raw_get(actor, 'effect_resistance'), -10000, 10000) then
        return invalid('EFFECT_RESISTANCE_INVALID', { field = path .. '.effect_resistance' })
    end
    return result_ok(copy_actor({
        actor_id = actor_id,
        side_order = raw_get(actor, 'side_order'),
        position = raw_get(actor, 'position'),
        alive = raw_get(actor, 'alive'),
        hp = raw_get(actor, 'hp'),
        max_hp = raw_get(actor, 'max_hp'),
        qi = raw_get(actor, 'qi'),
        max_qi = raw_get(actor, 'max_qi'),
        effect_accuracy = raw_get(actor, 'effect_accuracy'),
        effect_resistance = raw_get(actor, 'effect_resistance'),
        immunity_tags = raw_get(actor, 'immunity_tags') or {},
        control_immunity_tags = raw_get(actor, 'control_immunity_tags') or {},
    }))
end

function CombatRuntime.create(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('RUNTIME_INPUT_REQUIRED')
    end
    local combat_id = raw_get(input, 'combat_id')
    local id_check = validate_component(combat_id, 'combat_id')
    if not id_check.ok then
        return invalid('COMBAT_ID_INVALID', { field = 'combat_id' })
    end
    if not is_safe_integer(raw_get(input, 'rules_version'), 1, MAX_SAFE_INTEGER) then
        return invalid('RULES_VERSION_INVALID', { field = 'rules_version' })
    end
    local actors_input = raw_get(input, 'actors')
    if type_value(actors_input) ~= 'table'
        or get_metatable(actors_input) ~= nil
        or not is_dense_array(actors_input)
        or #actors_input < 1
        or #actors_input > MAX_ACTORS
    then
        return invalid('ACTORS_REQUIRED', { field = 'actors' })
    end

    local actors = {}
    local actor_order = {}
    local index
    for index = 1, #actors_input do
        local actor_result = validate_actor(
            actors_input[index],
            'actors[' .. tostring(index) .. ']'
        )
        if not actor_result.ok then
            return actor_result
        end
        local actor = actor_result.value
        if actors[actor.actor_id] ~= nil then
            return invalid('DUPLICATE_ACTOR_ID', { actor_id = actor.actor_id })
        end
        actors[actor.actor_id] = actor
        actor_order[#actor_order + 1] = actor.actor_id
    end
    table_sort(actor_order, bytewise_string_less)

    return result_ok({
        combat_id = combat_id,
        rules_version = raw_get(input, 'rules_version'),
        revision = 0,
        sequence_cursor = 1,
        status_sequence = 0,
        action_node_count = 0,
        combat_node_count = 0,
        actors = actors,
        actor_order = actor_order,
        status_instances = {},
        mechanic_flags = {},
        duration_advanced_actions = {},
        trigger_action_counts = {},
        trigger_combat_counts = {},
    })
end

function CombatRuntime.clone(runtime)
    if type_value(runtime) ~= 'table' or get_metatable(runtime) ~= nil then
        return invalid('RUNTIME_REQUIRED')
    end
    local actors = {}
    local actor_id
    local actor
    for actor_id, actor in raw_next, runtime.actors do
        actors[actor_id] = copy_actor(actor)
    end
    local actor_order = {}
    local index
    for index = 1, #runtime.actor_order do
        actor_order[index] = runtime.actor_order[index]
    end
    local statuses = {}
    local instance_id
    local instance
    for instance_id, instance in raw_next, runtime.status_instances do
        statuses[instance_id] = copy_status(instance)
    end
    local mechanic_flags = {}
    local key
    local value
    for key, value in raw_next, runtime.mechanic_flags or {} do
        mechanic_flags[key] = value
    end
    local duration_advanced = {}
    for key, value in raw_next, runtime.duration_advanced_actions or {} do
        duration_advanced[key] = value
    end
    local trigger_action_counts = {}
    for key, value in raw_next, runtime.trigger_action_counts or {} do
        trigger_action_counts[key] = value
    end
    local trigger_combat_counts = {}
    for key, value in raw_next, runtime.trigger_combat_counts or {} do
        trigger_combat_counts[key] = value
    end
    return result_ok({
        combat_id = runtime.combat_id,
        rules_version = runtime.rules_version,
        revision = runtime.revision,
        sequence_cursor = runtime.sequence_cursor,
        status_sequence = runtime.status_sequence,
        action_node_count = runtime.action_node_count,
        combat_node_count = runtime.combat_node_count,
        actors = actors,
        actor_order = actor_order,
        status_instances = statuses,
        mechanic_flags = mechanic_flags,
        duration_advanced_actions = duration_advanced,
        trigger_action_counts = trigger_action_counts,
        trigger_combat_counts = trigger_combat_counts,
    })
end

function CombatRuntime.get_actor(runtime, actor_id)
    if type_value(runtime) ~= 'table' then
        return nil
    end
    return runtime.actors[actor_id]
end

function CombatRuntime.list_statuses(runtime)
    local rows = {}
    local instance_id
    local instance
    for instance_id, instance in raw_next, runtime.status_instances do
        rows[#rows + 1] = copy_status(instance)
    end
    table_sort(rows, function(left, right)
        if left.application_sequence ~= right.application_sequence then
            return left.application_sequence < right.application_sequence
        end
        return bytewise_string_less(left.instance_id, right.instance_id)
    end)
    return rows
end

function CombatRuntime.count_statuses(runtime)
    local count = 0
    local _
    for _ in raw_next, runtime.status_instances do
        count = count + 1
    end
    return count
end

function CombatRuntime.count_owner_statuses(runtime, owner_actor_id)
    local count = 0
    local _
    local instance
    for _, instance in raw_next, runtime.status_instances do
        if instance.owner_actor_id == owner_actor_id then
            count = count + 1
        end
    end
    return count
end

function CombatRuntime.next_status_instance_id(runtime)
    runtime.status_sequence = runtime.status_sequence + 1
    return runtime.combat_id .. ':status_' .. tostring(runtime.status_sequence)
end

function CombatRuntime.bump_revision(runtime)
    runtime.revision = runtime.revision + 1
    return runtime.revision
end

function CombatRuntime.consume_node_budget(runtime, amount)
    amount = amount or 1
    if runtime.action_node_count + amount > MAX_NODES_PER_ACTION
        or runtime.combat_node_count + amount > MAX_NODES_PER_COMBAT
    then
        return fail(EffectErrorCodes.EFFECT_BUDGET_EXCEEDED, 'NODE_BUDGET_EXCEEDED', {
            action_node_count = runtime.action_node_count,
            combat_node_count = runtime.combat_node_count,
            amount = amount,
        })
    end
    runtime.action_node_count = runtime.action_node_count + amount
    runtime.combat_node_count = runtime.combat_node_count + amount
    return result_ok(true)
end

function CombatRuntime.reset_action_node_count(runtime)
    runtime.action_node_count = 0
end

return CombatRuntime
