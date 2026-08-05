local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local DeriveSeed = require 'wzx.domain.common.derive_seed_v1'
local ParkMiller = require 'wzx.domain.common.park_miller_rng'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'
local LootCatalog = require 'wzx.config.schema.economy.loot_catalog'

local LootRoller = {}
local canonical_derive = CanonicalReceiptHashV1.derive
local get_metatable = getmetatable
local is_integer = TableShape.is_integer
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_content = RuntimeId.validate_content

local MAX_SEED = 2147483646
local REWARD_SEED_FIELDS = {
    { name = 'loot_id', type = 'STRING' },
    { name = 'source_occurrence_id', type = 'STRING' },
}
local SEED_HASH_FIELDS = {
    { name = 'loot_id', type = 'STRING' },
    { name = 'seed', type = 'INTEGER' },
    { name = 'source_occurrence_id', type = 'STRING' },
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

local function append_hit(hits, reward_id, group_id, entry_order)
    hits[#hits + 1] = {
        reward_id = reward_id,
        group_id = group_id,
        entry_order = entry_order,
    }
end

local function filter_available(entries, used_unique_keys, reroll_unique)
    if not reroll_unique then
        return entries
    end
    local filtered = {}
    local index
    for index = 1, #entries do
        local entry = entries[index]
        local key = entry.unique_key
        if key == nil or used_unique_keys[key] ~= true then
            filtered[#filtered + 1] = entry
        end
    end
    return filtered
end

local function roll_weighted_one(prng, group, entries, used_unique_keys)
    local reroll_unique = group.duplicate_policy == 'REROLL_UNIQUE'
    local candidate_cap = #entries
    if candidate_cap < 1 then
        candidate_cap = 1
    end

    local attempt
    for attempt = 1, candidate_cap do
        local available = filter_available(entries, used_unique_keys, reroll_unique)
        local total = group.no_drop_weight
        local index
        for index = 1, #available do
            total = total + available[index].weight
        end
        if total < 1 then
            -- Exhausted unique candidates: treat as no-drop without infinite loop.
            return result_ok(nil)
        end

        local sampled = prng:uniform(total)
        if not sampled.ok then
            return fail(
                EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
                'PRNG_UNIFORM_FAILED',
                {
                    group_id = group.id,
                    upper = total,
                    cause = sampled.error and sampled.error.code,
                }
            )
        end
        local r = sampled.value + 1

        if r <= group.no_drop_weight then
            return result_ok(nil)
        end

        local cursor = group.no_drop_weight
        for index = 1, #available do
            local entry = available[index]
            cursor = cursor + entry.weight
            if r <= cursor then
                if reroll_unique and entry.unique_key ~= nil then
                    if used_unique_keys[entry.unique_key] == true then
                        -- Should not happen after filter; continue attempts.
                        break
                    end
                    used_unique_keys[entry.unique_key] = true
                end
                return result_ok(entry)
            end
        end
        -- Fall through: no hit selected (should not happen when total covers r).
        return result_ok(nil)
    end

    return result_ok(nil)
end

local function roll_independent_each(prng, group, entries, used_unique_keys, hits)
    local reroll_unique = group.duplicate_policy == 'REROLL_UNIQUE'
    local index
    for index = 1, #entries do
        local entry = entries[index]
        if reroll_unique
            and entry.unique_key ~= nil
            and used_unique_keys[entry.unique_key] == true
        then
            -- Still consume a stream draw to keep positions stable across policy.
            local skipped = prng:uniform(10000)
            if not skipped.ok then
                return fail(
                    EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
                    'PRNG_UNIFORM_FAILED',
                    { group_id = group.id }
                )
            end
        else
            local sampled = prng:uniform(10000)
            if not sampled.ok then
                return fail(
                    EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
                    'PRNG_UNIFORM_FAILED',
                    { group_id = group.id }
                )
            end
            -- r ∈ [1, 10000]; success when r <= chance_bp (always consume once).
            local r = sampled.value + 1
            if r <= entry.chance_bp then
                append_hit(hits, entry.reward_id, group.id, entry.entry_order)
                if reroll_unique and entry.unique_key ~= nil then
                    used_unique_keys[entry.unique_key] = true
                end
            end
        end
    end
    return result_ok(true)
end

local function roll_guaranteed_all(group, entries, used_unique_keys, hits)
    local reroll_unique = group.duplicate_policy == 'REROLL_UNIQUE'
    local index
    for index = 1, #entries do
        local entry = entries[index]
        if reroll_unique
            and entry.unique_key ~= nil
            and used_unique_keys[entry.unique_key] == true
        then
            -- skip duplicate unique; no RNG consume for GUARANTEED_ALL
        else
            append_hit(hits, entry.reward_id, group.id, entry.entry_order)
            if reroll_unique and entry.unique_key ~= nil then
                used_unique_keys[entry.unique_key] = true
            end
        end
    end
    return result_ok(true)
end

local function roll_group(prng, group_bundle, used_unique_keys, hits)
    local group = group_bundle.group
    local entries = group_bundle.entries
    local group_roll
    for group_roll = 1, group.roll_count do
        if group.mode == 'WEIGHTED_ONE' then
            local selected = roll_weighted_one(prng, group, entries, used_unique_keys)
            if not selected.ok then
                return selected
            end
            if selected.value ~= nil then
                local entry = selected.value
                append_hit(hits, entry.reward_id, group.id, entry.entry_order)
            end
        elseif group.mode == 'INDEPENDENT_EACH' then
            local independent = roll_independent_each(
                prng,
                group,
                entries,
                used_unique_keys,
                hits
            )
            if not independent.ok then
                return independent
            end
        elseif group.mode == 'GUARANTEED_ALL' then
            local guaranteed = roll_guaranteed_all(
                group,
                entries,
                used_unique_keys,
                hits
            )
            if not guaranteed.ok then
                return guaranteed
            end
        else
            return fail(
                EconomyErrorCodes.ECONOMY_LOOT_CONFIG_INVALID,
                'UNKNOWN_GROUP_MODE',
                { group_id = group.id, mode = group.mode }
            )
        end
    end
    return result_ok(true)
end

--- Pure deterministic loot roll.
--- context: { root_seed = 1..MAX, source_occurrence_id = component }
--- returns { hits, seed_hash, config_version, loot_id, reward_context_id, seed }
function LootRoller.roll(loot_catalog, loot_id, context)
    if not LootCatalog.is_authority(loot_catalog) then
        return invalid('LOOT_CATALOG_AUTHORITY_REQUIRED', { field = 'loot_catalog' })
    end
    if type_value(context) ~= 'table' or get_metatable(context) ~= nil then
        return invalid('CONTEXT_TABLE_REQUIRED', { field = 'context' })
    end

    local checked_loot = validate_content(loot_id, 'loot_', 'loot_id')
    if not checked_loot.ok then
        return invalid('LOOT_ID_INVALID', { field = 'loot_id' })
    end

    local root_seed = raw_get(context, 'root_seed')
    if not is_integer(root_seed, 1, MAX_SEED) then
        return fail(
            EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
            'ROOT_SEED_INVALID',
            {
                field = 'root_seed',
                minimum = 1,
                maximum = MAX_SEED,
            }
        )
    end

    local source_occurrence_id = raw_get(context, 'source_occurrence_id')
    local checked_source = validate_component(
        source_occurrence_id,
        'source_occurrence_id'
    )
    if not checked_source.ok then
        return fail(
            EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
            'SOURCE_OCCURRENCE_ID_INVALID',
            { field = 'source_occurrence_id' }
        )
    end

    local resolved = loot_catalog:resolve_table(loot_id)
    if not resolved.ok then
        return resolved
    end
    local loot_table = resolved.value.loot_table
    local groups = resolved.value.groups

    local reward_context = canonical_derive(
        'reward_seed',
        REWARD_SEED_FIELDS,
        {
            loot_id = loot_id,
            source_occurrence_id = source_occurrence_id,
        }
    )
    if not reward_context.ok then
        return fail(
            EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
            'REWARD_CONTEXT_DERIVE_FAILED',
            {
                cause = reward_context.error and reward_context.error.code,
            }
        )
    end
    local reward_context_id = reward_context.value.receipt_id

    local derived = DeriveSeed.derive(root_seed, 'reward', reward_context_id)
    if not derived.ok then
        return fail(
            EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
            'REWARD_SEED_DERIVE_FAILED',
            {
                cause = derived.error and derived.error.code,
            }
        )
    end
    local seed = derived.value.seed

    local seed_hash_result = canonical_derive(
        'loot_seed_hash',
        SEED_HASH_FIELDS,
        {
            loot_id = loot_id,
            seed = seed,
            source_occurrence_id = source_occurrence_id,
        }
    )
    if not seed_hash_result.ok then
        return fail(
            EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
            'SEED_HASH_DERIVE_FAILED',
            {
                cause = seed_hash_result.error and seed_hash_result.error.code,
            }
        )
    end
    local seed_hash = seed_hash_result.value.digest

    local prng_created = ParkMiller.new(seed)
    if not prng_created.ok then
        return fail(
            EconomyErrorCodes.ECONOMY_LOOT_CONTEXT_INVALID,
            'PRNG_CREATE_FAILED',
            {
                seed = seed,
                cause = prng_created.error and prng_created.error.code,
            }
        )
    end
    local prng = prng_created.value

    local hits = {}
    if loot_table.guaranteed_reward_id ~= nil then
        append_hit(hits, loot_table.guaranteed_reward_id, nil, 0)
    end

    -- Batch-scoped unique keys (table roll pass + all groups).
    local used_unique_keys = {}
    local table_roll
    for table_roll = 1, loot_table.roll_count do
        local group_index
        for group_index = 1, #groups do
            local rolled = roll_group(
                prng,
                groups[group_index],
                used_unique_keys,
                hits
            )
            if not rolled.ok then
                return rolled
            end
        end
    end

    return result_ok({
        loot_id = loot_id,
        hits = hits,
        seed_hash = seed_hash,
        config_version = loot_table.config_version,
        reward_context_id = reward_context_id,
        seed = seed,
        draw_count = prng:get_state().draw_count,
    })
end

return LootRoller
