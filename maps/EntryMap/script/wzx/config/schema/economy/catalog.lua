local ErrorCodes = require 'wzx.domain.common.error_codes'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.economy.validation'
local CurrencyDefinition = require 'wzx.config.schema.economy.currency_definition'

local Catalog = {}
local error_value = error
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local raw_get = rawget
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
    error_value('currency catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'CurrencyCatalog'
local COLLECTION_ORDER = {
    'currency_definitions',
}
local COLLECTION_FIELDS = {
    currency_definitions = true,
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
    local err = validation_no_unknown_fields(SCHEMA, source, COLLECTION_FIELDS)
    if err ~= nil then
        return err
    end

    local index
    for index = 1, #COLLECTION_ORDER do
        local collection_name = COLLECTION_ORDER[index]
        err = validation_dense_array(
            SCHEMA,
            collection_name,
            source[collection_name]
        )
        if err ~= nil then
            return err
        end
    end
    return result_ok(true)
end

local function build_registry(entries)
    local created = schema_registry_new({
        registry_name = 'currency_definitions',
        id_field = 'id',
        normalize_entry = CurrencyDefinition.validate,
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

function Catalog.build(source)
    if type_value(source) ~= 'table' or get_metatable(source) ~= nil then
        return invalid('$', 'TABLE_REQUIRED')
    end

    local checked = validate_source(source)
    if not checked.ok then
        return checked
    end

    local built = build_registry(source.currency_definitions)
    if not built.ok then
        return built
    end
    local registry = built.value

    local sealed = registry:seal()
    if not sealed.ok then
        return sealed
    end

    local view = set_metatable({}, CatalogView)
    STATES[view] = { registry = registry }
    return result_ok(view)
end

function Catalog.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

local function resolve_state(self)
    return STATES[self]
end

function CatalogView:get(currency_id)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.economy.catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.registry:get(currency_id)
end

function CatalogView:list()
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.economy.catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.registry:list()
end

function CatalogView:contains(currency_id)
    local state = resolve_state(self)
    if state == nil then
        return false
    end
    return state.registry:contains(currency_id)
end

function CatalogView:require(currency_id)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.economy.catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end

    local checked = validate_content_id(currency_id, 'currency_', 'currency_id')
    if not checked.ok then
        return catalog_error(
            EconomyErrorCodes.ECONOMY_ARGUMENT_INVALID,
            'error.economy.argument_invalid',
            'CURRENCY_ID_INVALID',
            { field = 'currency_id' }
        )
    end

    local found = state.registry:get(currency_id)
    if not found.ok then
        return catalog_error(
            EconomyErrorCodes.ECONOMY_CURRENCY_UNKNOWN,
            'error.economy.currency_unknown',
            'CURRENCY_NOT_FOUND',
            { currency_id = currency_id }
        )
    end
    return found
end

return Catalog
