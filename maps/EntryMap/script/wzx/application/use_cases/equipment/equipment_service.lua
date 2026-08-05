-- Offline application facade for system 08 equip/create + optional save bridge.

local CharacterLoadout = require 'wzx.domain.equipment.character_loadout'
local EquipmentCatalog = require 'wzx.config.schema.equipment.catalog'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local EquipmentInstance = require 'wzx.domain.equipment.equipment_instance'
local EquipmentSaveBridge = require 'wzx.application.use_cases.equipment.equipment_save_bridge'
local EquipmentSaveCodec = require 'wzx.domain.equipment.equipment_save_codec'
local Result = require 'wzx.domain.common.result'

local EquipmentService = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('equipment service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.equipment.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID, reason, details, false)
end

local function is_equipment_store(value)
    return type_value(value) == 'table'
        and type_value(value.get_instance) == 'function'
        and type_value(value.put_instance) == 'function'
        and type_value(value.get_loadout) == 'function'
        and type_value(value.get_instances_map) == 'function'
        and type_value(value.replace_instances_and_loadouts) == 'function'
end

local function maybe_persist_save(state, input)
    if type_value(input) == 'table' and raw_get(input, 'skip_save') == true then
        return result_ok({ status = 'SKIPPED', reason = 'SKIP_SAVE' })
    end
    if state.save_bridge == nil then
        return result_ok({ status = 'SKIPPED', reason = 'SAVE_BRIDGE_UNBOUND' })
    end
    local player_save_scope = type_value(input) == 'table'
        and raw_get(input, 'player_save_scope')
        or nil
    if player_save_scope == nil then
        return result_ok({
            status = 'SKIPPED',
            reason = 'PLAYER_SAVE_SCOPE_MISSING',
        })
    end
    local saved = state.save_bridge:persist_player_equipment({
        player_save_scope = player_save_scope,
        player_ref = raw_get(input, 'player_ref') or player_save_scope,
        request_id = raw_get(input, 'request_id') or 'request_equipment_save',
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
    if not saved.ok then
        return saved
    end
    return result_ok(saved.value)
end

local function loadouts_map_excluding(store, character_id)
    local exported = store:export_save_bundle()
    if not exported.ok then
        return exported
    end
    local decoded = EquipmentSaveCodec.decode(exported.value)
    if not decoded.ok then
        return decoded
    end
    local next_loadouts = {}
    local index
    for index = 1, #decoded.value.loadouts do
        local row = decoded.value.loadouts[index]
        if row.character_id ~= character_id then
            next_loadouts[row.character_id] = row
        end
    end
    return result_ok(next_loadouts)
end

function EquipmentService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    if not EquipmentCatalog.is_authority(catalog) then
        return invalid('CATALOG_AUTHORITY_REQUIRED', { field = 'catalog' })
    end
    local store = raw_get(options, 'store')
    if not is_equipment_store(store) then
        return invalid('EQUIPMENT_STORE_REQUIRED', { field = 'store' })
    end
    local save_bridge = raw_get(options, 'save_bridge')
    if save_bridge ~= nil
        and not EquipmentSaveBridge.is_authority(save_bridge)
    then
        return invalid('SAVE_BRIDGE_AUTHORITY_REQUIRED', {
            field = 'save_bridge',
        })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        store = store,
        save_bridge = save_bridge,
    }
    return result_ok(view)
end

function EquipmentService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

function Service:get_instance(instance_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return state.store:get_instance(instance_id)
end

function Service:get_loadout(character_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return state.store:get_loadout(character_id)
end

function Service:create_instance(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local draft = raw_get(input, 'draft')
    if draft == nil then
        local prepared = EquipmentInstance.prepare_instance(
            state.catalog,
            {
                equipment_id = raw_get(input, 'equipment_id'),
                origin_type = raw_get(input, 'origin_type'),
                origin_ref = raw_get(input, 'origin_ref'),
                creation_ordinal = raw_get(input, 'creation_ordinal') or 0,
                config_version = raw_get(input, 'config_version') or 1,
            },
            { seed = raw_get(input, 'seed') }
        )
        if not prepared.ok then
            return prepared
        end
        draft = prepared.value
    end

    local materialize = EquipmentInstance.from_draft(
        draft,
        raw_get(input, 'instance_id')
    )
    if not materialize.ok then
        return materialize
    end
    local instance = materialize.value
    if raw_get(input, 'created_receipt_id') ~= nil then
        instance.created_receipt_id = raw_get(input, 'created_receipt_id')
    end

    local put = state.store:put_instance(instance)
    if not put.ok then
        return put
    end
    local save = maybe_persist_save(state, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        instance = instance,
        store = put.value,
        save = save.value,
    })
end

function Service:equip(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local character_id = raw_get(input, 'character_id')
    local instance_id = raw_get(input, 'instance_id')
    local character_context = raw_get(input, 'character_context')
    if type_value(character_context) ~= 'table' then
        return invalid('CHARACTER_CONTEXT_REQUIRED', {
            field = 'character_context',
        })
    end

    local loadout = state.store:get_loadout(character_id)
    if not loadout.ok then
        return loadout
    end
    local instances = state.store:get_instances_map()
    if not instances.ok then
        return instances
    end

    local equipped = CharacterLoadout.equip(
        loadout.value,
        instances.value,
        state.catalog,
        character_context,
        instance_id,
        { replace = raw_get(input, 'replace') }
    )
    if not equipped.ok then
        return equipped
    end

    local next_loadouts = loadouts_map_excluding(state.store, character_id)
    if not next_loadouts.ok then
        return next_loadouts
    end
    next_loadouts.value[character_id] = equipped.value.loadout

    local replaced = state.store:replace_instances_and_loadouts(
        equipped.value.instances,
        next_loadouts.value
    )
    if not replaced.ok then
        return replaced
    end
    local save = maybe_persist_save(state, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        loadout = equipped.value.loadout,
        slot = equipped.value.slot,
        replaced_instance_id = equipped.value.replaced_instance_id,
        store = replaced.value,
        save = save.value,
    })
end

function Service:unequip(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local character_id = raw_get(input, 'character_id')
    local slot = raw_get(input, 'slot')
    local loadout = state.store:get_loadout(character_id)
    if not loadout.ok then
        return loadout
    end
    local instances = state.store:get_instances_map()
    if not instances.ok then
        return instances
    end

    local unequipped = CharacterLoadout.unequip(
        loadout.value,
        instances.value,
        slot
    )
    if not unequipped.ok then
        return unequipped
    end

    local next_loadouts = loadouts_map_excluding(state.store, character_id)
    if not next_loadouts.ok then
        return next_loadouts
    end
    next_loadouts.value[character_id] = unequipped.value.loadout

    local replaced = state.store:replace_instances_and_loadouts(
        unequipped.value.instances,
        next_loadouts.value
    )
    if not replaced.ok then
        return replaced
    end
    local save = maybe_persist_save(state, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        loadout = unequipped.value.loadout,
        slot = unequipped.value.slot,
        unequipped_instance_id = unequipped.value.unequipped_instance_id,
        store = replaced.value,
        save = save.value,
    })
end

return EquipmentService
