-- In-memory encounter progress authority (slot 2 facts).

local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local EncounterProgress = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_integer = TableShape.is_integer
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_COMPLETION_COUNT = 1000000

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
    return fail(EncounterErrorCodes.ENCOUNTER_PROGRESS_INVALID, reason, details)
end

local function copy_row(row)
    return {
        encounter_id = row.encounter_id,
        discovered = row.discovered == true,
        first_clear = row.first_clear == true,
        completion_count = row.completion_count,
        last_completion_fact_revision = row.last_completion_fact_revision,
        rules_version = row.rules_version,
    }
end

function EncounterProgress.empty()
    return {
        progress_revision = 0,
        rows = {},
        settlement_receipts = {},
    }
end

function EncounterProgress.get_row(snapshot, encounter_id)
    if type_value(snapshot) ~= 'table' or get_metatable(snapshot) ~= nil then
        return invalid('SNAPSHOT_REQUIRED')
    end
    local checked = validate_content(encounter_id, 'encounter_', 'encounter_id')
    if not checked.ok then
        return invalid('ENCOUNTER_ID_INVALID', { field = 'encounter_id' })
    end
    local row = snapshot.rows and snapshot.rows[encounter_id]
    if row == nil then
        return result_ok(nil)
    end
    return result_ok(copy_row(row))
end

function EncounterProgress.is_first_clear_already(snapshot, encounter_id)
    local row = EncounterProgress.get_row(snapshot, encounter_id)
    if not row.ok then
        return row
    end
    if row.value == nil then
        return result_ok(false)
    end
    return result_ok(row.value.first_clear == true)
end

function EncounterProgress.mark_discovered(snapshot, encounter_id, rules_version)
    if type_value(snapshot) ~= 'table' or get_metatable(snapshot) ~= nil then
        return invalid('SNAPSHOT_REQUIRED')
    end
    local checked = validate_content(encounter_id, 'encounter_', 'encounter_id')
    if not checked.ok then
        return invalid('ENCOUNTER_ID_INVALID', { field = 'encounter_id' })
    end
    if not is_integer(rules_version, 1, MAX_SAFE_INTEGER) then
        return invalid('RULES_VERSION_INVALID', { field = 'rules_version' })
    end

    local rows = {}
    local key
    local value
    for key, value in raw_next, (snapshot.rows or {}) do
        rows[key] = copy_row(value)
    end
    local existing = rows[encounter_id]
    if existing ~= nil then
        if existing.discovered then
            return result_ok({
                snapshot = {
                    progress_revision = snapshot.progress_revision or 0,
                    rows = rows,
                    settlement_receipts = snapshot.settlement_receipts or {},
                },
                changed = false,
                row = existing,
            })
        end
        existing.discovered = true
    else
        rows[encounter_id] = {
            encounter_id = encounter_id,
            discovered = true,
            first_clear = false,
            completion_count = 0,
            last_completion_fact_revision = 0,
            rules_version = rules_version,
        }
    end

    local next_revision = (snapshot.progress_revision or 0) + 1
    if next_revision > MAX_SAFE_INTEGER then
        return invalid('PROGRESS_REVISION_OVERFLOW')
    end
    local receipts = {}
    for key, value in raw_next, (snapshot.settlement_receipts or {}) do
        receipts[key] = {
            settlement_receipt_id = value.settlement_receipt_id,
            encounter_id = value.encounter_id,
            run_id = value.run_id,
            status = value.status,
        }
    end
    return result_ok({
        snapshot = {
            progress_revision = next_revision,
            rows = rows,
            settlement_receipts = receipts,
        },
        changed = true,
        row = copy_row(rows[encounter_id]),
    })
end

