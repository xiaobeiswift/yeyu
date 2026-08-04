local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'

local EconomyReceiptCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_derived = RuntimeId.validate_derived

local CURRENT_SCHEMA_VERSION = 1
local MAX_RECEIPT_ROWS = 256
local MAX_SOURCE_ROWS = 256
local MAX_SAFE_INTEGER = 9007199254740991

local BUNDLE_FIELDS = {
    economy_receipt_metadata = true,
    economy_reward_receipts = true,
    economy_source_occurrences = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    receipt_revision = true,
}
local RECEIPT_FIELDS = {
    receipt_id = true,
    source_occurrence_id = true,
    request_hash = true,
    result_hash = true,
    status = true,
    purpose_type = true,
    purpose_ref = true,
    economy_revision_after = true,
}
local SOURCE_FIELDS = {
    source_occurrence_id = true,
    receipt_id = true,
    status = true,
}
local STATUSES = {
    COMMITTED = true,
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
        EconomyErrorCodes.ECONOMY_RECEIPT_INVALID,
        'error.economy.receipt_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        EconomyErrorCodes.ECONOMY_RECEIPT_LIMIT_EXCEEDED,
        'error.economy.receipt_limit_exceeded',
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

local function is_sha256(value)
    return type_value(value) == 'string'
        and #value == 64
        and string.match(value, '^[a-f0-9]+$') ~= nil
end

function EconomyReceiptCodec.encode(snapshot)
    if type_value(snapshot) ~= 'table' then
        return invalid('SNAPSHOT_TABLE_REQUIRED', { field = 'snapshot' })
    end
    if not is_integer(snapshot.receipt_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('RECEIPT_REVISION_INVALID', { field = 'receipt_revision' })
    end
    if type_value(snapshot.receipts) ~= 'table'
        or type_value(snapshot.source_occurrences) ~= 'table'
    then
        return invalid('RECEIPT_MAPS_REQUIRED')
    end

    local receipt_ids = {}
    local receipt_id
    for receipt_id in raw_next, snapshot.receipts do
        receipt_ids[#receipt_ids + 1] = receipt_id
    end
    table_sort(receipt_ids, bytewise_string_less)
    if #receipt_ids > MAX_RECEIPT_ROWS then
        return limit_exceeded('RECEIPT_ROW_LIMIT', {
            count = #receipt_ids,
            max_receipt_rows = MAX_RECEIPT_ROWS,
        })
    end

    local receipt_rows = {}
    local index
    for index = 1, #receipt_ids do
        receipt_id = receipt_ids[index]
        local receipt = snapshot.receipts[receipt_id]
        local err = no_unknown_fields(receipt, RECEIPT_FIELDS, 'receipts.' .. receipt_id)
        if err ~= nil then
            return err
        end
        if receipt.receipt_id ~= receipt_id then
            return invalid('RECEIPT_ID_MISMATCH', {
                map_key = receipt_id,
                receipt_id = receipt.receipt_id,
            })
        end
        local checked_receipt = validate_derived(receipt.receipt_id, 'receipt_id')
        if not checked_receipt.ok then
            return invalid('RECEIPT_ID_INVALID', { receipt_id = receipt.receipt_id })
        end
        local checked_source = validate_component(
            receipt.source_occurrence_id,
            'source_occurrence_id'
        )
        if not checked_source.ok then
            return invalid('SOURCE_OCCURRENCE_ID_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        if not is_sha256(receipt.request_hash) or not is_sha256(receipt.result_hash) then
            return invalid('HASH_INVALID', { receipt_id = receipt.receipt_id })
        end
        if not STATUSES[receipt.status] then
            return invalid('STATUS_INVALID', {
                receipt_id = receipt.receipt_id,
                status = receipt.status,
            })
        end
        if type_value(receipt.purpose_type) ~= 'string'
            or string.match(receipt.purpose_type, '^[A-Z][A-Z0-9_]*$') == nil
        then
            return invalid('PURPOSE_TYPE_INVALID', { receipt_id = receipt.receipt_id })
        end
        if type_value(receipt.purpose_ref) ~= 'string' or receipt.purpose_ref == '' then
            return invalid('PURPOSE_REF_INVALID', { receipt_id = receipt.receipt_id })
        end
        if not is_integer(receipt.economy_revision_after, 0, MAX_SAFE_INTEGER) then
            return invalid('ECONOMY_REVISION_AFTER_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        receipt_rows[#receipt_rows + 1] = {
            receipt_id = receipt.receipt_id,
            source_occurrence_id = receipt.source_occurrence_id,
            request_hash = receipt.request_hash,
            result_hash = receipt.result_hash,
            status = receipt.status,
            purpose_type = receipt.purpose_type,
            purpose_ref = receipt.purpose_ref,
            economy_revision_after = receipt.economy_revision_after,
        }
    end

    local source_ids = {}
    local source_id
    for source_id in raw_next, snapshot.source_occurrences do
        source_ids[#source_ids + 1] = source_id
    end
    table_sort(source_ids, bytewise_string_less)
    if #source_ids > MAX_SOURCE_ROWS then
        return limit_exceeded('SOURCE_ROW_LIMIT', {
            count = #source_ids,
            max_source_rows = MAX_SOURCE_ROWS,
        })
    end

    local source_rows = {}
    for index = 1, #source_ids do
        source_id = source_ids[index]
        local row = snapshot.source_occurrences[source_id]
        local err = no_unknown_fields(row, SOURCE_FIELDS, 'source_occurrences.' .. source_id)
        if err ~= nil then
            return err
        end
        if row.source_occurrence_id ~= source_id then
            return invalid('SOURCE_ID_MISMATCH', {
                map_key = source_id,
                source_occurrence_id = row.source_occurrence_id,
            })
        end
        local checked_source = validate_component(source_id, 'source_occurrence_id')
        if not checked_source.ok then
            return invalid('SOURCE_OCCURRENCE_ID_INVALID', {
                source_occurrence_id = source_id,
            })
        end
        local checked_receipt = validate_derived(row.receipt_id, 'receipt_id')
        if not checked_receipt.ok then
            return invalid('RECEIPT_ID_INVALID', {
                source_occurrence_id = source_id,
            })
        end
        if not STATUSES[row.status] then
            return invalid('STATUS_INVALID', {
                source_occurrence_id = source_id,
                status = row.status,
            })
        end
        source_rows[#source_rows + 1] = {
            source_occurrence_id = row.source_occurrence_id,
            receipt_id = row.receipt_id,
            status = row.status,
        }
    end

    return result_ok({
        economy_receipt_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            receipt_revision = snapshot.receipt_revision,
        },
        economy_reward_receipts = receipt_rows,
        economy_source_occurrences = source_rows,
    })
end

function EconomyReceiptCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    local metadata = bundle.economy_receipt_metadata
    err = no_unknown_fields(metadata, METADATA_FIELDS, 'economy_receipt_metadata')
    if err ~= nil then
        return err
    end
    if metadata.schema_version ~= CURRENT_SCHEMA_VERSION then
        return failure(
            EconomyErrorCodes.ECONOMY_RECEIPT_VERSION_UNSUPPORTED,
            'error.economy.receipt_version_unsupported',
            'SCHEMA_VERSION_UNSUPPORTED',
            {
                actual = metadata.schema_version,
                current = CURRENT_SCHEMA_VERSION,
            }
        )
    end
    if not is_integer(metadata.receipt_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('RECEIPT_REVISION_INVALID', { field = 'receipt_revision' })
    end

    local receipt_rows = bundle.economy_reward_receipts
    local source_rows = bundle.economy_source_occurrences
    if type_value(receipt_rows) ~= 'table' or type_value(source_rows) ~= 'table' then
        return invalid('RECEIPT_ROWS_REQUIRED')
    end
    if #receipt_rows > MAX_RECEIPT_ROWS then
        return limit_exceeded('RECEIPT_ROW_LIMIT', { count = #receipt_rows })
    end
    if #source_rows > MAX_SOURCE_ROWS then
        return limit_exceeded('SOURCE_ROW_LIMIT', { count = #source_rows })
    end

    local receipts = {}
    local previous = nil
    local index
    for index = 1, #receipt_rows do
        local row = receipt_rows[index]
        err = no_unknown_fields(row, RECEIPT_FIELDS, 'economy_reward_receipts[' .. index .. ']')
        if err ~= nil then
            return err
        end
        if previous ~= nil and not bytewise_string_less(previous, row.receipt_id) then
            return invalid('RECEIPT_ROWS_NOT_SORTED_UNIQUE', {
                previous = previous,
                current = row.receipt_id,
            })
        end
        if not validate_derived(row.receipt_id, 'receipt_id').ok then
            return invalid('RECEIPT_ID_INVALID', { receipt_id = row.receipt_id })
        end
        if not validate_component(row.source_occurrence_id, 'source_occurrence_id').ok then
            return invalid('SOURCE_OCCURRENCE_ID_INVALID', {
                receipt_id = row.receipt_id,
            })
        end
        if not is_sha256(row.request_hash) or not is_sha256(row.result_hash) then
            return invalid('HASH_INVALID', { receipt_id = row.receipt_id })
        end
        if not STATUSES[row.status] then
            return invalid('STATUS_INVALID', { receipt_id = row.receipt_id })
        end
        if type_value(row.purpose_type) ~= 'string'
            or string.match(row.purpose_type, '^[A-Z][A-Z0-9_]*$') == nil
        then
            return invalid('PURPOSE_TYPE_INVALID', { receipt_id = row.receipt_id })
        end
        if type_value(row.purpose_ref) ~= 'string' or row.purpose_ref == '' then
            return invalid('PURPOSE_REF_INVALID', { receipt_id = row.receipt_id })
        end
        if not is_integer(row.economy_revision_after, 0, MAX_SAFE_INTEGER) then
            return invalid('ECONOMY_REVISION_AFTER_INVALID', {
                receipt_id = row.receipt_id,
            })
        end
        receipts[row.receipt_id] = {
            receipt_id = row.receipt_id,
            source_occurrence_id = row.source_occurrence_id,
            request_hash = row.request_hash,
            result_hash = row.result_hash,
            status = row.status,
            purpose_type = row.purpose_type,
            purpose_ref = row.purpose_ref,
            economy_revision_after = row.economy_revision_after,
        }
        previous = row.receipt_id
    end

    local sources = {}
    previous = nil
    for index = 1, #source_rows do
        local row = source_rows[index]
        err = no_unknown_fields(row, SOURCE_FIELDS, 'economy_source_occurrences[' .. index .. ']')
        if err ~= nil then
            return err
        end
        if previous ~= nil and not bytewise_string_less(previous, row.source_occurrence_id) then
            return invalid('SOURCE_ROWS_NOT_SORTED_UNIQUE', {
                previous = previous,
                current = row.source_occurrence_id,
            })
        end
        if not validate_component(row.source_occurrence_id, 'source_occurrence_id').ok then
            return invalid('SOURCE_OCCURRENCE_ID_INVALID', {
                source_occurrence_id = row.source_occurrence_id,
            })
        end
        if not validate_derived(row.receipt_id, 'receipt_id').ok then
            return invalid('RECEIPT_ID_INVALID', {
                source_occurrence_id = row.source_occurrence_id,
            })
        end
        if not STATUSES[row.status] then
            return invalid('STATUS_INVALID', {
                source_occurrence_id = row.source_occurrence_id,
            })
        end
        sources[row.source_occurrence_id] = {
            source_occurrence_id = row.source_occurrence_id,
            receipt_id = row.receipt_id,
            status = row.status,
        }
        previous = row.source_occurrence_id
    end

    return result_ok({
        receipt_revision = metadata.receipt_revision,
        receipts = receipts,
        source_occurrences = sources,
    })
end

return EconomyReceiptCodec
