local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local InventoryErrorCodes = require 'wzx.domain.inventory.error_codes'

local Inventory = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_ceil = math.ceil
local math_floor = math.floor
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_DELTA = 1000000000
local DEFAULT_CAPACITY_LIMIT = 60
local MAX_CAPACITY_LIMIT = 100
local MAX_STACK_ROWS = 512

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.inventory.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(InventoryErrorCodes.INVENTORY_ARGUMENT_INVALID, reason, details)
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function copy_stacks(stacks)
    local copied = {}
    local item_id
    local count
    for item_id, count in raw_next, stacks do
        copied[item_id] = count
    end
    return copied
end

local function stack_slots(count, max_stack)
    if count <= 0 then
        return 0
    end
    return math_floor((count + max_stack - 1) / max_stack)
end

function Inventory.empty(capacity_limit)
    if capacity_limit == nil then
        capacity_limit = DEFAULT_CAPACITY_LIMIT
    end
    if not is_safe_integer(capacity_limit, 1, MAX_CAPACITY_LIMIT) then
        return invalid('CAPACITY_LIMIT_INVALID', { field = 'capacity_limit' })
    end
    return result_ok({
        inventory_revision = 0,
        capacity_limit = capacity_limit,
        stacks = {},
    })
end

function Inventory.snapshot(state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('INVENTORY_STATE_REQUIRED', { field = 'state' })
    end
    if not is_safe_integer(raw_get(state, 'inventory_revision'), 0, MAX_SAFE_INTEGER) then
        return invalid('INVENTORY_REVISION_INVALID', { field = 'inventory_revision' })
    end
    if not is_safe_integer(raw_get(state, 'capacity_limit'), 1, MAX_CAPACITY_LIMIT) then
        return invalid('CAPACITY_LIMIT_INVALID', { field = 'capacity_limit' })
    end
    local stacks = raw_get(state, 'stacks')
    if type_value(stacks) ~= 'table' or get_metatable(stacks) ~= nil then
        return invalid('STACKS_TABLE_REQUIRED', { field = 'stacks' })
    end
    return result_ok({
        inventory_revision = state.inventory_revision,
        capacity_limit = state.capacity_limit,
        stacks = copy_stacks(stacks),
    })
end

function Inventory.get_count(state, item_id)
    local snap = Inventory.snapshot(state)
    if not snap.ok then
        return snap
    end
    local checked = validate_content(item_id, 'item_', 'item_id')
    if not checked.ok then
        return invalid('ITEM_ID_INVALID', { field = 'item_id' })
    end
    return result_ok(snap.value.stacks[item_id] or 0)
end

local function normalize_item_rows(rows, field_name)
    if type_value(rows) ~= 'table'
        or get_metatable(rows) ~= nil
        or not is_dense_array(rows)
    then
        return invalid('DENSE_ARRAY_REQUIRED', { field = field_name })
    end
    local merged = {}
    local index
    for index = 1, #rows do
        local row = rows[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return invalid('DELTA_ROW_TABLE_REQUIRED', {
                field = field_name .. '[' .. tostring(index) .. ']',
            })
        end
        local item_id = raw_get(row, 'item_id') or raw_get(row, 'target_id')
        local amount = raw_get(row, 'amount') or raw_get(row, 'quantity')
        local checked = validate_content(item_id, 'item_', 'item_id')
        if not checked.ok then
            return invalid('ITEM_ID_INVALID', {
                field = field_name .. '[' .. tostring(index) .. '].item_id',
            })
        end
        if not is_safe_integer(amount, 1, MAX_DELTA) then
            return invalid('AMOUNT_INVALID', {
                field = field_name .. '[' .. tostring(index) .. '].amount',
            })
        end
        local previous = merged[item_id] or 0
        local next_amount = previous + amount
        if next_amount > MAX_SAFE_INTEGER then
            return invalid('AMOUNT_OVERFLOW', {
                field = field_name,
                item_id = item_id,
            })
        end
        merged[item_id] = next_amount
    end

    local ordered = {}
    local item_id
    for item_id in raw_next, merged do
        ordered[#ordered + 1] = item_id
    end
    table_sort(ordered, bytewise_string_less)
    local normalized = {}
    for index = 1, #ordered do
        item_id = ordered[index]
        normalized[index] = {
            item_id = item_id,
            amount = merged[item_id],
        }
    end
    return result_ok(normalized)
end

function Inventory.normalize_deltas(rows, field_name)
    return normalize_item_rows(rows, field_name or 'deltas')
end

local function used_capacity_for_stacks(stacks, catalog)
    local used = 0
    local item_id
    local count
    for item_id, count in raw_next, stacks do
        local definition = catalog:require(item_id)
        if not definition.ok then
            return definition
        end
        if definition.value.capacity_policy ~= 'KEY_ITEM_FREE' then
            used = used + stack_slots(count, definition.value.max_stack)
        end
    end
    return result_ok(used)
end

function Inventory.used_capacity(state, catalog)
    local snap = Inventory.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require) ~= 'function' then
        return invalid('ITEM_CATALOG_REQUIRED', { field = 'catalog' })
    end
    local used = used_capacity_for_stacks(snap.value.stacks, catalog)
    if not used.ok then
        return used
    end
    return result_ok({
        used_capacity = used.value,
        capacity_limit = snap.value.capacity_limit,
        available_capacity = snap.value.capacity_limit - used.value,
        inventory_revision = snap.value.inventory_revision,
    })
end

function Inventory.plan_grant(state, grants, catalog, overflow_policy)
    local snap = Inventory.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require) ~= 'function' then
        return invalid('ITEM_CATALOG_REQUIRED', { field = 'catalog' })
    end
    if overflow_policy == nil then
        overflow_policy = 'REJECT'
    end
    if overflow_policy ~= 'REJECT' then
        -- PENDING_REWARD is owned by system 10; this slice only rejects full bags.
        return invalid('OVERFLOW_POLICY_UNSUPPORTED', {
            overflow_policy = overflow_policy,
        })
    end

    local rows = normalize_item_rows(grants or {}, 'grants')
    if not rows.ok then
        return rows
    end
    if #rows.value == 0 then
        return invalid('GRANTS_EMPTY', { field = 'grants' })
    end

    local stacks = copy_stacks(snap.value.stacks)
    local index
    for index = 1, #rows.value do
        local row = rows.value[index]
        local definition = catalog:require(row.item_id)
        if not definition.ok then
            return definition
        end
        if definition.value.deprecated == true then
            return fail(
                InventoryErrorCodes.INVENTORY_ENTRY_UNSUPPORTED,
                'ITEM_DEPRECATED',
                { item_id = row.item_id }
            )
        end
        local current = stacks[row.item_id] or 0
        local next_count = current + row.amount
        if next_count > definition.value.ownership_cap then
            return fail(
                InventoryErrorCodes.INVENTORY_ITEM_CAP_REACHED,
                'OWNERSHIP_CAP_EXCEEDED',
                {
                    item_id = row.item_id,
                    current = current,
                    amount = row.amount,
                    ownership_cap = definition.value.ownership_cap,
                }
            )
        end
        stacks[row.item_id] = next_count
    end

    local used = used_capacity_for_stacks(stacks, catalog)
    if not used.ok then
        return used
    end
    if used.value > snap.value.capacity_limit then
        return fail(
            InventoryErrorCodes.INVENTORY_FULL,
            'CAPACITY_EXCEEDED',
            {
                used_capacity = used.value,
                capacity_limit = snap.value.capacity_limit,
            }
        )
    end

    local row_count = 0
    local item_id
    for item_id in raw_next, stacks do
        row_count = row_count + 1
        if row_count > MAX_STACK_ROWS then
            return fail(
                InventoryErrorCodes.INVENTORY_SAVE_LIMIT_EXCEEDED,
                'STACK_ROW_LIMIT',
                { count = row_count, max_stack_rows = MAX_STACK_ROWS }
            )
        end
    end

    return result_ok({
        inventory_revision = snap.value.inventory_revision,
        capacity_limit = snap.value.capacity_limit,
        grants = rows.value,
        projected_stacks = stacks,
        used_capacity_after = used.value,
    })
end

function Inventory.plan_consume(state, costs, catalog)
    local snap = Inventory.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require) ~= 'function' then
        return invalid('ITEM_CATALOG_REQUIRED', { field = 'catalog' })
    end
    local rows = normalize_item_rows(costs or {}, 'costs')
    if not rows.ok then
        return rows
    end
    if #rows.value == 0 then
        return invalid('COSTS_EMPTY', { field = 'costs' })
    end

    local stacks = copy_stacks(snap.value.stacks)
    local index
    for index = 1, #rows.value do
        local row = rows.value[index]
        local definition = catalog:require(row.item_id)
        if not definition.ok then
            return definition
        end
        local current = stacks[row.item_id] or 0
        if current < row.amount then
            return fail(
                InventoryErrorCodes.INVENTORY_ITEM_INSUFFICIENT,
                'STACK_BELOW_COST',
                {
                    item_id = row.item_id,
                    available = current,
                    required = row.amount,
                }
            )
        end
        local next_count = current - row.amount
        if next_count == 0 then
            stacks[row.item_id] = nil
        else
            stacks[row.item_id] = next_count
        end
    end

    return result_ok({
        inventory_revision = snap.value.inventory_revision,
        capacity_limit = snap.value.capacity_limit,
        costs = rows.value,
        projected_stacks = stacks,
    })
