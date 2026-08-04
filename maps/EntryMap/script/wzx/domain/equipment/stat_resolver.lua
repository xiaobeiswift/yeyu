local DecimalInteger = require 'wzx.domain.common.decimal_integer'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local EquipmentCatalog = require 'wzx.config.schema.equipment.catalog'
local CharacterLoadout = require 'wzx.domain.equipment.character_loadout'

local StatResolver = {}
local get_metatable = getmetatable
local math_floor = math.floor
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local bytewise_string_less = Ordered.bytewise_string_less

local PRIORITY_BASE = 200
local PRIORITY_ENHANCE = 210
local PRIORITY_AFFIX = 220
local MAX_STAT_ABS = 2147483647

local SLOT_SEQUENCE = {
    { slot = 'WEAPON', field = 'weapon_instance_id', order = 1 },
    { slot = 'HEAD', field = 'head_instance_id', order = 2 },
    { slot = 'BODY', field = 'body_instance_id', order = 3 },
    { slot = 'ACCESSORY', field = 'accessory_instance_id', order = 4 },
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

local function check_overflow(value)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
        or value < -MAX_STAT_ABS
        or value > MAX_STAT_ABS
    then
        return false
    end
    return true
end

local function make_contribution(fields)
    local contribution = {
        source_type = 'EQUIPMENT',
        source_id = fields.source_id,
        target_stat = fields.target_stat,
        operation = fields.operation,
        value = fields.value,
        priority = fields.priority,
        condition_tags = {},
        stable_order_key = fields.stable_order_key,
    }
    local validated = StatContribution.validate(contribution)
    if not validated.ok then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_CONTRIBUTION_INVALID,
            'STAT_CONTRIBUTION_INVALID',
            {
                source_id = fields.source_id,
                target_stat = fields.target_stat,
            }
        )
    end
    return result_ok(contribution)
end

local function enhanced_flat(base_flat, rate_bp)
    -- B_enhanced = floor(B * (10000 + E_bp) / 10000)
    local numerator = base_flat * (10000 + rate_bp)
    if not check_overflow(numerator) and base_flat ~= 0 then
        -- Intermediate may exceed; recompute carefully with flooring division.
        -- For V1 fixtures rates and bases stay small; still guard.
        return fail(
            EquipmentErrorCodes.EQUIPMENT_STAT_OVERFLOW,
            'ENHANCE_NUMERATOR_OVERFLOW',
            { base_flat = base_flat, rate_bp = rate_bp }
        )
    end
    return result_ok(math_floor(numerator / 10000))
end

