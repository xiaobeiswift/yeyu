-- In-memory Traversal targeting/session authority for system 26.
-- Sessions are never persisted; only landing commits via 12 are durable.

local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local ReachabilitySourceVector = require 'wzx.domain.contracts.reachability_source_vector'
local TraversalErrorCodes = require 'wzx.domain.traversal.error_codes'
local Reachability = require 'wzx.domain.traversal.reachability'
local TraversalEvents = require 'wzx.domain.traversal.events'

local Runtime = {}
local get_metatable = getmetatable
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local function copy_array_local(values)
    local copy = {}
    local index
    for index = 1, #values do
        copy[index] = values[index]
    end
    return copy
end

local function profile_water_budget(profile)
    local index
    for index = 1, #profile.capability_specs do
        local spec = profile.capability_specs[index]
        if spec.capability_id == 'WATER_WALK' then
            return spec.water_range_cells
        end
    end
    return 0
end

local LANDING_TUPLE_FIELDS = {
    { name = 'player_save_scope', type = 'STRING' },
    { name = 'traversal_session_id', type = 'STRING' },
    { name = 'active_segment_command_id', type = 'STRING' },
    { name = 'segment_sequence', type = 'INTEGER' },
    { name = 'target_cell_id', type = 'STRING' },
    { name = 'rules_version', type = 'INTEGER' },
}

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.traversal.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(TraversalErrorCodes.TRAVERSAL_ARGUMENT_INVALID, reason, details, false)
end

function Runtime.empty()
    return {
        targeting = nil,
        traversal = nil,
        open_receipts = {},
        command_receipts = {},
        recovery_receipts = {},
        sequence_counter = 0,
    }
end

local function next_sequence(state)
    state.sequence_counter = state.sequence_counter + 1
    return state.sequence_counter
end

local function copy_source_vector(vector)
    return {
        spatial_revision = vector.spatial_revision,
        world_revision = vector.world_revision,
        source_loadout_revision = vector.source_loadout_revision,
        source_progress_revision = vector.source_progress_revision,
        profile_hash = vector.profile_hash,
        rules_version = vector.rules_version,
    }
end

local function copy_candidate(candidate)
    local link_ids = {}
    local path_cell_ids = {}
    local index
    for index = 1, #candidate.link_ids do
        link_ids[index] = candidate.link_ids[index]
    end
    for index = 1, #candidate.path_cell_ids do
        path_cell_ids[index] = candidate.path_cell_ids[index]
    end
    local world_anchor_cm = nil
    if candidate.world_anchor_cm ~= nil then
        world_anchor_cm = {
            x = candidate.world_anchor_cm.x,
            y = candidate.world_anchor_cm.y,
            z = candidate.world_anchor_cm.z,
        }
    end
    return {
        target_cell_id = candidate.target_cell_id,
        target_role = candidate.target_role,
        surface_type = candidate.surface_type,
        validity = candidate.validity,
        invalid_reason = candidate.invalid_reason,
        link_ids = link_ids,
        path_cell_ids = path_cell_ids,
        route_cost = candidate.route_cost,
        rise_levels = candidate.rise_levels,
        drop_levels = candidate.drop_levels,
        remaining_water_cells_after = candidate.remaining_water_cells_after,
        world_anchor_cm = world_anchor_cm,
        capability_id = candidate.capability_id,
        water_zone_id = candidate.water_zone_id,
        mode = candidate.mode,
        path_key = candidate.path_key,
    }
end

local function copy_candidates(list)
    local copied = {}
    local index
    for index = 1, #list do
        copied[index] = copy_candidate(list[index])
    end
    return copied
end

local function public_targeting(targeting)
    if targeting == nil then
        return nil
    end
    return {
        targeting_session_id = targeting.targeting_session_id,
        scope = targeting.scope,
        actor_id = targeting.actor_id,
        origin_cell_id = targeting.origin_cell_id,
        source_vector = copy_source_vector(targeting.source_vector),
        candidate_set_hash = targeting.candidate_set_hash,
        candidates = copy_candidates(targeting.candidates),
        valid_candidates = copy_candidates(targeting.valid_candidates),
        parent_traversal_session_id = targeting.parent_traversal_session_id,
        expected_parent_segment_sequence = targeting.expected_parent_segment_sequence,
        water_zone_id = targeting.water_zone_id,
        water_remaining_before = targeting.water_remaining_before,
        state = targeting.state,
    }
