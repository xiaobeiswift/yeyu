-- Build the durable EncounterCompleted domain fact (system 07 → consumers).
-- Only produced after settlement is committed; never from combat UI or CombatFinished.

local DomainEvent = require 'wzx.domain.common.domain_event'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Sha256 = require 'wzx.domain.common.sha256'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local EncounterCompletedEvent = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local math_floor = math.floor
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type

local SOURCE_SYSTEM = '07'
local EVENT_TYPE = 'EncounterCompleted'

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

local function copy_tags(tags)
    local out = {}
    if type_value(tags) ~= 'table' then
        return out
    end
    local index
    for index = 1, #tags do
        out[index] = tags[index]
    end
    return out
end

--- Aggregate victory-count spawn rows from cleared waves into defeated_entries.
-- @return ok + ordered array of { enemy_id, count, tags? }
function EncounterCompletedEvent.build_defeated_entries(catalog, run)
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_wave) ~= 'function'
    then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end

    local totals = {}
    local tags_by_enemy = {}
    local wave_index
    local cleared = run.cleared_wave_ids or {}
    for wave_index = 1, #cleared do
        local wave_id = cleared[wave_index]
        local wave = catalog:require_wave(wave_id)
        if not wave.ok then
            return wave
        end
        local rows = wave.value.spawn_rows or {}
        local row_index
        for row_index = 1, #rows do
            local row = rows[row_index]
            if type_value(row) == 'table'
                and row.counts_for_victory ~= false
                and type_value(row.enemy_id) == 'string'
            then
                local enemy_id = row.enemy_id
                totals[enemy_id] = (totals[enemy_id] or 0) + 1
                if tags_by_enemy[enemy_id] == nil
                    and type_value(catalog.require_enemy) == 'function'
                then
                    local enemy = catalog:require_enemy(enemy_id)
                    if enemy.ok then
                        tags_by_enemy[enemy_id] = copy_tags(enemy.value.default_tags)
                    end
                end
            end
        end
    end

    local enemy_ids = {}
    local enemy_id
    for enemy_id in raw_next, totals do
        enemy_ids[#enemy_ids + 1] = enemy_id
    end
    table_sort(enemy_ids, bytewise_string_less)

    local entries = {}
    local index
    for index = 1, #enemy_ids do
        enemy_id = enemy_ids[index]
        local entry = {
            enemy_id = enemy_id,
            count = totals[enemy_id],
        }
        local tags = tags_by_enemy[enemy_id]
        if tags ~= nil and #tags > 0 then
            entry.tags = tags
        end
        entries[index] = entry
    end
    return result_ok(entries)
end

--- Build a validated EncounterCompleted envelope from a settled victory run.
-- @param run settled run table (state COMPLETED, settlement_plan present)
-- @param options.catalog required for defeated_entries; optional if overridden
-- @param options.defeated_entries optional precomputed list
-- @param options.completion_count optional integer from progress authority
-- @return ok + domain event, or error
function EncounterCompletedEvent.build(run, options)
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end
    options = options or {}
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_REQUIRED')
    end

    local plan = raw_get(run, 'settlement_plan')
    if type_value(plan) ~= 'table' then
        return invalid('SETTLEMENT_PLAN_REQUIRED')
    end
    if plan.is_victory ~= true then
        return result_ok(nil)
    end

    local settlement_receipt_id = plan.settlement_receipt_id
        or run.settlement_receipt_id
    local receipt_check = RuntimeId.validate_derived(
        settlement_receipt_id,
        'settlement_receipt_id'
    )
    if not receipt_check.ok then
        return invalid('SETTLEMENT_RECEIPT_INVALID')
    end

    local run_id = plan.run_id or run.run_id
    local run_check = RuntimeId.validate_derived(run_id, 'run_id')
    if not run_check.ok then
        return invalid('RUN_ID_INVALID')
    end

    local encounter_id = plan.encounter_id or run.encounter_id
    local encounter_check = RuntimeId.validate_content(
        encounter_id,
        'encounter_',
        'encounter_id'
    )
    if not encounter_check.ok then
        return invalid('ENCOUNTER_ID_INVALID')
    end

    local defeated = raw_get(options, 'defeated_entries')
    if defeated == nil then
        local catalog = raw_get(options, 'catalog')
        if catalog == nil then
            defeated = {}
        else
            local built = EncounterCompletedEvent.build_defeated_entries(catalog, run)
            if not built.ok then
                return built
            end
            defeated = built.value
        end
    elseif type_value(defeated) ~= 'table' or get_metatable(defeated) ~= nil then
        return invalid('DEFEATED_ENTRIES_INVALID')
    end

    local completion_count = raw_get(options, 'completion_count')
    if completion_count == nil then
        completion_count = 1
    elseif type_value(completion_count) ~= 'number'
        or completion_count < 1
        or completion_count ~= math_floor(completion_count)
    then
        return invalid('COMPLETION_COUNT_INVALID')
    end

    local revision = run.revision or 0
    if type_value(revision) ~= 'number' or revision < 0 then
        revision = 0
    end

    -- event_id must use short derived components (<=64 bytes each).
    -- Hash the settlement receipt so long receipt_* ids remain stable and unique.
    local event_digest, digest_error = Sha256.hex(
        'EncounterCompleted|' .. settlement_receipt_id
    )
    if event_digest == nil then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'EVENT_ID_HASH_FAILED',
            { reason = digest_error }
        )
    end
    local event_id = 'enc:done:' .. event_digest
    local payload = {
        encounter_id = encounter_id,
        run_id = run_id,
        result = plan.outcome or 'ATTACKER_WIN',
        completion_fact_id = plan.completion_fact_id or run.completion_fact_id,
        is_first_clear = plan.is_first_clear == true,
        completion_count = completion_count,
        settlement_receipt_id = settlement_receipt_id,
        rules_version = plan.rules_version or run.rules_version,
        result_hash = plan.result_hash or run.result_hash,
        defeated_entries = defeated,
    }

    local event = {
        event_id = event_id,
        event_type = EVENT_TYPE,
        schema_version = 1,
        aggregate_id = run_id,
        revision = revision,
        payload = payload,
        source_system = SOURCE_SYSTEM,
        causation_id = settlement_receipt_id,
    }
    -- source_occurrence_id is atomic (no ':'); only attach when receipt is a component.
    local occurrence = RuntimeId.validate_component(
        settlement_receipt_id,
        'source_occurrence_id'
    )
    if occurrence.ok then
        event.source_occurrence_id = settlement_receipt_id
    end

    local validated = DomainEvent.validate(event)
    if not validated.ok then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'COMPLETION_EVENT_INVALID',
            {
                cause_code = validated.error and validated.error.code or 'UNKNOWN',
                cause_reason = validated.error
                    and validated.error.details
                    and validated.error.details.reason,
            }
        )
    end

    return DomainEvent.copy(event)
end

EncounterCompletedEvent.EVENT_TYPE = EVENT_TYPE
EncounterCompletedEvent.SOURCE_SYSTEM = SOURCE_SYSTEM

return EncounterCompletedEvent
