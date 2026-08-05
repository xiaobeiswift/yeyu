-- Deterministic reachability for system 26.
-- Jump uses single-hop JUMP_DIRECT links with JUMP_DUAL_LIMIT.
-- Water uses WATER_ENTER / WATER_STEP / WATER_EXIT with WATER_SESSION_COST.

local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local ReachabilitySourceVector = require 'wzx.domain.contracts.reachability_source_vector'
local TraversalErrorCodes = require 'wzx.domain.traversal.error_codes'

local Reachability = {}
local bytewise_string_less = Ordered.bytewise_string_less
local result_err = Result.err
local result_ok = Result.ok
local table_concat = table.concat
local table_sort = table.sort
local type_value = type

local CAPABILITY_ORDER = {
    JUMP_BASIC = 1,
    JUMP_LONG = 2,
    JUMP_HIGH = 3,
    WATER_WALK = 4,
}
local TARGET_ROLE_ORDER = {
    LANDING = 1,
    WATER_STEP = 2,
    SHORE_EXIT = 3,
    NEIGHBOR_INVALID = 4,
}
local CANDIDATE_HASH_FIELDS = {
    { name = 'scope', type = 'STRING' },
    { name = 'origin_cell_id', type = 'STRING' },
    { name = 'spatial_revision', type = 'INTEGER' },
    { name = 'world_revision', type = 'INTEGER' },
    { name = 'source_loadout_revision', type = 'INTEGER' },
    { name = 'source_progress_revision', type = 'INTEGER' },
    { name = 'profile_hash', type = 'STRING' },
    { name = 'rules_version', type = 'INTEGER' },
    { name = 'parent_traversal_session_id', type = 'STRING' },
    { name = 'expected_parent_segment_sequence', type = 'INTEGER' },
    { name = 'water_zone_id', type = 'STRING' },
    { name = 'water_remaining_before', type = 'INTEGER' },
    { name = 'candidates_digest', type = 'STRING' },
}
local CANDIDATE_ROW_HASH_FIELDS = {
    { name = 'target_cell_id', type = 'STRING' },
    { name = 'target_role', type = 'STRING' },
    { name = 'surface_type', type = 'STRING' },
    { name = 'validity', type = 'STRING' },
    { name = 'invalid_reason', type = 'STRING' },
    { name = 'route_cost', type = 'INTEGER' },
    { name = 'rise_levels', type = 'INTEGER' },
    { name = 'drop_levels', type = 'INTEGER' },
    { name = 'remaining_water_cells_after', type = 'INTEGER' },
    { name = 'path_key', type = 'STRING' },
    { name = 'previous_digest', type = 'STRING' },
}
local ZERO_DIGEST = string.rep('0', 64)

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.traversal.' .. string.lower(code),
        false,
        details
    )
end

