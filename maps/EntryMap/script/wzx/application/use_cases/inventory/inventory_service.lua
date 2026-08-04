local ItemCatalog = require 'wzx.config.schema.inventory.catalog'
local Inventory = require 'wzx.domain.inventory.inventory'
local InventoryErrorCodes = require 'wzx.domain.inventory.error_codes'
local InventorySaveBridge = require 'wzx.application.use_cases.inventory.inventory_save_bridge'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'

local InventoryService = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_content = RuntimeId.validate_content

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('inventory service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.inventory.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(InventoryErrorCodes.INVENTORY_ARGUMENT_INVALID, reason, details, false)
end

local function maybe_persist_save(self, input)
    local state = STATES[self]
    if state == nil or state.save_bridge == nil then
        return result_ok({ status = 'SKIPPED' })
    end
    local player_save_scope = raw_get(input, 'player_save_scope')
    if player_save_scope == nil then
        return result_ok({
            status = 'SKIPPED',
            reason = 'PLAYER_SAVE_SCOPE_MISSING',
        })
    end
    return state.save_bridge:persist_player_inventory({
        player_save_scope = player_save_scope,
        player_ref = raw_get(input, 'player_ref') or player_save_scope,
        request_id = (raw_get(input, 'request_id') or 'request_inventory')
            .. '_save',
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
end

function InventoryService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local item_catalog = raw_get(options, 'item_catalog')
    local store = raw_get(options, 'store')
    local save_bridge = raw_get(options, 'save_bridge')
    if not ItemCatalog.is_authority(item_catalog) then
        return invalid('ITEM_CATALOG_REQUIRED', { field = 'item_catalog' })
    end
    if type_value(store) ~= 'table'
        or type_value(store.get_inventory) ~= 'function'
        or type_value(store.replace_inventory) ~= 'function'
    then
        return invalid('STORE_REQUIRED', { field = 'store' })
    end
    if save_bridge ~= nil
        and not InventorySaveBridge.is_authority(save_bridge)
    then
        return invalid('SAVE_BRIDGE_AUTHORITY_REQUIRED', {
            field = 'save_bridge',
        })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        item_catalog = item_catalog,
        store = store,
        save_bridge = save_bridge,
    }
    return result_ok(view)
end

function InventoryService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

function Service:get_count(item_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local definition = state.item_catalog:require(item_id)
    if not definition.ok then
        return definition
    end
    local inventory = state.store:get_inventory()
    if not inventory.ok then
        return inventory
    end
    local count = Inventory.get_count(inventory.value, item_id)
    if not count.ok then
        return count
    end
    return result_ok({
        item_id = item_id,
        count = count.value,
        inventory_revision = inventory.value.inventory_revision,
        max_stack = definition.value.max_stack,
        ownership_cap = definition.value.ownership_cap,
    })
end

function Service:get_capacity()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local inventory = state.store:get_inventory()
    if not inventory.ok then
        return inventory
    end
    return Inventory.used_capacity(inventory.value, state.item_catalog)
end

function Service:plan_grant(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local inventory = state.store:get_inventory()
    if not inventory.ok then
        return inventory
    end
    return Inventory.plan_grant(
        inventory.value,
        raw_get(input, 'items') or raw_get(input, 'grants') or {},
        state.item_catalog,
        raw_get(input, 'overflow_policy') or 'REJECT'
    )
end

-- Mutating grant used by economy parent transactions and direct inventory tests.
function Service:grant_items(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local inventory = state.store:get_inventory()
    if not inventory.ok then
        return inventory
    end
    local plan = Inventory.plan_grant(
        inventory.value,
        raw_get(input, 'items') or raw_get(input, 'grants') or {},
        state.item_catalog,
        raw_get(input, 'overflow_policy') or 'REJECT'
    )
    if not plan.ok then
        return plan
    end
    local applied = Inventory.apply_plan(inventory.value, plan.value)
    if not applied.ok then
        return applied
    end
    local replaced = state.store:replace_inventory(applied.value)
    if not replaced.ok then
        return replaced
    end
    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        inventory_revision = applied.value.inventory_revision,
        grants = plan.value.grants,
        used_capacity_after = plan.value.used_capacity_after,
        capacity_limit = applied.value.capacity_limit,
        save = save.value,
    })
end

function Service:consume_items(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local inventory = state.store:get_inventory()
    if not inventory.ok then
        return inventory
    end
    local plan = Inventory.plan_consume(
        inventory.value,
        raw_get(input, 'items') or raw_get(input, 'costs') or {},
        state.item_catalog
    )
    if not plan.ok then
        return plan
    end
    local applied = Inventory.apply_plan(inventory.value, plan.value)
    if not applied.ok then
        return applied
    end
    local replaced = state.store:replace_inventory(applied.value)
    if not replaced.ok then
        return replaced
    end
    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        inventory_revision = applied.value.inventory_revision,
        costs = plan.value.costs,
        capacity_limit = applied.value.capacity_limit,
        save = save.value,
    })
end

return InventoryService
