local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.config.schema.effects.validation'

local EffectBundle = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_ok = Result.ok
local tostring_value = tostring
local type_value = type
local validation_boolean = Validation.boolean
local validation_content_id = Validation.content_id
local validation_dense_array = Validation.dense_array
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields
local validation_non_empty_string = Validation.non_empty_string

local SCHEMA = 'EffectBundle'
local MAX_NODES = 64
local MAX_EVENT_BUDGET_OVERRIDE = 2048
local FIELDS = {
    id = true,
    schema_version = true,
    atomicity = true,
    stop_policy = true,
    target_snapshot_policy = true,
    chance_scope = true,
    requires_source_alive = true,
    event_budget_override = true,
    presentation_group_id = true,
    nodes = true,
    deprecated = true,
}
local NODE_FIELDS = {
    node_id = true,
    operation = true,
    target_rule_id = true,
    condition = true,
    chance_bp = true,
    fixed_magnitude = true,
    status_id = true,
    stacks = true,
    duration_override = true,
    dispel_category = true,
    dispel_count = true,
    polarity_filter = true,
    dead_target_policy = true,
    failure_policy = true,
    presentation_cue_id = true,
    signal_id = true,
    mechanic_key = true,
    mechanic_value = true,
}
local CONDITION_FIELDS = {
    op = true,
    status_id = true,
    min_stacks = true,
    tag = true,
    max_depth = true,
    children = true,
}
local ATOMICITIES = {
    NODE = true,
    BUNDLE_VALIDATE_THEN_APPLY = true,
}
local STOP_POLICIES = {
    CONTINUE = true,
    STOP_ON_FIRST_FAILURE = true,
}
local TARGET_SNAPSHOT_POLICIES = {
    AT_START = true,
    PER_NODE = true,
}
local CHANCE_SCOPES = {
    PER_TARGET = true,
    BUNDLE = true,
}
local OPERATIONS = {
    DEAL_DAMAGE = true,
    HEAL = true,
    MODIFY_QI = true,
    APPLY_STATUS = true,
    REMOVE_STATUS = true,
    ADD_SHIELD = true,
    DISPEL = true,
    MOVE_POSITION = true,
    SUMMON = true,
    REVIVE = true,
    SET_MECHANIC_FLAG = true,
    EMIT_SIGNAL = true,
}
local FAILURE_POLICIES = {
    CONTINUE = true,
    STOP_BUNDLE = true,
    REQUIRE_SUCCESS = true,
}
local DEAD_TARGET_POLICIES = {
    SKIP = true,
    ALLOW = true,
}
local POLARITY_FILTERS = {
    BUFF = true,
    DEBUFF = true,
    ANY = true,
}
local DISPEL_CATEGORIES = {
    NONE = true,
    MAGICAL = true,
    PHYSICAL = true,
    ANY = true,
    UNDISPELLABLE = true,
}
local CONDITION_OPS = {
    ALWAYS = true,
    TARGET_ALIVE = true,
    TARGET_DOWNED = true,
    HAS_STATUS = true,
    HAS_TAG = true,
    ALL = true,
    ANY = true,
    NONE = true,
}

local function copy_condition(condition)
    if condition == nil then
        return nil
    end
    local copied = {
        op = raw_get(condition, 'op'),
        status_id = raw_get(condition, 'status_id'),
        min_stacks = raw_get(condition, 'min_stacks'),
        tag = raw_get(condition, 'tag'),
    }
    local children = raw_get(condition, 'children')
    if children ~= nil then
        local copied_children = {}
        local index
        for index = 1, #children do
            copied_children[index] = copy_condition(children[index])
        end
        copied.children = copied_children
    end
    return copied
end

