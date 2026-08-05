-- Offline quest session authority for system 14.
-- Holds active/terminal runs, objective progress, and event-receipt dedupe.

local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local FactProjector = require 'wzx.domain.quest.fact_projector'
local QuestErrorCodes = require 'wzx.domain.quest.error_codes'

local QuestSession = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local math_floor = math.floor
local math_min = math.min
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local MAX_ACTIVE_RUNS = 100
local MAX_TRACKED = 3
local TERMINAL = {
    COMPLETED = true,
    FAILED = true,
    ABANDONED = true,
    EXPIRED = true,
}
local OPEN = {
    ACTIVE = true,
    READY_TO_TURN_IN = true,
    COMPLETING = true,
    RECOVERY_REQUIRED = true,
}
local TRACKABLE = {
    ACTIVE = true,
    READY_TO_TURN_IN = true,
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.quest.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(QuestErrorCodes.QUEST_ARGUMENT_INVALID, reason, details)
end

function QuestSession.empty()
    return {
        session_revision = 0,
        runs = {},
        objectives = {},
        event_receipts = {},
        command_receipts = {},
        tracked_run_ids = {},
        -- Stable set of revealed HIDDEN_UNTIL_REVEALED quest ids.
        revealed_hidden_quests = {},
    }
end

local function copy_objective(row)
    return {
        run_id = row.run_id,
        objective_id = row.objective_id,
        progress = row.progress,
        status = row.status,
        last_fact_event_id = row.last_fact_event_id,
        state_revision = row.state_revision,
    }
end

local function copy_run(run)
    return {
        run_id = run.run_id,
        quest_id = run.quest_id,
        definition_version = run.definition_version,
        status = run.status,
        current_stage_id = run.current_stage_id,
        accept_receipt_id = run.accept_receipt_id,
        completion_receipt_id = run.completion_receipt_id,
        reward_receipt_id = run.reward_receipt_id,
        quest_revision = run.quest_revision,
        stage_entry_ordinal = run.stage_entry_ordinal,
        reward_policy = run.reward_policy,
        reward_id = run.reward_id,
        turn_in_npc_id = run.turn_in_npc_id,
        abandon_policy = run.abandon_policy,
        category = run.category,
        source_event_id = run.source_event_id,
        prerequisite_quest_id = run.prerequisite_quest_id,
    }
end

local function objective_key(run_id, objective_id)
    return run_id .. '|' .. objective_id
end

local function list_run_ids(session)
    local ids = {}
    local run_id
    for run_id in raw_next, session.runs do
        ids[#ids + 1] = run_id
    end
    table_sort(ids, bytewise_string_less)
    return ids
end

local function count_open_runs(session)
    local count = 0
    local run_id
    local run
    for run_id, run in raw_next, session.runs do
        if OPEN[run.status] then
            count = count + 1
        end
    end
    return count
end

local function find_open_run_for_quest(session, quest_id)
    local run_id
    local run
    for run_id, run in raw_next, session.runs do
        if run.quest_id == quest_id and OPEN[run.status] then
            return run
        end
    end
    return nil
end

local function find_completed_run_for_quest(session, quest_id)
    local run_id
    local run
    for run_id, run in raw_next, session.runs do
        if run.quest_id == quest_id and run.status == 'COMPLETED' then
            return run
        end
    end
    return nil
end

local function ensure_tracked_table(session)
    if type_value(session.tracked_run_ids) ~= 'table' then
        session.tracked_run_ids = {}
    end
    return session.tracked_run_ids
end

local function list_tracking_slots(session)
    local tracked = ensure_tracked_table(session)
    local slots = {}
    local position
    for position = 1, MAX_TRACKED do
        local run_id = tracked[position]
        if type_value(run_id) == 'string' and run_id ~= '' then
            local run = session.runs[run_id]
            slots[#slots + 1] = {
                tracking_position = position,
                run_id = run_id,
                quest_id = run and run.quest_id or nil,
                status = run and run.status or nil,
            }
        end
    end
    return slots
end

local function clear_tracking_for_run(session, run_id)
    local tracked = ensure_tracked_table(session)
    local cleared = {}
    local position
    for position = 1, MAX_TRACKED do
        if tracked[position] == run_id then
            tracked[position] = nil
            cleared[#cleared + 1] = position
        end
    end
    return cleared
end

local function find_tracking_position(session, run_id)
    local tracked = ensure_tracked_table(session)
    local position
    for position = 1, MAX_TRACKED do
        if tracked[position] == run_id then
            return position
        end
    end
    return nil
end

local function count_tracked(session)
    local tracked = ensure_tracked_table(session)
    local count = 0
    local position
    for position = 1, MAX_TRACKED do
        if type_value(tracked[position]) == 'string' and tracked[position] ~= '' then
            count = count + 1
        end
    end
    return count
end

function QuestSession.has_completed_quest(session, quest_id)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return false
    end
    if type_value(quest_id) ~= 'string' or quest_id == '' then
        return false
    end
    return find_completed_run_for_quest(session, quest_id) ~= nil
end

-- Offline chain candidates: AUTO_EVENT quests whose prerequisite just completed.
-- Callers must still AcceptQuest (never insert runs from events alone).
function QuestSession.list_chain_candidates(session, catalog, completed_quest_id)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.list) ~= 'function' then
        return invalid('CATALOG_REQUIRED')
    end
    local quest_check = validate_content(completed_quest_id, 'quest_', 'completed_quest_id')
    if not quest_check.ok then
        return invalid('COMPLETED_QUEST_ID_INVALID')
    end
    if not QuestSession.has_completed_quest(session, completed_quest_id) then
        return result_ok({ candidates = {} })
    end

    local listed = catalog:list('quest_definitions')
    if not listed.ok then
        return listed
    end

    local candidates = {}
    local index
    for index = 1, #listed.value do
        local quest = listed.value[index]
        if quest.deprecated ~= true
            and quest.accept_policy == 'AUTO_EVENT'
            and quest.prerequisite_quest_id == completed_quest_id
            and find_open_run_for_quest(session, quest.id) == nil
            and find_completed_run_for_quest(session, quest.id) == nil
        then
            candidates[#candidates + 1] = {
                quest_id = quest.id,
                accept_policy = quest.accept_policy,
                prerequisite_quest_id = quest.prerequisite_quest_id,
                category = quest.category,
            }
        end
    end
    table_sort(candidates, function(left, right)
        return bytewise_string_less(left.quest_id, right.quest_id)
    end)
    return result_ok({ candidates = candidates })
end

local function build_stage_objectives(session, catalog, run, stage)
    local created = {}
    local index
    for index = 1, #stage.objective_ids do
        local objective_id = stage.objective_ids[index]
        local objective = catalog:require_objective(objective_id)
        if not objective.ok then
            return objective
        end
        local key = objective_key(run.run_id, objective_id)
        local row = {
            run_id = run.run_id,
            objective_id = objective_id,
            progress = 0,
            status = 'IN_PROGRESS',
            last_fact_event_id = nil,
            state_revision = 1,
        }
        session.objectives[key] = row
        created[#created + 1] = copy_objective(row)
    end
    return result_ok(created)
end

local function stage_complete(session, catalog, run, stage)
    local required_ids = {}
    local index
    for index = 1, #stage.objective_ids do
        local objective = catalog:require_objective(stage.objective_ids[index])
        if not objective.ok then
            return objective
        end
        if objective.value.optional ~= true then
            required_ids[#required_ids + 1] = stage.objective_ids[index]
        end
    end

    local complete_count = 0
    for index = 1, #required_ids do
        local key = objective_key(run.run_id, required_ids[index])
        local row = session.objectives[key]
        if row ~= nil and row.status == 'COMPLETE' then
            complete_count = complete_count + 1
        end
    end

    if stage.completion_mode == 'ANY' then
        return result_ok(complete_count >= 1)
    end
    if stage.completion_mode == 'COUNT' then
        return result_ok(complete_count >= (stage.completion_count or 1))
    end
    return result_ok(complete_count >= #required_ids and #required_ids > 0)
end

local function enter_ready_or_complete(session, catalog, run)
    local quest = catalog:require_quest(run.quest_id)
    if not quest.ok then
        return quest
    end
    quest = quest.value
    if quest.reward_policy == 'TURN_IN_NPC' then
        run.status = 'READY_TO_TURN_IN'
        run.quest_revision = run.quest_revision + 1
        session.session_revision = session.session_revision + 1
        return result_ok({
            status = run.status,
            completed = false,
        })
    end
    -- AUTO_ON_COMPLETE / NO_REWARD mark ready for complete_run.
    run.status = 'READY_TO_TURN_IN'
    run.quest_revision = run.quest_revision + 1
    session.session_revision = session.session_revision + 1
    return result_ok({
        status = run.status,
        completed = false,
        auto_complete = quest.reward_policy ~= 'TURN_IN_NPC',
    })
end

local function advance_stage_if_needed(session, catalog, run)
    local stage = catalog:require_stage(run.current_stage_id)
    if not stage.ok then
        return stage
    end
    stage = stage.value
    local done = stage_complete(session, catalog, run, stage)
    if not done.ok then
        return done
    end
    if not done.value then
        return result_ok({ advanced = false })
    end

    if stage.next_stage_id == nil then
        local ready = enter_ready_or_complete(session, catalog, run)
        if not ready.ok then
            return ready
        end
        return result_ok({
            advanced = false,
            stage_finished = true,
            ready = ready.value,
        })
    end

    local next_stage = catalog:require_stage(stage.next_stage_id)
    if not next_stage.ok then
        return next_stage
    end
    next_stage = next_stage.value
    local from_stage = run.current_stage_id
    run.current_stage_id = next_stage.id
    run.stage_entry_ordinal = run.stage_entry_ordinal + 1
    run.quest_revision = run.quest_revision + 1
    session.session_revision = session.session_revision + 1
    local created = build_stage_objectives(session, catalog, run, next_stage)
    if not created.ok then
        return created
    end
    return result_ok({
        advanced = true,
        from_stage_id = from_stage,
        to_stage_id = next_stage.id,
        objectives = created.value,
    })
end

function QuestSession.accept(session, catalog, input)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require_quest) ~= 'function' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local quest_id = raw_get(input, 'quest_id')
    local run_id = raw_get(input, 'run_id')
    local accept_receipt_id = raw_get(input, 'accept_receipt_id')
    local command_id = raw_get(input, 'command_id')

    local run_check = validate_derived(run_id, 'run_id')
    if not run_check.ok then
        return invalid('RUN_ID_INVALID')
    end
    local receipt_check = validate_derived(accept_receipt_id, 'accept_receipt_id')
    if not receipt_check.ok then
        return invalid('ACCEPT_RECEIPT_INVALID')
    end
    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = session.command_receipts[command_id]
        if prior ~= nil then
            return result_ok({
                run = copy_run(session.runs[prior.run_id]),
                already_accepted = true,
                command_replay = true,
            })
        end
    end

    local quest = catalog:require_quest(quest_id)
    if not quest.ok then
        return quest
    end
    quest = quest.value
    if quest.accept_policy == 'BOARD' then
        return fail(QuestErrorCodes.QUEST_ACCEPT_DENIED, 'BOARD_OFFER_REQUIRED')
    end
    if quest.accept_policy == 'AUTO_EVENT' then
        local source_event_id = raw_get(input, 'source_event_id')
        if type_value(source_event_id) ~= 'string' or source_event_id == '' then
            return fail(
                QuestErrorCodes.QUEST_ACCEPT_DENIED,
                'AUTO_EVENT_SOURCE_REQUIRED',
                { quest_id = quest_id }
            )
        end
    end

    local existing = find_open_run_for_quest(session, quest_id)
    if existing ~= nil then
        return fail(QuestErrorCodes.QUEST_ALREADY_ACTIVE, 'QUEST_ALREADY_ACTIVE', {
            run_id = existing.run_id,
            quest_id = quest_id,
        })
    end
    -- V1 non-repeatable: a COMPLETED run blocks re-accept.
    local completed_run = find_completed_run_for_quest(session, quest_id)
    if completed_run ~= nil then
        return fail(QuestErrorCodes.QUEST_ALREADY_COMPLETED, 'QUEST_ALREADY_COMPLETED', {
            run_id = completed_run.run_id,
            quest_id = quest_id,
        })
    end
    if quest.prerequisite_quest_id ~= nil
        and not QuestSession.has_completed_quest(session, quest.prerequisite_quest_id)
    then
        return fail(
            QuestErrorCodes.QUEST_PREREQUISITE_MISSING,
            'PREREQUISITE_QUEST_INCOMPLETE',
            {
                quest_id = quest_id,
                prerequisite_quest_id = quest.prerequisite_quest_id,
            }
        )
    end
    if session.runs[run_id] ~= nil then
        return fail(QuestErrorCodes.QUEST_RECEIPT_CONFLICT, 'RUN_ID_REUSED', {
            run_id = run_id,
        })
    end
    if count_open_runs(session) >= MAX_ACTIVE_RUNS then
        return fail(QuestErrorCodes.QUEST_ACTIVE_LIMIT_REACHED, 'ACTIVE_LIMIT')
    end

    local first_stage = catalog:require_stage(quest.first_stage_id)
    if not first_stage.ok then
        return first_stage
    end
    first_stage = first_stage.value

    local source_event_id = raw_get(input, 'source_event_id')
    local run = {
        run_id = run_id,
        quest_id = quest.id,
        definition_version = quest.definition_version,
        status = 'ACTIVE',
        current_stage_id = first_stage.id,
        accept_receipt_id = accept_receipt_id,
        completion_receipt_id = nil,
        reward_receipt_id = nil,
        quest_revision = 1,
        stage_entry_ordinal = 1,
        reward_policy = quest.reward_policy,
        reward_id = quest.reward_id,
        turn_in_npc_id = quest.turn_in_npc_id,
        abandon_policy = quest.abandon_policy,
        category = quest.category,
        source_event_id = source_event_id,
        prerequisite_quest_id = quest.prerequisite_quest_id,
    }
    session.runs[run_id] = run
    local objectives = build_stage_objectives(session, catalog, run, first_stage)
    if not objectives.ok then
        session.runs[run_id] = nil
        return objectives
    end
    if type_value(command_id) == 'string' and command_id ~= '' then
        session.command_receipts[command_id] = {
            command_id = command_id,
            run_id = run_id,
            kind = 'ACCEPT',
        }
    end
    session.session_revision = session.session_revision + 1
    return result_ok({
        run = copy_run(run),
        objectives = objectives.value,
        already_accepted = false,
        source_event_id = source_event_id,
    })
end

function QuestSession.consume_fact(session, catalog, event)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(event) ~= 'table' or get_metatable(event) ~= nil then
        return invalid('EVENT_REQUIRED')
    end
    local event_id = raw_get(event, 'event_id')
    local event_type = raw_get(event, 'event_type')
    if type_value(event_id) ~= 'string' or event_id == '' then
        return invalid('EVENT_ID_REQUIRED')
    end
    if type_value(event_type) ~= 'string' or event_type == '' then
        return invalid('EVENT_TYPE_REQUIRED')
    end
    if session.event_receipts[event_id] ~= nil then
        return result_ok({
            applied = false,
            duplicate = true,
            changes = {},
        })
    end

    local changes = {}
    local run_ids = list_run_ids(session)
    local run_index
    for run_index = 1, #run_ids do
        local run = session.runs[run_ids[run_index]]
        if run.status == 'ACTIVE' or run.status == 'READY_TO_TURN_IN' then
            local stage = catalog:require_stage(run.current_stage_id)
            if not stage.ok then
                return stage
            end
            stage = stage.value
            local obj_index
            for obj_index = 1, #stage.objective_ids do
                local objective_id = stage.objective_ids[obj_index]
                local objective = catalog:require_objective(objective_id)
                if not objective.ok then
                    return objective
                end
                objective = objective.value
                local projected = FactProjector.project(objective, event)
                if not projected.ok then
                    return projected
                end
                if projected.value.matched then
                    local key = objective_key(run.run_id, objective_id)
                    local row = session.objectives[key]
                    if row == nil then
                        return fail(
                            QuestErrorCodes.QUEST_CONFIG_BROKEN,
                            'OBJECTIVE_STATE_MISSING',
                            { run_id = run.run_id, objective_id = objective_id }
                        )
                    end
                    if row.status ~= 'COMPLETE' then
                        local applied = FactProjector.apply_delta(
                            row.progress,
                            objective.required_count,
                            projected.value.delta or 0,
                            objective.progress_semantics
                        )
                        if not applied.ok then
                            return applied
                        end
                        if applied.value.increased then
                            local old_progress = row.progress
                            row.progress = applied.value.progress
                            row.status = applied.value.status
                            row.last_fact_event_id = event_id
                            row.state_revision = row.state_revision + 1
                            run.quest_revision = run.quest_revision + 1
                            changes[#changes + 1] = {
                                run_id = run.run_id,
                                quest_id = run.quest_id,
                                objective_id = objective_id,
                                old_progress = old_progress,
                                new_progress = row.progress,
                                required_count = objective.required_count,
                                status = row.status,
                            }
                        end
                    end
                end
            end

            -- Stage advance may chain once per fact for terminal stage readiness.
            local advanced = advance_stage_if_needed(session, catalog, run)
            if not advanced.ok then
                return advanced
            end
            if advanced.value.advanced or advanced.value.stage_finished then
                changes[#changes + 1] = {
                    run_id = run.run_id,
                    quest_id = run.quest_id,
                    stage_transition = advanced.value,
                }
            end
            -- If auto-complete and READY, leave status for service complete_run.
        end
    end

    session.event_receipts[event_id] = {
        event_id = event_id,
        event_type = event_type,
        applied_change_count = #changes,
    }
    session.session_revision = session.session_revision + 1
    return result_ok({
        applied = #changes > 0,
        duplicate = false,
        changes = changes,
    })
end

-- Pure validation for completion/turn-in. Does not mutate session so application
-- can grant rewards first and only then commit COMPLETED.
function QuestSession.validate_complete(session, catalog, input)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local run_id = raw_get(input, 'run_id')
    local completion_receipt_id = raw_get(input, 'completion_receipt_id')
    local turn_in_npc_id = raw_get(input, 'turn_in_npc_id')
    local command_id = raw_get(input, 'command_id')

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = session.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'COMPLETE' then
            local prior_run = session.runs[prior.run_id]
            if prior_run == nil then
                return fail(QuestErrorCodes.QUEST_RECEIPT_CONFLICT, 'COMPLETE_COMMAND_ORPHAN', {
                    command_id = command_id,
                    run_id = prior.run_id,
                })
            end
            return result_ok({
                already_completed = true,
                command_replay = true,
                run = copy_run(prior_run),
                reward_id = prior_run.reward_id,
                reward_policy = prior_run.reward_policy,
                reward_receipt_id = prior_run.reward_receipt_id,
                completion_receipt_id = prior_run.completion_receipt_id,
                needs_reward = false,
            })
        end
    end

    local run = session.runs[run_id]
    if run == nil then
        return fail(QuestErrorCodes.QUEST_RUN_UNKNOWN, 'RUN_UNKNOWN', { run_id = run_id })
    end
    if run.status == 'COMPLETED' and run.completion_receipt_id == completion_receipt_id then
        return result_ok({
            already_completed = true,
            command_replay = false,
            run = copy_run(run),
            reward_id = run.reward_id,
            reward_policy = run.reward_policy,
            reward_receipt_id = run.reward_receipt_id,
            completion_receipt_id = run.completion_receipt_id,
            needs_reward = false,
        })
    end
    if run.status == 'COMPLETED' then
        return fail(QuestErrorCodes.QUEST_ALREADY_COMPLETED, 'ALREADY_COMPLETED', {
            run_id = run_id,
        })
    end
    if run.status ~= 'READY_TO_TURN_IN' then
        return fail(QuestErrorCodes.QUEST_PHASE_INVALID, 'NOT_READY_TO_TURN_IN', {
            status = run.status,
        })
    end

    local stage = catalog:require_stage(run.current_stage_id)
    if not stage.ok then
        return stage
    end
    local done = stage_complete(session, catalog, run, stage.value)
    if not done.ok then
        return done
    end
    if not done.value or stage.value.next_stage_id ~= nil then
        return fail(QuestErrorCodes.QUEST_NOT_READY, 'OBJECTIVES_INCOMPLETE', {
            run_id = run_id,
            stage_id = run.current_stage_id,
        })
    end

    if run.reward_policy == 'TURN_IN_NPC' then
        if turn_in_npc_id == nil or turn_in_npc_id ~= run.turn_in_npc_id then
            return fail(QuestErrorCodes.QUEST_TURN_IN_INVALID, 'NPC_MISMATCH', {
                expected = run.turn_in_npc_id,
                actual = turn_in_npc_id,
            })
        end
    end

    local receipt_check = validate_derived(completion_receipt_id, 'completion_receipt_id')
    if not receipt_check.ok then
        return invalid('COMPLETION_RECEIPT_INVALID')
    end

    local needs_reward = run.reward_policy ~= 'NO_REWARD'
        and type_value(run.reward_id) == 'string'
        and run.reward_id ~= ''

    return result_ok({
        already_completed = false,
        command_replay = false,
        run = copy_run(run),
        reward_id = run.reward_id,
        reward_policy = run.reward_policy,
        completion_receipt_id = completion_receipt_id,
        needs_reward = needs_reward,
    })
end

function QuestSession.complete(session, catalog, input)
    local validated = QuestSession.validate_complete(session, catalog, input)
    if not validated.ok then
        return validated
    end
    if validated.value.already_completed then
        return result_ok({
            run = validated.value.run,
            already_completed = true,
            command_replay = validated.value.command_replay == true,
            reward_id = validated.value.reward_id,
            reward_policy = validated.value.reward_policy,
            reward_receipt_id = validated.value.reward_receipt_id,
        })
    end

    local run_id = raw_get(input, 'run_id')
    local completion_receipt_id = raw_get(input, 'completion_receipt_id')
    local command_id = raw_get(input, 'command_id')
    local reward_receipt_id = raw_get(input, 'reward_receipt_id')
    local run = session.runs[run_id]

    if reward_receipt_id ~= nil then
        local reward_check = validate_derived(reward_receipt_id, 'reward_receipt_id')
        if not reward_check.ok then
            return invalid('REWARD_RECEIPT_INVALID')
        end
    end

    run.status = 'COMPLETED'
    run.completion_receipt_id = completion_receipt_id
    run.reward_receipt_id = reward_receipt_id
    run.quest_revision = run.quest_revision + 1
    local cleared_positions = clear_tracking_for_run(session, run_id)
    if type_value(command_id) == 'string' and command_id ~= '' then
        session.command_receipts[command_id] = {
            command_id = command_id,
            run_id = run_id,
            kind = 'COMPLETE',
            completion_receipt_id = completion_receipt_id,
            reward_receipt_id = reward_receipt_id,
        }
    end
    session.session_revision = session.session_revision + 1
    return result_ok({
        run = copy_run(run),
        already_completed = false,
        command_replay = false,
        reward_id = run.reward_id,
        reward_policy = run.reward_policy,
        reward_receipt_id = run.reward_receipt_id,
        cleared_tracking_positions = cleared_positions,
        tracked = list_tracking_slots(session),
    })
end

-- Refresh OWN_ITEM / DELIVER_ITEM progress from an item_id -> count map.
-- May regress READY_TO_TURN_IN back to ACTIVE when delivery ownership drops.
function QuestSession.refresh_snapshot_objectives(session, catalog, input)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require_objective) ~= 'function' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local run_id = raw_get(input, 'run_id')
    local item_counts = raw_get(input, 'item_counts') or {}
    if type_value(item_counts) ~= 'table' or get_metatable(item_counts) ~= nil then
        return invalid('ITEM_COUNTS_REQUIRED')
    end
    local run = session.runs[run_id]
    if run == nil then
        return fail(QuestErrorCodes.QUEST_RUN_UNKNOWN, 'RUN_UNKNOWN', { run_id = run_id })
    end
    if TERMINAL[run.status] then
        return fail(QuestErrorCodes.QUEST_PHASE_INVALID, 'RUN_TERMINAL', {
            status = run.status,
        })
    end

    local changes = {}
    local key
    local row
    for key, row in raw_next, session.objectives do
        if row.run_id == run_id then
            local objective = catalog:require_objective(row.objective_id)
            if not objective.ok then
                return objective
            end
            objective = objective.value
            if objective.objective_type == 'OWN_ITEM'
                or objective.objective_type == 'DELIVER_ITEM'
            then
                local count = item_counts[objective.target_id] or 0
                if type_value(count) ~= 'number'
                    or count ~= math.floor(count)
                    or count < 0
                then
                    return invalid('ITEM_COUNT_INVALID', {
                        item_id = objective.target_id,
                    })
                end
                local next_progress = math_min(objective.required_count, count)
                local next_status = next_progress >= objective.required_count
                    and 'COMPLETE'
                    or 'IN_PROGRESS'
                if next_progress ~= row.progress or next_status ~= row.status then
                    local old_progress = row.progress
                    local old_status = row.status
                    row.progress = next_progress
                    row.status = next_status
                    row.state_revision = row.state_revision + 1
                    run.quest_revision = run.quest_revision + 1
                    changes[#changes + 1] = {
                        objective_id = row.objective_id,
                        old_progress = old_progress,
                        new_progress = next_progress,
                        old_status = old_status,
                        new_status = next_status,
                        objective_type = objective.objective_type,
                        regressed = next_progress < old_progress
                            or (old_status == 'COMPLETE' and next_status ~= 'COMPLETE'),
                    }
                end
            end
        end
    end

    local status_changed = false
    if run.status == 'READY_TO_TURN_IN' then
        local stage = catalog:require_stage(run.current_stage_id)
        if not stage.ok then
            return stage
        end
        local done = stage_complete(session, catalog, run, stage.value)
        if not done.ok then
            return done
        end
        if not done.value then
            run.status = 'ACTIVE'
            run.quest_revision = run.quest_revision + 1
            status_changed = true
        end
    elseif run.status == 'ACTIVE' then
        local advanced = advance_stage_if_needed(session, catalog, run)
        if not advanced.ok then
            return advanced
        end
        if advanced.value.stage_finished or advanced.value.advanced then
            status_changed = true
        end
        if run.status == 'READY_TO_TURN_IN' then
            status_changed = true
        end
    end

    if #changes > 0 or status_changed then
        session.session_revision = session.session_revision + 1
    end
    return result_ok({
        run = copy_run(run),
        changes = changes,
        status_changed = status_changed,
    })
end

-- Collect DELIVER_ITEM costs for the run's current stage (turn-in deduction).
function QuestSession.collect_delivery_costs(session, catalog, run_id)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    local run = session.runs[run_id]
    if run == nil then
        return fail(QuestErrorCodes.QUEST_RUN_UNKNOWN, 'RUN_UNKNOWN', { run_id = run_id })
    end
    local stage = catalog:require_stage(run.current_stage_id)
    if not stage.ok then
        return stage
    end
    stage = stage.value
    local costs = {}
    local merged = {}
    local index
    for index = 1, #stage.objective_ids do
        local objective = catalog:require_objective(stage.objective_ids[index])
        if not objective.ok then
            return objective
        end
        objective = objective.value
        if objective.objective_type == 'DELIVER_ITEM'
            and objective.optional ~= true
            and objective.target_id ~= nil
        then
            local amount = objective.required_count or 1
            merged[objective.target_id] = (merged[objective.target_id] or 0) + amount
        end
    end
    local item_ids = {}
    local item_id
    for item_id in raw_next, merged do
        item_ids[#item_ids + 1] = item_id
    end
    table_sort(item_ids, bytewise_string_less)
    for index = 1, #item_ids do
        costs[#costs + 1] = {
            item_id = item_ids[index],
            amount = merged[item_ids[index]],
        }
    end
    return result_ok({
        costs = costs,
        run_id = run_id,
        stage_id = stage.id,
    })
end

function QuestSession.abandon(session, input)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local run = session.runs[raw_get(input, 'run_id')]
    if run == nil then
        return fail(QuestErrorCodes.QUEST_RUN_UNKNOWN, 'RUN_UNKNOWN')
    end
    if TERMINAL[run.status] then
        return fail(QuestErrorCodes.QUEST_PHASE_INVALID, 'ALREADY_TERMINAL', {
            status = run.status,
        })
    end
    if run.abandon_policy == 'DENY' then
        return fail(QuestErrorCodes.QUEST_ABANDON_DENIED, 'ABANDON_DENIED', {
            quest_id = run.quest_id,
        })
    end
    run.status = 'ABANDONED'
    run.quest_revision = run.quest_revision + 1
    local cleared_positions = clear_tracking_for_run(session, run.run_id)
    session.session_revision = session.session_revision + 1
    return result_ok({
        run = copy_run(run),
        cleared_tracking_positions = cleared_positions,
        tracked = list_tracking_slots(session),
    })
end

function QuestSession.get_run(session, run_id)
    if type_value(session) ~= 'table' then
        return invalid('SESSION_REQUIRED')
    end
    local run = session.runs[run_id]
    if run == nil then
        return fail(QuestErrorCodes.QUEST_RUN_UNKNOWN, 'RUN_UNKNOWN', { run_id = run_id })
    end
    local objectives = {}
    local key
    local row
    for key, row in raw_next, session.objectives do
        if row.run_id == run_id then
            objectives[#objectives + 1] = copy_objective(row)
        end
    end
    table_sort(objectives, function(left, right)
        return bytewise_string_less(left.objective_id, right.objective_id)
    end)
    return result_ok({
        run = copy_run(run),
        objectives = objectives,
    })
end

function QuestSession.get_journal(session, catalog)
    if type_value(session) ~= 'table' then
        return invalid('SESSION_REQUIRED')
    end
    local tracking_by_run = {}
    local tracked_slots = list_tracking_slots(session)
    local track_index
    for track_index = 1, #tracked_slots do
        tracking_by_run[tracked_slots[track_index].run_id] =
            tracked_slots[track_index].tracking_position
    end
    local entries = {}
    local run_ids = list_run_ids(session)
    local index
    for index = 1, #run_ids do
        local run = session.runs[run_ids[index]]
        local sort_order = 1000
        if catalog ~= nil and type_value(catalog.require_quest) == 'function' then
            local quest = catalog:require_quest(run.quest_id)
            if quest.ok then
                sort_order = quest.value.journal_sort_order
            end
        end
        entries[#entries + 1] = {
            run_id = run.run_id,
            quest_id = run.quest_id,
            status = run.status,
            current_stage_id = run.current_stage_id,
            category = run.category,
            journal_sort_order = sort_order,
            quest_revision = run.quest_revision,
            tracking_position = tracking_by_run[run.run_id],
        }
    end
    table_sort(entries, function(left, right)
        -- Tracked first (lower position first), then journal_sort_order, quest_id.
        local left_track = left.tracking_position or 999
        local right_track = right.tracking_position or 999
        if left_track ~= right_track then
            return left_track < right_track
        end
        if left.journal_sort_order ~= right.journal_sort_order then
            return left.journal_sort_order < right.journal_sort_order
        end
        return bytewise_string_less(left.quest_id, right.quest_id)
    end)
    return result_ok({
        session_revision = session.session_revision,
        entries = entries,
        tracked = tracked_slots,
    })
end

-- TrackQuest: set or clear tracking_position 1-3. run_id nil/empty clears the slot.
-- Moving an already-tracked run to a new position is allowed (old slot cleared).
function QuestSession.track(session, input)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local tracking_position = raw_get(input, 'tracking_position')
    if not (type_value(tracking_position) == 'number'
        and tracking_position == math_floor(tracking_position)
        and tracking_position >= 1
        and tracking_position <= MAX_TRACKED)
    then
        return invalid('TRACKING_POSITION_INVALID', {
            field = 'tracking_position',
            minimum = 1,
            maximum = MAX_TRACKED,
        })
    end

    local command_id = raw_get(input, 'command_id')
    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = session.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'TRACK' then
            return result_ok({
                already_applied = true,
                command_replay = true,
                tracking_position = prior.tracking_position,
                run_id = prior.run_id,
                tracked = list_tracking_slots(session),
            })
        end
    end

    local run_id = raw_get(input, 'run_id')
    local tracked = ensure_tracked_table(session)
    local previous_run_id = tracked[tracking_position]

    -- Clear slot.
    if run_id == nil or run_id == '' then
        tracked[tracking_position] = nil
        if type_value(command_id) == 'string' and command_id ~= '' then
            session.command_receipts[command_id] = {
                command_id = command_id,
                kind = 'TRACK',
                tracking_position = tracking_position,
                run_id = nil,
            }
        end
        session.session_revision = session.session_revision + 1
        return result_ok({
            already_applied = false,
            command_replay = false,
            tracking_position = tracking_position,
            run_id = nil,
            previous_run_id = previous_run_id,
            cleared = true,
            tracked = list_tracking_slots(session),
        })
    end

    local run_check = validate_derived(run_id, 'run_id')
    if not run_check.ok then
        return invalid('RUN_ID_INVALID')
    end
    local run = session.runs[run_id]
    if run == nil then
        return fail(QuestErrorCodes.QUEST_RUN_UNKNOWN, 'RUN_UNKNOWN', {
            run_id = run_id,
        })
    end
    if not TRACKABLE[run.status] then
        return fail(QuestErrorCodes.QUEST_PHASE_INVALID, 'RUN_NOT_TRACKABLE', {
            run_id = run_id,
            status = run.status,
        })
    end

    -- Idempotent: same run already in this position.
    if previous_run_id == run_id then
        if type_value(command_id) == 'string' and command_id ~= '' then
            session.command_receipts[command_id] = {
                command_id = command_id,
                kind = 'TRACK',
                tracking_position = tracking_position,
                run_id = run_id,
            }
        end
        return result_ok({
            already_applied = true,
            command_replay = false,
            tracking_position = tracking_position,
            run_id = run_id,
            quest_id = run.quest_id,
            tracked = list_tracking_slots(session),
        })
    end

    -- If run is tracked elsewhere, clear the old slot (move).
    local prior_position = find_tracking_position(session, run_id)
    if prior_position ~= nil and prior_position ~= tracking_position then
        tracked[prior_position] = nil
    end

    -- Occupying a new slot with a new run when already at max is only possible
    -- if we're replacing an occupied slot or moving; fixed 1-3 positions always
    -- overwrite. Guard keeps the error code live for callers that pass free
    -- position selection without overwrite intent.
    if prior_position == nil
        and previous_run_id == nil
        and count_tracked(session) >= MAX_TRACKED
    then
        return fail(
            QuestErrorCodes.QUEST_TRACK_LIMIT_REACHED,
            'TRACK_LIMIT',
            { maximum = MAX_TRACKED }
        )
    end

    tracked[tracking_position] = run_id
    if type_value(command_id) == 'string' and command_id ~= '' then
        session.command_receipts[command_id] = {
            command_id = command_id,
            kind = 'TRACK',
            tracking_position = tracking_position,
            run_id = run_id,
        }
    end
    session.session_revision = session.session_revision + 1
    return result_ok({
        already_applied = false,
        command_replay = false,
        tracking_position = tracking_position,
        run_id = run_id,
        quest_id = run.quest_id,
        previous_run_id = previous_run_id,
        moved_from_position = prior_position,
        tracked = list_tracking_slots(session),
    })
end

function QuestSession.get_tracked(session)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    return result_ok({
        tracked = list_tracking_slots(session),
        maximum = MAX_TRACKED,
    })
end

local function is_revealed(session, context, quest_id)
    if session.revealed_hidden_quests ~= nil
        and session.revealed_hidden_quests[quest_id] == true
    then
        return true
    end
    if type_value(context) == 'table' then
        local revealed = raw_get(context, 'revealed_quest_ids')
        if type_value(revealed) == 'table' and revealed[quest_id] == true then
            return true
        end
    end
    return false
end

-- Pure acceptability projection (doc 7.1). Does not mutate session.
-- status: HIDDEN | LOCKED | AVAILABLE | ACTIVE | READY_TO_TURN_IN | COMPLETED | ...
function QuestSession.evaluate_availability(session, catalog, quest_id, context)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require_quest) ~= 'function' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(quest_id) ~= 'string' or quest_id == '' then
        return invalid('QUEST_ID_REQUIRED')
    end
    if context ~= nil and (type_value(context) ~= 'table' or get_metatable(context) ~= nil) then
        return invalid('CONTEXT_TABLE_REQUIRED')
    end
    context = context or {}

    local quest = catalog:require_quest(quest_id)
    if not quest.ok then
        -- require_quest already maps unknown/deprecated.
        return quest
    end
    quest = quest.value

    local open_run = find_open_run_for_quest(session, quest_id)
    if open_run ~= nil then
        return result_ok({
            quest_id = quest_id,
            status = open_run.status,
            can_accept = false,
            reason = 'QUEST_ALREADY_ACTIVE',
            run_id = open_run.run_id,
            accept_policy = quest.accept_policy,
            accept_ref_id = quest.accept_ref_id,
            visibility_policy = quest.visibility_policy,
            category = quest.category,
            journal_sort_order = quest.journal_sort_order,
            prerequisite_quest_id = quest.prerequisite_quest_id,
        })
    end

    local completed_run = find_completed_run_for_quest(session, quest_id)
    if completed_run ~= nil then
        return result_ok({
            quest_id = quest_id,
            status = 'COMPLETED',
            can_accept = false,
            reason = 'QUEST_ALREADY_COMPLETED',
            run_id = completed_run.run_id,
            accept_policy = quest.accept_policy,
            accept_ref_id = quest.accept_ref_id,
            visibility_policy = quest.visibility_policy,
            category = quest.category,
            journal_sort_order = quest.journal_sort_order,
            prerequisite_quest_id = quest.prerequisite_quest_id,
        })
    end

    -- Terminal non-completed (abandoned/failed) still blocks re-accept for V1
    -- non-repeatable unless abandon policy allows reset — check abandoned.
    local any_run_id
    local any_run
    for any_run_id, any_run in raw_next, session.runs do
        if any_run.quest_id == quest_id and TERMINAL[any_run.status] then
            if any_run.status == 'ABANDONED'
                and quest.abandon_policy == 'ALLOW_RESET_RUN'
            then
                -- Re-acceptable after abandon-reset.
                break
            end
            return result_ok({
                quest_id = quest_id,
                status = any_run.status,
                can_accept = false,
                reason = 'QUEST_TERMINAL',
                run_id = any_run.run_id,
                accept_policy = quest.accept_policy,
                accept_ref_id = quest.accept_ref_id,
                visibility_policy = quest.visibility_policy,
                category = quest.category,
                journal_sort_order = quest.journal_sort_order,
                prerequisite_quest_id = quest.prerequisite_quest_id,
            })
        end
    end

    if quest.visibility_policy == 'HIDDEN_UNTIL_REVEALED'
        and not is_revealed(session, context, quest_id)
    then
        return result_ok({
            quest_id = quest_id,
            status = 'HIDDEN',
            can_accept = false,
            reason = 'NOT_REVEALED',
            accept_policy = quest.accept_policy,
            accept_ref_id = quest.accept_ref_id,
            visibility_policy = quest.visibility_policy,
            category = quest.category,
            journal_sort_order = quest.journal_sort_order,
            prerequisite_quest_id = quest.prerequisite_quest_id,
        })
    end

    if quest.prerequisite_quest_id ~= nil
        and not QuestSession.has_completed_quest(session, quest.prerequisite_quest_id)
    then
        local locked_status = 'LOCKED'
        -- Unrevealed-style hide: journal may suppress LOCKED when visibility is
        -- HIDDEN_UNTIL_ACCEPTED (no public marker until accepted).
        if quest.visibility_policy == 'HIDDEN_UNTIL_ACCEPTED' then
            locked_status = 'HIDDEN'
        end
        return result_ok({
            quest_id = quest_id,
            status = locked_status,
            can_accept = false,
            reason = 'PREREQUISITE_QUEST_INCOMPLETE',
            accept_policy = quest.accept_policy,
            accept_ref_id = quest.accept_ref_id,
            visibility_policy = quest.visibility_policy,
            category = quest.category,
            journal_sort_order = quest.journal_sort_order,
            prerequisite_quest_id = quest.prerequisite_quest_id,
        })
    end

    if quest.accept_policy == 'BOARD' then
        return result_ok({
            quest_id = quest_id,
            status = 'LOCKED',
            can_accept = false,
            reason = 'BOARD_OFFER_REQUIRED',
            accept_policy = quest.accept_policy,
            accept_ref_id = quest.accept_ref_id,
            visibility_policy = quest.visibility_policy,
            category = quest.category,
            journal_sort_order = quest.journal_sort_order,
            prerequisite_quest_id = quest.prerequisite_quest_id,
        })
    end

    local can_accept = true
    local reason = 'AVAILABLE'
    local entry_kind = raw_get(context, 'entry_kind')
    local entry_ref = raw_get(context, 'entry_ref')
    if quest.accept_policy == 'AUTO_EVENT' then
        if entry_kind ~= nil and entry_kind ~= 'AUTO_EVENT' then
            can_accept = false
            reason = 'AUTO_EVENT_ENTRY_REQUIRED'
        end
    elseif quest.accept_policy == 'MANUAL_NPC' then
        if entry_kind == 'AUTO_EVENT' then
            can_accept = false
            reason = 'MANUAL_NPC_ENTRY_REQUIRED'
        elseif type_value(entry_ref) == 'string'
            and entry_ref ~= ''
            and quest.accept_ref_id ~= nil
            and entry_ref ~= quest.accept_ref_id
        then
            can_accept = false
            reason = 'ENTRY_REF_MISMATCH'
        end
    elseif quest.accept_policy == 'AUTO_CONDITION' then
        if entry_kind ~= nil
            and entry_kind ~= 'AUTO_CONDITION'
            and entry_kind ~= 'AUTO_EVENT'
        then
            can_accept = false
            reason = 'AUTO_CONDITION_ENTRY_REQUIRED'
        end
    end

    if can_accept and count_open_runs(session) >= MAX_ACTIVE_RUNS then
        can_accept = false
        reason = 'ACTIVE_LIMIT'
    end

    -- HIDDEN_UNTIL_ACCEPTED: still accept via NPC/entry, but journal/status is
    -- not public AVAILABLE until a run exists.
    local status
    if not can_accept then
        status = 'LOCKED'
    elseif quest.visibility_policy == 'HIDDEN_UNTIL_ACCEPTED' then
        status = 'HIDDEN'
        reason = 'HIDDEN_UNTIL_ACCEPTED'
    else
        status = 'AVAILABLE'
    end

    return result_ok({
        quest_id = quest_id,
        status = status,
        can_accept = can_accept,
        reason = reason,
        accept_policy = quest.accept_policy,
        accept_ref_id = quest.accept_ref_id,
        visibility_policy = quest.visibility_policy,
        category = quest.category,
        journal_sort_order = quest.journal_sort_order,
        prerequisite_quest_id = quest.prerequisite_quest_id,
    })
end

-- List availability for all catalog quests (stable quest_id order).
function QuestSession.list_availability(session, catalog, context)
    if type_value(catalog) ~= 'table' or type_value(catalog.list) ~= 'function' then
        return invalid('CATALOG_REQUIRED')
    end
    local listed = catalog:list('quest_definitions')
    if not listed.ok then
        return listed
    end
    local rows = {}
    local index
    for index = 1, #listed.value do
        local quest = listed.value[index]
        -- Skip deprecated at list layer; evaluate still handles require_quest.
        if quest.deprecated ~= true then
            local evaluated = QuestSession.evaluate_availability(
                session,
                catalog,
                quest.id,
                context
            )
            if evaluated.ok then
                rows[#rows + 1] = evaluated.value
            end
        end
    end
    table_sort(rows, function(left, right)
        if left.journal_sort_order ~= right.journal_sort_order then
            return left.journal_sort_order < right.journal_sort_order
        end
        return bytewise_string_less(left.quest_id, right.quest_id)
    end)
    return result_ok({
        session_revision = session.session_revision,
        entries = rows,
    })
end

function QuestSession.reveal_hidden_quest(session, quest_id)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED')
    end
    local quest_check = validate_content(quest_id, 'quest_', 'quest_id')
    if not quest_check.ok then
        return invalid('QUEST_ID_INVALID')
    end
    if session.revealed_hidden_quests == nil then
        session.revealed_hidden_quests = {}
    end
    if session.revealed_hidden_quests[quest_id] == true then
        return result_ok({
            quest_id = quest_id,
            already_revealed = true,
        })
    end
    session.revealed_hidden_quests[quest_id] = true
    session.session_revision = session.session_revision + 1
    return result_ok({
        quest_id = quest_id,
        already_revealed = false,
    })
end

return QuestSession
