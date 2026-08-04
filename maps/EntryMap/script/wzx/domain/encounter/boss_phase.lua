-- Pure boss phase controller for system 07.
-- ONE_WAY sequential phases; each phase enters at most once; healing never rolls back.

local Result = require 'wzx.domain.common.result'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local BossPhase = {}
local get_metatable = getmetatable
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

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

local function copy_phase(phase)
    local flag_updates = {}
    local index
    for index = 1, #phase.mechanic_flag_updates do
        local row = phase.mechanic_flag_updates[index]
        flag_updates[index] = {
            flag_key = row.flag_key,
            flag_value = row.flag_value,
        }
    end
    return {
        id = phase.id,
        schema_version = phase.schema_version,
        rules_version = phase.rules_version,
        phase_index = phase.phase_index,
        trigger = phase.trigger,
        trigger_value = phase.trigger_value,
        trigger_flag_key = phase.trigger_flag_key,
        on_enter_effect_bundle_id = phase.on_enter_effect_bundle_id,
        add_move_ids = copy_strings(phase.add_move_ids),
        remove_move_ids = copy_strings(phase.remove_move_ids),
        ai_profile_override_id = phase.ai_profile_override_id,
        immunity_profile_override_id = phase.immunity_profile_override_id,
        mechanic_flag_updates = flag_updates,
        summon_request_ids = copy_strings(phase.summon_request_ids),
        presentation_cue_id = phase.presentation_cue_id,
        persist_once_entered = phase.persist_once_entered,
    }
end

local function trigger_met(phase, context)
    if phase.trigger == 'HP_AT_OR_BELOW_BP' then
        return context.hp_bp <= phase.trigger_value
    end
    if phase.trigger == 'ACTION_INDEX' then
        return context.action_index >= phase.trigger_value
    end
    if phase.trigger == 'MECHANIC_FLAG' then
        local flags = context.mechanic_flags
        if type_value(flags) ~= 'table' then
            return false
        end
        local current = flags[phase.trigger_flag_key]
        return current == phase.trigger_value
    end
    return false
end

