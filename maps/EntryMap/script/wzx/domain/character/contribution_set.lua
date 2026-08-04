local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local TableShape = require 'wzx.domain.common.table_shape'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'
local ErrorCodes = require 'wzx.domain.character.error_codes'

local ContributionSet = {}

local function error_summary(err)
    local summary = {
        code = type(err) == 'table' and err.code or 'UNKNOWN',
        message_key = type(err) == 'table' and err.message_key or 'error.unknown',
        retryable = type(err) == 'table' and err.retryable == true,
    }
    if type(err) ~= 'table'
        or type(err.details) ~= 'table'
        or getmetatable(err.details) ~= nil
    then
        return summary
    end

    local details = {}
    local key
    local value
    for key, value in pairs(err.details) do
        if type(key) == 'string'
            and (type(value) == 'string'
                or type(value) == 'boolean'
                or TableShape.is_integer(value))
        then
            details[key] = value
        end
    end
    summary.details = details
    return summary
end

local function failure(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err(
        ErrorCodes.CHARACTER_CONTRIBUTION_INVALID,
        'error.character.contribution_invalid',
        false,
        details
    )
end

local function copy_strings(values)
    local copy = {}
    local index
    for index = 1, #values do
        copy[index] = values[index]
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
        condition_tags = copy_strings(value.condition_tags),
        stable_order_key = value.stable_order_key,
    }
end

local function validate_context_tags(context_tags)
    if getmetatable(context_tags) ~= nil or not Ordered.is_dense_array(context_tags) then
        return failure('CONTEXT_TAGS_DENSE_ARRAY_REQUIRED')
    end
    local previous
    local index
    for index = 1, #context_tags do
        local tag = context_tags[index]
        if type(tag) ~= 'string' or tag == '' then
            return failure('CONTEXT_TAG_INVALID', { index = index })
        end
        if previous ~= nil and not Ordered.bytewise_string_less(previous, tag) then
            return failure('CONTEXT_TAGS_STRICT_ASCENDING_REQUIRED', { index = index })
        end
        previous = tag
    end
    return Result.ok(true)
end

local function applies(contribution, context_set)
    local index
    for index = 1, #contribution.condition_tags do
        if not context_set[contribution.condition_tags[index]] then
            return false
        end
    end
    return true
end

function ContributionSet.prepare(contributions, context_tags)
    if getmetatable(contributions) ~= nil or not Ordered.is_dense_array(contributions) then
        return failure('CONTRIBUTIONS_DENSE_ARRAY_REQUIRED')
    end
    local context_result = validate_context_tags(context_tags)
    if not context_result.ok then
        return context_result
    end

    local copied = {}
    local seen_order_keys = {}
    local index
    for index = 1, #contributions do
        if type(contributions[index]) ~= 'table'
            or getmetatable(contributions[index]) ~= nil
        then
            return failure('CANONICAL_CONTRIBUTION_INVALID', { index = index })
        end
        if type(contributions[index].condition_tags) ~= 'table'
            or getmetatable(contributions[index].condition_tags) ~= nil
        then
            return failure('CANONICAL_CONTRIBUTION_INVALID', { index = index })
        end
        local validated = StatContribution.validate(contributions[index])
        if not validated.ok then
            return failure('CANONICAL_CONTRIBUTION_INVALID', {
                index = index,
                cause = error_summary(validated.error),
            })
        end
        local contribution = contributions[index]
        if contribution.operation == 'MULTIPLY_BP'
            and (contribution.value < 0 or contribution.value > 50000)
        then
            return failure('MULTIPLIER_OUT_OF_RANGE', {
                index = index,
                minimum = 0,
                maximum = 50000,
            })
        end
        if seen_order_keys[contribution.stable_order_key] then
            return Result.err(
                ErrorCodes.CHARACTER_CONTRIBUTION_INVALID,
                'error.character.contribution_invalid',
                false,
                {
                    reason = 'DUPLICATE_STABLE_ORDER_KEY',
                    index = index,
                    stable_order_key = contribution.stable_order_key,
                }
            )
        end
        seen_order_keys[contribution.stable_order_key] = true
        copied[index] = copy_contribution(contribution)
    end

    table.sort(copied, function(left, right)
        if left.priority ~= right.priority then
            return left.priority < right.priority
        end
        return Ordered.bytewise_string_less(
            left.stable_order_key,
            right.stable_order_key
        )
    end)

    local context_set = {}
    for index = 1, #context_tags do
        context_set[context_tags[index]] = true
    end
    local applicable = {}
    for index = 1, #copied do
        if applies(copied[index], context_set) then
            applicable[#applicable + 1] = copy_contribution(copied[index])
        end
    end

    return Result.ok({
        all = copied,
        applicable = applicable,
        context_tags = copy_strings(context_tags),
    })
end

return ContributionSet
