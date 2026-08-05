-- Durable traversal domain facts (system 26).
-- Only COMMITTED safe landings and water enter/exit become DomainEvents.
-- WaterWalkAdvanced stays a lightweight runtime notice and is not projected to quests.

local DomainEvent = require 'wzx.domain.common.domain_event'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Sha256 = require 'wzx.domain.common.sha256'
local TraversalErrorCodes = require 'wzx.domain.traversal.error_codes'

local TraversalEvents = {}
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local SOURCE_SYSTEM = '26'

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.traversal.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(TraversalErrorCodes.TRAVERSAL_ARGUMENT_INVALID, reason, details)
end

local function hash_event_id(namespace, key)
    local digest, digest_error = Sha256.hex(namespace .. '|' .. key)
    if digest == nil then
        return fail(
            TraversalErrorCodes.TRAVERSAL_BUILD_INVALID,
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
            TraversalErrorCodes.TRAVERSAL_BUILD_INVALID,
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

local function copy_link_ids(link_ids)
    local copied = {}
    if type_value(link_ids) ~= 'table' then
        return copied
    end
    local index
    for index = 1, #link_ids do
        copied[index] = link_ids[index]
    end
    return copied
end

function TraversalEvents.build_landed(input)
    if type_value(input) ~= 'table' then
        return invalid('INPUT_REQUIRED')
    end
    local receipt_id = input.landing_receipt_id
    local receipt_check = RuntimeId.validate_derived(receipt_id, 'landing_receipt_id')
    if not receipt_check.ok then
        return invalid('LANDING_RECEIPT_INVALID')
    end
    local digest = hash_event_id('TraversalLanded', receipt_id)
    if not digest.ok then
        return digest
    end
    local event = {
        event_id = 'traversal:landed:' .. digest.value,
        event_type = 'TraversalLanded',
        schema_version = 1,
        aggregate_id = input.target_cell_id or input.to_cell_id,
        revision = input.revision or 0,
        payload = {
            traversal_session_id = input.traversal_session_id,
            from_cell_id = input.from_cell_id,
            to_cell_id = input.to_cell_id or input.target_cell_id,
            traversed_link_ids = copy_link_ids(input.traversed_link_ids),
            marker_id = input.marker_id,
            landing_receipt_id = receipt_id,
            segment_sequence = input.segment_sequence or 1,
            mode = input.mode or 'JUMP',
            water_zone_id = input.water_zone_id,
        },
        source_system = SOURCE_SYSTEM,
        causation_id = receipt_id,
    }
    return finalize(event)
end

function TraversalEvents.build_water_entered(input)
    if type_value(input) ~= 'table' then
        return invalid('INPUT_REQUIRED')
    end
    local session_id = input.traversal_session_id
    local session_check = RuntimeId.validate_derived(session_id, 'traversal_session_id')
    if not session_check.ok then
        return invalid('SESSION_ID_INVALID')
    end
    local sequence = input.segment_sequence or 1
    local key = session_id .. '|enter|' .. tostring(sequence)
    local digest = hash_event_id('WaterWalkEntered', key)
    if not digest.ok then
        return digest
    end
    local event = {
        event_id = 'traversal:water_enter:' .. digest.value,
        event_type = 'WaterWalkEntered',
        schema_version = 1,
        aggregate_id = input.water_zone_id or session_id,
        revision = input.revision or 0,
        payload = {
            traversal_session_id = session_id,
            water_zone_id = input.water_zone_id,
            entry_cell_id = input.entry_cell_id,
            remaining = input.remaining or 0,
            segment_sequence = sequence,
        },
        source_system = SOURCE_SYSTEM,
        causation_id = session_id,
    }
    return finalize(event)
end

function TraversalEvents.build_water_exited(input)
    if type_value(input) ~= 'table' then
        return invalid('INPUT_REQUIRED')
    end
    local receipt_id = input.landing_receipt_id
    local receipt_check = RuntimeId.validate_derived(receipt_id, 'landing_receipt_id')
    if not receipt_check.ok then
        return invalid('LANDING_RECEIPT_INVALID')
    end
    local digest = hash_event_id('WaterWalkExited', receipt_id)
    if not digest.ok then
        return digest
    end
    local event = {
        event_id = 'traversal:water_exit:' .. digest.value,
        event_type = 'WaterWalkExited',
        schema_version = 1,
        aggregate_id = input.water_zone_id or input.shore_cell_id,
        revision = input.revision or 0,
        payload = {
            traversal_session_id = input.traversal_session_id,
            water_zone_id = input.water_zone_id,
            shore_cell_id = input.shore_cell_id,
            shore_marker_id = input.shore_marker_id or input.marker_id,
            landing_receipt_id = receipt_id,
            segment_sequence = input.segment_sequence or 1,
        },
        source_system = SOURCE_SYSTEM,
        causation_id = receipt_id,
    }
    return finalize(event)
end

TraversalEvents.SOURCE_SYSTEM = SOURCE_SYSTEM

return TraversalEvents
