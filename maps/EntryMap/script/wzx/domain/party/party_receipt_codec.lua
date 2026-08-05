-- System 03 slot-5 party operation receipts (formation writes + presets).
-- Parallel flat rows only; COMMITTED status only for V1. No PREPARED saga.

local Ordered = require 'wzx.domain.common.ordered'
local PartyErrorCodes = require 'wzx.domain.party.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local PartyReceiptCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_dense_array = Ordered.is_dense_array
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local CURRENT_SCHEMA_VERSION = 1
local MAX_RECEIPT_ROWS = 256
local MAX_SAFE_INTEGER = 9007199254740991

local CONTEXTS = {
    PVE_MAIN = true,
    PVE_ALT = true,
    ARENA_DEFENSE = true,
}

local BUNDLE_FIELDS = {
    party_operation_metadata = true,
    party_operation_receipts = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    receipt_revision = true,
}
local RECEIPT_FIELDS = {
    receipt_id = true,
    request_hash = true,
    result_hash = true,
    status = true,
    operation_type = true,
    party_context = true,
    party_save_revision_after = true,
    preset_id = true,
    formation_revision_after = true,
    active_preset_id = true,
}
local OPERATION_TYPES = {
    COMMIT_FORMATION = true,
    SAVE_PARTY_PRESET = true,
    APPLY_PARTY_PRESET = true,
    DELETE_PARTY_PRESET = true,
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
        PartyErrorCodes.PARTY_RECEIPT_INVALID,
        'error.party.receipt_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        PartyErrorCodes.PARTY_RECEIPT_LIMIT_EXCEEDED,
        'error.party.receipt_limit_exceeded',
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

local function has_preset_id(receipt)
    return receipt.preset_id ~= nil
end

local function has_formation_revision(receipt)
    return receipt.formation_revision_after ~= nil
end

local function validate_optional_active_preset_id(receipt)
    if receipt.active_preset_id == nil then
        return nil
    end
    if receipt.active_preset_id == '' then
        return invalid('ACTIVE_PRESET_ID_EMPTY_STRING', {
            receipt_id = receipt.receipt_id,
        })
    end
    local checked = validate_content(
        receipt.active_preset_id,
        'preset_party_',
        'active_preset_id'
    )
    if not checked.ok then
        return invalid('ACTIVE_PRESET_ID_INVALID', {
            receipt_id = receipt.receipt_id,
        })
    end
    return nil
end

local function validate_operation_fields(receipt)
    if CONTEXTS[receipt.party_context] ~= true then
        return invalid('PARTY_CONTEXT_INVALID', {
            receipt_id = receipt.receipt_id,
            party_context = receipt.party_context,
        })
    end
    if not is_integer(receipt.party_save_revision_after, 0, MAX_SAFE_INTEGER) then
        return invalid('PARTY_SAVE_REVISION_AFTER_INVALID', {
            receipt_id = receipt.receipt_id,
        })
    end

    if receipt.operation_type == 'COMMIT_FORMATION' then
        if has_preset_id(receipt) then
            return invalid('PRESET_ID_FORBIDDEN', {
                receipt_id = receipt.receipt_id,
                operation_type = receipt.operation_type,
            })
        end
        if not is_integer(receipt.formation_revision_after, 0, MAX_SAFE_INTEGER) then
            return invalid('FORMATION_REVISION_AFTER_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        return validate_optional_active_preset_id(receipt)
    end

    if receipt.operation_type == 'SAVE_PARTY_PRESET' then
        if has_formation_revision(receipt) then
            return invalid('FORMATION_REVISION_FORBIDDEN', {
                receipt_id = receipt.receipt_id,
                operation_type = receipt.operation_type,
            })
        end
        if receipt.active_preset_id ~= nil then
            return invalid('ACTIVE_PRESET_ID_FORBIDDEN', {
                receipt_id = receipt.receipt_id,
                operation_type = receipt.operation_type,
            })
        end
        local checked = validate_content(
            receipt.preset_id,
            'preset_party_',
            'preset_id'
        )
        if not checked.ok then
            return invalid('PRESET_ID_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        return nil
    end

    if receipt.operation_type == 'APPLY_PARTY_PRESET' then
        local checked = validate_content(
            receipt.preset_id,
            'preset_party_',
            'preset_id'
        )
        if not checked.ok then
            return invalid('PRESET_ID_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        if not is_integer(receipt.formation_revision_after, 0, MAX_SAFE_INTEGER) then
            return invalid('FORMATION_REVISION_AFTER_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        return validate_optional_active_preset_id(receipt)
    end

    -- DELETE_PARTY_PRESET
    if has_formation_revision(receipt) then
        return invalid('FORMATION_REVISION_FORBIDDEN', {
            receipt_id = receipt.receipt_id,
            operation_type = receipt.operation_type,
        })
    end
    local checked = validate_content(
        receipt.preset_id,
        'preset_party_',
        'preset_id'
    )
    if not checked.ok then
        return invalid('PRESET_ID_INVALID', {
            receipt_id = receipt.receipt_id,
        })
    end
    return validate_optional_active_preset_id(receipt)
end

local function normalize_row(receipt)
    local row = {
        receipt_id = receipt.receipt_id,
        request_hash = receipt.request_hash,
        result_hash = receipt.result_hash,
        status = receipt.status,
        operation_type = receipt.operation_type,
        party_context = receipt.party_context,
        party_save_revision_after = receipt.party_save_revision_after,
    }
    if receipt.operation_type == 'COMMIT_FORMATION' then
        row.formation_revision_after = receipt.formation_revision_after
        if receipt.active_preset_id ~= nil then
            row.active_preset_id = receipt.active_preset_id
        end
    elseif receipt.operation_type == 'SAVE_PARTY_PRESET' then
        row.preset_id = receipt.preset_id
    elseif receipt.operation_type == 'APPLY_PARTY_PRESET' then
        row.preset_id = receipt.preset_id
        row.formation_revision_after = receipt.formation_revision_after
        if receipt.active_preset_id ~= nil then
            row.active_preset_id = receipt.active_preset_id
        end
    else
        row.preset_id = receipt.preset_id
        if receipt.active_preset_id ~= nil then
            row.active_preset_id = receipt.active_preset_id
        end
    end
    return row
end

function PartyReceiptCodec.encode(snapshot)
    if type_value(snapshot) ~= 'table' then
        return invalid('SNAPSHOT_TABLE_REQUIRED', { field = 'snapshot' })
    end
    if not is_integer(snapshot.receipt_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('RECEIPT_REVISION_INVALID', { field = 'receipt_revision' })
    end
    if type_value(snapshot.receipts) ~= 'table' then
        return invalid('RECEIPTS_MAP_REQUIRED', { field = 'receipts' })
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
        local err = no_unknown_fields(
            receipt,
            RECEIPT_FIELDS,
            'receipts.' .. receipt_id
        )
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
        if not is_sha256(receipt.request_hash) or not is_sha256(receipt.result_hash) then
            return invalid('HASH_INVALID', { receipt_id = receipt.receipt_id })
        end
        if not STATUSES[receipt.status] then
            return invalid('STATUS_INVALID', {
                receipt_id = receipt.receipt_id,
                status = receipt.status,
            })
        end
        if not OPERATION_TYPES[receipt.operation_type] then
            return invalid('OPERATION_TYPE_INVALID', {
                receipt_id = receipt.receipt_id,
                operation_type = receipt.operation_type,
            })
        end
        err = validate_operation_fields(receipt)
        if err ~= nil then
            return err
        end
        receipt_rows[#receipt_rows + 1] = normalize_row(receipt)
    end

    return result_ok({
        party_operation_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            receipt_revision = snapshot.receipt_revision,
        },
        party_operation_receipts = receipt_rows,
    })
end

function PartyReceiptCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    err = no_unknown_fields(
        bundle.party_operation_metadata,
        METADATA_FIELDS,
        'party_operation_metadata'
    )
    if err ~= nil then
        return err
    end
    local meta = bundle.party_operation_metadata
    if meta.schema_version ~= CURRENT_SCHEMA_VERSION then
        return failure(
            PartyErrorCodes.PARTY_RECEIPT_VERSION_UNSUPPORTED,
            'error.party.receipt_version_unsupported',
            'SCHEMA_VERSION_UNSUPPORTED',
            { schema_version = meta.schema_version }
        )
    end
    if not is_integer(meta.receipt_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('RECEIPT_REVISION_INVALID', {
            field = 'receipt_revision',
        })
    end
    if type_value(bundle.party_operation_receipts) ~= 'table'
        or not is_dense_array(bundle.party_operation_receipts)
    then
        return invalid('DENSE_ARRAY_REQUIRED', {
            field = 'party_operation_receipts',
        })
    end
    if #bundle.party_operation_receipts > MAX_RECEIPT_ROWS then
        return limit_exceeded('RECEIPT_ROW_LIMIT', {
            count = #bundle.party_operation_receipts,
            max_receipt_rows = MAX_RECEIPT_ROWS,
        })
    end

    local receipts = {}
    local index
    for index = 1, #bundle.party_operation_receipts do
        local row = bundle.party_operation_receipts[index]
        err = no_unknown_fields(
            row,
            RECEIPT_FIELDS,
            'party_operation_receipts[' .. tostring(index) .. ']'
        )
        if err ~= nil then
            return err
        end
        local checked_receipt = validate_derived(row.receipt_id, 'receipt_id')
        if not checked_receipt.ok then
            return invalid('RECEIPT_ID_INVALID', { receipt_id = row.receipt_id })
        end
        if receipts[row.receipt_id] ~= nil then
            return invalid('DUPLICATE_RECEIPT_ID', { receipt_id = row.receipt_id })
        end
        if not is_sha256(row.request_hash) or not is_sha256(row.result_hash) then
            return invalid('HASH_INVALID', { receipt_id = row.receipt_id })
        end
        if not STATUSES[row.status] then
            return invalid('STATUS_INVALID', {
                receipt_id = row.receipt_id,
                status = row.status,
            })
        end
        if not OPERATION_TYPES[row.operation_type] then
            return invalid('OPERATION_TYPE_INVALID', {
                receipt_id = row.receipt_id,
                operation_type = row.operation_type,
            })
        end
        err = validate_operation_fields(row)
        if err ~= nil then
            return err
        end
        receipts[row.receipt_id] = normalize_row(row)
    end

    return result_ok({
        receipt_revision = meta.receipt_revision,
        receipts = receipts,
    })
end

return PartyReceiptCodec
