local ErrorCodes = require 'wzx.domain.common.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.equipment.validation'
local AffixDefinition = require 'wzx.config.schema.equipment.affix_definition'
local AffixPool = require 'wzx.config.schema.equipment.affix_pool'
local BaseStatSet = require 'wzx.config.schema.equipment.base_stat_set'
local EnhancementTrack = require 'wzx.config.schema.equipment.enhancement_track'
local EquipmentDefinition = require 'wzx.config.schema.equipment.equipment_definition'
local TemperRule = require 'wzx.config.schema.equipment.temper_rule'

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
    error_value('equipment catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'EquipmentCatalog'
local COLLECTION_ORDER = {
    'base_stat_sets',
    'affix_definitions',
    'affix_pools',
    'enhancement_tracks',
    'temper_rules',
    'equipment_definitions',
}
local COLLECTION_FIELDS = {
    base_stat_sets = true,
    affix_definitions = true,
    affix_pools = true,
    enhancement_tracks = true,
    temper_rules = true,
    equipment_definitions = true,
}
local COLLECTION_SPECS = {
    base_stat_sets = {
        registry_name = 'base_stat_sets',
        normalize_entry = BaseStatSet.validate,
    },
    affix_definitions = {
        registry_name = 'affix_definitions',
        normalize_entry = AffixDefinition.validate,
    },
    affix_pools = {
        registry_name = 'affix_pools',
        normalize_entry = AffixPool.validate,
    },
    enhancement_tracks = {
        registry_name = 'enhancement_tracks',
        normalize_entry = EnhancementTrack.validate,
    },
    temper_rules = {
        registry_name = 'temper_rules',
        normalize_entry = TemperRule.validate,
    },
    equipment_definitions = {
        registry_name = 'equipment_definitions',
        normalize_entry = EquipmentDefinition.validate,
    },
}
local RARITY_RANK = {
    COMMON = 1,
    FINE = 2,
    RARE = 3,
    EPIC = 4,
    LEGEND = 5,
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
    return result_ok(registry)
end

local function list_contains(values, needle)
    local index
    for index = 1, #values do
        if values[index] == needle then
            return true
        end
    end
    return false
end

local function validate_cross_references(registries)
    local pools = registries.affix_pools:list()
    if not pools.ok then
        return pools
    end
    local equipments = registries.equipment_definitions:list()
    if not equipments.ok then
        return equipments
    end

    local pool_index
    for pool_index = 1, #pools.value do
        local pool = pools.value[pool_index]
        local entry_index
        for entry_index = 1, #pool.entries do
            local entry = pool.entries[entry_index]
            local affix = registries.affix_definitions:get(entry.affix_id)
            if not affix.ok then
                return invalid('affix_pools.entries.affix_id', 'REFERENCE_NOT_FOUND', {
                    affix_pool_id = pool.id,
                    reference_id = entry.affix_id,
                })
            end
            if entry.tier > #affix.value.tiers then
                return invalid('affix_pools.entries.tier', 'AFFIX_TIER_NOT_FOUND', {
                    affix_pool_id = pool.id,
                    affix_id = entry.affix_id,
                    tier = entry.tier,
                })
            end
        end
    end

    local equip_index
    for equip_index = 1, #equipments.value do
        local equipment = equipments.value[equip_index]
        if not registries.base_stat_sets:contains(equipment.base_stat_set_id) then
            return invalid('base_stat_set_id', 'REFERENCE_NOT_FOUND', {
                equipment_id = equipment.id,
                reference_id = equipment.base_stat_set_id,
            })
        end
        if not registries.enhancement_tracks:contains(equipment.enhancement_track_id) then
            return invalid('enhancement_track_id', 'REFERENCE_NOT_FOUND', {
                equipment_id = equipment.id,
                reference_id = equipment.enhancement_track_id,
            })
        end
        if equipment.temper_rule_id ~= nil then
            if not registries.temper_rules:contains(equipment.temper_rule_id) then
                return invalid('temper_rule_id', 'REFERENCE_NOT_FOUND', {
                    equipment_id = equipment.id,
                    reference_id = equipment.temper_rule_id,
                })
            end
        end
        if equipment.affix_pool_id ~= nil then
            local pool = registries.affix_pools:get(equipment.affix_pool_id)
            if not pool.ok then
                return invalid('affix_pool_id', 'REFERENCE_NOT_FOUND', {
                    equipment_id = equipment.id,
                    reference_id = equipment.affix_pool_id,
                })
            end
            -- Pool entries must be compatible with equipment slot/route for at least
            -- one candidate when affix_count_max > 0.
            local compatible = 0
            local entry_index
            for entry_index = 1, #pool.value.entries do
                local entry = pool.value.entries[entry_index]
                local rarity_ok = RARITY_RANK[equipment.rarity] >= RARITY_RANK[entry.rarity_min]
                    and RARITY_RANK[equipment.rarity] <= RARITY_RANK[entry.rarity_max]
                if rarity_ok then
                    local affix = registries.affix_definitions:get(entry.affix_id)
                    if affix.ok
                        and list_contains(affix.value.allowed_slots, equipment.slot)
                        and list_contains(affix.value.allowed_routes, equipment.weapon_route)
                    then
                        compatible = compatible + 1
                    end
                end
            end
            if equipment.affix_count_max > 0 and compatible < 1 then
                return invalid('affix_pool_id', 'AFFIX_POOL_EMPTY_FOR_EQUIPMENT', {
                    equipment_id = equipment.id,
                    affix_pool_id = equipment.affix_pool_id,
                })
            end
        end
    end

    return result_ok(true)
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
            'error.equipment.catalog_collection_invalid',
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
            'error.equipment.catalog_collection_invalid',
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

function CatalogView:require_equipment(equipment_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID,
            'error.equipment.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(equipment_id, 'equip_', 'equipment_id')
    if not checked.ok then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID,
            'error.equipment.equipment_id_invalid',
            'EQUIPMENT_ID_INVALID',
            { field = 'equipment_id' }
        )
    end
    local found = state.registries.equipment_definitions:get(equipment_id)
    if not found.ok then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_UNKNOWN,
            'error.equipment.unknown',
            'EQUIPMENT_UNKNOWN',
            { equipment_id = equipment_id }
        )
    end
    return found
end

function CatalogView:require_base_stat_set(set_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID,
            'error.equipment.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.base_stat_sets:get(set_id)
    if not found.ok then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_CONFIG_BROKEN,
            'error.equipment.base_stat_set_unknown',
            'BASE_STAT_SET_UNKNOWN',
            { base_stat_set_id = set_id }
        )
    end
    return found
end

function CatalogView:require_affix(affix_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID,
            'error.equipment.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.affix_definitions:get(affix_id)
    if not found.ok then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_CONFIG_BROKEN,
            'error.equipment.affix_unknown',
            'AFFIX_UNKNOWN',
            { affix_id = affix_id }
        )
    end
    return found
end

function CatalogView:require_affix_pool(pool_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID,
            'error.equipment.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.affix_pools:get(pool_id)
    if not found.ok then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_CONFIG_BROKEN,
            'error.equipment.affix_pool_unknown',
            'AFFIX_POOL_UNKNOWN',
            { affix_pool_id = pool_id }
        )
    end
    return found
end

function CatalogView:require_enhancement_track(track_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID,
            'error.equipment.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.enhancement_tracks:get(track_id)
    if not found.ok then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_CONFIG_BROKEN,
            'error.equipment.enhancement_track_unknown',
            'ENHANCEMENT_TRACK_UNKNOWN',
            { enhancement_track_id = track_id }
        )
    end
    return found
end

function CatalogView:require_temper_rule(rule_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID,
            'error.equipment.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.temper_rules:get(rule_id)
    if not found.ok then
        return catalog_error(
            EquipmentErrorCodes.EQUIPMENT_CONFIG_BROKEN,
            'error.equipment.temper_rule_unknown',
            'TEMPER_RULE_UNKNOWN',
            { temper_rule_id = rule_id }
        )
    end
    return found
end

function Catalog.build(source)
    -- Defensive shallow copy so missing collections can be defaulted without
    -- mutating caller tables.
    if type_value(source) ~= 'table' or get_metatable(source) ~= nil then
        return invalid('$', 'TABLE_REQUIRED')
    end
    local normalized_source = {
        base_stat_sets = source.base_stat_sets or {},
        affix_definitions = source.affix_definitions or {},
        affix_pools = source.affix_pools or {},
        enhancement_tracks = source.enhancement_tracks or {},
        temper_rules = source.temper_rules or {},
        equipment_definitions = source.equipment_definitions or {},
    }
    local checked = validate_source(normalized_source)
    if not checked.ok then
        return checked
    end

    local registries = {}
    local index
    for index = 1, #COLLECTION_ORDER do
        local collection_name = COLLECTION_ORDER[index]
        local built = build_registry(collection_name, normalized_source[collection_name])
        if not built.ok then
            return built
        end
        registries[collection_name] = built.value
    end

    local references = validate_cross_references(registries)
    if not references.ok then
        return references
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

function Catalog.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

return Catalog
