local DomainEvent = require 'wzx.domain.common.domain_event'
local DecimalInteger = require 'wzx.domain.common.decimal_integer'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local Ordered = require 'wzx.domain.common.ordered'

local CombatEvent = {}

local ALLOWED_FIELDS = {
    event_id = true,
    event_type = true,
    schema_version = true,
    aggregate_id = true,
    revision = true,
    payload = true,
    causation_id = true,
    correlation_id = true,
    source_system = true,
    source_occurrence_id = true,
    combat_id = true,
    sequence = true,
    action_index = true,
    occurred_at = true,
}

local function invalid(field, reason, details)
    details = details or {}
    details.field = field
    details.reason = reason
    return Result.err('COMBAT_EVENT_INVALID', 'error.foundation.combat_event_invalid', false, details)
end

function CombatEvent.validate(event, options)
    if type(event) ~= 'table' then
        return invalid('event', 'TABLE_REQUIRED')
    end
    local keys = Ordered.sorted_string_keys(event)
    if not keys.ok then
        return invalid('event', 'NON_STRING_FIELD_KEY')
    end
    local field
    local field_index
    for field_index = 1, #keys.value do
        field = keys.value[field_index]
        if not ALLOWED_FIELDS[field] then
            return invalid(field, 'UNKNOWN_FIELD')
        end
    end
    if event.occurred_at ~= nil then
        return invalid('occurred_at', 'FIELD_MUST_BE_ABSENT')
    end

    local combat_id_check = RuntimeId.validate_component(event.combat_id, 'combat_id')
    if not combat_id_check.ok then
        return invalid('combat_id', 'ATOMIC_COMBAT_ID_REQUIRED')
    end
    if not TableShape.is_integer(event.sequence, 1) then
        return invalid('sequence', 'POSITIVE_INTEGER_REQUIRED')
    end
    if not TableShape.is_integer(event.action_index, 0, 99) then
        return invalid('action_index', 'ACTION_INDEX_OUT_OF_RANGE', {
            minimum = 0,
            maximum = 99,
        })
    end

    local expected_event_id = event.combat_id .. ':' .. DecimalInteger.encode(event.sequence)
    if event.event_id ~= expected_event_id then
        return invalid('event_id', 'COMBAT_EVENT_ID_MISMATCH', {
            expected = expected_event_id,
        })
    end
    if event.aggregate_id ~= event.combat_id then
        return invalid('aggregate_id', 'COMBAT_AGGREGATE_ID_MISMATCH')
    end
    if event.revision ~= event.sequence then
        return invalid('revision', 'COMBAT_REVISION_MUST_EQUAL_SEQUENCE')
    end

    options = options or {}
    local base = DomainEvent.validate(event, {
        allow_specialized_fields = true,
        payload_maximum_table_depth = options.payload_maximum_table_depth,
        registry = options.registry,
    })
    if not base.ok then
        return invalid('event', 'DOMAIN_EVENT_ENVELOPE_INVALID', {
            cause = base.error,
        })
    end
    return Result.ok(event)
end

function CombatEvent.create(fields, options)
    if type(fields) ~= 'table' then
        return invalid('fields', 'TABLE_REQUIRED')
    end
    if not TableShape.is_integer(fields.sequence, 1) then
        return invalid('sequence', 'POSITIVE_INTEGER_REQUIRED')
    end
    local event = {
        event_id = tostring(fields.combat_id or '') .. ':' .. DecimalInteger.encode(fields.sequence),
        event_type = fields.event_type,
        schema_version = fields.schema_version,
        aggregate_id = fields.combat_id,
        revision = fields.sequence,
        payload = fields.payload,
        causation_id = fields.causation_id,
        correlation_id = fields.correlation_id,
        source_system = fields.source_system,
        source_occurrence_id = fields.source_occurrence_id,
        combat_id = fields.combat_id,
        sequence = fields.sequence,
        action_index = fields.action_index,
    }
    local validated = CombatEvent.validate(event, options)
    if not validated.ok then
        return validated
    end
    return Result.ok(event)
end

function CombatEvent.validate_sequence(events, expected_combat_id, starting_sequence, options)
    if type(events) ~= 'table' or not Ordered.is_dense_array(events) then
        return invalid('events', 'DENSE_ARRAY_REQUIRED')
    end
    local combat_id_check = RuntimeId.validate_component(expected_combat_id, 'expected_combat_id')
    if not combat_id_check.ok then
        return invalid('expected_combat_id', 'ATOMIC_COMBAT_ID_REQUIRED')
    end
    if starting_sequence ~= nil and not TableShape.is_integer(starting_sequence, 1) then
        return invalid('starting_sequence', 'POSITIVE_INTEGER_REQUIRED')
    end
    local expected = starting_sequence or 1
    local index
    for index = 1, #events do
        local event = events[index]
        local validated = CombatEvent.validate(event, options)
        if not validated.ok then
            return validated
        end
        if event.combat_id ~= expected_combat_id or event.sequence ~= expected then
            return invalid('events', 'EVENT_SEQUENCE_GAP', {
                index = index,
                expected_sequence = expected,
            })
        end
        expected = expected + 1
    end
    return Result.ok({ next_sequence = expected })
end

return CombatEvent
