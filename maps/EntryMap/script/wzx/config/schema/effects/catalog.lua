local ErrorCodes = require 'wzx.domain.common.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local EffectErrorCodes = require 'wzx.domain.effects.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.effects.validation'
local EffectBundle = require 'wzx.config.schema.effects.effect_bundle'
local StatusDefinition = require 'wzx.config.schema.effects.status_definition'
local StatusTrigger = require 'wzx.config.schema.effects.status_trigger'

local Catalog = {}
local error_value = error
local get_metatable = getmetatable
local result_err = Result.err
local result_ok = Result.ok
local schema_registry_new = SchemaRegistry.new
local set_metatable = setmetatable
local type_value = type
local validate_content_id = RuntimeId.validate_content
local validation_dense_array = Validation.dense_array
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local CatalogView = {}
CatalogView.__index = CatalogView
CatalogView.__newindex = function()
    error_value('effect catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'EffectCatalog'
local COLLECTION_ORDER = {
    'status_definitions',
    'effect_bundles',
    'status_triggers',
}
local COLLECTION_FIELDS = {
    status_definitions = true,
    effect_bundles = true,
    status_triggers = true,
}
local COLLECTION_SPECS = {
    status_definitions = {
        registry_name = 'status_definitions',
        normalize_entry = StatusDefinition.validate,
    },
    effect_bundles = {
        registry_name = 'effect_bundles',
        normalize_entry = EffectBundle.validate,
    },
    status_triggers = {
        registry_name = 'status_triggers',
        normalize_entry = StatusTrigger.validate,
    },
}

local function invalid(field, reason, details)
    return validation_invalid(SCHEMA, field, reason, details)
end

local function catalog_error(code, message_key, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(code, message_key, false, details)
end

local function validate_source(source)
    if type_value(source) ~= 'table' or get_metatable(source) ~= nil then
        return invalid('$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, source, COLLECTION_FIELDS)
    if err ~= nil then
        return err
    end
    local index
    for index = 1, #COLLECTION_ORDER do
        local collection_name = COLLECTION_ORDER[index]
        err = validation_dense_array(SCHEMA, collection_name, source[collection_name])
        if err ~= nil then
            return err
        end
    end
    return result_ok(true)
end

local function build_registry(collection_name, entries)
    local spec = COLLECTION_SPECS[collection_name]
    local created = schema_registry_new({
        registry_name = spec.registry_name,
        id_field = 'id',
        normalize_entry = spec.normalize_entry,
    })
    if not created.ok then
        return created
    end
    local registry = created.value
    local index
    for index = 1, #entries do
        local registered = registry:register(entries[index])
        if not registered.ok then
            return registered
        end
    end
    return result_ok(registry)
end

local function has_tag(tags, expected)
    local index
    for index = 1, #tags do
        if tags[index] == expected then
            return true
        end
    end
    return false
end

local function validate_cross_references(registries)
    local statuses = registries.status_definitions:list()
    if not statuses.ok then
        return statuses
    end
    local bundles = registries.effect_bundles:list()
    if not bundles.ok then
        return bundles
    end
    local triggers = registries.status_triggers:list()
    if not triggers.ok then
        return triggers
    end

    local status_by_id = {}
    local status_index
    for status_index = 1, #statuses.value do
        local status = statuses.value[status_index]
        status_by_id[status.id] = status
    end

    local bundle_index
    for bundle_index = 1, #bundles.value do
        local bundle = bundles.value[bundle_index]
        local node_index
        for node_index = 1, #bundle.nodes do
            local node = bundle.nodes[node_index]
            if node.operation == 'REVIVE' then
                return catalog_error(
                    EffectErrorCodes.EFFECT_GRAPH_INVALID,
                    'error.effects.graph_invalid',
                    'REVIVE_DISABLED_UNTIL_CONFIGURED',
                    {
                        bundle_id = bundle.id,
                        node_id = node.node_id,
                    }
                )
            end
            if node.status_id ~= nil then
                local status = status_by_id[node.status_id]
                if status == nil then
                    return invalid('nodes.status_id', 'REFERENCE_NOT_FOUND', {
                        bundle_id = bundle.id,
                        node_id = node.node_id,
                        reference_id = node.status_id,
                    })
                end
                if status.deprecated and not bundle.deprecated then
                    return invalid('nodes.status_id', 'DEPRECATED_STATUS_REFERENCE', {
                        bundle_id = bundle.id,
                        status_id = node.status_id,
                    })
                end
                if node.operation == 'ADD_SHIELD' and not has_tag(status.tags, 'SHIELD') then
                    return invalid('nodes.status_id', 'SHIELD_STATUS_REQUIRED', {
                        bundle_id = bundle.id,
                        status_id = node.status_id,
                    })
                end
                if node.duration_override ~= nil then
                    if status.duration_unit == 'UNTIL_COMBAT_END' then
                        return invalid(
                            'nodes.duration_override',
                            'DURATION_OVERRIDE_FORBIDDEN',
                            {
                                bundle_id = bundle.id,
                                status_id = node.status_id,
                            }
                        )
                    end
                    if node.duration_override > status.max_duration then
                        return invalid(
                            'nodes.duration_override',
                            'DURATION_OVERRIDE_EXCEEDS_MAX',
                            {
                                bundle_id = bundle.id,
                                status_id = node.status_id,
                            }
                        )
                    end
                end
            end
        end
    end

    local trigger_index
    for trigger_index = 1, #triggers.value do
        local trigger = triggers.value[trigger_index]
        if status_by_id[trigger.status_id] == nil then
            return invalid('status_id', 'REFERENCE_NOT_FOUND', {
                trigger_id = trigger.id,
                reference_id = trigger.status_id,
            })
        end
        if not registries.effect_bundles:contains(trigger.effect_bundle_id) then
            return invalid('effect_bundle_id', 'REFERENCE_NOT_FOUND', {
                trigger_id = trigger.id,
                reference_id = trigger.effect_bundle_id,
            })
        end
    end

    return result_ok(true)
end

function Catalog.build(source)
    local checked = validate_source(source)
    if not checked.ok then
        return checked
    end

    local registries = {}
    local index
    for index = 1, #COLLECTION_ORDER do
        local collection_name = COLLECTION_ORDER[index]
        local built = build_registry(collection_name, source[collection_name])
        if not built.ok then
            return built
        end
        registries[collection_name] = built.value
    end

    local graph = validate_cross_references(registries)
    if not graph.ok then
        return graph
    end

    for index = 1, #COLLECTION_ORDER do
        local sealed = registries[COLLECTION_ORDER[index]]:seal()
        if not sealed.ok then
            return sealed
        end
    end

    local view = set_metatable({}, CatalogView)
    STATES[view] = { registries = registries }
    return result_ok(view)
end

local function resolve_registry(self, collection_name)
    local state = STATES[self]
    if state == nil or type_value(collection_name) ~= 'string' then
        return nil
    end
    return state.registries[collection_name]
end

function CatalogView:get(collection_name, entry_id)
    local registry = resolve_registry(self, collection_name)
    if registry == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.effects.catalog_collection_invalid',
            'COLLECTION_INVALID',
            { collection_name = collection_name }
        )
    end
    return registry:get(entry_id)
end

function CatalogView:list(collection_name)
    local registry = resolve_registry(self, collection_name)
    if registry == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.effects.catalog_collection_invalid',
            'COLLECTION_INVALID',
            { collection_name = collection_name }
        )
    end
    return registry:list()
end

function CatalogView:contains(collection_name, entry_id)
    local registry = resolve_registry(self, collection_name)
    if registry == nil then
        return false
    end
    return registry:contains(entry_id)
end

function CatalogView:require_status(status_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EffectErrorCodes.EFFECT_ARGUMENT_INVALID,
            'error.effects.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(status_id, 'status_', 'status_id')
    if not checked.ok then
        return catalog_error(
            EffectErrorCodes.EFFECT_ARGUMENT_INVALID,
            'error.effects.status_id_invalid',
            'STATUS_ID_INVALID',
            { field = 'status_id' }
        )
    end
    local got = state.registries.status_definitions:get(status_id)
    if not got.ok then
        return catalog_error(
            EffectErrorCodes.EFFECT_CONFIG_MISSING,
            'error.effects.config_missing',
            'STATUS_NOT_FOUND',
            { status_id = status_id }
        )
    end
    return got
end

function CatalogView:require_bundle(bundle_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EffectErrorCodes.EFFECT_ARGUMENT_INVALID,
            'error.effects.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(bundle_id, 'effect_', 'bundle_id')
    if not checked.ok then
        return catalog_error(
            EffectErrorCodes.EFFECT_ARGUMENT_INVALID,
            'error.effects.bundle_id_invalid',
            'BUNDLE_ID_INVALID',
            { field = 'bundle_id' }
        )
    end
    local got = state.registries.effect_bundles:get(bundle_id)
    if not got.ok then
        return catalog_error(
            EffectErrorCodes.EFFECT_CONFIG_MISSING,
            'error.effects.config_missing',
            'BUNDLE_NOT_FOUND',
            { bundle_id = bundle_id }
        )
    end
    return got
end

function CatalogView:list_triggers_for_status(status_id)
    local listed = self:list('status_triggers')
    if not listed.ok then
        return listed
    end
    local rows = {}
    local index
    for index = 1, #listed.value do
        local trigger = listed.value[index]
        if trigger.status_id == status_id and not trigger.deprecated then
            rows[#rows + 1] = trigger
        end
    end
    return result_ok(rows)
end

function Catalog.is_authority(catalog)
    return STATES[catalog] ~= nil
end

return Catalog
