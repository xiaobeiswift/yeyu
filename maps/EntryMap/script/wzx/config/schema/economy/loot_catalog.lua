local ErrorCodes = require 'wzx.domain.common.error_codes'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.economy.validation'
local LootTable = require 'wzx.config.schema.economy.loot_table'
local LootGroup = require 'wzx.config.schema.economy.loot_group'
local LootEntry = require 'wzx.config.schema.economy.loot_entry'

local Catalog = {}
local bytewise_string_less = Ordered.bytewise_string_less
local error_value = error
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local schema_registry_new = SchemaRegistry.new
local set_metatable = setmetatable
local table_sort = table.sort
local tostring_value = tostring
local type_value = type
local validate_content_id = RuntimeId.validate_content
local validation_dense_array = Validation.dense_array
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local CatalogView = {}
CatalogView.__index = CatalogView
CatalogView.__newindex = function()
    error_value('loot catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'LootCatalog'
local MAX_WEIGHT_TOTAL = 2000000000
local COLLECTION_ORDER = {
    'loot_tables',
    'loot_groups',
    'loot_entries',
}
local COLLECTION_FIELDS = {
    loot_tables = true,
    loot_groups = true,
    loot_entries = true,
}

local function invalid(field, reason, details)
    return validation_invalid(SCHEMA, field, reason, details)
end

local function catalog_error(code, message_key, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(code, message_key, false, details)
end

local function validate_source(source)
    if type_value(source) ~= 'table' or get_metatable(source) ~= nil then
        return invalid('$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, source, COLLECTION_FIELDS)
    if err ~= nil then
        return err
    end

    local index
    for index = 1, #COLLECTION_ORDER do
        local collection_name = COLLECTION_ORDER[index]
        err = validation_dense_array(
            SCHEMA,
            collection_name,
            source[collection_name]
        )
        if err ~= nil then
            return err
        end
    end
    return result_ok(true)
end

local function build_registry(registry_name, id_field, normalize_entry, entries)
    local created = schema_registry_new({
        registry_name = registry_name,
        id_field = id_field,
        normalize_entry = normalize_entry,
    })
    if not created.ok then
        return created
    end
    local registry = created.value
    local index
    for index = 1, #entries do
        local registered = registry:register(entries[index])
        if not registered.ok then
            return registered
        end
    end
    return result_ok(registry)
end

local function entry_less(left, right)
    if left.entry_order ~= right.entry_order then
        return left.entry_order < right.entry_order
    end
    return bytewise_string_less(left.reward_id, right.reward_id)
end

local function index_entries(raw_entries, group_registry)
    if not is_dense_array(raw_entries) then
        return invalid('loot_entries', 'DENSE_ARRAY_REQUIRED')
    end

    local by_group = {}
    local order_keys = {}
    local index
    for index = 1, #raw_entries do
        local validated = LootEntry.validate(raw_entries[index])
        if not validated.ok then
            local details = validated.error and validated.error.details or {}
            details.entry_index = index
            return result_err(
                validated.error.code,
                validated.error.message_key,
                false,
                details
            )
        end
        local entry = validated.value
        if not group_registry:contains(entry.group_id) then
            return invalid(
                'loot_entries[' .. tostring_value(index) .. '].group_id',
                'REFERENCE_NOT_FOUND',
                {
                    group_id = entry.group_id,
                    referenced_collection = 'loot_groups',
                }
            )
        end
        local bucket = by_group[entry.group_id]
        if bucket == nil then
            bucket = {}
            by_group[entry.group_id] = bucket
            order_keys[#order_keys + 1] = entry.group_id
        end
        bucket[#bucket + 1] = entry
    end

    local group_index
    for group_index = 1, #order_keys do
        local group_id = order_keys[group_index]
        local entries = by_group[group_id]
        table_sort(entries, entry_less)
        local seen_orders = {}
        local entry_index
        for entry_index = 1, #entries do
            local entry = entries[entry_index]
            if seen_orders[entry.entry_order] then
                return invalid(
                    'loot_entries',
                    'DUPLICATE_ENTRY_ORDER',
                    {
                        group_id = group_id,
                        entry_order = entry.entry_order,
                    }
                )
            end
            seen_orders[entry.entry_order] = true
        end
    end

    return result_ok(by_group)
end

local function validate_group_entries(group, entries)
    local mode = group.mode
    local path_prefix = 'loot_groups[' .. group.id .. ']'
    entries = entries or {}

    if mode == 'WEIGHTED_ONE' then
        local total = group.no_drop_weight
        local index
        for index = 1, #entries do
            local entry = entries[index]
            if entry.weight == nil then
                return invalid(
                    path_prefix .. '.entries',
                    'WEIGHT_REQUIRED_FOR_WEIGHTED_ONE',
                    {
                        group_id = group.id,
                        entry_order = entry.entry_order,
                    }
                )
            end
            if entry.chance_bp ~= nil then
                return invalid(
                    path_prefix .. '.entries',
                    'CHANCE_BP_FORBIDDEN_FOR_WEIGHTED_ONE',
                    {
                        group_id = group.id,
                        entry_order = entry.entry_order,
                    }
                )
            end
            total = total + entry.weight
            if total > MAX_WEIGHT_TOTAL then
                return invalid(
                    path_prefix,
                    'WEIGHT_TOTAL_OVERFLOW',
                    {
                        group_id = group.id,
                        total = total,
                        max = MAX_WEIGHT_TOTAL,
                    }
                )
            end
        end
        if total < 1 then
            return invalid(
                path_prefix,
                'WEIGHT_TOTAL_BELOW_ONE',
                {
                    group_id = group.id,
                    total = total,
                }
            )
        end
    elseif mode == 'INDEPENDENT_EACH' then
        if #entries == 0 then
            return invalid(path_prefix, 'INDEPENDENT_GROUP_REQUIRES_ENTRIES', {
                group_id = group.id,
            })
        end
        local index
        for index = 1, #entries do
            local entry = entries[index]
            if entry.chance_bp == nil then
                return invalid(
                    path_prefix .. '.entries',
                    'CHANCE_BP_REQUIRED_FOR_INDEPENDENT_EACH',
                    {
                        group_id = group.id,
                        entry_order = entry.entry_order,
                    }
                )
            end
            if entry.weight ~= nil then
                return invalid(
                    path_prefix .. '.entries',
                    'WEIGHT_FORBIDDEN_FOR_INDEPENDENT_EACH',
                    {
                        group_id = group.id,
                        entry_order = entry.entry_order,
                    }
                )
            end
        end
    elseif mode == 'GUARANTEED_ALL' then
        if #entries == 0 then
            return invalid(path_prefix, 'GUARANTEED_GROUP_REQUIRES_ENTRIES', {
                group_id = group.id,
            })
        end
        local index
        for index = 1, #entries do
            local entry = entries[index]
            if entry.weight ~= nil or entry.chance_bp ~= nil then
                return invalid(
                    path_prefix .. '.entries',
                    'WEIGHT_AND_CHANCE_FORBIDDEN_FOR_GUARANTEED_ALL',
                    {
                        group_id = group.id,
                        entry_order = entry.entry_order,
                    }
                )
            end
        end
    end

    if group.duplicate_policy == 'REROLL_UNIQUE' then
        local index
        for index = 1, #entries do
            if entries[index].unique_key == nil then
                return invalid(
                    path_prefix .. '.entries',
                    'UNIQUE_KEY_REQUIRED_FOR_REROLL_UNIQUE',
                    {
                        group_id = group.id,
                        entry_order = entries[index].entry_order,
                    }
                )
            end
        end
    end

    return result_ok(true)
end

local function validate_cross_refs(table_registry, group_registry, entries_by_group)
    local listed_tables = table_registry:list()
    if not listed_tables.ok then
        return listed_tables
    end
    local listed_groups = group_registry:list()
    if not listed_groups.ok then
        return listed_groups
    end

    local table_index
    for table_index = 1, #listed_tables.value do
        local loot_table = listed_tables.value[table_index]
        local group_index
        for group_index = 1, #loot_table.group_ids do
            local group_id = loot_table.group_ids[group_index]
            if not group_registry:contains(group_id) then
                return invalid(
                    'loot_tables[' .. loot_table.id .. '].group_ids',
                    'REFERENCE_NOT_FOUND',
                    {
                        loot_id = loot_table.id,
                        group_id = group_id,
                        referenced_collection = 'loot_groups',
                    }
                )
            end
        end
    end

    local group_index
    for group_index = 1, #listed_groups.value do
        local group = listed_groups.value[group_index]
        local checked = validate_group_entries(group, entries_by_group[group.id])
        if not checked.ok then
            return checked
        end
    end

    return result_ok(true)
end

function Catalog.build(source)
    local checked = validate_source(source)
    if not checked.ok then
        return checked
    end

    local tables_built = build_registry(
        'loot_tables',
        'id',
        LootTable.validate,
        source.loot_tables
    )
    if not tables_built.ok then
        return tables_built
    end
    local table_registry = tables_built.value

    local groups_built = build_registry(
        'loot_groups',
        'id',
        LootGroup.validate,
        source.loot_groups
    )
    if not groups_built.ok then
        return groups_built
    end
    local group_registry = groups_built.value

    local indexed = index_entries(source.loot_entries, group_registry)
    if not indexed.ok then
        return indexed
    end
    local entries_by_group = indexed.value

    local cross = validate_cross_refs(table_registry, group_registry, entries_by_group)
    if not cross.ok then
        return cross
    end

    local sealed_tables = table_registry:seal()
    if not sealed_tables.ok then
        return sealed_tables
    end
    local sealed_groups = group_registry:seal()
    if not sealed_groups.ok then
        return sealed_groups
    end

    -- Freeze entry rows per group (already sorted). Prefer registry list order.
    local frozen_entries = {}
    local listed_groups = group_registry:list()
    if not listed_groups.ok then
        return listed_groups
    end
    local freeze_index
    for freeze_index = 1, #listed_groups.value do
        local group_id = listed_groups.value[freeze_index].id
        local entries = entries_by_group[group_id]
        if entries ~= nil then
            local frozen = {}
            local index
            for index = 1, #entries do
                local entry = entries[index]
                frozen[index] = {
                    group_id = entry.group_id,
                    entry_order = entry.entry_order,
                    reward_id = entry.reward_id,
                    weight = entry.weight,
                    chance_bp = entry.chance_bp,
                    min_quantity_multiplier = 1,
                    max_quantity_multiplier = 1,
                    condition_set_id = entry.condition_set_id,
                    unique_key = entry.unique_key,
                }
            end
            frozen_entries[group_id] = frozen
        end
    end

    local view = set_metatable({}, CatalogView)
    STATES[view] = {
        table_registry = table_registry,
        group_registry = group_registry,
        entries_by_group = frozen_entries,
    }
    return result_ok(view)
end

function Catalog.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

local function resolve_state(self)
    return STATES[self]
end

function CatalogView:get_table(loot_id)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.economy.loot_catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.table_registry:get(loot_id)
end

function CatalogView:get_group(group_id)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.economy.loot_catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.group_registry:get(group_id)
end

function CatalogView:list_entries(group_id)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.economy.loot_catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(group_id, 'lootgroup_', 'group_id')
    if not checked.ok then
        return catalog_error(
            EconomyErrorCodes.ECONOMY_ARGUMENT_INVALID,
            'error.economy.argument_invalid',
            'GROUP_ID_INVALID',
            { field = 'group_id' }
        )
    end
    local entries = state.entries_by_group[group_id]
    if entries == nil then
        return result_ok({})
    end
    local copied = {}
    local index
    for index = 1, #entries do
        local entry = entries[index]
        copied[index] = {
            group_id = entry.group_id,
            entry_order = entry.entry_order,
            reward_id = entry.reward_id,
            weight = entry.weight,
            chance_bp = entry.chance_bp,
            min_quantity_multiplier = entry.min_quantity_multiplier,
            max_quantity_multiplier = entry.max_quantity_multiplier,
            condition_set_id = entry.condition_set_id,
            unique_key = entry.unique_key,
        }
    end
    return result_ok(copied)
end

function CatalogView:contains_table(loot_id)
    local state = resolve_state(self)
    if state == nil then
        return false
    end
    return state.table_registry:contains(loot_id)
end

function CatalogView:require_table(loot_id)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.economy.loot_catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    local checked = validate_content_id(loot_id, 'loot_', 'loot_id')
    if not checked.ok then
        return catalog_error(
            EconomyErrorCodes.ECONOMY_ARGUMENT_INVALID,
            'error.economy.argument_invalid',
            'LOOT_ID_INVALID',
            { field = 'loot_id' }
        )
    end
    local found = state.table_registry:get(loot_id)
    if not found.ok then
        return catalog_error(
            EconomyErrorCodes.ECONOMY_LOOT_UNKNOWN,
            'error.economy.loot_unknown',
            'LOOT_TABLE_NOT_FOUND',
            { loot_id = loot_id }
        )
    end
    return found
end

function CatalogView:resolve_table(loot_id)
    local required = self:require_table(loot_id)
    if not required.ok then
        return required
    end
    local state = resolve_state(self)
    local loot_table = required.value
    local groups = {}
    local index
    for index = 1, #loot_table.group_ids do
        local group_id = loot_table.group_ids[index]
        local group = state.group_registry:get(group_id)
        if not group.ok then
            return catalog_error(
                EconomyErrorCodes.ECONOMY_LOOT_CONFIG_INVALID,
                'error.economy.loot_config_invalid',
                'GROUP_MISSING_AT_RESOLVE',
                { loot_id = loot_id, group_id = group_id }
            )
        end
        local entries = state.entries_by_group[group_id] or {}
        local entry_copies = {}
        local entry_index
        for entry_index = 1, #entries do
            local entry = entries[entry_index]
            entry_copies[entry_index] = {
                group_id = entry.group_id,
                entry_order = entry.entry_order,
                reward_id = entry.reward_id,
                weight = entry.weight,
                chance_bp = entry.chance_bp,
                min_quantity_multiplier = entry.min_quantity_multiplier,
                max_quantity_multiplier = entry.max_quantity_multiplier,
                condition_set_id = entry.condition_set_id,
                unique_key = entry.unique_key,
            }
        end
        groups[index] = {
            group = {
                id = group.value.id,
                mode = group.value.mode,
                roll_count = group.value.roll_count,
                no_drop_weight = group.value.no_drop_weight,
                duplicate_policy = group.value.duplicate_policy,
            },
            entries = entry_copies,
        }
    end
    return result_ok({
        loot_table = {
            id = loot_table.id,
            roll_count = loot_table.roll_count,
            guaranteed_reward_id = loot_table.guaranteed_reward_id,
            group_ids = loot_table.group_ids,
            duplicate_policy = loot_table.duplicate_policy,
            config_version = loot_table.config_version,
        },
        groups = groups,
    })
end

return Catalog
