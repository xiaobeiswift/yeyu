local ErrorCodes = require 'wzx.domain.common.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local QuestErrorCodes = require 'wzx.domain.quest.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.quest.validation'
local QuestDefinition = require 'wzx.config.schema.quest.quest_definition'
local StageDefinition = require 'wzx.config.schema.quest.stage_definition'
local ObjectiveDefinition = require 'wzx.config.schema.quest.objective_definition'

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
    error_value('quest catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'QuestCatalog'
local COLLECTION_ORDER = {
    'objective_definitions',
    'stage_definitions',
    'quest_definitions',
}
local COLLECTION_FIELDS = {
    objective_definitions = true,
    stage_definitions = true,
    quest_definitions = true,
}
local COLLECTION_SPECS = {
    objective_definitions = {
        registry_name = 'objective_definitions',
        normalize_entry = ObjectiveDefinition.validate,
    },
    stage_definitions = {
        registry_name = 'stage_definitions',
        normalize_entry = StageDefinition.validate,
    },
    quest_definitions = {
        registry_name = 'quest_definitions',
        normalize_entry = QuestDefinition.validate,
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
    local objectives = registries.objective_definitions:list()
    if not objectives.ok then
        return objectives
    end
    local stages = registries.stage_definitions:list()
    if not stages.ok then
        return stages
    end
    local quests = registries.quest_definitions:list()
    if not quests.ok then
        return quests
    end

    local index
    for index = 1, #stages.value do
        local stage = stages.value[index]
        local obj_index
        for obj_index = 1, #stage.objective_ids do
            local objective_id = stage.objective_ids[obj_index]
            local objective = registries.objective_definitions:get(objective_id)
            if not objective.ok then
                return invalid('objective_ids', 'REFERENCE_NOT_FOUND', {
                    stage_id = stage.id,
                    reference_id = objective_id,
                })
            end
            if objective.value.stage_id ~= stage.id then
                return invalid('stage_id', 'OBJECTIVE_STAGE_MISMATCH', {
                    stage_id = stage.id,
                    objective_id = objective_id,
                    objective_stage_id = objective.value.stage_id,
                })
            end
            if objective.value.rules_version ~= stage.rules_version then
                return invalid('rules_version', 'OBJECTIVE_RULES_MISMATCH', {
                    stage_id = stage.id,
                    objective_id = objective_id,
                })
            end
        end
        if stage.next_stage_id ~= nil then
            local next_stage = registries.stage_definitions:get(stage.next_stage_id)
            if not next_stage.ok then
                return invalid('next_stage_id', 'REFERENCE_NOT_FOUND', {
                    stage_id = stage.id,
                    reference_id = stage.next_stage_id,
                })
            end
            if next_stage.value.quest_id ~= stage.quest_id then
                return invalid('next_stage_id', 'NEXT_STAGE_QUEST_MISMATCH', {
                    stage_id = stage.id,
                    next_stage_id = stage.next_stage_id,
                })
            end
        end
    end

    for index = 1, #quests.value do
        local quest = quests.value[index]
        local stage_index
        for stage_index = 1, #quest.stage_ids do
            local stage_id = quest.stage_ids[stage_index]
            local stage = registries.stage_definitions:get(stage_id)
            if not stage.ok then
                return invalid('stage_ids', 'REFERENCE_NOT_FOUND', {
                    quest_id = quest.id,
                    reference_id = stage_id,
                })
            end
            if stage.value.quest_id ~= quest.id then
                return invalid('quest_id', 'STAGE_QUEST_MISMATCH', {
                    quest_id = quest.id,
                    stage_id = stage_id,
                })
            end
            if stage.value.rules_version ~= quest.rules_version then
                return invalid('rules_version', 'STAGE_RULES_MISMATCH', {
                    quest_id = quest.id,
                    stage_id = stage_id,
                })
            end
        end
        local first = registries.stage_definitions:get(quest.first_stage_id)
        if not first.ok then
            return invalid('first_stage_id', 'REFERENCE_NOT_FOUND', {
                quest_id = quest.id,
                reference_id = quest.first_stage_id,
            })
        end
        if quest.prerequisite_quest_id ~= nil then
            local prereq = registries.quest_definitions:get(quest.prerequisite_quest_id)
            if not prereq.ok then
                return invalid('prerequisite_quest_id', 'REFERENCE_NOT_FOUND', {
                    quest_id = quest.id,
                    reference_id = quest.prerequisite_quest_id,
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
            'error.quest.catalog_collection_invalid',
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
            'error.quest.catalog_collection_invalid',
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

function CatalogView:require_quest(quest_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            QuestErrorCodes.QUEST_ARGUMENT_INVALID,
            'error.quest.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(quest_id, 'quest_', 'quest_id')
    if not checked.ok then
        return catalog_error(
            QuestErrorCodes.QUEST_ARGUMENT_INVALID,
            'error.quest.quest_id_invalid',
            'QUEST_ID_INVALID',
            { field = 'quest_id' }
        )
    end
    local found = state.registries.quest_definitions:get(quest_id)
    if not found.ok then
        return catalog_error(
            QuestErrorCodes.QUEST_DEFINITION_UNKNOWN,
            'error.quest.definition_unknown',
            'QUEST_UNKNOWN',
            { quest_id = quest_id }
        )
    end
    if found.value.deprecated then
        return catalog_error(
            QuestErrorCodes.QUEST_DEPRECATED,
            'error.quest.deprecated',
            'QUEST_DEPRECATED',
            { quest_id = quest_id }
        )
    end
    return found
end

function CatalogView:require_stage(stage_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            QuestErrorCodes.QUEST_ARGUMENT_INVALID,
            'error.quest.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.stage_definitions:get(stage_id)
    if not found.ok then
        return catalog_error(
            QuestErrorCodes.QUEST_STAGE_UNKNOWN,
            'error.quest.stage_unknown',
            'STAGE_UNKNOWN',
            { stage_id = stage_id }
        )
    end
    return found
end

function CatalogView:require_objective(objective_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            QuestErrorCodes.QUEST_ARGUMENT_INVALID,
            'error.quest.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.objective_definitions:get(objective_id)
    if not found.ok then
        return catalog_error(
            QuestErrorCodes.QUEST_OBJECTIVE_UNKNOWN,
            'error.quest.objective_unknown',
            'OBJECTIVE_UNKNOWN',
            { objective_id = objective_id }
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
