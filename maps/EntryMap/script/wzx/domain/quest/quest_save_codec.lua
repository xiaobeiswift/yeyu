local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local QuestErrorCodes = require 'wzx.domain.quest.error_codes'
local QuestSession = require 'wzx.domain.quest.quest_session'

local QuestSaveCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local CURRENT_SCHEMA_VERSION = 1
local MAX_RUNS = 256
local MAX_OBJECTIVES = 2048
local MAX_EVENT_RECEIPTS = 2048
local MAX_SAFE_INTEGER = 9007199254740991

local BUNDLE_FIELDS = {
    quest_metadata = true,
    quest_runs = true,
    quest_objectives = true,
    quest_event_receipts = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    session_revision = true,
}
local RUN_FIELDS = {
    run_id = true,
    quest_id = true,
    definition_version = true,
    status = true,
    current_stage_id = true,
    accept_receipt_id = true,
    completion_receipt_id = true,
    quest_revision = true,
    stage_entry_ordinal = true,
    reward_policy = true,
    reward_id = true,
    turn_in_npc_id = true,
    abandon_policy = true,
    category = true,
}
local OBJECTIVE_FIELDS = {
    run_id = true,
    objective_id = true,
    progress = true,
    status = true,
    last_fact_event_id = true,
    state_revision = true,
}
local EVENT_FIELDS = {
    event_id = true,
    event_type = true,
    applied_change_count = true,
}

local function failure(code, message_key, reason, details)
    local copied = {}
    local key
    local value
    if type_value(details) == 'table' then
        for key, value in raw_next, details do
            copied[key] = value
        end
    end
    copied.reason = reason
    return result_err(code, message_key, false, copied)
end

local function invalid(reason, details)
    return failure(
        QuestErrorCodes.QUEST_SAVE_INVALID,
        'error.quest.save_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        QuestErrorCodes.QUEST_SAVE_LIMIT_EXCEEDED,
        'error.quest.save_limit_exceeded',
        reason,
        details
    )
end

local function no_unknown_fields(value, allowed, path)
    if type_value(value) ~= 'table' then
        return invalid('TABLE_REQUIRED', { field = path })
    end
    local key
    for key in raw_next, value do
        if type_value(key) ~= 'string' or not allowed[key] then
            return invalid('UNKNOWN_FIELD', {
                field = path == '$' and tostring(key) or (path .. '.' .. tostring(key)),
            })
        end
    end
    return nil
end

function QuestSaveCodec.encode(session)
    if type_value(session) ~= 'table' then
        return invalid('SESSION_REQUIRED')
    end
    if not is_integer(session.session_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('SESSION_REVISION_INVALID')
    end

    local run_ids = {}
    local run_id
    for run_id in raw_next, (session.runs or {}) do
        run_ids[#run_ids + 1] = run_id
    end
    table_sort(run_ids, bytewise_string_less)
    if #run_ids > MAX_RUNS then
        return limit_exceeded('RUN_LIMIT', { maximum = MAX_RUNS })
    end

    local quest_runs = {}
    local index
    for index = 1, #run_ids do
        local run = session.runs[run_ids[index]]
        local err = no_unknown_fields(run, RUN_FIELDS, 'runs')
        if err ~= nil then
            return err
        end
        quest_runs[index] = {
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

    local objective_keys = {}
    local key
    for key in raw_next, (session.objectives or {}) do
        objective_keys[#objective_keys + 1] = key
    end
    table_sort(objective_keys, bytewise_string_less)
    if #objective_keys > MAX_OBJECTIVES then
        return limit_exceeded('OBJECTIVE_LIMIT', { maximum = MAX_OBJECTIVES })
    end
    local quest_objectives = {}
    for index = 1, #objective_keys do
        local row = session.objectives[objective_keys[index]]
        quest_objectives[index] = {
            run_id = row.run_id,
            objective_id = row.objective_id,
            progress = row.progress,
            status = row.status,
            last_fact_event_id = row.last_fact_event_id,
            state_revision = row.state_revision,
        }
    end

    local event_ids = {}
    for key in raw_next, (session.event_receipts or {}) do
        event_ids[#event_ids + 1] = key
    end
    table_sort(event_ids, bytewise_string_less)
    if #event_ids > MAX_EVENT_RECEIPTS then
        return limit_exceeded('EVENT_RECEIPT_LIMIT', { maximum = MAX_EVENT_RECEIPTS })
    end
    local quest_event_receipts = {}
    for index = 1, #event_ids do
        local row = session.event_receipts[event_ids[index]]
        quest_event_receipts[index] = {
            event_id = row.event_id,
            event_type = row.event_type,
            applied_change_count = row.applied_change_count,
        }
    end

    return result_ok({
        quest_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            session_revision = session.session_revision,
        },
        quest_runs = quest_runs,
        quest_objectives = quest_objectives,
        quest_event_receipts = quest_event_receipts,
    })
end

function QuestSaveCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    err = no_unknown_fields(bundle.quest_metadata, METADATA_FIELDS, 'quest_metadata')
    if err ~= nil then
        return err
    end
    if bundle.quest_metadata.schema_version ~= CURRENT_SCHEMA_VERSION then
        return failure(
            QuestErrorCodes.QUEST_SAVE_VERSION_UNSUPPORTED,
            'error.quest.save_version_unsupported',
            'SCHEMA_VERSION_UNSUPPORTED',
            { schema_version = bundle.quest_metadata.schema_version }
        )
    end

    local session = QuestSession.empty()
    session.session_revision = bundle.quest_metadata.session_revision

    local index
    for index = 1, #(bundle.quest_runs or {}) do
        local run = bundle.quest_runs[index]
        err = no_unknown_fields(run, RUN_FIELDS, 'quest_runs')
        if err ~= nil then
            return err
        end
        session.runs[run.run_id] = {
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
    for index = 1, #(bundle.quest_objectives or {}) do
        local row = bundle.quest_objectives[index]
        err = no_unknown_fields(row, OBJECTIVE_FIELDS, 'quest_objectives')
        if err ~= nil then
            return err
        end
        local key = row.run_id .. '|' .. row.objective_id
        session.objectives[key] = {
            run_id = row.run_id,
            objective_id = row.objective_id,
            progress = row.progress,
            status = row.status,
            last_fact_event_id = row.last_fact_event_id,
            state_revision = row.state_revision,
        }
    end
    for index = 1, #(bundle.quest_event_receipts or {}) do
        local row = bundle.quest_event_receipts[index]
        err = no_unknown_fields(row, EVENT_FIELDS, 'quest_event_receipts')
        if err ~= nil then
            return err
        end
        session.event_receipts[row.event_id] = {
            event_id = row.event_id,
            event_type = row.event_type,
            applied_change_count = row.applied_change_count,
        }
    end
    return result_ok(session)
end

return QuestSaveCodec
