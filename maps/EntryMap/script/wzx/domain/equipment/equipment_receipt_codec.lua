-- System 08 slot-5 equipment operation receipts (enhance + temper + destroy).
-- Parallel flat rows only; no nested result objects.

local Ordered = require 'wzx.domain.common.ordered'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local EquipmentReceiptCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_dense_array = Ordered.is_dense_array
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local CURRENT_SCHEMA_VERSION = 1
local MAX_RECEIPT_ROWS = 256
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_ENHANCEMENT = 20

local BUNDLE_FIELDS = {
    equipment_operation_metadata = true,
    equipment_operation_receipts = true,
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
    instance_id = true,
    from_level = true,
    to_level = true,
    slot_index = true,
    new_affix_id = true,
    new_tier = true,
    new_rolled_value = true,
    new_roll_ordinal = true,
    destroy_reason = true,
    copper_cost = true,
    material_item_id = true,
    material_count = true,
    equipment_save_revision_after = true,
}
local OPERATION_TYPES = {
    ENHANCE_EQUIPMENT = true,
    TEMPER_AFFIX = true,
    DESTROY_EQUIPMENT = true,
}
local DESTROY_REASONS = {
    SALVAGE = true,
    DISCARD = true,
    ADMIN = true,
    MIGRATION = true,
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
        EquipmentErrorCodes.EQUIPMENT_RECEIPT_INVALID,
        'error.equipment.receipt_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        EquipmentErrorCodes.EQUIPMENT_RECEIPT_LIMIT_EXCEEDED,
        'error.equipment.receipt_limit_exceeded',
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

local function validate_cost_fields(receipt)
    if not is_integer(receipt.copper_cost, 0, 2000000000) then
        return invalid('COPPER_COST_INVALID', {
            receipt_id = receipt.receipt_id,
        })
    end
    if not is_integer(receipt.material_count, 0, 9999) then
        return invalid('MATERIAL_COUNT_INVALID', {
            receipt_id = receipt.receipt_id,
        })
    end
    if receipt.material_count > 0 then
        if receipt.material_item_id == nil then
            return invalid('MATERIAL_ITEM_REQUIRED', {
                receipt_id = receipt.receipt_id,
            })
        end
        local checked_item = validate_component(
            receipt.material_item_id,
            'material_item_id'
        )
        if not checked_item.ok then
            return invalid('MATERIAL_ITEM_ID_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
    elseif receipt.material_item_id ~= nil then
        return invalid('MATERIAL_ITEM_FORBIDDEN_WHEN_ZERO', {
            receipt_id = receipt.receipt_id,
        })
    end
    if not is_integer(receipt.equipment_save_revision_after, 0, MAX_SAFE_INTEGER) then
        return invalid('EQUIPMENT_SAVE_REVISION_AFTER_INVALID', {
            receipt_id = receipt.receipt_id,
        })
    end
    return nil
end

local function has_temper_fields(receipt)
    return receipt.slot_index ~= nil
        or receipt.new_affix_id ~= nil
        or receipt.new_tier ~= nil
        or receipt.new_rolled_value ~= nil
        or receipt.new_roll_ordinal ~= nil
end

local function has_enhance_fields(receipt)
    return receipt.from_level ~= nil or receipt.to_level ~= nil
end

local function validate_operation_fields(receipt)
    if receipt.operation_type == 'ENHANCE_EQUIPMENT' then
        if has_temper_fields(receipt) or receipt.destroy_reason ~= nil then
            return invalid('NON_ENHANCE_FIELDS_FORBIDDEN', {
                receipt_id = receipt.receipt_id,
            })
        end
        if not is_integer(receipt.from_level, 0, MAX_ENHANCEMENT)
            or not is_integer(receipt.to_level, 0, MAX_ENHANCEMENT)
            or receipt.to_level ~= receipt.from_level + 1
        then
            return invalid('LEVEL_PAIR_INVALID', {
                receipt_id = receipt.receipt_id,
                from_level = receipt.from_level,
                to_level = receipt.to_level,
            })
        end
        return nil
    end

    if receipt.operation_type == 'TEMPER_AFFIX' then
        if has_enhance_fields(receipt) or receipt.destroy_reason ~= nil then
            return invalid('NON_TEMPER_FIELDS_FORBIDDEN', {
                receipt_id = receipt.receipt_id,
            })
        end
        if not is_integer(receipt.slot_index, 1, 6) then
            return invalid('SLOT_INDEX_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        local affix_id = validate_content(receipt.new_affix_id, 'affix_', 'new_affix_id')
        if not affix_id.ok then
            return invalid('NEW_AFFIX_ID_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        if not is_integer(receipt.new_tier, 1, 5) then
            return invalid('NEW_TIER_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        if not is_integer(receipt.new_rolled_value, -2000000000, 2000000000) then
            return invalid('NEW_ROLLED_VALUE_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        if not is_integer(receipt.new_roll_ordinal, 0, MAX_SAFE_INTEGER) then
            return invalid('NEW_ROLL_ORDINAL_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        return nil
    end

    -- DESTROY_EQUIPMENT
    if has_enhance_fields(receipt) or has_temper_fields(receipt) then
        return invalid('NON_DESTROY_FIELDS_FORBIDDEN', {
            receipt_id = receipt.receipt_id,
        })
    end
    if DESTROY_REASONS[receipt.destroy_reason] ~= true then
        return invalid('DESTROY_REASON_INVALID', {
            receipt_id = receipt.receipt_id,
            destroy_reason = receipt.destroy_reason,
        })
    end
    return nil
end

local function normalize_row(receipt)
    local row = {
        receipt_id = receipt.receipt_id,
        request_hash = receipt.request_hash,
        result_hash = receipt.result_hash,
        status = receipt.status,
        operation_type = receipt.operation_type,
        instance_id = receipt.instance_id,
        copper_cost = receipt.copper_cost,
        material_count = receipt.material_count,
        equipment_save_revision_after = receipt.equipment_save_revision_after,
    }
    if receipt.material_item_id ~= nil then
        row.material_item_id = receipt.material_item_id
    end
    if receipt.operation_type == 'ENHANCE_EQUIPMENT' then
        row.from_level = receipt.from_level
        row.to_level = receipt.to_level
    elseif receipt.operation_type == 'TEMPER_AFFIX' then
        row.slot_index = receipt.slot_index
        row.new_affix_id = receipt.new_affix_id
        row.new_tier = receipt.new_tier
        row.new_rolled_value = receipt.new_rolled_value
        row.new_roll_ordinal = receipt.new_roll_ordinal
    else
        row.destroy_reason = receipt.destroy_reason
    end
    return row
end

function EquipmentReceiptCodec.encode(snapshot)
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
        local checked_instance = validate_derived(receipt.instance_id, 'instance_id')
        if not checked_instance.ok then
            return invalid('INSTANCE_ID_INVALID', {
                receipt_id = receipt.receipt_id,
            })
        end
        err = validate_operation_fields(receipt)
        if err ~= nil then
            return err
        end
        err = validate_cost_fields(receipt)
        if err ~= nil then
            return err
        end
        receipt_rows[#receipt_rows + 1] = normalize_row(receipt)
    end

    return result_ok({
        equipment_operation_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            receipt_revision = snapshot.receipt_revision,
        },
        equipment_operation_receipts = receipt_rows,
    })
end

function EquipmentReceiptCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    err = no_unknown_fields(
        bundle.equipment_operation_metadata,
        METADATA_FIELDS,
        'equipment_operation_metadata'
    )
    if err ~= nil then
        return err
    end
    local meta = bundle.equipment_operation_metadata
    if meta.schema_version ~= CURRENT_SCHEMA_VERSION then
        return failure(
            EquipmentErrorCodes.EQUIPMENT_RECEIPT_VERSION_UNSUPPORTED,
            'error.equipment.receipt_version_unsupported',
            'SCHEMA_VERSION_UNSUPPORTED',
            { schema_version = meta.schema_version }
        )
    end
    if not is_integer(meta.receipt_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('RECEIPT_REVISION_INVALID', {
            field = 'receipt_revision',
        })
    end
    if type_value(bundle.equipment_operation_receipts) ~= 'table'
        or not is_dense_array(bundle.equipment_operation_receipts)
    then
        return invalid('DENSE_ARRAY_REQUIRED', {
            field = 'equipment_operation_receipts',
        })
    end
    if #bundle.equipment_operation_receipts > MAX_RECEIPT_ROWS then
        return limit_exceeded('RECEIPT_ROW_LIMIT', {
            count = #bundle.equipment_operation_receipts,
            max_receipt_rows = MAX_RECEIPT_ROWS,
        })
    end

    local receipts = {}
    local index
    for index = 1, #bundle.equipment_operation_receipts do
        local row = bundle.equipment_operation_receipts[index]
        err = no_unknown_fields(
            row,
            RECEIPT_FIELDS,
            'equipment_operation_receipts[' .. tostring(index) .. ']'
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
            })
        end
        local checked_instance = validate_derived(row.instance_id, 'instance_id')
        if not checked_instance.ok then
            return invalid('INSTANCE_ID_INVALID', {
                receipt_id = row.receipt_id,
            })
        end
        err = validate_operation_fields(row)
        if err ~= nil then
            return err
        end
        err = validate_cost_fields(row)
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

return EquipmentReceiptCodec