local function validate_condition(condition, path, depth, node_count_box)
    if condition == nil then
        return nil
    end
    if depth > 4 then
        return validation_invalid(SCHEMA, path, 'CONDITION_DEPTH_EXCEEDED')
    end
    if node_count_box.count >= 32 then
        return validation_invalid(SCHEMA, path, 'CONDITION_NODE_LIMIT_EXCEEDED')
    end
    node_count_box.count = node_count_box.count + 1
    if type_value(condition) ~= 'table' or get_metatable(condition) ~= nil then
        return validation_invalid(SCHEMA, path, 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, condition, CONDITION_FIELDS)
    if err ~= nil then
        local nested = err.error.details.field
        if nested == '$' then
            nested = path
        else
            nested = path .. '.' .. nested
        end
        return validation_invalid(SCHEMA, nested, err.error.details.reason)
    end
    local op = raw_get(condition, 'op')
    err = validation_enum(SCHEMA, path .. '.op', op, CONDITION_OPS)
    if err ~= nil then
        return err
    end
    if op == 'HAS_STATUS' then
        err = validation_first(
            validation_content_id(SCHEMA, path .. '.status_id', raw_get(condition, 'status_id'), 'status_'),
            validation_integer(
                SCHEMA,
                path .. '.min_stacks',
                raw_get(condition, 'min_stacks') or 1,
                1,
                99
            )
        )
        if err ~= nil then
            return err
        end
    elseif op == 'HAS_TAG' then
        err = validation_non_empty_string(SCHEMA, path .. '.tag', raw_get(condition, 'tag'))
        if err ~= nil then
            return err
        end
    elseif op == 'ALL' or op == 'ANY' or op == 'NONE' then
        local children = raw_get(condition, 'children')
        err = validation_dense_array(SCHEMA, path .. '.children', children)
        if err ~= nil then
            return err
        end
        if #children < 1 then
            return validation_invalid(SCHEMA, path .. '.children', 'NON_EMPTY_REQUIRED')
        end
        local index
        for index = 1, #children do
            err = validate_condition(
                children[index],
                path .. '.children[' .. tostring_value(index) .. ']',
                depth + 1,
                node_count_box
            )
            if err ~= nil then
                return err
            end
        end
    end
    return nil
end

