local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local CombatRuntime = require 'wzx.domain.effects.combat_runtime'
local EffectErrorCodes = require 'wzx.domain.effects.error_codes'

local StatusCollection = {}
local bytewise_string_less = Ordered.bytewise_string_less
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local raw_get = rawget
local raw_next = next
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

local function has_tag(tags, expected)
    local index
    for index = 1, #tags do
        if tags[index] == expected then
            return true
        end
    end
    return false
end

local function actor_has_immunity(actor, required_absent)
    local index
    for index = 1, #required_absent do
        local tag = required_absent[index]
        if actor.immunity_tags[tag] == true then
            return true, tag
        end
    end
    return false, nil
end

local function control_blocked(actor, control_tags)
    local index
    for index = 1, #control_tags do
        local tag = control_tags[index]
        if actor.control_immunity_tags[tag] == true then
            return true, tag
        end
    end
    return false, nil
end

local function strength_of(instance)
    local snapshot = instance.magnitude_snapshot or {}
    local strength = raw_get(snapshot, 'strength')
    if type_value(strength) == 'number' then
        return strength
    end
    local shield = raw_get(snapshot, 'shield_remaining')
    if type_value(shield) == 'number' then
        return shield
    end
    return instance.stack_count or 0
end

local function matches_source_scope(definition, existing, source_actor_id, source_definition_id)
    local scope = definition.source_scope
    if scope == 'ANY_SOURCE' then
        return true
    end
    if scope == 'PER_SOURCE_ACTOR' then
        return existing.source_actor_id == source_actor_id
    end
    if scope == 'PER_SOURCE_DEFINITION' then
        return existing.source_definition_id == source_definition_id
    end
    return true
end

