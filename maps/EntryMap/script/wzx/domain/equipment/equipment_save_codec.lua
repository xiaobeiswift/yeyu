-- System 08 slot-4 equipment save codec.
-- Flat parallel tables only: instances, affixes, loadouts, empty tombstones.
-- Does not store derived combat stats or engine unit handles.

local Ordered = require 'wzx.domain.common.ordered'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local EquipmentSaveCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_dense_array = Ordered.is_dense_array
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived
local validate_source_reference = RuntimeId.validate_source_reference

local CURRENT_SCHEMA_VERSION = 1
local MAX_INSTANCES = 512
local MAX_AFFIXES_PER_INSTANCE = 6
local MAX_LOADOUTS = 64
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_ENHANCEMENT = 20

local ORIGIN_TYPES = {
    LOOT = true,
    QUEST = true,
    SHOP = true,
    CRAFT = true,
    ADMIN_MIGRATION = true,
}

local BUNDLE_FIELDS = {
    equipment_metadata = true,
    equipment_instance_rows = true,
    equipment_affix_rows = true,
    equipment_locked_affix_rows = true,
    character_loadout_rows = true,
    equipment_tombstone_rows = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    equipment_save_revision = true,
}
local INSTANCE_FIELDS = {
    instance_id = true,
    equipment_id = true,
    owner_character_id = true,
    enhancement_level = true,
    origin_type = true,
    origin_ref = true,
    roll_seed_hash = true,
    instance_revision = true,
    created_receipt_id = true,
}
local AFFIX_FIELDS = {
    instance_id = true,
    slot_index = true,
    affix_id = true,
    tier = true,
    rolled_value = true,
    roll_ordinal = true,
}
local LOCKED_FIELDS = {
    instance_id = true,
    slot_index = true,
}
local LOADOUT_FIELDS = {
    character_id = true,
    weapon_instance_id = true,
    head_instance_id = true,
    body_instance_id = true,
    accessory_instance_id = true,
    loadout_revision = true,
}
local SNAPSHOT_FIELDS = {
    equipment_save_revision = true,
    instances = true,
    loadouts = true,
    tombstones = true,
}

local function failure(code, message_key, reason, details)
    local copied = {}
    local key
    local value
    if type_value(details) == 'table' then
        for key, value in raw_next, details do
            copied[key] = value
        end
    end
    copied.reason = reason
    return result_err(code, message_key, false, copied)
end

local function invalid(reason, details)
    return failure(
        EquipmentErrorCodes.EQUIPMENT_ARGUMENT_INVALID,
        'error.equipment.save_invalid',
        reason,
        details
    )
end

local function no_unknown_fields(value, allowed, path)
    if type_value(value) ~= 'table' then
        return invalid('TABLE_REQUIRED', { field = path })
    end
    local key
    for key in raw_next, value do
        if type_value(key) ~= 'string' or not allowed[key] then
            return invalid('UNKNOWN_FIELD', {
                field = path == '$' and tostring(key)
                    or (path .. '.' .. tostring(key)),
            })
        end
    end
    return nil
end

local function validate_instance_id(value, field)
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

local function is_sha256(value)
    return type_value(value) == 'string'
        and #value == 64
        and value:match('^[0-9a-f]+$') ~= nil
end

local function copy_affixes(affixes)
    local copied = {}
    local index
    for index = 1, #affixes do
        local affix = affixes[index]
        copied[index] = {
            slot_index = affix.slot_index,
            affix_id = affix.affix_id,
            tier = affix.tier,
            rolled_value = affix.rolled_value,
            roll_ordinal = affix.roll_ordinal,
        }
    end
    return copied
end

local function copy_instance(instance)
    local locked = {}
    local index
    for index = 1, #(instance.locked_affix_slots or {}) do
        locked[index] = instance.locked_affix_slots[index]
    end
    return {
        instance_id = instance.instance_id,
        equipment_id = instance.equipment_id,
        owner_character_id = instance.owner_character_id,
        enhancement_level = instance.enhancement_level,
        affixes = copy_affixes(instance.affixes or {}),
        locked_affix_slots = locked,
        origin_type = instance.origin_type,
        origin_ref = instance.origin_ref,
        roll_seed_hash = instance.roll_seed_hash,
        instance_revision = instance.instance_revision or 0,
        created_receipt_id = instance.created_receipt_id,
    }
