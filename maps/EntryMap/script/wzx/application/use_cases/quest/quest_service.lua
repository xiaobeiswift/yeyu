-- Application facade for system 14 quest runs.
-- Completion saga (offline):
--   validate turn-in → plan/consume DELIVER_ITEM costs → grant reward → COMPLETED
--   → QuestCompleted event → chain AcceptQuest for AUTO_EVENT successors.
-- Delivery failure keeps READY; reward failure after successful consume is still
-- fail-closed for quest COMPLETED (items already spent; caller may query
-- inventory/economy receipts). Chain accept never inserts runs outside AcceptQuest.
-- MAIN accept auto-tracks slot 1 via TrackQuest when enabled (default on);
-- never preempts an occupied slot 1; player may disable auto_track_main.
-- Optional QuestSaveBridge persists quest sections to slot 2 via SaveCoordinator
-- after successful mutating commands that carry player_save_scope.
-- Optional QuestCompletionSaveBridge stages one multi-slot checkpoint for complete
-- (slot 2 + optional slot 4/5) after owner mutations with skip_save.

local Result = require 'wzx.domain.common.result'
local Sha256 = require 'wzx.domain.common.sha256'
local QuestSession = require 'wzx.domain.quest.quest_session'
local QuestEvents = require 'wzx.domain.quest.quest_events'
local QuestErrorCodes = require 'wzx.domain.quest.error_codes'
local QuestSaveBridge = require 'wzx.application.use_cases.quest.quest_save_bridge'
local QuestCompletionSaveBridge =
    require 'wzx.application.use_cases.quest.quest_completion_save_bridge'

local QuestService = {}
local error_value = error
local get_metatable = getmetatable
local pairs_value = pairs
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local string_sub = string.sub
local table_sort = table.sort
local type_value = type

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('quest service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.quest.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(QuestErrorCodes.QUEST_ARGUMENT_INVALID, reason, details, false)
end

local function is_economy_service(value)
    return type_value(value) == 'table'
        and type_value(value.prepare_reward) == 'function'
        and type_value(value.grant_prepared_reward) == 'function'
end

local function is_inventory_service(value)
    return type_value(value) == 'table'
        and type_value(value.get_count) == 'function'
        and type_value(value.consume_items) == 'function'
end

local function is_quest_store(value)
    return type_value(value) == 'table'
        and type_value(value.get_session) == 'function'
        and type_value(value.replace_session) == 'function'
end

function QuestService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    local quest_store = raw_get(options, 'quest_store')
    local economy_service = raw_get(options, 'economy_service')
    local inventory_service = raw_get(options, 'inventory_service')
    local save_bridge = raw_get(options, 'save_bridge')
    local completion_save_bridge = raw_get(options, 'completion_save_bridge')
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_quest) ~= 'function'
    then
        return invalid('QUEST_CATALOG_REQUIRED', { field = 'catalog' })
    end
    if quest_store ~= nil and not is_quest_store(quest_store) then
        return invalid('QUEST_STORE_INVALID', { field = 'quest_store' })
    end
    if economy_service ~= nil and not is_economy_service(economy_service) then
        return invalid('ECONOMY_SERVICE_INVALID', { field = 'economy_service' })
    end
    if inventory_service ~= nil and not is_inventory_service(inventory_service) then
        return invalid('INVENTORY_SERVICE_INVALID', {
            field = 'inventory_service',
        })
    end
    if save_bridge ~= nil and not QuestSaveBridge.is_authority(save_bridge) then
        return invalid('SAVE_BRIDGE_AUTHORITY_REQUIRED', {
            field = 'save_bridge',
        })
    end
    if save_bridge ~= nil and quest_store == nil then
        return invalid('QUEST_STORE_REQUIRED_FOR_SAVE_BRIDGE', {
            field = 'quest_store',
        })
    end
    if completion_save_bridge ~= nil
        and not QuestCompletionSaveBridge.is_authority(completion_save_bridge)
    then
        return invalid('COMPLETION_SAVE_BRIDGE_AUTHORITY_REQUIRED', {
            field = 'completion_save_bridge',
        })
    end
    if completion_save_bridge ~= nil and quest_store == nil then
        return invalid('QUEST_STORE_REQUIRED_FOR_COMPLETION_SAVE_BRIDGE', {
            field = 'quest_store',
        })
    end

    local auto_track_main = raw_get(options, 'auto_track_main')
    if auto_track_main == nil then
        auto_track_main = true
    elseif type_value(auto_track_main) ~= 'boolean' then
        return invalid('AUTO_TRACK_MAIN_INVALID', { field = 'auto_track_main' })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        quest_store = quest_store,
        economy_service = economy_service,
        inventory_service = inventory_service,
        save_bridge = save_bridge,
        completion_save_bridge = completion_save_bridge,
        auto_track_main = auto_track_main,
        session = QuestSession.empty(),
    }
    return result_ok(view)
