local ErrorCodes = require 'wzx.domain.common.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local MartialErrorCodes = require 'wzx.domain.martial.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.martial.validation'
local CompatibilityRule = require 'wzx.config.schema.martial.compatibility_rule'
local LightnessProfileDefinition = require 'wzx.config.schema.martial.lightness_profile_definition'
local MartialDefinition = require 'wzx.config.schema.martial.martial_definition'
local MoveDefinition = require 'wzx.config.schema.martial.move_definition'

local Catalog = {}
local error_value = error
local get_metatable = getmetatable
local result_err = Result.err
local result_ok = Result.ok
local schema_registry_new = SchemaRegistry.new
local set_metatable = setmetatable
local tostring_value = tostring
local type_value = type
local validate_content_id = RuntimeId.validate_content
local validation_dense_array = Validation.dense_array
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local CatalogView = {}
CatalogView.__index = CatalogView
CatalogView.__newindex = function()
    error_value('martial catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'MartialCatalog'
local COLLECTION_ORDER = {
    'compatibility_rules',
    'move_definitions',
    'lightness_traversal_profiles',
    'martial_definitions',
}
local COLLECTION_FIELDS = {
    compatibility_rules = true,
    move_definitions = true,
    lightness_traversal_profiles = true,
    martial_definitions = true,
}
local COLLECTION_SPECS = {
    compatibility_rules = {
        registry_name = 'compatibility_rules',
        normalize_entry = CompatibilityRule.validate,
    },
    move_definitions = {
        registry_name = 'move_definitions',
        normalize_entry = MoveDefinition.validate,
    },
    lightness_traversal_profiles = {
        registry_name = 'lightness_traversal_profiles',
        normalize_entry = LightnessProfileDefinition.validate,
    },
    martial_definitions = {
        registry_name = 'martial_definitions',
        normalize_entry = MartialDefinition.validate,
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

local function validate_cross_references(registries)
    local moves = registries.move_definitions:list()
    if not moves.ok then
        return moves
    end
    local profiles = registries.lightness_traversal_profiles:list()
    if not profiles.ok then
        return profiles
    end
    local martials = registries.martial_definitions:list()
    if not martials.ok then
        return martials
    end

    local martial_by_id = {}
    local martial_index
    for martial_index = 1, #martials.value do
        local martial = martials.value[martial_index]
        martial_by_id[martial.id] = martial
        if not registries.compatibility_rules:contains(martial.compatibility_rule_id) then
            return invalid('compatibility_rule_id', 'REFERENCE_NOT_FOUND', {
                martial_id = martial.id,
                reference_id = martial.compatibility_rule_id,
            })
        end
        if martial.lightness_traversal_profile_id ~= nil then
            if not registries.lightness_traversal_profiles:contains(
                martial.lightness_traversal_profile_id
            )
            then
                return invalid('lightness_traversal_profile_id', 'REFERENCE_NOT_FOUND', {
                    martial_id = martial.id,
                    reference_id = martial.lightness_traversal_profile_id,
                })
            end
        end

        local move_set = {}
        local move_index
        for move_index = 1, #martial.move_ids do
            local move_id = martial.move_ids[move_index]
            if not registries.move_definitions:contains(move_id) then
                return invalid('move_ids', 'REFERENCE_NOT_FOUND', {
                    martial_id = martial.id,
                    reference_id = move_id,
                })
            end
            move_set[move_id] = true
        end

        local level_index
        for level_index = 1, #martial.level_rows do
            local row = martial.level_rows[level_index]
            local unlocked_index
            for unlocked_index = 1, #row.unlocked_move_ids do
                local unlocked_id = row.unlocked_move_ids[unlocked_index]
                if move_set[unlocked_id] ~= true then
                    return invalid(
                        'level_rows.unlocked_move_ids',
                        'UNLOCKED_MOVE_NOT_IN_MARTIAL',
                        {
                            martial_id = martial.id,
                            level = row.level,
                            move_id = unlocked_id,
                        }
                    )
                end
            end
        end
    end

    local move_index
    for move_index = 1, #moves.value do
        local move = moves.value[move_index]
        local owner = martial_by_id[move.source_martial_id]
        if owner == nil then
            return invalid('source_martial_id', 'REFERENCE_NOT_FOUND', {
                move_id = move.id,
                reference_id = move.source_martial_id,
            })
        end
        local found = false
        local martial_move_index
        for martial_move_index = 1, #owner.move_ids do
            if owner.move_ids[martial_move_index] == move.id then
                found = true
                break
            end
        end
        if not found then
            return invalid('source_martial_id', 'MOVE_NOT_LISTED_ON_MARTIAL', {
                move_id = move.id,
                martial_id = owner.id,
            })
        end
    end

    local profile_index
    for profile_index = 1, #profiles.value do
        local profile = profiles.value[profile_index]
        local martial = martial_by_id[profile.source_martial_id]
        if martial == nil then
            return invalid('source_martial_id', 'REFERENCE_NOT_FOUND', {
                profile_id = profile.id,
                reference_id = profile.source_martial_id,
            })
        end
        if martial.category ~= 'LIGHTNESS' then
            return invalid('source_martial_id', 'PROFILE_SOURCE_MUST_BE_LIGHTNESS', {
                profile_id = profile.id,
                martial_id = martial.id,
            })
        end
        if martial.lightness_traversal_profile_id ~= profile.id then
            return invalid('source_martial_id', 'PROFILE_REVERSE_REFERENCE_MISMATCH', {
                profile_id = profile.id,
                martial_id = martial.id,
                expected_profile_id = martial.lightness_traversal_profile_id,
            })
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
            'error.martial.catalog_collection_invalid',
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
            'error.martial.catalog_collection_invalid',
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

function CatalogView:require_martial(martial_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            MartialErrorCodes.MARTIAL_ARGUMENT_INVALID,
            'error.martial.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(martial_id, 'martial_', 'martial_id')
    if not checked.ok then
        return catalog_error(
            MartialErrorCodes.MARTIAL_ARGUMENT_INVALID,
            'error.martial.martial_id_invalid',
            'MARTIAL_ID_INVALID',
            { field = 'martial_id' }
        )
    end
    local found = state.registries.martial_definitions:get(martial_id)
    if not found.ok then
        return catalog_error(
            MartialErrorCodes.MARTIAL_UNKNOWN,
            'error.martial.unknown',
            'MARTIAL_UNKNOWN',
            { martial_id = martial_id }
        )
    end
    return found
end

function CatalogView:require_compatibility_rule(rule_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            MartialErrorCodes.MARTIAL_ARGUMENT_INVALID,
            'error.martial.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.registries.compatibility_rules:get(rule_id)
end

function CatalogView:require_lightness_profile(profile_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            MartialErrorCodes.MARTIAL_ARGUMENT_INVALID,
            'error.martial.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.registries.lightness_traversal_profiles:get(profile_id)
end

function CatalogView:require_move(move_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            MartialErrorCodes.MARTIAL_ARGUMENT_INVALID,
            'error.martial.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.registries.move_definitions:get(move_id)
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