end

function Inventory.apply_plan(state, plan)
    local snap = Inventory.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(plan) ~= 'table' or get_metatable(plan) ~= nil then
        return invalid('PLAN_TABLE_REQUIRED', { field = 'plan' })
    end
    if raw_get(plan, 'inventory_revision') ~= snap.value.inventory_revision then
        return fail(
            InventoryErrorCodes.INVENTORY_REVISION_CONFLICT,
            'INVENTORY_REVISION_MISMATCH',
            {
                expected = plan.inventory_revision,
                actual = snap.value.inventory_revision,
            }
        )
    end
    if raw_get(plan, 'capacity_limit') ~= snap.value.capacity_limit then
        return invalid('CAPACITY_LIMIT_MISMATCH', {
            expected = plan.capacity_limit,
            actual = snap.value.capacity_limit,
        })
    end
    local projected = raw_get(plan, 'projected_stacks')
    if type_value(projected) ~= 'table' or get_metatable(projected) ~= nil then
        return invalid('PROJECTED_STACKS_REQUIRED', { field = 'projected_stacks' })
    end

    return result_ok({
        inventory_revision = snap.value.inventory_revision + 1,
        capacity_limit = snap.value.capacity_limit,
        stacks = copy_stacks(projected),
    })
end

return Inventory
