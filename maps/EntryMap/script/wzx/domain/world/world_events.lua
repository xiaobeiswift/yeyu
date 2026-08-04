-- Build durable world domain facts (system 12 → quest/dialogue consumers).

local DomainEvent = require 'wzx.domain.common.domain_event'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Sha256 = require 'wzx.domain.common.sha256'
local WorldErrorCodes = require 'wzx.domain.world.error_codes'

local WorldEvents = {}
local get_metatable = getmetatable
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local SOURCE_SYSTEM = '12'

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.world.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(WorldErrorCodes.WORLD_ARGUMENT_INVALID, reason, details)
end

local function hash_event_id(namespace, key)
    local digest, digest_error = Sha256.hex(namespace .. '|' .. key)
    if digest == nil then
        return fail(
            WorldErrorCodes.WORLD_BUILD_INVALID,
            'EVENT_ID_HASH_FAILED',
            { reason = digest_error }
        )
    end
    return result_ok(digest)
end

local function finalize(event)
    local validated = DomainEvent.validate(event)
    if not validated.ok then
        return fail(
            WorldErrorCodes.WORLD_BUILD_INVALID,
            'DOMAIN_EVENT_INVALID',
            {
                cause_code = validated.error and validated.error.code or 'UNKNOWN',
                cause_reason = validated.error
                    and validated.error.details
                    and validated.error.details.reason,
            }
        )
    end
    return DomainEvent.copy(event)
end

function WorldEvents.build_location_discovered(state, location, receipt_id)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(location) ~= 'table' or get_metatable(location) ~= nil then
        return invalid('LOCATION_REQUIRED')
    end
    local receipt_check = RuntimeId.validate_derived(receipt_id, 'receipt_id')
    if not receipt_check.ok then
        return invalid('RECEIPT_INVALID')
    end

    local digest = hash_event_id('LocationDiscovered', receipt_id)
    if not digest.ok then
        return digest
    end

    local event = {
        event_id = 'world:loc:' .. digest.value,
        event_type = 'LocationDiscovered',
        schema_version = 1,
        aggregate_id = location.id,
        revision = state.world_revision or 0,
        payload = {
            location_id = location.id,
            area_id = location.area_id,
            receipt_id = receipt_id,
            unlock_ids = {},
        },
        source_system = SOURCE_SYSTEM,
        causation_id = receipt_id,
    }
    return finalize(event)
end

function WorldEvents.build_flag_changed(state, flag_id, old_value, new_value, reason, receipt_id)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    local receipt_check = RuntimeId.validate_derived(receipt_id, 'receipt_id')
    if not receipt_check.ok then
        return invalid('RECEIPT_INVALID')
    end
    local flag_check = RuntimeId.validate_content(flag_id, 'flag_', 'flag_id')
    if not flag_check.ok then
        return invalid('FLAG_ID_INVALID')
    end

    local digest = hash_event_id('WorldFlagChanged', receipt_id)
    if not digest.ok then
        return digest
    end

    local event = {
        event_id = 'world:flag:' .. digest.value,
        event_type = 'WorldFlagChanged',
        schema_version = 1,
        aggregate_id = flag_id,
        revision = state.world_revision or 0,
        payload = {
            flag_id = flag_id,
            old_value = old_value,
            new_value = new_value,
            reason = reason or 'SET_FLAG',
            receipt_id = receipt_id,
        },
        source_system = SOURCE_SYSTEM,
        causation_id = receipt_id,
    }
    return finalize(event)
end

function WorldEvents.build_chest_opened(state, interactable, receipt_id, terminal_state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(interactable) ~= 'table' or get_metatable(interactable) ~= nil then
        return invalid('INTERACTABLE_REQUIRED')
    end
    local receipt_check = RuntimeId.validate_derived(receipt_id, 'receipt_id')
    if not receipt_check.ok then
        return invalid('RECEIPT_INVALID')
    end

    local digest = hash_event_id('ChestOpened', receipt_id)
    if not digest.ok then
        return digest
    end

    local event = {
        event_id = 'world:chest:' .. digest.value,
        event_type = 'ChestOpened',
        schema_version = 1,
        aggregate_id = interactable.id,
        revision = state.world_revision or 0,
        payload = {
            interactable_id = interactable.id,
            location_id = interactable.location_id,
            reward_id = interactable.action_ref_id,
            reward_receipt_id = receipt_id,
            state = terminal_state or 'OPENED',
        },
        source_system = SOURCE_SYSTEM,
        causation_id = receipt_id,
    }
    return finalize(event)
end

function WorldEvents.build_search_resolved(state, interactable, receipt_id)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(interactable) ~= 'table' or get_metatable(interactable) ~= nil then
        return invalid('INTERACTABLE_REQUIRED')
    end
    local receipt_check = RuntimeId.validate_derived(receipt_id, 'receipt_id')
    if not receipt_check.ok then
        return invalid('RECEIPT_INVALID')
    end

    local digest = hash_event_id('SearchPointResolved', receipt_id)
    if not digest.ok then
        return digest
    end

    local event = {
        event_id = 'world:search:' .. digest.value,
        event_type = 'SearchPointResolved',
        schema_version = 1,
        aggregate_id = interactable.id,
        revision = state.world_revision or 0,
        payload = {
            interactable_id = interactable.id,
            location_id = interactable.location_id,
            result_type = interactable.result_type,
            result_ref = interactable.result_ref_id,
            receipt_id = receipt_id,
        },
        source_system = SOURCE_SYSTEM,
        causation_id = receipt_id,
    }
    return finalize(event)
end

WorldEvents.SOURCE_SYSTEM = SOURCE_SYSTEM

return WorldEvents