end

function QuestService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

local function load_session(state)
    if state.quest_store == nil then
        return result_ok(state.session)
    end
    local loaded = state.quest_store:get_session()
    if not loaded.ok then
        return loaded
    end
    state.session = loaded.value
    return result_ok(state.session)
end

local function persist_session(state)
    if state.quest_store == nil then
        return result_ok({ persisted = false })
    end
    local saved = state.quest_store:replace_session(state.session)
    if not saved.ok then
        return saved
    end
    return result_ok({ persisted = true })
end

-- Persist quest sections to slot 2 after a successful in-memory/store mutation.
-- Requires player_save_scope on the command input; otherwise SKIPPED.
local function maybe_persist_save(state, input, options)
    options = options or {}
    if state.save_bridge == nil then
        return result_ok({
            status = 'SKIPPED',
            reason = 'SAVE_BRIDGE_UNBOUND',
        })
    end
    if options.skip == true then
        return result_ok({
            status = 'SKIPPED',
            reason = options.skip_reason or 'NO_MUTATION',
        })
    end
    if type_value(input) ~= 'table' then
        return result_ok({
            status = 'SKIPPED',
            reason = 'INPUT_MISSING',
        })
    end
    local player_save_scope = raw_get(input, 'player_save_scope')
    if player_save_scope == nil then
        return result_ok({
            status = 'SKIPPED',
            reason = 'PLAYER_SAVE_SCOPE_MISSING',
        })
    end
    local request_id = raw_get(input, 'request_id')
    if type_value(request_id) ~= 'string' or request_id == '' then
        local command_id = raw_get(input, 'command_id')
        if type_value(command_id) == 'string' and command_id ~= '' then
            request_id = command_id .. '_quest_save'
        else
            request_id = 'request_quest_save'
        end
    end
    local command_id = raw_get(input, 'command_id')
    local ckpt_command_id = nil
    if type_value(command_id) == 'string' and command_id ~= '' then
        ckpt_command_id = command_id .. '_quest_ckpt'
    end
    return state.save_bridge:persist_player_quest({
        player_save_scope = player_save_scope,
        player_ref = raw_get(input, 'player_ref') or player_save_scope,
        request_id = request_id,
        command_id = ckpt_command_id,
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
end

local MAIN_AUTO_TRACK_POSITION = 1

-- After AcceptQuest for MAIN: occupy tracking slot 1 via TrackQuest when enabled.
-- Never preempts an occupied slot 1; never moves an already-tracked run.
local function maybe_auto_track_main(state, accept_value)
    if state.auto_track_main ~= true then
        return result_ok({
            applied = false,
            reason = 'DISABLED',
        })
    end
    if accept_value.command_replay == true or accept_value.already_accepted == true then
        return result_ok({
            applied = false,
            reason = 'REPLAY_OR_EXISTING',
        })
    end
    local run = accept_value.run
    if type_value(run) ~= 'table' or type_value(run.run_id) ~= 'string' then
        return result_ok({
            applied = false,
            reason = 'RUN_MISSING',
        })
    end
    if run.category ~= 'MAIN' then
        return result_ok({
            applied = false,
            reason = 'NOT_MAIN',
            category = run.category,
        })
    end

    local current = QuestSession.get_tracked(state.session)
    if not current.ok then
        return current
    end
    local slots = current.value.tracked
    local index
    for index = 1, #slots do
        local slot = slots[index]
        if slot.run_id == run.run_id then
            return result_ok({
                applied = false,
                reason = 'ALREADY_TRACKED',
                tracking_position = slot.tracking_position,
                run_id = run.run_id,
            })
        end
        if slot.tracking_position == MAIN_AUTO_TRACK_POSITION then
            return result_ok({
                applied = false,
                reason = 'SLOT_OCCUPIED',
                tracking_position = MAIN_AUTO_TRACK_POSITION,
                occupant_run_id = slot.run_id,
                run_id = run.run_id,
            })
        end
    end

    local tracked = QuestSession.track(state.session, {
        run_id = run.run_id,
        tracking_position = MAIN_AUTO_TRACK_POSITION,
    })
    if not tracked.ok then
        return tracked
    end
    return result_ok({
        applied = true,
        reason = 'TRACKED',
        tracking_position = MAIN_AUTO_TRACK_POSITION,
        run_id = run.run_id,
        quest_id = run.quest_id,
        tracked = tracked.value.tracked,
    })
end

function Service:set_auto_track_main(enabled)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(enabled) ~= 'boolean' then
        return invalid('AUTO_TRACK_MAIN_INVALID', { field = 'enabled' })
    end
    state.auto_track_main = enabled
    return result_ok({
        auto_track_main = enabled,
    })
end

function Service:get_auto_track_main()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return result_ok({
        auto_track_main = state.auto_track_main == true,
    })
end

function Service:accept(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    local accepted = QuestSession.accept(session.value, state.catalog, input)
    if not accepted.ok then
        return accepted
    end
    local auto_track = maybe_auto_track_main(state, accepted.value)
    if not auto_track.ok then
        return auto_track
    end
    accepted.value.auto_track = auto_track.value
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    accepted.value.persisted = persisted.value.persisted
    local saved = maybe_persist_save(state, input, {
        skip = accepted.value.command_replay == true
            or accepted.value.already_accepted == true,
        skip_reason = 'REPLAY_OR_EXISTING',
    })
    if not saved.ok then
        return saved
    end
    accepted.value.save = saved.value
    return accepted
end

function Service:consume_fact(event, save_context)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    local consumed = QuestSession.consume_fact(session.value, state.catalog, event)
    if not consumed.ok then
        return consumed
    end
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    consumed.value.persisted = persisted.value.persisted
    local context = save_context
    if type_value(context) ~= 'table' and type_value(event) == 'table' then
        -- Optional offline save fields may ride on the event envelope table.
        context = event
    end
    local saved = maybe_persist_save(state, context, {
        skip = consumed.value.duplicate == true
            or consumed.value.applied == false,
        skip_reason = 'NO_MUTATION',
    })
    if not saved.ok then
        return saved
    end
    consumed.value.save = saved.value
    return consumed
end

local function build_item_counts(inventory_service, item_ids)
    local counts = {}
    local index
    for index = 1, #item_ids do
        local item_id = item_ids[index]
        local counted = inventory_service:get_count(item_id)
        if not counted.ok then
            return counted
        end
        counts[item_id] = counted.value.count
    end
    return result_ok(counts)
end

local function collect_snapshot_item_ids(session, catalog, run_id)
    local ids = {}
    local seen = {}
    local key
    local row
    for key, row in raw_next, session.objectives do
        if row.run_id == run_id then
            local objective = catalog:require_objective(row.objective_id)
            if not objective.ok then
                return objective
            end
            objective = objective.value
            if (objective.objective_type == 'OWN_ITEM'
                or objective.objective_type == 'DELIVER_ITEM')
                and objective.target_id ~= nil
                and seen[objective.target_id] ~= true
            then
                seen[objective.target_id] = true
                ids[#ids + 1] = objective.target_id
            end
        end
    end
    return result_ok(ids)
end

function Service:refresh_snapshot_objectives(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local run_id = raw_get(input, 'run_id')
    local session = load_session(state)
    if not session.ok then
        return session
    end

    local item_counts = raw_get(input, 'item_counts')
    if item_counts == nil then
        if state.inventory_service == nil then
            return fail(
                QuestErrorCodes.QUEST_INVENTORY_REQUIRED,
                'INVENTORY_SERVICE_REQUIRED_FOR_SNAPSHOT',
                { run_id = run_id },
                false
            )
        end
        local item_ids = collect_snapshot_item_ids(
            session.value,
            state.catalog,
            run_id
        )
        if not item_ids.ok then
            return item_ids
        end
        local counted = build_item_counts(state.inventory_service, item_ids.value)
        if not counted.ok then
            return counted
        end
        item_counts = counted.value
    end

    local refreshed = QuestSession.refresh_snapshot_objectives(
        session.value,
        state.catalog,
        {
            run_id = run_id,
            item_counts = item_counts,
        }
    )
    if not refreshed.ok then
        return refreshed
    end
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    refreshed.value.persisted = persisted.value.persisted
    local change_count = type_value(refreshed.value.changes) == 'table'
        and #refreshed.value.changes
        or 0
    local saved = maybe_persist_save(state, input, {
        skip = change_count == 0 and refreshed.value.status_changed ~= true,
        skip_reason = 'NO_MUTATION',
    })
    if not saved.ok then
        return saved
    end
    refreshed.value.save = saved.value
    return refreshed
end

local function grant_quest_reward(economy_service, plan, input)
    local reward_receipt_id = raw_get(input, 'reward_receipt_id')
        or raw_get(input, 'completion_receipt_id')
    local prepared = economy_service:prepare_reward({
        reward_id = plan.reward_id,
        source_type = 'QUEST_COMPLETION',
        source_ref = plan.run.quest_id,
        source_occurrence_id = plan.run.run_id,
        overflow_policy = raw_get(input, 'overflow_policy'),
    })
    if not prepared.ok then
        return fail(
            QuestErrorCodes.QUEST_REWARD_FAILED,
            'PREPARE_REWARD_FAILED',
            {
                cause_code = prepared.error and prepared.error.code or 'UNKNOWN',
                reward_id = plan.reward_id,
                run_id = plan.run.run_id,
            },
            prepared.error and prepared.error.retryable == true
        )
    end
    local granted = economy_service:grant_prepared_reward({
        prepared = prepared.value,
        receipt_id = reward_receipt_id,
        purpose_type = 'QUEST_COMPLETION',
        purpose_ref = plan.run.quest_id,
        player_save_scope = raw_get(input, 'player_save_scope'),
        player_ref = raw_get(input, 'player_ref'),
        request_id = raw_get(input, 'request_id'),
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
        skip_save = raw_get(input, 'skip_save') == true,
    })
    if not granted.ok then
        return fail(
            QuestErrorCodes.QUEST_REWARD_FAILED,
            'GRANT_REWARD_FAILED',
            {
                cause_code = granted.error and granted.error.code or 'UNKNOWN',
                reward_id = plan.reward_id,
                run_id = plan.run.run_id,
                receipt_id = reward_receipt_id,
            },
            granted.error and granted.error.retryable == true
        )
    end
    return result_ok({
        status = granted.value.status or 'COMMITTED',
        already_committed = granted.value.already_committed == true,
        receipt_id = granted.value.receipt_id or reward_receipt_id,
        reward_id = plan.reward_id,
        save = granted.value.save,
        economy_revision = granted.value.economy_revision,
    })
end

local function derive_chain_ids(completion_receipt_id, next_quest_id)
    local material = completion_receipt_id .. '|' .. next_quest_id
    local digest, digest_error = Sha256.hex(material)
    if digest == nil then
        return fail(
            QuestErrorCodes.QUEST_ARGUMENT_INVALID,
            'CHAIN_ID_HASH_FAILED',
            {
                reason = digest_error,
                quest_id = next_quest_id,
            },
            false
        )
    end
    local short = string_sub(digest, 1, 24)
    return result_ok({
        run_id = 'qrun_chain_' .. short,
        accept_receipt_id = 'rcpt_chain_' .. short,
        command_id = 'cmd_chain_' .. short,
    })
end

local function resolve_chain_binding(input, candidate, completion_receipt_id)
    local bindings = raw_get(input, 'chain_bindings')
    if type_value(bindings) == 'table' then
        local binding = raw_get(bindings, candidate.quest_id)
        if type_value(binding) == 'table' then
            return result_ok({
                run_id = raw_get(binding, 'run_id'),
                accept_receipt_id = raw_get(binding, 'accept_receipt_id'),
                command_id = raw_get(binding, 'command_id'),
                from_binding = true,
            })
        end
    end
    return derive_chain_ids(completion_receipt_id, candidate.quest_id)
end

-- After QuestCompleted: re-enter AcceptQuest for AUTO_EVENT successors.
-- Failures are reported per-candidate and do not roll back COMPLETED.
local function accept_chain_successors(state, completed_quest_id, source_event_id, input)
    local candidates = QuestSession.list_chain_candidates(
        state.session,
        state.catalog,
        completed_quest_id
    )
    if not candidates.ok then
        return candidates
    end

    local chain_accepts = {}
    local completion_receipt_id = raw_get(input, 'completion_receipt_id')
    local index
    for index = 1, #candidates.value.candidates do
        local candidate = candidates.value.candidates[index]
        local binding = resolve_chain_binding(
            input,
            candidate,
            completion_receipt_id
        )
        if not binding.ok then
            chain_accepts[#chain_accepts + 1] = {
                quest_id = candidate.quest_id,
                accepted = false,
                error = binding.error,
            }
        else
            local accepted = QuestSession.accept(state.session, state.catalog, {
                quest_id = candidate.quest_id,
                run_id = binding.value.run_id,
                accept_receipt_id = binding.value.accept_receipt_id,
                command_id = binding.value.command_id,
                source_event_id = source_event_id,
            })
            if not accepted.ok then
                chain_accepts[#chain_accepts + 1] = {
                    quest_id = candidate.quest_id,
                    accepted = false,
                    error = accepted.error,
                }
            else
                local auto_track = maybe_auto_track_main(state, accepted.value)
                if not auto_track.ok then
                    chain_accepts[#chain_accepts + 1] = {
                        quest_id = candidate.quest_id,
                        accepted = true,
                        already_accepted = accepted.value.already_accepted == true,
                        command_replay = accepted.value.command_replay == true,
                        run = accepted.value.run,
                        objectives = accepted.value.objectives,
                        source_event_id = source_event_id,
                        accept_receipt_id = binding.value.accept_receipt_id,
                        command_id = binding.value.command_id,
                        auto_track_error = auto_track.error,
                    }
                else
                    chain_accepts[#chain_accepts + 1] = {
                        quest_id = candidate.quest_id,
                        accepted = true,
                        already_accepted = accepted.value.already_accepted == true,
                        command_replay = accepted.value.command_replay == true,
                        run = accepted.value.run,
                        objectives = accepted.value.objectives,
                        source_event_id = source_event_id,
                        accept_receipt_id = binding.value.accept_receipt_id,
                        command_id = binding.value.command_id,
                        auto_track = auto_track.value,
                    }
                end
            end
        end
    end
    return result_ok({ chain_accepts = chain_accepts })
end

local function collect_existing_chain_accepts(state, completed_quest_id, source_event_id)
    -- list_chain_candidates skips already-active/completed successors; scan catalog
    -- for successors that already have runs after a prior complete.
    local listed = state.catalog:list('quest_definitions')
    if not listed.ok then
        return listed
    end
    local chain_accepts = {}
    local index
    for index = 1, #listed.value do
        local quest = listed.value[index]
        if quest.accept_policy == 'AUTO_EVENT'
            and quest.prerequisite_quest_id == completed_quest_id
            and quest.deprecated ~= true
        then
            local run_id
            local run
            for run_id, run in pairs_value(state.session.runs) do
                if run.quest_id == quest.id then
                    chain_accepts[#chain_accepts + 1] = {
                        quest_id = quest.id,
                        accepted = true,
                        already_accepted = true,
                        command_replay = true,
                        run = {
                            run_id = run.run_id,
                            quest_id = run.quest_id,
                            status = run.status,
                            current_stage_id = run.current_stage_id,
                            accept_receipt_id = run.accept_receipt_id,
                            source_event_id = run.source_event_id or source_event_id,
                        },
                        source_event_id = run.source_event_id or source_event_id,
                    }
                    break
                end
            end
        end
    end
    table_sort(chain_accepts, function(left, right)
        return left.quest_id < right.quest_id
    end)
    return result_ok({ chain_accepts = chain_accepts })
end

local function consume_delivery_costs(state, plan, input)
    local costs = QuestSession.collect_delivery_costs(
        state.session,
        state.catalog,
        plan.run.run_id
    )
    if not costs.ok then
        return costs
    end
    if #costs.value.costs == 0 then
        return result_ok({
            status = 'SKIPPED',
            reason = 'NO_DELIVERY_COSTS',
            costs = {},
        })
    end
    if state.inventory_service == nil then
        return fail(
            QuestErrorCodes.QUEST_INVENTORY_REQUIRED,
            'INVENTORY_SERVICE_REQUIRED_FOR_DELIVERY',
            {
                run_id = plan.run.run_id,
                cost_count = #costs.value.costs,
            },
            false
        )
    end
    local consumed = state.inventory_service:consume_items({
        items = costs.value.costs,
        purpose_type = 'QUEST_DELIVERY',
        purpose_ref = plan.run.quest_id,
        player_save_scope = raw_get(input, 'player_save_scope'),
        player_ref = raw_get(input, 'player_ref'),
        request_id = raw_get(input, 'request_id'),
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
        skip_save = raw_get(input, 'skip_save') == true,
    })
    if not consumed.ok then
        return fail(
            QuestErrorCodes.QUEST_DELIVERY_FAILED,
            'CONSUME_DELIVERY_FAILED',
            {
                cause_code = consumed.error and consumed.error.code or 'UNKNOWN',
                run_id = plan.run.run_id,
            },
            consumed.error and consumed.error.retryable == true
        )
    end
    return result_ok({
        status = consumed.value.status or 'COMMITTED',
        costs = costs.value.costs,
        inventory_revision = consumed.value.inventory_revision,
        save = consumed.value.save,
    })
end

function Service:complete(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end

    local plan = QuestSession.validate_complete(
        session.value,
        state.catalog,
        input
    )
    if not plan.ok then
        return plan
    end

    if plan.value.already_completed then
        local reward_result = nil
        if plan.value.reward_policy ~= 'NO_REWARD'
            and plan.value.reward_id ~= nil
            and plan.value.reward_receipt_id ~= nil
        then
            reward_result = {
                status = 'COMMITTED',
                already_committed = true,
                receipt_id = plan.value.reward_receipt_id,
                reward_id = plan.value.reward_id,
            }
        elseif plan.value.reward_policy == 'NO_REWARD' then
            reward_result = {
                status = 'SKIPPED',
                reason = 'NO_REWARD',
            }
        end
        local events = {}
        local event = QuestEvents.build_completed({
            run_id = plan.value.run.run_id,
            quest_id = plan.value.run.quest_id,
            completion_receipt_id = plan.value.completion_receipt_id
                or plan.value.run.completion_receipt_id,
            reward_receipt_id = plan.value.reward_receipt_id,
            reward_state = reward_result and reward_result.status or 'NOT_REQUIRED',
            revision = plan.value.run.quest_revision or 1,
        })
        if event.ok then
            events[1] = event.value
        end
        local chain = collect_existing_chain_accepts(
            state,
            plan.value.run.quest_id,
            event.ok and event.value.event_id or nil
        )
        if not chain.ok then
            return chain
        end
        return result_ok({
            run = plan.value.run,
            already_completed = true,
            command_replay = plan.value.command_replay == true,
            reward = reward_result,
            delivery = {
                status = 'SKIPPED',
                reason = 'ALREADY_COMPLETED',
            },
            reward_id = plan.value.reward_id,
            reward_policy = plan.value.reward_policy,
            reward_receipt_id = plan.value.reward_receipt_id,
            events = events,
            domain_events = events,
            chain_accepts = chain.value.chain_accepts,
            persisted = false,
            save = {
                status = 'SKIPPED',
                reason = 'ALREADY_COMPLETED',
            },
        })
    end

    -- 2) Preflight owner services and prepare reward before any mutation so a
    -- REJECT reward path never deducts delivery items.
    local delivery_plan = QuestSession.collect_delivery_costs(
        session.value,
        state.catalog,
        plan.value.run.run_id
    )
    if not delivery_plan.ok then
        return delivery_plan
    end
    if #delivery_plan.value.costs > 0 and state.inventory_service == nil then
        return fail(
            QuestErrorCodes.QUEST_INVENTORY_REQUIRED,
            'INVENTORY_SERVICE_REQUIRED_FOR_DELIVERY',
            {
                run_id = plan.value.run.run_id,
                cost_count = #delivery_plan.value.costs,
            },
            false
        )
    end
    if plan.value.needs_reward and state.economy_service == nil then
        return fail(
            QuestErrorCodes.QUEST_REWARD_REQUIRED,
            'ECONOMY_SERVICE_REQUIRED',
            {
                reward_id = plan.value.reward_id,
                run_id = plan.value.run.run_id,
            },
            false
        )
    end

    local prepared_reward = nil
    if plan.value.needs_reward then
        prepared_reward = state.economy_service:prepare_reward({
            reward_id = plan.value.reward_id,
            source_type = 'QUEST_COMPLETION',
            source_ref = plan.value.run.quest_id,
            source_occurrence_id = plan.value.run.run_id,
            overflow_policy = raw_get(input, 'overflow_policy'),
        })
        if not prepared_reward.ok then
            return fail(
                QuestErrorCodes.QUEST_REWARD_FAILED,
                'PREPARE_REWARD_FAILED',
                {
                    cause_code = prepared_reward.error
                        and prepared_reward.error.code
                        or 'UNKNOWN',
                    reward_id = plan.value.reward_id,
                    run_id = plan.value.run.run_id,
                },
                prepared_reward.error and prepared_reward.error.retryable == true
            )
        end
    end

    -- 3) Consume DELIVER_ITEM costs, then grant reward, then COMPLETED.
    -- When completion multi-slot bridge is bound, owner services mutate in-memory
    -- only (skip_save) and one checkpoint writes slots 2/4/5 together.
    local defer_owner_saves = state.completion_save_bridge ~= nil
    local owner_input = input
    if defer_owner_saves then
        owner_input = {}
        local key
        local value
        for key, value in pairs_value(input) do
            owner_input[key] = value
        end
        owner_input.skip_save = true
    end

    local delivery = consume_delivery_costs(state, plan.value, owner_input)
    if not delivery.ok then
        return delivery
    end

    local reward_result = {
        status = 'SKIPPED',
        reason = 'NO_REWARD',
    }
    local reward_receipt_id = nil
    if plan.value.needs_reward then
        local granted = grant_quest_reward(
            state.economy_service,
            plan.value,
            owner_input
        )
        if not granted.ok then
            return granted
        end
        reward_result = granted.value
        reward_receipt_id = granted.value.receipt_id
    end

    -- 4) Commit quest COMPLETED.
    local complete_input = {}
    local key
    local value
    for key, value in pairs_value(input) do
        complete_input[key] = value
    end
    complete_input.reward_receipt_id = reward_receipt_id

    local completed = QuestSession.complete(
        session.value,
        state.catalog,
        complete_input
    )
    if not completed.ok then
        return completed
    end

    local reward_state = reward_result.status or 'NOT_REQUIRED'
    local event = QuestEvents.build_completed({
        run_id = completed.value.run.run_id,
        quest_id = completed.value.run.quest_id,
        completion_receipt_id = completed.value.run.completion_receipt_id,
        reward_receipt_id = completed.value.reward_receipt_id,
        reward_state = reward_state,
        revision = completed.value.run.quest_revision,
    })
    if not event.ok then
        return event
    end

    -- Chain accept still goes through AcceptQuest with QuestCompleted event id.
    local chain = accept_chain_successors(
        state,
        completed.value.run.quest_id,
        event.value.event_id,
        complete_input
    )
    if not chain.ok then
        return chain
    end

    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end

    local saved
    if state.completion_save_bridge ~= nil then
        local player_save_scope = raw_get(input, 'player_save_scope')
        if player_save_scope == nil then
            saved = result_ok({
                status = 'SKIPPED',
                reason = 'PLAYER_SAVE_SCOPE_MISSING',
            })
        else
            local request_id = raw_get(input, 'request_id')
            local command_id = raw_get(input, 'command_id')
            if type_value(request_id) ~= 'string' or request_id == '' then
                if type_value(command_id) == 'string' and command_id ~= '' then
                    request_id = command_id .. '_quest_completion_save'
                else
                    request_id = 'request_quest_completion_save'
                end
            end
            local ckpt_command_id = nil
            if type_value(command_id) == 'string' and command_id ~= '' then
                ckpt_command_id = command_id .. '_quest_completion_ckpt'
            end
            saved = state.completion_save_bridge:persist_completion({
                player_save_scope = player_save_scope,
                player_ref = raw_get(input, 'player_ref') or player_save_scope,
                request_id = request_id,
                command_id = ckpt_command_id,
                save_seed = raw_get(input, 'save_seed'),
                content_version = raw_get(input, 'content_version'),
            })
        end
    else
        saved = maybe_persist_save(state, input)
    end
    if not saved.ok then
        return saved
    end

    return result_ok({
        run = completed.value.run,
        already_completed = false,
        command_replay = false,
        reward = reward_result,
        delivery = delivery.value,
        reward_id = completed.value.reward_id,
        reward_policy = completed.value.reward_policy,
        reward_receipt_id = completed.value.reward_receipt_id,
        events = { event.value },
        domain_events = { event.value },
        chain_accepts = chain.value.chain_accepts,
        persisted = persisted.value.persisted,
        save = saved.value,
    })
end

function Service:abandon(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    local abandoned = QuestSession.abandon(session.value, input)
    if not abandoned.ok then
        return abandoned
    end
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    abandoned.value.persisted = persisted.value.persisted
    local saved = maybe_persist_save(state, input)
    if not saved.ok then
        return saved
    end
    abandoned.value.save = saved.value
    return abandoned
end

function Service:get_run(run_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    return QuestSession.get_run(session.value, run_id)
end

function Service:get_journal()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    return QuestSession.get_journal(session.value, state.catalog)
end

function Service:evaluate_availability(quest_id, context)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    return QuestSession.evaluate_availability(
        session.value,
        state.catalog,
        quest_id,
        context
    )
end

function Service:list_availability(context)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    return QuestSession.list_availability(
        session.value,
        state.catalog,
        context
    )
end

function Service:reveal_hidden_quest(quest_id, save_context)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    local revealed = QuestSession.reveal_hidden_quest(session.value, quest_id)
    if not revealed.ok then
        return revealed
    end
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    revealed.value.persisted = persisted.value.persisted
    local saved = maybe_persist_save(state, save_context, {
        skip = revealed.value.already_revealed == true,
        skip_reason = 'ALREADY_REVEALED',
    })
    if not saved.ok then
        return saved
    end
    revealed.value.save = saved.value
    return revealed
end

function Service:track(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    local tracked = QuestSession.track(session.value, input)
    if not tracked.ok then
        return tracked
    end
    local persisted = persist_session(state)
    if not persisted.ok then
        return persisted
    end
    tracked.value.persisted = persisted.value.persisted
    local saved = maybe_persist_save(state, input, {
        skip = tracked.value.command_replay == true
            or tracked.value.already_applied == true,
        skip_reason = 'REPLAY_OR_EXISTING',
    })
    if not saved.ok then
        return saved
    end
    tracked.value.save = saved.value
    return tracked
end

function Service:get_tracked()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local session = load_session(state)
    if not session.ok then
        return session
    end
    return QuestSession.get_tracked(session.value)
end

return QuestService
