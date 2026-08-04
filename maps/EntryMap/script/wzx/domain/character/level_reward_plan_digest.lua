local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local ErrorCodes = require 'wzx.domain.character.error_codes'

local LevelRewardPlanDigest = {}
local canonical_derive = CanonicalReceiptHashV1.derive
local is_dense_array = Ordered.is_dense_array
local sorted_string_keys = Ordered.sorted_string_keys
local result_err = Result.err
local result_ok = Result.ok
local validate_content_id = RuntimeId.validate_content
local is_integer = TableShape.is_integer
local get_metatable = getmetatable
local raw_get = rawget
local tostring_value = tostring
local type_value = type

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_LEVEL = 100
local MAX_REWARD_REFS = 64
local ZERO_DIGEST = string.rep('0', 64)
local PLAN_FIELDS = {
    character_id = true,
    definition_version = true,
    curve_id = true,
    expected_revision = true,
    old_level = true,
    new_level = true,
    rewards = true,
}
local PLAN_FIELD_ORDER = {
    'character_id',
    'definition_version',
    'curve_id',
    'expected_revision',
    'old_level',
    'new_level',
    'rewards',
}
local REWARD_ROW_FIELDS = {
    reached_level = true,
    reward_ref = true,
}
local REWARD_ROW_FIELD_ORDER = {
    'reached_level',
    'reward_ref',
}
local STEP_DIGEST_FIELDS = {
    { name = 'ordinal', type = 'INTEGER' },
    { name = 'reached_level', type = 'INTEGER' },
    { name = 'reward_ref', type = 'STRING' },
    { name = 'previous_digest', type = 'STRING' },
}
local PLAN_DIGEST_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'definition_version', type = 'INTEGER' },
    { name = 'curve_id', type = 'STRING' },
    { name = 'expected_revision', type = 'INTEGER' },
    { name = 'old_level', type = 'INTEGER' },
    { name = 'new_level', type = 'INTEGER' },
    { name = 'reward_ref_count', type = 'INTEGER' },
    { name = 'chain_digest', type = 'STRING' },
}

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        ErrorCodes.CHARACTER_REWARD_PLAN_INVALID,
        'error.character.reward_plan_invalid',
        false,
        details
    )
end

local function exact_fields(value, allowed, field_order, path)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return invalid('PLAIN_TABLE_REQUIRED', { path = path })
    end
    local keys = sorted_string_keys(value)
    if not keys.ok then
        return invalid('STRING_FIELDS_REQUIRED', { path = path })
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        if not allowed[key] then
            return invalid('UNKNOWN_FIELD', {
                path = path,
                field = key,
            })
        end
    end
    for index = 1, #field_order do
        local field = field_order[index]
        if raw_get(value, field) == nil then
            return invalid('FIELD_REQUIRED', {
                path = path,
                field = field,
            })
        end
    end
    return nil
end

