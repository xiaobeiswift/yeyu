local Result = require 'wzx.domain.common.result'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'
local Validation = require 'wzx.config.schema.character.validation'

local TalentDefinition = {}

local SCHEMA = 'TalentDefinition'
local FIELDS = {
    id = true,
    schema_version = true,
    name_key = true,
    description_key = true,
    unlock_rule_id = true,
    contributions = true,
    combat_hook_ids = true,
    exclusive_group = true,
    tags = true,
    deprecated = true,
}

local function copy_array(value)
    local copy = {}
    local index
    for index = 1, #value do
        copy[index] = value[index]
    end
    return copy
end

local function copy_contribution(value)
    return {
        source_type = value.source_type,
        source_id = value.source_id,
        target_stat = value.target_stat,
        operation = value.operation,
        value = value.value,
        priority = value.priority,
        condition_tags = copy_array(value.condition_tags),
        stable_order_key = value.stable_order_key,
    }
end

local function validate_contributions(value)
    local err = Validation.dense_array(SCHEMA, 'contributions', value)
    if err ~= nil then
        return err
    end

    local previous_priority
    local previous_order_key
    local seen_order_keys = {}
    local index
    for index = 1, #value do
        if type(value[index]) ~= 'table' or getmetatable(value[index]) ~= nil then
            return Validation.invalid(
                SCHEMA,
                'contributions',
                'STAT_CONTRIBUTION_INVALID',
                { index = index }
            )
        end
        if type(value[index].condition_tags) ~= 'table'
            or getmetatable(value[index].condition_tags) ~= nil
        then
            return Validation.invalid(
                SCHEMA,
                'contributions',
                'STAT_CONTRIBUTION_INVALID',
                { index = index }
            )
        end
        local checked = StatContribution.validate(value[index])
        if not checked.ok then
            return Validation.invalid(
                SCHEMA,
                'contributions',
                'STAT_CONTRIBUTION_INVALID',
                {
                    index = index,
                    cause = Validation.error_summary(checked.error),
                }
            )
        end

        local contribution = value[index]
        if contribution.source_type ~= 'TALENT' then
            return Validation.invalid(
                SCHEMA,
                'contributions',
                'SOURCE_TYPE_MUST_BE_TALENT',
                { index = index }
            )
        end
        if contribution.operation == 'MULTIPLY_BP'
            and (contribution.value < 0 or contribution.value > 50000)
        then
            return Validation.invalid(
                SCHEMA,
                'contributions',
                'MULTIPLIER_OUT_OF_RANGE',
                { index = index, minimum = 0, maximum = 50000 }
            )
        end
        if seen_order_keys[contribution.stable_order_key] then
            return Validation.invalid(
                SCHEMA,
                'contributions',
                'STABLE_ORDER_KEY_DUPLICATE',
                { index = index }
            )
        end
        if previous_priority ~= nil
            and (previous_priority > contribution.priority
                or (previous_priority == contribution.priority
                    and not Validation.bytewise_string_less(
                        previous_order_key,
                        contribution.stable_order_key
                    )))
        then
            return Validation.invalid(
                SCHEMA,
                'contributions',
                'CONTRIBUTIONS_NOT_STRICTLY_ORDERED',
                { index = index }
            )
        end
        seen_order_keys[contribution.stable_order_key] = true
        previous_priority = contribution.priority
        previous_order_key = contribution.stable_order_key
    end
    return nil
end

function TalentDefinition.validate(value)
    local err = Validation.no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    err = Validation.first(
        Validation.content_id(SCHEMA, 'id', value.id, 'talent_'),
        Validation.integer(SCHEMA, 'schema_version', value.schema_version, 1),
        Validation.non_empty_string(SCHEMA, 'name_key', value.name_key),
        Validation.non_empty_string(SCHEMA, 'description_key', value.description_key),
        Validation.content_id(SCHEMA, 'unlock_rule_id', value.unlock_rule_id),
        Validation.sorted_unique_content_ids(
            SCHEMA,
            'combat_hook_ids',
            value.combat_hook_ids
        ),
        Validation.content_id(
            SCHEMA,
            'exclusive_group',
            value.exclusive_group,
            nil,
            true
        ),
        Validation.sorted_unique_strings(SCHEMA, 'tags', value.tags),
        Validation.boolean(SCHEMA, 'deprecated', value.deprecated)
    )
    if err ~= nil then
        return err
    end

    err = validate_contributions(value.contributions)
    if err ~= nil then
        return err
    end
    local contributions = {}
    local index
    for index = 1, #value.contributions do
        contributions[index] = copy_contribution(value.contributions[index])
    end
    return Result.ok({
        id = value.id,
        schema_version = value.schema_version,
        name_key = value.name_key,
        description_key = value.description_key,
        unlock_rule_id = value.unlock_rule_id,
        contributions = contributions,
        combat_hook_ids = copy_array(value.combat_hook_ids),
        exclusive_group = value.exclusive_group,
        tags = copy_array(value.tags),
        deprecated = value.deprecated,
    })
end

return TalentDefinition
