local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local InventoryErrorCodes = require 'wzx.domain.inventory.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.inventory.validation'
local ItemDefinition = require 'wzx.config.schema.inventory.item_definition'

local Catalog = {}
local error_value = error
local get_metatable = getmetatable
local result_err = Result.err
local result_ok = Result.ok
local schema_registry_new = SchemaRegistry.new
local set_metatable = setmetatable
local type_value = type
local validation_dense_array = Validation.dense_array
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local CatalogView = {}
CatalogView.__index = CatalogView
CatalogView.__newindex = function()
    error_value('item catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'ItemCatalog'
local COLLECTION_FIELDS = {
    item_definitions = true,
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
    err = validation_dense_array(
        SCHEMA,
        'item_definitions',
        source.item_definitions
    )
    if err ~= nil then
        return err
    end
    return result_ok(true)
end

local function build_registry(entries)
    local created = schema_registry_new({
        registry_name = 'item_definitions',
        id_field = 'id',
        normalize_entry = ItemDefinition.validate,
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
    local built = build_registry(source.item_definitions)
    if not built.ok then
        return built
    end
    local sealed = built.value:seal()
    if not sealed.ok then
        return sealed
    end
    local view = set_metatable({}, CatalogView)
    STATES[view] = { registry = built.value }
    return result_ok(view)
end

function Catalog.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

function CatalogView:get(item_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            InventoryErrorCodes.INVENTORY_ARGUMENT_INVALID,
            'error.inventory.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.registry:get(item_id)
end

function CatalogView:require(item_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            InventoryErrorCodes.INVENTORY_ARGUMENT_INVALID,
            'error.inventory.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = RuntimeId.validate_content(item_id, 'item_', 'item_id')
    if not checked.ok then
        return catalog_error(
            InventoryErrorCodes.INVENTORY_ARGUMENT_INVALID,
            'error.inventory.item_id_invalid',
            'ITEM_ID_INVALID',
            { field = 'item_id' }
        )
    end
    local found = state.registry:get(item_id)
    if not found.ok then
        return catalog_error(
            InventoryErrorCodes.INVENTORY_ITEM_UNKNOWN,
            'error.inventory.item_unknown',
            'ITEM_UNKNOWN',
            { item_id = item_id }
        )
    end
    return found
end

function CatalogView:contains(item_id)
    local found = self:get(item_id)
    return found.ok == true
end

return Catalog
