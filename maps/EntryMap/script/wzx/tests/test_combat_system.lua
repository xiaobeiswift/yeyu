local Harness = require 'wzx.tests.harness'
local ParkMiller = require 'wzx.domain.common.park_miller_rng'
local CombatAggregate = require 'wzx.domain.combat.combat_aggregate'
local CombatService = require 'wzx.application.use_cases.combat.combat_service'
local Damage = require 'wzx.domain.combat.damage'
local Rules = require 'wzx.domain.combat.rules'
local Timeline = require 'wzx.domain.combat.timeline'

local case = Harness.case
local assert = Harness.assert
local HASH_A = string.rep('a', 64)

local function stats(overrides)
    local value = {
        max_hp = 100,
        attack = 50,
        defense = 10,
        speed = 100,
        accuracy = 8000,
        evasion = 0,
        crit_chance_bp = 0,
        crit_damage_bp = 15000,
        crit_resist_bp = 0,
        block_chance_bp = 0,
        block_reduction_bp = 5000,
        damage_bonus_bp = 0,
        damage_reduction_bp = 0,
        healing_bonus_bp = 0,
        healing_received_bp = 0,
        max_qi = 100,
        initial_qi = 0,
        qi_gain_bp = 10000,
        effect_accuracy = 0,
        effect_resistance = 0,
    }
    if overrides ~= nil then
        local key
        local item
        for key, item in pairs(overrides) do
            value[key] = item
        end
    end
    return value
end

local function combatant(side, actor_id, definition_id, position_index, overrides)
    overrides = overrides or {}
    local member = {
        actor_id = actor_id,
        definition_id = definition_id,
        side = side,
        position_index = position_index,
        level = 5,
        tags = side == 'ATTACKER' and { 'hero', 'human' } or { 'bandit', 'human' },
        stats = stats(overrides.stats),
        martial_loadout = overrides.martial_loadout or {
            basic_attack = {
                move_id = 'move_basic_' .. side:lower(),
                qi_cost = 0,
                action_cooldown = 0,
                on_hit_qi_gain = 5,
                damage = {
                    damage_type = 'PHYSICAL',
                    attack_ratio_bp = 10000,
                    flat_damage = 0,
                    hit_mode = 'UNMISSABLE',
                    variance_min_bp = 10000,
                    variance_max_bp = 10000,
                    can_crit = false,
                    can_block = false,
                    minimum_damage = 1,
                },
            },
        },
        initial_status_ids = {},
        ai_profile_id = side == 'ATTACKER' and 'ai_story_player' or 'ai_bandit_melee',
        source_revision = 1,
        source_hash = HASH_A,
    }
    return member
end

local function snapshot(overrides)
    overrides = overrides or {}
    return {
        snapshot_schema_version = 1,
        rules_version = 1,
        combat_kind = overrides.combat_kind or 'PVE_ENCOUNTER',
        encounter_id = 'encounter_test_bridge',
        attacker_formation = {
            members = overrides.attackers or {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 120, attack = 40, max_hp = 80 },
                }),
            },
        },
        defender_formation = {
            members = overrides.defenders or {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 80, attack = 20, max_hp = 60, defense = 5 },
                }),
            },
        },
        environment_spec_id = nil,
        control_policy = overrides.control_policy or 'AUTO_ALL',
        seed = overrides.seed or 7,
        action_limit = overrides.action_limit or 99,
        event_budget = overrides.event_budget or 10000,
        source_hashes = {
            attacker = HASH_A,
            defender = HASH_A,
        },
        snapshot_hash = HASH_A,
    }
end

local function start_combat(overrides)
    local started = CombatAggregate.start({
        combat_id = 'cbt1',
        snapshot = snapshot(overrides),
    })
    assert.equal(started.ok, true, 'start combat')
    return started.value
end

local function event_types(events)
    local types = {}
    local index
    for index = 1, #events do
        types[index] = events[index].event_type
    end
    return types
end

local function has_event(events, event_type)
    local index
    for index = 1, #events do
        if events[index].event_type == event_type then
            return true
        end
    end
    return false
end

