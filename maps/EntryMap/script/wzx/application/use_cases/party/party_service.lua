local Formation = require 'wzx.domain.contracts.formation'
local PartyAggregate = require 'wzx.domain.party.party_aggregate'
local PartyErrorCodes = require 'wzx.domain.party.error_codes'
local PartyPreset = require 'wzx.domain.party.party_preset'
local PartySaveBridge = require 'wzx.application.use_cases.party.party_save_bridge'
local Result = require 'wzx.domain.common.result'

local PartyService = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('party service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.party.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(PartyErrorCodes.PARTY_ARGUMENT_INVALID, reason, details, false)
end

local function is_party_store(value)
    return type_value(value) == 'table'
        and type_value(value.get_party) == 'function'
        and type_value(value.replace_party) == 'function'
end

local function load_party(state)
    if state.party_store == nil then
        return result_ok(state.party)
    end
    local loaded = state.party_store:get_party(state.party_context)
    if not loaded.ok then
        return loaded
    end
    state.party = loaded.value
    return result_ok(state.party)
end

local function load_presets_map(state)
    if state.party_store ~= nil
        and type_value(state.party_store.get_presets_map) == 'function'
    then
        local loaded = state.party_store:get_presets_map()
        if not loaded.ok then
            return loaded
        end
        state.presets = loaded.value
        return result_ok(state.presets)
    end
    return result_ok(state.presets)
end

local function persist_party(state)
    if state.party_store == nil then
        return result_ok({ persisted = false })
    end
    local saved = state.party_store:replace_party(state.party)
    if not saved.ok then
        return saved
    end
    return result_ok({
        persisted = true,
        party_save_revision = saved.value.party_save_revision,
    })
end

local function persist_presets(state)
    if state.party_store == nil then
        return result_ok({ persisted = false })
    end
    if type_value(state.party_store.replace_presets) ~= 'function' then
        return invalid('PARTY_STORE_PRESETS_UNSUPPORTED', {
            field = 'party_store.replace_presets',
        })
    end
    local saved = state.party_store:replace_presets(state.presets)
    if not saved.ok then
        return saved
    end
    return result_ok({
        persisted = true,
        party_save_revision = saved.value.party_save_revision,
    })
end

local function persist_party_and_presets(state)
    if state.party_store == nil then
        return result_ok({ persisted = false })
    end
    if type_value(state.party_store.replace_party_and_presets) == 'function' then
        local saved = state.party_store:replace_party_and_presets(
            state.party,
            state.presets
        )
        if not saved.ok then
            return saved
        end
        return result_ok({
            persisted = true,
            party_save_revision = saved.value.party_save_revision,
        })
    end
    local party_saved = persist_party(state)
    if not party_saved.ok then
        return party_saved
    end
    local presets_saved = persist_presets(state)
    if not presets_saved.ok then
        return presets_saved
    end
    return result_ok({
        persisted = party_saved.value.persisted or presets_saved.value.persisted,
        party_save_revision = presets_saved.value.party_save_revision
            or party_saved.value.party_save_revision,
    })
end

local function allocate_preset_id(state)
    if state.party_store ~= nil
        and type_value(state.party_store.allocate_preset_id) == 'function'
    then
        return state.party_store:allocate_preset_id()
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

local function maybe_persist_save(self, input)
    local state = STATES[self]
    if state == nil then
        return result_ok({ status = 'SKIPPED', reason = 'SERVICE_MISSING' })
    end
    if type_value(input) == 'table' and raw_get(input, 'skip_save') == true then
        return result_ok({ status = 'SKIPPED', reason = 'SKIP_SAVE' })
    end
    if state.save_bridge == nil then
        return result_ok({ status = 'SKIPPED', reason = 'SAVE_BRIDGE_UNBOUND' })
    end
    local player_save_scope = type_value(input) == 'table'
        and raw_get(input, 'player_save_scope')
        or nil
    if player_save_scope == nil then
        return result_ok({
            status = 'SKIPPED',
            reason = 'PLAYER_SAVE_SCOPE_MISSING',
        })
    end
    local saved = state.save_bridge:persist_player_party({
        player_save_scope = player_save_scope,
        player_ref = raw_get(input, 'player_ref') or player_save_scope,
        request_id = raw_get(input, 'request_id') or 'request_party_save',
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
    if not saved.ok then
        return saved
    end
    return result_ok(saved.value)
end

function PartyService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local party_context = raw_get(options, 'party_context') or 'PVE_MAIN'
    local empty = PartyAggregate.empty(party_context)
    if not empty.ok then
        return empty
    end
    local owned = raw_get(options, 'owned_character_ids')
    if owned ~= nil and (type_value(owned) ~= 'table' or get_metatable(owned) ~= nil) then
        return invalid('OWNED_CHARACTER_IDS_TABLE_REQUIRED', {
            field = 'owned_character_ids',
        })
    end
    local party_store = raw_get(options, 'party_store')
    if party_store ~= nil and not is_party_store(party_store) then
        return invalid('PARTY_STORE_INVALID', { field = 'party_store' })
    end
    local save_bridge = raw_get(options, 'save_bridge')
    if save_bridge ~= nil and not PartySaveBridge.is_authority(save_bridge) then
        return invalid('SAVE_BRIDGE_AUTHORITY_REQUIRED', {
            field = 'save_bridge',
        })
    end
    if save_bridge ~= nil and party_store == nil then
        return invalid('PARTY_STORE_REQUIRED_FOR_SAVE_BRIDGE', {
            field = 'party_store',
        })
    end

    local party = empty.value
    local presets = {}
    local next_preset_seq = 1
    if party_store ~= nil then
        local loaded = party_store:get_party(party_context)
        if not loaded.ok then
            return loaded
        end
        party = loaded.value
        if type_value(party_store.get_presets_map) == 'function' then
            local loaded_presets = party_store:get_presets_map()
            if not loaded_presets.ok then
                return loaded_presets
            end
            presets = loaded_presets.value
        end
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        party = party,
        party_context = party_context,
        owned_character_ids = owned,
        party_store = party_store,
        save_bridge = save_bridge,
        presets = presets,
        next_preset_seq = next_preset_seq,
    }
    return result_ok(view)
end

function PartyService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

function Service:get_formation()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_party(state)
    if not loaded.ok then
        return loaded
    end
    return PartyAggregate.snapshot(loaded.value)
end

function Service:list_presets(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_presets_map(state)
    if not loaded.ok then
        return loaded
    end
    local party_context = nil
    if type_value(input) == 'table' then
        party_context = raw_get(input, 'party_context')
    end
    if party_context == nil then
        party_context = state.party_context
    end
    local listed = PartyPreset.presets_map_to_list(loaded.value)
    if not listed.ok then
        return listed
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

function Service:get_preset(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local loaded = load_presets_map(state)
    if not loaded.ok then
        return loaded
    end
    local preset_id = raw_get(input, 'preset_id')
    local preset = loaded.value[preset_id]
    if preset == nil then
        return fail(
            PartyErrorCodes.PARTY_PRESET_NOT_FOUND,
            'PRESET_NOT_FOUND',
            { preset_id = preset_id },
            false
        )
    end
    return PartyPreset.copy_preset(preset)
end

function Service:set_owned_characters(owned_character_ids)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(owned_character_ids) ~= 'table'
        or get_metatable(owned_character_ids) ~= nil
    then
        return invalid('OWNED_CHARACTER_IDS_TABLE_REQUIRED', {
            field = 'owned_character_ids',
        })
    end
    state.owned_character_ids = owned_character_ids
    return result_ok(true)
end

function Service:commit_formation(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local loaded = load_party(state)
    if not loaded.ok then
        return loaded
    end

    -- Manual edits that omit active_preset_id keep the previous one and mark dirty.
    local commit_input = input
    if raw_get(input, 'active_preset_id') == nil
        and loaded.value.active_preset_id ~= nil
        and raw_get(input, 'clear_active_preset') ~= true
    then
        commit_input = {
            member_rows = raw_get(input, 'member_rows'),
            leader_character_id = raw_get(input, 'leader_character_id'),
            formation_template_id = raw_get(input, 'formation_template_id'),
            expected_revision = raw_get(input, 'expected_revision'),
            active_preset_id = loaded.value.active_preset_id,
            is_dirty_from_preset = true,
        }
    end

    local committed = PartyAggregate.commit_formation(
        loaded.value,
        commit_input,
        state.owned_character_ids
    )
    if not committed.ok then
        return committed
    end
    state.party = committed.value
    local persisted = persist_party(state)
    if not persisted.ok then
        return persisted
    end
    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        formation = committed.value,
        revision = committed.value.revision,
        store = persisted.value,
        save = save.value,
    })
end

function Service:swap_positions(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local loaded = load_party(state)
    if not loaded.ok then
        return loaded
    end
    local swapped = PartyAggregate.swap_positions(
        loaded.value,
        raw_get(input, 'position_a'),
        raw_get(input, 'position_b'),
        raw_get(input, 'expected_revision')
    )
    if not swapped.ok then
        return swapped
    end
    state.party = swapped.value
    local persisted = persist_party(state)
    if not persisted.ok then
        return persisted
    end
    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        formation = swapped.value,
        revision = swapped.value.revision,
        store = persisted.value,
        save = save.value,
    })
end

function Service:save_preset(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local loaded_presets = load_presets_map(state)
    if not loaded_presets.ok then
        return loaded_presets
    end

    local party_context = raw_get(input, 'party_context') or state.party_context
    local member_rows = raw_get(input, 'member_rows')
    local leader_character_id = raw_get(input, 'leader_character_id')
    local formation_template_id = raw_get(input, 'formation_template_id')

    -- Optional: copy draft from current party when members omitted.
    if member_rows == nil or leader_character_id == nil then
        local loaded_party = load_party(state)
        if not loaded_party.ok then
            return loaded_party
        end
        if #loaded_party.value.member_rows < 1 then
            return invalid('PARTY_EMPTY_CANNOT_SAVE_PRESET', {
                party_context = party_context,
            })
        end
        if member_rows == nil then
            member_rows = loaded_party.value.member_rows
        end
        if leader_character_id == nil then
            leader_character_id = loaded_party.value.leader_character_id
        end
        if formation_template_id == nil then
            formation_template_id = loaded_party.value.formation_template_id
        end
    end

    local save_input = {
        preset_id = raw_get(input, 'preset_id'),
        display_name = raw_get(input, 'display_name'),
        party_context = party_context,
        leader_character_id = leader_character_id,
        member_rows = member_rows,
        formation_template_id = formation_template_id,
        expected_revision = raw_get(input, 'expected_revision'),
        protected = raw_get(input, 'protected'),
    }

    local saved = PartyPreset.save_preset(loaded_presets.value, save_input, {
        next_preset_id = function()
            local allocated = allocate_preset_id(state)
            if not allocated.ok then
                return nil
            end
            return allocated.value
        end,
    })
    if not saved.ok then
        return saved
    end
    state.presets = saved.value.presets_map
    local persisted = persist_presets(state)
    if not persisted.ok then
        return persisted
    end
    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = saved.value.status,
        preset = saved.value.preset,
        created = saved.value.created,
        store = persisted.value,
        save = save.value,
    })
end

function Service:apply_preset(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local loaded_presets = load_presets_map(state)
    if not loaded_presets.ok then
        return loaded_presets
    end
    local preset_id = raw_get(input, 'preset_id')
    local preset = loaded_presets.value[preset_id]
    if preset == nil then
        return fail(
            PartyErrorCodes.PARTY_PRESET_NOT_FOUND,
            'PRESET_NOT_FOUND',
            { preset_id = preset_id },
            false
        )
    end
    local loaded_party = load_party(state)
    if not loaded_party.ok then
        return loaded_party
    end
    local applied = PartyPreset.apply_preset_to_party(
        loaded_party.value,
        preset,
        state.owned_character_ids,
        {
            expected_formation_revision = raw_get(input, 'expected_formation_revision')
                or raw_get(input, 'expected_revision'),
        }
    )
    if not applied.ok then
        return applied
    end
    state.party = applied.value.party
    local persisted = persist_party(state)
    if not persisted.ok then
        return persisted
    end
    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'APPLIED',
        formation = applied.value.party,
        preset = applied.value.preset,
        revision = applied.value.party.revision,
        store = persisted.value,
        save = save.value,
    })
