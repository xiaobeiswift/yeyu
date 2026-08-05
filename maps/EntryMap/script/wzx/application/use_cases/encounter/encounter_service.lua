-- Application facade for system 07 encounter runs + system 10 reward grant
-- + optional encounter progress authority (slot 2 facts).

local Result = require 'wzx.domain.common.result'
local EncounterRun = require 'wzx.domain.encounter.encounter_run'
local EncounterCompletedEvent = require 'wzx.domain.encounter.encounter_completed_event'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local EncounterService = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('encounter service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.encounter.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID, reason, details, false)
end

local function is_economy_service(value)
    return type_value(value) == 'table'
        and type_value(value.prepare_reward) == 'function'
        and type_value(value.grant_prepared_reward) == 'function'
end

local function is_progress_store(value)
    return type_value(value) == 'table'
        and type_value(value.is_first_clear_already) == 'function'
        and type_value(value.mark_discovered) == 'function'
        and type_value(value.record_victory) == 'function'
end

function EncounterService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    local economy_service = raw_get(options, 'economy_service')
    local progress_store = raw_get(options, 'progress_store')
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_encounter) ~= 'function'
        or type_value(catalog.require_wave) ~= 'function'
    then
        return invalid('ENCOUNTER_CATALOG_REQUIRED', { field = 'catalog' })
    end
    if economy_service ~= nil and not is_economy_service(economy_service) then
        return invalid('ECONOMY_SERVICE_INVALID', { field = 'economy_service' })
    end
    if progress_store ~= nil and not is_progress_store(progress_store) then
        return invalid('PROGRESS_STORE_INVALID', { field = 'progress_store' })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        economy_service = economy_service,
        progress_store = progress_store,
    }
    return result_ok(view)
end

function EncounterService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

