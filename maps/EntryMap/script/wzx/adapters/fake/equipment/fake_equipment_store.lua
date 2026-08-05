local CharacterLoadout = require 'wzx.domain.equipment.character_loadout'
local EquipmentInstance = require 'wzx.domain.equipment.equipment_instance'
local EquipmentReceiptCodec = require 'wzx.domain.equipment.equipment_receipt_codec'
local EquipmentSaveCodec = require 'wzx.domain.equipment.equipment_save_codec'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'

local FakeEquipmentStore = {}
local bytewise_string_less = Ordered.bytewise_string_less
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local table_sort = table.sort
local type_value = type

local Store = {}
Store.__index = Store
Store.__newindex = function()
    error_value('fake equipment store is read-only', 2)
end
Store.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'INVALID_ARGUMENT',
        'error.equipment.fake_store_invalid',
        false,
        details
    )
end

local function copy_instance(instance)
    return EquipmentInstance.copy(instance)
end

local function copy_loadout(loadout)
    return CharacterLoadout.snapshot(loadout)
end

local function copy_receipt(receipt)
    local copied = {
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
        copied.material_item_id = receipt.material_item_id
    end
    if receipt.operation_type == 'ENHANCE_EQUIPMENT' then
        copied.from_level = receipt.from_level
        copied.to_level = receipt.to_level
    elseif receipt.operation_type == 'TEMPER_AFFIX' then
        copied.slot_index = receipt.slot_index
        copied.new_affix_id = receipt.new_affix_id
        copied.new_tier = receipt.new_tier
        copied.new_rolled_value = receipt.new_rolled_value
        copied.new_roll_ordinal = receipt.new_roll_ordinal
    elseif receipt.operation_type == 'DESTROY_EQUIPMENT' then
        copied.destroy_reason = receipt.destroy_reason
    else
        -- Preserve unknown operation fields for fail-closed codec import.
        if receipt.from_level ~= nil then
            copied.from_level = receipt.from_level
        end
        if receipt.to_level ~= nil then
            copied.to_level = receipt.to_level
        end
        if receipt.slot_index ~= nil then
            copied.slot_index = receipt.slot_index
        end
        if receipt.new_affix_id ~= nil then
            copied.new_affix_id = receipt.new_affix_id
        end
        if receipt.new_tier ~= nil then
            copied.new_tier = receipt.new_tier
        end
        if receipt.new_rolled_value ~= nil then
            copied.new_rolled_value = receipt.new_rolled_value
        end
        if receipt.new_roll_ordinal ~= nil then
            copied.new_roll_ordinal = receipt.new_roll_ordinal
        end
        if receipt.destroy_reason ~= nil then
            copied.destroy_reason = receipt.destroy_reason
        end
    end
    return copied
end

local function copy_tombstones_map(tombstones)
    local copied = {}
    local instance_id
    local destroyed_revision
    for instance_id, destroyed_revision in raw_next, tombstones do
        copied[instance_id] = destroyed_revision
    end
    return copied
end

local function snapshot_state(state)
    local instances = {}
    local instance_id
    local instance
    for instance_id, instance in raw_next, state.instances do
        local copied = copy_instance(instance)
        if not copied.ok then
            return copied
        end
        instances[#instances + 1] = copied.value
    end
    table_sort(instances, function(left, right)
        return bytewise_string_less(left.instance_id, right.instance_id)
    end)

    local loadouts = {}
    local character_id
    local loadout
    for character_id, loadout in raw_next, state.loadouts do
        local copied = copy_loadout(loadout)
        if not copied.ok then
            return copied
        end
        loadouts[#loadouts + 1] = copied.value
    end
    table_sort(loadouts, function(left, right)
        return bytewise_string_less(left.character_id, right.character_id)
    end)

    local tombstones = {}
    local destroyed_revision
    for instance_id, destroyed_revision in raw_next, state.tombstones do
        tombstones[#tombstones + 1] = {
            instance_id = instance_id,
            destroyed_revision = destroyed_revision,
        }
    end
    table_sort(tombstones, function(left, right)
        return bytewise_string_less(left.instance_id, right.instance_id)
    end)

    return result_ok({
        equipment_save_revision = state.equipment_save_revision,
        instances = instances,
        loadouts = loadouts,
        tombstones = tombstones,
    })
end

local function snapshot_receipts(state)
    local receipts = {}
    local receipt_id
    local receipt
    for receipt_id, receipt in raw_next, state.receipts do
        receipts[receipt_id] = copy_receipt(receipt)
    end
    return {
        receipt_revision = state.receipt_revision,
        receipts = receipts,
    }
end

function FakeEquipmentStore.new()
    local view = set_metatable({}, Store)
    STATES[view] = {
        equipment_save_revision = 0,
        receipt_revision = 0,
        instances = {},
        loadouts = {},
        tombstones = {},
        receipts = {},
    }
    return result_ok(view)
end

function Store:get_instance(instance_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local instance = state.instances[instance_id]
    if instance == nil then
        return result_err(
            'EQUIPMENT_NOT_FOUND',
            'error.equipment.not_found',
            false,
            { reason = 'INSTANCE_NOT_FOUND', instance_id = instance_id }
        )
    end
    return copy_instance(instance)
end

function Store:put_instance(instance, options)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local copied = copy_instance(instance)
    if not copied.ok then
        return copied
    end
    local instance_id = copied.value.instance_id
    if state.tombstones[instance_id] ~= nil then
        return result_err(
            'EQUIPMENT_TOMBSTONED',
            'error.equipment.tombstoned',
            false,
            {
                reason = 'INSTANCE_TOMBSTONED',
                instance_id = instance_id,
                destroyed_revision = state.tombstones[instance_id],
            }
        )
    end
    options = options or {}
    local bump = options.bump_save_revision
    if bump == nil then
        bump = true
    end
    state.instances[instance_id] = copied.value
    if bump == true then
        state.equipment_save_revision = state.equipment_save_revision + 1
    end
    return result_ok({
        equipment_save_revision = state.equipment_save_revision,
        instance_id = instance_id,
    })
end

function Store:replace_instances_and_loadouts(instances_map, loadouts_map, options)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(instances_map) ~= 'table' or get_metatable(instances_map) ~= nil then
        return invalid('INSTANCES_MAP_REQUIRED', { field = 'instances_map' })
    end
    if type_value(loadouts_map) ~= 'table' or get_metatable(loadouts_map) ~= nil then
        return invalid('LOADOUTS_MAP_REQUIRED', { field = 'loadouts_map' })
    end
    options = options or {}
    local bump = options.bump_save_revision
    if bump == nil then
        bump = true
    end

    local next_instances = {}
    local instance_id
    local instance
    for instance_id, instance in raw_next, instances_map do
        if state.tombstones[instance_id] ~= nil then
            return result_err(
                'EQUIPMENT_TOMBSTONED',
                'error.equipment.tombstoned',
                false,
                {
                    reason = 'INSTANCE_TOMBSTONED',
                    instance_id = instance_id,
                    destroyed_revision = state.tombstones[instance_id],
                }
            )
        end
        local copied = copy_instance(instance)
        if not copied.ok then
            return copied
        end
        next_instances[instance_id] = copied.value
    end

    local next_loadouts = {}
    local character_id
    local loadout
    for character_id, loadout in raw_next, loadouts_map do
        local copied = copy_loadout(loadout)
        if not copied.ok then
            return copied
        end
        next_loadouts[character_id] = copied.value
    end

    state.instances = next_instances
    state.loadouts = next_loadouts
    if bump == true then
        state.equipment_save_revision = state.equipment_save_revision + 1
    end
    return result_ok({
        equipment_save_revision = state.equipment_save_revision,
    })
end

--- Atomically remove an instance, write a tombstone, and clear loadout slots.
--- destroyed_revision should be the pre-destroy instance_revision.
function Store:destroy_instance(instance_id, destroyed_revision, options)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(instance_id) ~= 'string' or instance_id == '' then
        return invalid('INSTANCE_ID_REQUIRED', { field = 'instance_id' })
    end
    if type_value(destroyed_revision) ~= 'number'
        or destroyed_revision ~= destroyed_revision
        or destroyed_revision == math.huge
        or destroyed_revision == -math.huge
        or destroyed_revision ~= math.floor(destroyed_revision)
        or destroyed_revision < 0
    then
        return invalid('DESTROYED_REVISION_INVALID', {
            field = 'destroyed_revision',
        })
    end
    if state.tombstones[instance_id] ~= nil then
        return result_err(
            'EQUIPMENT_ALREADY_DESTROYED',
            'error.equipment.already_destroyed',
            false,
            {
                reason = 'ALREADY_TOMBSTONED',
                instance_id = instance_id,
                destroyed_revision = state.tombstones[instance_id],
            }
        )
    end
    local existing = state.instances[instance_id]
    if existing == nil then
        return result_err(
            'EQUIPMENT_NOT_FOUND',
            'error.equipment.not_found',
            false,
            { reason = 'INSTANCE_NOT_FOUND', instance_id = instance_id }
        )
    end

    options = options or {}
    local bump = options.bump_save_revision
    if bump == nil then
        bump = true
    end

    local cleared_slots = {}
    local character_id
    local loadout
    local slot_fields = {
        'weapon_instance_id',
        'head_instance_id',
        'body_instance_id',
        'accessory_instance_id',
    }
    for character_id, loadout in raw_next, state.loadouts do
        local dirty = false
        local slot_index
        for slot_index = 1, #slot_fields do
            local field = slot_fields[slot_index]
            if loadout[field] == instance_id then
                loadout[field] = nil
                dirty = true
                cleared_slots[#cleared_slots + 1] = {
                    character_id = character_id,
                    slot = field,
                }
            end
        end
        if dirty then
            loadout.loadout_revision = (loadout.loadout_revision or 0) + 1
        end
    end

    state.instances[instance_id] = nil
    state.tombstones[instance_id] = destroyed_revision
    if bump == true then
        state.equipment_save_revision = state.equipment_save_revision + 1
    end
    return result_ok({
        equipment_save_revision = state.equipment_save_revision,
        instance_id = instance_id,
        destroyed_revision = destroyed_revision,
        cleared_slots = cleared_slots,
    })
end

function Store:get_tombstone(instance_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local destroyed_revision = state.tombstones[instance_id]
    if destroyed_revision == nil then
        return result_ok(nil)
    end
    return result_ok({
        instance_id = instance_id,
        destroyed_revision = destroyed_revision,
    })
end

function Store:get_tombstones_map()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return result_ok(copy_tombstones_map(state.tombstones))
end

function Store:get_loadout(character_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local loadout = state.loadouts[character_id]
    if loadout == nil then
        return CharacterLoadout.empty(character_id)
    end
    return copy_loadout(loadout)
end

function Store:get_instances_map()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local copied = {}
    local instance_id
    local instance
    for instance_id, instance in raw_next, state.instances do
        local row = copy_instance(instance)
        if not row.ok then
            return row
        end
        copied[instance_id] = row.value
    end
    return result_ok(copied)
end

function Store:export_save_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local snapshot = snapshot_state(state)
    if not snapshot.ok then
        return snapshot
    end
    return EquipmentSaveCodec.encode(snapshot.value)
end

function Store:export_receipt_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return EquipmentReceiptCodec.encode(snapshot_receipts(state))
end

function Store:import_save_bundle(bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local decoded = EquipmentSaveCodec.decode(bundle)
    if not decoded.ok then
        return decoded
    end
    local instances = {}
    local index
    for index = 1, #decoded.value.instances do
        local instance = decoded.value.instances[index]
        instances[instance.instance_id] = instance
    end
    local loadouts = {}
    for index = 1, #decoded.value.loadouts do
        local loadout = decoded.value.loadouts[index]
        loadouts[loadout.character_id] = loadout
    end
    local tombstones = {}
    for index = 1, #decoded.value.tombstones do
        local tombstone = decoded.value.tombstones[index]
        tombstones[tombstone.instance_id] = tombstone.destroyed_revision
    end
    state.equipment_save_revision = decoded.value.equipment_save_revision
    state.instances = instances
    state.loadouts = loadouts
    state.tombstones = tombstones
    return result_ok(true)
end

function Store:import_receipt_bundle(bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local decoded = EquipmentReceiptCodec.decode(bundle)
    if not decoded.ok then
        return decoded
    end
    local receipts = {}
    local receipt_id
    local receipt
    for receipt_id, receipt in raw_next, decoded.value.receipts do
        receipts[receipt_id] = copy_receipt(receipt)
    end
    state.receipt_revision = decoded.value.receipt_revision
    state.receipts = receipts
    return result_ok(true)
end

function Store:get_receipt(receipt_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local receipt = state.receipts[receipt_id]
    if receipt == nil then
        return result_ok(nil)
    end
    return result_ok(copy_receipt(receipt))
end

function Store:put_committed_receipt(receipt)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(receipt) ~= 'table' or get_metatable(receipt) ~= nil then
        return invalid('RECEIPT_TABLE_REQUIRED', { field = 'receipt' })
    end
    local receipt_id = raw_get(receipt, 'receipt_id')
    if type_value(receipt_id) ~= 'string' then
        return invalid('RECEIPT_ID_REQUIRED', { field = 'receipt_id' })
    end
    if state.receipts[receipt_id] ~= nil then
        return result_ok({
            already_present = true,
            receipt = copy_receipt(state.receipts[receipt_id]),
        })
    end
    state.receipts[receipt_id] = copy_receipt(receipt)
    state.receipt_revision = state.receipt_revision + 1
    return result_ok({
        already_present = false,
        receipt_revision = state.receipt_revision,
    })
end

function Store:get_save_revision()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return result_ok(state.equipment_save_revision)
end

function Store:get_receipt_revision()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return result_ok(state.receipt_revision)
end

return FakeEquipmentStore
