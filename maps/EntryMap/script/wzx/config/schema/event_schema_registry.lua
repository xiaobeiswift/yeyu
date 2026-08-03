local Result = require 'wzx.domain.common.result'
local ErrorCodes = require 'wzx.domain.common.error_codes'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Ordered = require 'wzx.domain.common.ordered'
local TableShape = require 'wzx.domain.common.table_shape'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'

local EventSchemaRegistry = {}
local EventRegistry = {}
EventRegistry.__index = EventRegistry
EventRegistry.__newindex = function()
    error('event schema registry is read-only', 2)
end
EventRegistry.__metatable = false
local STATES = setmetatable({}, { __mode = 'k' })

local ENVELOPE_KINDS = {
    DOMAIN_EVENT = true,
    COMBAT_EVENT = true,
}

local PERSISTENCE_POLICIES = {
    TRANSIENT = true,
    RECEIPT_REQUIRED = true,
    AUDIT_REQUIRED = true,
}
local VALUE_TYPES = {
    STRING = true,
    INTEGER = true,
    BOOLEAN = true,
    TABLE = true,
    ARRAY = true,
    ENUM = true,
    ID = true,
    HASH = true,
}
local ENTRY_FIELDS = {
    event_type = true,
    producer_system = true,
    schema_version = true,
    envelope_kind = true,
    required_payload_fields = true,
    optional_payload_fields = true,
    payload_schema_hash = true,
    payload_validator = true,
    consumer_systems = true,
    persistence_policy = true,
    deprecated = true,
}
local DESCRIPTOR_FIELDS = {
    name = true,
    value_type = true,
    sensitive = true,
    constraint_id = true,
    default_semantics = true,
}

local function is_positive_integer(value)
    return TableShape.is_integer(value, 1)
end

local function normalize_consumers(consumers)
    if not Ordered.is_dense_array(consumers) then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_consumers_not_ordered_array',
            false
        )
    end

    local normalized = {}
    local previous_system_id = nil
    local index
    for index = 1, #consumers do
        local consumer = consumers[index]
        local system_id
        local minimum_schema_version

        if type(consumer) == 'string' then
            system_id = consumer
            minimum_schema_version = 1
        elseif type(consumer) == 'table' then
            system_id = consumer.system_id
            minimum_schema_version = consumer.minimum_schema_version
        else
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_consumer_invalid',
                false,
                { consumer_index = index }
            )
        end

        if type(system_id) ~= 'string' or system_id:match('^[0-9][0-9]$') == nil then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_consumer_system_invalid',
                false,
                { consumer_index = index }
            )
        end

        if not is_positive_integer(minimum_schema_version) then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_consumer_version_invalid',
                false,
                { consumer_index = index }
            )
        end

        if previous_system_id ~= nil and previous_system_id >= system_id then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_consumers_not_strictly_sorted',
                false,
                {
                    consumer_index = index,
                    previous_system_id = previous_system_id,
                    system_id = system_id,
                }
            )
        end

        normalized[index] = {
            system_id = system_id,
            minimum_schema_version = minimum_schema_version,
        }
        previous_system_id = system_id
    end

    return Result.ok(normalized)
end

local function normalize_entry(entry)
    if type(entry) ~= 'table' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_schema_invalid',
            false
        )
    end

    local entry_keys = Ordered.sorted_string_keys(entry)
    if not entry_keys.ok then
        return entry_keys
    end
    local key
    local key_index
    for key_index = 1, #entry_keys.value do
        key = entry_keys.value[key_index]
        if not ENTRY_FIELDS[key] then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_schema_unknown_field',
                false,
                { field = key }
            )
        end
    end

    local consumers_result = normalize_consumers(entry.consumer_systems)
    if not consumers_result.ok then
        return consumers_result
    end

    local copy = {}
    local key
    local value
    for key, value in pairs(entry) do
        copy[key] = value
    end
    copy.consumer_systems = consumers_result.value
    copy.envelope_kind = entry.envelope_kind or 'DOMAIN_EVENT'
    copy.persistence_policy = entry.persistence_policy or 'TRANSIENT'
    copy.deprecated = entry.deprecated == true

    local registry_key_result = RuntimeId.compose({
        entry.event_type,
        entry.schema_version,
    })
    if not registry_key_result.ok then
        return registry_key_result
    end
    copy.registry_key = registry_key_result.value
    return Result.ok(copy)
end

