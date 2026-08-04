local ErrorCodes = require 'wzx.domain.common.error_codes'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local RewardErrorCodes = require 'wzx.domain.reward.error_codes'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local Validation = require 'wzx.config.schema.reward.validation'
local RewardBundle = require 'wzx.config.schema.reward.reward_bundle'

local Catalog = {}
local error_value = error
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local schema_registry_new = SchemaRegistry.new
local set_metatable = setmetatable
local tostring_value = tostring
local type_value = type
local validate_content_id = RuntimeId.validate_content
local validation_dense_array = Validation.dense_array
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

local CatalogView = {}
CatalogView.__index = CatalogView
CatalogView.__newindex = function()
    error_value('reward catalog is read-only', 2)
end
CatalogView.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })
local SCHEMA = 'RewardCatalog'
local COLLECTION_ORDER = {
    'reward_bundles',
}
local COLLECTION_FIELDS = {
    reward_bundles = true,
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

local function build_registry(entries)
    local created = schema_registry_new({
        registry_name = 'reward_bundles',
        id_field = 'id',
        normalize_entry = RewardBundle.validate,
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

local function validate_bundle_graph(registry)
    local listed = registry:list()
    if not listed.ok then
        return listed
    end

    local index
    for index = 1, #listed.value do
        local bundle = listed.value[index]
        local entry_index
        for entry_index = 1, #bundle.entries do
            local entry = bundle.entries[entry_index]
            if entry.entry_type == 'REWARD_BUNDLE' then
                local nested_id = entry.target_id
                if nested_id == bundle.id then
                    return invalid(
                        'entries[' .. tostring_value(entry_index) .. '].target_id',
                        'SELF_NESTED_BUNDLE_FORBIDDEN',
                        {
                            reward_id = bundle.id,
                            nested_reward_id = nested_id,
                        }
                    )
                end
                if not registry:contains(nested_id) then
                    return invalid(
                        'entries[' .. tostring_value(entry_index) .. '].target_id',
                        'REFERENCE_NOT_FOUND',
                        {
                            reward_id = bundle.id,
                            reference_id = nested_id,
                            referenced_collection = 'reward_bundles',
                        }
                    )
                end

                local nested_result = registry:get(nested_id)
                if not nested_result.ok then
                    return nested_result
                end
                local nested = nested_result.value
                local nested_entry_index
                for nested_entry_index = 1, #nested.entries do
                    local nested_entry = nested.entries[nested_entry_index]
                    if nested_entry.entry_type == 'REWARD_BUNDLE' then
                        return catalog_error(
                            RewardErrorCodes.REWARD_NESTING_INVALID,
                            'error.reward.nesting_invalid',
                            'NESTING_DEPTH_EXCEEDED',
                            {
                                reward_id = bundle.id,
                                nested_reward_id = nested_id,
                                nested_entry_index = nested_entry_index,
                            }
                        )
                    end
                end
            end
        end
    end
    return result_ok(true)
end

function Catalog.build(source)
    local checked = validate_source(source)
    if not checked.ok then
        return checked
    end

    local built = build_registry(source.reward_bundles)
    if not built.ok then
        return built
    end
    local registry = built.value

    local graph = validate_bundle_graph(registry)
    if not graph.ok then
        return graph
    end

    local sealed = registry:seal()
    if not sealed.ok then
        return sealed
    end

    local view = set_metatable({}, CatalogView)
    STATES[view] = { registry = registry }
    return result_ok(view)
end

local function resolve_state(self)
    return STATES[self]
end

function CatalogView:get(reward_id)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.reward.catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.registry:get(reward_id)
end

function CatalogView:list()
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.reward.catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    return state.registry:list()
end

function CatalogView:contains(reward_id)
    local state = resolve_state(self)
    if state == nil then
        return false
    end
    return state.registry:contains(reward_id)
end

local function expand_leaves(self, reward_id)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.reward.catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end

    local checked_id = validate_content_id(reward_id, 'reward_', 'reward_id')
    if not checked_id.ok then
        return catalog_error(
            RewardErrorCodes.REWARD_ARGUMENT_INVALID,
            'error.reward.argument_invalid',
            'REWARD_ID_INVALID',
            { field = 'reward_id' }
        )
    end

    local root_result = state.registry:get(reward_id)
    if not root_result.ok then
        return catalog_error(
            RewardErrorCodes.REWARD_REFERENCE_NOT_FOUND,
            'error.reward.reference_not_found',
            'REFERENCE_NOT_FOUND',
            {
                reward_id = reward_id,
            }
        )
    end

    local leaves = {}
    local root = root_result.value
    local index
    for index = 1, #root.entries do
        local entry = root.entries[index]
        if entry.entry_type == 'REWARD_BUNDLE' then
            local nested_result = state.registry:get(entry.target_id)
            if not nested_result.ok then
                return catalog_error(
                    RewardErrorCodes.REWARD_REFERENCE_NOT_FOUND,
                    'error.reward.reference_not_found',
                    'REFERENCE_NOT_FOUND',
                    {
                        reward_id = reward_id,
                        nested_reward_id = entry.target_id,
                    }
                )
            end
            local nested = nested_result.value
            local nested_index
            for nested_index = 1, #nested.entries do
                local nested_entry = nested.entries[nested_index]
                if nested_entry.entry_type == 'REWARD_BUNDLE' then
                    return catalog_error(
                        RewardErrorCodes.REWARD_NESTING_INVALID,
                        'error.reward.nesting_invalid',
                        'NESTING_DEPTH_EXCEEDED',
                        {
                            reward_id = reward_id,
                            nested_reward_id = entry.target_id,
                        }
                    )
                end
                leaves[#leaves + 1] = {
                    source_reward_id = reward_id,
                    nested_reward_id = entry.target_id,
                    entry_type = nested_entry.entry_type,
                    target_id = nested_entry.target_id,
                    quantity_min = nested_entry.quantity_min,
                    quantity_max = nested_entry.quantity_max,
                    scale_rule_id = nested_entry.scale_rule_id,
                    condition_set_id = nested_entry.condition_set_id,
                    first_clear_only = nested_entry.first_clear_only,
                    metadata = nested_entry.metadata,
                    path = 'entries['
                        .. tostring_value(index)
                        .. ']->'
                        .. entry.target_id
                        .. '.entries['
                        .. tostring_value(nested_index)
                        .. ']',
                }
            end
        else
            leaves[#leaves + 1] = {
                source_reward_id = reward_id,
                nested_reward_id = nil,
                entry_type = entry.entry_type,
                target_id = entry.target_id,
                quantity_min = entry.quantity_min,
                quantity_max = entry.quantity_max,
                scale_rule_id = entry.scale_rule_id,
                condition_set_id = entry.condition_set_id,
                first_clear_only = entry.first_clear_only,
                metadata = entry.metadata,
                path = 'entries[' .. tostring_value(index) .. ']',
            }
        end
    end
    return result_ok(leaves)
end
CatalogView.expand_leaves = expand_leaves
Catalog.expand_leaves = expand_leaves

local function validate_as_level_reward(self, reward_id)
    local expanded = expand_leaves(self, reward_id)
    if not expanded.ok then
        return expanded
    end

    local index
    for index = 1, #expanded.value do
        local leaf = expanded.value[index]
        if leaf.entry_type == 'CHARACTER_XP' then
            return catalog_error(
                RewardErrorCodes.REWARD_LEVEL_XP_FORBIDDEN,
                'error.reward.level_xp_forbidden',
                'LEVEL_REWARD_CHARACTER_XP_FORBIDDEN',
                {
                    reward_id = reward_id,
                    target_id = leaf.target_id,
                    path = leaf.path,
                    nested_reward_id = leaf.nested_reward_id,
                }
            )
        end
    end
    return result_ok({
        reward_id = reward_id,
        leaf_count = #expanded.value,
        leaves = expanded.value,
    })
end
CatalogView.validate_as_level_reward = validate_as_level_reward
Catalog.validate_as_level_reward = validate_as_level_reward

local function validate_level_curve_refs(self, level_curves)
    local state = resolve_state(self)
    if state == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.reward.catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    if get_metatable(level_curves) ~= nil or not is_dense_array(level_curves) then
        return catalog_error(
            RewardErrorCodes.REWARD_ARGUMENT_INVALID,
            'error.reward.argument_invalid',
            'DENSE_ARRAY_REQUIRED',
            { field = 'level_curves' }
        )
    end

    local curve_index
    for curve_index = 1, #level_curves do
        local curve = level_curves[curve_index]
        if type_value(curve) ~= 'table' or get_metatable(curve) ~= nil then
            return catalog_error(
                RewardErrorCodes.REWARD_ARGUMENT_INVALID,
                'error.reward.argument_invalid',
                'TABLE_REQUIRED',
                {
                    field = 'level_curves[' .. tostring_value(curve_index) .. ']',
                }
            )
        end

        local curve_id = raw_get(curve, 'id')
        local refs = raw_get(curve, 'level_reward_refs')
        if refs == nil then
            refs = {}
        end
        if get_metatable(refs) ~= nil or not is_dense_array(refs) then
            return catalog_error(
                RewardErrorCodes.REWARD_ARGUMENT_INVALID,
                'error.reward.argument_invalid',
                'DENSE_ARRAY_REQUIRED',
                {
                    field = 'level_curves['
                        .. tostring_value(curve_index)
                        .. '].level_reward_refs',
                    curve_id = curve_id,
                }
            )
        end

        local ref_index
        for ref_index = 1, #refs do
            local row = refs[ref_index]
            if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
                return catalog_error(
                    RewardErrorCodes.REWARD_ARGUMENT_INVALID,
                    'error.reward.argument_invalid',
                    'TABLE_REQUIRED',
                    {
                        field = 'level_curves['
                            .. tostring_value(curve_index)
                            .. '].level_reward_refs['
                            .. tostring_value(ref_index)
                            .. ']',
                        curve_id = curve_id,
                    }
                )
            end
            local reward_ref = raw_get(row, 'reward_ref')
            local checked = validate_content_id(
                reward_ref,
                'reward_',
                'reward_ref'
            )
            if not checked.ok then
                return catalog_error(
                    RewardErrorCodes.REWARD_ARGUMENT_INVALID,
                    'error.reward.argument_invalid',
                    'REWARD_ID_INVALID',
                    {
                        curve_id = curve_id,
                        field = 'level_reward_refs['
                            .. tostring_value(ref_index)
                            .. '].reward_ref',
                    }
                )
            end
            if not state.registry:contains(reward_ref) then
                return catalog_error(
                    RewardErrorCodes.REWARD_REFERENCE_NOT_FOUND,
                    'error.reward.reference_not_found',
                    'LEVEL_REWARD_REFERENCE_NOT_FOUND',
                    {
                        curve_id = curve_id,
                        reward_ref = reward_ref,
                        reached_level = raw_get(row, 'reached_level'),
                    }
                )
            end
            local safe = validate_as_level_reward(self, reward_ref)
            if not safe.ok then
                local details = safe.error.details or {}
                details.curve_id = curve_id
                details.reached_level = raw_get(row, 'reached_level')
                details.reward_ref = reward_ref
                return result_err(
                    safe.error.code,
                    safe.error.message_key,
                    safe.error.retryable,
                    details
                )
            end
        end
    end
    return result_ok(true)
end
CatalogView.validate_level_curve_refs = validate_level_curve_refs
Catalog.validate_level_curve_refs = validate_level_curve_refs

function Catalog.validate_character_level_rewards(reward_catalog, character_catalog)
    if STATES[reward_catalog] == nil then
        return catalog_error(
            ErrorCodes.INVALID_ARGUMENT,
            'error.reward.catalog_authority_invalid',
            'CATALOG_AUTHORITY_REQUIRED'
        )
    end
    if type_value(character_catalog) ~= 'table'
        or type_value(character_catalog.list) ~= 'function'
    then
        return catalog_error(
            RewardErrorCodes.REWARD_ARGUMENT_INVALID,
            'error.reward.argument_invalid',
            'CHARACTER_CATALOG_REQUIRED'
        )
    end

    local listed = character_catalog:list('level_curves')
    if not listed.ok then
        return listed
    end
    return validate_level_curve_refs(reward_catalog, listed.value)
end

function Catalog.is_authority(catalog)
    return STATES[catalog] ~= nil
end

return Catalog
