-- Sealed offline TraversalCatalog for system 26.
-- Grid/Cell/Link shape mirrors the 12 TraversalSpacePort snapshot;
-- rules and water zones are owned by 26.

local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TraversalErrorCodes = require 'wzx.domain.traversal.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.traversal.validation'
local CellDefinition = require 'wzx.config.schema.traversal.cell_definition'
local LinkDefinition = require 'wzx.config.schema.traversal.link_definition'
local RuleDefinition = require 'wzx.config.schema.traversal.rule_definition'
local WaterZoneDefinition = require 'wzx.config.schema.traversal.water_zone_definition'

local Catalog = {}
local error_value = error
local get_metatable = getmetatable
local math_floor = math.floor
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
    error_value('traversal catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'TraversalCatalog'
local COLLECTION_ORDER = {
    'cell_definitions',
    'link_definitions',
    'rule_definitions',
    'water_zone_definitions',
}
local COLLECTION_FIELDS = {
    cell_definitions = true,
    link_definitions = true,
    rule_definitions = true,
    water_zone_definitions = true,
    spatial_revision = true,
    grid_id = true,
}
local COLLECTION_SPECS = {
    cell_definitions = {
        registry_name = 'traversal_cell_definitions',
        normalize_entry = CellDefinition.validate,
    },
    link_definitions = {
        registry_name = 'traversal_link_definitions',
        normalize_entry = LinkDefinition.validate,
    },
    rule_definitions = {
        registry_name = 'traversal_rule_definitions',
        normalize_entry = RuleDefinition.validate,
    },
    water_zone_definitions = {
        registry_name = 'water_zone_definitions',
        normalize_entry = WaterZoneDefinition.validate,
    },
}

local function invalid(field, reason, details)
    return validation_invalid(SCHEMA, field, reason, details)
end

local function catalog_error(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.traversal.' .. string.lower(code),
        false,
        details
    )
end

local function validate_source(source)
    if type_value(source) ~= 'table' or get_metatable(source) ~= nil then
        return invalid('$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, source, COLLECTION_FIELDS)
    if err ~= nil then
        return err
    end
    if source.spatial_revision == nil then
        source.spatial_revision = 1
    end
    if type_value(source.spatial_revision) ~= 'number'
        or source.spatial_revision ~= math_floor(source.spatial_revision)
        or source.spatial_revision < 0
    then
        return invalid('spatial_revision', 'INTEGER_OUT_OF_RANGE')
    end
    if source.grid_id == nil then
        source.grid_id = 'traversal_grid_default'
    end
    local grid_check = validate_content_id(source.grid_id, 'traversal_grid_', 'grid_id')
    if not grid_check.ok then
        return invalid('grid_id', 'CONTENT_ID_INVALID')
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
            return catalog_error(
                TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                'ENTRY_REGISTER_FAILED',
                {
                    collection = collection_name,
                    index = index,
                    cause_code = registered.error and registered.error.code or 'UNKNOWN',
                    cause_details = registered.error and registered.error.details or nil,
                }
            )
        end
    end
    local sealed = registry:seal()
    if not sealed.ok then
        return sealed
    end
    return result_ok(registry)
end

local function require_id(registry, id, code, prefix, field)
    local checked = validate_content_id(id, prefix, field)
    if not checked.ok then
        return catalog_error(
            TraversalErrorCodes.TRAVERSAL_ARGUMENT_INVALID,
            'ID_INVALID',
            { field = field }
        )
    end
    local found = registry:get(id)
    if not found.ok then
        return catalog_error(
            code,
            'NOT_FOUND',
            { id = id, field = field }
        )
    end
    return result_ok(found.value)
end

local function cross_validate(state)
    local cells_list = state.registries.cell_definitions:list()
    if not cells_list.ok then
        return cells_list
    end
    local links_list = state.registries.link_definitions:list()
    if not links_list.ok then
        return links_list
    end
    local zones_list = state.registries.water_zone_definitions:list()
    if not zones_list.ok then
        return zones_list
    end

    local index
    for index = 1, #cells_list.value do
        local cell = cells_list.value[index]
        if cell.grid_id ~= state.grid_id then
            return catalog_error(
                TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                'CELL_GRID_MISMATCH',
                { cell_id = cell.id }
            )
        end
    end

    local blocked_pairs = {}
    for index = 1, #links_list.value do
        local link = links_list.value[index]
        if link.grid_id ~= state.grid_id then
            return catalog_error(
                TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                'LINK_GRID_MISMATCH',
                { link_id = link.id }
            )
        end
        local from_cell = state.registries.cell_definitions:get(link.from_cell_id)
        local to_cell = state.registries.cell_definitions:get(link.to_cell_id)
        if not from_cell.ok then
            return catalog_error(
                TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                'LINK_FROM_MISSING',
                { link_id = link.id, from_cell_id = link.from_cell_id }
            )
        end
        if not to_cell.ok then
            return catalog_error(
                TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                'LINK_TO_MISSING',
                { link_id = link.id, to_cell_id = link.to_cell_id }
            )
        end
        from_cell = from_cell.value
        to_cell = to_cell.value
        if link.link_type == 'BLOCK' then
            blocked_pairs[link.from_cell_id .. '->' .. link.to_cell_id] = true
        elseif link.link_type == 'JUMP_DIRECT' then
            if from_cell.surface_type ~= 'GROUND' or to_cell.surface_type ~= 'GROUND' then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'JUMP_SURFACES_INVALID',
                    { link_id = link.id }
                )
            end
        elseif link.link_type == 'WATER_ENTER' then
            if from_cell.surface_type ~= 'GROUND' or to_cell.surface_type ~= 'WATER' then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'WATER_ENTER_SURFACES_INVALID',
                    { link_id = link.id }
                )
            end
        elseif link.link_type == 'WATER_STEP' then
            if from_cell.surface_type ~= 'WATER' or to_cell.surface_type ~= 'WATER' then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'WATER_STEP_SURFACES_INVALID',
                    { link_id = link.id }
                )
            end
        elseif link.link_type == 'WATER_EXIT' then
            if from_cell.surface_type ~= 'WATER' or to_cell.surface_type ~= 'GROUND' then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'WATER_EXIT_SURFACES_INVALID',
                    { link_id = link.id }
                )
            end
            if to_cell.landing_safety ~= 'SAFE_GROUND' then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'WATER_EXIT_UNSAFE',
                    { link_id = link.id }
                )
            end
        end
    end

    for index = 1, #links_list.value do
        local link = links_list.value[index]
        if link.link_type ~= 'BLOCK' then
            local pair = link.from_cell_id .. '->' .. link.to_cell_id
            if blocked_pairs[pair] then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'LINK_BLOCKED_BY_BLOCK_EDGE',
                    { link_id = link.id }
                )
            end
        end
    end

    for index = 1, #zones_list.value do
        local zone = zones_list.value[index]
        if zone.grid_id ~= state.grid_id then
            return catalog_error(
                TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                'ZONE_GRID_MISMATCH',
                { water_zone_id = zone.id }
            )
        end
        local cell_set = {}
        local cell_index
        for cell_index = 1, #zone.cell_ids do
            local cell_id = zone.cell_ids[cell_index]
            local cell = state.registries.cell_definitions:get(cell_id)
            if not cell.ok or cell.value.surface_type ~= 'WATER' then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'ZONE_CELL_INVALID',
                    { water_zone_id = zone.id, cell_id = cell_id }
                )
            end
            cell_set[cell_id] = true
        end
        local link_index
        for link_index = 1, #zone.entry_link_ids do
            local link = state.registries.link_definitions:get(zone.entry_link_ids[link_index])
            if not link.ok
                or link.value.link_type ~= 'WATER_ENTER'
                or link.value.water_zone_id ~= zone.id
            then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'ZONE_ENTRY_LINK_INVALID',
                    {
                        water_zone_id = zone.id,
                        link_id = zone.entry_link_ids[link_index],
                    }
                )
            end
            if not cell_set[link.value.to_cell_id] then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'ZONE_ENTRY_TARGET_OUTSIDE',
                    { water_zone_id = zone.id, link_id = link.value.id }
                )
            end
        end
        for link_index = 1, #zone.exit_link_ids do
            local link = state.registries.link_definitions:get(zone.exit_link_ids[link_index])
            if not link.ok
                or link.value.link_type ~= 'WATER_EXIT'
                or link.value.water_zone_id ~= zone.id
            then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'ZONE_EXIT_LINK_INVALID',
                    {
                        water_zone_id = zone.id,
                        link_id = zone.exit_link_ids[link_index],
                    }
                )
            end
            if not cell_set[link.value.from_cell_id] then
                return catalog_error(
                    TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN,
                    'ZONE_EXIT_SOURCE_OUTSIDE',
                    { water_zone_id = zone.id, link_id = link.value.id }
                )
            end
        end
    end

    return result_ok(true)