--- Record a victorious settlement against progress authority.
-- Idempotent on settlement_receipt_id.
function EncounterProgress.record_victory(snapshot, input)
    if type_value(snapshot) ~= 'table' or get_metatable(snapshot) ~= nil then
        return invalid('SNAPSHOT_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local encounter_id = raw_get(input, 'encounter_id')
    local rules_version = raw_get(input, 'rules_version')
    local settlement_receipt_id = raw_get(input, 'settlement_receipt_id')
    local run_id = raw_get(input, 'run_id')

    local checked = validate_content(encounter_id, 'encounter_', 'encounter_id')
    if not checked.ok then
        return invalid('ENCOUNTER_ID_INVALID', { field = 'encounter_id' })
    end
    if not is_integer(rules_version, 1, MAX_SAFE_INTEGER) then
        return invalid('RULES_VERSION_INVALID', { field = 'rules_version' })
    end
    local receipt_check = validate_derived(settlement_receipt_id, 'settlement_receipt_id')
    if not receipt_check.ok then
        return invalid('SETTLEMENT_RECEIPT_INVALID', { field = 'settlement_receipt_id' })
    end
    local run_check = validate_derived(run_id, 'run_id')
    if not run_check.ok then
        return invalid('RUN_ID_INVALID', { field = 'run_id' })
    end

    local rows = {}
    local key
    local value
    for key, value in raw_next, (snapshot.rows or {}) do
        rows[key] = copy_row(value)
    end
    local receipts = {}
    for key, value in raw_next, (snapshot.settlement_receipts or {}) do
        receipts[key] = {
            settlement_receipt_id = value.settlement_receipt_id,
            encounter_id = value.encounter_id,
            run_id = value.run_id,
            status = value.status,
        }
    end

    if receipts[settlement_receipt_id] ~= nil then
        local existing_row = rows[encounter_id]
        return result_ok({
            snapshot = {
                progress_revision = snapshot.progress_revision or 0,
                rows = rows,
                settlement_receipts = receipts,
            },
            already_applied = true,
            first_clear_awarded = false,
            row = existing_row and copy_row(existing_row) or nil,
        })
    end

    local row = rows[encounter_id]
    local first_clear_awarded = false
    if row == nil then
        row = {
            encounter_id = encounter_id,
            discovered = true,
            first_clear = true,
            completion_count = 1,
            last_completion_fact_revision = 0,
            rules_version = rules_version,
        }
        first_clear_awarded = true
        rows[encounter_id] = row
    else
        row.discovered = true
        if not row.first_clear then
            row.first_clear = true
            first_clear_awarded = true
        end
        if row.completion_count >= MAX_COMPLETION_COUNT then
            return invalid('COMPLETION_COUNT_CAP', {
                completion_count = row.completion_count,
            })
        end
        row.completion_count = row.completion_count + 1
        row.rules_version = rules_version
    end

    local next_revision = (snapshot.progress_revision or 0) + 1
    if next_revision > MAX_SAFE_INTEGER then
        return invalid('PROGRESS_REVISION_OVERFLOW')
    end
    row.last_completion_fact_revision = next_revision
    receipts[settlement_receipt_id] = {
        settlement_receipt_id = settlement_receipt_id,
        encounter_id = encounter_id,
        run_id = run_id,
        status = 'COMMITTED',
    }

    return result_ok({
        snapshot = {
            progress_revision = next_revision,
            rows = rows,
            settlement_receipts = receipts,
        },
        already_applied = false,
        first_clear_awarded = first_clear_awarded,
        row = copy_row(row),
    })
end

function EncounterProgress.list_rows(snapshot)
    if type_value(snapshot) ~= 'table' or get_metatable(snapshot) ~= nil then
        return invalid('SNAPSHOT_REQUIRED')
    end
    local ids = {}
    local encounter_id
    for encounter_id in raw_next, (snapshot.rows or {}) do
        ids[#ids + 1] = encounter_id
    end
    table_sort(ids, bytewise_string_less)
    local rows = {}
    local index
    for index = 1, #ids do
        rows[index] = copy_row(snapshot.rows[ids[index]])
    end
    return result_ok(rows)
end

return EncounterProgress
