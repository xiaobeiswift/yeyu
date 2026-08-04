local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local CombatRuntime = require 'wzx.domain.effects.combat_runtime'
local StatusCollection = require 'wzx.domain.effects.status_collection'
local EffectErrorCodes = require 'wzx.domain.effects.error_codes'

local EffectExecutor = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type

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

local function emit(events, event_type, payload)
    events[#events + 1] = {
        event_type = event_type,
        payload = payload,
    }
end

local function clamp_bp(value)
    if value < 0 then
        return 0
    end
    if value > 10000 then
        return 10000
    end
    return value
end

local function evaluate_condition(condition, runtime, catalog, target_id)
    if condition == nil then
        return result_ok(true)
    end
    local op = condition.op
    local actor = CombatRuntime.get_actor(runtime, target_id)
    if actor == nil then
        return result_ok(false)
    end
    if op == 'ALWAYS' then
        return result_ok(true)
    end
    if op == 'TARGET_ALIVE' then
        return result_ok(actor.alive == true)
    end
    if op == 'TARGET_DOWNED' then
        return result_ok(actor.alive ~= true)
    end
    if op == 'HAS_STATUS' then
        local min_stacks = condition.min_stacks or 1
        return result_ok(
            StatusCollection.owner_has_status(runtime, target_id, condition.status_id, min_stacks)
        )
    end
    if op == 'HAS_TAG' then
        return result_ok(
            StatusCollection.owner_has_tag(runtime, catalog, target_id, condition.tag)
        )
    end
    if op == 'ALL' or op == 'ANY' or op == 'NONE' then
        local children = condition.children or {}
        local index
        local true_count = 0
        for index = 1, #children do
            local child = evaluate_condition(children[index], runtime, catalog, target_id)
            if not child.ok then
                return child
            end
            if child.value then
                true_count = true_count + 1
            end
        end
        if op == 'ALL' then
            return result_ok(true_count == #children)
        end
        if op == 'ANY' then
            return result_ok(true_count > 0)
        end
        return result_ok(true_count == 0)
    end
    return fail(EffectErrorCodes.EFFECT_CONDITION_INVALID, 'UNKNOWN_CONDITION_OP', {
        op = op,
    })
end

local function roll_chance(prng, chance_bp)
    if chance_bp == 0 then
        return result_ok({ success = false, consumed = false, roll = nil })
    end
    if chance_bp == 10000 then
        return result_ok({ success = true, consumed = false, roll = nil })
    end
    local rolled = prng:uniform(10000)
    if not rolled.ok then
        return rolled
    end
    return result_ok({
        success = rolled.value < chance_bp,
        consumed = true,
        roll = rolled.value,
    })
end

local function resolve_targets(runtime, context, node, bundle)
    local ids = context.primary_target_ids
    if node.target_rule_id == nil then
        local copied = {}
        local index
        for index = 1, #ids do
            copied[index] = ids[index]
        end
        return result_ok(copied)
    end
    -- Offline slice: only inherit primary targets. Full target rules belong to combat 06.
    local copied = {}
    local index
    for index = 1, #ids do
        copied[index] = ids[index]
    end
    return result_ok(copied)
end

local function apply_damage(runtime, catalog, source_actor_id, target_id, amount, events)
    local actor = CombatRuntime.get_actor(runtime, target_id)
    if actor == nil then
        return fail(EffectErrorCodes.EFFECT_TARGET_INVALID, 'TARGET_NOT_FOUND', {
            target_id = target_id,
        })
    end
    if not actor.alive then
        return result_ok({ applied = false, reason = 'TARGET_DOWNED' })
    end
    emit(events, 'DamageRequested', {
        source_actor_id = source_actor_id,
        target_id = target_id,
        amount = amount,
    })
    local absorb = StatusCollection.absorb_damage(runtime, catalog, target_id, amount, events)
    if not absorb.ok then
        return absorb
    end
    local remaining = absorb.value.remaining_damage
    local old_hp = actor.hp
    local new_hp = math_max(0, old_hp - remaining)
    actor.hp = new_hp
    local hp_damage = old_hp - new_hp
    if new_hp == 0 then
        actor.alive = false
    end
    emit(events, 'DamageApplied', {
        source_actor_id = source_actor_id,
        target_id = target_id,
        requested = amount,
        shield_absorbed = absorb.value.absorbed,
        hp_damage = hp_damage,
        old_hp = old_hp,
        new_hp = new_hp,
        downed = actor.alive ~= true,
    })
    CombatRuntime.bump_revision(runtime)
    return result_ok({ applied = true })
end

local function apply_heal(runtime, target_id, amount, events)
    local actor = CombatRuntime.get_actor(runtime, target_id)
    if actor == nil then
        return fail(EffectErrorCodes.EFFECT_TARGET_INVALID, 'TARGET_NOT_FOUND', {
            target_id = target_id,
        })
    end
    if not actor.alive then
        return result_ok({ applied = false, reason = 'TARGET_DOWNED' })
    end
    local old_hp = actor.hp
    local new_hp = math_min(actor.max_hp, old_hp + amount)
    local healed = new_hp - old_hp
    local overflow = amount - healed
    actor.hp = new_hp
    emit(events, 'HealingApplied', {
        target_id = target_id,
        requested = amount,
        healed = healed,
        overflow = overflow,
        old_hp = old_hp,
        new_hp = new_hp,
    })
    CombatRuntime.bump_revision(runtime)
    return result_ok({ applied = true })
end

local function apply_qi(runtime, target_id, delta, events)
    local actor = CombatRuntime.get_actor(runtime, target_id)
    if actor == nil then
        return fail(EffectErrorCodes.EFFECT_TARGET_INVALID, 'TARGET_NOT_FOUND', {
            target_id = target_id,
        })
    end
    local old_qi = actor.qi
    local new_qi = old_qi + delta
    if new_qi < 0 then
        new_qi = 0
    end
    if new_qi > actor.max_qi then
        new_qi = actor.max_qi
    end
    actor.qi = new_qi
    emit(events, 'QiChanged', {
        target_id = target_id,
        old_qi = old_qi,
        new_qi = new_qi,
        delta = new_qi - old_qi,
    })
    CombatRuntime.bump_revision(runtime)
    return result_ok({ applied = true })
end

local function execute_node_on_target(
    runtime,
    catalog,
    context,
    node,
    target_id,
    prng,
    events,
    requests
)
    local actor = CombatRuntime.get_actor(runtime, target_id)
    if actor == nil then
        return fail(EffectErrorCodes.EFFECT_TARGET_INVALID, 'TARGET_NOT_FOUND', {
            target_id = target_id,
        })
    end
    if not actor.alive and node.dead_target_policy == 'SKIP' then
        if node.operation ~= 'REVIVE' then
            emit(events, 'EffectNodeSkipped', {
                node_id = node.node_id,
                target_id = target_id,
                reason = 'INVALIDATED',
            })
            return result_ok({ ok = true, stopped = false })
        end
    end

    local condition = evaluate_condition(node.condition, runtime, catalog, target_id)
    if not condition.ok then
        return condition
    end
    if not condition.value then
        emit(events, 'EffectNodeSkipped', {
            node_id = node.node_id,
            target_id = target_id,
            reason = 'CONDITION',
        })
        return result_ok({ ok = true, stopped = false })
    end

    local chance = roll_chance(prng, node.chance_bp)
    if not chance.ok then
        return chance
    end
    if not chance.value.success then
        emit(events, 'EffectNodeSkipped', {
            node_id = node.node_id,
            target_id = target_id,
            reason = 'CHANCE',
            roll = chance.value.roll,
        })
        return result_ok({ ok = true, stopped = false })
    end

    local budget = CombatRuntime.consume_node_budget(runtime, 1)
    if not budget.ok then
        emit(events, 'EffectBudgetExceeded', {
            budget_type = 'NODE',
            action_node_count = runtime.action_node_count,
            combat_node_count = runtime.combat_node_count,
            node_id = node.node_id,
        })
        return budget
    end

    local operation = node.operation
    local op_result
    if operation == 'DEAL_DAMAGE' then
        op_result = apply_damage(
            runtime,
            catalog,
            context.source_actor_id,
            target_id,
            node.fixed_magnitude,
            events
        )
    elseif operation == 'HEAL' then
        op_result = apply_heal(runtime, target_id, node.fixed_magnitude, events)
    elseif operation == 'MODIFY_QI' then
        op_result = apply_qi(runtime, target_id, node.fixed_magnitude, events)
    elseif operation == 'APPLY_STATUS' or operation == 'ADD_SHIELD' then
        local definition_result = catalog:require_status(node.status_id)
        if not definition_result.ok then
            return definition_result
        end
        local definition = definition_result.value
        local consumed_rng = false
        if definition.requires_hit_roll then
            local source = CombatRuntime.get_actor(runtime, context.source_actor_id)
            local accuracy = source and source.effect_accuracy or 0
            local resistance = actor.effect_resistance or 0
            local final_bp = clamp_bp(
                definition.base_hit_chance_bp + accuracy - resistance
            )
            local hit = roll_chance(prng, final_bp)
            if not hit.ok then
                return hit
            end
            consumed_rng = hit.value.consumed
            if not hit.value.success then
                emit(events, 'StatusApplicationRejected', {
                    status_id = definition.id,
                    owner_actor_id = target_id,
                    reason = 'RESISTED',
                    consumed_rng = consumed_rng,
                    roll = hit.value.roll,
                })
                return result_ok({ ok = true, stopped = false })
            end
        end
        op_result = StatusCollection.apply(runtime, definition, {
            owner_actor_id = target_id,
            source_actor_id = context.source_actor_id,
            source_definition_id = context.source_definition_id,
            stacks = node.stacks,
            duration_override = node.duration_override,
            fixed_magnitude = node.fixed_magnitude,
            consumed_rng = consumed_rng,
        }, events)
    elseif operation == 'REMOVE_STATUS' then
        op_result = StatusCollection.remove(runtime, catalog, {
            owner_actor_id = target_id,
            status_id = node.status_id,
            reason = 'DISPELLED',
        }, events)
    elseif operation == 'DISPEL' then
        op_result = StatusCollection.remove(runtime, catalog, {
            owner_actor_id = target_id,
            dispel_category = node.dispel_category,
            polarity_filter = node.polarity_filter,
            count = node.dispel_count,
            reason = 'DISPELLED',
        }, events)
    elseif operation == 'MOVE_POSITION' then
        requests.moves[#requests.moves + 1] = {
            source_actor_id = context.source_actor_id,
            target_id = target_id,
            magnitude = node.fixed_magnitude,
        }
        emit(events, 'PositionMoveRequested', {
            source_actor_id = context.source_actor_id,
            target_id = target_id,
            magnitude = node.fixed_magnitude,
        })
        op_result = result_ok({ applied = true })
    elseif operation == 'SUMMON' then
        requests.summons[#requests.summons + 1] = {
            source_actor_id = context.source_actor_id,
            target_id = target_id,
            magnitude = node.fixed_magnitude,
        }
        emit(events, 'SummonRequested', {
            source_actor_id = context.source_actor_id,
            target_id = target_id,
        })
        op_result = result_ok({ applied = true })
    elseif operation == 'SET_MECHANIC_FLAG' then
        runtime.mechanic_flags[node.mechanic_key] = node.mechanic_value
        emit(events, 'MechanicSignalEmitted', {
            signal_id = 'mechanic:' .. node.mechanic_key,
            mechanic_key = node.mechanic_key,
            mechanic_value = node.mechanic_value,
        })
        CombatRuntime.bump_revision(runtime)
        op_result = result_ok({ applied = true })
    elseif operation == 'EMIT_SIGNAL' then
        requests.signals[#requests.signals + 1] = {
            signal_id = node.signal_id,
            source_actor_id = context.source_actor_id,
            target_id = target_id,
        }
        emit(events, 'MechanicSignalEmitted', {
            signal_id = node.signal_id,
            source_actor_id = context.source_actor_id,
            target_id = target_id,
        })
        op_result = result_ok({ applied = true })
    elseif operation == 'REVIVE' then
        return fail(EffectErrorCodes.EFFECT_OPERATION_UNSUPPORTED, 'REVIVE_DISABLED', {
            node_id = node.node_id,
        })
    else
        return fail(EffectErrorCodes.EFFECT_OPERATION_UNSUPPORTED, 'UNKNOWN_OPERATION', {
            operation = operation,
        })
    end

    if not op_result.ok then
        if node.failure_policy == 'REQUIRE_SUCCESS' then
            return op_result
        end
        if node.failure_policy == 'STOP_BUNDLE' then
            return result_ok({ ok = false, stopped = true, error = op_result.error })
        end
        return result_ok({ ok = true, stopped = false })
    end
    return result_ok({ ok = true, stopped = false })
end

local function collect_status_triggers(runtime, catalog, hook, owner_actor_id, trigger_depth, from_triggered)
    local tasks = {}
    local statuses = CombatRuntime.list_statuses(runtime)
    local index
    for index = 1, #statuses do
        local instance = statuses[index]
        if owner_actor_id == nil or instance.owner_actor_id == owner_actor_id then
            if not instance.suppressed then
                local triggers = catalog:list_triggers_for_status(instance.status_id)
                if triggers.ok then
                    local trigger_index
                    for trigger_index = 1, #triggers.value do
                        local trigger = triggers.value[trigger_index]
                        if trigger.hook == hook then
                            if from_triggered and not trigger.can_trigger_from_triggered_effect then
                                -- skip
                            else
                                local actor = CombatRuntime.get_actor(runtime, instance.owner_actor_id)
                                if actor ~= nil then
                                    local action_key = trigger.id .. ':' .. tostring(runtime.action_node_count)
                                    local combat_key = trigger.id
                                    local action_count = runtime.trigger_action_counts[trigger.id] or 0
                                    local combat_count = runtime.trigger_combat_counts[trigger.id] or 0
                                    if action_count < trigger.limit_per_action
                                        and combat_count < trigger.limit_per_combat
                                    then
                                        tasks[#tasks + 1] = {
                                            priority = trigger.priority,
                                            side_order = actor.side_order,
                                            position = actor.position,
                                            owner_actor_id = instance.owner_actor_id,
                                            application_sequence = instance.application_sequence,
                                            trigger_id = trigger.id,
                                            effect_bundle_id = trigger.effect_bundle_id,
                                            source_actor_id = instance.source_actor_id,
                                            source_definition_id = instance.status_id,
                                            primary_target_ids = { instance.owner_actor_id },
                                            trigger_depth = trigger_depth + 1,
                                            consume_stack = trigger.consume_stack,
                                            instance_id = instance.instance_id,
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table_sort(tasks, function(left, right)
        if left.priority ~= right.priority then
            return left.priority > right.priority
        end
        if left.side_order ~= right.side_order then
            return left.side_order < right.side_order
        end
        if left.position ~= right.position then
            return left.position < right.position
        end
        if left.owner_actor_id ~= right.owner_actor_id then
            return bytewise_string_less(left.owner_actor_id, right.owner_actor_id)
        end
        if left.application_sequence ~= right.application_sequence then
            return left.application_sequence < right.application_sequence
        end
        return bytewise_string_less(left.trigger_id, right.trigger_id)
    end)
    return tasks
end

local function validate_context(context)
    if type_value(context) ~= 'table' or get_metatable(context) ~= nil then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'CONTEXT_REQUIRED')
    end
    if type_value(context.source_definition_id) ~= 'string' or context.source_definition_id == '' then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'SOURCE_DEFINITION_REQUIRED')
    end
    if type_value(context.primary_target_ids) ~= 'table'
        or get_metatable(context.primary_target_ids) ~= nil
        or not is_dense_array(context.primary_target_ids)
        or #context.primary_target_ids < 1
    then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'PRIMARY_TARGETS_REQUIRED')
    end
    if type_value(context.action_index) ~= 'number'
        or context.action_index ~= math_floor(context.action_index)
        or context.action_index < 0
        or context.action_index > 99
    then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'ACTION_INDEX_INVALID')
    end
    local trigger_depth = context.trigger_depth or 0
    if type_value(trigger_depth) ~= 'number'
        or trigger_depth ~= math_floor(trigger_depth)
        or trigger_depth < 0
        or trigger_depth > CombatRuntime.MAX_TRIGGER_DEPTH
    then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'TRIGGER_DEPTH_INVALID')
    end
    return result_ok(true)