end

local function build_outgoing_index(state)
    local outgoing = {}
    local links_list = state.registries.link_definitions:list()
    local index
    for index = 1, #links_list.value do
        local link = links_list.value[index]
        if link.link_type ~= 'BLOCK' then
            local bucket = outgoing[link.from_cell_id]
            if bucket == nil then
                bucket = {}
                outgoing[link.from_cell_id] = bucket
            end
            bucket[#bucket + 1] = link
        end
    end
    return outgoing
end

function Catalog.seal(source)
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

    local state = {
        registries = registries,
        spatial_revision = source.spatial_revision,
        grid_id = source.grid_id,
    }
    local cross = cross_validate(state)
    if not cross.ok then
        return cross
    end
    state.outgoing = build_outgoing_index(state)

    local view = set_metatable({}, CatalogView)
    STATES[view] = state
    return result_ok(view)
end

function Catalog.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

function CatalogView:spatial_revision()
    local state = STATES[self]
    return state.spatial_revision
end

function CatalogView:grid_id()
    local state = STATES[self]
    return state.grid_id
end

function CatalogView:require_cell(cell_id)
    local state = STATES[self]
    return require_id(
        state.registries.cell_definitions,
        cell_id,
        TraversalErrorCodes.TRAVERSAL_CONFIG_MISSING,
        'traversal_cell_',
        'cell_id'
    )
end

function CatalogView:require_link(link_id)
    local state = STATES[self]
    return require_id(
        state.registries.link_definitions,
        link_id,
        TraversalErrorCodes.TRAVERSAL_CONFIG_MISSING,
        'traversal_link_',
        'link_id'
    )
end

function CatalogView:require_rule(rule_id)
    local state = STATES[self]
    return require_id(
        state.registries.rule_definitions,
        rule_id,
        TraversalErrorCodes.TRAVERSAL_CONFIG_MISSING,
        'traversal_rule_',
        'rule_id'
    )
end

function CatalogView:require_water_zone(zone_id)
    local state = STATES[self]
    return require_id(
        state.registries.water_zone_definitions,
        zone_id,
        TraversalErrorCodes.TRAVERSAL_CONFIG_MISSING,
        'water_zone_',
        'water_zone_id'
    )
end

function CatalogView:outgoing_links(cell_id)
    local state = STATES[self]
    local bucket = state.outgoing[cell_id]
    if bucket == nil then
        return result_ok({})
    end
    local copy = {}
    local index
    for index = 1, #bucket do
        copy[index] = bucket[index]
    end
    return result_ok(copy)
end

function CatalogView:list_water_zones()
    local state = STATES[self]
    return state.registries.water_zone_definitions:list()
end

function CatalogView:list_rules()
    local state = STATES[self]
    return state.registries.rule_definitions:list()
end

return Catalog
