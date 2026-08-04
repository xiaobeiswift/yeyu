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
        quest_revision = run.quest_revision,
        stage_entry_ordinal = run.stage_entry_ordinal,
        reward_policy = run.reward_policy,
        reward_id = run.reward_id,
        turn_in_npc_id = run.turn_in_npc_id,
        abandon_policy = run.abandon_policy,
        category = run.category,
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

    local existing = find_open_run_for_quest(session, quest_id)
    if existing ~= nil then
        return fail(QuestErrorCodes.QUEST_ALREADY_ACTIVE, 'QUEST_ALREADY_ACTIVE', {
            run_id = existing.run_id,
            quest_id = quest_id,
        })
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

    local run = {
        run_id = run_id,
        quest_id = quest.id,
        definition_version = quest.definition_version,
        status = 'ACTIVE',
        current_stage_id = first_stage.id,
        accept_receipt_id = accept_receipt_id,
        completion_receipt_id = nil,
        quest_revision = 1,
        stage_entry_ordinal = 1,
        reward_policy = quest.reward_policy,
        reward_id = quest.reward_id,
        turn_in_npc_id = quest.turn_in_npc_id,
        abandon_policy = quest.abandon_policy,
        category = quest.category,
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

function QuestSession.complete(session, catalog, input)
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

    local run = session.runs[run_id]
    if run == nil then
        return fail(QuestErrorCodes.QUEST_RUN_UNKNOWN, 'RUN_UNKNOWN', { run_id = run_id })
    end
    if run.status == 'COMPLETED' and run.completion_receipt_id == completion_receipt_id then
        return result_ok({
            run = copy_run(run),
            already_completed = true,
        })
    end
    if run.status == 'COMPLETED' then
        return fail(QuestErrorCodes.QUEST_ALREADY_COMPLETED, 'ALREADY_COMPLETED', {
            run_id = run_id,
        })
    end
    if run.status ~= 'READY_TO_TURN_IN' and run.status ~= 'ACTIVE' then
        return fail(QuestErrorCodes.QUEST_PHASE_INVALID, 'NOT_COMPLETABLE', {
            status = run.status,
        })
    end

    -- Ensure current stage fully complete before finish.
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

    run.status = 'COMPLETED'
    run.completion_receipt_id = completion_receipt_id
    run.quest_revision = run.quest_revision + 1
    if type_value(command_id) == 'string' and command_id ~= '' then
        session.command_receipts[command_id] = {
            command_id = command_id,
            run_id = run_id,
            kind = 'COMPLETE',
        }
    end
    session.session_revision = session.session_revision + 1
    return result_ok({
        run = copy_run(run),
        already_completed = false,
        reward_id = run.reward_id,
        reward_policy = run.reward_policy,
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
    session.session_revision = session.session_revision + 1
    return result_ok({ run = copy_run(run) })
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
        }
    end
    table_sort(entries, function(left, right)
        if left.journal_sort_order ~= right.journal_sort_order then
            return left.journal_sort_order < right.journal_sort_order
        end
        return bytewise_string_less(left.quest_id, right.quest_id)
    end)
    return result_ok({
        session_revision = session.session_revision,
        entries = entries,
    })
end

return QuestSession