end

local function public_traversal(traversal)
    if traversal == nil then
        return nil
    end
    return {
        traversal_session_id = traversal.traversal_session_id,
        entry_command_id = traversal.entry_command_id,
        active_segment_command_id = traversal.active_segment_command_id,
        segment_sequence = traversal.segment_sequence,
        actor_id = traversal.actor_id,
        mode = traversal.mode,
        state = traversal.state,
        origin_cell_id = traversal.origin_cell_id,
        current_cell_id = traversal.current_cell_id,
        target_cell_id = traversal.target_cell_id,
        path_cell_ids = copy_array_local(traversal.path_cell_ids),
        link_ids = copy_array_local(traversal.link_ids),
        source_vector = copy_source_vector(traversal.source_vector),
        candidate_set_hash = traversal.candidate_set_hash,
        movement_token = traversal.movement_token,
        last_safe_marker_id = traversal.last_safe_marker_id,
        water_zone_id = traversal.water_zone_id,
        water_budget_total = traversal.water_budget_total,
        water_budget_remaining = traversal.water_budget_remaining,
        landing_receipt_id = traversal.landing_receipt_id,
        authorized_candidate = traversal.authorized_candidate
            and copy_candidate(traversal.authorized_candidate)
            or nil,
    }
end

function Runtime.landing_tuple(input)
    if type_value(input) ~= 'table' then
        return invalid('LANDING_TUPLE_INPUT_REQUIRED')
    end
    local values = {
        player_save_scope = raw_get(input, 'player_save_scope'),
        traversal_session_id = raw_get(input, 'traversal_session_id'),
        active_segment_command_id = raw_get(input, 'active_segment_command_id'),
        segment_sequence = raw_get(input, 'segment_sequence'),
        target_cell_id = raw_get(input, 'target_cell_id'),
        rules_version = raw_get(input, 'rules_version'),
    }
    if type_value(values.player_save_scope) ~= 'string'
        or values.player_save_scope == ''
    then
        return invalid('PLAYER_SAVE_SCOPE_REQUIRED')
    end
    local session_check = validate_derived(
        values.traversal_session_id,
        'traversal_session_id'
    )
    if not session_check.ok then
        return invalid('TRAVERSAL_SESSION_ID_INVALID')
    end
    local command_check = validate_derived(
        values.active_segment_command_id,
        'active_segment_command_id'
    )
    if not command_check.ok then
        return invalid('ACTIVE_SEGMENT_COMMAND_ID_INVALID')
    end
    if type_value(values.segment_sequence) ~= 'number'
        or values.segment_sequence ~= math_floor(values.segment_sequence)
        or values.segment_sequence < 1
    then
        return invalid('SEGMENT_SEQUENCE_INVALID')
    end
    local cell_check = validate_content(
        values.target_cell_id,
        'traversal_cell_',
        'target_cell_id'
    )
    if not cell_check.ok then
        return invalid('TARGET_CELL_ID_INVALID')
    end
    if type_value(values.rules_version) ~= 'number'
        or values.rules_version ~= math_floor(values.rules_version)
        or values.rules_version < 1
    then
        return invalid('RULES_VERSION_INVALID')
    end
    local derived = CanonicalReceiptHashV1.derive(
        'traversal_landing',
        LANDING_TUPLE_FIELDS,
        values
    )
    if not derived.ok then
        return derived
    end
    return result_ok({
        tuple = values,
        landing_receipt_id = derived.value.receipt_id,
        digest = derived.value.digest,
    })
end

