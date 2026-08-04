local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local EncounterSaveCodec = {}
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
local MAX_PROGRESS_ROWS = 256
local MAX_SETTLEMENT_ROWS = 512
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_COMPLETION_COUNT = 1000000

local BUNDLE_FIELDS = {
    encounter_metadata = true,
    encounter_progress_rows = true,
    encounter_settlement_rows = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    progress_revision = true,
}
local PROGRESS_ROW_FIELDS = {
    encounter_id = true,
    discovered = true,
    first_clear = true,
    completion_count = true,
    last_completion_fact_revision = true,
    rules_version = true,
}
local SETTLEMENT_ROW_FIELDS = {
    settlement_receipt_id = true,
    encounter_id = true,
    run_id = true,
    status = true,
}
local SNAPSHOT_FIELDS = {
    progress_revision = true,
    rows = true,
    settlement_receipts = true,
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
        EncounterErrorCodes.ENCOUNTER_SAVE_INVALID,
        'error.encounter.save_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        EncounterErrorCodes.ENCOUNTER_SAVE_LIMIT_EXCEEDED,
        'error.encounter.save_limit_exceeded',
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

function EncounterSaveCodec.encode(snapshot)
    local err = no_unknown_fields(snapshot, SNAPSHOT_FIELDS, '$')
    if err ~= nil then
        return err
    end
    if not is_integer(snapshot.progress_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('PROGRESS_REVISION_INVALID', { field = 'progress_revision' })
    end
    if type_value(snapshot.rows) ~= 'table' then
        return invalid('ROWS_TABLE_REQUIRED', { field = 'rows' })
    end
    if type_value(snapshot.settlement_receipts) ~= 'table' then
        return invalid('SETTLEMENT_RECEIPTS_REQUIRED', {
            field = 'settlement_receipts',
        })
    end

    local encounter_ids = {}
    local encounter_id
    for encounter_id in raw_next, snapshot.rows do
        encounter_ids[#encounter_ids + 1] = encounter_id
    end
    table_sort(encounter_ids, bytewise_string_less)
    if #encounter_ids > MAX_PROGRESS_ROWS then
        return limit_exceeded('PROGRESS_ROW_LIMIT', {
            count = #encounter_ids,
            max_progress_rows = MAX_PROGRESS_ROWS,
        })
    end

    local progress_rows = {}
    local index
    for index = 1, #encounter_ids do
        encounter_id = encounter_ids[index]
        local checked = validate_content(encounter_id, 'encounter_', 'encounter_id')
        if not checked.ok then
            return invalid('ENCOUNTER_ID_INVALID', { encounter_id = encounter_id })
        end
        local row = snapshot.rows[encounter_id]
        if type_value(row) ~= 'table' then
            return invalid('PROGRESS_ROW_INVALID', { encounter_id = encounter_id })
        end
        err = no_unknown_fields(row, PROGRESS_ROW_FIELDS, 'rows.' .. encounter_id)
        if err ~= nil then
            return err
        end
        if row.encounter_id ~= encounter_id then
            return invalid('PROGRESS_ROW_ID_MISMATCH', { encounter_id = encounter_id })
        end
        if type_value(row.discovered) ~= 'boolean'
            or type_value(row.first_clear) ~= 'boolean'
        then
            return invalid('PROGRESS_BOOL_INVALID', { encounter_id = encounter_id })
        end
        if not is_integer(row.completion_count, 0, MAX_COMPLETION_COUNT) then
            return invalid('COMPLETION_COUNT_INVALID', { encounter_id = encounter_id })
        end
        if not is_integer(row.last_completion_fact_revision, 0, MAX_SAFE_INTEGER) then
            return invalid('LAST_COMPLETION_FACT_REVISION_INVALID', {
                encounter_id = encounter_id,
            })
        end
        if not is_integer(row.rules_version, 1, MAX_SAFE_INTEGER) then
            return invalid('RULES_VERSION_INVALID', { encounter_id = encounter_id })
        end
        progress_rows[index] = {
            encounter_id = row.encounter_id,
            discovered = row.discovered,
            first_clear = row.first_clear,
            completion_count = row.completion_count,
            last_completion_fact_revision = row.last_completion_fact_revision,
            rules_version = row.rules_version,
        }
    end

    local receipt_ids = {}
    local receipt_id
    for receipt_id in raw_next, snapshot.settlement_receipts do
        receipt_ids[#receipt_ids + 1] = receipt_id
    end
    table_sort(receipt_ids, bytewise_string_less)
    if #receipt_ids > MAX_SETTLEMENT_ROWS then
        return limit_exceeded('SETTLEMENT_ROW_LIMIT', {
            count = #receipt_ids,
            max_settlement_rows = MAX_SETTLEMENT_ROWS,
        })
    end

    local settlement_rows = {}
    for index = 1, #receipt_ids do
        receipt_id = receipt_ids[index]
        local receipt = snapshot.settlement_receipts[receipt_id]
        if type_value(receipt) ~= 'table' then
            return invalid('SETTLEMENT_RECEIPT_INVALID', {
                settlement_receipt_id = receipt_id,
            })
        end
        err = no_unknown_fields(
            receipt,
            SETTLEMENT_ROW_FIELDS,
            'settlement_receipts.' .. receipt_id
        )
        if err ~= nil then
            return err
        end
        if receipt.settlement_receipt_id ~= receipt_id then
            return invalid('SETTLEMENT_RECEIPT_ID_MISMATCH', {
                settlement_receipt_id = receipt_id,
            })
        end
        local receipt_check = validate_derived(receipt_id, 'settlement_receipt_id')
        if not receipt_check.ok then
            return invalid('SETTLEMENT_RECEIPT_ID_INVALID', {
                settlement_receipt_id = receipt_id,
            })
        end
        local enc_check = validate_content(receipt.encounter_id, 'encounter_', 'encounter_id')
        if not enc_check.ok then
            return invalid('SETTLEMENT_ENCOUNTER_ID_INVALID', {
                settlement_receipt_id = receipt_id,
            })
        end
        local run_check = validate_derived(receipt.run_id, 'run_id')
        if not run_check.ok then
            return invalid('SETTLEMENT_RUN_ID_INVALID', {
                settlement_receipt_id = receipt_id,
            })
        end
        if receipt.status ~= 'COMMITTED' then
            return invalid('SETTLEMENT_STATUS_INVALID', {
                settlement_receipt_id = receipt_id,
                status = receipt.status,
            })
        end
        settlement_rows[index] = {
            settlement_receipt_id = receipt.settlement_receipt_id,
            encounter_id = receipt.encounter_id,
            run_id = receipt.run_id,
            status = receipt.status,
        }
    end

    return result_ok({
        encounter_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            progress_revision = snapshot.progress_revision,
        },
        encounter_progress_rows = progress_rows,
        encounter_settlement_rows = settlement_rows,
    })
end

function EncounterSaveCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    local metadata = bundle.encounter_metadata
    err = no_unknown_fields(metadata, METADATA_FIELDS, 'encounter_metadata')
    if err ~= nil then
        return err
    end
    if metadata.schema_version ~= CURRENT_SCHEMA_VERSION then
        return failure(
            EncounterErrorCodes.ENCOUNTER_SAVE_VERSION_UNSUPPORTED,
            'error.encounter.save_version_unsupported',
            'SCHEMA_VERSION_UNSUPPORTED',
            {
                actual = metadata.schema_version,
                current = CURRENT_SCHEMA_VERSION,
            }
        )
    end
    if not is_integer(metadata.progress_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('PROGRESS_REVISION_INVALID', { field = 'progress_revision' })
    end

    local progress_rows = bundle.encounter_progress_rows
    if type_value(progress_rows) ~= 'table' then
        return invalid('PROGRESS_ROWS_REQUIRED', {
            field = 'encounter_progress_rows',
        })
    end
    local progress_count = #progress_rows
    if progress_count > MAX_PROGRESS_ROWS then
        return limit_exceeded('PROGRESS_ROW_LIMIT', {
            count = progress_count,
            max_progress_rows = MAX_PROGRESS_ROWS,
        })
    end

    local rows = {}
    local previous_id = nil
    local index
    for index = 1, progress_count do
        local row = progress_rows[index]
        err = no_unknown_fields(
            row,
            PROGRESS_ROW_FIELDS,
            'encounter_progress_rows[' .. index .. ']'
        )
        if err ~= nil then
            return err
        end
        local checked = validate_content(row.encounter_id, 'encounter_', 'encounter_id')
        if not checked.ok then
            return invalid('ENCOUNTER_ID_INVALID', {
                field = 'encounter_progress_rows[' .. index .. '].encounter_id',
            })
        end
        if previous_id ~= nil and not bytewise_string_less(previous_id, row.encounter_id) then
            return invalid('PROGRESS_ROWS_NOT_SORTED_UNIQUE', {
                previous = previous_id,
                current = row.encounter_id,
            })
        end
        if type_value(row.discovered) ~= 'boolean'
            or type_value(row.first_clear) ~= 'boolean'
        then
            return invalid('PROGRESS_BOOL_INVALID', {
                field = 'encounter_progress_rows[' .. index .. ']',
            })
        end
        if not is_integer(row.completion_count, 0, MAX_COMPLETION_COUNT) then
            return invalid('COMPLETION_COUNT_INVALID', {
                field = 'encounter_progress_rows[' .. index .. '].completion_count',
            })
        end
        if not is_integer(row.last_completion_fact_revision, 0, MAX_SAFE_INTEGER) then
            return invalid('LAST_COMPLETION_FACT_REVISION_INVALID', {
                field = 'encounter_progress_rows['
                    .. index
                    .. '].last_completion_fact_revision',
            })
        end
        if not is_integer(row.rules_version, 1, MAX_SAFE_INTEGER) then
            return invalid('RULES_VERSION_INVALID', {
                field = 'encounter_progress_rows[' .. index .. '].rules_version',
            })
        end
        rows[row.encounter_id] = {
            encounter_id = row.encounter_id,
            discovered = row.discovered,
            first_clear = row.first_clear,
            completion_count = row.completion_count,
            last_completion_fact_revision = row.last_completion_fact_revision,
            rules_version = row.rules_version,
        }
        previous_id = row.encounter_id
    end

    local settlement_rows = bundle.encounter_settlement_rows
    if settlement_rows == nil then
        settlement_rows = {}
    end
    if type_value(settlement_rows) ~= 'table' then
        return invalid('SETTLEMENT_ROWS_REQUIRED', {
            field = 'encounter_settlement_rows',
        })
    end
    local settlement_count = #settlement_rows
    if settlement_count > MAX_SETTLEMENT_ROWS then
        return limit_exceeded('SETTLEMENT_ROW_LIMIT', {
            count = settlement_count,
            max_settlement_rows = MAX_SETTLEMENT_ROWS,
        })
    end

    local settlement_receipts = {}
    previous_id = nil
    for index = 1, settlement_count do
        local row = settlement_rows[index]
        err = no_unknown_fields(
            row,
            SETTLEMENT_ROW_FIELDS,
            'encounter_settlement_rows[' .. index .. ']'
        )
        if err ~= nil then
            return err
        end
        local receipt_check = validate_derived(
            row.settlement_receipt_id,
            'settlement_receipt_id'
        )
        if not receipt_check.ok then
            return invalid('SETTLEMENT_RECEIPT_ID_INVALID', {
                field = 'encounter_settlement_rows['
                    .. index
                    .. '].settlement_receipt_id',
            })
        end
        if previous_id ~= nil
            and not bytewise_string_less(previous_id, row.settlement_receipt_id)
        then
            return invalid('SETTLEMENT_ROWS_NOT_SORTED_UNIQUE', {
                previous = previous_id,
                current = row.settlement_receipt_id,
            })
        end
        local enc_check = validate_content(row.encounter_id, 'encounter_', 'encounter_id')
        if not enc_check.ok then
            return invalid('SETTLEMENT_ENCOUNTER_ID_INVALID', {
                field = 'encounter_settlement_rows[' .. index .. '].encounter_id',
            })
        end
        local run_check = validate_derived(row.run_id, 'run_id')
        if not run_check.ok then
            return invalid('SETTLEMENT_RUN_ID_INVALID', {
                field = 'encounter_settlement_rows[' .. index .. '].run_id',
            })
        end
        if row.status ~= 'COMMITTED' then
            return invalid('SETTLEMENT_STATUS_INVALID', {
                field = 'encounter_settlement_rows[' .. index .. '].status',
            })
        end
        settlement_receipts[row.settlement_receipt_id] = {
            settlement_receipt_id = row.settlement_receipt_id,
            encounter_id = row.encounter_id,
            run_id = row.run_id,
            status = row.status,
        }
        previous_id = row.settlement_receipt_id
    end

    return result_ok({
        progress_revision = metadata.progress_revision,
        rows = rows,
        settlement_receipts = settlement_receipts,
    })
end

EncounterSaveCodec.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION

return EncounterSaveCodec
