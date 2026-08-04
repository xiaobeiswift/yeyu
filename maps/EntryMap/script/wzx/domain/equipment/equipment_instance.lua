local DecimalInteger = require 'wzx.domain.common.decimal_integer'
local Ordered = require 'wzx.domain.common.ordered'
local ParkMiller = require 'wzx.domain.common.park_miller_rng'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Sha256 = require 'wzx.domain.common.sha256'
local TableShape = require 'wzx.domain.common.table_shape'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local EquipmentCatalog = require 'wzx.config.schema.equipment.catalog'

local EquipmentInstance = {}
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local table_concat = table.concat
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_source_reference = RuntimeId.validate_source_reference

local MAX_SEED = 2147483646
local ORIGIN_TYPES = {
    LOOT = true,
    QUEST = true,
    SHOP = true,
    CRAFT = true,
    ADMIN_MIGRATION = true,
}
local RARITY_RANK = {
    COMMON = 1,
    FINE = 2,
    RARE = 3,
    EPIC = 4,
    LEGEND = 5,
}
local RULES_VERSION = 1

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

local function list_contains(values, needle)
    local index
    for index = 1, #values do
        if values[index] == needle then
            return true
        end
    end
    return false
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

local function filter_pool_entries(pool, equipment, catalog, used_groups)
    local candidates = {}
    local entry_index
    for entry_index = 1, #pool.entries do
        local entry = pool.entries[entry_index]
        local rarity_ok = RARITY_RANK[equipment.rarity] >= RARITY_RANK[entry.rarity_min]
            and RARITY_RANK[equipment.rarity] <= RARITY_RANK[entry.rarity_max]
        if rarity_ok then
            local affix = catalog:require_affix(entry.affix_id)
            if affix.ok
                and entry.tier <= #affix.value.tiers
                and list_contains(affix.value.allowed_slots, equipment.slot)
                and list_contains(affix.value.allowed_routes, equipment.weapon_route)
            then
                local group = affix.value.exclusive_group
                if group == nil or used_groups[group] ~= true then
                    candidates[#candidates + 1] = {
                        entry = entry,
                        affix = affix.value,
                    }
                end
            end
        end
    end
    return candidates
end

local function weighted_pick(rng, candidates)
    local total_weight = 0
    local index
    for index = 1, #candidates do
        total_weight = total_weight + candidates[index].entry.weight
    end
    if total_weight < 1 then
        return nil
    end
    -- ParkMiller.uniform returns [0, upper_exclusive); map to [1, total_weight].
    local rolled = rng:uniform(total_weight)
    if not rolled.ok then
        return rolled
    end
    local target = rolled.value + 1
    local cumulative = 0
    for index = 1, #candidates do
        cumulative = cumulative + candidates[index].entry.weight
        if target <= cumulative then
            return result_ok(candidates[index])
        end
    end
    return result_ok(candidates[#candidates])
end

local function roll_affix_value(rng, tier_row)
    local steps = math_floor((tier_row.max_value - tier_row.min_value) / tier_row.step) + 1
    local rolled = rng:uniform(steps)
    if not rolled.ok then
        return rolled
    end
    return result_ok(tier_row.min_value + rolled.value * tier_row.step)
end

local function build_draft_hash(fields)
    local parts = {
        'equipment_draft_v1',
        fields.equipment_id,
        fields.origin_type,
        fields.origin_ref,
        DecimalInteger.encode(fields.creation_ordinal),
        DecimalInteger.encode(fields.config_version),
        DecimalInteger.encode(fields.rules_version),
        fields.roll_seed_hash,
    }
    local affix_index
    for affix_index = 1, #fields.affixes do
        local affix = fields.affixes[affix_index]
        parts[#parts + 1] = table_concat({
            DecimalInteger.encode(affix.slot_index),
            affix.affix_id,
            DecimalInteger.encode(affix.tier),
            DecimalInteger.encode(affix.rolled_value),
            DecimalInteger.encode(affix.roll_ordinal),
        }, ':')
    end
    local digest, hash_error = Sha256.hex(table_concat(parts, '\0'))
    if digest == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_DRAFT_INVALID,
            'DRAFT_HASH_FAILED',
            { reason = hash_error }
        )
    end
    return result_ok(digest)
