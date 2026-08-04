local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local ParkMiller = require 'wzx.domain.common.park_miller_rng'
local Sha256 = require 'wzx.domain.common.sha256'
local CombatSnapshot = require 'wzx.domain.contracts.combat_snapshot'
local CombatErrorCodes = require 'wzx.domain.combat.error_codes'
local Rules = require 'wzx.domain.combat.rules'
local Damage = require 'wzx.domain.combat.damage'
local Timeline = require 'wzx.domain.combat.timeline'
local MartialLoadoutRuntime = require 'wzx.domain.combat.martial_loadout_runtime'
local CombatRuntime = require 'wzx.domain.effects.combat_runtime'
local EffectExecutor = require 'wzx.domain.effects.effect_executor'

local CombatAggregate = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_concat = table.concat
local table_sort = table.sort
local type_value = type
local validate_component = RuntimeId.validate_component

local PHASE = {
    CREATED = 'CREATED',
    RUNNING = 'RUNNING',
    DECISION_REQUIRED = 'DECISION_REQUIRED',
    FINISHING = 'FINISHING',
    FINISHED = 'FINISHED',
    INVALID = 'INVALID',
}

-- Forward declaration: effect bridge helpers call append_event before its body.
local append_event

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.combat.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(CombatErrorCodes.COMBAT_ARGUMENT_INVALID, reason, details)
end

local function copy_stats(stats)
    return {
        max_hp = stats.max_hp,
        attack = stats.attack,
        defense = stats.defense,
        speed = stats.speed,
        accuracy = stats.accuracy,
        evasion = stats.evasion,
        crit_chance_bp = stats.crit_chance_bp,
        crit_damage_bp = stats.crit_damage_bp,
        crit_resist_bp = stats.crit_resist_bp,
        block_chance_bp = stats.block_chance_bp,
        block_reduction_bp = stats.block_reduction_bp,
        damage_bonus_bp = stats.damage_bonus_bp,
        damage_reduction_bp = stats.damage_reduction_bp,
        healing_bonus_bp = stats.healing_bonus_bp,
        healing_received_bp = stats.healing_received_bp,
        max_qi = stats.max_qi,
        initial_qi = stats.initial_qi,
        qi_gain_bp = stats.qi_gain_bp,
        effect_accuracy = stats.effect_accuracy,
        effect_resistance = stats.effect_resistance,
    }
end

local function make_actor(member)
    local stats = copy_stats(member.stats)
    local loadout = MartialLoadoutRuntime.normalize(member.martial_loadout or {})
    local actor = {
        actor_id = member.actor_id,
        definition_id = member.definition_id,
        side = member.side,
        position_index = member.position_index,
        level = member.level,
        tags = member.tags,
        stats = stats,
        max_hp = stats.max_hp,
        current_hp = stats.max_hp,
        max_qi = stats.max_qi,
        current_qi = stats.initial_qi,
        speed = stats.speed,
        accuracy = stats.accuracy,
        evasion = stats.evasion,
        attack = stats.attack,
        defense = stats.defense,
        crit_chance_bp = stats.crit_chance_bp,
        crit_damage_bp = stats.crit_damage_bp,
        crit_resist_bp = stats.crit_resist_bp,
        block_chance_bp = stats.block_chance_bp,
        block_reduction_bp = stats.block_reduction_bp,
        damage_bonus_bp = stats.damage_bonus_bp,
        damage_reduction_bp = stats.damage_reduction_bp,
        qi_gain_bp = stats.qi_gain_bp,
        effect_accuracy = stats.effect_accuracy,
        effect_resistance = stats.effect_resistance,
        gauge = 0,
        alive_state = 'ALIVE',
        action_count = 0,
        ai_profile_id = member.ai_profile_id,
        -- Normalized martial loadout (basic_move + active_moves).
        martial_loadout = loadout,
        -- Legacy alias used by older call sites / diagnostics.
        basic_attack = loadout.basic_move,
        move_cooldowns = {},
        stunned = false,
    }
    MartialLoadoutRuntime.apply_initial_cooldowns(actor, loadout)
    return actor
end

local function side_order_of(side)
    if side == 'ATTACKER' then
        return 0
    end
    return 1
end