local function validate_entry(entry)
    if type(entry.event_type) ~= 'string'
        or #entry.event_type > 64
        or entry.event_type:match('^[A-Z][A-Za-z0-9]*$') == nil
    then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_type_invalid',
            false
        )
    end

    if type(entry.producer_system) ~= 'string'
        or entry.producer_system:match('^[0-9][0-9]$') == nil
    then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_producer_system_invalid',
            false,
            { event_type = entry.event_type }
        )
    end

    if not is_positive_integer(entry.schema_version) then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_schema_version_invalid',
            false,
            { event_type = entry.event_type }
        )
    end

    if type(entry.payload_validator) ~= 'function' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_payload_validator_invalid',
            false,
            { event_type = entry.event_type }
        )
    end

    if type(entry.payload_schema_hash) ~= 'string'
        or #entry.payload_schema_hash ~= 64
        or entry.payload_schema_hash:match('^[a-f0-9]+$') == nil
    then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_payload_schema_hash_invalid',
            false,
            { event_type = entry.event_type }
        )
    end

    local seen_payload_fields = {}
    local descriptor_sets = {
        { name = 'required_payload_fields', values = entry.required_payload_fields, optional = false },
        { name = 'optional_payload_fields', values = entry.optional_payload_fields, optional = true },
    }
    local set_index
    for set_index = 1, #descriptor_sets do
        local descriptor_set = descriptor_sets[set_index]
        if not Ordered.is_dense_array(descriptor_set.values) then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_payload_descriptors_invalid',
                false,
                { descriptor_set = descriptor_set.name }
            )
        end
        local previous_name = nil
        local descriptor_index
        for descriptor_index = 1, #descriptor_set.values do
            local descriptor = descriptor_set.values[descriptor_index]
            if type(descriptor) ~= 'table' then
                return Result.err(
                    ErrorCodes.SCHEMA_VALIDATION_FAILED,
                    'error.foundation.event_payload_descriptor_invalid',
                    false,
                    { descriptor_set = descriptor_set.name, descriptor_index = descriptor_index }
                )
            end
            local descriptor_keys = Ordered.sorted_string_keys(descriptor)
            if not descriptor_keys.ok then
                return descriptor_keys
            end
            local field
            local field_index
            for field_index = 1, #descriptor_keys.value do
                field = descriptor_keys.value[field_index]
                if not DESCRIPTOR_FIELDS[field] then
                    return Result.err(
                        ErrorCodes.SCHEMA_VALIDATION_FAILED,
                        'error.foundation.event_payload_descriptor_unknown_field',
                        false,
                        { field = field }
                    )
                end
            end
            if type(descriptor.name) ~= 'string'
                or descriptor.name:match('^[a-z][a-z0-9_]*$') == nil
                or not VALUE_TYPES[descriptor.value_type]
                or type(descriptor.sensitive) ~= 'boolean'
                or (descriptor.constraint_id ~= nil
                    and not RuntimeId.validate_content(
                        descriptor.constraint_id,
                        'constraint_',
                        'constraint_id'
                    ).ok)
                or (descriptor_set.optional
                    and (type(descriptor.default_semantics) ~= 'string'
                        or descriptor.default_semantics == ''))
                or (not descriptor_set.optional and descriptor.default_semantics ~= nil)
            then
                return Result.err(
                    ErrorCodes.SCHEMA_VALIDATION_FAILED,
                    'error.foundation.event_payload_descriptor_invalid',
                    false,
                    { descriptor_set = descriptor_set.name, descriptor_index = descriptor_index }
                )
            end
            if previous_name ~= nil and previous_name >= descriptor.name then
                return Result.err(
                    ErrorCodes.SCHEMA_VALIDATION_FAILED,
                    'error.foundation.event_payload_descriptors_not_sorted',
                    false,
                    { descriptor_set = descriptor_set.name, descriptor_index = descriptor_index }
                )
            end
            if seen_payload_fields[descriptor.name] then
                return Result.err(
                    ErrorCodes.SCHEMA_VALIDATION_FAILED,
                    'error.foundation.event_payload_field_duplicate',
                    false,
                    { field = descriptor.name }
                )
            end
            seen_payload_fields[descriptor.name] = true
            previous_name = descriptor.name
        end
    end

    local consumer_index
    for consumer_index = 1, #entry.consumer_systems do
        if entry.consumer_systems[consumer_index].minimum_schema_version
            > entry.schema_version
        then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_consumer_version_unsupported',
                false,
                {
                    event_type = entry.event_type,
                    consumer_system = entry.consumer_systems[consumer_index].system_id,
                }
            )
        end
    end

    if not ENVELOPE_KINDS[entry.envelope_kind] then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_envelope_kind_invalid',
            false,
            { event_type = entry.event_type }
        )
    end

    if not PERSISTENCE_POLICIES[entry.persistence_policy] then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_persistence_policy_invalid',
            false,
            { event_type = entry.event_type }
        )
    end

    if type(entry.deprecated) ~= 'boolean' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_deprecated_invalid',
            false,
            { event_type = entry.event_type }
        )
    end

    return Result.ok(true)