end

local function seed_hash(seed)
    local digest, hash_error = Sha256.hex(
        'equipment_roll_seed_v1\0' .. DecimalInteger.encode(seed)
    )
    if digest == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_DRAFT_INVALID,
            'ROLL_SEED_HASH_FAILED',
            { reason = hash_error }
        )
    end
    return result_ok(digest)
end

--- Pure deterministic equipment instance draft.
--- source_spec: equipment_id, origin_type, origin_ref, creation_ordinal, config_version
--- seed_context: { seed = integer 1..MAX } explicit ParkMiller seed only
function EquipmentInstance.prepare_instance(catalog, source_spec, seed_context)
    if not EquipmentCatalog.is_authority(catalog) then
        return invalid('CATALOG_AUTHORITY_REQUIRED', { field = 'catalog' })
    end
    if type_value(source_spec) ~= 'table' or get_metatable(source_spec) ~= nil then
        return invalid('SOURCE_SPEC_REQUIRED', { field = 'source_spec' })
    end
    if type_value(seed_context) ~= 'table' or get_metatable(seed_context) ~= nil then
        return invalid('SEED_CONTEXT_REQUIRED', { field = 'seed_context' })
    end

    local equipment_id = raw_get(source_spec, 'equipment_id')
    local origin_type = raw_get(source_spec, 'origin_type')
    local origin_ref = raw_get(source_spec, 'origin_ref')
    local creation_ordinal = raw_get(source_spec, 'creation_ordinal')
    local config_version = raw_get(source_spec, 'config_version')
    local seed = raw_get(seed_context, 'seed')

    local checked = validate_content(equipment_id, 'equip_', 'equipment_id')
    if not checked.ok then
        return invalid('EQUIPMENT_ID_INVALID', { field = 'equipment_id' })
    end
    if type_value(origin_type) ~= 'string' or ORIGIN_TYPES[origin_type] ~= true then
        return invalid('ORIGIN_TYPE_INVALID', { field = 'origin_type' })
    end
    local ref_checked = validate_source_reference(origin_ref, 'origin_ref')
    if not ref_checked.ok then
        return invalid('ORIGIN_REF_INVALID', { field = 'origin_ref' })
    end
    if not TableShape.is_integer(creation_ordinal, 0, 1000000) then
        return invalid('CREATION_ORDINAL_INVALID', { field = 'creation_ordinal' })
    end
    if not TableShape.is_integer(config_version, 1, 1000000) then
        return invalid('CONFIG_VERSION_INVALID', { field = 'config_version' })
    end
    if not TableShape.is_integer(seed, 1, MAX_SEED) then
        return invalid('SEED_INVALID', { field = 'seed_context.seed' })
    end

    local equipment = catalog:require_equipment(equipment_id)
    if not equipment.ok then
        return equipment
    end
    equipment = equipment.value
    if equipment.deprecated then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_DEPRECATED,
            'DEPRECATED_NOT_CREATABLE',
            { equipment_id = equipment_id }
        )
    end

    local rng_result = ParkMiller.new(seed)
    if not rng_result.ok then
        return invalid('SEED_INVALID', { field = 'seed_context.seed' })
    end
    local rng = rng_result.value

    local affixes = {}
    local affix_count = 0
    if equipment.affix_count_max > 0 then
        local span = equipment.affix_count_max - equipment.affix_count_min + 1
        local count_roll = rng:uniform(span)
        if not count_roll.ok then
            return count_roll
        end
        affix_count = equipment.affix_count_min + count_roll.value
    end

    if affix_count > 0 then
        local pool = catalog:require_affix_pool(equipment.affix_pool_id)
        if not pool.ok then
            return pool
        end
        pool = pool.value
        local used_groups = {}
        local slot_index
        for slot_index = 1, affix_count do
            local candidates = filter_pool_entries(pool, equipment, catalog, used_groups)
            if #candidates < 1 then
                return fail(
                    EquipmentErrorCodes.EQUIPMENT_AFFIX_POOL_EMPTY,
                    'AFFIX_POOL_EMPTY',
                    {
                        equipment_id = equipment_id,
                        affix_pool_id = equipment.affix_pool_id,
                        slot_index = slot_index,
                    }
                )
            end
            local picked = weighted_pick(rng, candidates)
            if not picked.ok then
                return picked
            end
            local pick = picked.value
            local tier_row = pick.affix.tiers[pick.entry.tier]
            local value_roll = roll_affix_value(rng, tier_row)
            if not value_roll.ok then
                return value_roll
            end
            affixes[slot_index] = {
                slot_index = slot_index,
                affix_id = pick.entry.affix_id,
                tier = pick.entry.tier,
                rolled_value = value_roll.value,
                roll_ordinal = 0,
            }
            if pick.affix.exclusive_group ~= nil then
                used_groups[pick.affix.exclusive_group] = true
            end
        end
    end

    local roll_seed = seed_hash(seed)
    if not roll_seed.ok then
        return roll_seed
    end

    local draft_fields = {
        equipment_id = equipment_id,
        origin_type = origin_type,
        origin_ref = origin_ref,
        creation_ordinal = creation_ordinal,
        config_version = config_version,
        rules_version = RULES_VERSION,
        affixes = affixes,
        roll_seed_hash = roll_seed.value,
    }
    local draft_hash = build_draft_hash(draft_fields)
    if not draft_hash.ok then
        return draft_hash
    end

    return result_ok({
        draft_hash = draft_hash.value,
        equipment_id = equipment_id,
        enhancement_level = 0,
        affixes = copy_affixes(affixes),
        origin_type = origin_type,
        origin_ref = origin_ref,
        creation_ordinal = creation_ordinal,
        config_version = config_version,
        rules_version = RULES_VERSION,
        roll_seed_hash = roll_seed.value,
    })