local function copy_array(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

local function path_key(link_ids, path_cell_ids)
    return table_concat(link_ids, ',') .. '|' .. table_concat(path_cell_ids, ',')
end

local function index_capabilities(profile)
    local by_id = {}
    local index
    for index = 1, #profile.capability_specs do
        local spec = profile.capability_specs[index]
        by_id[spec.capability_id] = spec
    end
    return by_id
end

local function capability_satisfies_jump(spec, link)
    if spec == nil then
        return false
    end
    if link.horizontal_cost > spec.jump_range_cells then
        return false
    end
    if link.horizontal_cost > spec.max_route_cost then
        return false
    end
    if link.rise_levels > spec.max_rise_levels then
        return false
    end
    if link.drop_levels > spec.max_drop_levels then
        return false
    end
    return true
end

local function choose_jump_capability(capabilities, link)
    local best = nil
    local best_order = nil
    local capability_id
    for capability_id, order in pairs(CAPABILITY_ORDER) do
        if capability_id ~= 'WATER_WALK' then
            local spec = capabilities[capability_id]
            if capability_satisfies_jump(spec, link) then
                if best == nil
                    or order < best_order
                then
                    best = spec
                    best_order = order
                end
            end
        end
    end
    return best
end

local function sort_candidates(candidates)
    table_sort(candidates, function(left, right)
        local left_valid = left.validity == 'VALID' and 0 or 1
        local right_valid = right.validity == 'VALID' and 0 or 1
        if left_valid ~= right_valid then
            return left_valid < right_valid
        end
        local left_role = TARGET_ROLE_ORDER[left.target_role] or 99
        local right_role = TARGET_ROLE_ORDER[right.target_role] or 99
        if left_role ~= right_role then
            return left_role < right_role
        end
        if left.route_cost ~= right.route_cost then
            return left.route_cost < right.route_cost
        end
        if left.target_cell_id ~= right.target_cell_id then
            return bytewise_string_less(left.target_cell_id, right.target_cell_id)
        end
        return bytewise_string_less(left.path_key, right.path_key)
    end)
end

local function hash_candidates(scope_context, candidates)
    local previous = ZERO_DIGEST
    local index
    for index = 1, #candidates do
        local candidate = candidates[index]
        local remaining = candidate.remaining_water_cells_after
        if remaining == nil then
            remaining = -1
        end
        local invalid_reason = candidate.invalid_reason or ''
        local derived = CanonicalReceiptHashV1.derive(
            'traversal_candidate_row',
            CANDIDATE_ROW_HASH_FIELDS,
            {
                target_cell_id = candidate.target_cell_id,
                target_role = candidate.target_role,
                surface_type = candidate.surface_type,
                validity = candidate.validity,
                invalid_reason = invalid_reason,
                route_cost = candidate.route_cost,
                rise_levels = candidate.rise_levels,
                drop_levels = candidate.drop_levels,
                remaining_water_cells_after = remaining,
                path_key = candidate.path_key,
                previous_digest = previous,
            }
        )
        if not derived.ok then
            return derived
        end
        previous = derived.value.digest
    end

    local hashed = CanonicalReceiptHashV1.derive(
        'traversal_candidate_set',
        CANDIDATE_HASH_FIELDS,
        {
            scope = scope_context.scope,
            origin_cell_id = scope_context.origin_cell_id,
            spatial_revision = scope_context.source_vector.spatial_revision,
            world_revision = scope_context.source_vector.world_revision,
            source_loadout_revision = scope_context.source_vector.source_loadout_revision,
            source_progress_revision = scope_context.source_vector.source_progress_revision,
            profile_hash = scope_context.source_vector.profile_hash,
            rules_version = scope_context.source_vector.rules_version,
            parent_traversal_session_id = scope_context.parent_traversal_session_id or '',
            expected_parent_segment_sequence = scope_context.expected_parent_segment_sequence or 0,
            water_zone_id = scope_context.water_zone_id or '',
            water_remaining_before = scope_context.water_remaining_before or -1,
            candidates_digest = previous,
        }
    )
    if not hashed.ok then
        return hashed
    end
    return result_ok(hashed.value.digest)
end

local function make_candidate(fields)
    local candidate = {
        target_cell_id = fields.target_cell_id,
        target_role = fields.target_role,
        surface_type = fields.surface_type,
        validity = fields.validity,
        invalid_reason = fields.invalid_reason,
        link_ids = copy_array(fields.link_ids),
        path_cell_ids = copy_array(fields.path_cell_ids),
        route_cost = fields.route_cost,
        rise_levels = fields.rise_levels,
        drop_levels = fields.drop_levels,
        remaining_water_cells_after = fields.remaining_water_cells_after,
        world_anchor_cm = fields.world_anchor_cm,
        capability_id = fields.capability_id,
        water_zone_id = fields.water_zone_id,
        mode = fields.mode,
    }
    candidate.path_key = path_key(candidate.link_ids, candidate.path_cell_ids)
    return candidate
end

local function compute_jump_candidates(catalog, origin_cell_id, capabilities)
    local candidates = {}
    local seen_targets = {}
    local outgoing = catalog:outgoing_links(origin_cell_id)
    if not outgoing.ok then
        return outgoing
    end
    local index
    for index = 1, #outgoing.value do
        local link = outgoing.value[index]
        if link.link_type == 'JUMP_DIRECT' then
            local target = catalog:require_cell(link.to_cell_id)
            if not target.ok then
                return target
            end
            target = target.value
            if target.reveal_state == 'HIDDEN' then
                -- Hidden cells never appear in candidate lists.
            else
                local chosen = choose_jump_capability(capabilities, link)
                local validity = 'VALID'
                local invalid_reason = nil
                if capabilities.JUMP_BASIC == nil
                    and capabilities.JUMP_LONG == nil
                    and capabilities.JUMP_HIGH == nil
                then
                    validity = 'INVALID'
                    invalid_reason = 'CAPABILITY_MISSING'
                elseif chosen == nil then
                    if link.rise_levels > 0 or link.drop_levels > 0 then
                        validity = 'INVALID'
                        invalid_reason = 'HEIGHT_EXCEEDED'
                    else
                        validity = 'INVALID'
                        invalid_reason = 'OUT_OF_RANGE'
                    end
                elseif target.blocked then
                    validity = 'INVALID'
                    invalid_reason = 'PATH_BLOCKED'
                elseif target.landing_safety ~= 'SAFE_GROUND'
                    or target.surface_type ~= 'GROUND'
                then
                    validity = 'INVALID'
                    invalid_reason = 'LANDING_UNSAFE'
                end

                local candidate = make_candidate({
                    target_cell_id = target.id,
                    target_role = 'LANDING',
                    surface_type = target.surface_type,
                    validity = validity,
                    invalid_reason = invalid_reason,
                    link_ids = { link.id },
                    path_cell_ids = { origin_cell_id, target.id },
                    route_cost = link.horizontal_cost,
                    rise_levels = link.rise_levels,
                    drop_levels = link.drop_levels,
                    remaining_water_cells_after = nil,
                    world_anchor_cm = {
                        x = target.world_anchor_cm_x,
                        y = target.world_anchor_cm_y,
                        z = target.world_anchor_cm_z,
                    },
                    capability_id = chosen and chosen.capability_id or nil,
                    mode = 'JUMP',
                })
                local previous = seen_targets[target.id]
                if previous == nil
                    or candidate.validity == 'VALID' and previous.validity ~= 'VALID'
                    or (
                        candidate.validity == previous.validity
                        and (
                            candidate.route_cost < previous.route_cost
                            or (
                                candidate.route_cost == previous.route_cost
                                and bytewise_string_less(candidate.path_key, previous.path_key)
                            )
                        )
                    )
                then
                    seen_targets[target.id] = candidate
                end
            end
        end
    end

    local target_id
    for target_id in pairs(seen_targets) do
        candidates[#candidates + 1] = seen_targets[target_id]
    end
    return result_ok(candidates)
end

local function min_exit_cost_from(catalog, zone, from_cell_id)
    local best = nil
    local index
    for index = 1, #zone.exit_link_ids do
        local link = catalog:require_link(zone.exit_link_ids[index])
        if not link.ok then
            return link
        end
        link = link.value
        if link.from_cell_id == from_cell_id then
            if best == nil or link.horizontal_cost < best then
                best = link.horizontal_cost
            end
        end
    end
    -- Also allow multi-hop to an exit cell via WATER_STEP.
    -- Dijkstra distances to all zone cells, then add exit cost.
    local distances = {}
    local hop_counts = {}
    local previous_link = {}
    local previous_cell = {}
    distances[from_cell_id] = 0
    hop_counts[from_cell_id] = 0
    local queue = { from_cell_id }
    local head = 1
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        local outgoing = catalog:outgoing_links(current)
        if not outgoing.ok then
            return outgoing
        end
        local out_index
        for out_index = 1, #outgoing.value do
            local link = outgoing.value[out_index]
            if link.link_type == 'WATER_STEP'
                and link.water_zone_id == zone.id
            then
                local next_cost = distances[current] + link.horizontal_cost
                local next_hops = hop_counts[current] + 1
                local existing = distances[link.to_cell_id]
                local replace = false
                if existing == nil then
                    replace = true
                elseif next_cost < existing then
                    replace = true
                elseif next_cost == existing then
                    if next_hops < hop_counts[link.to_cell_id] then
                        replace = true
                    elseif next_hops == hop_counts[link.to_cell_id]
                        and bytewise_string_less(link.id, previous_link[link.to_cell_id] or '')
                    then
                        replace = true
                    end
                end
                if replace then
                    distances[link.to_cell_id] = next_cost
                    hop_counts[link.to_cell_id] = next_hops
                    previous_link[link.to_cell_id] = link.id
                    previous_cell[link.to_cell_id] = current
                    queue[#queue + 1] = link.to_cell_id
                end
            end
        end
    end

    best = nil
    for index = 1, #zone.exit_link_ids do
        local link = catalog:require_link(zone.exit_link_ids[index]).value
        local dist = distances[link.from_cell_id]
        if dist ~= nil then
            local total = dist + link.horizontal_cost
            if best == nil or total < best then
                best = total
            end
        end
    end
    return result_ok(best)
end

local function reconstruct_path(previous_link, previous_cell, origin, target)
    local link_ids = {}
    local path_cells = { target }
    local current = target
    while current ~= origin do
        local link_id = previous_link[current]
        local prev = previous_cell[current]
        if link_id == nil or prev == nil then
            return nil, nil
        end
        link_ids[#link_ids + 1] = link_id
        path_cells[#path_cells + 1] = prev
        current = prev
    end
    -- reverse
    local reversed_links = {}
    local reversed_cells = {}
    local index
    for index = #link_ids, 1, -1 do
        reversed_links[#reversed_links + 1] = link_ids[index]
    end
    for index = #path_cells, 1, -1 do
        reversed_cells[#reversed_cells + 1] = path_cells[index]
    end
    return reversed_links, reversed_cells
end

local function compute_water_segment_candidates(
    catalog,
    origin_cell_id,
    capabilities,
    water_zone_id,
    water_remaining_before
)
    local water_walk = capabilities.WATER_WALK
    if water_walk == nil then
        return result_ok({})
    end
    local zone = catalog:require_water_zone(water_zone_id)
    if not zone.ok then
        return zone
    end
    zone = zone.value

    local distances = {}
    local hop_counts = {}
    local previous_link = {}
    local previous_cell = {}
    local path_rise = {}
    local path_drop = {}
    distances[origin_cell_id] = 0
    hop_counts[origin_cell_id] = 0
    path_rise[origin_cell_id] = 0
    path_drop[origin_cell_id] = 0
    local queue = { origin_cell_id }
    local head = 1
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        local outgoing = catalog:outgoing_links(current)
        if not outgoing.ok then
            return outgoing
        end
        local index
        for index = 1, #outgoing.value do
            local link = outgoing.value[index]
            if (
                link.link_type == 'WATER_STEP'
                or link.link_type == 'WATER_EXIT'
            ) and link.water_zone_id == zone.id
            then
                local next_cost = distances[current] + link.horizontal_cost
                if next_cost <= water_remaining_before then
                    local next_hops = hop_counts[current] + 1
                    local existing = distances[link.to_cell_id]
                    local replace = false
                    if existing == nil then
                        replace = true
                    elseif next_cost < existing then
                        replace = true
                    elseif next_cost == existing then
                        if next_hops < hop_counts[link.to_cell_id] then
                            replace = true
                        elseif next_hops == hop_counts[link.to_cell_id]
                            and bytewise_string_less(
                                link.id,
                                previous_link[link.to_cell_id] or ''
                            )
                        then
                            replace = true
                        end
                    end
                    if replace then
                        distances[link.to_cell_id] = next_cost
                        hop_counts[link.to_cell_id] = next_hops
                        previous_link[link.to_cell_id] = link.id
                        previous_cell[link.to_cell_id] = current
                        path_rise[link.to_cell_id] = path_rise[current] + link.rise_levels
                        path_drop[link.to_cell_id] = path_drop[current] + link.drop_levels
                        queue[#queue + 1] = link.to_cell_id
                    end
                end
            end
        end
    end

    local candidates = {}
    local seen = {}
    local target_id
    for target_id in pairs(distances) do
        if target_id ~= origin_cell_id then
            local target = catalog:require_cell(target_id)
            if not target.ok then
                return target
            end
            target = target.value
            if target.reveal_state ~= 'HIDDEN' then
                local link_ids, path_cell_ids = reconstruct_path(
                    previous_link,
                    previous_cell,
                    origin_cell_id,
                    target_id
                )
                if link_ids ~= nil then
                    local last_link = catalog:require_link(link_ids[#link_ids])
                    if not last_link.ok then
                        return last_link
                    end
                    last_link = last_link.value
                    local cost = distances[target_id]
                    local remaining_after = water_remaining_before - cost
                    local role
                    local mode
                    local validity = 'VALID'
                    local invalid_reason = nil
                    if last_link.link_type == 'WATER_EXIT' then
                        role = 'SHORE_EXIT'
                        mode = 'WATER_EXIT'
                        if target.landing_safety ~= 'SAFE_GROUND' then
                            validity = 'INVALID'
                            invalid_reason = 'LANDING_UNSAFE'
                        end
                    else
                        role = 'WATER_STEP'
                        mode = 'WATER_STEP'
                        local exit_cost = min_exit_cost_from(catalog, zone, target_id)
                        if not exit_cost.ok then
                            return exit_cost
                        end
                        if exit_cost.value == nil
                            or remaining_after < exit_cost.value
                        then
                            validity = 'INVALID'
                            invalid_reason = 'NO_SAFE_WATER_EXIT'
                        end
                    end
                    local candidate = make_candidate({
                        target_cell_id = target_id,
                        target_role = role,
                        surface_type = target.surface_type,
                        validity = validity,
                        invalid_reason = invalid_reason,
                        link_ids = link_ids,
                        path_cell_ids = path_cell_ids,
                        route_cost = cost,
                        rise_levels = path_rise[target_id] or 0,
                        drop_levels = path_drop[target_id] or 0,
                        remaining_water_cells_after = remaining_after,
                        world_anchor_cm = {
                            x = target.world_anchor_cm_x,
                            y = target.world_anchor_cm_y,
                            z = target.world_anchor_cm_z,
                        },
                        capability_id = 'WATER_WALK',
                        water_zone_id = zone.id,
                        mode = mode,
                    })
                    if seen[target_id] == nil then
                        seen[target_id] = true
                        candidates[#candidates + 1] = candidate
                    end
                end
            end
        end
    end
    return result_ok(candidates)
end

local function compute_water_enter_candidates(catalog, origin_cell_id, capabilities)
    local water_walk = capabilities.WATER_WALK
    if water_walk == nil then
        return result_ok({})
    end
    local candidates = {}
    local outgoing = catalog:outgoing_links(origin_cell_id)
    if not outgoing.ok then
        return outgoing
    end
    local index
    for index = 1, #outgoing.value do
        local link = outgoing.value[index]
        if link.link_type == 'WATER_ENTER' then
            local target = catalog:require_cell(link.to_cell_id)
            if not target.ok then
                return target
            end
            target = target.value
            if target.reveal_state ~= 'HIDDEN' then
                local zone = catalog:require_water_zone(link.water_zone_id)
                if not zone.ok then
                    return zone
                end
                zone = zone.value
                local budget = water_walk.water_range_cells
                local remaining_after = budget - link.horizontal_cost
                local validity = 'VALID'
                local invalid_reason = nil
                if link.horizontal_cost > budget then
                    validity = 'INVALID'
                    invalid_reason = 'OUT_OF_RANGE'
                elseif remaining_after < 0 then
                    validity = 'INVALID'
                    invalid_reason = 'OUT_OF_RANGE'
                else
                    local exit_cost = min_exit_cost_from(catalog, zone, target.id)
                    if not exit_cost.ok then
                        return exit_cost
                    end
                    if exit_cost.value == nil or remaining_after < exit_cost.value then
                        validity = 'INVALID'
                        invalid_reason = 'NO_SAFE_WATER_EXIT'
                    end
                end
                candidates[#candidates + 1] = make_candidate({
                    target_cell_id = target.id,
                    target_role = 'WATER_STEP',
                    surface_type = target.surface_type,
                    validity = validity,
                    invalid_reason = invalid_reason,
                    link_ids = { link.id },
                    path_cell_ids = { origin_cell_id, target.id },
                    route_cost = link.horizontal_cost,
                    rise_levels = link.rise_levels,
                    drop_levels = link.drop_levels,
                    remaining_water_cells_after = remaining_after >= 0 and remaining_after or 0,
                    world_anchor_cm = {
                        x = target.world_anchor_cm_x,
                        y = target.world_anchor_cm_y,
                        z = target.world_anchor_cm_z,
                    },
                    capability_id = 'WATER_WALK',
                    water_zone_id = zone.id,
                    mode = 'WATER_ENTER',
                })
            end
        end
    end
    return result_ok(candidates)
end

function Reachability.build_source_vector(profile, spatial_revision, world_revision)
    local vector = {
        spatial_revision = spatial_revision,
        world_revision = world_revision,
        source_loadout_revision = profile.source_loadout_revision,
        source_progress_revision = profile.source_progress_revision,
        profile_hash = profile.profile_hash,
        rules_version = profile.rules_version,
    }
    return ReachabilitySourceVector.validate(vector)
end

function Reachability.compute(catalog, profile, options)
    if type_value(catalog) ~= 'table' or type_value(catalog.require_cell) ~= 'function' then
        return fail(TraversalErrorCodes.TRAVERSAL_ARGUMENT_INVALID, 'CATALOG_REQUIRED')
    end
    if type_value(profile) ~= 'table' then
        return fail(TraversalErrorCodes.TRAVERSAL_ARGUMENT_INVALID, 'PROFILE_REQUIRED')
    end
    options = options or {}
    local scope = options.scope or 'GROUND_OR_ENTRY'
    local origin_cell_id = options.origin_cell_id
    if type_value(origin_cell_id) ~= 'string' then
        return fail(TraversalErrorCodes.TRAVERSAL_ORIGIN_UNKNOWN, 'ORIGIN_CELL_REQUIRED')
    end
    local origin = catalog:require_cell(origin_cell_id)
    if not origin.ok then
        return fail(TraversalErrorCodes.TRAVERSAL_ORIGIN_UNKNOWN, 'ORIGIN_CELL_MISSING', {
            origin_cell_id = origin_cell_id,
        })
    end
    origin = origin.value
    if origin.reveal_state == 'HIDDEN' then
        return fail(TraversalErrorCodes.TRAVERSAL_ORIGIN_UNKNOWN, 'ORIGIN_HIDDEN', {
            origin_cell_id = origin_cell_id,
        })
    end

    local spatial_revision = options.spatial_revision
    if spatial_revision == nil then
        spatial_revision = catalog:spatial_revision()
    end
    local world_revision = options.world_revision
    if world_revision == nil then
        world_revision = 0
    end
    local source_vector = Reachability.build_source_vector(
        profile,
        spatial_revision,
        world_revision
    )
    if not source_vector.ok then
        return source_vector
    end
    source_vector = source_vector.value

    local capabilities = index_capabilities(profile)
    local candidates
    if scope == 'WATER_SEGMENT' then
        if type_value(options.water_zone_id) ~= 'string'
            or type_value(options.water_remaining_before) ~= 'number'
        then
            return fail(
                TraversalErrorCodes.TRAVERSAL_PARENT_SESSION_INVALID,
                'WATER_SEGMENT_CONTEXT_REQUIRED'
            )
        end
        if origin.surface_type ~= 'WATER' then
            return fail(
                TraversalErrorCodes.TRAVERSAL_PARENT_SESSION_INVALID,
                'WATER_SEGMENT_ORIGIN_NOT_WATER'
            )
        end
        candidates = compute_water_segment_candidates(
            catalog,
            origin_cell_id,
            capabilities,
            options.water_zone_id,
            options.water_remaining_before
        )
    else
        if origin.surface_type ~= 'GROUND' or origin.landing_safety ~= 'SAFE_GROUND' then
            return fail(
                TraversalErrorCodes.TRAVERSAL_ORIGIN_UNKNOWN,
                'GROUND_ORIGIN_REQUIRED',
                { origin_cell_id = origin_cell_id }
            )
        end
        local jump = compute_jump_candidates(catalog, origin_cell_id, capabilities)
        if not jump.ok then
            return jump
        end
        local enter = compute_water_enter_candidates(catalog, origin_cell_id, capabilities)
        if not enter.ok then
            return enter
        end
        candidates = result_ok({})
        local merged = {}
        local index
        for index = 1, #jump.value do
            merged[#merged + 1] = jump.value[index]
        end
        for index = 1, #enter.value do
            merged[#merged + 1] = enter.value[index]
        end
        candidates = result_ok(merged)
    end
    if not candidates.ok then
        return candidates
    end
    candidates = candidates.value
    sort_candidates(candidates)

    local scope_context = {
        scope = scope,
        origin_cell_id = origin_cell_id,
        source_vector = source_vector,
        parent_traversal_session_id = options.parent_traversal_session_id,
        expected_parent_segment_sequence = options.expected_parent_segment_sequence,
        water_zone_id = options.water_zone_id,
        water_remaining_before = options.water_remaining_before,
    }
    local hashed = hash_candidates(scope_context, candidates)
    if not hashed.ok then
        return hashed
    end

    local valid_only = {}
    local index
    for index = 1, #candidates do
        if candidates[index].validity == 'VALID' then
            valid_only[#valid_only + 1] = candidates[index]
        end
    end

    return result_ok({
        scope = scope,
        origin_cell_id = origin_cell_id,
        source_vector = source_vector,
        candidates = candidates,
        valid_candidates = valid_only,
        candidate_set_hash = hashed.value,
        parent_traversal_session_id = options.parent_traversal_session_id,
        expected_parent_segment_sequence = options.expected_parent_segment_sequence,
        water_zone_id = options.water_zone_id,
        water_remaining_before = options.water_remaining_before,
    })
end

function Reachability.find_valid_candidate(query_result, target_cell_id)
    if type_value(query_result) ~= 'table' or type_value(query_result.valid_candidates) ~= 'table' then
        return fail(TraversalErrorCodes.TRAVERSAL_ARGUMENT_INVALID, 'QUERY_REQUIRED')
    end
    local index
    for index = 1, #query_result.valid_candidates do
        local candidate = query_result.valid_candidates[index]
        if candidate.target_cell_id == target_cell_id then
            return result_ok(candidate)
        end
    end
    return fail(TraversalErrorCodes.TRAVERSAL_UNREACHABLE, 'TARGET_NOT_IN_VALID_SET', {
        target_cell_id = target_cell_id,
    })
end

return Reachability