end

function EventSchemaRegistry.new()
    local generic_result = SchemaRegistry.new({
        registry_name = 'EventSchemaRegistry',
        id_field = 'registry_key',
        validate_entry = validate_entry,
        validate_id = function(value)
            return RuntimeId.validate_derived(value, 'event_schema_registry_key')
        end,
    })
    if not generic_result.ok then
        return generic_result
    end

    local registry = setmetatable({}, EventRegistry)
    STATES[registry] = {
        registry = generic_result.value,
        families = {},
    }
    return Result.ok(registry)
end

function EventRegistry:register(entry)
    local normalized_result = normalize_entry(entry)
    if not normalized_result.ok then
        return normalized_result
    end

    local normalized = normalized_result.value
    local state = STATES[self]
    local family = state.families[normalized.event_type]
    if family ~= nil then
        if family.producer_system ~= normalized.producer_system then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_producer_drift',
                false,
                {
                    event_type = normalized.event_type,
                    expected = family.producer_system,
                    actual = normalized.producer_system,
                }
            )
        end
        if family.envelope_kind ~= normalized.envelope_kind then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.event_envelope_kind_drift',
                false,
                {
                    event_type = normalized.event_type,
                    expected = family.envelope_kind,
                    actual = normalized.envelope_kind,
                }
            )
        end
    end

    local registered = state.registry:register(normalized)
    if not registered.ok then
        return registered
    end

    if family == nil then
        family = {
            producer_system = normalized.producer_system,
            envelope_kind = normalized.envelope_kind,
            latest_version = normalized.schema_version,
        }
        state.families[normalized.event_type] = family
    elseif normalized.schema_version > family.latest_version then
        family.latest_version = normalized.schema_version
    end
    return Result.ok(normalized.registry_key)
end

local function make_registry_key(event_type, schema_version)
    if type(event_type) ~= 'string'
        or #event_type > 64
        or event_type:match('^[A-Z][A-Za-z0-9]*$') == nil
    then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_type_invalid',
            false
        )
    end
    if not is_positive_integer(schema_version) then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_schema_version_invalid',
            false,
            { event_type = event_type }
        )
    end
    return RuntimeId.compose({ event_type, schema_version })
end

local function to_public_entry(entry)
    local public = {}
    local key
    local value
    for key, value in pairs(entry) do
        if key ~= 'registry_key' then
            public[key] = value
        end
    end
    return public
end

function EventRegistry:get(event_type, schema_version)
    local key_result = make_registry_key(event_type, schema_version)
    if not key_result.ok then
        return key_result
    end

    local entry_result = STATES[self].registry:get(key_result.value)
    if not entry_result.ok then
        return entry_result
    end
    return Result.ok(to_public_entry(entry_result.value))
end

function EventRegistry:get_latest(event_type)
    local event_key = make_registry_key(event_type, 1)
    if not event_key.ok then
        return event_key
    end

    local family = STATES[self].families[event_type]
    if family == nil then
        return Result.err(
            ErrorCodes.REGISTRY_ENTRY_NOT_FOUND,
            'error.foundation.event_schema_not_found',
            false,
            { event_type = event_type }
        )
    end
    return self:get(event_type, family.latest_version)
end

function EventRegistry:contains(event_type, schema_version)
    local key_result = make_registry_key(event_type, schema_version)
    if not key_result.ok then
        return false
    end
    return STATES[self].registry:contains(key_result.value)
end

function EventRegistry:list()
    local entries_result = STATES[self].registry:list()
    if not entries_result.ok then
        return entries_result
    end

    local entries = entries_result.value
    table.sort(entries, function(left, right)
        if left.event_type ~= right.event_type then
            return left.event_type < right.event_type
        end
        return left.schema_version < right.schema_version
    end)

    local public = {}
    local index
    for index = 1, #entries do
        public[index] = to_public_entry(entries[index])
    end
    return Result.ok(public)
end

function EventRegistry:seal()
    return STATES[self].registry:seal()
end

function EventRegistry:is_sealed()
    return STATES[self].registry:is_sealed()
end

function EventRegistry:validate_payload(event_type, schema_version, payload)
    local schema_result = self:get(event_type, schema_version)
    if not schema_result.ok then
        return schema_result
    end

    local schema = schema_result.value
    local succeeded, validation_result = pcall(schema.payload_validator, payload)
    if not succeeded then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_payload_validator_failed',
            false,
            { event_type = event_type }
        )
    end
    local contract_result = Result.validate(validation_result)
    if not contract_result.ok then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.event_payload_validator_result_invalid',
            false,
            { event_type = event_type }
        )
    end
    return validation_result
end

return EventSchemaRegistry
