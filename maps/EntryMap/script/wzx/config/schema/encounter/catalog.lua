local ErrorCodes = require 'wzx.domain.common.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.encounter.validation'
local EnemyStatProfile = require 'wzx.config.schema.encounter.enemy_stat_profile'
local EnemyMoveSet = require 'wzx.config.schema.encounter.enemy_move_set'
local EnemyDefinition = require 'wzx.config.schema.encounter.enemy_definition'
local WaveDefinition = require 'wzx.config.schema.encounter.wave_definition'
local BossPhaseDefinition = require 'wzx.config.schema.encounter.boss_phase_definition'
local BossControllerDefinition = require 'wzx.config.schema.encounter.boss_controller_definition'
local EncounterDefinition = require 'wzx.config.schema.encounter.encounter_definition'

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
    error_value('encounter catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'EncounterCatalog'
local COLLECTION_ORDER = {
    'enemy_stat_profiles',
    'enemy_move_sets',
    'enemy_definitions',
    'wave_definitions',
    'boss_phase_definitions',
    'boss_controller_definitions',
    'encounter_definitions',
}
local COLLECTION_FIELDS = {
    enemy_stat_profiles = true,
    enemy_move_sets = true,
    enemy_definitions = true,
    wave_definitions = true,
    boss_phase_definitions = true,
    boss_controller_definitions = true,
    encounter_definitions = true,
}
local COLLECTION_SPECS = {
    enemy_stat_profiles = {
        registry_name = 'enemy_stat_profiles',
        normalize_entry = EnemyStatProfile.validate,
    },
    enemy_move_sets = {
        registry_name = 'enemy_move_sets',
        normalize_entry = EnemyMoveSet.validate,
    },
    enemy_definitions = {
        registry_name = 'enemy_definitions',
        normalize_entry = EnemyDefinition.validate,
    },
    wave_definitions = {
        registry_name = 'wave_definitions',
        normalize_entry = WaveDefinition.validate,
    },
    boss_phase_definitions = {
        registry_name = 'boss_phase_definitions',
        normalize_entry = BossPhaseDefinition.validate,
    },
    boss_controller_definitions = {
        registry_name = 'boss_controller_definitions',
        normalize_entry = BossControllerDefinition.validate,
    },
    encounter_definitions = {
        registry_name = 'encounter_definitions',
        normalize_entry = EncounterDefinition.validate,
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
    local enemies = registries.enemy_definitions:list()
    if not enemies.ok then
        return enemies
    end
    local waves = registries.wave_definitions:list()
    if not waves.ok then
        return waves
    end
    local phases = registries.boss_phase_definitions:list()
    if not phases.ok then
        return phases
    end
    local controllers = registries.boss_controller_definitions:list()
    if not controllers.ok then
        return controllers
    end
    local encounters = registries.encounter_definitions:list()
    if not encounters.ok then
        return encounters
    end

    local index
    for index = 1, #enemies.value do
        local enemy = enemies.value[index]
        if not registries.enemy_stat_profiles:contains(enemy.stat_profile_id) then
            return invalid('stat_profile_id', 'REFERENCE_NOT_FOUND', {
                enemy_id = enemy.id,
                reference_id = enemy.stat_profile_id,
            })
        end
        if not registries.enemy_move_sets:contains(enemy.move_set_id) then
            return invalid('move_set_id', 'REFERENCE_NOT_FOUND', {
                enemy_id = enemy.id,
                reference_id = enemy.move_set_id,
            })
        end
        local profile = registries.enemy_stat_profiles:get(enemy.stat_profile_id)
        if profile.ok and profile.value.rules_version ~= enemy.rules_version then
            return invalid('rules_version', 'ENEMY_PROFILE_RULES_MISMATCH', {
                enemy_id = enemy.id,
                enemy_rules_version = enemy.rules_version,
                profile_rules_version = profile.value.rules_version,
            })
        end
        local move_set = registries.enemy_move_sets:get(enemy.move_set_id)
        if move_set.ok and move_set.value.rules_version ~= enemy.rules_version then
            return invalid('rules_version', 'ENEMY_MOVE_SET_RULES_MISMATCH', {
                enemy_id = enemy.id,
                enemy_rules_version = enemy.rules_version,
                move_set_rules_version = move_set.value.rules_version,
            })
        end
    end

    for index = 1, #waves.value do
        local wave = waves.value[index]
        local row_index
        for row_index = 1, #wave.spawn_rows do
            local row = wave.spawn_rows[row_index]
            if not registries.enemy_definitions:contains(row.enemy_id) then
                return invalid('spawn_rows.enemy_id', 'REFERENCE_NOT_FOUND', {
                    wave_id = wave.id,
                    reference_id = row.enemy_id,
                    index = row_index,
                })
            end
            local enemy = registries.enemy_definitions:get(row.enemy_id)
            if enemy.ok then
                local profile = registries.enemy_stat_profiles:get(enemy.value.stat_profile_id)
                if profile.ok then
                    if row.level < profile.value.level_min or row.level > profile.value.level_max then
                        return invalid('spawn_rows.level', 'ENEMY_LEVEL_OUT_OF_PROFILE_RANGE', {
                            wave_id = wave.id,
                            enemy_id = row.enemy_id,
                            level = row.level,
                            level_min = profile.value.level_min,
                            level_max = profile.value.level_max,
                        })
                    end
                end
            end
        end
    end

    for index = 1, #controllers.value do
        local controller = controllers.value[index]
        local phase_index
        local previous_hp_threshold = nil
        for phase_index = 1, #controller.phase_ids do
            local phase_id = controller.phase_ids[phase_index]
            local phase = registries.boss_phase_definitions:get(phase_id)
            if not phase.ok then
                return invalid('phase_ids', 'REFERENCE_NOT_FOUND', {
                    controller_id = controller.id,
                    reference_id = phase_id,
                    index = phase_index,
                })
            end
            if phase.value.phase_index ~= phase_index then
                return invalid('phase_ids', 'PHASE_INDEX_NOT_SEQUENTIAL', {
                    controller_id = controller.id,
                    phase_id = phase_id,
                    expected_index = phase_index,
                    actual_index = phase.value.phase_index,
                })
            end
            if phase.value.rules_version ~= controller.rules_version then
                return invalid('rules_version', 'PHASE_RULES_MISMATCH', {
                    controller_id = controller.id,
                    phase_id = phase_id,
                })
            end
            if phase.value.trigger == 'HP_AT_OR_BELOW_BP' then
                if previous_hp_threshold ~= nil
                    and phase.value.trigger_value >= previous_hp_threshold
                then
                    return invalid('trigger_value', 'HP_THRESHOLD_NOT_DECREASING', {
                        controller_id = controller.id,
                        phase_id = phase_id,
                        trigger_value = phase.value.trigger_value,
                        previous = previous_hp_threshold,
                    })
                end
                previous_hp_threshold = phase.value.trigger_value
            end
        end
    end

    for index = 1, #encounters.value do
        local encounter = encounters.value[index]
        local wave_index
        for wave_index = 1, #encounter.wave_ids do
            local wave_id = encounter.wave_ids[wave_index]
            local wave = registries.wave_definitions:get(wave_id)
            if not wave.ok then
                return invalid('wave_ids', 'REFERENCE_NOT_FOUND', {
                    encounter_id = encounter.id,
                    reference_id = wave_id,
                    index = wave_index,
                })
            end
            if wave.value.wave_index ~= wave_index then
                return invalid('wave_ids', 'WAVE_INDEX_NOT_SEQUENTIAL', {
                    encounter_id = encounter.id,
                    wave_id = wave_id,
                    expected_index = wave_index,
                    actual_index = wave.value.wave_index,
                })
            end
            if wave.value.rules_version ~= encounter.rules_version then
                return invalid('rules_version', 'WAVE_RULES_MISMATCH', {
                    encounter_id = encounter.id,
                    wave_id = wave_id,
                })
            end
        end
        if encounter.boss_controller_id ~= nil then
            local controller = registries.boss_controller_definitions:get(
                encounter.boss_controller_id
            )
            if not controller.ok then
                return invalid('boss_controller_id', 'REFERENCE_NOT_FOUND', {
                    encounter_id = encounter.id,
                    reference_id = encounter.boss_controller_id,
                })
            end
            if controller.value.rules_version ~= encounter.rules_version then
                return invalid('rules_version', 'BOSS_CONTROLLER_RULES_MISMATCH', {
                    encounter_id = encounter.id,
                    controller_id = encounter.boss_controller_id,
                })
            end
            local spawn_found = false
            for wave_index = 1, #encounter.wave_ids do
                local wave = registries.wave_definitions:get(encounter.wave_ids[wave_index])
                if wave.ok then
                    local row_index
                    for row_index = 1, #wave.value.spawn_rows do
                        if wave.value.spawn_rows[row_index].spawn_id
                            == controller.value.boss_spawn_id
                        then
                            spawn_found = true
                            break
                        end
                    end
                end
                if spawn_found then
                    break
                end
            end
            if not spawn_found then
                return invalid('boss_spawn_id', 'BOSS_SPAWN_NOT_IN_ENCOUNTER_WAVES', {
                    encounter_id = encounter.id,
                    controller_id = encounter.boss_controller_id,
                    boss_spawn_id = controller.value.boss_spawn_id,
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
            'error.encounter.catalog_collection_invalid',
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
            'error.encounter.catalog_collection_invalid',
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

function CatalogView:require_enemy(enemy_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(enemy_id, 'enemy_', 'enemy_id')
    if not checked.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.enemy_id_invalid',
            'ENEMY_ID_INVALID',
            { field = 'enemy_id' }
        )
    end
    local found = state.registries.enemy_definitions:get(enemy_id)
    if not found.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ENEMY_UNKNOWN,
            'error.encounter.enemy_unknown',
            'ENEMY_UNKNOWN',
            { enemy_id = enemy_id }
        )
    end
    return found
end

function CatalogView:require_wave(wave_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.wave_definitions:get(wave_id)
    if not found.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_WAVE_UNKNOWN,
            'error.encounter.wave_unknown',
            'WAVE_UNKNOWN',
            { wave_id = wave_id }
        )
    end
    return found
end

function CatalogView:require_encounter(encounter_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(encounter_id, 'encounter_', 'encounter_id')
    if not checked.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.encounter_id_invalid',
            'ENCOUNTER_ID_INVALID',
            { field = 'encounter_id' }
        )
    end
    local found = state.registries.encounter_definitions:get(encounter_id)
    if not found.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_UNKNOWN,
            'error.encounter.unknown',
            'ENCOUNTER_UNKNOWN',
            { encounter_id = encounter_id }
        )
    end
    if found.value.deprecated then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_DEPRECATED,
            'error.encounter.deprecated',
            'ENCOUNTER_DEPRECATED',
            { encounter_id = encounter_id }
        )
    end
    return found
end

function CatalogView:require_stat_profile(profile_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.enemy_stat_profiles:get(profile_id)
    if not found.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
            'error.encounter.stat_profile_unknown',
            'STAT_PROFILE_UNKNOWN',
            { stat_profile_id = profile_id }
        )
    end
    return found
end

function CatalogView:require_move_set(move_set_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.enemy_move_sets:get(move_set_id)
    if not found.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_CONFIG_BROKEN,
            'error.encounter.move_set_unknown',
            'MOVE_SET_UNKNOWN',
            { move_set_id = move_set_id }
        )
    end
    return found
end

function CatalogView:require_boss_controller(controller_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(controller_id, 'bossctl_', 'boss_controller_id')
    if not checked.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.boss_controller_id_invalid',
            'BOSS_CONTROLLER_ID_INVALID',
            { field = 'boss_controller_id' }
        )
    end
    local found = state.registries.boss_controller_definitions:get(controller_id)
    if not found.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_BOSS_CONTROLLER_UNKNOWN,
            'error.encounter.boss_controller_unknown',
            'BOSS_CONTROLLER_UNKNOWN',
            { boss_controller_id = controller_id }
        )
    end
    return found
end

function CatalogView:require_boss_phase(phase_id)
    local state = STATES[self]
    if state == nil then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'error.encounter.catalog_authority_required',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local found = state.registries.boss_phase_definitions:get(phase_id)
    if not found.ok then
        return catalog_error(
            EncounterErrorCodes.ENCOUNTER_BOSS_PHASE_UNKNOWN,
            'error.encounter.boss_phase_unknown',
            'BOSS_PHASE_UNKNOWN',
            { boss_phase_id = phase_id }
        )
    end
    return found
end

function CatalogView:build_boss_runtime(controller_id, boss_actor_id, move_library)
    local controller = self:require_boss_controller(controller_id)
    if not controller.ok then
        return controller
    end
    controller = controller.value
    local phases = {}
    local index
    for index = 1, #controller.phase_ids do
        local phase = self:require_boss_phase(controller.phase_ids[index])
        if not phase.ok then
            return phase
        end
        phases[index] = phase.value
    end
    local BossPhase = require 'wzx.domain.encounter.boss_phase'
    return BossPhase.create_runtime({
        controller = controller,
        phases = phases,
        boss_actor_id = boss_actor_id,
        move_library = move_library,
    })
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