return {
    case('damage formula unmissable path is deterministic without rng draws', function()
        local prng = ParkMiller.new(1)
        assert.equal(prng.ok, true)
        local resolved = Damage.resolve_hit(
            { attack = 100, accuracy = 0, damage_bonus_bp = 0, crit_chance_bp = 0 },
            { defense = 20, evasion = 0, damage_reduction_bp = 0, block_chance_bp = 0, crit_resist_bp = 0 },
            {
                damage_type = 'PHYSICAL',
                attack_ratio_bp = 10000,
                flat_damage = 0,
                hit_mode = 'UNMISSABLE',
                penetration_flat = 0,
                penetration_bp = 0,
                damage_bonus_bp = 0,
                variance_min_bp = 10000,
                variance_max_bp = 10000,
                can_crit = false,
                can_block = false,
                minimum_damage = 1,
            },
            prng.value
        )
        assert.equal(resolved.ok, true)
        assert.equal(resolved.value.hit, true)
        assert.equal(prng.value.draw_count, 0)
        -- base 100, def 20, scale 20 => mitigated floor(100 * 10000 / (10000 + 400)) = floor(1000000/10400)=96
        assert.equal(resolved.value.final_damage, 96)
    end),

    case('timeline prefers higher speed then seed-preferred side', function()
        local state = {
            current_tick = 0,
            tie_preferred_side = 'ATTACKER',
            actors = {
                slow = {
                    actor_id = 'slow',
                    side = 'DEFENDER',
                    position_index = 0,
                    speed = 50,
                    gauge = 0,
                    alive_state = 'ALIVE',
                },
                fast = {
                    actor_id = 'fast',
                    side = 'ATTACKER',
                    position_index = 1,
                    speed = 200,
                    gauge = 0,
                    alive_state = 'ALIVE',
                },
            },
        }
        local selected = Timeline.select_next_actor(state)
        assert.equal(selected.ok, true)
        assert.equal(selected.value.actor.actor_id, 'fast')
        assert.equal(state.current_tick > 0, true)
        assert.equal(state.actors.fast.gauge >= Rules.GAUGE_THRESHOLD, true)
    end),

    case('auto combat finishes with attacker wipe or defender wipe', function()
        local state = start_combat({ action_limit = 99, seed = 3 })
        local advanced = CombatAggregate.apply_command(state, {
            command_id = 'cmd1',
            command_type = 'ADVANCE',
            expected_revision = 1,
        })
        assert.equal(advanced.ok, true)
        assert.equal(advanced.value.finished, true)
        assert.not_nil(advanced.value.result)
        local outcome = advanced.value.result.outcome
        assert.equal(
            outcome == 'ATTACKER_WIN' or outcome == 'DEFENDER_WIN' or outcome == 'TIMEOUT',
            true
        )
        assert.equal(has_event(state.events, 'CombatStarted'), true)
        assert.equal(has_event(state.events, 'CombatFinished'), true)
        assert.equal(has_event(state.events, 'DamageApplied') or has_event(state.events, 'AttackMissed'), true)
    end),

    case('same snapshot and seed produce identical result and event hash', function()
        local a = start_combat({ seed = 42, action_limit = 99 })
        local b = start_combat({ seed = 42, action_limit = 99 })
        local ra = CombatAggregate.apply_command(a, {
            command_id = 'cmd1',
            command_type = 'ADVANCE',
        })
        local rb = CombatAggregate.apply_command(b, {
            command_id = 'cmd1',
            command_type = 'ADVANCE',
        })
        assert.equal(ra.ok, true)
        assert.equal(rb.ok, true)
        assert.equal(ra.value.result.outcome, rb.value.result.outcome)
        assert.equal(ra.value.result.event_hash, rb.value.result.event_hash)
        assert.equal(ra.value.result.action_count, rb.value.result.action_count)
        assert.equal(ra.value.result.prng_draw_count, rb.value.result.prng_draw_count)
        assert.equal(#a.events, #b.events)
        local index
        for index = 1, #a.events do
            assert.equal(a.events[index].event_type, b.events[index].event_type)
        end
    end),

    case('action limit 1 times out as defender win', function()
        local state = start_combat({
            seed = 9,
            action_limit = 1,
            attackers = {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 100, attack = 1, max_hp = 500 },
                }),
            },
            defenders = {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 100, attack = 1, max_hp = 500 },
                }),
            },
        })
        local advanced = CombatAggregate.apply_command(state, {
            command_id = 'cmd_timeout',
            command_type = 'ADVANCE',
        })
        assert.equal(advanced.ok, true)
        assert.equal(advanced.value.result.outcome, 'TIMEOUT')
        assert.equal(advanced.value.result.winner_side, 'DEFENDER')
        assert.equal(advanced.value.result.action_count, 1)
        assert.equal(has_event(state.events, 'CombatFinished'), true)
    end),

    case('forfeit ends as attacker forfeit', function()
        local state = start_combat({ seed = 2 })
        local result = CombatAggregate.apply_command(state, {
            command_id = 'cmd_forfeit',
            command_type = 'FORFEIT',
            expected_revision = 1,
        })
        assert.equal(result.ok, true)
        assert.equal(result.value.result.outcome, 'ATTACKER_FORFEIT')
        assert.equal(result.value.result.winner_side, 'DEFENDER')
        assert.equal(state.phase, CombatAggregate.PHASE.FINISHED)
    end),

    case('item commands are rejected before state mutation', function()
        local state = start_combat({ seed = 2 })
        local revision = state.revision
        local event_count = #state.events
        local rejected = CombatAggregate.apply_command(state, {
            command_id = 'cmd_item',
            command_type = 'USE_ITEM',
        })
        assert.equal(rejected.ok, false)
        assert.equal(rejected.error.code, 'COMBAT_ITEM_USE_UNSUPPORTED')
        assert.equal(state.revision, revision)
        assert.equal(#state.events, event_count)
        assert.equal(state.phase, CombatAggregate.PHASE.RUNNING)
    end),

    case('revision conflict and duplicate command id fail closed', function()
        local state = start_combat({ seed = 5, action_limit = 1 })
        local first = CombatAggregate.apply_command(state, {
            command_id = 'cmd_once',
            command_type = 'ADVANCE',
            expected_revision = 1,
        })
        assert.equal(first.ok, true)
        local replay = CombatAggregate.apply_command(state, {
            command_id = 'cmd_once',
            command_type = 'ADVANCE',
        })
        assert.equal(replay.ok, false)
        assert.equal(replay.error.code, 'COMBAT_COMMAND_IDEMPOTENT_REPLAY')

        local fresh = start_combat({ seed = 5, action_limit = 1 })
        local conflict = CombatAggregate.apply_command(fresh, {
            command_id = 'cmd_bad_rev',
            command_type = 'ADVANCE',
            expected_revision = 99,
        })
        assert.equal(conflict.ok, false)
        assert.equal(conflict.error.code, 'COMBAT_REVISION_CONFLICT')
    end),

    case('faster attacker acts first and can finish fight in few actions', function()
        local state = start_combat({
            seed = 11,
            attackers = {
                combatant('ATTACKER', 'atk1', 'char_hero', 0, {
                    stats = { speed = 300, attack = 80, max_hp = 100 },
                }),
            },
            defenders = {
                combatant('DEFENDER', 'def1', 'enemy_bandit', 0, {
                    stats = { speed = 10, attack = 5, max_hp = 40, defense = 0 },
                }),
            },
        })
        local advanced = CombatAggregate.apply_command(state, {
            command_id = 'cmd_fast',
            command_type = 'ADVANCE',
        })
        assert.equal(advanced.ok, true)
        assert.equal(advanced.value.result.outcome, 'ATTACKER_WIN')
        -- first ready actor should be attacker
        local types = event_types(state.events)
        local first_ready
        local index
        for index = 1, #state.events do
            if state.events[index].event_type == 'ActorReady' then
                first_ready = state.events[index].payload.actor_id
                break
            end
        end
        assert.equal(first_ready, 'atk1')
        assert.equal(types[1], 'CombatCreated')
    end),

    case('combat service start and advance expose public session', function()
        local created = CombatService.new()
        assert.equal(created.ok, true)
        local service = created.value
        local started = service:start_session({
            combat_id = 'cbt2',
            snapshot = snapshot({ seed = 13 }),
        })
        assert.equal(started.ok, true)
        assert.equal(started.value.session.phase, 'RUNNING')
        assert.equal(#started.value.session.actors, 2)
        local advanced = service:advance({ command_id = 'svc_cmd1' })
        assert.equal(advanced.ok, true)
        assert.equal(advanced.value.finished, true)
        assert.not_nil(advanced.value.result.event_hash)
        local view = service:get_session()
        assert.equal(view.ok, true)
        assert.equal(view.value.phase == 'FINISHED' or view.value.phase == 'INVALID', true)
    end),

    case('seed parity sets tie preferred side without consuming rng', function()
        assert.equal(Rules.tie_preferred_side(1), 'ATTACKER')
        assert.equal(Rules.tie_preferred_side(2), 'DEFENDER')
        local odd = start_combat({ seed = 1 })
        local even = start_combat({ seed = 2 })
        assert.equal(odd.tie_preferred_side, 'ATTACKER')
        assert.equal(even.tie_preferred_side, 'DEFENDER')
        assert.equal(odd.prng.draw_count, 0)
        assert.equal(even.prng.draw_count, 0)
    end),

    case('invalid snapshot is rejected', function()
        local bad = CombatAggregate.start({
            combat_id = 'cbt3',
            snapshot = snapshot({ control_policy = 'AUTO_ALL', combat_kind = 'ARENA_RANKED' }),
        })
        -- arena requires AUTO_ALL which we set; use bad seed instead
        bad = CombatAggregate.start({
            combat_id = 'cbt3',
            snapshot = {
                snapshot_schema_version = 1,
                rules_version = 1,
                combat_kind = 'PVE_ENCOUNTER',
                encounter_id = 'encounter_test_bridge',
                attacker_formation = { members = {} },
                defender_formation = { members = {
                    combatant('DEFENDER', 'def1', 'enemy_bandit', 0),
                } },
                control_policy = 'AUTO_ALL',
                seed = 1,
                action_limit = 99,
                event_budget = 1000,
                source_hashes = { a = HASH_A },
                snapshot_hash = HASH_A,
            },
        })
        assert.equal(bad.ok, false)
        assert.equal(bad.error.code, 'COMBAT_SNAPSHOT_INVALID')
    end),
}