local function validate_plan(plan)
    local exact = exact_fields(plan, PLAN_FIELDS, PLAN_FIELD_ORDER, '$')
    if exact ~= nil then
        return exact
    end
    if not validate_content_id(
        raw_get(plan, 'character_id'),
        'char_',
        'character_id'
    ).ok then
        return invalid('CHARACTER_ID_INVALID', { field = 'character_id' })
    end
    if not is_integer(raw_get(plan, 'definition_version'), 1, MAX_SAFE_INTEGER) then
        return invalid('DEFINITION_VERSION_INVALID', {
            field = 'definition_version',
        })
    end
    if not validate_content_id(
        raw_get(plan, 'curve_id'),
        'curve_level_',
        'curve_id'
    ).ok then
        return invalid('CURVE_ID_INVALID', { field = 'curve_id' })
    end
    if not is_integer(raw_get(plan, 'expected_revision'), 0, MAX_SAFE_INTEGER) then
        return invalid('EXPECTED_REVISION_INVALID', {
            field = 'expected_revision',
        })
    end
    local old_level = raw_get(plan, 'old_level')
    local new_level = raw_get(plan, 'new_level')
    if not is_integer(old_level, 1, MAX_LEVEL) then
        return invalid('OLD_LEVEL_INVALID', { field = 'old_level' })
    end
    if not is_integer(new_level, old_level, MAX_LEVEL) then
        return invalid('NEW_LEVEL_INVALID', { field = 'new_level' })
    end

    local rewards = raw_get(plan, 'rewards')
    if type_value(rewards) ~= 'table'
        or get_metatable(rewards) ~= nil
        or not is_dense_array(rewards)
    then
        return invalid('PLAIN_DENSE_REWARD_ARRAY_REQUIRED', {
            field = 'rewards',
        })
    end
    if #rewards > MAX_REWARD_REFS then
        return invalid('REWARD_REF_COUNT_LIMIT_EXCEEDED', {
            field = 'rewards',
            actual = #rewards,
            maximum = MAX_REWARD_REFS,
        })
    end

    local previous_level
    local index
    for index = 1, #rewards do
        local row = raw_get(rewards, index)
        local row_path = 'rewards[' .. tostring_value(index) .. ']'
        exact = exact_fields(
            row,
            REWARD_ROW_FIELDS,
            REWARD_ROW_FIELD_ORDER,
            row_path
        )
        if exact ~= nil then
            return exact
        end
        local reached_level = raw_get(row, 'reached_level')
        if not is_integer(reached_level, old_level + 1, new_level) then
            return invalid('REACHED_LEVEL_OUTSIDE_TRANSITION', {
                path = row_path,
                field = 'reached_level',
                minimum = old_level + 1,
                maximum = new_level,
            })
        end
        if previous_level ~= nil and previous_level >= reached_level then
            return invalid('STRICT_ASCENDING_REACHED_LEVEL_REQUIRED', {
                path = row_path,
                field = 'reached_level',
            })
        end
        local reward_ref = raw_get(row, 'reward_ref')
        local checked_reward = validate_content_id(
            reward_ref,
            'reward_',
            row_path .. '.reward_ref'
        )
        if not checked_reward.ok then
            return invalid('REWARD_REF_INVALID', {
                path = row_path,
                field = 'reward_ref',
                cause_code = checked_reward.error.code,
            })
        end
        previous_level = reached_level
    end
    return result_ok(true)
end

function LevelRewardPlanDigest.derive(plan)
    local validated = validate_plan(plan)
    if not validated.ok then
        return validated
    end

    local rewards = raw_get(plan, 'rewards')
    if #rewards == 0 then
        return result_ok({ count = 0, digest = ZERO_DIGEST })
    end

    local chain_digest = ZERO_DIGEST
    local index
    for index = 1, #rewards do
        local row = raw_get(rewards, index)
        local step = canonical_derive(
            'character_level_reward_plan_step',
            STEP_DIGEST_FIELDS,
            {
                ordinal = index,
                reached_level = raw_get(row, 'reached_level'),
                reward_ref = raw_get(row, 'reward_ref'),
                previous_digest = chain_digest,
            }
        )
        if not step.ok then
            return invalid('STEP_DIGEST_DERIVATION_FAILED', {
                index = index,
                cause_code = step.error.code,
            })
        end
        chain_digest = step.value.digest
    end

    local derived = canonical_derive(
        'character_level_reward_plan',
        PLAN_DIGEST_FIELDS,
        {
            character_id = raw_get(plan, 'character_id'),
            definition_version = raw_get(plan, 'definition_version'),
            curve_id = raw_get(plan, 'curve_id'),
            expected_revision = raw_get(plan, 'expected_revision'),
            old_level = raw_get(plan, 'old_level'),
            new_level = raw_get(plan, 'new_level'),
            reward_ref_count = #rewards,
            chain_digest = chain_digest,
        }
    )
    if not derived.ok then
        return invalid('PLAN_DIGEST_DERIVATION_FAILED', {
            cause_code = derived.error.code,
        })
    end
    if derived.value.digest == ZERO_DIGEST then
        return invalid('RESERVED_ZERO_SENTINEL_COLLISION')
    end
    return result_ok({
        count = #rewards,
        digest = derived.value.digest,
    })
end

LevelRewardPlanDigest.MAX_REWARD_REFS = MAX_REWARD_REFS
LevelRewardPlanDigest.ZERO_DIGEST = ZERO_DIGEST

return LevelRewardPlanDigest
