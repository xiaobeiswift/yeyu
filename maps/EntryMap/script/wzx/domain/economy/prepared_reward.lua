local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local RewardEntry = require 'wzx.domain.contracts.reward_entry'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'

local PreparedReward = {}
local bytewise_string_less = Ordered.bytewise_string_less
local canonical_derive = CanonicalReceiptHashV1.derive
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_floor = math.floor
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived
local reward_entry_validate = RewardEntry.validate

local ZERO_DIGEST = string.rep('0', 64)
local MAX_ENTRIES = 100
local ENTRY_TYPE_ORDER = {
    AFFINITY = 1,
    CHARACTER_XP = 2,
    CURRENCY = 3,
    EQUIPMENT = 4,
    ITEM = 5,
    MARTIAL_XP = 6,
    UNLOCK_FLAG = 7,
}

local CONTENT_FIELDS = {
    { name = 'entry_count', type = 'INTEGER' },
    { name = 'entries_digest', type = 'STRING' },
    { name = 'overflow_policy', type = 'STRING' },
    { name = 'config_version', type = 'INTEGER' },
}
local ENTRY_DIGEST_FIELDS = {
    { name = 'ordinal', type = 'INTEGER' },
    { name = 'entry_type', type = 'STRING' },
    { name = 'target_id', type = 'STRING' },
    { name = 'quantity', type = 'INTEGER' },
    { name = 'target_character_id', type = 'STRING' },
    { name = 'previous_digest', type = 'STRING' },
}
local PREPARED_ID_FIELDS = {
    { name = 'source_type', type = 'STRING' },
    { name = 'source_ref', type = 'STRING' },
    { name = 'source_occurrence_id', type = 'STRING' },
    { name = 'content_hash', type = 'STRING' },
    { name = 'config_version', type = 'INTEGER' },
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.economy.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(EconomyErrorCodes.ECONOMY_ARGUMENT_INVALID, reason, details)
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function entry_sort_key(entry)
    local type_order = ENTRY_TYPE_ORDER[entry.entry_type] or 99
    local target_character = entry.target_character_id or ''
    return {
        type_order = type_order,
        target_id = entry.target_id,
        target_character_id = target_character,
    }
end

local function entry_less(left, right)
    local left_key = entry_sort_key(left)
    local right_key = entry_sort_key(right)
    if left_key.type_order ~= right_key.type_order then
        return left_key.type_order < right_key.type_order
    end
    if left_key.target_id ~= right_key.target_id then
        return bytewise_string_less(left_key.target_id, right_key.target_id)
    end
    if left_key.target_character_id ~= right_key.target_character_id then
        return bytewise_string_less(
            left_key.target_character_id,
            right_key.target_character_id
        )
    end
    return false
end

local function merge_key(entry)
    if entry.entry_type == 'EQUIPMENT' then
        return nil
    end
    return entry.entry_type
        .. '\0'
        .. entry.target_id
        .. '\0'
        .. (entry.target_character_id or '')
end

local function copy_metadata(metadata)
    if metadata == nil then
        return {}
    end
    local copied = {}
    local key
    local value
    for key, value in raw_next, metadata do
        copied[key] = value
    end
    return copied
end

local function derive_entries_digest(entries)
    local digest = ZERO_DIGEST
    local index
    for index = 1, #entries do
        local entry = entries[index]
        local derived = canonical_derive('economy_prepared_entry', ENTRY_DIGEST_FIELDS, {
            ordinal = index,
            entry_type = entry.entry_type,
            target_id = entry.target_id,
            quantity = entry.quantity,
            target_character_id = entry.target_character_id or '',
            previous_digest = digest,
        })
        if not derived.ok then
            return derived
        end
        digest = derived.value.digest
    end
    return result_ok(digest)
end

function PreparedReward.normalize_currency_leaves(leaves, options)
    options = options or {}
    if type_value(leaves) ~= 'table'
        or get_metatable(leaves) ~= nil
        or not is_dense_array(leaves)
    then
        return invalid('LEAVES_TABLE_REQUIRED', { field = 'leaves' })
    end

    local default_character_id = raw_get(options, 'default_character_id')
    if default_character_id ~= nil then
        local checked = validate_content(default_character_id, 'char_', 'default_character_id')
        if not checked.ok then
            return invalid('DEFAULT_CHARACTER_ID_INVALID', {
                field = 'default_character_id',
            })
        end
    end

    local merged = {}
    local order = {}
    local index
    for index = 1, #leaves do
        local leaf = leaves[index]
        if type_value(leaf) ~= 'table' or get_metatable(leaf) ~= nil then
            return invalid('LEAF_TABLE_REQUIRED', {
                field = 'leaves[' .. tostring(index) .. ']',
            })
        end

        local entry_type = raw_get(leaf, 'entry_type')
        if entry_type ~= 'CURRENCY' then
            return fail(
                EconomyErrorCodes.ECONOMY_ENTRY_UNSUPPORTED,
                'ONLY_CURRENCY_SUPPORTED_IN_MINIMAL_SLICE',
                {
                    entry_type = entry_type,
                    target_id = raw_get(leaf, 'target_id'),
                    path = raw_get(leaf, 'path'),
                }
            )
        end

        local quantity_min = raw_get(leaf, 'quantity_min')
        local quantity_max = raw_get(leaf, 'quantity_max')
        local quantity = raw_get(leaf, 'quantity')
        if quantity == nil then
            if quantity_min == nil or quantity_max == nil then
                return invalid('QUANTITY_REQUIRED', {
                    field = 'leaves[' .. tostring(index) .. ']',
                })
            end
            if quantity_min ~= quantity_max then
                return fail(
                    EconomyErrorCodes.ECONOMY_ENTRY_UNSUPPORTED,
                    'RANDOM_QUANTITY_UNSUPPORTED_IN_MINIMAL_SLICE',
                    {
                        target_id = raw_get(leaf, 'target_id'),
                        quantity_min = quantity_min,
                        quantity_max = quantity_max,
                    }
                )
            end
            quantity = quantity_min
        end
        if not is_safe_integer(quantity, 1, 1000000000) then
            return invalid('QUANTITY_INVALID', {
                field = 'leaves[' .. tostring(index) .. '].quantity',
            })
        end

        local candidate = {
            entry_type = 'CURRENCY',
            target_id = raw_get(leaf, 'target_id'),
            quantity = quantity,
            target_character_id = raw_get(leaf, 'target_character_id'),
            metadata = copy_metadata(raw_get(leaf, 'metadata')),
            entry_order = index,
        }
        local validated = reward_entry_validate(candidate)
        if not validated.ok then
            return fail(
                EconomyErrorCodes.ECONOMY_PREPARED_INVALID,
                'REWARD_ENTRY_INVALID',
                {
                    field = 'leaves[' .. tostring(index) .. ']',
                    cause = validated.error and validated.error.details and validated.error.details.reason,
                }
            )
        end

        local key = merge_key(candidate)
        local existing = merged[key]
        if existing == nil then
            merged[key] = {
                entry_type = candidate.entry_type,
                target_id = candidate.target_id,
                quantity = candidate.quantity,
                target_character_id = candidate.target_character_id,
                metadata = candidate.metadata,
            }
            order[#order + 1] = key
        else
            local next_quantity = existing.quantity + candidate.quantity
            if next_quantity > 1000000000 then
                return invalid('QUANTITY_OVERFLOW', {
                    target_id = candidate.target_id,
                })
            end
            existing.quantity = next_quantity
        end
    end

    local entries = {}
    for index = 1, #order do
        local item = merged[order[index]]
        entries[#entries + 1] = {
            entry_type = item.entry_type,
            target_id = item.target_id,
            quantity = item.quantity,
            target_character_id = item.target_character_id,
            metadata = item.metadata,
            entry_order = #entries + 1,
        }
    end
    table_sort(entries, entry_less)
    for index = 1, #entries do
        entries[index].entry_order = index
    end
    if #entries > MAX_ENTRIES then
        return fail(
            EconomyErrorCodes.ECONOMY_PREPARED_INVALID,
            'ENTRY_LIMIT_EXCEEDED',
            { entry_count = #entries, max_entries = MAX_ENTRIES }
        )
    end
    return result_ok(entries)
end

function PreparedReward.build(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local source_type = raw_get(input, 'source_type')
    local source_ref = raw_get(input, 'source_ref')
    local source_occurrence_id = raw_get(input, 'source_occurrence_id')
    local config_version = raw_get(input, 'config_version') or 1
    local overflow_policy = raw_get(input, 'overflow_policy') or 'REJECT'
    local seed_hash = raw_get(input, 'seed_hash') or ZERO_DIGEST
    local entries = raw_get(input, 'entries')

    if type_value(source_type) ~= 'string'
        or source_type == ''
        or #source_type > 64
        or string.match(source_type, '^[A-Z][A-Z0-9_]*$') == nil
    then
        return invalid('SOURCE_TYPE_INVALID', { field = 'source_type' })
    end
    local checked_ref = validate_content(source_ref, nil, 'source_ref')
    if not checked_ref.ok then
        -- source_ref may be a content id without a fixed prefix in this slice.
        if type_value(source_ref) ~= 'string'
            or source_ref == ''
            or #source_ref > 96
            or string.match(source_ref, '^[a-z][a-z0-9_]*$') == nil
        then
            return invalid('SOURCE_REF_INVALID', { field = 'source_ref' })
        end
    end
    local checked_occurrence = validate_component(
        source_occurrence_id,
        'source_occurrence_id'
    )
    if not checked_occurrence.ok then
        return invalid('SOURCE_OCCURRENCE_ID_INVALID', {
            field = 'source_occurrence_id',
        })
    end
    if not is_safe_integer(config_version, 1, 1000) then
        return invalid('CONFIG_VERSION_INVALID', { field = 'config_version' })
    end
    if overflow_policy ~= 'REJECT' and overflow_policy ~= 'PENDING' then
        return invalid('OVERFLOW_POLICY_INVALID', { field = 'overflow_policy' })
    end
    if type_value(seed_hash) ~= 'string'
        or #seed_hash ~= 64
        or string.match(seed_hash, '^[a-f0-9]+$') == nil
    then
        return invalid('SEED_HASH_INVALID', { field = 'seed_hash' })
    end
    if type_value(entries) ~= 'table' or get_metatable(entries) ~= nil then
        return invalid('ENTRIES_REQUIRED', { field = 'entries' })
    end

    local normalized = PreparedReward.normalize_currency_leaves(entries, {
        default_character_id = raw_get(input, 'default_character_id'),
    })
    if not normalized.ok then
        return normalized
    end
    if #normalized.value == 0 then
        return fail(
            EconomyErrorCodes.ECONOMY_PREPARED_INVALID,
            'EMPTY_REWARD_FORBIDDEN',
            { source_ref = source_ref }
        )
    end

    local entries_digest = derive_entries_digest(normalized.value)
    if not entries_digest.ok then
        return entries_digest
    end
    local content = canonical_derive('economy_prepared_content', CONTENT_FIELDS, {
        entry_count = #normalized.value,
        entries_digest = entries_digest.value,
        overflow_policy = overflow_policy,
        config_version = config_version,
    })
    if not content.ok then
        return content
    end

    local prepared_id = canonical_derive('economy_prepared', PREPARED_ID_FIELDS, {
        source_type = source_type,
        source_ref = source_ref,
        source_occurrence_id = source_occurrence_id,
        content_hash = content.value.digest,
        config_version = config_version,
    })
    if not prepared_id.ok then
        return prepared_id
    end

    local entry_copies = {}
    local index
    for index = 1, #normalized.value do
        local entry = normalized.value[index]
        entry_copies[index] = {
            entry_type = entry.entry_type,
            target_id = entry.target_id,
            quantity = entry.quantity,
            target_character_id = entry.target_character_id,
            metadata = copy_metadata(entry.metadata),
            entry_order = entry.entry_order,
        }
    end

    return result_ok({
        prepared_id = prepared_id.value.receipt_id,
        source_type = source_type,
        source_ref = source_ref,
        source_occurrence_id = source_occurrence_id,
        config_version = config_version,
        seed_hash = seed_hash,
        entries = entry_copies,
        content_hash = content.value.digest,
        overflow_policy = overflow_policy,
    })
end

function PreparedReward.verify_content_hash(prepared)
    if type_value(prepared) ~= 'table' or get_metatable(prepared) ~= nil then
        return invalid('PREPARED_TABLE_REQUIRED', { field = 'prepared' })
    end
    local rebuilt = PreparedReward.build({
        source_type = raw_get(prepared, 'source_type'),
        source_ref = raw_get(prepared, 'source_ref'),
        source_occurrence_id = raw_get(prepared, 'source_occurrence_id'),
        config_version = raw_get(prepared, 'config_version'),
        overflow_policy = raw_get(prepared, 'overflow_policy'),
        seed_hash = raw_get(prepared, 'seed_hash'),
        entries = raw_get(prepared, 'entries'),
    })
    if not rebuilt.ok then
        return rebuilt
    end
    if rebuilt.value.content_hash ~= raw_get(prepared, 'content_hash')
        or rebuilt.value.prepared_id ~= raw_get(prepared, 'prepared_id')
    then
        return fail(
            EconomyErrorCodes.ECONOMY_PREPARED_STALE,
            'CONTENT_HASH_MISMATCH',
            {
                expected = prepared.content_hash,
                actual = rebuilt.value.content_hash,
            }
        )
    end
    return result_ok(rebuilt.value)
end

function PreparedReward.to_currency_rewards(prepared)
    local verified = PreparedReward.verify_content_hash(prepared)
    if not verified.ok then
        return verified
    end
    local rewards = {}
    local index
    for index = 1, #verified.value.entries do
        local entry = verified.value.entries[index]
        rewards[index] = {
            currency_id = entry.target_id,
            amount = entry.quantity,
        }
    end
    return result_ok(rewards)
end

function PreparedReward.derive_request_hash(prepared, purpose_type, purpose_ref)
    local verified = PreparedReward.verify_content_hash(prepared)
    if not verified.ok then
        return verified
    end
    if type_value(purpose_type) ~= 'string'
        or purpose_type == ''
        or string.match(purpose_type, '^[A-Z][A-Z0-9_]*$') == nil
    then
        return invalid('PURPOSE_TYPE_INVALID', { field = 'purpose_type' })
    end
    if type_value(purpose_ref) ~= 'string'
        or purpose_ref == ''
        or #purpose_ref > 96
    then
        return invalid('PURPOSE_REF_INVALID', { field = 'purpose_ref' })
    end
    return canonical_derive('economy_grant_request', {
        { name = 'prepared_id', type = 'STRING' },
        { name = 'content_hash', type = 'STRING' },
        { name = 'purpose_type', type = 'STRING' },
        { name = 'purpose_ref', type = 'STRING' },
        { name = 'source_occurrence_id', type = 'STRING' },
    }, {
        prepared_id = verified.value.prepared_id,
        content_hash = verified.value.content_hash,
        purpose_type = purpose_type,
        purpose_ref = purpose_ref,
        source_occurrence_id = verified.value.source_occurrence_id,
    })
end

return PreparedReward