local function build_effect_runtime(state)
    local actors = {}
    local index
    for index = 1, #state.actor_order do
        local actor = state.actors[state.actor_order[index]]
        actors[#actors + 1] = {
            actor_id = actor.actor_id,
            side_order = side_order_of(actor.side),
            position = actor.position_index + 1,
            alive = actor.alive_state == 'ALIVE',
            hp = actor.current_hp,
            max_hp = actor.max_hp,
            qi = actor.current_qi,
            max_qi = actor.max_qi,
            effect_accuracy = actor.effect_accuracy or 0,
            effect_resistance = actor.effect_resistance or 0,
            immunity_tags = {},
            control_immunity_tags = {},
        }
    end
    return CombatRuntime.create({
        combat_id = state.combat_id,
        rules_version = state.rules_version,
        actors = actors,
    })
end

local function sync_effect_runtime_from_combat(state)
    if state.effect_runtime == nil then
        return
    end
    local runtime = state.effect_runtime
    local actor_id
    local actor
    for actor_id, actor in raw_next, state.actors do
        local effect_actor = runtime.actors[actor_id]
        if effect_actor ~= nil then
            effect_actor.hp = actor.current_hp
            effect_actor.max_hp = actor.max_hp
            effect_actor.qi = actor.current_qi
            effect_actor.max_qi = actor.max_qi
            effect_actor.alive = actor.alive_state == 'ALIVE'
            effect_actor.effect_accuracy = actor.effect_accuracy or 0
            effect_actor.effect_resistance = actor.effect_resistance or 0
        end
    end
end

local function sync_combat_from_effect_runtime(state)
    if state.effect_runtime == nil then
        return
    end
    local runtime = state.effect_runtime
    local actor_id
    local effect_actor
    for actor_id, effect_actor in raw_next, runtime.actors do
        local actor = state.actors[actor_id]
        if actor ~= nil then
            actor.current_qi = effect_actor.qi
            -- HP/alive from effect DEAL_DAMAGE/HEAL; combat damage path already applied first.
            if effect_actor.hp < actor.current_hp then
                actor.current_hp = effect_actor.hp
                if actor.current_hp == 0 and actor.alive_state == 'ALIVE' then
                    actor.alive_state = 'DOWNED'
                    append_event(state, 'ActorDowned', {
                        actor_id = actor.actor_id,
                        source_actor_id = nil,
                        reason = 'EFFECT',
                    })
                end
            elseif effect_actor.hp > actor.current_hp and effect_actor.alive then
                actor.current_hp = effect_actor.hp
            end
            if not effect_actor.alive and actor.alive_state == 'ALIVE' and actor.current_hp == 0 then
                actor.alive_state = 'DOWNED'
            end
        end
    end
end

local function append_effect_events(state, bundle_id, source_actor_id, effect_events)
    append_event(state, 'EffectBundleResolved', {
        bundle_id = bundle_id,
        source_actor_id = source_actor_id,
        child_event_count = #effect_events,
        child_events = effect_events,
    })
    local index
    for index = 1, #effect_events do
        local child = effect_events[index]
        append_event(state, child.event_type, child.payload or {})
    end
end

local function resolve_effect_bundle(state, actor, move, target_ids)
    if move.effect_bundle_id == nil then
        return result_ok({ applied = false, reason = 'NO_BUNDLE' })
    end
    if state.effect_catalog == nil or state.effect_runtime == nil then
        -- Compatible with legacy tests: ignore bundle when catalog not injected.
        return result_ok({ applied = false, reason = 'NO_CATALOG' })
    end
    sync_effect_runtime_from_combat(state)
    local resolved = EffectExecutor.resolve_bundle({
        catalog = state.effect_catalog,
        runtime = state.effect_runtime,
        bundle_id = move.effect_bundle_id,
        prng = state.prng,
        context = {
            combat_id = state.combat_id,
            source_actor_id = actor.actor_id,
            source_definition_id = move.move_id,
            primary_target_ids = target_ids,
            action_index = state.action_index,
            trigger_depth = 0,
            rules_version = state.rules_version,
        },
    })
    if not resolved.ok then
        return resolved
    end
    state.effect_runtime = resolved.value.runtime
    append_effect_events(
        state,
        move.effect_bundle_id,
        actor.actor_id,
        resolved.value.events or {}
    )
    sync_combat_from_effect_runtime(state)
    return result_ok({ applied = true })
end

