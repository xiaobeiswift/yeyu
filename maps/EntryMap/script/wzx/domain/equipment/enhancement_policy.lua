local Result = require 'wzx.domain.common.result'
local TableShape = require 'wzx.domain.common.table_shape'
local EquipmentErrorCodes = require 'wzx.domain.equipment.error_codes'
local EquipmentCatalog = require 'wzx.config.schema.equipment.catalog'
local EquipmentInstance = require 'wzx.domain.equipment.equipment_instance'

local EnhancementPolicy = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

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

--- Compute planned cost for enhancing instance by exactly +1 level.
--- Does not deduct currency/materials; returns planned_cost only.
function EnhancementPolicy.plan_enhance(instance, catalog)
    if not EquipmentCatalog.is_authority(catalog) then
        return invalid('CATALOG_AUTHORITY_REQUIRED', { field = 'catalog' })
    end
    if type_value(instance) ~= 'table' or get_metatable(instance) ~= nil then
        return invalid('INSTANCE_REQUIRED', { field = 'instance' })
    end
    local level = raw_get(instance, 'enhancement_level')
    if not TableShape.is_integer(level, 0, 15) then
        return invalid('ENHANCEMENT_LEVEL_INVALID', { field = 'enhancement_level' })
    end

    local equipment = catalog:require_equipment(instance.equipment_id)
    if not equipment.ok then
        return equipment
    end
    local track = catalog:require_enhancement_track(equipment.value.enhancement_track_id)
    if not track.ok then
        return track
    end
    track = track.value

    local next_level = level + 1
    if next_level > track.max_level then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_ENHANCE_MAX_LEVEL,
            'ENHANCE_MAX_LEVEL',
            {
                instance_id = instance.instance_id,
                current_level = level,
                max_level = track.max_level,
            }
        )
    end

    local row = track.level_rows[next_level]
    if row == nil then
        return fail(
            EquipmentErrorCodes.EQUIPMENT_CONFIG_BROKEN,
            'ENHANCE_ROW_MISSING',
            { target_level = next_level }
        )
    end

    return result_ok({
        from_level = level,
        to_level = next_level,
        planned_cost = {
            copper_cost = row.copper_cost,
            material_item_id = row.material_item_id,
            material_count = row.material_count,
            required_player_chapter = row.required_player_chapter,
        },
        stat_rate_bp = row.stat_rate_bp,
    })
end

--- Apply +1 enhancement offline. Records planned_cost; no economy debit.
function EnhancementPolicy.enhance(instance, catalog)
    local plan = EnhancementPolicy.plan_enhance(instance, catalog)
    if not plan.ok then
        return plan
    end
    local copied = EquipmentInstance.copy(instance)
    if not copied.ok then
        return copied
    end
    local next_instance = copied.value
    next_instance.enhancement_level = plan.value.to_level
    next_instance.instance_revision = next_instance.instance_revision + 1
    return result_ok({
        instance = next_instance,
        from_level = plan.value.from_level,
        to_level = plan.value.to_level,
        planned_cost = plan.value.planned_cost,
        stat_rate_bp = plan.value.stat_rate_bp,
    })
end

return EnhancementPolicy
