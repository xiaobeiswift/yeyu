-- Pure domain temper (one-slot affix reroll). No economy debit.

local EquipmentCatalog = require 'wzx.config.schema.equipment.catalog'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local EquipmentInstance = require 'wzx.domain.equipment.equipment_instance'
local ParkMiller = require 'wzx.domain.common.park_miller_rng'
local Result = require 'wzx.domain.common.result'
local TableShape = require 'wzx.domain.common.table_shape'

local TemperPolicy = {}
local get_metatable = getmetatable
local is_integer = TableShape.is_integer
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

local MAX_SEED = 2147483646
local MAX_REROLL_ATTEMPTS = 8
local MAX_COPPER = 2000000000
local RARITY_RANK = {
    COMMON = 1,
    FINE = 2,
    RARE = 3,
    EPIC = 4,
    LEGEND = 5,
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

local function list_contains(values, needle)
    local index
    for index = 1, #values do
        if values[index] == needle then
            return true
        end
    end
    return false
end

local function find_affix_row(affixes, slot_index)
    local index
    for index = 1, #affixes do
        if affixes[index].slot_index == slot_index then
            return affixes[index], index
        end
    end
    return nil, nil
end

local function is_locked(locked_slots, slot_index)
    local index
    for index = 1, #(locked_slots or {}) do
        if locked_slots[index] == slot_index then
            return true
        end
    end
    return false
end

local function filter_candidates(pool, equipment, catalog, used_groups)
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
        return fail(
            EquipmentErrorCodes.EQUIPMENT_AFFIX_POOL_EMPTY,
            'AFFIX_POOL_WEIGHT_ZERO',
            { candidate_count = #candidates }
        )
    end
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

local function roll_value(rng, tier_row)
    local steps = math_floor((tier_row.max_value - tier_row.min_value) / tier_row.step) + 1
    local rolled = rng:uniform(steps)
    if not rolled.ok then
        return rolled
    end
    return result_ok(tier_row.min_value + rolled.value * tier_row.step)
end

local function same_affix(left, right)
    return left.affix_id == right.affix_id
        and left.tier == right.tier
        and left.rolled_value == right.rolled_value
end

local function build_used_groups(affixes, exclude_slot, catalog)
    local used = {}
    local index
    for index = 1, #affixes do
        local row = affixes[index]
        if row.slot_index ~= exclude_slot then
            local affix = catalog:require_affix(row.affix_id)
            if affix.ok and affix.value.exclusive_group ~= nil then
                used[affix.value.exclusive_group] = true
            end
        end
    end
    return used
end

local function compute_copper_cost(rule, old_ordinal)
    local growth_factor = rule.cost_growth_bp_per_ordinal
        * math.min(old_ordinal, rule.max_roll_ordinal_for_cost)
    local cost = math_floor(
        rule.copper_cost_base * (10000 + growth_factor) / 10000
    )
    if cost < 0 then
        cost = 0
    end
    if cost > MAX_COPPER then
        cost = MAX_COPPER
    end
    return cost
end

function TemperPolicy.plan_temper(instance, catalog, slot_index)
    if not EquipmentCatalog.is_authority(catalog) then
        return invalid('CATALOG_AUTHORITY_REQUIRED', { field = 'catalog' })
    end
    if type_value(instance) ~= 'table' or get_metatable(instance) ~= nil then
        return invalid('INSTANCE_REQUIRED', { field = 'instance' })
    end
    if not is_integer(slot_index, 1, 6) then
        return invalid('SLOT_INDEX_INVALID', { field = 'slot_index' })
    end

    local affixes = raw_get(instance, 'affixes') or {}
    local old_affix = find_affix_row(affixes, slot_index)
    if old_affix == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_AFFIX_SLOT_INVALID,
            'AFFIX_SLOT_EMPTY',
            {
                instance_id = instance.instance_id,
                slot_index = slot_index,
            }
        )
    end
    if is_locked(instance.locked_affix_slots, slot_index) then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_AFFIX_SLOT_INVALID,
            'AFFIX_SLOT_LOCKED',
            {
                instance_id = instance.instance_id,
                slot_index = slot_index,
            }
        )
    end

    local equipment = catalog:require_equipment(instance.equipment_id)
    if not equipment.ok then
        return equipment
    end
    equipment = equipment.value
    if equipment.temper_rule_id == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_TEMPER_UNAVAILABLE,
            'TEMPER_RULE_MISSING',
            { equipment_id = equipment.id }
        )
    end
    local rule = catalog:require_temper_rule(equipment.temper_rule_id)
    if not rule.ok then
        return rule
    end
    rule = rule.value
    if equipment.affix_pool_id == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_AFFIX_POOL_EMPTY,
            'AFFIX_POOL_MISSING',
            { equipment_id = equipment.id }
        )
    end
    local pool = catalog:require_affix_pool(equipment.affix_pool_id)
    if not pool.ok then
        return pool
    end
    pool = pool.value

    local used_groups = build_used_groups(affixes, slot_index, catalog)
    local candidates = filter_candidates(pool, equipment, catalog, used_groups)
    if #candidates < 1 then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_AFFIX_POOL_EMPTY,
            'AFFIX_POOL_EMPTY',
            {
                equipment_id = equipment.id,
                affix_pool_id = equipment.affix_pool_id,
                slot_index = slot_index,
            }
        )
    end

    local copper_cost = compute_copper_cost(rule, old_affix.roll_ordinal)
    return result_ok({
        slot_index = slot_index,
        old_affix = {
            slot_index = old_affix.slot_index,
            affix_id = old_affix.affix_id,
            tier = old_affix.tier,
            rolled_value = old_affix.rolled_value,
            roll_ordinal = old_affix.roll_ordinal,
        },
        planned_cost = {
            copper_cost = copper_cost,
            material_item_id = rule.material_item_id,
            material_count = rule.material_count,
        },
        temper_rule_id = rule.id,
        allow_same_result = rule.allow_same_result,
        candidate_count = #candidates,
        affix_pool_id = pool.id,
    })
