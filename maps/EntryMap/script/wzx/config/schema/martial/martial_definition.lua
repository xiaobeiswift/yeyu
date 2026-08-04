local Result = require 'wzx.domain.common.result'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'
local Validation = require 'wzx.config.schema.martial.validation'

local MartialDefinition = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_error_summary = Validation.error_summary
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string
local validation_sorted_unique_content_ids = Validation.sorted_unique_content_ids

local SCHEMA = 'MartialDefinition'
local LEVEL_SCHEMA = 'MartialLevelRow'
local FIELDS = {
    id = true,
    schema_version = true,
    rules_version = true,
    name_key = true,
    description_key = true,
    category = true,
    weapon_path = true,
    rarity = true,
    learn_policy = true,
    move_ids = true,
    compatibility_rule_id = true,
    lightness_traversal_profile_id = true,
    y3_visual_set_id = true,
    level_rows = true,
    acquisition_tags = true,
    deprecated = true,
}
local LEVEL_FIELDS = {
    level = true,
    required_character_level = true,
    cost_bundle_id = true,
    mastery_required = true,
    unlocked_move_ids = true,
    contributions = true,
}
local CATEGORIES = {
    ROUTINE = true,
    INTERNAL = true,
    LIGHTNESS = true,
}
local WEAPON_PATHS = {
    UNARMED = true,
    SWORD = true,
    BLADE = true,
    STAFF = true,
    NONE = true,
}
local RARITIES = {
    BASIC = true,
    REFINED = true,
    PROFOUND = true,
    MASTER = true,
}
local LEARN_POLICIES = {
    SINGLE_COPY_PER_CHARACTER = true,
    ACCOUNT_UNLOCK = true,
}

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

local function copy_contribution(value)
    local tags = {}
    local index
    for index = 1, #value.condition_tags do
        tags[index] = value.condition_tags[index]
    end
    return {
        source_type = value.source_type,
        source_id = value.source_id,
        target_stat = value.target_stat,
        operation = value.operation,
        value = value.value,
        priority = value.priority,
        condition_tags = tags,
        stable_order_key = value.stable_order_key,
    }
end

local function validate_contributions(contributions, martial_id, level)
    local err = validation_dense_array(LEVEL_SCHEMA, 'contributions', contributions)
    if err ~= nil then
        return err
    end
    local seen = {}
    local copied = {}
    local index
    for index = 1, #contributions do
        local contribution = contributions[index]
        if type_value(contribution) ~= 'table' or get_metatable(contribution) ~= nil then
            return validation_invalid(LEVEL_SCHEMA, 'contributions', 'STAT_CONTRIBUTION_INVALID', {
                index = index,
            })
        end
        if type_value(contribution.condition_tags) ~= 'table'
            or get_metatable(contribution.condition_tags) ~= nil
        then
            return validation_invalid(LEVEL_SCHEMA, 'contributions', 'STAT_CONTRIBUTION_INVALID', {
                index = index,
            })
        end
        local checked = StatContribution.validate(contribution)
        if not checked.ok then
            return validation_invalid(LEVEL_SCHEMA, 'contributions', 'STAT_CONTRIBUTION_INVALID', {
                index = index,
                cause = validation_error_summary(checked.error),
            })
        end
        if contribution.source_type ~= 'MARTIAL' then
            return validation_invalid(LEVEL_SCHEMA, 'contributions', 'SOURCE_TYPE_MUST_BE_MARTIAL', {
                index = index,
            })
        end
        if seen[contribution.stable_order_key] then
            return validation_invalid(LEVEL_SCHEMA, 'contributions', 'DUPLICATE_STABLE_ORDER_KEY', {
                index = index,
                stable_order_key = contribution.stable_order_key,
            })
        end
        seen[contribution.stable_order_key] = true
        copied[index] = copy_contribution(contribution)
    end
    return result_ok(copied)
end

