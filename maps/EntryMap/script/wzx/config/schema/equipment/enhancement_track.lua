local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.equipment.validation'

local EnhancementTrack = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local SCHEMA = 'EnhancementTrack'
local ROW_SCHEMA = 'EnhancementLevelRow'
local FIELDS = {
    id = true,
    schema_version = true,
    level_rows = true,
}
local ROW_FIELDS = {
    target_level = true,
    stat_rate_bp = true,
    copper_cost = true,
    material_item_id = true,
    material_count = true,
    required_player_chapter = true,
}

local function validate_row(row, expected_level)
    local path = 'level_rows[' .. tostring(expected_level) .. ']'
    local err = validation_no_unknown_fields(ROW_SCHEMA, row, ROW_FIELDS)
    if err ~= nil then
        return err
    end
    local material_item_id = raw_get(row, 'material_item_id')
    local material_count = raw_get(row, 'material_count')
    if material_count == nil then
        material_count = 0
    end
    local required_player_chapter = raw_get(row, 'required_player_chapter')
    if required_player_chapter == nil then
        required_player_chapter = 0
    end
    err = validation_first(
        validation_integer(ROW_SCHEMA, path .. '.target_level', raw_get(row, 'target_level'), 1, 15),
        validation_integer(ROW_SCHEMA, path .. '.stat_rate_bp', raw_get(row, 'stat_rate_bp'), 0, 30000),
        validation_integer(ROW_SCHEMA, path .. '.copper_cost', raw_get(row, 'copper_cost'), 0, 2000000000),
        validation_content_id(
            ROW_SCHEMA,
            path .. '.material_item_id',
            material_item_id,
            'item_',
            true
        ),
        validation_integer(ROW_SCHEMA, path .. '.material_count', material_count, 0, 9999),
        validation_integer(
            ROW_SCHEMA,
            path .. '.required_player_chapter',
            required_player_chapter,
            0,
            99
        )
    )
    if err ~= nil then
        return err
    end
    if row.target_level ~= expected_level then
        return validation_invalid(ROW_SCHEMA, path .. '.target_level', 'LEVEL_SEQUENCE_INVALID', {
            expected = expected_level,
            actual = row.target_level,
        })
    end
    if material_item_id == nil and material_count ~= 0 then
        return validation_invalid(ROW_SCHEMA, path .. '.material_count', 'MATERIAL_COUNT_MUST_BE_ZERO')
    end
    if material_item_id ~= nil and material_count < 1 then
        return validation_invalid(ROW_SCHEMA, path .. '.material_count', 'MATERIAL_COUNT_REQUIRED')
    end
    return result_ok({
        target_level = row.target_level,
        stat_rate_bp = row.stat_rate_bp,
        copper_cost = row.copper_cost,
        material_item_id = material_item_id,
        material_count = material_count,
        required_player_chapter = required_player_chapter,
    })
end

function EnhancementTrack.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'enhance_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_dense_array(SCHEMA, 'level_rows', raw_get(value, 'level_rows'))
    )
    if err ~= nil then
        return err
    end
    if #value.level_rows < 1 or #value.level_rows > 15 then
        return validation_invalid(SCHEMA, 'level_rows', 'LEVEL_ROW_COUNT_OUT_OF_RANGE', {
            count = #value.level_rows,
        })
    end

    local level_rows = {}
    local previous_rate = nil
    local index
    for index = 1, #value.level_rows do
        local row = value.level_rows[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return validation_invalid(SCHEMA, 'level_rows[' .. tostring(index) .. ']', 'TABLE_REQUIRED')
        end
        local validated = validate_row(row, index)
        if not validated.ok then
            return validated
        end
        if previous_rate ~= nil and validated.value.stat_rate_bp < previous_rate then
            return validation_invalid(
                SCHEMA,
                'level_rows[' .. tostring(index) .. '].stat_rate_bp',
                'STAT_RATE_REGRESSED'
            )
        end
        previous_rate = validated.value.stat_rate_bp
        level_rows[index] = validated.value
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        level_rows = level_rows,
        max_level = #level_rows,
    })
end

return EnhancementTrack