end

function EffectExecutor.resolve_bundle(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'INPUT_REQUIRED')
    end
    local catalog = raw_get(input, 'catalog')
    local runtime = raw_get(input, 'runtime')
    local context = raw_get(input, 'context')
    local bundle_id = raw_get(input, 'bundle_id')
    local prng = raw_get(input, 'prng')

    if catalog == nil or type_value(catalog.require_bundle) ~= 'function' then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'CATALOG_REQUIRED')
    end
    if type_value(runtime) ~= 'table' then
        return fail(EffectErrorCodes.EFFECT_RUNTIME_INVALID, 'RUNTIME_REQUIRED')
    end
    if type_value(prng) ~= 'table' or type_value(prng.uniform) ~= 'function' then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'PRNG_REQUIRED')
    end
    local context_check = validate_context(context)
    if not context_check.ok then
        return context_check
    end
    if context.rules_version ~= nil and context.rules_version ~= runtime.rules_version then
        return fail(EffectErrorCodes.EFFECT_REVISION_CONFLICT, 'RULES_VERSION_MISMATCH', {
            expected = runtime.rules_version,
            actual = context.rules_version,
        })
    end
    if (context.trigger_depth or 0) > CombatRuntime.MAX_TRIGGER_DEPTH then
        return fail(EffectErrorCodes.EFFECT_BUDGET_EXCEEDED, 'TRIGGER_DEPTH_EXCEEDED', {
            trigger_depth = context.trigger_depth,
        })
    end

    local cloned = CombatRuntime.clone(runtime)
    if not cloned.ok then
        return cloned
    end
    runtime = cloned.value

    local prng_start = prng.draw_count or 0
    local events = {}
    local requests = {
        moves = {},
        summons = {},
        signals = {},
    }

    local queue = {
        {
            bundle_id = bundle_id,
            context = context,
            from_triggered = (context.trigger_depth or 0) > 0,
        },
    }

    while #queue > 0 do
        local task = table.remove(queue, 1)
        if task.context.trigger_depth > CombatRuntime.MAX_TRIGGER_DEPTH then
            emit(events, 'EffectBudgetExceeded', {
                budget_type = 'TRIGGER_DEPTH',
                trigger_depth = task.context.trigger_depth,
            })
            return fail(EffectErrorCodes.EFFECT_BUDGET_EXCEEDED, 'TRIGGER_DEPTH_EXCEEDED', {
                trigger_depth = task.context.trigger_depth,
            })
        end

        local bundle_result = catalog:require_bundle(task.bundle_id)
        if not bundle_result.ok then
            return bundle_result
        end
        local bundle = bundle_result.value
        if bundle.deprecated then
            return fail(EffectErrorCodes.EFFECT_CONFIG_MISSING, 'BUNDLE_DEPRECATED', {
                bundle_id = task.bundle_id,
            })
        end

        if bundle.requires_source_alive and task.context.source_actor_id ~= nil then
            local source = CombatRuntime.get_actor(runtime, task.context.source_actor_id)
            if source == nil or not source.alive then
                emit(events, 'EffectNodeSkipped', {
                    node_id = '*',
                    reason = 'SOURCE_DOWNED',
                    bundle_id = task.bundle_id,
                })
            else
                -- continue below
            end
        end

        local source_blocked = false
        if bundle.requires_source_alive and task.context.source_actor_id ~= nil then
            local source = CombatRuntime.get_actor(runtime, task.context.source_actor_id)
            if source == nil or not source.alive then
                source_blocked = true
            end
        end

        if not source_blocked then
            emit(events, 'EffectBundleStarted', {
                bundle_id = task.bundle_id,
                source_actor_id = task.context.source_actor_id,
                source_definition_id = task.context.source_definition_id,
                primary_target_ids = task.context.primary_target_ids,
                trigger_depth = task.context.trigger_depth or 0,
            })

            local node_results = {}
            local stop_bundle = false
            local bundle_chance_success = true
            if bundle.chance_scope == 'BUNDLE' then
                -- Use first node chance as package gate when scope is bundle-level.
                local first_chance = 10000
                if #bundle.nodes > 0 then
                    first_chance = bundle.nodes[1].chance_bp
                end
                local package_roll = roll_chance(prng, first_chance)
                if not package_roll.ok then
                    return package_roll
                end
                bundle_chance_success = package_roll.value.success
                if not bundle_chance_success then
                    emit(events, 'EffectNodeSkipped', {
                        node_id = '*',
                        reason = 'CHANCE',
                        scope = 'BUNDLE',
                        roll = package_roll.value.roll,
                    })
                end
            end

            if bundle_chance_success then
                local snapshot_targets = nil
                if bundle.target_snapshot_policy == 'AT_START' then
                    local resolved = resolve_targets(runtime, task.context, { target_rule_id = nil }, bundle)
                    if not resolved.ok then
                        return resolved
                    end
                    snapshot_targets = resolved.value
                end

                local node_index
                for node_index = 1, #bundle.nodes do
                    if stop_bundle then
                        break
                    end
                    local node = bundle.nodes[node_index]
                    local targets
                    if snapshot_targets ~= nil then
                        targets = snapshot_targets
                    else
                        local resolved = resolve_targets(runtime, task.context, node, bundle)
                        if not resolved.ok then
                            return resolved
                        end
                        targets = resolved.value
                    end

                    local effective_node = node
                    if bundle.chance_scope == 'BUNDLE' then
                        effective_node = {}
                        local key
                        local value
                        for key, value in pairs(node) do
                            effective_node[key] = value
                        end
                        effective_node.chance_bp = 10000
                    end

                    local target_index
                    for target_index = 1, #targets do
                        local target_id = targets[target_index]
                        local node_result = execute_node_on_target(
                            runtime,
                            catalog,
                            task.context,
                            effective_node,
                            target_id,
                            prng,
                            events,
                            requests
                        )
                        if not node_result.ok then
                            return node_result
                        end
                        node_results[#node_results + 1] = {
                            node_id = node.node_id,
                            target_id = target_id,
                        }
                        if node_result.value.stopped then
                            stop_bundle = true
                            break
                        end
                        if node.failure_policy == 'STOP_BUNDLE' and node_result.value.ok == false then
                            stop_bundle = true
                            break
                        end
                    end
                end
            end

            emit(events, 'EffectBundleFinished', {
                bundle_id = task.bundle_id,
                node_result_count = #node_results,
                source_actor_id = task.context.source_actor_id,
            })

            -- Collect AFTER_DAMAGE style hooks only when depth allows; offline slice hooks ACTION_FINISHED via advance.
            local triggered = collect_status_triggers(
                runtime,
                catalog,
                'STATUS_REMOVED',
                nil,
                task.context.trigger_depth or 0,
                true
            )
            -- STATUS_REMOVED auto-chain is reserved; keep queue extension point without free loops.
            local _ = triggered
        end
    end

    local prng_end = prng.draw_count or prng_start
    return result_ok({
        runtime = runtime,
        events = events,
        requests = requests,
        prng_draw_start = prng_start,
        prng_draw_end = prng_end,
        revision = runtime.revision,
    })