--- Build a sealed runtime plan from controller + ordered phase definitions.
-- @param input {
--   controller = BossControllerDefinition,
--   phases = BossPhaseDefinition[] (same order as controller.phase_ids),
--   boss_actor_id = string,
--   move_library = { [move_id] = move_spec }?,
-- }
function BossPhase.create_runtime(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local controller = raw_get(input, 'controller')
    local phases = raw_get(input, 'phases')
    local boss_actor_id = raw_get(input, 'boss_actor_id')
    local move_library = raw_get(input, 'move_library')
    if type_value(controller) ~= 'table' or get_metatable(controller) ~= nil then
        return invalid('CONTROLLER_REQUIRED')
    end
    if type_value(phases) ~= 'table' or get_metatable(phases) ~= nil then
        return invalid('PHASES_REQUIRED')
    end
    if type_value(boss_actor_id) ~= 'string' or boss_actor_id == '' then
        return invalid('BOSS_ACTOR_ID_REQUIRED')
    end
    if #phases ~= #controller.phase_ids then
        return fail(
            EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
            'PHASE_COUNT_MISMATCH',
            {
                controller_id = controller.id,
                expected = #controller.phase_ids,
                actual = #phases,
            }
        )
    end
    if controller.phase_transition_policy ~= 'ONE_WAY' then
        return fail(
            EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
            'PHASE_POLICY_UNSUPPORTED',
            { policy = controller.phase_transition_policy }
        )
    end

    local ordered = {}
    local by_index = {}
    local index
    for index = 1, #phases do
        local phase = phases[index]
        if type_value(phase) ~= 'table' then
            return invalid('PHASE_ENTRY_INVALID', { index = index })
        end
        if phase.id ~= controller.phase_ids[index] then
            return fail(
                EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
                'PHASE_ID_ORDER_MISMATCH',
                {
                    index = index,
                    expected = controller.phase_ids[index],
                    actual = phase.id,
                }
            )
        end
        if phase.phase_index ~= index then
            return fail(
                EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
                'PHASE_INDEX_NOT_SEQUENTIAL',
                {
                    phase_id = phase.id,
                    expected = index,
                    actual = phase.phase_index,
                }
            )
        end
        if by_index[phase.phase_index] ~= nil then
            return fail(
                EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
                'DUPLICATE_PHASE_INDEX',
                { phase_index = phase.phase_index }
            )
        end
        -- HP thresholds must strictly decrease across HP-triggered phases after phase 1.
        if index > 1
            and phase.trigger == 'HP_AT_OR_BELOW_BP'
            and ordered[index - 1] ~= nil
            and ordered[index - 1].trigger == 'HP_AT_OR_BELOW_BP'
            and phase.trigger_value >= ordered[index - 1].trigger_value
        then
            return fail(
                EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
                'HP_THRESHOLD_NOT_DECREASING',
                {
                    phase_id = phase.id,
                    trigger_value = phase.trigger_value,
                    previous = ordered[index - 1].trigger_value,
                }
            )
        end
        local copied = copy_phase(phase)
        ordered[index] = copied
        by_index[phase.phase_index] = copied
    end

    local library = {}
    if move_library ~= nil then
        if type_value(move_library) ~= 'table' or get_metatable(move_library) ~= nil then
            return invalid('MOVE_LIBRARY_INVALID')
        end
        local move_id
        local move
        for move_id, move in pairs(move_library) do
            if type_value(move_id) == 'string' and type_value(move) == 'table' then
                library[move_id] = move
            end
        end
    end

    -- Phase 1 is always the initial entered phase (combat start).
    local entered = { [1] = true }
    local entered_order = { ordered[1].id }

    local runtime = {
        controller_id = controller.id,
        boss_spawn_id = controller.boss_spawn_id,
        boss_actor_id = boss_actor_id,
        phase_transition_policy = controller.phase_transition_policy,
        enrage_action_index = controller.enrage_action_index,
        phase_event_budget = controller.phase_event_budget,
        boss_bar_style_id = controller.boss_bar_style_id,
        phases = ordered,
        move_library = library,
        entered_phase_indexes = entered,
        entered_phase_ids = entered_order,
        current_phase_index = 1,
        mechanic_flags = {},
        enraged = false,
        phase_enter_count = 1,
        revision = 1,
    }
    -- Duck-typed ports for combat aggregate (06 must not require this module).
    runtime.try_enter_next = function(self, context)
        return BossPhase.try_enter_next(self, context)
    end
    runtime.get_public_view = function(self)
        return BossPhase.get_public_view(self)
    end
    return result_ok(runtime)
end

function BossPhase.hp_bp(current_hp, max_hp)
    if type_value(current_hp) ~= 'number' or type_value(max_hp) ~= 'number' then
        return 0
    end
    if max_hp <= 0 then
        return 0
    end
    if current_hp <= 0 then
        return 0
    end
    if current_hp >= max_hp then
        return 10000
    end
    return math_floor(current_hp * 10000 / max_hp)
end

--- Evaluate at a combat safe boundary. Enters at most one next phase per call.
-- Caller must re-invoke after applying transition if multi-threshold was crossed.
-- @param runtime from create_runtime
-- @param context { current_hp, max_hp, boss_alive, action_index, mechanic_flags? }
function BossPhase.try_enter_next(runtime, context)
    if type_value(runtime) ~= 'table' or get_metatable(runtime) ~= nil then
        return invalid('RUNTIME_REQUIRED')
    end
    if type_value(context) ~= 'table' or get_metatable(context) ~= nil then
        return invalid('CONTEXT_REQUIRED')
    end
    if context.boss_alive ~= true then
        return result_ok({
            entered = false,
            reason = 'BOSS_NOT_ALIVE',
            enraged = false,
        })
    end

    local action_index = raw_get(context, 'action_index')
    if type_value(action_index) ~= 'number' or action_index ~= math_floor(action_index) then
        return invalid('ACTION_INDEX_INVALID')
    end

    local enraged_now = false
    if runtime.enrage_action_index ~= nil
        and runtime.enraged ~= true
        and action_index >= runtime.enrage_action_index
    then
        runtime.enraged = true
        runtime.mechanic_flags.enraged = 1
        enraged_now = true
        runtime.revision = runtime.revision + 1
    end

    local next_index = runtime.current_phase_index + 1
    local next_phase = runtime.phases[next_index]
    if next_phase == nil then
        return result_ok({
            entered = false,
            reason = 'NO_MORE_PHASES',
            enraged = enraged_now,
        })
    end
    if runtime.entered_phase_indexes[next_index] == true then
        return result_ok({
            entered = false,
            reason = 'ALREADY_ENTERED',
            enraged = enraged_now,
        })
    end

    local hp_bp = BossPhase.hp_bp(context.current_hp, context.max_hp)
    local flags = runtime.mechanic_flags
    if type_value(context.mechanic_flags) == 'table' then
        flags = context.mechanic_flags
    end
    local eval_context = {
        hp_bp = hp_bp,
        action_index = action_index,
        mechanic_flags = flags,
    }
    if not trigger_met(next_phase, eval_context) then
        return result_ok({
            entered = false,
            reason = 'TRIGGER_NOT_MET',
            hp_bp = hp_bp,
            enraged = enraged_now,
        })
    end

    -- Enter exactly one phase (ONE_WAY). Multi-threshold requires re-evaluate.
    runtime.entered_phase_indexes[next_index] = true
    runtime.entered_phase_ids[#runtime.entered_phase_ids + 1] = next_phase.id
    runtime.current_phase_index = next_index
    runtime.phase_enter_count = runtime.phase_enter_count + 1
    runtime.revision = runtime.revision + 1

    local flag_index
    for flag_index = 1, #next_phase.mechanic_flag_updates do
        local row = next_phase.mechanic_flag_updates[flag_index]
        runtime.mechanic_flags[row.flag_key] = row.flag_value
    end

    return result_ok({
        entered = true,
        phase = next_phase,
        phase_index = next_index,
        hp_bp = hp_bp,
        enraged = enraged_now,
        reason = next_phase.trigger,
    })
end

function BossPhase.get_public_view(runtime)
    if type_value(runtime) ~= 'table' then
        return invalid('RUNTIME_REQUIRED')
    end
    local entered = {}
    local index
    for index = 1, #runtime.entered_phase_ids do
        entered[index] = runtime.entered_phase_ids[index]
    end
    local flags = {}
    local key
    local value
    for key, value in pairs(runtime.mechanic_flags) do
        flags[key] = value
    end
    return result_ok({
        controller_id = runtime.controller_id,
        boss_actor_id = runtime.boss_actor_id,
        current_phase_index = runtime.current_phase_index,
        current_phase_id = runtime.phases[runtime.current_phase_index]
            and runtime.phases[runtime.current_phase_index].id
            or nil,
        entered_phase_ids = entered,
        enraged = runtime.enraged == true,
        mechanic_flags = flags,
        revision = runtime.revision,
    })
end

return BossPhase
