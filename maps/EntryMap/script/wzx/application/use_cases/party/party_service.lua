local Formation = require 'wzx.domain.contracts.formation'
local PartyAggregate = require 'wzx.domain.party.party_aggregate'
local PartyErrorCodes = require 'wzx.domain.party.error_codes'
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

    local view = set_metatable({}, Service)
    STATES[view] = {
        party = empty.value,
        owned_character_ids = owned,
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
    return PartyAggregate.snapshot(state.party)
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
    local committed = PartyAggregate.commit_formation(
        state.party,
        input,
        state.owned_character_ids
    )
    if not committed.ok then
        return committed
    end
    state.party = committed.value
    return result_ok({
        status = 'COMMITTED',
        formation = committed.value,
        revision = committed.value.revision,
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
    local swapped = PartyAggregate.swap_positions(
        state.party,
        raw_get(input, 'position_a'),
        raw_get(input, 'position_b'),
        raw_get(input, 'expected_revision')
    )
    if not swapped.ok then
        return swapped
    end
    state.party = swapped.value
    return result_ok({
        status = 'COMMITTED',
        formation = swapped.value,
        revision = swapped.value.revision,
    })
end

function Service:validate_ready()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local snap = PartyAggregate.snapshot(state.party)
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