end

--- Materialize a draft into a runtime instance (offline helper; no ownership).
function EquipmentInstance.from_draft(draft, instance_id)
    if type_value(draft) ~= 'table' or get_metatable(draft) ~= nil then
        return invalid('DRAFT_REQUIRED', { field = 'draft' })
    end
    local checked = validate_content(instance_id, 'eqinst_', 'instance_id')
    if not checked.ok then
        -- Allow derived-style instance ids used in offline tests.
        local derived = RuntimeId.validate_derived(instance_id, 'instance_id')
        if not derived.ok then
            return invalid('INSTANCE_ID_INVALID', { field = 'instance_id' })
        end
    end
    if type_value(raw_get(draft, 'equipment_id')) ~= 'string' then
        return invalid('DRAFT_EQUIPMENT_ID_REQUIRED', { field = 'draft.equipment_id' })
    end
    local affixes = raw_get(draft, 'affixes')
    if type_value(affixes) ~= 'table' or get_metatable(affixes) ~= nil or not is_dense_array(affixes) then
        return invalid('DRAFT_AFFIXES_REQUIRED', { field = 'draft.affixes' })
    end
    return result_ok({
        instance_id = instance_id,
        equipment_id = draft.equipment_id,
        owner_character_id = nil,
        enhancement_level = draft.enhancement_level or 0,
        affixes = copy_affixes(affixes),
        locked_affix_slots = {},
        origin_type = draft.origin_type,
        origin_ref = draft.origin_ref,
        roll_seed_hash = draft.roll_seed_hash,
        instance_revision = 0,
        created_receipt_id = nil,
    })
end

function EquipmentInstance.copy(instance)
    if type_value(instance) ~= 'table' or get_metatable(instance) ~= nil then
        return invalid('INSTANCE_REQUIRED', { field = 'instance' })
    end
    local locked = {}
    local locked_source = raw_get(instance, 'locked_affix_slots')
    if type_value(locked_source) == 'table' and is_dense_array(locked_source) then
        local index
        for index = 1, #locked_source do
            locked[index] = locked_source[index]
        end
    end
    return result_ok({
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
    })
end

return EquipmentInstance