local function list_matching(runtime, owner_actor_id, status_id, definition, source_actor_id, source_definition_id)
    local matches = {}
    local _
    local instance
    for _, instance in raw_next, runtime.status_instances do
        if instance.owner_actor_id == owner_actor_id
            and instance.status_id == status_id
            and matches_source_scope(definition, instance, source_actor_id, source_definition_id)
        then
            matches[#matches + 1] = instance
        end
    end
    table_sort(matches, function(left, right)
        if left.application_sequence ~= right.application_sequence then
            return left.application_sequence < right.application_sequence
        end
        return bytewise_string_less(left.instance_id, right.instance_id)
    end)
    return matches
end

local function resolve_duration(definition, duration_override)
    if definition.duration_unit == 'UNTIL_COMBAT_END' then
        return nil
    end
    local duration = duration_override
    if duration == nil then
        duration = definition.base_duration
    end
    if duration > definition.max_duration then
        duration = definition.max_duration
    end
    return duration
end

local function apply_refresh_duration(definition, existing_remaining, incoming_duration)
    if definition.duration_unit == 'UNTIL_COMBAT_END' then
        return nil
    end
    local policy = definition.refresh_policy
    if policy == 'NO_REFRESH' then
        return existing_remaining
    end
    if policy == 'RESET_TO_BASE' then
        return incoming_duration
    end
    if policy == 'KEEP_LONGER' then
        if existing_remaining == nil then
            return incoming_duration
        end
        if incoming_duration == nil then
            return existing_remaining
        end
        return math_max(existing_remaining, incoming_duration)
    end
    if policy == 'ADD_DURATION_CLAMPED' then
        local total = (existing_remaining or 0) + (incoming_duration or 0)
        return math_min(total, definition.max_duration)
    end
    return incoming_duration
end

local function apply_magnitude_policy(definition, existing_snapshot, incoming_snapshot)
    local policy = definition.magnitude_policy
    if policy == 'KEEP_OLD' and existing_snapshot ~= nil then
        return existing_snapshot
    end
    if policy == 'KEEP_MAX' and existing_snapshot ~= nil then
        local left = strength_of({ magnitude_snapshot = existing_snapshot, stack_count = 0 })
        local right = strength_of({ magnitude_snapshot = incoming_snapshot, stack_count = 0 })
        if left >= right then
            return existing_snapshot
        end
        return incoming_snapshot
    end
    if policy == 'ADD_CLAMPED' and existing_snapshot ~= nil then
        local merged = {}
        local key
        local value
        for key, value in raw_next, existing_snapshot do
            merged[key] = value
        end
        for key, value in raw_next, incoming_snapshot or {} do
            local previous = merged[key]
            if type_value(previous) == 'number' and type_value(value) == 'number' then
                local sum = previous + value
                if sum > 1000000000 then
                    sum = 1000000000
                end
                merged[key] = sum
            else
                merged[key] = value
            end
        end
        return merged
    end
    return incoming_snapshot or {}
end

local function emit(events, event_type, payload)
    events[#events + 1] = {
        event_type = event_type,
        payload = payload,
    }
end

local function remove_instance(runtime, instance, reason, events)
    runtime.status_instances[instance.instance_id] = nil
    emit(events, 'StatusRemoved', {
        instance_id = instance.instance_id,
        status_id = instance.status_id,
        owner_actor_id = instance.owner_actor_id,
        reason = reason,
        stack_count = instance.stack_count,
    })
end

function StatusCollection.apply(runtime, definition, params, events)
    events = events or {}
    local owner = CombatRuntime.get_actor(runtime, params.owner_actor_id)
    if owner == nil then
        return fail(EffectErrorCodes.EFFECT_TARGET_INVALID, 'OWNER_NOT_FOUND', {
            owner_actor_id = params.owner_actor_id,
        })
    end
    if not owner.alive and params.allow_dead ~= true then
        return fail(EffectErrorCodes.EFFECT_TARGET_INVALID, 'OWNER_NOT_ALIVE', {
            owner_actor_id = params.owner_actor_id,
        })
    end

    local immune, immune_tag = actor_has_immunity(owner, definition.immunity_tags_required_absent)
    if immune then
        emit(events, 'StatusApplicationRejected', {
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            reason = 'IMMUNE',
            immune_tag = immune_tag,
            consumed_rng = false,
        })
        return result_ok({
            outcome = 'REJECTED',
            reason = 'IMMUNE',
            events = events,
            consumed_rng = false,
        })
    end

    local blocked, control_tag = control_blocked(owner, definition.control_tags)
    if blocked then
        emit(events, 'StatusApplicationRejected', {
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            reason = 'CONTROL_IMMUNE',
            immune_tag = control_tag,
            consumed_rng = false,
        })
        return result_ok({
            outcome = 'REJECTED',
            reason = 'CONTROL_IMMUNE',
            events = events,
            consumed_rng = false,
        })
    end

    local owner_count = CombatRuntime.count_owner_statuses(runtime, params.owner_actor_id)
    local combat_count = CombatRuntime.count_statuses(runtime)
    local matches = list_matching(
        runtime,
        params.owner_actor_id,
        definition.id,
        definition,
        params.source_actor_id,
        params.source_definition_id
    )
    local incoming_duration = resolve_duration(definition, params.duration_override)
    local stacks = params.stacks or 1
    if stacks > definition.max_stacks then
        stacks = definition.max_stacks
    end
    local incoming_magnitude = params.magnitude_snapshot or {}
    if params.fixed_magnitude ~= nil then
        incoming_magnitude = {
            strength = params.fixed_magnitude,
            shield_remaining = has_tag(definition.tags, 'SHIELD') and params.fixed_magnitude or nil,
        }
        if not has_tag(definition.tags, 'SHIELD') then
            incoming_magnitude.shield_remaining = nil
        end
    end

    local mode = definition.stacking_mode
    if mode == 'REPLACE' then
        local index
        for index = 1, #matches do
            remove_instance(runtime, matches[index], 'REPLACED', events)
        end
        if CombatRuntime.count_owner_statuses(runtime, params.owner_actor_id)
            >= CombatRuntime.MAX_STATUS_INSTANCES_PER_ACTOR
            or CombatRuntime.count_statuses(runtime) >= CombatRuntime.MAX_STATUS_INSTANCES_COMBAT
        then
            return fail(EffectErrorCodes.EFFECT_STATUS_LIMIT, 'STATUS_INSTANCE_LIMIT', {
                owner_actor_id = params.owner_actor_id,
            })
        end
        local instance_id = CombatRuntime.next_status_instance_id(runtime)
        local instance = {
            instance_id = instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            source_actor_id = params.source_actor_id,
            source_definition_id = params.source_definition_id,
            stack_count = stacks,
            remaining_duration = incoming_duration,
            duration_unit = definition.duration_unit,
            magnitude_snapshot = incoming_magnitude,
            application_sequence = runtime.status_sequence,
            trigger_counters = {},
            suppressed = false,
        }
        runtime.status_instances[instance_id] = instance
        emit(events, 'StatusApplied', {
            instance_id = instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            source_actor_id = params.source_actor_id,
            stack_count = stacks,
            remaining_duration = incoming_duration,
            duration_unit = definition.duration_unit,
        })
        CombatRuntime.bump_revision(runtime)
        return result_ok({
            outcome = 'REPLACED',
            instance = instance,
            events = events,
            consumed_rng = params.consumed_rng == true,
        })
    end

    if mode == 'INDEPENDENT' then
        if #matches >= definition.max_instances_per_actor then
            return fail(EffectErrorCodes.EFFECT_STATUS_LIMIT, 'STATUS_INSTANCE_LIMIT', {
                owner_actor_id = params.owner_actor_id,
                status_id = definition.id,
            })
        end
        if owner_count >= CombatRuntime.MAX_STATUS_INSTANCES_PER_ACTOR
            or combat_count >= CombatRuntime.MAX_STATUS_INSTANCES_COMBAT
        then
            return fail(EffectErrorCodes.EFFECT_STATUS_LIMIT, 'STATUS_INSTANCE_LIMIT', {
                owner_actor_id = params.owner_actor_id,
            })
        end
        local instance_id = CombatRuntime.next_status_instance_id(runtime)
        local instance = {
            instance_id = instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            source_actor_id = params.source_actor_id,
            source_definition_id = params.source_definition_id,
            stack_count = stacks,
            remaining_duration = incoming_duration,
            duration_unit = definition.duration_unit,
            magnitude_snapshot = incoming_magnitude,
            application_sequence = runtime.status_sequence,
            trigger_counters = {},
            suppressed = false,
        }
        runtime.status_instances[instance_id] = instance
        emit(events, 'StatusApplied', {
            instance_id = instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            source_actor_id = params.source_actor_id,
            stack_count = stacks,
            remaining_duration = incoming_duration,
            duration_unit = definition.duration_unit,
        })
        CombatRuntime.bump_revision(runtime)
        return result_ok({
            outcome = 'APPLIED',
            instance = instance,
            events = events,
            consumed_rng = params.consumed_rng == true,
        })
    end

    local existing = matches[1]
    if existing == nil then
        if owner_count >= CombatRuntime.MAX_STATUS_INSTANCES_PER_ACTOR
            or combat_count >= CombatRuntime.MAX_STATUS_INSTANCES_COMBAT
        then
            return fail(EffectErrorCodes.EFFECT_STATUS_LIMIT, 'STATUS_INSTANCE_LIMIT', {
                owner_actor_id = params.owner_actor_id,
            })
        end
        local instance_id = CombatRuntime.next_status_instance_id(runtime)
        local instance = {
            instance_id = instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            source_actor_id = params.source_actor_id,
            source_definition_id = params.source_definition_id,
            stack_count = stacks,
            remaining_duration = incoming_duration,
            duration_unit = definition.duration_unit,
            magnitude_snapshot = incoming_magnitude,
            application_sequence = runtime.status_sequence,
            trigger_counters = {},
            suppressed = false,
        }
        runtime.status_instances[instance_id] = instance
        emit(events, 'StatusApplied', {
            instance_id = instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            source_actor_id = params.source_actor_id,
            stack_count = stacks,
            remaining_duration = incoming_duration,
            duration_unit = definition.duration_unit,
        })
        CombatRuntime.bump_revision(runtime)
        return result_ok({
            outcome = 'APPLIED',
            instance = instance,
            events = events,
            consumed_rng = params.consumed_rng == true,
        })
    end

    if mode == 'KEEP_STRONGER' then
        local old_strength = strength_of(existing)
        local new_strength = strength_of({
            magnitude_snapshot = incoming_magnitude,
            stack_count = stacks,
        })
        if new_strength <= old_strength then
            emit(events, 'StatusApplicationRejected', {
                status_id = definition.id,
                owner_actor_id = params.owner_actor_id,
                reason = 'NO_CHANGE',
                consumed_rng = params.consumed_rng == true,
            })
            return result_ok({
                outcome = 'NO_CHANGE',
                instance = existing,
                events = events,
                consumed_rng = params.consumed_rng == true,
            })
        end
        remove_instance(runtime, existing, 'REPLACED', events)
        local instance_id = CombatRuntime.next_status_instance_id(runtime)
        local instance = {
            instance_id = instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            source_actor_id = params.source_actor_id,
            source_definition_id = params.source_definition_id,
            stack_count = stacks,
            remaining_duration = incoming_duration,
            duration_unit = definition.duration_unit,
            magnitude_snapshot = incoming_magnitude,
            application_sequence = runtime.status_sequence,
            trigger_counters = {},
            suppressed = false,
        }
        runtime.status_instances[instance_id] = instance
        emit(events, 'StatusApplied', {
            instance_id = instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            source_actor_id = params.source_actor_id,
            stack_count = stacks,
            remaining_duration = incoming_duration,
            duration_unit = definition.duration_unit,
        })
        CombatRuntime.bump_revision(runtime)
        return result_ok({
            outcome = 'REPLACED',
            instance = instance,
            events = events,
            consumed_rng = params.consumed_rng == true,
        })
    end

    if mode == 'REFRESH' then
        local old_duration = existing.remaining_duration
        existing.remaining_duration = apply_refresh_duration(
            definition,
            existing.remaining_duration,
            incoming_duration
        )
        existing.magnitude_snapshot = apply_magnitude_policy(
            definition,
            existing.magnitude_snapshot,
            incoming_magnitude
        )
        existing.source_actor_id = params.source_actor_id
        existing.source_definition_id = params.source_definition_id
        emit(events, 'StatusRefreshed', {
            instance_id = existing.instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            old_remaining_duration = old_duration,
            remaining_duration = existing.remaining_duration,
            stack_count = existing.stack_count,
        })
        CombatRuntime.bump_revision(runtime)
        return result_ok({
            outcome = 'REFRESHED',
            instance = existing,
            events = events,
            consumed_rng = params.consumed_rng == true,
        })
    end

    if mode == 'ADD_STACK' then
        local old_stacks = existing.stack_count
        local new_stacks = math_min(old_stacks + stacks, definition.max_stacks)
        existing.stack_count = new_stacks
        existing.remaining_duration = apply_refresh_duration(
            definition,
            existing.remaining_duration,
            incoming_duration
        )
        existing.magnitude_snapshot = apply_magnitude_policy(
            definition,
            existing.magnitude_snapshot,
            incoming_magnitude
        )
        existing.source_actor_id = params.source_actor_id
        existing.source_definition_id = params.source_definition_id
        emit(events, 'StatusStackChanged', {
            instance_id = existing.instance_id,
            status_id = definition.id,
            owner_actor_id = params.owner_actor_id,
            old_stack_count = old_stacks,
            stack_count = new_stacks,
            remaining_duration = existing.remaining_duration,
        })
        CombatRuntime.bump_revision(runtime)
        return result_ok({
            outcome = 'STACKED',
            instance = existing,
            events = events,
            consumed_rng = params.consumed_rng == true,
        })
    end

    return fail(EffectErrorCodes.EFFECT_ARGUMENT_INVALID, 'UNKNOWN_STACKING_MODE', {
        stacking_mode = mode,
    })
end

local function dispel_sort(left, right)
    if left.dispel_priority ~= right.dispel_priority then
        return left.dispel_priority > right.dispel_priority
    end
    if left.application_sequence ~= right.application_sequence then
        return left.application_sequence < right.application_sequence
    end
    if left.status_id ~= right.status_id then
        return bytewise_string_less(left.status_id, right.status_id)
    end
    return bytewise_string_less(left.instance_id, right.instance_id)
end

function StatusCollection.remove(runtime, catalog, params, events)
    events = events or {}
    local owner_actor_id = params.owner_actor_id
    local removed = {}
    local candidates = {}
    local _
    local instance
    for _, instance in raw_next, runtime.status_instances do
        if owner_actor_id == nil or instance.owner_actor_id == owner_actor_id then
            if params.instance_id ~= nil then
                if instance.instance_id == params.instance_id then
                    candidates[#candidates + 1] = {
                        instance = instance,
                        dispel_priority = 0,
                    }
                end
            elseif params.status_id ~= nil then
                if instance.status_id == params.status_id then
                    candidates[#candidates + 1] = {
                        instance = instance,
                        dispel_priority = 0,
                    }
                end
            else
                local definition_result = catalog:require_status(instance.status_id)
                if not definition_result.ok then
                    return definition_result
                end
                local definition = definition_result.value
                local category = params.dispel_category or 'ANY'
                local polarity_filter = params.polarity_filter or 'ANY'
                local category_ok = category == 'ANY'
                    or definition.dispel_category == category
                    or definition.dispel_category == 'ANY'
                if definition.dispel_category == 'UNDISPELLABLE'
                    or has_tag(definition.tags, 'UNDISPELLABLE')
                then
                    category_ok = false
                end
                local polarity_ok = polarity_filter == 'ANY'
                    or definition.polarity == polarity_filter
                if category_ok and polarity_ok then
                    candidates[#candidates + 1] = {
                        instance = instance,
                        dispel_priority = definition.dispel_priority,
                        status_id = instance.status_id,
                        application_sequence = instance.application_sequence,
                        instance_id = instance.instance_id,
                    }
                end
            end
        end
    end

    if params.instance_id == nil and params.status_id == nil then
        table_sort(candidates, function(left, right)
            return dispel_sort(left, right)
        end)
    end

    local limit = params.count or #candidates
    local index
    for index = 1, #candidates do
        if #removed >= limit then
            break
        end
        local row = candidates[index]
        local target = row.instance
        remove_instance(runtime, target, params.reason or 'DISPELLED', events)
        removed[#removed + 1] = target.instance_id
    end
    if #removed > 0 then
        CombatRuntime.bump_revision(runtime)
    end
    return result_ok({
        removed = removed,
        events = events,
    })
end

function StatusCollection.list_control_tags(runtime, owner_actor_id)
    local tags = {}
    local _
    local instance
    for _, instance in raw_next, runtime.status_instances do
        if instance.owner_actor_id == owner_actor_id and not instance.suppressed then
            -- control tags live on definition; callers should pass catalog when needed
            tags[#tags + 1] = instance
        end
    end
    return tags
end

function StatusCollection.absorb_damage(runtime, catalog, owner_actor_id, amount, events)
    events = events or {}
    if amount <= 0 then
        return result_ok({
            remaining_damage = 0,
            absorbed = 0,
            events = events,
        })
    end
    local shields = {}
    local _
    local instance
    for _, instance in raw_next, runtime.status_instances do
        if instance.owner_actor_id == owner_actor_id then
            local definition_result = catalog:require_status(instance.status_id)
            if definition_result.ok then
                local definition = definition_result.value
                if has_tag(definition.tags, 'SHIELD') then
                    local remaining = raw_get(instance.magnitude_snapshot, 'shield_remaining') or 0
                    if remaining > 0 then
                        shields[#shields + 1] = {
                            instance = instance,
                            definition = definition,
                            absorb_priority = definition.absorb_priority,
                            application_sequence = instance.application_sequence,
                            instance_id = instance.instance_id,
                        }
                    end
                end
            end
        end
    end
    table_sort(shields, function(left, right)
        if left.absorb_priority ~= right.absorb_priority then
            return left.absorb_priority > right.absorb_priority
        end
        if left.application_sequence ~= right.application_sequence then
            return left.application_sequence < right.application_sequence
        end
        return bytewise_string_less(left.instance_id, right.instance_id)
    end)

    local remaining = amount
    local absorbed_total = 0
    local index
    for index = 1, #shields do
        if remaining <= 0 then
            break
        end
        local row = shields[index]
        local instance = row.instance
        local shield_remaining = instance.magnitude_snapshot.shield_remaining or 0
        local absorbed = math_min(shield_remaining, remaining)
        shield_remaining = shield_remaining - absorbed
        remaining = remaining - absorbed
        absorbed_total = absorbed_total + absorbed
        instance.magnitude_snapshot.shield_remaining = shield_remaining
        emit(events, 'ShieldAbsorbed', {
            instance_id = instance.instance_id,
            status_id = instance.status_id,
            owner_actor_id = owner_actor_id,
            absorbed = absorbed,
            remaining = shield_remaining,
        })
        if shield_remaining <= 0 then
            emit(events, 'ShieldBroken', {
                instance_id = instance.instance_id,
                status_id = instance.status_id,
                owner_actor_id = owner_actor_id,
            })
            remove_instance(runtime, instance, 'CONSUMED', events)
        end
    end
    if absorbed_total > 0 then
        CombatRuntime.bump_revision(runtime)
    end
    return result_ok({
        remaining_damage = remaining,
        absorbed = absorbed_total,
        events = events,
    })
end

function StatusCollection.advance_durations(runtime, catalog, action_event, events)
    events = events or {}
    local action_index = action_event.action_index
    if runtime.duration_advanced_actions[action_index] == true then
        return result_ok({
            removed = {},
            events = events,
            replayed = true,
        })
    end

    local actor_id = action_event.actor_id
    local expired = {}
    local _
    local instance
    for _, instance in raw_next, runtime.status_instances do
        if instance.remaining_duration ~= nil then
            local unit = instance.duration_unit
            local should_tick = false
            if unit == 'GLOBAL_ACTIONS' then
                should_tick = true
            elseif unit == 'OWNER_ACTIONS' and instance.owner_actor_id == actor_id then
                should_tick = true
            elseif unit == 'SOURCE_ACTIONS' and instance.source_actor_id == actor_id then
                should_tick = true
            end
            if should_tick then
                instance.remaining_duration = instance.remaining_duration - 1
                if instance.remaining_duration <= 0 then
                    expired[#expired + 1] = instance
                end
            end
        end
    end
    table_sort(expired, function(left, right)
        if left.application_sequence ~= right.application_sequence then
            return left.application_sequence < right.application_sequence
        end
        return bytewise_string_less(left.instance_id, right.instance_id)
    end)
    local removed = {}
    local index
    for index = 1, #expired do
        remove_instance(runtime, expired[index], 'EXPIRED', events)
        removed[#removed + 1] = expired[index].instance_id
    end
    runtime.duration_advanced_actions[action_index] = true
    if #removed > 0 then
        CombatRuntime.bump_revision(runtime)
    end
    return result_ok({
        removed = removed,
        events = events,
        replayed = false,
    })
end

function StatusCollection.owner_has_status(runtime, owner_actor_id, status_id, min_stacks)
    min_stacks = min_stacks or 1
    local _
    local instance
    for _, instance in raw_next, runtime.status_instances do
        if instance.owner_actor_id == owner_actor_id
            and instance.status_id == status_id
            and instance.stack_count >= min_stacks
        then
            return true
        end
    end
    return false
end

function StatusCollection.owner_has_tag(runtime, catalog, owner_actor_id, tag)
    local _
    local instance
    for _, instance in raw_next, runtime.status_instances do
        if instance.owner_actor_id == owner_actor_id then
            local definition_result = catalog:require_status(instance.status_id)
            if definition_result.ok and has_tag(definition_result.value.tags, tag) then
                return true
            end
        end
    end
    return false
end

-- silence unused import warning path for math_floor in some analyzers
local _ = math_floor

return StatusCollection
