local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local EquipmentCatalog = require 'wzx.config.schema.equipment.catalog'
local EquipmentInstance = require 'wzx.domain.equipment.equipment_instance'

local CharacterLoadout = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local SLOT_FIELDS = {
    WEAPON = 'weapon_instance_id',
    HEAD = 'head_instance_id',
    BODY = 'body_instance_id',
    ACCESSORY = 'accessory_instance_id',
}
local SLOT_ORDER = {
    WEAPON = 1,
    HEAD = 2,
    BODY = 3,
    ACCESSORY = 4,
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.equipment.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID, reason, details)
end

local function copy_loadout(row)
    return {
        character_id = row.character_id,
        weapon_instance_id = row.weapon_instance_id,
        head_instance_id = row.head_instance_id,
        body_instance_id = row.body_instance_id,
        accessory_instance_id = row.accessory_instance_id,
        loadout_revision = row.loadout_revision,
    }
end

function CharacterLoadout.empty(character_id)
    local checked = validate_content(character_id, 'char_', 'character_id')
    if not checked.ok then
        return invalid('CHARACTER_ID_INVALID', { field = 'character_id' })
    end
    return result_ok({
        character_id = character_id,
        weapon_instance_id = nil,
        head_instance_id = nil,
        body_instance_id = nil,
        accessory_instance_id = nil,
        loadout_revision = 0,
    })
end

function CharacterLoadout.snapshot(state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('LOADOUT_REQUIRED', { field = 'state' })
    end
    if not TableShape.is_integer(raw_get(state, 'loadout_revision'), 0) then
        return invalid('LOADOUT_REVISION_INVALID', { field = 'loadout_revision' })
    end
    local checked = validate_content(raw_get(state, 'character_id'), 'char_', 'character_id')
    if not checked.ok then
        return invalid('CHARACTER_ID_INVALID', { field = 'character_id' })
    end
    return result_ok(copy_loadout(state))
end

local function resolve_instance_id(value, field)
    if value == nil then
        return result_ok(nil)
    end
    local content = validate_content(value, 'eqinst_', field)
    if content.ok then
        return result_ok(value)
    end
    local derived = validate_derived(value, field)
    if not derived.ok then
        return invalid('INSTANCE_ID_INVALID', { field = field })
    end
    return result_ok(value)
end

local function find_slot_of_instance(loadout, instance_id)
    local slot
    local field
    for slot, field in pairs(SLOT_FIELDS) do
        if loadout[field] == instance_id then
            return slot
        end
    end
    return nil
end

local function tag_set(tags)
    local set = {}
    local index
    for index = 1, #tags do
        set[tags[index]] = true
    end
    return set
end

local function check_compatibility(equipment, character_context)
    local character_level = raw_get(character_context, 'character_level')
    if not TableShape.is_integer(character_level, 1, 100) then
        return invalid('CHARACTER_LEVEL_INVALID', { field = 'character_level' })
    end
    if character_level < equipment.required_character_level then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_CHARACTER_LEVEL_TOO_LOW,
            'CHARACTER_LEVEL_TOO_LOW',
            {
                required = equipment.required_character_level,
                actual = character_level,
            }
        )
    end

    if equipment.slot == 'WEAPON' then
        local weapon_route = raw_get(character_context, 'weapon_route')
        if weapon_route ~= nil and weapon_route ~= equipment.weapon_route then
            return fail(
                EquipmentErrorCodes.EQUIPMENT_WEAPON_ROUTE_MISMATCH,
                'WEAPON_ROUTE_MISMATCH',
                {
                    required = equipment.weapon_route,
                    actual = weapon_route,
                }
            )
        end
    end

    local tags = raw_get(character_context, 'character_tags')
    if tags == nil then
        tags = {}
    end
    if type_value(tags) ~= 'table' or get_metatable(tags) ~= nil then
        return invalid('CHARACTER_TAGS_INVALID', { field = 'character_tags' })
    end
    if #equipment.allowed_character_tags > 0 then
        local have = tag_set(tags)
        local index
        for index = 1, #equipment.allowed_character_tags do
            local required = equipment.allowed_character_tags[index]
            if have[required] ~= true then
                return fail(
                    EquipmentErrorCodes.EQUIPMENT_TAG_REQUIRED,
                    'CHARACTER_TAG_REQUIRED',
                    { tag = required }
                )
            end
        end
    end

    return result_ok(true)
end

