local ErrorCodes = require 'wzx.domain.common.error_codes'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local CharacterErrorCodes = require 'wzx.domain.character.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.character.validation'
local AttributeFormulaSet = require 'wzx.config.schema.character.attribute_formula_set'
local CharacterDefinition = require 'wzx.config.schema.character.character_definition'
local LevelCurve = require 'wzx.config.schema.character.level_curve'
local TalentDefinition = require 'wzx.config.schema.character.talent_definition'

local Catalog = {}
local CatalogView = {}
CatalogView.__index = CatalogView
CatalogView.__newindex = function()
    error('character catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = setmetatable({}, { __mode = 'k' })
local SCHEMA = 'CharacterCatalog'
local COLLECTION_ORDER = {
    'character_definitions',
    'level_curves',
    'formula_sets',
    'talent_definitions',
}
local COLLECTION_FIELDS = {
    character_definitions = true,
    level_curves = true,
    formula_sets = true,
    talent_definitions = true,
}
local COLLECTION_SPECS = {
    character_definitions = {
        registry_name = 'character_definitions',
        normalize_entry = CharacterDefinition.validate,
    },
    level_curves = {
        registry_name = 'level_curves',
        normalize_entry = LevelCurve.validate,
    },
    formula_sets = {
        registry_name = 'formula_sets',
        normalize_entry = AttributeFormulaSet.validate,
    },
    talent_definitions = {
        registry_name = 'talent_definitions',
        normalize_entry = TalentDefinition.validate,
    },
}

local function invalid(field, reason, details)
    return Validation.invalid(SCHEMA, field, reason, details)
end

local function validate_source(source)
    local err = Validation.no_unknown_fields(SCHEMA, source, COLLECTION_FIELDS)
    if err ~= nil then
        return err
    end

    local index
    for index = 1, #COLLECTION_ORDER do
        local collection_name = COLLECTION_ORDER[index]
        err = Validation.dense_array(
            SCHEMA,
            collection_name,
            source[collection_name]
        )
        if err ~= nil then
            return err
        end
    end
    return Result.ok(true)
end

local function build_registry(collection_name, entries)
    local spec = COLLECTION_SPECS[collection_name]
    local created = SchemaRegistry.new({
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
    return Result.ok(registry)
end

local function missing_reference(character_id, field, reference_id, collection_name)
    return invalid(field, 'REFERENCE_NOT_FOUND', {
        character_id = character_id,
        reference_id = reference_id,
        referenced_collection = collection_name,
    })
end

local function validate_character_references(registries)
    local listed = registries.character_definitions:list()
    if not listed.ok then
        return listed
    end

    local character_index
    for character_index = 1, #listed.value do
        local character = listed.value[character_index]
        if not registries.level_curves:contains(character.level_curve_id) then
            return missing_reference(
                character.id,
                'level_curve_id',
                character.level_curve_id,
                'level_curves'
            )
        end
        if not registries.formula_sets:contains(character.formula_set_id) then
            return missing_reference(
                character.id,
                'formula_set_id',
                character.formula_set_id,
                'formula_sets'
            )
        end

        local talent_by_exclusive_group = {}
        local talent_index
        for talent_index = 1, #character.default_talent_ids do
            local talent_id = character.default_talent_ids[talent_index]
            if not registries.talent_definitions:contains(talent_id) then
                return missing_reference(
                    character.id,
                    'default_talent_ids[' .. tostring(talent_index) .. ']',
                    talent_id,
                    'talent_definitions'
                )
            end

            local talent_result = registries.talent_definitions:get(talent_id)
            if not talent_result.ok then
                return talent_result
            end
            local talent = talent_result.value
            if not character.deprecated and talent.deprecated then
                return invalid(
                    'default_talent_ids[' .. tostring(talent_index) .. ']',
                    'DEPRECATED_DEFAULT_TALENT_REFERENCE',
                    {
                        character_id = character.id,
                        talent_id = talent_id,
                    }
                )
            end

            local exclusive_group = talent.exclusive_group
            if exclusive_group ~= nil then
                local conflicting_talent_id = talent_by_exclusive_group[exclusive_group]
                if conflicting_talent_id ~= nil then
                    return invalid(
                        'default_talent_ids[' .. tostring(talent_index) .. ']',
                        'DEFAULT_TALENT_EXCLUSIVE_GROUP_CONFLICT',
                        {
                            character_id = character.id,
                            talent_id = talent_id,
                            conflicting_talent_id = conflicting_talent_id,
                            exclusive_group = exclusive_group,
                        }
                    )
                end
                talent_by_exclusive_group[exclusive_group] = talent_id
            end
        end
    end
    return Result.ok(true)
end

local function resolve_registry(self, collection_name)
    local state = STATES[self]
    if state == nil or type(collection_name) ~= 'string' then
        return nil
    end
    return state.registries[collection_name]
end

local function invalid_collection(collection_name)
    local details = nil
    if type(collection_name) == 'string' then
        details = { collection_name = collection_name }
    end
    return Result.err(
        ErrorCodes.INVALID_ARGUMENT,
        'error.character.catalog_collection_invalid',
        false,
        details
    )
end

local function invalid_authority(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err(
        ErrorCodes.INVALID_ARGUMENT,
        'error.character.catalog_authority_invalid',
        false,
        details
    )
end

local function invalid_build(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err(
        CharacterErrorCodes.CHARACTER_BUILD_INVALID,
        'error.character.build_invalid',
        false,
        details
    )
end

function CatalogView:get(collection_name, entry_id)
    local registry = resolve_registry(self, collection_name)
    if registry == nil then
        return invalid_collection(collection_name)
    end
    return registry:get(entry_id)
end

function CatalogView:list(collection_name)
    local registry = resolve_registry(self, collection_name)
    if registry == nil then
        return invalid_collection(collection_name)
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

    local references = validate_character_references(registries)
    if not references.ok then
        return references
    end

    for index = 1, #COLLECTION_ORDER do
        local sealed = registries[COLLECTION_ORDER[index]]:seal()
        if not sealed.ok then
            return sealed
        end
    end

    local view = setmetatable({}, CatalogView)
    STATES[view] = { registries = registries }
    return Result.ok(view)
end

-- This is the trusted projection boundary used by application character rules.
-- It verifies the sealed catalog identity before returning only domain-relevant
-- facts and the curve already cross-checked during Catalog.build.
function CatalogView:resolve_character(character_id)
    local state = STATES[self]
    if state == nil then
        return invalid_authority('CATALOG_AUTHORITY_REQUIRED')
    end
    local checked_id = RuntimeId.validate_content(
        character_id,
        'char_',
        'character_id'
    )
    if not checked_id.ok then
        return invalid_authority('CHARACTER_ID_INVALID', {
            field = 'character_id',
        })
    end

    local definition_result = state.registries.character_definitions:get(character_id)
    if not definition_result.ok then
        return definition_result
    end
    local definition = definition_result.value
    local curve_result = state.registries.level_curves:get(definition.level_curve_id)
    if not curve_result.ok then
        return curve_result
    end

    local talent_ids = {}
    local index
    for index = 1, #definition.default_talent_ids do
        talent_ids[index] = definition.default_talent_ids[index]
    end
    return Result.ok({
        definition_facts = {
            id = definition.id,
            definition_version = definition.definition_version,
            role = definition.role,
            level_curve_id = definition.level_curve_id,
            default_talent_ids = talent_ids,
            deprecated = definition.deprecated,
        },
        level_curve = curve_result.value,
    })
end

function CatalogView:validate_owned_talents(character_id, talent_ids)
    local state = STATES[self]
    if state == nil then
        return invalid_authority('CATALOG_AUTHORITY_REQUIRED')
    end
    local checked_id = RuntimeId.validate_content(
        character_id,
        'char_',
        'character_id'
    )
    if not checked_id.ok then
        return invalid_build('CHARACTER_ID_INVALID', {
            field = 'state.character_id',
        })
    end
    if getmetatable(talent_ids) ~= nil or not Ordered.is_dense_array(talent_ids) then
        return invalid_build('DENSE_ARRAY_REQUIRED', {
            field = 'state.unlocked_talent_ids',
        })
    end

    local talent_by_exclusive_group = {}
    local index
    for index = 1, #talent_ids do
        local talent_id = talent_ids[index]
        local checked_talent_id = RuntimeId.validate_content(
            talent_id,
            'talent_',
            'state.unlocked_talent_ids[' .. tostring(index) .. ']'
        )
        if not checked_talent_id.ok then
            return invalid_build('TALENT_ID_INVALID', {
                field = 'state.unlocked_talent_ids[' .. tostring(index) .. ']',
            })
        end
        local talent_result = state.registries.talent_definitions:get(talent_id)
        if not talent_result.ok then
            return invalid_build('TALENT_REFERENCE_NOT_FOUND', {
                character_id = character_id,
                talent_id = talent_id,
                index = index,
            })
        end

        local talent = talent_result.value
        if talent.exclusive_group ~= nil then
            local conflicting_talent_id = talent_by_exclusive_group[
                talent.exclusive_group
            ]
            if conflicting_talent_id ~= nil then
                return invalid_build('TALENT_EXCLUSIVE_GROUP_CONFLICT', {
                    character_id = character_id,
                    talent_id = talent_id,
                    conflicting_talent_id = conflicting_talent_id,
                    exclusive_group = talent.exclusive_group,
                })
            end
            talent_by_exclusive_group[talent.exclusive_group] = talent_id
        end
    end
    return Result.ok(true)
end

function Catalog.is_authority(catalog)
    return STATES[catalog] ~= nil
end

return Catalog
