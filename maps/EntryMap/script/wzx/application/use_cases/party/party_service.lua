local Formation = require 'wzx.domain.contracts.formation'
local PartyAggregate = require 'wzx.domain.party.party_aggregate'
local PartyErrorCodes = require 'wzx.domain.party.error_codes'
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
    if party_store ~= nil then
        local loaded = party_store:get_party(party_context)
        if not loaded.ok then
            return loaded
        end
        party = loaded.value
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        party = party,
        party_context = party_context,
        owned_character_ids = owned,
        party_store = party_store,
        save_bridge = save_bridge,
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
    local committed = PartyAggregate.commit_formation(
        loaded.value,
        input,
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
