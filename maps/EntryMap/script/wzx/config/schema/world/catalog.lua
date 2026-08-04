local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local WorldErrorCodes = require 'wzx.domain.world.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.world.validation'
local AreaDefinition = require 'wzx.config.schema.world.area_definition'
local LocationDefinition = require 'wzx.config.schema.world.location_definition'
local WorldFlagDefinition = require 'wzx.config.schema.world.world_flag_definition'
local InteractableDefinition = require 'wzx.config.schema.world.interactable_definition'

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
    error_value('world catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'WorldCatalog'
local COLLECTION_ORDER = {
    'flag_definitions',
    'location_definitions',
    'area_definitions',
    'interactable_definitions',
}
local COLLECTION_FIELDS = {
    flag_definitions = true,
    location_definitions = true,
    area_definitions = true,
    interactable_definitions = true,
}
local COLLECTION_SPECS = {
    flag_definitions = {
        registry_name = 'flag_definitions',
        normalize_entry = WorldFlagDefinition.validate,
    },
    location_definitions = {
        registry_name = 'location_definitions',
        normalize_entry = LocationDefinition.validate,
    },
    area_definitions = {
        registry_name = 'area_definitions',
        normalize_entry = AreaDefinition.validate,
    },
    interactable_definitions = {
        registry_name = 'interactable_definitions',
        normalize_entry = InteractableDefinition.validate,
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
        local collection = source[collection_name]
        if collection == nil then
            source[collection_name] = {}
            collection = source[collection_name]
        end
        err = validation_dense_array(SCHEMA, collection_name, collection)
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
    local sealed = registry:seal()
    if not sealed.ok then
        return sealed
    end
    return result_ok(registry)
end

local function validate_cross_references(registries)
    local locations = registries.location_definitions:list()
    if not locations.ok then
        return locations
    end
    local areas = registries.area_definitions:list()
    if not areas.ok then
        return areas
    end

    local index
    for index = 1, #locations.value do
        local location = locations.value[index]
        local area = registries.area_definitions:get(location.area_id)
        if not area.ok then
            return invalid('area_id', 'REFERENCE_NOT_FOUND', {
                location_id = location.id,
                reference_id = location.area_id,
            })
        end
        local neighbor_index
        for neighbor_index = 1, #location.neighbor_location_ids do
            local neighbor_id = location.neighbor_location_ids[neighbor_index]
            local neighbor = registries.location_definitions:get(neighbor_id)
            if not neighbor.ok then
                return invalid('neighbor_location_ids', 'REFERENCE_NOT_FOUND', {
                    location_id = location.id,
                    reference_id = neighbor_id,
                })
            end
        end
    end

    for index = 1, #areas.value do
        local area = areas.value[index]
        local loc_index
        for loc_index = 1, #area.location_ids do
            local location_id = area.location_ids[loc_index]
            local location = registries.location_definitions:get(location_id)
            if not location.ok then
                return invalid('location_ids', 'REFERENCE_NOT_FOUND', {
                    area_id = area.id,
                    reference_id = location_id,
                })
            end
            if location.value.area_id ~= area.id then
                return invalid('area_id', 'LOCATION_AREA_MISMATCH', {
                    area_id = area.id,
                    location_id = location_id,
                    location_area_id = location.value.area_id,
                })
            end
            if location.value.rules_version ~= area.rules_version then
                return invalid('rules_version', 'LOCATION_RULES_MISMATCH', {
                    area_id = area.id,
                    location_id = location_id,
                })
            end
        end
    end

    local interactables = registries.interactable_definitions:list()
    if not interactables.ok then
        return interactables
    end
    for index = 1, #interactables.value do
        local interactable = interactables.value[index]
        local location = registries.location_definitions:get(interactable.location_id)
        if not location.ok then
            return invalid('location_id', 'REFERENCE_NOT_FOUND', {
                interactable_id = interactable.id,
                reference_id = interactable.location_id,
            })
        end
        if interactable.flag_id ~= nil then
            local flag = registries.flag_definitions:get(interactable.flag_id)
            if not flag.ok then
                return invalid('flag_id', 'REFERENCE_NOT_FOUND', {
                    interactable_id = interactable.id,
                    reference_id = interactable.flag_id,
                })
            end
        end
    end

    return result_ok(true)
end

function CatalogView:require_area(area_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'error.world.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(area_id, 'area_', 'area_id')
    if not checked.ok then
        return catalog_error(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'error.world.area_id_invalid',
            'AREA_ID_INVALID',
            { field = 'area_id' }
        )
    end
    local found = state.registries.area_definitions:get(area_id)
    if not found.ok then
        return catalog_error(
            WorldErrorCodes.WORLD_AREA_UNKNOWN,
            'error.world.area_unknown',
            'AREA_UNKNOWN',
            { area_id = area_id }
        )
    end
    if found.value.deprecated then
        return catalog_error(
            WorldErrorCodes.WORLD_DEPRECATED,
            'error.world.deprecated',
            'AREA_DEPRECATED',
            { area_id = area_id }
        )
    end
    return found
end

function CatalogView:require_location(location_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'error.world.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(location_id, 'location_', 'location_id')
    if not checked.ok then
        return catalog_error(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'error.world.location_id_invalid',
            'LOCATION_ID_INVALID',
            { field = 'location_id' }
        )
    end
    local found = state.registries.location_definitions:get(location_id)
    if not found.ok then
        return catalog_error(
            WorldErrorCodes.WORLD_LOCATION_UNKNOWN,
            'error.world.location_unknown',
            'LOCATION_UNKNOWN',
            { location_id = location_id }
        )
    end
    if found.value.deprecated then
        return catalog_error(
            WorldErrorCodes.WORLD_DEPRECATED,
            'error.world.deprecated',
            'LOCATION_DEPRECATED',
            { location_id = location_id }
        )
    end
    return found
end

function CatalogView:require_flag(flag_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'error.world.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(flag_id, 'flag_', 'flag_id')
    if not checked.ok then
        return catalog_error(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'error.world.flag_id_invalid',
            'FLAG_ID_INVALID',
            { field = 'flag_id' }
        )
    end
    local found = state.registries.flag_definitions:get(flag_id)
    if not found.ok then
        return catalog_error(
            WorldErrorCodes.WORLD_FLAG_UNKNOWN,
            'error.world.flag_unknown',
            'FLAG_UNKNOWN',
            { flag_id = flag_id }
        )
    end
    if found.value.deprecated then
        return catalog_error(
            WorldErrorCodes.WORLD_DEPRECATED,
            'error.world.deprecated',
            'FLAG_DEPRECATED',
            { flag_id = flag_id }
        )
    end
    return found
end

function CatalogView:require_interactable(interactable_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'error.world.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(interactable_id, 'interact_', 'interactable_id')
    if not checked.ok then
        return catalog_error(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'error.world.interactable_id_invalid',
            'INTERACTABLE_ID_INVALID',
            { field = 'interactable_id' }
        )
    end
    local found = state.registries.interactable_definitions:get(interactable_id)
    if not found.ok then
        return catalog_error(
            WorldErrorCodes.WORLD_INTERACTABLE_UNKNOWN,
            'error.world.interactable_unknown',
            'INTERACTABLE_UNKNOWN',
            { interactable_id = interactable_id }
        )
    end
    if found.value.deprecated then
        return catalog_error(
            WorldErrorCodes.WORLD_DEPRECATED,
            'error.world.deprecated',
            'INTERACTABLE_DEPRECATED',
            { interactable_id = interactable_id }
        )
    end
    return found
end

function Catalog.seal(source)
    local validated = validate_source(source)
    if not validated.ok then
        return validated
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

    local cross = validate_cross_references(registries)
    if not cross.ok then
        return cross
    end

    local view = set_metatable({}, CatalogView)
    STATES[view] = {
        registries = registries,
    }
    return result_ok(view)
end

return Catalog
