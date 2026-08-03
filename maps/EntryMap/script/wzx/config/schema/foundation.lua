local Result = require 'wzx.domain.common.result'
local EventSchemaRegistry = require 'wzx.config.schema.event_schema_registry'
local Ordered = require 'wzx.domain.common.ordered'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local FoundationSections = require 'wzx.config.schema.sections.foundation'
local Versions = require 'wzx.config.schema.versions'

local Foundation = {}

local function owner_mismatch(kind, system_id, declared_system_id)
    return Result.err(
        'SCHEMA_VALIDATION_FAILED',
        'error.foundation.registrar_owner_mismatch',
        false,
        {
            declaration_kind = kind,
            registrar_system_id = system_id,
            declared_system_id = declared_system_id,
        }
    )
end

local function make_event_facade(registry, system_id)
    local facade = {}

    function facade:register(entry)
        if type(entry) ~= 'table' or entry.producer_system ~= system_id then
            return owner_mismatch(
                'EVENT_PRODUCER',
                system_id,
                type(entry) == 'table' and entry.producer_system or nil
            )
        end
        return registry:register(entry)
    end

    function facade:get(event_type, schema_version)
        return registry:get(event_type, schema_version)
    end

    function facade:get_latest(event_type)
        return registry:get_latest(event_type)
    end

    function facade:contains(event_type, schema_version)
        return registry:contains(event_type, schema_version)
    end

    function facade:list()
        return registry:list()
    end

    function facade:validate_payload(event_type, schema_version, payload)
        return registry:validate_payload(event_type, schema_version, payload)
    end

    function facade:is_sealed()
        return registry:is_sealed()
    end

    return facade
end

local function make_section_facade(registry, system_id)
    local facade = {}

    function facade:register(entry)
        if type(entry) ~= 'table' or entry.owner_system ~= system_id then
            return owner_mismatch(
                'SECTION_OWNER',
                system_id,
                type(entry) == 'table' and entry.owner_system or nil
            )
        end
        return registry:register(entry)
    end

    function facade:get(section_key)
        return registry:get(section_key)
    end

    function facade:find_by_path(slot_id, section_path)
        return registry:find_by_path(slot_id, section_path)
    end

    function facade:authorize_write(owner_system, slot_id, section_path)
        return registry:authorize_write(owner_system, slot_id, section_path)
    end

    function facade:list()
        return registry:list()
    end

    function facade:is_sealed()
        return registry:is_sealed()
    end

    return facade
end

local function make_versions_view()
    return setmetatable({}, {
        __index = Versions,
        __newindex = function()
            error('foundation versions are read-only')
        end,
        __metatable = false,
    })
end

local function make_registrar_context(context, system_id)
    return {
        event_schemas = make_event_facade(context.event_schemas, system_id),
        section_owners = make_section_facade(context.section_owners, system_id),
        versions = make_versions_view(),
        system_id = system_id,
    }
end

local function run_registrars(registrars, context)
    if not Ordered.is_dense_array(registrars) then
        return Result.err('SCHEMA_VALIDATION_FAILED', 'error.foundation.registrars_not_ordered_array', false)
    end
    local previous_system_id = nil
    local index
    for index = 1, #registrars do
        local registrar = registrars[index]
        if type(registrar) ~= 'table' or type(registrar.register) ~= 'function' then
            return Result.err('SCHEMA_VALIDATION_FAILED', 'error.foundation.registrar_invalid', false, {
                registrar_index = index,
            })
        end
        if type(registrar.system_id) ~= 'string'
            or registrar.system_id:match('^[0-9][0-9]$') == nil
        then
            return Result.err('SCHEMA_VALIDATION_FAILED', 'error.foundation.registrar_system_id_invalid', false, {
                registrar_index = index,
            })
        end
        if previous_system_id ~= nil and previous_system_id >= registrar.system_id then
            return Result.err('SCHEMA_VALIDATION_FAILED', 'error.foundation.registrars_not_sorted', false, {
                registrar_index = index,
            })
        end
        local registrar_context = make_registrar_context(context, registrar.system_id)
        local succeeded, registered = pcall(registrar.register, registrar_context)
        if not succeeded then
            return Result.err('SCHEMA_VALIDATION_FAILED', 'error.foundation.registrar_failed', false, {
                registrar_index = index,
                system_id = registrar.system_id,
            })
        end
        local result_contract = Result.validate(registered)
        if not result_contract.ok then
            return Result.err('SCHEMA_VALIDATION_FAILED', 'error.foundation.registrar_result_invalid', false, {
                registrar_index = index,
                system_id = registrar.system_id,
            })
        end
        if not registered.ok then
            return registered
        end
        previous_system_id = registrar.system_id
    end
    return Result.ok(#registrars)
end

function Foundation.create(options)
    if options == nil then
        options = {}
    elseif type(options) ~= 'table' then
        return Result.err(
            'SCHEMA_VALIDATION_FAILED',
            'error.foundation.options_invalid',
            false
        )
    end
    local events_result = EventSchemaRegistry.new()
    if not events_result.ok then
        return events_result
    end

    local sections_result = SectionOwnerRegistry.new()
    if not sections_result.ok then
        return sections_result
    end

    local sections_registered = FoundationSections.register_into(sections_result.value)
    if not sections_registered.ok then
        return sections_registered
    end

    local registrar_context = {
        event_schemas = events_result.value,
        section_owners = sections_result.value,
        versions = Versions,
    }
    local registrars_result = run_registrars(options.registrars or {}, registrar_context)
    if not registrars_result.ok then
        return registrars_result
    end

    local events_sealed = events_result.value:seal()
    if not events_sealed.ok then
        return events_sealed
    end

    local sections_sealed = sections_result.value:seal()
    if not sections_sealed.ok then
        return sections_sealed
    end

    return Result.ok({
        event_schemas = events_result.value,
        section_owners = sections_result.value,
        versions = make_versions_view(),
        registrar_count = registrars_result.value,
    })
end

return Foundation