end

function Service:delete_preset(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local loaded_presets = load_presets_map(state)
    if not loaded_presets.ok then
        return loaded_presets
    end
    local deleted = PartyPreset.delete_preset(
        loaded_presets.value,
        raw_get(input, 'preset_id'),
        raw_get(input, 'expected_revision')
    )
    if not deleted.ok then
        return deleted
    end
    state.presets = deleted.value.presets_map

    local cleared_active = false
    local loaded_party = load_party(state)
    if not loaded_party.ok then
        return loaded_party
    end
    local party = loaded_party.value
    if party.active_preset_id == raw_get(input, 'preset_id') then
        party = {
            party_context = party.party_context,
            leader_character_id = party.leader_character_id,
            member_rows = party.member_rows,
            formation_template_id = party.formation_template_id,
            active_preset_id = nil,
            is_dirty_from_preset = false,
            revision = party.revision,
        }
        -- Clear active marker without bumping formation revision (metadata only).
        state.party = party
        cleared_active = true
        local persisted = persist_party_and_presets(state)
        if not persisted.ok then
            return persisted
        end
        local save = maybe_persist_save(self, input)
        if not save.ok then
            return save
        end
        return result_ok({
            status = 'DELETED',
            preset = deleted.value.preset,
            cleared_active_preset = true,
            formation = party,
            store = persisted.value,
            save = save.value,
        })
    end

    local persisted = persist_presets(state)
    if not persisted.ok then
        return persisted
    end
    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'DELETED',
        preset = deleted.value.preset,
        cleared_active_preset = cleared_active,
        store = persisted.value,
        save = save.value,
    })
end

function Service:validate_ready()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = load_party(state)
    if not loaded.ok then
        return loaded
    end
    local snap = PartyAggregate.snapshot(loaded.value)
    if not snap.ok then
        return snap
    end
    if #snap.value.member_rows < 1 then
        return fail(
            PartyErrorCodes.PARTY_NOT_READY,
            'PARTY_EMPTY',
            { party_context = snap.value.party_context },
            false
        )
    end
    local validated = Formation.validate(snap.value)
    if not validated.ok then
        return validated
    end
    return result_ok({
        ready = true,
        formation = snap.value,
        revision = snap.value.revision,
    })
end

return PartyService
