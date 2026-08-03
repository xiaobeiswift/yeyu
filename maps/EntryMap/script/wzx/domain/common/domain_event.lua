local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local Ordered = require 'wzx.domain.common.ordered'

local DomainEvent = {}

local REQUIRED_FIELDS = {
    event_id = true,
    event_type = true,
    schema_version = true,
    aggregate_id = true,
    revision = true,
    payload = true,
}

local OPTIONAL_FIELDS = {
    occurred_at = true,
    causation_id = true,
    correlation_id = true,
    source_system = true,
    source_occurrence_id = true,
}

local function invalid(field, reason, details)
    details = details or {}
    details.field = field
    details.reason = reason
    return Result.err('DOMAIN_EVENT_INVALID', 'error.foundation.domain_event_invalid', false, details)
end

local function validate_identifier(value, field, atomic)
    local checked
    if atomic then
        checked = RuntimeId.validate_component(value, field)
    else
        checked = RuntimeId.validate_derived(value, field)
    end
    if not checked.ok then
        return invalid(field, 'IDENTIFIER_INVALID')
    end
    return nil
end

function DomainEvent.validate(envelope, options)
    options = options or {}
    if type(envelope) ~= 'table' then
        return invalid('event', 'TABLE_REQUIRED')
    end

    local field
    if options.allow_specialized_fields ~= true then
        local keys = Ordered.sorted_string_keys(envelope)
        if not keys.ok then
            return invalid('event', 'NON_STRING_FIELD_KEY')
        end
        local field_index
        for field_index = 1, #keys.value do
            field = keys.value[field_index]
            if not REQUIRED_FIELDS[field] and not OPTIONAL_FIELDS[field] then
                return invalid(field, 'UNKNOWN_FIELD')
            end
        end
    end

    local identifier_fields = {
        { name = 'event_id', atomic = false },
        { name = 'aggregate_id', atomic = false },
        { name = 'causation_id', atomic = false },
        { name = 'correlation_id', atomic = true },
        { name = 'source_occurrence_id', atomic = true },
    }
    local index
    local found
    for index = 1, #identifier_fields do
        field = identifier_fields[index].name
        if envelope[field] ~= nil then
            found = validate_identifier(envelope[field], field, identifier_fields[index].atomic)
            if found ~= nil then
                return found
            end
        elseif REQUIRED_FIELDS[field] then
            return invalid(field, 'FIELD_REQUIRED')
        end
    end

    if type(envelope.event_type) ~= 'string'
        or #envelope.event_type < 1
        or #envelope.event_type > 64
        or envelope.event_type:match('^[A-Z][A-Za-z0-9]*$') == nil
    then
        return invalid('event_type', 'COMPLETED_FACT_NAME_REQUIRED')
    end
    if not TableShape.is_integer(envelope.schema_version, 1) then
        return invalid('schema_version', 'POSITIVE_INTEGER_REQUIRED')
    end
    if not TableShape.is_integer(envelope.revision, 0) then
        return invalid('revision', 'NON_NEGATIVE_INTEGER_REQUIRED')
    end
    if envelope.occurred_at ~= nil and not TableShape.is_integer(envelope.occurred_at, 0) then
        return invalid('occurred_at', 'NON_NEGATIVE_INTEGER_REQUIRED')
    end
    if envelope.source_system ~= nil then
        if type(envelope.source_system) ~= 'string'
            or envelope.source_system:match('^[0-9][0-9]$') == nil
        then
            return invalid('source_system', 'TWO_DIGIT_SYSTEM_ID_REQUIRED')
        end
    end

    if type(envelope.payload) ~= 'table' then
        return invalid('payload', 'TABLE_REQUIRED')
    end
    local payload_check = TableShape.validate_serializable(
        envelope.payload,
        options.payload_maximum_table_depth or 8,
        '$.payload'
    )
    if not payload_check.ok then
        return invalid('payload', 'PAYLOAD_INVALID', {
            cause = payload_check.error,
        })
    end

    if options.registry ~= nil then
        if type(options.registry.validate_payload) ~= 'function' then
            return invalid('event_type', 'EVENT_REGISTRY_INVALID')
        end
        local payload_result = options.registry:validate_payload(
            envelope.event_type,
            envelope.schema_version,
            envelope.payload
        )
        if not payload_result.ok then
            return invalid('payload', 'PAYLOAD_SCHEMA_REJECTED', {
                cause = payload_result.error,
            })
        end
    end

    return Result.ok(envelope)
end

function DomainEvent.copy(envelope, options)
    local validated = DomainEvent.validate(envelope, options)
    if not validated.ok then
        return validated
    end
    return TableShape.deep_copy_serializable(envelope, 10, '$')
end

return DomainEvent