--- Equip an instance into its definition slot.
--- instances: map instance_id -> instance table (mutated owner fields on success copy)
--- character_context: { character_level, weapon_route?, character_tags? }
--- options: { replace = bool } default true (swap existing slot occupant)
function CharacterLoadout.equip(loadout, instances, catalog, character_context, instance_id, options)
    if not EquipmentCatalog.is_authority(catalog) then
        return invalid('CATALOG_AUTHORITY_REQUIRED', { field = 'catalog' })
    end
    local snap = CharacterLoadout.snapshot(loadout)
    if not snap.ok then
        return snap
    end
    loadout = snap.value
    options = options or {}
    local replace = options.replace
    if replace == nil then
        replace = true
    end

    if type_value(instances) ~= 'table' or get_metatable(instances) ~= nil then
        return invalid('INSTANCES_MAP_REQUIRED', { field = 'instances' })
    end
    if type_value(character_context) ~= 'table' or get_metatable(character_context) ~= nil then
        return invalid('CHARACTER_CONTEXT_REQUIRED', { field = 'character_context' })
    end
    local id_check = resolve_instance_id(instance_id, 'instance_id')
    if not id_check.ok then
        return id_check
    end

    local instance = instances[instance_id]
    if instance == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_NOT_FOUND,
            'INSTANCE_NOT_FOUND',
            { instance_id = instance_id }
        )
    end
    local instance_copy = EquipmentInstance.copy(instance)
    if not instance_copy.ok then
        return instance_copy
    end
    instance = instance_copy.value

    if instance.owner_character_id ~= nil
        and instance.owner_character_id ~= loadout.character_id
    then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_OWNED_BY_OTHER_CHARACTER,
            'OWNED_BY_OTHER',
            {
                owner_character_id = instance.owner_character_id,
                character_id = loadout.character_id,
            }
        )
    end

    local equipment = catalog:require_equipment(instance.equipment_id)
    if not equipment.ok then
        return equipment
    end
    equipment = equipment.value

    local compat = check_compatibility(equipment, character_context)
    if not compat.ok then
        return compat
    end

    local slot = equipment.slot
    local field = SLOT_FIELDS[slot]
    if field == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_INCOMPATIBLE,
            'SLOT_UNKNOWN',
            { slot = slot }
        )
    end

    -- Already equipped on this character in same slot.
    if loadout[field] == instance_id then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_ALREADY_EQUIPPED,
            'ALREADY_EQUIPPED',
            { instance_id = instance_id, slot = slot }
        )
    end

    -- Instance currently in another slot of this loadout.
    local existing_slot = find_slot_of_instance(loadout, instance_id)
    if existing_slot ~= nil and existing_slot ~= slot then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_INCOMPATIBLE,
            'INSTANCE_SLOT_MISMATCH',
            { instance_id = instance_id, slot = existing_slot }
        )
    end

    local replaced_instance_id = loadout[field]
    if replaced_instance_id ~= nil and not replace then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_SLOT_OCCUPIED,
            'SLOT_OCCUPIED',
            { slot = slot, instance_id = replaced_instance_id }
        )
    end

    local next_instances = {}
    local key
    local value
    for key, value in pairs(instances) do
        local copied = EquipmentInstance.copy(value)
        if not copied.ok then
            return copied
        end
        next_instances[key] = copied.value
    end

    if replaced_instance_id ~= nil then
        local previous = next_instances[replaced_instance_id]
        if previous == nil then
            return fail(
                EquipmentErrorCodes.EQUIPMENT_NOT_FOUND,
                'REPLACED_INSTANCE_MISSING',
                { instance_id = replaced_instance_id }
            )
        end
        previous.owner_character_id = nil
        previous.instance_revision = previous.instance_revision + 1
    end

    local next_instance = next_instances[instance_id]
    next_instance.owner_character_id = loadout.character_id
    next_instance.instance_revision = next_instance.instance_revision + 1

    local next_loadout = copy_loadout(loadout)
    next_loadout[field] = instance_id
    next_loadout.loadout_revision = loadout.loadout_revision + 1

    return result_ok({
        loadout = next_loadout,
        instances = next_instances,
        slot = slot,
        replaced_instance_id = replaced_instance_id,
    })
end

function CharacterLoadout.unequip(loadout, instances, slot)
    local snap = CharacterLoadout.snapshot(loadout)
    if not snap.ok then
        return snap
    end
    loadout = snap.value
    local field = SLOT_FIELDS[slot]
    if field == nil then
        return invalid('SLOT_INVALID', { field = 'slot', slot = slot })
    end
    if type_value(instances) ~= 'table' or get_metatable(instances) ~= nil then
        return invalid('INSTANCES_MAP_REQUIRED', { field = 'instances' })
    end

    local instance_id = loadout[field]
    if instance_id == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_SLOT_EMPTY,
            'SLOT_EMPTY',
            { slot = slot }
        )
    end

    local next_instances = {}
    local key
    local value
    for key, value in pairs(instances) do
        local copied = EquipmentInstance.copy(value)
        if not copied.ok then
            return copied
        end
        next_instances[key] = copied.value
    end

    local instance = next_instances[instance_id]
    if instance == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_NOT_FOUND,
            'INSTANCE_NOT_FOUND',
            { instance_id = instance_id }
        )
    end
    instance.owner_character_id = nil
    instance.instance_revision = instance.instance_revision + 1

    local next_loadout = copy_loadout(loadout)
    next_loadout[field] = nil
    next_loadout.loadout_revision = loadout.loadout_revision + 1

    return result_ok({
        loadout = next_loadout,
        instances = next_instances,
        slot = slot,
        unequipped_instance_id = instance_id,
    })
end

CharacterLoadout.SLOT_FIELDS = SLOT_FIELDS
CharacterLoadout.SLOT_ORDER = SLOT_ORDER

return CharacterLoadout