local function open_result_view(targeting)
    return {
        targeting = public_targeting(targeting),
        candidate_set_hash = targeting.candidate_set_hash,
        source_vector = copy_source_vector(targeting.source_vector),
        valid_count = #targeting.valid_candidates,
        total_count = #targeting.candidates,
    }
end

function Runtime.open_targeting(state, catalog, profile, world_context, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end
    local request_id = raw_get(input, 'request_id')
    local request_check = validate_derived(request_id, 'request_id')
    if not request_check.ok then
        return invalid('REQUEST_ID_INVALID')
    end
    local prior = state.open_receipts[request_id]
    if prior ~= nil then
        return result_ok(prior)
    end

    if world_context.input_locked == true then
        return fail(
            TraversalErrorCodes.TRAVERSAL_INPUT_LOCKED,
            'WORLD_INPUT_LOCKED',
            { lock_reason = world_context.lock_reason }
        )
    end
    local actor_id = raw_get(input, 'actor_id') or world_context.actor_id
    if actor_id ~= world_context.actor_id then
        return fail(
            TraversalErrorCodes.TRAVERSAL_ACTOR_NOT_PROTAGONIST,
            'ACTOR_NOT_PROTAGONIST',
            {
                actor_id = actor_id,
                protagonist_id = world_context.actor_id,
            }
        )
    end

    local parent_id = raw_get(input, 'parent_traversal_session_id')
    local scope = 'GROUND_OR_ENTRY'
    local origin_cell_id
    local water_zone_id
    local water_remaining_before
    local expected_parent_segment_sequence

    if parent_id ~= nil then
        local parent = state.traversal
        if parent == nil
            or parent.traversal_session_id ~= parent_id
            or parent.state ~= 'ON_WATER_IDLE'
        then
            return fail(
                TraversalErrorCodes.TRAVERSAL_PARENT_SESSION_INVALID,
                'PARENT_NOT_ON_WATER_IDLE',
                { parent_traversal_session_id = parent_id }
            )
        end
        if state.targeting ~= nil then
            return fail(
                TraversalErrorCodes.TRAVERSAL_BUSY,
                'TARGETING_ALREADY_OPEN'
            )
        end
        scope = 'WATER_SEGMENT'
        origin_cell_id = parent.current_cell_id
        water_zone_id = parent.water_zone_id
        water_remaining_before = parent.water_budget_remaining
        expected_parent_segment_sequence = parent.segment_sequence
    else
        if state.traversal ~= nil then
            return fail(
                TraversalErrorCodes.TRAVERSAL_ACTIVE,
                'TRAVERSAL_SESSION_ACTIVE',
                { state = state.traversal.state }
            )
        end
        if state.targeting ~= nil then
            return fail(
                TraversalErrorCodes.TRAVERSAL_BUSY,
                'TARGETING_ALREADY_OPEN'
            )
        end
        origin_cell_id = world_context.origin_cell_id
        if type_value(origin_cell_id) ~= 'string' then
            return fail(
                TraversalErrorCodes.TRAVERSAL_ORIGIN_UNKNOWN,
                'WORLD_ORIGIN_MISSING'
            )
        end
    end

    if #profile.capability_specs == 0 then
        return fail(
            TraversalErrorCodes.TRAVERSAL_CAPABILITY_MISSING,
            'NO_LIGHTNESS_CAPABILITY'
        )
    end

    local query = Reachability.compute(catalog, profile, {
        scope = scope,
        origin_cell_id = origin_cell_id,
        spatial_revision = world_context.spatial_revision or catalog:spatial_revision(),
        world_revision = world_context.world_revision or 0,
        parent_traversal_session_id = parent_id,
        expected_parent_segment_sequence = expected_parent_segment_sequence,
        water_zone_id = water_zone_id,
        water_remaining_before = water_remaining_before,
    })
    if not query.ok then
        return query
    end
    query = query.value

    local targeting_session_id = 'targeting_' .. request_id
    local targeting = {
        targeting_session_id = targeting_session_id,
        request_id = request_id,
        scope = scope,
        actor_id = actor_id,
        origin_cell_id = origin_cell_id,
        source_vector = copy_source_vector(query.source_vector),
        candidate_set_hash = query.candidate_set_hash,
        candidates = copy_candidates(query.candidates),
        valid_candidates = copy_candidates(query.valid_candidates),
        parent_traversal_session_id = parent_id,
        expected_parent_segment_sequence = expected_parent_segment_sequence,
        water_zone_id = water_zone_id,
        water_remaining_before = water_remaining_before,
        state = 'TARGETING',
        created_sequence = next_sequence(state),
    }
    state.targeting = targeting
    if state.traversal ~= nil and scope == 'WATER_SEGMENT' then
        state.traversal.active_targeting_session_id = targeting_session_id
    end

    local view = open_result_view(targeting)
    state.open_receipts[request_id] = view
    return result_ok(view)
end

function Runtime.cancel_targeting(state, input)
    if type_value(state) ~= 'table' then
        return invalid('STATE_REQUIRED')
    end
    input = input or {}
    local targeting = state.targeting
    if targeting == nil then
        return fail(
            TraversalErrorCodes.TRAVERSAL_TARGETING_NOT_FOUND,
            'NO_ACTIVE_TARGETING'
        )
    end
    local session_id = raw_get(input, 'targeting_session_id')
    if session_id ~= nil and session_id ~= targeting.targeting_session_id then
        return fail(
            TraversalErrorCodes.TRAVERSAL_TARGETING_NOT_FOUND,
            'TARGETING_ID_MISMATCH',
            {
                expected = targeting.targeting_session_id,
                actual = session_id,
            }
        )
    end
    local scope = targeting.scope
    state.targeting = nil
    if state.traversal ~= nil then
        state.traversal.active_targeting_session_id = nil
    end
    local resume_state = 'IDLE'
    if scope == 'WATER_SEGMENT' and state.traversal ~= nil then
        resume_state = 'ON_WATER_IDLE'
    end
    return result_ok({
        cancelled = true,
        scope = scope,
        resume_state = resume_state,
    })
end

local function source_matches(left, right)
    local compared = ReachabilitySourceVector.equals(left, right)
    if not compared.ok then
        return false
    end
    return compared.value == true
end

function Runtime.request_traversal(state, catalog, profile, world_context, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local command_id = raw_get(input, 'command_id')
    local command_check = validate_derived(command_id, 'command_id')
    if not command_check.ok then
        return invalid('COMMAND_ID_INVALID')
    end
    local prior = state.command_receipts[command_id]
    if prior ~= nil then
        local expected_hash = raw_get(input, 'input_digest')
        if expected_hash ~= nil and prior.input_digest ~= expected_hash then
            return fail(
                TraversalErrorCodes.TRAVERSAL_IDEMPOTENCY_CONFLICT,
                'COMMAND_INPUT_MISMATCH',
                { command_id = command_id }
            )
        end
        return result_ok(prior.result)
    end

    local targeting = state.targeting
    if targeting == nil then
        return fail(
            TraversalErrorCodes.TRAVERSAL_TARGETING_NOT_FOUND,
            'NO_ACTIVE_TARGETING'
        )
    end
    local targeting_session_id = raw_get(input, 'targeting_session_id')
    if targeting_session_id ~= targeting.targeting_session_id then
        return fail(
            TraversalErrorCodes.TRAVERSAL_TARGETING_NOT_FOUND,
            'TARGETING_ID_MISMATCH'
        )
    end

    local provided_vector = raw_get(input, 'source_vector')
    if provided_vector == nil
        or not source_matches(provided_vector, targeting.source_vector)
    then
        return fail(
            TraversalErrorCodes.TRAVERSAL_SOURCE_STALE,
            'SOURCE_VECTOR_MISMATCH'
        )
    end
    local provided_hash = raw_get(input, 'candidate_set_hash')
    if provided_hash ~= targeting.candidate_set_hash then
        return fail(
            TraversalErrorCodes.TRAVERSAL_SOURCE_STALE,
            'CANDIDATE_HASH_MISMATCH'
        )
    end

    local target_cell_id = raw_get(input, 'target_cell_id')
    if type_value(target_cell_id) ~= 'string' then
        return invalid('TARGET_CELL_ID_REQUIRED')
    end

    -- Recompute against latest profile/world; never trust the stored candidate list.
    local recompute_options = {
        scope = targeting.scope,
        origin_cell_id = targeting.origin_cell_id,
        spatial_revision = world_context.spatial_revision or catalog:spatial_revision(),
        world_revision = world_context.world_revision or 0,
        parent_traversal_session_id = targeting.parent_traversal_session_id,
        expected_parent_segment_sequence = targeting.expected_parent_segment_sequence,
        water_zone_id = targeting.water_zone_id,
        water_remaining_before = targeting.water_remaining_before,
    }
    if targeting.scope == 'GROUND_OR_ENTRY' then
        if world_context.origin_cell_id ~= targeting.origin_cell_id then
            return fail(
                TraversalErrorCodes.TRAVERSAL_SOURCE_STALE,
                'ORIGIN_CHANGED'
            )
        end
    else
        local parent = state.traversal
        if parent == nil
            or parent.traversal_session_id ~= targeting.parent_traversal_session_id
            or parent.state ~= 'ON_WATER_IDLE'
            or parent.segment_sequence ~= targeting.expected_parent_segment_sequence
            or parent.water_budget_remaining ~= targeting.water_remaining_before
            or parent.water_zone_id ~= targeting.water_zone_id
            or parent.current_cell_id ~= targeting.origin_cell_id
        then
            return fail(
                TraversalErrorCodes.TRAVERSAL_PARENT_SESSION_INVALID,
                'PARENT_SNAPSHOT_STALE'
            )
        end
    end

    local recomputed = Reachability.compute(catalog, profile, recompute_options)
    if not recomputed.ok then
        return recomputed
    end
    recomputed = recomputed.value
    if not source_matches(recomputed.source_vector, targeting.source_vector)
        or recomputed.candidate_set_hash ~= targeting.candidate_set_hash
    then
        return fail(
            TraversalErrorCodes.TRAVERSAL_SOURCE_STALE,
            'RECOMPUTE_DIVERGED'
        )
    end

    local candidate = Reachability.find_valid_candidate(recomputed, target_cell_id)
    if not candidate.ok then
        return candidate
    end
    candidate = candidate.value

    local mode = candidate.mode
    local traversal
    local movement_token = 'move_' .. command_id
    if targeting.scope == 'WATER_SEGMENT' then
        traversal = state.traversal
        traversal.active_segment_command_id = command_id
        traversal.segment_sequence = traversal.segment_sequence + 1
        traversal.mode = mode
        traversal.state = mode == 'WATER_EXIT' and 'WATER_EXITING' or 'WATER_MOVING'
        traversal.origin_cell_id = targeting.origin_cell_id
        traversal.target_cell_id = candidate.target_cell_id
        traversal.path_cell_ids = copy_array_local(candidate.path_cell_ids)
        traversal.link_ids = copy_array_local(candidate.link_ids)
        traversal.source_vector = copy_source_vector(recomputed.source_vector)
        traversal.candidate_set_hash = recomputed.candidate_set_hash
        traversal.movement_token = movement_token
        traversal.authorized_candidate = copy_candidate(candidate)
        traversal.active_targeting_session_id = nil
    else
        if mode == 'WATER_ENTER' then
            traversal = {
                traversal_session_id = 'traversal_' .. command_id,
                entry_command_id = command_id,
                active_segment_command_id = command_id,
                segment_sequence = 1,
                actor_id = targeting.actor_id,
                mode = 'WATER_ENTER',
                state = 'WATER_ENTERING',
                origin_cell_id = targeting.origin_cell_id,
                current_cell_id = targeting.origin_cell_id,
                target_cell_id = candidate.target_cell_id,
                path_cell_ids = copy_array_local(candidate.path_cell_ids),
                link_ids = copy_array_local(candidate.link_ids),
                source_vector = copy_source_vector(recomputed.source_vector),
                candidate_set_hash = recomputed.candidate_set_hash,
                movement_token = movement_token,
                last_safe_marker_id = world_context.last_safe_marker_id,
                water_zone_id = candidate.water_zone_id,
                water_budget_total = profile_water_budget(profile),
                water_budget_remaining = profile_water_budget(profile),
                landing_receipt_id = nil,
                authorized_candidate = copy_candidate(candidate),
                active_targeting_session_id = nil,
            }
        else
            traversal = {
                traversal_session_id = 'traversal_' .. command_id,
                entry_command_id = command_id,
                active_segment_command_id = command_id,
                segment_sequence = 1,
                actor_id = targeting.actor_id,
                mode = 'JUMP',
                state = 'AUTHORIZED',
                origin_cell_id = targeting.origin_cell_id,
                current_cell_id = targeting.origin_cell_id,
                target_cell_id = candidate.target_cell_id,
                path_cell_ids = copy_array_local(candidate.path_cell_ids),
                link_ids = copy_array_local(candidate.link_ids),
                source_vector = copy_source_vector(recomputed.source_vector),
                candidate_set_hash = recomputed.candidate_set_hash,
                movement_token = movement_token,
                last_safe_marker_id = world_context.last_safe_marker_id,
                water_zone_id = nil,
                water_budget_total = nil,
                water_budget_remaining = nil,
                landing_receipt_id = nil,
                authorized_candidate = copy_candidate(candidate),
                active_targeting_session_id = nil,
            }
        end
        state.traversal = traversal
    end

    state.targeting = nil

    local input_digest = command_id
        .. '|'
        .. targeting.targeting_session_id
        .. '|'
        .. target_cell_id
        .. '|'
        .. targeting.candidate_set_hash
    local result = {
        accepted = true,
        traversal = public_traversal(traversal),
        mode = mode,
        movement_token = movement_token,
        segment_sequence = traversal.segment_sequence,
        candidate = copy_candidate(candidate),
    }
    state.command_receipts[command_id] = {
        input_digest = raw_get(input, 'input_digest') or input_digest,
        result = result,
    }
    return result_ok(result)
end

function Runtime.complete_segment(state, catalog, world_context, input, position_commit)
    if type_value(state) ~= 'table' then
        return invalid('STATE_REQUIRED')
    end
    if type_value(input) ~= 'table' then
        return invalid('INPUT_REQUIRED')
    end
    local traversal = state.traversal
    if traversal == nil then
        return fail(
            TraversalErrorCodes.TRAVERSAL_SESSION_NOT_FOUND,
            'NO_ACTIVE_TRAVERSAL'
        )
    end
    local session_id = raw_get(input, 'traversal_session_id')
    if session_id ~= nil and session_id ~= traversal.traversal_session_id then
        return fail(
            TraversalErrorCodes.TRAVERSAL_SESSION_NOT_FOUND,
            'SESSION_MISMATCH'
        )
    end
    local token = raw_get(input, 'movement_token')
    if token ~= nil and token ~= traversal.movement_token then
        return fail(
            TraversalErrorCodes.TRAVERSAL_TOKEN_INVALID,
            'MOVEMENT_TOKEN_MISMATCH'
        )
    end
    local sequence = raw_get(input, 'segment_sequence')
    if sequence ~= nil and sequence ~= traversal.segment_sequence then
        return fail(
            TraversalErrorCodes.TRAVERSAL_TOKEN_INVALID,
            'SEGMENT_SEQUENCE_MISMATCH'
        )
    end

    local active_states = {
        AUTHORIZED = true,
        WATER_ENTERING = true,
        WATER_MOVING = true,
        WATER_EXITING = true,
    }
    if not active_states[traversal.state] then
        return fail(
            TraversalErrorCodes.TRAVERSAL_BUSY,
            'SEGMENT_NOT_EXECUTABLE',
            { state = traversal.state }
        )
    end

    local candidate = traversal.authorized_candidate
    if candidate == nil then
        return fail(
            TraversalErrorCodes.TRAVERSAL_BUILD_INVALID,
            'AUTHORIZED_CANDIDATE_MISSING'
        )
    end

    local target = catalog:require_cell(candidate.target_cell_id)
    if not target.ok then
        return target
    end
    target = target.value

    local events = {}
    local committed_marker = nil
    local landing_receipt_id = nil

    if candidate.mode == 'JUMP' or candidate.mode == 'WATER_EXIT' then
        if target.landing_safety ~= 'SAFE_GROUND' or target.safe_marker_id == nil then
            return fail(
                TraversalErrorCodes.TRAVERSAL_LANDING_UNSAFE,
                'TARGET_NOT_SAFE_GROUND'
            )
        end
        local tuple = Runtime.landing_tuple({
            player_save_scope = world_context.player_save_scope or 'player_default',
            traversal_session_id = traversal.traversal_session_id,
            active_segment_command_id = traversal.active_segment_command_id,
            segment_sequence = traversal.segment_sequence,
            target_cell_id = candidate.target_cell_id,
            rules_version = traversal.source_vector.rules_version,
        })
        if not tuple.ok then
            return tuple
        end
        if type_value(position_commit) ~= 'function' then
            return fail(
                TraversalErrorCodes.TRAVERSAL_COMMIT_FAILED,
                'POSITION_COMMIT_REQUIRED'
            )
        end
        local committed = position_commit({
            landing_receipt_id = tuple.value.landing_receipt_id,
            digest = tuple.value.digest,
            tuple = tuple.value.tuple,
            marker_id = target.safe_marker_id,
            target_cell_id = candidate.target_cell_id,
            mode = candidate.mode,
        })
        if not committed.ok then
            return fail(
                TraversalErrorCodes.TRAVERSAL_COMMIT_FAILED,
                'POSITION_COMMIT_REJECTED',
                {
                    cause_code = committed.error and committed.error.code or 'UNKNOWN',
                }
            )
        end
        landing_receipt_id = committed.value.landing_receipt_id or tuple.value.landing_receipt_id
        committed_marker = committed.value.marker_id or target.safe_marker_id
        local from_cell_id = traversal.origin_cell_id
        local water_zone_id = traversal.water_zone_id
        local session_id = traversal.traversal_session_id
        local segment_sequence = traversal.segment_sequence
        traversal.landing_receipt_id = landing_receipt_id
        traversal.last_safe_marker_id = committed_marker
        traversal.current_cell_id = candidate.target_cell_id

        local landed = TraversalEvents.build_landed({
            landing_receipt_id = landing_receipt_id,
            traversal_session_id = session_id,
            from_cell_id = from_cell_id,
            to_cell_id = candidate.target_cell_id,
            target_cell_id = candidate.target_cell_id,
            traversed_link_ids = candidate.link_ids,
            marker_id = committed_marker,
            segment_sequence = segment_sequence,
            mode = candidate.mode,
            water_zone_id = water_zone_id,
            revision = committed.value.world_revision or 0,
        })
        if not landed.ok then
            return landed
        end
        events[#events + 1] = landed.value

        if candidate.mode == 'WATER_EXIT' then
            local exited = TraversalEvents.build_water_exited({
                landing_receipt_id = landing_receipt_id,
                traversal_session_id = session_id,
                water_zone_id = water_zone_id,
                shore_cell_id = candidate.target_cell_id,
                shore_marker_id = committed_marker,
                marker_id = committed_marker,
                segment_sequence = segment_sequence,
                revision = committed.value.world_revision or 0,
            })
            if not exited.ok then
                return exited
            end
            events[#events + 1] = exited.value
        end
        state.traversal = nil
        return result_ok({
            status = 'COMMITTED',
            events = events,
            domain_events = events,
            landing_receipt_id = landing_receipt_id,
            marker_id = committed_marker,
            resume_state = 'STABLE_GROUND',
            traversal = nil,
            world_revision = committed.value.world_revision,
            already_committed = committed.value.already_committed == true,
        })
    end

    -- Water enter / water step: no durable landing, budget update only.
    local cost = candidate.route_cost
    if traversal.water_budget_remaining == nil or traversal.water_budget_remaining < cost then
        return fail(
            TraversalErrorCodes.TRAVERSAL_OUT_OF_RANGE,
            'WATER_BUDGET_EXCEEDED'
        )
    end
    traversal.water_budget_remaining = traversal.water_budget_remaining - cost
    traversal.current_cell_id = candidate.target_cell_id
    traversal.origin_cell_id = candidate.target_cell_id
    traversal.target_cell_id = nil
    traversal.path_cell_ids = {}
    traversal.link_ids = {}
    traversal.movement_token = nil
    traversal.authorized_candidate = nil
    traversal.state = 'ON_WATER_IDLE'

    local domain_events = {}
    if candidate.mode == 'WATER_ENTER' then
        local entered = TraversalEvents.build_water_entered({
            traversal_session_id = traversal.traversal_session_id,
            water_zone_id = traversal.water_zone_id,
            entry_cell_id = candidate.target_cell_id,
            remaining = traversal.water_budget_remaining,
            segment_sequence = traversal.segment_sequence,
            revision = 0,
        })
        if not entered.ok then
            return entered
        end
        events[#events + 1] = entered.value
        domain_events[#domain_events + 1] = entered.value
    else
        -- Runtime notice only; not a quest-facing durable fact.
        events[#events + 1] = {
            event_type = 'WaterWalkAdvanced',
            traversal_session_id = traversal.traversal_session_id,
            water_zone_id = traversal.water_zone_id,
            to_cell_id = candidate.target_cell_id,
            remaining = traversal.water_budget_remaining,
            segment_sequence = traversal.segment_sequence,
        }
    end

    return result_ok({
        status = 'ON_WATER_IDLE',
        events = events,
        domain_events = domain_events,
        remaining_water_cells = traversal.water_budget_remaining,
        current_cell_id = traversal.current_cell_id,
        resume_state = 'ON_WATER_IDLE',
        traversal = public_traversal(traversal),
    })
end

function Runtime.recover(state, world_context, input)
    if type_value(state) ~= 'table' then
        return invalid('STATE_REQUIRED')
    end
    input = input or {}
    local recovery_id = raw_get(input, 'recovery_id')
    if recovery_id ~= nil then
        local checked = validate_derived(recovery_id, 'recovery_id')
        if not checked.ok then
            return invalid('RECOVERY_ID_INVALID')
        end
        local prior = state.recovery_receipts[recovery_id]
        if prior ~= nil then
            return result_ok(prior)
        end
    end

    local safe_marker = world_context.last_safe_marker_id
    local safe_cell = world_context.origin_cell_id
    if type_value(safe_marker) ~= 'string' or safe_marker == '' then
        return fail(
            TraversalErrorCodes.TRAVERSAL_SAFE_MARKER_INVALID,
            'LAST_SAFE_MISSING'
        )
    end

    local had_traversal = state.traversal ~= nil
    local had_targeting = state.targeting ~= nil
    local session_id = state.traversal and state.traversal.traversal_session_id or nil
    state.targeting = nil
    state.traversal = nil

    local result = {
        recovered = true,
        had_traversal = had_traversal,
        had_targeting = had_targeting,
        traversal_session_id = session_id,
        safe_marker_id = safe_marker,
        safe_cell_id = safe_cell,
        reason = raw_get(input, 'reason') or 'MANUAL_RECOVER',
        events = {
            {
                event_type = 'TraversalRecoveryCompleted',
                recovery_id = recovery_id,
                safe_marker_id = safe_marker,
                reason = raw_get(input, 'reason') or 'MANUAL_RECOVER',
            },
        },
    }
    if recovery_id ~= nil then
        state.recovery_receipts[recovery_id] = result
    end
    return result_ok(result)
end

function Runtime.snapshot(state)
    return {
        targeting = public_targeting(state.targeting),
        traversal = public_traversal(state.traversal),
    }
end

return Runtime