local function validate_level_row(row, expected_level, martial_id, previous_required_level, previous_mastery)
    local path = 'level_rows[' .. tostring(expected_level) .. ']'
    local err = validation_no_unknown_fields(LEVEL_SCHEMA, row, LEVEL_FIELDS)
    if err ~= nil then
        return err
    end
    local mastery_required = raw_get(row, 'mastery_required')
    if mastery_required == nil then
        mastery_required = 0
    end
    local unlocked = raw_get(row, 'unlocked_move_ids')
    if unlocked == nil then
        unlocked = {}
    end
    local contributions = raw_get(row, 'contributions')
    if contributions == nil then
        contributions = {}
    end
    err = validation_first(
        validation_integer(LEVEL_SCHEMA, path .. '.level', raw_get(row, 'level'), 1, 10),
        validation_integer(
            LEVEL_SCHEMA,
            path .. '.required_character_level',
            raw_get(row, 'required_character_level'),
            1,
            100
        ),
        validation_content_id(
            LEVEL_SCHEMA,
            path .. '.cost_bundle_id',
            raw_get(row, 'cost_bundle_id'),
            'cost_',
            true
        ),
        validation_integer(LEVEL_SCHEMA, path .. '.mastery_required', mastery_required, 0),
        validation_dense_array(LEVEL_SCHEMA, path .. '.unlocked_move_ids', unlocked),
        validation_sorted_unique_content_ids(
            LEVEL_SCHEMA,
            path .. '.unlocked_move_ids',
            unlocked,
            'move_'
        )
    )
    if err ~= nil then
        return err
    end
    if row.level ~= expected_level then
        return validation_invalid(LEVEL_SCHEMA, path .. '.level', 'LEVEL_SEQUENCE_INVALID', {
            expected = expected_level,
            actual = row.level,
        })
    end
    if previous_required_level ~= nil
        and row.required_character_level < previous_required_level
    then
        return validation_invalid(
            LEVEL_SCHEMA,
            path .. '.required_character_level',
            'REQUIRED_CHARACTER_LEVEL_DECREASED'
        )
    end
    if previous_mastery ~= nil and mastery_required < previous_mastery then
        return validation_invalid(
            LEVEL_SCHEMA,
            path .. '.mastery_required',
            'MASTERY_REQUIRED_DECREASED'
        )
    end
    if expected_level >= 2 and row.cost_bundle_id == nil then
        -- Free upgrades are allowed when explicitly free via nil only for level 1.
        -- Levels 2-10 may also be free for first-slice fixtures (explicit nil = free).
    end

    local contribution_result = validate_contributions(contributions, martial_id, expected_level)
    if not contribution_result.ok then
        return contribution_result
    end

    return result_ok({
        level = row.level,
        required_character_level = row.required_character_level,
        cost_bundle_id = row.cost_bundle_id,
        mastery_required = mastery_required,
        unlocked_move_ids = copy_strings(unlocked),
        contributions = contribution_result.value,
    })
end

