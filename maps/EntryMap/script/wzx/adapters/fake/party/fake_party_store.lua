local PartyAggregate = require 'wzx.domain.party.party_aggregate'
local PartySaveCodec = require 'wzx.domain.party.party_save_codec'
local Result = require 'wzx.domain.common.result'

local FakePartyStore = {}
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
    return {
        party_save_revision = state.party_save_revision,
        parties = parties,
    }
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
        parties = {
            [initial_context] = empty.value,
        },
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

function Store:export_save_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return PartySaveCodec.encode(snapshot_state(state))
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
    state.party_save_revision = decoded.value.party_save_revision
    state.parties = parties
    return result_ok(true)
end

function Store:get_save_revision()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return result_ok(state.party_save_revision)
end

return FakePartyStore