end

local function roll_one(rng, candidates)
    local picked = weighted_pick(rng, candidates)
    if not picked.ok then
        return picked
    end
    local pick = picked.value
    local tier_row = pick.affix.tiers[pick.entry.tier]
    local value = roll_value(rng, tier_row)
    if not value.ok then
        return value
    end
    return result_ok({
        affix_id = pick.entry.affix_id,
        tier = pick.entry.tier,
        rolled_value = value.value,
        entry_order = pick.entry.entry_order,
    })
end

local function next_sorted_different(candidates, old_affix, preferred)
    -- Prefer first candidate (entry_order order) that differs from old triple.
    local index
    for index = 1, #candidates do
        local entry = candidates[index].entry
        local tier_row = candidates[index].affix.tiers[entry.tier]
        -- Use min_value as deterministic fallback value for forced pick.
        local candidate = {
            affix_id = entry.affix_id,
            tier = entry.tier,
            rolled_value = preferred and preferred.rolled_value or tier_row.min_value,
        }
        if not same_affix(candidate, old_affix) then
            return {
                affix_id = entry.affix_id,
                tier = entry.tier,
                rolled_value = tier_row.min_value,
                entry_order = entry.entry_order,
            }
        end
        -- Same affix_id+tier as old: try other value step if available.
        if entry.affix_id == old_affix.affix_id and entry.tier == old_affix.tier then
            local steps = math_floor(
                (tier_row.max_value - tier_row.min_value) / tier_row.step
            ) + 1
            local step_index
            for step_index = 0, steps - 1 do
                local value = tier_row.min_value + step_index * tier_row.step
                if value ~= old_affix.rolled_value then
                    return {
                        affix_id = entry.affix_id,
                        tier = entry.tier,
                        rolled_value = value,
                        entry_order = entry.entry_order,
                    }
                end
            end
        end
    end
    return nil
end

--- Apply one-slot temper with explicit seed. Records planned_cost; no economy debit.
function TemperPolicy.temper(instance, catalog, slot_index, seed)
    local plan = TemperPolicy.plan_temper(instance, catalog, slot_index)
    if not plan.ok then
        return plan
    end
    if not is_integer(seed, 1, MAX_SEED) then
        return invalid('SEED_INVALID', { field = 'seed' })
    end

    local equipment = catalog:require_equipment(instance.equipment_id)
    if not equipment.ok then
        return equipment
    end
    equipment = equipment.value
    local pool = catalog:require_affix_pool(equipment.affix_pool_id)
    if not pool.ok then
        return pool
    end
    pool = pool.value
    local used_groups = build_used_groups(
        instance.affixes or {},
        slot_index,
        catalog
    )
    local candidates = filter_candidates(pool, equipment, catalog, used_groups)
    if #candidates < 1 then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_AFFIX_POOL_EMPTY,
            'AFFIX_POOL_EMPTY',
            { slot_index = slot_index }
        )
    end

    local rng_result = ParkMiller.new(seed)
    if not rng_result.ok then
        return invalid('SEED_INVALID', { field = 'seed' })
    end
    local rng = rng_result.value
    local old_affix = plan.value.old_affix
    local allow_same = plan.value.allow_same_result == true

    local chosen = nil
    local attempt
    for attempt = 1, MAX_REROLL_ATTEMPTS do
        local rolled = roll_one(rng, candidates)
        if not rolled.ok then
            return rolled
        end
        if allow_same or not same_affix(rolled.value, old_affix) then
            chosen = rolled.value
            break
        end
        -- Keep last same roll if no other option later.
        chosen = rolled.value
    end

    if not allow_same and same_affix(chosen, old_affix) then
        local fallback = next_sorted_different(candidates, old_affix, chosen)
        if fallback ~= nil then
            chosen = fallback
        end
        -- If no different candidate exists, keep same result without extra cost.
    end

    local copied = EquipmentInstance.copy(instance)
    if not copied.ok then
        return copied
    end
    local next_instance = copied.value
    local _, affix_index = find_affix_row(next_instance.affixes, slot_index)
    next_instance.affixes[affix_index] = {
        slot_index = slot_index,
        affix_id = chosen.affix_id,
        tier = chosen.tier,
        rolled_value = chosen.rolled_value,
        roll_ordinal = old_affix.roll_ordinal + 1,
    }
    next_instance.instance_revision = next_instance.instance_revision + 1

    return result_ok({
        instance = next_instance,
        slot_index = slot_index,
        old_affix = old_affix,
        new_affix = next_instance.affixes[affix_index],
        planned_cost = plan.value.planned_cost,
        temper_rule_id = plan.value.temper_rule_id,
        seed = seed,
    })
end

return TemperPolicy