local function validate_node(node, index, seen_node_ids)
    local path = 'nodes[' .. tostring_value(index) .. ']'
    if type_value(node) ~= 'table' or get_metatable(node) ~= nil then
        return validation_invalid(SCHEMA, path, 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, node, NODE_FIELDS)
    if err ~= nil then
        local nested = err.error.details.field
        if nested == '$' then
            nested = path
        else
            nested = path .. '.' .. nested
        end
        return validation_invalid(SCHEMA, nested, err.error.details.reason)
    end

    local node_id = raw_get(node, 'node_id')
    local operation = raw_get(node, 'operation')
    local chance_bp = raw_get(node, 'chance_bp')
    if chance_bp == nil then
        chance_bp = 10000
    end
    local stacks = raw_get(node, 'stacks')
    if stacks == nil then
        stacks = 1
    end
    local failure_policy = raw_get(node, 'failure_policy')
    if failure_policy == nil then
        failure_policy = 'CONTINUE'
    end
    local dead_target_policy = raw_get(node, 'dead_target_policy')
    if dead_target_policy == nil then
        dead_target_policy = 'SKIP'
    end
    local dispel_count = raw_get(node, 'dispel_count')
    if dispel_count == nil then
        dispel_count = 1
    end
    local polarity_filter = raw_get(node, 'polarity_filter')
    if polarity_filter == nil then
        polarity_filter = 'ANY'
    end

    err = validation_first(
        validation_non_empty_string(SCHEMA, path .. '.node_id', node_id),
        validation_enum(SCHEMA, path .. '.operation', operation, OPERATIONS),
        validation_content_id(
            SCHEMA,
            path .. '.target_rule_id',
            raw_get(node, 'target_rule_id'),
            'target_',
            true
        ),
        validation_integer(SCHEMA, path .. '.chance_bp', chance_bp, 0, 10000),
        validation_integer(SCHEMA, path .. '.fixed_magnitude', raw_get(node, 'fixed_magnitude'), -1000000000, 1000000000, true),
        validation_content_id(
            SCHEMA,
            path .. '.status_id',
            raw_get(node, 'status_id'),
            'status_',
            true
        ),
        validation_integer(SCHEMA, path .. '.stacks', stacks, 1, 99),
        validation_integer(
            SCHEMA,
            path .. '.duration_override',
            raw_get(node, 'duration_override'),
            0,
            999,
            true
        ),
        validation_enum(
            SCHEMA,
            path .. '.dispel_category',
            raw_get(node, 'dispel_category') or 'ANY',
            DISPEL_CATEGORIES
        ),
        validation_integer(SCHEMA, path .. '.dispel_count', dispel_count, 1, 99),
        validation_enum(SCHEMA, path .. '.polarity_filter', polarity_filter, POLARITY_FILTERS),
        validation_enum(SCHEMA, path .. '.dead_target_policy', dead_target_policy, DEAD_TARGET_POLICIES),
        validation_enum(SCHEMA, path .. '.failure_policy', failure_policy, FAILURE_POLICIES),
        validation_non_empty_string(
            SCHEMA,
            path .. '.presentation_cue_id',
            raw_get(node, 'presentation_cue_id'),
            true
        ),
        validation_non_empty_string(
            SCHEMA,
            path .. '.signal_id',
            raw_get(node, 'signal_id'),
            true
        ),
        validation_non_empty_string(
            SCHEMA,
            path .. '.mechanic_key',
            raw_get(node, 'mechanic_key'),
            true
        ),
        validation_integer(
            SCHEMA,
            path .. '.mechanic_value',
            raw_get(node, 'mechanic_value'),
            -1000000000,
            1000000000,
            true
        )
    )
    if err ~= nil then
        return err
    end
    if seen_node_ids[node_id] then
        return validation_invalid(SCHEMA, path .. '.node_id', 'DUPLICATE_NODE_ID')
    end
    seen_node_ids[node_id] = true

    if operation == 'APPLY_STATUS'
        or operation == 'REMOVE_STATUS'
        or operation == 'ADD_SHIELD'
    then
        if raw_get(node, 'status_id') == nil then
            return validation_invalid(SCHEMA, path .. '.status_id', 'STATUS_ID_REQUIRED')
        end
    end
    if operation == 'DEAL_DAMAGE'
        or operation == 'HEAL'
        or operation == 'MODIFY_QI'
        or operation == 'ADD_SHIELD'
    then
        if raw_get(node, 'fixed_magnitude') == nil then
            return validation_invalid(SCHEMA, path .. '.fixed_magnitude', 'MAGNITUDE_REQUIRED')
        end
    end
    if operation == 'DEAL_DAMAGE' or operation == 'HEAL' or operation == 'ADD_SHIELD' then
        if raw_get(node, 'fixed_magnitude') <= 0 then
            return validation_invalid(SCHEMA, path .. '.fixed_magnitude', 'POSITIVE_MAGNITUDE_REQUIRED')
        end
    end
    if operation == 'EMIT_SIGNAL' and raw_get(node, 'signal_id') == nil then
        return validation_invalid(SCHEMA, path .. '.signal_id', 'SIGNAL_ID_REQUIRED')
    end
    if operation == 'SET_MECHANIC_FLAG' then
        if raw_get(node, 'mechanic_key') == nil or raw_get(node, 'mechanic_value') == nil then
            return validation_invalid(SCHEMA, path .. '.mechanic_key', 'MECHANIC_FIELDS_REQUIRED')
        end
    end
    if operation == 'REVIVE' then
        -- Reserved; catalog graph rejects until explicitly enabled by content flag later.
    end

    err = validate_condition(
        raw_get(node, 'condition'),
        path .. '.condition',
        1,
        { count = 0 }
    )
    if err ~= nil then
        return err
    end

    return result_ok({
        node_id = node_id,
        operation = operation,
        target_rule_id = raw_get(node, 'target_rule_id'),
        condition = copy_condition(raw_get(node, 'condition')),
        chance_bp = chance_bp,
        fixed_magnitude = raw_get(node, 'fixed_magnitude'),
        status_id = raw_get(node, 'status_id'),
        stacks = stacks,
        duration_override = raw_get(node, 'duration_override'),
        dispel_category = raw_get(node, 'dispel_category') or 'ANY',
        dispel_count = dispel_count,
        polarity_filter = polarity_filter,
        dead_target_policy = dead_target_policy,
        failure_policy = failure_policy,
        presentation_cue_id = raw_get(node, 'presentation_cue_id'),
        signal_id = raw_get(node, 'signal_id'),
        mechanic_key = raw_get(node, 'mechanic_key'),
        mechanic_value = raw_get(node, 'mechanic_value'),
    })