end

local function copy_loadout(loadout)
    return {
        character_id = loadout.character_id,
        weapon_instance_id = loadout.weapon_instance_id,
        head_instance_id = loadout.head_instance_id,
        body_instance_id = loadout.body_instance_id,
        accessory_instance_id = loadout.accessory_instance_id,
        loadout_revision = loadout.loadout_revision,
    }
end

local function instance_less(left, right)
    return bytewise_string_less(left.instance_id, right.instance_id)
end

local function affix_less(left, right)
    if left.instance_id ~= right.instance_id then
        return bytewise_string_less(left.instance_id, right.instance_id)
    end
    return left.slot_index < right.slot_index
end

local function loadout_less(left, right)
    return bytewise_string_less(left.character_id, right.character_id)
end

function EquipmentSaveCodec.encode(snapshot)
    local err = no_unknown_fields(snapshot, SNAPSHOT_FIELDS, '$')
    if err ~= nil then
        return err
    end
    if not is_integer(snapshot.equipment_save_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('EQUIPMENT_SAVE_REVISION_INVALID', {
            field = 'equipment_save_revision',
        })
    end
    if type_value(snapshot.instances) ~= 'table'
        or not is_dense_array(snapshot.instances)
    then
        return invalid('INSTANCES_DENSE_ARRAY_REQUIRED', { field = 'instances' })
    end
    if type_value(snapshot.loadouts) ~= 'table'
        or not is_dense_array(snapshot.loadouts)
    then
        return invalid('LOADOUTS_DENSE_ARRAY_REQUIRED', { field = 'loadouts' })
    end
    if type_value(snapshot.tombstones) ~= 'table'
        or not is_dense_array(snapshot.tombstones)
    then
        return invalid('TOMBSTONES_DENSE_ARRAY_REQUIRED', { field = 'tombstones' })
    end
    if #snapshot.instances > MAX_INSTANCES then
        return invalid('INSTANCE_LIMIT', { count = #snapshot.instances })
    end
    if #snapshot.loadouts > MAX_LOADOUTS then
        return invalid('LOADOUT_LIMIT', { count = #snapshot.loadouts })
    end
    -- Offline V1 keeps tombstones empty until destroy path lands.
    if #snapshot.tombstones > 0 then
        return invalid('TOMBSTONES_UNSUPPORTED', {
            count = #snapshot.tombstones,
        })
    end

    local instance_rows = {}
    local affix_rows = {}
    local locked_rows = {}
    local seen_instances = {}
    local index
    for index = 1, #snapshot.instances do
        local instance = snapshot.instances[index]
        if type_value(instance) ~= 'table' then
            return invalid('INSTANCE_ROW_REQUIRED', {
                field = 'instances[' .. tostring(index) .. ']',
            })
        end
        local id_check = validate_instance_id(instance.instance_id, 'instance_id')
        if not id_check.ok then
            return id_check
        end
        if seen_instances[instance.instance_id] then
            return invalid('DUPLICATE_INSTANCE_ID', {
                instance_id = instance.instance_id,
            })
        end
        seen_instances[instance.instance_id] = true
        local equip_check = validate_content(
            instance.equipment_id,
            'equip_',
            'equipment_id'
        )
        if not equip_check.ok then
            return invalid('EQUIPMENT_ID_INVALID', {
                instance_id = instance.instance_id,
            })
        end
        if instance.owner_character_id ~= nil then
            local owner = validate_content(
                instance.owner_character_id,
                'char_',
                'owner_character_id'
            )
            if not owner.ok then
                return invalid('OWNER_CHARACTER_ID_INVALID', {
                    instance_id = instance.instance_id,
                })
            end
        end
        if not is_integer(instance.enhancement_level, 0, MAX_ENHANCEMENT) then
            return invalid('ENHANCEMENT_LEVEL_INVALID', {
                instance_id = instance.instance_id,
            })
        end
        if ORIGIN_TYPES[instance.origin_type] ~= true then
            return invalid('ORIGIN_TYPE_INVALID', {
                instance_id = instance.instance_id,
            })
        end
        local ref = validate_source_reference(instance.origin_ref, 'origin_ref')
        if not ref.ok then
            return invalid('ORIGIN_REF_INVALID', {
                instance_id = instance.instance_id,
            })
        end
        if not is_sha256(instance.roll_seed_hash) then
            return invalid('ROLL_SEED_HASH_INVALID', {
                instance_id = instance.instance_id,
            })
        end
        if not is_integer(instance.instance_revision, 0, MAX_SAFE_INTEGER) then
            return invalid('INSTANCE_REVISION_INVALID', {
                instance_id = instance.instance_id,
            })
        end
        if instance.created_receipt_id ~= nil then
            local receipt = validate_derived(
                instance.created_receipt_id,
                'created_receipt_id'
            )
            if not receipt.ok then
                local content = validate_content(
                    instance.created_receipt_id,
                    'receipt_',
                    'created_receipt_id'
                )
                if not content.ok then
                    -- Accept opaque non-empty string receipts used offline.
                    if type_value(instance.created_receipt_id) ~= 'string'
                        or instance.created_receipt_id == ''
                    then
                        return invalid('CREATED_RECEIPT_ID_INVALID', {
                            instance_id = instance.instance_id,
                        })
                    end
                end
            end
        end
        if type_value(instance.affixes) ~= 'table'
            or not is_dense_array(instance.affixes)
        then
            return invalid('AFFIXES_REQUIRED', {
                instance_id = instance.instance_id,
            })
        end
        if #instance.affixes > MAX_AFFIXES_PER_INSTANCE then
            return invalid('AFFIX_LIMIT', {
                instance_id = instance.instance_id,
                count = #instance.affixes,
            })
        end
        if type_value(instance.locked_affix_slots) ~= 'table'
            or not is_dense_array(instance.locked_affix_slots)
        then
            return invalid('LOCKED_AFFIX_SLOTS_REQUIRED', {
                instance_id = instance.instance_id,
            })
        end

        instance_rows[#instance_rows + 1] = {
            instance_id = instance.instance_id,
            equipment_id = instance.equipment_id,
            owner_character_id = instance.owner_character_id,
            enhancement_level = instance.enhancement_level,
            origin_type = instance.origin_type,
            origin_ref = instance.origin_ref,
            roll_seed_hash = instance.roll_seed_hash,
            instance_revision = instance.instance_revision,
            created_receipt_id = instance.created_receipt_id,
        }

        local affix_index
        for affix_index = 1, #instance.affixes do
            local affix = instance.affixes[affix_index]
            if not is_integer(affix.slot_index, 1, MAX_AFFIXES_PER_INSTANCE) then
                return invalid('AFFIX_SLOT_INDEX_INVALID', {
                    instance_id = instance.instance_id,
                    index = affix_index,
                })
            end
            local affix_id = validate_content(affix.affix_id, 'affix_', 'affix_id')
            if not affix_id.ok then
                return invalid('AFFIX_ID_INVALID', {
                    instance_id = instance.instance_id,
                    index = affix_index,
                })
            end
            if not is_integer(affix.tier, 1, 10) then
                return invalid('AFFIX_TIER_INVALID', {
                    instance_id = instance.instance_id,
                    index = affix_index,
                })
            end
            if not is_integer(affix.rolled_value, -1000000, 1000000) then
                return invalid('AFFIX_VALUE_INVALID', {
                    instance_id = instance.instance_id,
                    index = affix_index,
                })
            end
            if not is_integer(affix.roll_ordinal, 0, MAX_SAFE_INTEGER) then
                return invalid('AFFIX_ROLL_ORDINAL_INVALID', {
                    instance_id = instance.instance_id,
                    index = affix_index,
                })
            end
            affix_rows[#affix_rows + 1] = {
                instance_id = instance.instance_id,
                slot_index = affix.slot_index,
                affix_id = affix.affix_id,
                tier = affix.tier,
                rolled_value = affix.rolled_value,
                roll_ordinal = affix.roll_ordinal,
            }
        end

        for affix_index = 1, #instance.locked_affix_slots do
            local slot_index = instance.locked_affix_slots[affix_index]
            if not is_integer(slot_index, 1, MAX_AFFIXES_PER_INSTANCE) then
                return invalid('LOCKED_SLOT_INDEX_INVALID', {
                    instance_id = instance.instance_id,
                    index = affix_index,
                })
            end
            locked_rows[#locked_rows + 1] = {
                instance_id = instance.instance_id,
                slot_index = slot_index,
            }
        end
    end

    local loadout_rows = {}
    local seen_loadouts = {}
    for index = 1, #snapshot.loadouts do
        local loadout = snapshot.loadouts[index]
        if type_value(loadout) ~= 'table' then
            return invalid('LOADOUT_ROW_REQUIRED', {
                field = 'loadouts[' .. tostring(index) .. ']',
            })
        end
        local character = validate_content(
            loadout.character_id,
            'char_',
            'character_id'
        )
        if not character.ok then
            return invalid('CHARACTER_ID_INVALID', {
                field = 'loadouts[' .. tostring(index) .. '].character_id',
            })
        end
        if seen_loadouts[loadout.character_id] then
            return invalid('DUPLICATE_LOADOUT_CHARACTER', {
                character_id = loadout.character_id,
            })
        end
        seen_loadouts[loadout.character_id] = true
        if not is_integer(loadout.loadout_revision, 0, MAX_SAFE_INTEGER) then
            return invalid('LOADOUT_REVISION_INVALID', {
                character_id = loadout.character_id,
            })
        end
        local slot_fields = {
            'weapon_instance_id',
            'head_instance_id',
            'body_instance_id',
            'accessory_instance_id',
        }
        local slot_index
        for slot_index = 1, #slot_fields do
            local field = slot_fields[slot_index]
            local value = loadout[field]
            if value ~= nil then
                local id_check = validate_instance_id(value, field)
                if not id_check.ok then
                    return id_check
                end
                if not seen_instances[value] then
                    return invalid('LOADOUT_INSTANCE_MISSING', {
                        character_id = loadout.character_id,
                        field = field,
                        instance_id = value,
                    })
                end
            end
        end
        loadout_rows[#loadout_rows + 1] = {
            character_id = loadout.character_id,
            weapon_instance_id = loadout.weapon_instance_id,
            head_instance_id = loadout.head_instance_id,
            body_instance_id = loadout.body_instance_id,
            accessory_instance_id = loadout.accessory_instance_id,
            loadout_revision = loadout.loadout_revision,
        }
    end

    table_sort(instance_rows, instance_less)
    table_sort(affix_rows, affix_less)
    table_sort(locked_rows, affix_less)
    table_sort(loadout_rows, loadout_less)

    return result_ok({
        equipment_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            equipment_save_revision = snapshot.equipment_save_revision,
        },
        equipment_instance_rows = instance_rows,
        equipment_affix_rows = affix_rows,
        equipment_locked_affix_rows = locked_rows,
        character_loadout_rows = loadout_rows,
        equipment_tombstone_rows = {},
    })
end

function EquipmentSaveCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    err = no_unknown_fields(
        bundle.equipment_metadata,
        METADATA_FIELDS,
        'equipment_metadata'
    )
    if err ~= nil then
        return err
    end
    local meta = bundle.equipment_metadata
    if meta.schema_version ~= CURRENT_SCHEMA_VERSION then
        return invalid('SCHEMA_VERSION_UNSUPPORTED', {
            schema_version = meta.schema_version,
        })
    end
    if not is_integer(meta.equipment_save_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('EQUIPMENT_SAVE_REVISION_INVALID', {
            field = 'equipment_save_revision',
        })
    end

    local lists = {
        'equipment_instance_rows',
        'equipment_affix_rows',
        'equipment_locked_affix_rows',
        'character_loadout_rows',
        'equipment_tombstone_rows',
    }
    local list_index
    for list_index = 1, #lists do
        local key = lists[list_index]
        if type_value(bundle[key]) ~= 'table' or not is_dense_array(bundle[key]) then
            return invalid('DENSE_ARRAY_REQUIRED', { field = key })
        end
    end
    if #bundle.equipment_tombstone_rows > 0 then
        return invalid('TOMBSTONES_UNSUPPORTED', {
            count = #bundle.equipment_tombstone_rows,
        })
    end
    if #bundle.equipment_instance_rows > MAX_INSTANCES then
        return invalid('INSTANCE_LIMIT', {
            count = #bundle.equipment_instance_rows,
        })
    end
    if #bundle.character_loadout_rows > MAX_LOADOUTS then
        return invalid('LOADOUT_LIMIT', {
            count = #bundle.character_loadout_rows,
        })
    end

    local affixes_by_instance = {}
    local locked_by_instance = {}
    local index
    for index = 1, #bundle.equipment_affix_rows do
        local row = bundle.equipment_affix_rows[index]
        err = no_unknown_fields(
            row,
            AFFIX_FIELDS,
            'equipment_affix_rows[' .. tostring(index) .. ']'
        )
        if err ~= nil then
            return err
        end
        local id_check = validate_instance_id(row.instance_id, 'instance_id')
        if not id_check.ok then
            return id_check
        end
        local list = affixes_by_instance[row.instance_id]
        if list == nil then
            list = {}
            affixes_by_instance[row.instance_id] = list
        end
        list[#list + 1] = {
            slot_index = row.slot_index,
            affix_id = row.affix_id,
            tier = row.tier,
            rolled_value = row.rolled_value,
            roll_ordinal = row.roll_ordinal,
        }
    end
    for index = 1, #bundle.equipment_locked_affix_rows do
        local row = bundle.equipment_locked_affix_rows[index]
        err = no_unknown_fields(
            row,
            LOCKED_FIELDS,
            'equipment_locked_affix_rows[' .. tostring(index) .. ']'
        )
        if err ~= nil then
            return err
        end
        local id_check = validate_instance_id(row.instance_id, 'instance_id')
        if not id_check.ok then
            return id_check
        end
        local list = locked_by_instance[row.instance_id]
        if list == nil then
            list = {}
            locked_by_instance[row.instance_id] = list
        end
        list[#list + 1] = row.slot_index
    end

    local instances = {}
    local seen_instances = {}
    for index = 1, #bundle.equipment_instance_rows do
        local row = bundle.equipment_instance_rows[index]
        err = no_unknown_fields(
            row,
            INSTANCE_FIELDS,
            'equipment_instance_rows[' .. tostring(index) .. ']'
        )
        if err ~= nil then
            return err
        end
        local id_check = validate_instance_id(row.instance_id, 'instance_id')
        if not id_check.ok then
            return id_check
        end
        if seen_instances[row.instance_id] then
            return invalid('DUPLICATE_INSTANCE_ID', {
                instance_id = row.instance_id,
            })
        end
        seen_instances[row.instance_id] = true
        local equip_check = validate_content(
            row.equipment_id,
            'equip_',
            'equipment_id'
        )
        if not equip_check.ok then
            return invalid('EQUIPMENT_ID_INVALID', {
                instance_id = row.instance_id,
            })
        end
        if row.owner_character_id ~= nil then
            local owner = validate_content(
                row.owner_character_id,
                'char_',
                'owner_character_id'
            )
            if not owner.ok then
                return invalid('OWNER_CHARACTER_ID_INVALID', {
                    instance_id = row.instance_id,
                })
            end
        end
        if not is_integer(row.enhancement_level, 0, MAX_ENHANCEMENT) then
            return invalid('ENHANCEMENT_LEVEL_INVALID', {
                instance_id = row.instance_id,
            })
        end
        if ORIGIN_TYPES[row.origin_type] ~= true then
            return invalid('ORIGIN_TYPE_INVALID', {
                instance_id = row.instance_id,
            })
        end
        local ref = validate_source_reference(row.origin_ref, 'origin_ref')
        if not ref.ok then
            return invalid('ORIGIN_REF_INVALID', {
                instance_id = row.instance_id,
            })
        end
        if not is_sha256(row.roll_seed_hash) then
            return invalid('ROLL_SEED_HASH_INVALID', {
                instance_id = row.instance_id,
            })
        end
        if not is_integer(row.instance_revision, 0, MAX_SAFE_INTEGER) then
            return invalid('INSTANCE_REVISION_INVALID', {
                instance_id = row.instance_id,
            })
        end
        local affixes = affixes_by_instance[row.instance_id] or {}
        if #affixes > MAX_AFFIXES_PER_INSTANCE then
            return invalid('AFFIX_LIMIT', {
                instance_id = row.instance_id,
                count = #affixes,
            })
        end
        table_sort(affixes, function(left, right)
            return left.slot_index < right.slot_index
        end)
        local locked = locked_by_instance[row.instance_id] or {}
        table_sort(locked)
        instances[#instances + 1] = {
            instance_id = row.instance_id,
            equipment_id = row.equipment_id,
            owner_character_id = row.owner_character_id,
            enhancement_level = row.enhancement_level,
            affixes = affixes,
            locked_affix_slots = locked,
            origin_type = row.origin_type,
            origin_ref = row.origin_ref,
            roll_seed_hash = row.roll_seed_hash,
            instance_revision = row.instance_revision,
            created_receipt_id = row.created_receipt_id,
        }
    end

    -- Orphan affix/locked rows fail closed.
    local instance_id
    for instance_id in raw_next, affixes_by_instance do
        if not seen_instances[instance_id] then
            return invalid('AFFIX_INSTANCE_MISSING', {
                instance_id = instance_id,
            })
        end
    end
    for instance_id in raw_next, locked_by_instance do
        if not seen_instances[instance_id] then
            return invalid('LOCKED_INSTANCE_MISSING', {
                instance_id = instance_id,
            })
        end
    end

    local loadouts = {}
    local seen_loadouts = {}
    for index = 1, #bundle.character_loadout_rows do
        local row = bundle.character_loadout_rows[index]
        err = no_unknown_fields(
            row,
            LOADOUT_FIELDS,
            'character_loadout_rows[' .. tostring(index) .. ']'
        )
        if err ~= nil then
            return err
        end
        local character = validate_content(
            row.character_id,
            'char_',
            'character_id'
        )
        if not character.ok then
            return invalid('CHARACTER_ID_INVALID', {
                field = 'character_loadout_rows[' .. tostring(index) .. '].character_id',
            })
        end
        if seen_loadouts[row.character_id] then
            return invalid('DUPLICATE_LOADOUT_CHARACTER', {
                character_id = row.character_id,
            })
        end
        seen_loadouts[row.character_id] = true
        if not is_integer(row.loadout_revision, 0, MAX_SAFE_INTEGER) then
            return invalid('LOADOUT_REVISION_INVALID', {
                character_id = row.character_id,
            })
        end
        local slot_fields = {
            'weapon_instance_id',
            'head_instance_id',
            'body_instance_id',
            'accessory_instance_id',
        }
        local slot_index
        for slot_index = 1, #slot_fields do
            local field = slot_fields[slot_index]
            local value = row[field]
            if value ~= nil then
                local id_check = validate_instance_id(value, field)
                if not id_check.ok then
                    return id_check
                end
                if not seen_instances[value] then
                    return invalid('LOADOUT_INSTANCE_MISSING', {
                        character_id = row.character_id,
                        field = field,
                        instance_id = value,
                    })
                end
            end
        end
        loadouts[#loadouts + 1] = {
            character_id = row.character_id,
            weapon_instance_id = row.weapon_instance_id,
            head_instance_id = row.head_instance_id,
            body_instance_id = row.body_instance_id,
            accessory_instance_id = row.accessory_instance_id,
            loadout_revision = row.loadout_revision,
        }
    end

    table_sort(instances, instance_less)
    table_sort(loadouts, loadout_less)

    local copied_instances = {}
    for index = 1, #instances do
        copied_instances[index] = copy_instance(instances[index])
    end
    local copied_loadouts = {}
    for index = 1, #loadouts do
        copied_loadouts[index] = copy_loadout(loadouts[index])
    end

    return result_ok({
        equipment_save_revision = meta.equipment_save_revision,
        instances = copied_instances,
        loadouts = copied_loadouts,
        tombstones = {},
    })
end

EquipmentSaveCodec.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION

return EquipmentSaveCodec
