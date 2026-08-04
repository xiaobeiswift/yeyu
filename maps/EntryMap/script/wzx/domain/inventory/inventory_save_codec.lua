local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local InventoryErrorCodes = require 'wzx.domain.inventory.error_codes'

local InventorySaveCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content

local CURRENT_SCHEMA_VERSION = 1
local MAX_STACK_ROWS = 512
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_CAPACITY_LIMIT = 100
local MAX_COUNT = 2000000000

local BUNDLE_FIELDS = {
    inventory_metadata = true,
    inventory_stack_rows = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    inventory_revision = true,
    capacity_limit = true,
}
local STACK_ROW_FIELDS = {
    item_id = true,
    count = true,
}
local SNAPSHOT_FIELDS = {
    inventory_revision = true,
    capacity_limit = true,
    stacks = true,
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
        InventoryErrorCodes.INVENTORY_SAVE_INVALID,
        'error.inventory.save_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        InventoryErrorCodes.INVENTORY_SAVE_LIMIT_EXCEEDED,
        'error.inventory.save_limit_exceeded',
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

function InventorySaveCodec.encode(snapshot)
    local err = no_unknown_fields(snapshot, SNAPSHOT_FIELDS, '$')
    if err ~= nil then
        return err
    end
    if not is_integer(snapshot.inventory_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('INVENTORY_REVISION_INVALID', { field = 'inventory_revision' })
    end
    if not is_integer(snapshot.capacity_limit, 1, MAX_CAPACITY_LIMIT) then
        return invalid('CAPACITY_LIMIT_INVALID', { field = 'capacity_limit' })
    end
    if type_value(snapshot.stacks) ~= 'table' then
        return invalid('STACKS_TABLE_REQUIRED', { field = 'stacks' })
    end

    local item_ids = {}
    local item_id
    for item_id in raw_next, snapshot.stacks do
        item_ids[#item_ids + 1] = item_id
    end
    table_sort(item_ids, bytewise_string_less)
    if #item_ids > MAX_STACK_ROWS then
        return limit_exceeded('STACK_ROW_LIMIT', {
            count = #item_ids,
            max_stack_rows = MAX_STACK_ROWS,
        })
    end

    local rows = {}
    local index
    for index = 1, #item_ids do
        item_id = item_ids[index]
        local checked = validate_content(item_id, 'item_', 'item_id')
        if not checked.ok then
            return invalid('ITEM_ID_INVALID', { item_id = item_id })
        end
        local count = snapshot.stacks[item_id]
        if not is_integer(count, 1, MAX_COUNT) then
            return invalid('STACK_COUNT_INVALID', {
                item_id = item_id,
                count = count,
            })
        end
        rows[index] = {
            item_id = item_id,
            count = count,
        }
    end

    return result_ok({
        inventory_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            inventory_revision = snapshot.inventory_revision,
            capacity_limit = snapshot.capacity_limit,
        },
        inventory_stack_rows = rows,
    })
end

function InventorySaveCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    err = no_unknown_fields(bundle.inventory_metadata, METADATA_FIELDS, 'inventory_metadata')
    if err ~= nil then
        return err
    end
    local meta = bundle.inventory_metadata
    if meta.schema_version ~= CURRENT_SCHEMA_VERSION then
        return invalid('SCHEMA_VERSION_UNSUPPORTED', {
            schema_version = meta.schema_version,
        })
    end
    if not is_integer(meta.inventory_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('INVENTORY_REVISION_INVALID', { field = 'inventory_revision' })
    end
    if not is_integer(meta.capacity_limit, 1, MAX_CAPACITY_LIMIT) then
        return invalid('CAPACITY_LIMIT_INVALID', { field = 'capacity_limit' })
    end
    if type_value(bundle.inventory_stack_rows) ~= 'table'
        or not Ordered.is_dense_array(bundle.inventory_stack_rows)
    then
        return invalid('STACK_ROWS_DENSE_ARRAY_REQUIRED', {
            field = 'inventory_stack_rows',
        })
    end
    if #bundle.inventory_stack_rows > MAX_STACK_ROWS then
        return limit_exceeded('STACK_ROW_LIMIT', {
            count = #bundle.inventory_stack_rows,
            max_stack_rows = MAX_STACK_ROWS,
        })
    end

    local stacks = {}
    local previous_id = nil
    local index
    for index = 1, #bundle.inventory_stack_rows do
        local row = bundle.inventory_stack_rows[index]
        err = no_unknown_fields(row, STACK_ROW_FIELDS, 'inventory_stack_rows[' .. index .. ']')
        if err ~= nil then
            return err
        end
        local checked = validate_content(row.item_id, 'item_', 'item_id')
        if not checked.ok then
            return invalid('ITEM_ID_INVALID', {
                field = 'inventory_stack_rows[' .. index .. '].item_id',
            })
        end
        if previous_id ~= nil and not bytewise_string_less(previous_id, row.item_id) then
            return invalid('STACK_ROWS_NOT_SORTED_UNIQUE', {
                item_id = row.item_id,
            })
        end
        if stacks[row.item_id] ~= nil then
            return invalid('DUPLICATE_ITEM_ID', { item_id = row.item_id })
        end
        if not is_integer(row.count, 1, MAX_COUNT) then
            return invalid('STACK_COUNT_INVALID', {
                item_id = row.item_id,
                count = row.count,
            })
        end
        stacks[row.item_id] = row.count
        previous_id = row.item_id
    end

    return result_ok({
        inventory_revision = meta.inventory_revision,
        capacity_limit = meta.capacity_limit,
        stacks = stacks,
    })
end

return InventorySaveCodec
