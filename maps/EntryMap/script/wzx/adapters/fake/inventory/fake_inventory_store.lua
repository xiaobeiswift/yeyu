local Inventory = require 'wzx.domain.inventory.inventory'
local InventorySaveCodec = require 'wzx.domain.inventory.inventory_save_codec'
local Result = require 'wzx.domain.common.result'

local FakeInventoryStore = {}
local error_value = error
local get_metatable = getmetatable
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Store = {}
Store.__index = Store
Store.__newindex = function()
    error_value('fake inventory store is read-only', 2)
end
Store.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'INVALID_ARGUMENT',
        'error.inventory.fake_store_invalid',
        false,
        details
    )
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

function FakeInventoryStore.new(options)
    options = options or {}
    local empty = Inventory.empty(options.capacity_limit)
    if not empty.ok then
        return empty
    end
    local view = set_metatable({}, Store)
    STATES[view] = {
        inventory = empty.value,
    }
    return result_ok(view)
end

function Store:get_inventory()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return Inventory.snapshot(state.inventory)
end

function Store:replace_inventory(inventory)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local snap = Inventory.snapshot(inventory)
    if not snap.ok then
        return snap
    end
    state.inventory = {
        inventory_revision = snap.value.inventory_revision,
        capacity_limit = snap.value.capacity_limit,
        stacks = copy_stacks(snap.value.stacks),
    }
    return result_ok({
        inventory_revision = state.inventory.inventory_revision,
    })
end

function Store:export_save_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local snap = Inventory.snapshot(state.inventory)
    if not snap.ok then
        return snap
    end
    return InventorySaveCodec.encode(snap.value)
end

function Store:import_save_bundle(bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local decoded = InventorySaveCodec.decode(bundle)
    if not decoded.ok then
        return decoded
    end
    state.inventory = {
        inventory_revision = decoded.value.inventory_revision,
        capacity_limit = decoded.value.capacity_limit,
        stacks = copy_stacks(decoded.value.stacks),
    }
    return result_ok(true)
end

return FakeInventoryStore