end

function EffectBundle.validate(value)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return validation_invalid(SCHEMA, '$', 'TABLE_REQUIRED')
    end
    local err = validation_no_unknown_fields(SCHEMA, value, FIELDS)
    if err ~= nil then
        return err
    end

    local atomicity = raw_get(value, 'atomicity')
    if atomicity == nil then
        atomicity = 'NODE'
    end
    local stop_policy = raw_get(value, 'stop_policy')
    if stop_policy == nil then
        stop_policy = 'CONTINUE'
    end
    local target_snapshot_policy = raw_get(value, 'target_snapshot_policy')
    if target_snapshot_policy == nil then
        target_snapshot_policy = 'AT_START'
    end
    local chance_scope = raw_get(value, 'chance_scope')
    if chance_scope == nil then
        chance_scope = 'PER_TARGET'
    end
    local requires_source_alive = raw_get(value, 'requires_source_alive')
    if requires_source_alive == nil then
        requires_source_alive = false
    end
    local deprecated = raw_get(value, 'deprecated')
    if deprecated == nil then
        deprecated = false
    end
    local nodes = raw_get(value, 'nodes')

    err = validation_first(
        validation_content_id(SCHEMA, 'id', raw_get(value, 'id'), 'effect_'),
        validation_integer(SCHEMA, 'schema_version', raw_get(value, 'schema_version'), 1, 1),
        validation_enum(SCHEMA, 'atomicity', atomicity, ATOMICITIES),
        validation_enum(SCHEMA, 'stop_policy', stop_policy, STOP_POLICIES),
        validation_enum(
            SCHEMA,
            'target_snapshot_policy',
            target_snapshot_policy,
            TARGET_SNAPSHOT_POLICIES
        ),
        validation_enum(SCHEMA, 'chance_scope', chance_scope, CHANCE_SCOPES),
        validation_boolean(SCHEMA, 'requires_source_alive', requires_source_alive),
        validation_integer(
            SCHEMA,
            'event_budget_override',
            raw_get(value, 'event_budget_override'),
            1,
            MAX_EVENT_BUDGET_OVERRIDE,
            true
        ),
        validation_non_empty_string(
            SCHEMA,
            'presentation_group_id',
            raw_get(value, 'presentation_group_id'),
            true
        ),
        validation_dense_array(SCHEMA, 'nodes', nodes),
        validation_boolean(SCHEMA, 'deprecated', deprecated)
    )
    if err ~= nil then
        return err
    end
    if #nodes < 1 or #nodes > MAX_NODES then
        return validation_invalid(SCHEMA, 'nodes', 'NODE_COUNT_OUT_OF_RANGE', {
            minimum = 1,
            maximum = MAX_NODES,
        })
    end

    local normalized_nodes = {}
    local seen_node_ids = {}
    local index
    for index = 1, #nodes do
        local node_result = validate_node(nodes[index], index, seen_node_ids)
        if not node_result.ok then
            return node_result
        end
        normalized_nodes[index] = node_result.value
    end

    return result_ok({
        id = raw_get(value, 'id'),
        schema_version = 1,
        atomicity = atomicity,
        stop_policy = stop_policy,
        target_snapshot_policy = target_snapshot_policy,
        chance_scope = chance_scope,
        requires_source_alive = requires_source_alive,
        event_budget_override = raw_get(value, 'event_budget_override'),
        presentation_group_id = raw_get(value, 'presentation_group_id'),
        nodes = normalized_nodes,
        deprecated = deprecated,
    })
end

return EffectBundle