function Service:prepare(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local prepared_input = {}
    local key
    local value
    for key, value in pairs(input) do
        prepared_input[key] = value
    end

    local encounter = state.catalog:require_encounter(prepared_input.encounter_id)
    if not encounter.ok then
        return encounter
    end

    -- Prefer explicit override; otherwise read first-clear fact from progress store.
    if prepared_input.first_clear_already == nil and state.progress_store ~= nil then
        local already = state.progress_store:is_first_clear_already(
            prepared_input.encounter_id
        )
        if not already.ok then
            return already
        end
        prepared_input.first_clear_already = already.value == true
    end

    local prepared = EncounterRun.prepare(state.catalog, prepared_input)
    if not prepared.ok then
        return prepared
    end

    if state.progress_store ~= nil then
        local discovered = state.progress_store:mark_discovered(
            prepared.value.encounter_id,
            prepared.value.rules_version
        )
        if not discovered.ok then
            return discovered
        end
        prepared.value.progress = {
            discovered = true,
            first_clear_already = prepared.value.first_clear_already == true,
            progress_revision = discovered.value.progress_revision,
            row = discovered.value.row,
        }
    end

    return prepared
end

function Service:activate_combat(run)
    if STATES[self] == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return EncounterRun.activate_combat(run)
end

function Service:record_combat_result(run, combat_result)
    if STATES[self] == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return EncounterRun.record_combat_result(run, combat_result)
end

function Service:advance_wave(run)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return EncounterRun.advance_wave(run, state.catalog)
end

function Service:abandon(run, reason)
    if STATES[self] == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return EncounterRun.abandon(run, reason)
end

function Service:get_public_view(run)
    if STATES[self] == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return EncounterRun.get_public_view(run)
end

function Service:get_progress(encounter_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if state.progress_store == nil then
        return fail(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'PROGRESS_STORE_REQUIRED',
            {},
            false
        )
    end
    return state.progress_store:get_row(encounter_id)
end

local function build_reward_source(plan)
    if plan.is_first_clear then
        return {
            source_type = 'ENCOUNTER_FIRST_CLEAR',
            source_occurrence_id = 'fc_' .. plan.encounter_id,
            purpose_type = 'ENCOUNTER_FIRST_CLEAR',
        }
    end
    return {
        source_type = 'ENCOUNTER_REPEAT',
        source_occurrence_id = plan.run_id,
        purpose_type = 'ENCOUNTER_REPEAT',
    }
end

local function grant_settlement_reward(economy_service, plan, input)
    local identities = build_reward_source(plan)
    local prepared_payload
    local prepared_id
    local entry_count
    local loot_meta = nil

    -- Priority: loot_table_id → prepare_loot; else reward_bundle_id → prepare_reward.
    -- When loot is configured, never silently fall back to bundle.
    if plan.loot_table_id ~= nil then
        if type_value(economy_service.prepare_loot) ~= 'function' then
            return fail(
                EncounterErrorCodes.ENCOUNTER_REWARD_GRANT_FAILED,
                'PREPARE_LOOT_UNSUPPORTED',
                {
                    loot_table_id = plan.loot_table_id,
                    reward_bundle_id = plan.reward_bundle_id,
                },
                false
            )
        end
        local root_seed = plan.root_seed
        if root_seed == nil then
            root_seed = raw_get(input, 'root_seed')
        end
        if root_seed == nil then
            return fail(
                EncounterErrorCodes.ENCOUNTER_REWARD_GRANT_FAILED,
                'ROOT_SEED_REQUIRED_FOR_LOOT',
                {
                    loot_table_id = plan.loot_table_id,
                },
                false
            )
        end
        local prepared = economy_service:prepare_loot({
            loot_id = plan.loot_table_id,
            root_seed = root_seed,
            source_type = identities.source_type,
            source_ref = plan.loot_table_id,
            source_occurrence_id = identities.source_occurrence_id,
            overflow_policy = raw_get(input, 'overflow_policy'),
        })
        if not prepared.ok then
            return fail(
                EncounterErrorCodes.ENCOUNTER_REWARD_GRANT_FAILED,
                'PREPARE_LOOT_FAILED',
                {
                    cause_code = prepared.error and prepared.error.code or 'UNKNOWN',
                    cause_reason = prepared.error
                        and prepared.error.details
                        and prepared.error.details.reason
                        or nil,
                    loot_table_id = plan.loot_table_id,
                },
                prepared.error and prepared.error.retryable == true
            )
        end
        -- prepare_loot wraps PreparedReward under .prepared and attaches .loot.
        prepared_payload = prepared.value.prepared
        prepared_id = prepared_payload.prepared_id
        entry_count = #prepared_payload.entries
        loot_meta = prepared.value.loot
    else
        local prepared = economy_service:prepare_reward({
            reward_id = plan.reward_bundle_id,
            source_type = identities.source_type,
            source_ref = plan.reward_bundle_id,
            source_occurrence_id = identities.source_occurrence_id,
            overflow_policy = raw_get(input, 'overflow_policy'),
        })
        if not prepared.ok then
            return fail(
                EncounterErrorCodes.ENCOUNTER_REWARD_GRANT_FAILED,
                'PREPARE_REWARD_FAILED',
                {
                    cause_code = prepared.error and prepared.error.code or 'UNKNOWN',
                    reward_bundle_id = plan.reward_bundle_id,
                },
                prepared.error and prepared.error.retryable == true
            )
        end
        prepared_payload = prepared.value
        prepared_id = prepared_payload.prepared_id
        entry_count = #prepared_payload.entries
    end

    local granted = economy_service:grant_prepared_reward({
        prepared = prepared_payload,
        receipt_id = plan.settlement_receipt_id,
        purpose_type = identities.purpose_type,
        purpose_ref = plan.encounter_id,
        player_save_scope = raw_get(input, 'player_save_scope'),
        player_ref = raw_get(input, 'player_ref'),
        request_id = raw_get(input, 'request_id'),
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
    if not granted.ok then
        return fail(
            EncounterErrorCodes.ENCOUNTER_REWARD_GRANT_FAILED,
            'GRANT_REWARD_FAILED',
            {
                cause_code = granted.error and granted.error.code or 'UNKNOWN',
                reward_bundle_id = plan.reward_bundle_id,
                loot_table_id = plan.loot_table_id,
                settlement_receipt_id = plan.settlement_receipt_id,
            },
            granted.error and granted.error.retryable == true
        )
    end

    return result_ok({
        status = granted.value.status or 'COMMITTED',
        already_committed = granted.value.already_committed == true,
        receipt_id = granted.value.receipt_id,
        request_hash = granted.value.request_hash,
        result_hash = granted.value.result_hash,
        economy_revision = granted.value.economy_revision,
        source_type = identities.source_type,
        source_occurrence_id = identities.source_occurrence_id,
        reward_bundle_id = plan.reward_bundle_id,
        loot_table_id = plan.loot_table_id,
        prepared_id = prepared_id,
        entry_count = entry_count,
        loot = loot_meta,
        save = granted.value.save,
    })
end

--- Settle a terminal encounter run and grant rewards through economy when due.
-- Victory with loot_table_id or reward_bundle_id requires a bound economy_service.
-- Loot path: prepare_loot then grant; bundle path: prepare_reward then grant.
-- Defeat / abandon / no-reward victory skip economy and still complete.
-- On victory, optional progress_store records first_clear/completion facts.
function Service:settle(run, input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED', { field = 'run' })
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local settlement_receipt_id = raw_get(input, 'settlement_receipt_id')
    if run.state == EncounterRun.PHASE.COMPLETED
        and run.settlement_receipt_id == settlement_receipt_id
    then
        local completion_event = run.completion_event
        if completion_event == nil and run.settlement_plan ~= nil then
            local completion_count = nil
            if run.progress_update ~= nil
                and run.progress_update.row ~= nil
            then
                completion_count = run.progress_update.row.completion_count
            end
            local built = EncounterCompletedEvent.build(run, {
                catalog = state.catalog,
                completion_count = completion_count,
            })
            if not built.ok then
                return built
            end
            completion_event = built.value
            run.completion_event = completion_event
        end
        return result_ok({
            state = run.state,
            plan = run.settlement_plan,
            reward = run.reward_grant,
            progress = run.progress_update,
            completion_event = completion_event,
            idempotent = true,
        })
    end

    local planned = EncounterRun.plan_settlement(run, settlement_receipt_id)
    if not planned.ok then
        return planned
    end
    local plan = planned.value.plan

    local reward_result
    if plan.grants_normal_reward then
        if state.economy_service == nil then
            return fail(
                EncounterErrorCodes.ENCOUNTER_REWARD_SERVICE_REQUIRED,
                'ECONOMY_SERVICE_REQUIRED_FOR_REWARD',
                {
                    loot_table_id = plan.loot_table_id,
                    reward_bundle_id = plan.reward_bundle_id,
                    is_first_clear = plan.is_first_clear,
                },
                false
            )
        end
        local granted = grant_settlement_reward(state.economy_service, plan, input)
        if not granted.ok then
            return granted
        end
        reward_result = granted.value
    else
        reward_result = {
            status = 'SKIPPED',
            reason = plan.is_victory and 'NO_REWARD_BUNDLE' or 'NOT_VICTORY',
            loot_table_id = plan.loot_table_id,
            reward_bundle_id = plan.reward_bundle_id,
        }
    end

    local progress_result = {
        status = 'SKIPPED',
        reason = 'NO_PROGRESS_STORE',
    }
    if state.progress_store ~= nil then
        if plan.is_victory then
            local recorded = state.progress_store:record_victory({
                encounter_id = plan.encounter_id,
                rules_version = plan.rules_version,
                settlement_receipt_id = plan.settlement_receipt_id,
                run_id = plan.run_id,
            })
            if not recorded.ok then
                return recorded
            end
            progress_result = {
                status = 'COMMITTED',
                already_applied = recorded.value.already_applied == true,
                first_clear_awarded = recorded.value.first_clear_awarded == true,
                row = recorded.value.row,
                progress_revision = recorded.value.progress_revision,
            }
        else
            progress_result = {
                status = 'SKIPPED',
                reason = 'NOT_VICTORY',
            }
        end
    end

    local completed = EncounterRun.complete_settlement(run, settlement_receipt_id)
    if not completed.ok then
        return completed
    end

    run.reward_grant = reward_result
    run.progress_update = progress_result

    local completion_event = nil
    if plan.is_victory then
        local completion_count = nil
        if progress_result.row ~= nil then
            completion_count = progress_result.row.completion_count
        end
        local built = EncounterCompletedEvent.build(run, {
            catalog = state.catalog,
            completion_count = completion_count,
        })
        if not built.ok then
            return built
        end
        completion_event = built.value
        run.completion_event = completion_event
    end

    return result_ok({
        state = completed.value.state,
        plan = plan,
        reward = reward_result,
        progress = progress_result,
        completion_event = completion_event,
        idempotent = completed.value.idempotent == true,
        revision = completed.value.revision or run.revision,
    })
end

return EncounterService