function MartialDefinition.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local category = raw_get(value, 'category')
    local weapon_path = raw_get(value, 'weapon_path')
    local acquisition_tags = raw_get(value, 'acquisition_tags')
    if acquisition_tags == nil then
        acquisition_tags = {}
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'martial_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1),
        validation_integer(SCHEMA, 'rules_version', raw_get(value, 'rules_version'), 1),
        validation_non_empty_string(SCHEMA, 'name_key', raw_get(value, 'name_key')),
        validation_non_empty_string(SCHEMA, 'description_key', raw_get(value, 'description_key')),
        validation_enum(SCHEMA, 'category', category, CATEGORIES),
        validation_enum(SCHEMA, 'weapon_path', weapon_path, WEAPON_PATHS),
        validation_enum(SCHEMA, 'rarity', raw_get(value, 'rarity'), RARITIES),
        validation_enum(SCHEMA, 'learn_policy', raw_get(value, 'learn_policy'), LEARN_POLICIES),
        validation_dense_array(SCHEMA, 'move_ids', raw_get(value, 'move_ids')),
        validation_sorted_unique_content_ids(SCHEMA, 'move_ids', raw_get(value, 'move_ids'), 'move_'),
        validation_content_id(
            SCHEMA,
            'compatibility_rule_id',
            raw_get(value, 'compatibility_rule_id'),
            'martial_compat_'
        ),
        validation_content_id(
            SCHEMA,
            'lightness_traversal_profile_id',
            raw_get(value, 'lightness_traversal_profile_id'),
            'traversal_profile_',
            true
        ),
        validation_content_id(
            SCHEMA,
            'y3_visual_set_id',
            raw_get(value, 'y3_visual_set_id'),
            'visual_'
        ),
        validation_dense_array(SCHEMA, 'level_rows', raw_get(value, 'level_rows')),
        validation_dense_array(SCHEMA, 'acquisition_tags', acquisition_tags),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end

    if category == 'ROUTINE' then
        if weapon_path == 'NONE' then
            return validation_invalid(SCHEMA, 'weapon_path', 'ROUTINE_WEAPON_PATH_REQUIRED')
        end
        if value.lightness_traversal_profile_id ~= nil then
            return validation_invalid(
                SCHEMA,
                'lightness_traversal_profile_id',
                'NON_LIGHTNESS_PROFILE_FORBIDDEN'
            )
        end
    elseif category == 'LIGHTNESS' then
        if weapon_path ~= 'NONE' then
            return validation_invalid(SCHEMA, 'weapon_path', 'NON_ROUTINE_WEAPON_PATH_MUST_BE_NONE')
        end
        if value.lightness_traversal_profile_id == nil then
            return validation_invalid(
                SCHEMA,
                'lightness_traversal_profile_id',
                'LIGHTNESS_PROFILE_REQUIRED'
            )
        end
    else
        if weapon_path ~= 'NONE' then
            return validation_invalid(SCHEMA, 'weapon_path', 'NON_ROUTINE_WEAPON_PATH_MUST_BE_NONE')
        end
        if value.lightness_traversal_profile_id ~= nil then
            return validation_invalid(
                SCHEMA,
                'lightness_traversal_profile_id',
                'NON_LIGHTNESS_PROFILE_FORBIDDEN'
            )
        end
    end

    if #value.move_ids < 1 then
        return validation_invalid(SCHEMA, 'move_ids', 'AT_LEAST_ONE_MOVE_REQUIRED')
    end
    if #value.level_rows ~= 10 then
        return validation_invalid(SCHEMA, 'level_rows', 'EXACTLY_TEN_LEVEL_ROWS_REQUIRED', {
            count = #value.level_rows,
        })
    end

    local level_rows = {}
    local previous_required = nil
    local previous_mastery = nil
    local unlocked_union = {}
    local index
    for index = 1, 10 do
        local row = value.level_rows[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return validation_invalid(SCHEMA, 'level_rows[' .. tostring(index) .. ']', 'TABLE_REQUIRED')
        end
        local validated = validate_level_row(
            row,
            index,
            value.id,
            previous_required,
            previous_mastery
        )
        if not validated.ok then
            return validated
        end
        level_rows[index] = validated.value
        previous_required = validated.value.required_character_level
        previous_mastery = validated.value.mastery_required

        -- Unlocked moves may only grow: every prior unlock must still appear.
        local current_set = {}
        local move_index
        for move_index = 1, #validated.value.unlocked_move_ids do
            current_set[validated.value.unlocked_move_ids[move_index]] = true
        end
        local previous_id
        for previous_id in pairs(unlocked_union) do
            if current_set[previous_id] ~= true then
                return validation_invalid(
                    SCHEMA,
                    'level_rows[' .. tostring(index) .. '].unlocked_move_ids',
                    'UNLOCKED_MOVES_REGRESSED',
                    { move_id = previous_id }
                )
            end
        end
        for move_index = 1, #validated.value.unlocked_move_ids do
            unlocked_union[validated.value.unlocked_move_ids[move_index]] = true
        end
    end

    return result_ok({
        id = value.id,
        schema_version = value.schema_version,
        rules_version = value.rules_version,
        name_key = value.name_key,
        description_key = value.description_key,
        category = category,
        weapon_path = weapon_path,
        rarity = value.rarity,
        learn_policy = value.learn_policy,
        move_ids = copy_strings(value.move_ids),
        compatibility_rule_id = value.compatibility_rule_id,
        lightness_traversal_profile_id = value.lightness_traversal_profile_id,
        y3_visual_set_id = value.y3_visual_set_id,
        level_rows = level_rows,
        acquisition_tags = copy_strings(acquisition_tags),
        deprecated = deprecated,
    })
end

return MartialDefinition
