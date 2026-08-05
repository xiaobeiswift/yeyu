local PartyAggregate = require 'wzx.domain.party.party_aggregate'
local PartyPreset = require 'wzx.domain.party.party_preset'
local PartyReceiptCodec = require 'wzx.domain.party.party_receipt_codec'
local PartySaveCodec = require 'wzx.domain.party.party_save_codec'
local Result = require 'wzx.domain.common.result'

local FakePartyStore = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Store = {}
Store.__index = Store
Store.__newindex = function()
    error_value('fake party store is read-only', 2)
end
Store.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'INVALID_ARGUMENT',
        'error.party.fake_store_invalid',
        false,
        details
    )
end

local function copy_party(party)
    local members = {}
    local index
    for index = 1, #party.member_rows do
        local row = party.member_rows[index]
        members[index] = {
            character_id = row.character_id,
            position_index = row.position_index,
            entry_order = row.entry_order,
            role_tag_override = row.role_tag_override,
        }
    end
    return {
        party_context = party.party_context,
        leader_character_id = party.leader_character_id,
        member_rows = members,
        formation_template_id = party.formation_template_id,
        active_preset_id = party.active_preset_id,
        is_dirty_from_preset = party.is_dirty_from_preset == true,
        revision = party.revision,
    }
end

local function copy_preset(preset)
    local snap = PartyPreset.copy_preset(preset)
    if not snap.ok then
        return nil
    end
    return snap.value
end

local function copy_receipt(receipt)
    local copied = {
        receipt_id = receipt.receipt_id,
        request_hash = receipt.request_hash,
        result_hash = receipt.result_hash,
        status = receipt.status,
        operation_type = receipt.operation_type,
        party_context = receipt.party_context,
        party_save_revision_after = receipt.party_save_revision_after,
    }
    if receipt.preset_id ~= nil then
        copied.preset_id = receipt.preset_id
    end
    if receipt.formation_revision_after ~= nil then
        copied.formation_revision_after = receipt.formation_revision_after
    end
    if receipt.active_preset_id ~= nil then
        copied.active_preset_id = receipt.active_preset_id
    end
    return copied
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