end

function EffectExecutor.advance_status_durations(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'INPUT_REQUIRED')
    end
    local catalog = raw_get(input, 'catalog')
    local runtime = raw_get(input, 'runtime')
    local action_event = raw_get(input, 'action_event')
    if catalog == nil then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'CATALOG_REQUIRED')
    end
    if type_value(runtime) ~= 'table' then
        return fail(EffectErrorCodes.EFFECT_RUNTIME_INVALID, 'RUNTIME_REQUIRED')
    end
    if type_value(action_event) ~= 'table'
        or type_value(action_event.action_index) ~= 'number'
        or type_value(action_event.actor_id) ~= 'string'
    then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'ACTION_EVENT_REQUIRED')
    end
    local cloned = CombatRuntime.clone(runtime)
    if not cloned.ok then
        return cloned
    end
    runtime = cloned.value
    local events = {}
    local advanced = StatusCollection.advance_durations(runtime, catalog, action_event, events)
    if not advanced.ok then
        return advanced
    end
    return result_ok({
        runtime = runtime,
        events = events,
        removed = advanced.value.removed,
        replayed = advanced.value.replayed,
        revision = runtime.revision,
    })
end

function EffectExecutor.apply_status(input)
    if type_value(input) ~= 'table' then
        return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'INPUT_REQUIRED')
    end
    if raw_get(input, 'authorized') ~= true then
        return fail(EffectErrorCodes.EFFECT_CALLER_UNAUTHORIZED, 'UNAUTHORIZED_CALLER')
    end
    local catalog = raw_get(input, 'catalog')
    local runtime = raw_get(input, 'runtime')
    local status_id = raw_get(input, 'status_id')
    local definition_result = catalog:require_status(status_id)
    if not definition_result.ok then
        return definition_result
    end
    local cloned = CombatRuntime.clone(runtime)
    if not cloned.ok then
        return cloned
    end
    runtime = cloned.value
    local events = {}
    local applied = StatusCollection.apply(runtime, definition_result.value, {
        owner_actor_id = raw_get(input, 'owner_actor_id'),
        source_actor_id = raw_get(input, 'source_actor_id'),
        source_definition_id = raw_get(input, 'source_definition_id') or 'manual',
        stacks = raw_get(input, 'stacks'),
        duration_override = raw_get(input, 'duration_override'),
        fixed_magnitude = raw_get(input, 'fixed_magnitude'),
    }, events)
    if not applied.ok then
        return applied
    end
    return result_ok({
        runtime = runtime,
        outcome = applied.value.outcome,
        events = events,
        revision = runtime.revision,
    })
end

return EffectExecutor