append_event = function(state, event_type, payload)
    local sequence = state.sequence_cursor
    state.sequence_cursor = sequence + 1
    local event = {
        event_type = event_type,
        schema_version = Rules.EVENT_SCHEMA_VERSION,
        combat_id = state.combat_id,
        sequence = sequence,
        action_index = state.action_index,
        payload = payload or {},
    }
    state.events[#state.events + 1] = event
    state.event_trace[#state.event_trace + 1] = event_type
        .. ':'
        .. tostring(sequence)
        .. ':'
        .. tostring(state.action_index)
    return event
end

local function side_alive_count(state, side)
    local count = 0
    local _
    local actor
    for _, actor in raw_next, state.actors do
        if actor.side == side and actor.alive_state == 'ALIVE' then
            count = count + 1
        end
    end
    return count
end

local function list_alive_enemies(state, side)
    local enemy_side = side == 'ATTACKER' and 'DEFENDER' or 'ATTACKER'
    local rows = {}
    local _
    local actor
    for _, actor in raw_next, state.actors do
        if actor.side == enemy_side and actor.alive_state == 'ALIVE' then
            rows[#rows + 1] = actor
        end
    end
    table_sort(rows, function(left, right)
        if left.position_index ~= right.position_index then
            return left.position_index < right.position_index
        end
        return bytewise_string_less(left.actor_id, right.actor_id)
    end)
    return rows
end

local function list_survivors(state)
    local rows = {}
    local _
    local actor
    for _, actor in raw_next, state.actors do
        rows[#rows + 1] = {
            actor_id = actor.actor_id,
            side = actor.side,
            alive_state = actor.alive_state,
            current_hp = actor.current_hp,
            current_qi = actor.current_qi,
        }
    end
    table_sort(rows, function(left, right)
        return bytewise_string_less(left.actor_id, right.actor_id)
    end)
    return rows
end

local function compute_event_hash(state)
    local hashed = Sha256.hex(table_concat(state.event_trace, '\n'))
    if type_value(hashed) == 'string' then
        return hashed
    end
    return string.rep('0', 64)
end

local function finish(state, outcome, finish_reason)
    if state.phase == PHASE.FINISHED or state.phase == PHASE.INVALID then
        return
    end
    state.phase = PHASE.FINISHING
    append_event(state, 'CombatFinishing', {
        outcome = outcome,
        finish_reason = finish_reason,
    })
    local winner_side = nil
    if outcome == 'ATTACKER_WIN' then
        winner_side = 'ATTACKER'
    elseif outcome == 'DEFENDER_WIN'
        or outcome == 'ATTACKER_FORFEIT'
        or outcome == 'TIMEOUT'
    then
        winner_side = 'DEFENDER'
    end
    local prng_state = state.prng:get_state()
    state.result = {
        outcome = outcome,
        winner_side = winner_side,
        finish_reason = finish_reason,
        action_count = state.action_index,
        final_tick = state.current_tick,
        survivor_rows = list_survivors(state),
        snapshot_hash = state.snapshot_hash,
        command_hash = state.command_hash,
        event_hash = compute_event_hash(state),
        prng_draw_count = prng_state.draw_count,
        rules_version = state.rules_version,
        diagnostics = {},
    }
    append_event(state, 'CombatFinished', {
        outcome = outcome,
        winner_side = winner_side,
        finish_reason = finish_reason,
        action_count = state.action_index,
        event_hash = state.result.event_hash,
        prng_draw_count = state.result.prng_draw_count,
    })
    if outcome == 'INVALID_RULE_EXECUTION' then
        state.phase = PHASE.INVALID
    else
        state.phase = PHASE.FINISHED
    end
    state.revision = state.revision + 1
end

local function check_victory(state)
    local attackers = side_alive_count(state, 'ATTACKER')
    local defenders = side_alive_count(state, 'DEFENDER')
    if attackers == 0 and defenders == 0 then
        finish(state, Rules.MUTUAL_DOWN_OUTCOME, 'MUTUAL_DOWN')
        return true
    end
    if defenders == 0 then
        finish(state, 'ATTACKER_WIN', 'DEFENDER_WIPED')
        return true
    end
    if attackers == 0 then
        finish(state, 'DEFENDER_WIN', 'ATTACKER_WIPED')
        return true
    end
    return false
end

local function apply_damage_to_actor(state, target, amount, source_actor_id, diagnostics)
    local old_hp = target.current_hp
    local new_hp = math_max(0, old_hp - amount)
    target.current_hp = new_hp
    append_event(state, 'DamageApplied', {
        source_actor_id = source_actor_id,
        target_id = target.actor_id,
        amount = amount,
        old_hp = old_hp,
        new_hp = new_hp,
        hit = diagnostics.hit,
        crit = diagnostics.crit,
        blocked = diagnostics.blocked,
        formula = diagnostics,
    })
    if new_hp == 0 and target.alive_state == 'ALIVE' then
        target.alive_state = 'DOWNED'
        append_event(state, 'ActorDowned', {
            actor_id = target.actor_id,
            source_actor_id = source_actor_id,
        })
    end
end

local function gain_qi(actor, base_gain)
    if base_gain == nil or base_gain == 0 then
        return 0
    end
    local actual = math_floor(base_gain * (actor.qi_gain_bp or 10000) / 10000)
    local old = actor.current_qi
    local new_qi = math_min(actor.max_qi, math_max(0, old + actual))
    actor.current_qi = new_qi
    return new_qi - old
end

local function tick_cooldowns(actor, used_move_id)
    local move_id
    local remaining
    for move_id, remaining in raw_next, actor.move_cooldowns do
        if move_id ~= used_move_id and remaining > 0 then
            actor.move_cooldowns[move_id] = remaining - 1
        end
    end
end

local function resolve_selected_move(state, actor)
    local enemies = list_alive_enemies(state, actor.side)
    if #enemies == 0 then
        return result_ok({ skipped = true, reason = 'NO_TARGET' })
    end
    local target = enemies[1]
    local move, reject_reason = MartialLoadoutRuntime.select_auto_move(actor)
    if move == nil then
        return result_ok({ skipped = true, reason = reject_reason or 'NO_MOVE' })
    end

    local target_ids = { target.actor_id }
    actor.current_qi = actor.current_qi - (move.qi_cost or 0)
    append_event(state, 'MoveSelected', {
        actor_id = actor.actor_id,
        move_id = move.move_id,
        move_type = move.move_type,
        target_ids = target_ids,
        qi_cost = move.qi_cost or 0,
        auto = true,
    })

    -- 1) Optional combat damage path (BASIC always has damage; ACTIVE may omit).
    if type_value(move.damage) == 'table' then
        local resolved = Damage.resolve_hit(actor, target, move.damage, state.prng)
        if not resolved.ok then
            return resolved
        end
        local damage_result = resolved.value
        append_event(state, 'DamageRequested', {
            source_actor_id = actor.actor_id,
            target_id = target.actor_id,
            move_id = move.move_id,
            diagnostics = damage_result.diagnostics,
        })
        if damage_result.hit then
            apply_damage_to_actor(
                state,
                target,
                damage_result.final_damage,
                actor.actor_id,
                damage_result.diagnostics
            )
            local qi_gain = gain_qi(actor, move.on_hit_qi_gain)
            if qi_gain ~= 0 then
                append_event(state, 'QiChanged', {
                    actor_id = actor.actor_id,
                    delta = qi_gain,
                    new_qi = actor.current_qi,
                    reason = 'ON_HIT',
                })
            end
        else
            append_event(state, 'AttackMissed', {
                source_actor_id = actor.actor_id,
                target_id = target.actor_id,
                move_id = move.move_id,
            })
        end
    end

    -- 2) Optional effect bundle (ignored cleanly when catalog not injected).
    local effect_result = resolve_effect_bundle(state, actor, move, target_ids)
    if not effect_result.ok then
        return effect_result
    end

    if (move.action_cooldown or 0) > 0 then
        actor.move_cooldowns[move.move_id] = move.action_cooldown
    end
    return result_ok({
        skipped = false,
        move_id = move.move_id,
        move_type = move.move_type,
    })
end

local function resolve_action(state, actor)
    append_event(state, 'ActorReady', {
        actor_id = actor.actor_id,
        side = actor.side,
        gauge = actor.gauge,
        current_tick = state.current_tick,
    })

    if actor.stunned then
        append_event(state, 'ActionSkipped', {
            actor_id = actor.actor_id,
            reason = 'STUN',
        })
        Timeline.consume_action_gauge(actor)
        actor.action_count = actor.action_count + 1
        state.action_index = state.action_index + 1
        tick_cooldowns(actor, nil)
        append_event(state, 'ActionFinished', {
            actor_id = actor.actor_id,
            action_index = state.action_index,
            skipped = true,
        })
        return result_ok(true)
    end

    local action = resolve_selected_move(state, actor)
    if not action.ok then
        return action
    end
    if action.value.skipped then
        append_event(state, 'ActionSkipped', {
            actor_id = actor.actor_id,
            reason = action.value.reason,
        })
    end

    Timeline.consume_action_gauge(actor)
    actor.action_count = actor.action_count + 1
    state.action_index = state.action_index + 1
    tick_cooldowns(actor, action.value.move_id)
    append_event(state, 'ActionFinished', {
        actor_id = actor.actor_id,
        action_index = state.action_index,
        skipped = action.value.skipped == true,
        move_id = action.value.move_id,
        move_type = action.value.move_type,
    })
    return result_ok(true)
end

local function is_terminal(state)
    return state.phase == PHASE.FINISHED or state.phase == PHASE.INVALID
end

function CombatAggregate.start(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local combat_id = raw_get(input, 'combat_id')
    local id_check = validate_component(combat_id, 'combat_id')
    if not id_check.ok then
        return invalid('COMBAT_ID_INVALID', { field = 'combat_id' })
    end
    local snapshot = raw_get(input, 'snapshot')
    local validated = CombatSnapshot.validate(snapshot)
    if not validated.ok then
        return fail(CombatErrorCodes.COMBAT_SNAPSHOT_INVALID, 'SNAPSHOT_INVALID', {
            cause = validated.error,
        })
    end
    if snapshot.rules_version ~= Rules.RULES_VERSION then
        return fail(CombatErrorCodes.COMBAT_RULES_MISMATCH, 'RULES_VERSION_UNSUPPORTED', {
            expected = Rules.RULES_VERSION,
            actual = snapshot.rules_version,
        })
    end

    local prng = ParkMiller.new(snapshot.seed)
    if not prng.ok then
        return invalid('SEED_INVALID', { seed = snapshot.seed })
    end

    local actors = {}
    local actor_order = {}
    -- Optional carry-over vitals for multi-wave encounters:
    -- { [actor_id] = { current_hp = n, current_qi = n } }
    local actor_vitals = raw_get(input, 'actor_vitals')
    if actor_vitals ~= nil then
        if type_value(actor_vitals) ~= 'table' or get_metatable(actor_vitals) ~= nil then
            return invalid('ACTOR_VITALS_INVALID')
        end
    end

    local function apply_vitals(actor)
        if actor_vitals == nil then
            return
        end
        local vitals = raw_get(actor_vitals, actor.actor_id)
        if type_value(vitals) ~= 'table' then
            return
        end
        local hp = raw_get(vitals, 'current_hp')
        local qi = raw_get(vitals, 'current_qi')
        if type_value(hp) == 'number' and hp == math_floor(hp) then
            if hp < 0 then
                hp = 0
            end
            if hp > actor.max_hp then
                hp = actor.max_hp
            end
            actor.current_hp = hp
            if hp == 0 then
                actor.alive_state = 'DOWN'
            end
        end
        if type_value(qi) == 'number' and qi == math_floor(qi) then
            if qi < 0 then
                qi = 0
            end
            if qi > actor.max_qi then
                qi = actor.max_qi
            end
            actor.current_qi = qi
        end
    end

    local function add_side(members)
        local index
        for index = 1, #members do
            local actor = make_actor(members[index])
            apply_vitals(actor)
            if actors[actor.actor_id] ~= nil then
                return fail(CombatErrorCodes.COMBAT_SNAPSHOT_INVALID, 'DUPLICATE_ACTOR', {
                    actor_id = actor.actor_id,
                })
            end
            actors[actor.actor_id] = actor
            actor_order[#actor_order + 1] = actor.actor_id
        end
        return nil
    end
    local err = add_side(snapshot.attacker_formation.members)
    if err ~= nil then
        return err
    end
    err = add_side(snapshot.defender_formation.members)
    if err ~= nil then
        return err
    end
    table_sort(actor_order, bytewise_string_less)

    local action_limit = snapshot.action_limit
    if action_limit == nil then
        action_limit = Rules.ACTION_LIMIT
    end

    local state = {
        combat_id = combat_id,
        phase = PHASE.RUNNING,
        revision = 1,
        current_tick = 0,
        action_index = 0,
        sequence_cursor = 1,
        rules_version = snapshot.rules_version,
        combat_kind = snapshot.combat_kind,
        control_policy = snapshot.control_policy,
        action_limit = action_limit,
        seed = snapshot.seed,
        snapshot_hash = snapshot.snapshot_hash,
        command_hash = string.rep('0', 64),
        tie_preferred_side = Rules.tie_preferred_side(snapshot.seed),
        actors = actors,
        actor_order = actor_order,
        prng = prng.value,
        events = {},
        event_trace = {},
        command_log = {},
        result = nil,
        auto = snapshot.control_policy == 'AUTO_ALL',
        -- Optional effects bridge (05). Absent => effect_bundle_id ignored.
        effect_catalog = nil,
        effect_runtime = nil,
    }

    local effect_catalog = raw_get(input, 'effect_catalog')
    if effect_catalog ~= nil then
        if type_value(effect_catalog) ~= 'table'
            or type_value(effect_catalog.require_bundle) ~= 'function'
        then
            return invalid('EFFECT_CATALOG_INVALID')
        end
        local runtime_result = build_effect_runtime(state)
        if not runtime_result.ok then
            return fail(
                CombatErrorCodes.COMBAT_ARGUMENT_INVALID,
                'EFFECT_RUNTIME_CREATE_FAILED',
                { cause = runtime_result.error }
            )
        end
        state.effect_catalog = effect_catalog
        state.effect_runtime = runtime_result.value
    end

    append_event(state, 'CombatCreated', {
        combat_kind = snapshot.combat_kind,
        control_policy = snapshot.control_policy,
        seed = snapshot.seed,
        action_limit = action_limit,
        effect_bridge = state.effect_catalog ~= nil,
    })
    append_event(state, 'CombatStarted', {
        attacker_count = #snapshot.attacker_formation.members,
        defender_count = #snapshot.defender_formation.members,
        tie_preferred_side = state.tie_preferred_side,
    })

    if check_victory(state) then
        return result_ok(state)
    end
    return result_ok(state)
end

local function record_command(state, command)
    state.command_log[#state.command_log + 1] = {
        command_id = command.command_id,
        command_type = command.command_type,
        expected_revision = command.expected_revision,
    }
    local parts = {}
    local index
    for index = 1, #state.command_log do
        local row = state.command_log[index]
        parts[#parts + 1] = row.command_id .. ':' .. row.command_type
    end
    local hashed = Sha256.hex(table_concat(parts, '\n'))
    if type_value(hashed) == 'string' then
        state.command_hash = hashed
    else
        state.command_hash = string.rep('0', 64)
    end
end

function CombatAggregate.apply_command(state, command)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(command) ~= 'table' or get_metatable(command) ~= nil then
        return invalid('COMMAND_REQUIRED')
    end

    local command_type = raw_get(command, 'command_type')
    if command_type == 'USE_ITEM' or command_type == 'ITEM' or command_type == 'QUICK_SLOT' then
        return fail(CombatErrorCodes.COMBAT_ITEM_USE_UNSUPPORTED, 'ITEM_USE_UNSUPPORTED', {
            command_type = command_type,
        })
    end
    if command_type ~= 'ADVANCE'
        and command_type ~= 'FORFEIT'
        and command_type ~= 'SET_AUTO'
        and command_type ~= 'CHOOSE_MOVE'
        and command_type ~= 'PASS_ULTIMATE'
    then
        return fail(
            CombatErrorCodes.COMBAT_COMMAND_TYPE_UNSUPPORTED,
            'COMMAND_TYPE_UNSUPPORTED',
            { command_type = command_type }
        )
    end

    if type_value(raw_get(command, 'command_id')) ~= 'string' or command.command_id == '' then
        return invalid('COMMAND_ID_REQUIRED')
    end
    if command.combat_id ~= nil and command.combat_id ~= state.combat_id then
        return invalid('COMBAT_ID_MISMATCH')
    end

    -- idempotent replay by command_id (checked before terminal gate)
    local index
    for index = 1, #state.command_log do
        if state.command_log[index].command_id == command.command_id then
            return fail(
                CombatErrorCodes.COMBAT_COMMAND_IDEMPOTENT_REPLAY,
                'COMMAND_ALREADY_APPLIED',
                { command_id = command.command_id }
            )
        end
    end

    if is_terminal(state) then
        return fail(CombatErrorCodes.COMBAT_ALREADY_FINISHED, 'COMBAT_TERMINAL', {
            phase = state.phase,
        })
    end

    if command.expected_revision ~= nil and command.expected_revision ~= state.revision then
        return fail(CombatErrorCodes.COMBAT_REVISION_CONFLICT, 'REVISION_CONFLICT', {
            expected = command.expected_revision,
            actual = state.revision,
        })
    end

    if command_type == 'SET_AUTO' then
        state.auto = true
        state.control_policy = 'AUTO_ALL'
        record_command(state, command)
        state.revision = state.revision + 1
        append_event(state, 'AutoModeEnabled', { actor_id = command.actor_id })
        return result_ok({
            state = state,
            events = state.events,
            finished = false,
        })
    end

    if command_type == 'FORFEIT' then
        record_command(state, command)
        finish(state, 'ATTACKER_FORFEIT', 'PLAYER_FORFEIT')
        return result_ok({
            state = state,
            events = state.events,
            finished = true,
            result = state.result,
        })
    end

    if command_type == 'CHOOSE_MOVE' or command_type == 'PASS_ULTIMATE' then
        -- Offline slice: manual ultimate not fully wired; only AUTO_ALL path is supported.
        if state.control_policy ~= 'AUTO_ALL' and state.phase == PHASE.DECISION_REQUIRED then
            return fail(CombatErrorCodes.COMBAT_PHASE_INVALID, 'MANUAL_ULTIMATE_NOT_IMPLEMENTED')
        end
        return fail(CombatErrorCodes.COMBAT_PHASE_INVALID, 'NO_PENDING_DECISION')
    end

    -- ADVANCE
    if state.control_policy ~= 'AUTO_ALL' and not state.auto then
        return fail(CombatErrorCodes.COMBAT_NOT_AUTO, 'MANUAL_MODE_REQUIRES_DECISION_COMMANDS')
    end

    record_command(state, command)
    local event_start = #state.events + 1
    local safety = 0
    while not is_terminal(state) do
        safety = safety + 1
        if safety > (state.action_limit * 4 + 16) then
            finish(state, 'INVALID_RULE_EXECUTION', 'ADVANCE_SAFETY_LIMIT')
            break
        end

        local selected = Timeline.select_next_actor(state)
        if not selected.ok then
            finish(state, 'INVALID_RULE_EXECUTION', selected.error.details.reason or 'TIMELINE_FAILED')
            break
        end
        local action = resolve_action(state, selected.value.actor)
        if not action.ok then
            finish(state, 'INVALID_RULE_EXECUTION', action.error.details.reason or 'ACTION_FAILED')
            break
        end
        if check_victory(state) then
            break
        end
        if state.action_index >= state.action_limit then
            finish(state, 'TIMEOUT', 'ACTION_LIMIT_REACHED')
            break
        end
    end

    state.revision = state.revision + 1
    local batch = {}
    for index = event_start, #state.events do
        batch[#batch + 1] = state.events[index]
    end
    return result_ok({
        state = state,
        events = batch,
        finished = is_terminal(state),
        result = state.result,
    })
end

function CombatAggregate.get_public_view(state)
    if type_value(state) ~= 'table' then
        return invalid('STATE_REQUIRED')
    end
    local actors = {}
    local index
    for index = 1, #state.actor_order do
        local actor = state.actors[state.actor_order[index]]
        actors[#actors + 1] = {
            actor_id = actor.actor_id,
            side = actor.side,
            position_index = actor.position_index,
            alive_state = actor.alive_state,
            current_hp = actor.current_hp,
            max_hp = actor.max_hp,
            current_qi = actor.current_qi,
            max_qi = actor.max_qi,
            gauge = actor.gauge,
            speed = actor.speed,
        }
    end
    return result_ok({
        combat_id = state.combat_id,
        phase = state.phase,
        revision = state.revision,
        action_index = state.action_index,
        current_tick = state.current_tick,
        control_policy = state.control_policy,
        actors = actors,
        result = state.result,
    })
end

CombatAggregate.PHASE = PHASE

return CombatAggregate