local function snapshot_state(state)
    local parties = {}
    local context
    local party
    for context, party in raw_next, state.parties do
        parties[#parties + 1] = copy_party(party)
    end
    table.sort(parties, function(left, right)
        return left.party_context < right.party_context
    end)

    local listed = PartyPreset.presets_map_to_list(state.presets)
    if not listed.ok then
        return listed
    end
    return result_ok({
        party_save_revision = state.party_save_revision,
        parties = parties,
        presets = listed.value,
    })
end

function FakePartyStore.new(options)
    options = options or {}
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local initial_context = options.party_context or 'PVE_MAIN'
    local empty = PartyAggregate.empty(initial_context)
    if not empty.ok then
        return empty
    end
    local view = set_metatable({}, Store)
    STATES[view] = {
        party_save_revision = 0,
        receipt_revision = 0,
        parties = {
            [initial_context] = empty.value,
        },
        presets = {},
        next_preset_seq = 1,
        receipts = {},
    }
    return result_ok(view)
end

function Store:get_party(party_context)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    party_context = party_context or 'PVE_MAIN'
    local party = state.parties[party_context]
    if party == nil then
        local empty = PartyAggregate.empty(party_context)
        if not empty.ok then
            return empty
        end
        return result_ok(empty.value)
    end
    return result_ok(copy_party(party))
end

function Store:replace_party(party, options)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local snap = PartyAggregate.snapshot(party)
    if not snap.ok then
        return snap
    end
    options = options or {}
    local bump = options.bump_save_revision
    if bump == nil then
        bump = true
    end
    state.parties[snap.value.party_context] = copy_party(snap.value)
    if bump == true then
        state.party_save_revision = state.party_save_revision + 1
    end
    return result_ok({
        party_save_revision = state.party_save_revision,
        party_context = snap.value.party_context,
        revision = snap.value.revision,
    })
end

function Store:get_preset(preset_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local preset = state.presets[preset_id]
    if preset == nil then
        return result_err(
            'PARTY_PRESET_NOT_FOUND',
            'error.party.party_preset_not_found',
            false,
            { reason = 'PRESET_NOT_FOUND', preset_id = preset_id }
        )
    end
    local copied = copy_preset(preset)
    if copied == nil then
        return invalid('PRESET_COPY_FAILED', { preset_id = preset_id })
    end
    return result_ok(copied)
end

function Store:list_presets(party_context)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local listed = PartyPreset.presets_map_to_list(state.presets)
    if not listed.ok then
        return listed
    end
    if party_context == nil then
        return result_ok(listed.value)
    end
    local filtered = {}
    local index
    for index = 1, #listed.value do
        if listed.value[index].party_context == party_context then
            filtered[#filtered + 1] = listed.value[index]
        end
    end
    return result_ok(filtered)
end

function Store:get_presets_map()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local listed = PartyPreset.presets_map_to_list(state.presets)
    if not listed.ok then
        return listed
    end
    local mapped = PartyPreset.presets_list_to_map(listed.value)
    if not mapped.ok then
        return mapped
    end
    return result_ok(mapped.value)
end

-- Full replace of presets map. options.bump_save_revision defaults true.
function Store:replace_presets(presets_map, options)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(presets_map) ~= 'table' or get_metatable(presets_map) ~= nil then
        return invalid('PRESETS_MAP_REQUIRED', { field = 'presets_map' })
    end
    local listed = PartyPreset.presets_map_to_list(presets_map)
    if not listed.ok then
        return listed
    end
    local validated = PartyPreset.presets_list_to_map(listed.value)
    if not validated.ok then
        return validated
    end
    options = options or {}
    local bump = options.bump_save_revision
    if bump == nil then
        bump = true
    end
    state.presets = validated.value
    if bump == true then
        state.party_save_revision = state.party_save_revision + 1
    end
    return result_ok({
        party_save_revision = state.party_save_revision,
        preset_count = #listed.value,
    })
end

function Store:replace_party_and_presets(party, presets_map, options)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local snap = PartyAggregate.snapshot(party)
    if not snap.ok then
        return snap
    end
    if type_value(presets_map) ~= 'table' or get_metatable(presets_map) ~= nil then
        return invalid('PRESETS_MAP_REQUIRED', { field = 'presets_map' })
    end
    local listed = PartyPreset.presets_map_to_list(presets_map)
    if not listed.ok then
        return listed
    end
    local validated = PartyPreset.presets_list_to_map(listed.value)
    if not validated.ok then
        return validated
    end
    options = options or {}
    local bump = options.bump_save_revision
    if bump == nil then
        bump = true
    end
    state.parties[snap.value.party_context] = copy_party(snap.value)
    state.presets = validated.value
    if bump == true then
        state.party_save_revision = state.party_save_revision + 1
    end
    return result_ok({
        party_save_revision = state.party_save_revision,
        party_context = snap.value.party_context,
        revision = snap.value.revision,
        preset_count = #listed.value,
    })
end

function Store:allocate_preset_id()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local seq = state.next_preset_seq
    local guard = 0
    while guard < 10000 do
        local candidate = 'preset_party_' .. tostring(seq)
        seq = seq + 1
        guard = guard + 1
        if state.presets[candidate] == nil then
            state.next_preset_seq = seq
            return result_ok(candidate)
        end
    end
    return invalid('PRESET_ID_ALLOCATION_EXHAUSTED')
end

function Store:export_save_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local snap = snapshot_state(state)
    if not snap.ok then
        return snap
    end
    return PartySaveCodec.encode(snap.value)
end

function Store:import_save_bundle(bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local decoded = PartySaveCodec.decode(bundle)
    if not decoded.ok then
        return decoded
    end
    local parties = {}
    local index
    for index = 1, #decoded.value.parties do
        local party = decoded.value.parties[index]
        parties[party.party_context] = copy_party(party)
    end
    local mapped = PartyPreset.presets_list_to_map(decoded.value.presets or {})
    if not mapped.ok then
        return mapped
    end
    state.party_save_revision = decoded.value.party_save_revision
    state.parties = parties
    state.presets = mapped.value

    local max_seq = state.next_preset_seq
    local preset_id
    for preset_id in raw_next, state.presets do
        local num = string.match(preset_id, '^preset_party_(%d+)$')
        if num ~= nil then
            local n = tonumber(num)
            if n ~= nil and n >= max_seq then
                max_seq = n + 1
            end
        end
    end
    state.next_preset_seq = max_seq
    return result_ok(true)
end

function Store:get_save_revision()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return result_ok(state.party_save_revision)
end

function Store:export_receipt_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return PartyReceiptCodec.encode(snapshot_receipts(state))
end

function Store:import_receipt_bundle(bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local decoded = PartyReceiptCodec.decode(bundle)
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

function Store:get_receipt_revision()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return result_ok(state.receipt_revision)
end

return FakePartyStore