local function append_instance_contributions(out, instance, equipment, catalog, slot_order)
    local base_set = catalog:require_base_stat_set(equipment.base_stat_set_id)
    if not base_set.ok then
        return base_set
    end
    base_set = base_set.value

    local rate_bp = 0
    if instance.enhancement_level > 0 then
        local track = catalog:require_enhancement_track(equipment.enhancement_track_id)
        if not track.ok then
            return track
        end
        local row = track.value.level_rows[instance.enhancement_level]
        if row == nil then
            return fail(
                EquipmentErrorCodes.EQUIPMENT_CONFIG_BROKEN,
                'ENHANCE_LEVEL_ROW_MISSING',
                {
                    instance_id = instance.instance_id,
                    enhancement_level = instance.enhancement_level,
                }
            )
        end
        rate_bp = row.stat_rate_bp
    end

    local entry_index
    for entry_index = 1, #base_set.entries do
        local entry = base_set.entries[entry_index]
        local local_id = 'e' .. DecimalInteger.encode(entry.entry_order)

        if entry.flat_value ~= 0 then
            local enhanced = enhanced_flat(entry.flat_value, rate_bp)
            if not enhanced.ok then
                return enhanced
            end
            local b_enhanced = enhanced.value
            if not check_overflow(b_enhanced) then
                return fail(
                    EquipmentErrorCodes.EQUIPMENT_STAT_OVERFLOW,
                    'BASE_ENHANCED_OVERFLOW',
                    { stat_id = entry.stat_id }
                )
            end

            -- base component
            local base_key = table.concat({
                'equipment',
                DecimalInteger.encode(slot_order),
                instance.instance_id,
                '1',
                '0',
                entry.stat_id,
                'ADD_FLAT',
                local_id .. 'b',
            }, ':')
            local base_contrib = make_contribution({
                source_id = instance.instance_id .. ':base',
                target_stat = entry.stat_id,
                operation = 'ADD_FLAT',
                value = entry.flat_value,
                priority = PRIORITY_BASE,
                stable_order_key = base_key,
            })
            if not base_contrib.ok then
                return base_contrib
            end
            out[#out + 1] = base_contrib.value

            local enhance_delta = b_enhanced - entry.flat_value
            if enhance_delta ~= 0 then
                local enhance_key = table.concat({
                    'equipment',
                    DecimalInteger.encode(slot_order),
                    instance.instance_id,
                    '2',
                    '0',
                    entry.stat_id,
                    'ADD_FLAT',
                    local_id .. 'e',
                }, ':')
                local enhance_contrib = make_contribution({
                    source_id = instance.instance_id .. ':enhance',
                    target_stat = entry.stat_id,
                    operation = 'ADD_FLAT',
                    value = enhance_delta,
                    priority = PRIORITY_ENHANCE,
                    stable_order_key = enhance_key,
                })
                if not enhance_contrib.ok then
                    return enhance_contrib
                end
                out[#out + 1] = enhance_contrib.value
            end
        end

        if entry.rate_basis_points ~= 0 then
            local rate_key = table.concat({
                'equipment',
                DecimalInteger.encode(slot_order),
                instance.instance_id,
                '1',
                '0',
                entry.stat_id,
                'ADD_BP',
                local_id .. 'r',
            }, ':')
            local rate_contrib = make_contribution({
                source_id = instance.instance_id .. ':base',
                target_stat = entry.stat_id,
                operation = 'ADD_BP',
                value = entry.rate_basis_points,
                priority = PRIORITY_BASE,
                stable_order_key = rate_key,
            })
            if not rate_contrib.ok then
                return rate_contrib
            end
            out[#out + 1] = rate_contrib.value
        end
    end

    local affix_index
    for affix_index = 1, #(instance.affixes or {}) do
        local roll = instance.affixes[affix_index]
        local affix = catalog:require_affix(roll.affix_id)
        if not affix.ok then
            return affix
        end
        affix = affix.value
        local operation = affix.value_mode == 'RATE_BP' and 'ADD_BP' or 'ADD_FLAT'
        if not check_overflow(roll.rolled_value) then
            return fail(
                EquipmentErrorCodes.EQUIPMENT_STAT_OVERFLOW,
                'AFFIX_VALUE_OVERFLOW',
                { affix_id = roll.affix_id }
            )
        end
        local local_id = 'a' .. DecimalInteger.encode(roll.slot_index)
        local order_key = table.concat({
            'equipment',
            DecimalInteger.encode(slot_order),
            instance.instance_id,
            '3',
            DecimalInteger.encode(roll.slot_index),
            affix.stat_id,
            operation,
            local_id,
        }, ':')
        local contrib = make_contribution({
            source_id = instance.instance_id .. ':affix:' .. DecimalInteger.encode(roll.slot_index),
            target_stat = affix.stat_id,
            operation = operation,
            value = roll.rolled_value,
            priority = PRIORITY_AFFIX,
            stable_order_key = order_key,
        })
        if not contrib.ok then
            return contrib
        end
        out[#out + 1] = contrib.value
    end

    return result_ok(true)
end

local function compare_contributions(left, right)
    if left.priority ~= right.priority then
        return left.priority < right.priority
    end
    return bytewise_string_less(left.stable_order_key, right.stable_order_key)
end

--- Calculate canonical StatContribution[] for a character loadout.
function StatResolver.calculate_contributions(loadout, instances, catalog)
    if not EquipmentCatalog.is_authority(catalog) then
        return invalid('CATALOG_AUTHORITY_REQUIRED', { field = 'catalog' })
    end
    local snap = CharacterLoadout.snapshot(loadout)
    if not snap.ok then
        return snap
    end
    loadout = snap.value
    if type_value(instances) ~= 'table' or get_metatable(instances) ~= nil then
        return invalid('INSTANCES_MAP_REQUIRED', { field = 'instances' })
    end

    local contributions = {}
    local index
    for index = 1, #SLOT_SEQUENCE do
        local slot_info = SLOT_SEQUENCE[index]
        local instance_id = loadout[slot_info.field]
        if instance_id ~= nil then
            local instance = instances[instance_id]
            if instance == nil then
                return fail(
                    EquipmentErrorCodes.EQUIPMENT_NOT_FOUND,
                    'LOADOUT_INSTANCE_MISSING',
                    { instance_id = instance_id, slot = slot_info.slot }
                )
            end
            local equipment = catalog:require_equipment(instance.equipment_id)
            if not equipment.ok then
                return equipment
            end
            if equipment.value.slot ~= slot_info.slot then
                return fail(
                    EquipmentErrorCodes.EQUIPMENT_INCOMPATIBLE,
                    'LOADOUT_SLOT_MISMATCH',
                    {
                        instance_id = instance_id,
                        expected_slot = slot_info.slot,
                        actual_slot = equipment.value.slot,
                    }
                )
            end
            local appended = append_instance_contributions(
                contributions,
                instance,
                equipment.value,
                catalog,
                slot_info.order
            )
            if not appended.ok then
                return appended
            end
        end
    end

    table_sort(contributions, compare_contributions)

    local seen_keys = {}
    for index = 1, #contributions do
        local key = contributions[index].stable_order_key
        if seen_keys[key] then
            return fail(
                EquipmentErrorCodes.EQUIPMENT_CONTRIBUTION_INVALID,
                'DUPLICATE_STABLE_ORDER_KEY',
                { stable_order_key = key }
            )
        end
        seen_keys[key] = true
    end

    return result_ok(contributions)
end

return StatResolver
