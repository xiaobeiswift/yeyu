-- Offline world state authority for system 12.
-- Owns position, discovered locations, flags, and durable event receipts.

local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local WorldErrorCodes = require 'wzx.domain.world.error_codes'
local WorldEvents = require 'wzx.domain.world.world_events'

local WorldState = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_derived = RuntimeId.validate_derived

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.world.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(WorldErrorCodes.WORLD_ARGUMENT_INVALID, reason, details)
end

function WorldState.empty()
    return {
        world_revision = 0,
        position = {
            area_id = nil,
            location_id = nil,
            current_marker_id = nil,
            last_safe_marker_id = nil,
            last_landing_receipt_id = nil,
            current_cell_id = nil,
            facing_octant = 0,
        },
        discovered = {},
        flags = {},
        interactables = {},
        event_receipts = {},
        command_receipts = {},
        landing_receipts = {},
    }
end

local function ensure_interactable_row(state, interactable)
    local row = state.interactables[interactable.id]
    if row == nil then
        row = {
            interactable_id = interactable.id,
            state = interactable.initial_state or 'AVAILABLE',
            receipt_id = nil,
            reward_receipt_id = nil,
        }
        state.interactables[interactable.id] = row
    end
    return row
end

local function copy_position(position)
    return {
        area_id = position.area_id,
        location_id = position.location_id,
        current_marker_id = position.current_marker_id,
        last_safe_marker_id = position.last_safe_marker_id,
        last_landing_receipt_id = position.last_landing_receipt_id,
        current_cell_id = position.current_cell_id,
        facing_octant = position.facing_octant or 0,
    }
end

local function sorted_ids(map)
    local ids = {}
    local key
    for key in raw_next, map do
        ids[#ids + 1] = key
    end
    table_sort(ids, bytewise_string_less)
    return ids
end

local function values_equal(left, right)
    if left == right then
        return true
    end
    return false
end

local function validate_flag_value(flag_def, value)
    local value_type = flag_def.value_type
    if value_type == 'BOOLEAN' then
        if type_value(value) ~= 'boolean' then
            return fail(
                WorldErrorCodes.WORLD_FLAG_TYPE_MISMATCH,
                'BOOLEAN_REQUIRED',
                { flag_id = flag_def.id }
            )
        end
    elseif value_type == 'INTEGER' then
        if type_value(value) ~= 'number'
            or value ~= math.floor(value)
            or value < -1000000
            or value > 1000000
        then
            return fail(
                WorldErrorCodes.WORLD_FLAG_TYPE_MISMATCH,
                'INTEGER_REQUIRED',
                { flag_id = flag_def.id }
            )
        end
    else
        if type_value(value) ~= 'string' or #value > 64 then
            return fail(
                WorldErrorCodes.WORLD_FLAG_TYPE_MISMATCH,
                'STRING_REQUIRED',
                { flag_id = flag_def.id }
            )
        end
    end
    return result_ok(true)
end

function WorldState.bootstrap_position(state, catalog, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require_location) ~= 'function' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local location_id = raw_get(input, 'location_id')
    local location = catalog:require_location(location_id)
    if not location.ok then
        return location
    end
    location = location.value

    local marker_id = raw_get(input, 'marker_id')
        or location.safe_return_marker_id
        or location.discovery_marker_id
    local facing = raw_get(input, 'facing_octant')
    if facing == nil then
        facing = 0
    elseif type_value(facing) ~= 'number'
        or facing ~= math.floor(facing)
        or facing < 0
        or facing > 7
    then
        return invalid('FACING_INVALID')
    end

    state.position = {
        area_id = location.area_id,
        location_id = location.id,
        current_marker_id = marker_id,
        last_safe_marker_id = location.safe_return_marker_id or marker_id,
        last_landing_receipt_id = state.position.last_landing_receipt_id,
        current_cell_id = raw_get(input, 'current_cell_id') or state.position.current_cell_id,
        facing_octant = facing,
    }
    state.world_revision = state.world_revision + 1
    return result_ok({
        position = copy_position(state.position),
        world_revision = state.world_revision,
    })
end

function WorldState.enter_location(state, catalog, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local location_id = raw_get(input, 'location_id')
    local location = catalog:require_location(location_id)
    if not location.ok then
        return location
    end
    location = location.value

    local marker_id = raw_get(input, 'marker_id')
        or location.safe_return_marker_id
        or location.discovery_marker_id
    local facing = raw_get(input, 'facing_octant')
    if facing == nil then
        facing = state.position.facing_octant or 0
    elseif type_value(facing) ~= 'number'
        or facing ~= math.floor(facing)
        or facing < 0
        or facing > 7
    then
        return invalid('FACING_INVALID')
    end

    state.position = {
        area_id = location.area_id,
        location_id = location.id,
        current_marker_id = marker_id,
        last_safe_marker_id = location.safe_return_marker_id
            or state.position.last_safe_marker_id
            or marker_id,
        last_landing_receipt_id = state.position.last_landing_receipt_id,
        current_cell_id = raw_get(input, 'current_cell_id') or state.position.current_cell_id,
        facing_octant = facing,
    }
    state.world_revision = state.world_revision + 1
    return result_ok({
        position = copy_position(state.position),
        world_revision = state.world_revision,
    })
end

function WorldState.discover_location(state, catalog, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local location_id = raw_get(input, 'location_id')
    local discovery_receipt_id = raw_get(input, 'discovery_receipt_id')
    local command_id = raw_get(input, 'command_id')
    local also_enter = raw_get(input, 'also_enter')
    if also_enter == nil then
        also_enter = true
    end

    local receipt_check = validate_derived(discovery_receipt_id, 'discovery_receipt_id')
    if not receipt_check.ok then
        return invalid('DISCOVERY_RECEIPT_INVALID')
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = state.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'DISCOVER' then
            return result_ok({
                already_discovered = true,
                command_replay = true,
                location_id = prior.location_id,
                discovery_event = nil,
            })
        end
    end

    local location = catalog:require_location(location_id)
    if not location.ok then
        return location
    end
    location = location.value
    if location.discoverable ~= true then
        return fail(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'LOCATION_NOT_DISCOVERABLE',
            { location_id = location.id }
        )
    end

    if state.discovered[location.id] ~= nil then
        local existing = state.discovered[location.id]
        if existing.discovery_receipt_id == discovery_receipt_id then
            return result_ok({
                already_discovered = true,
                location_id = location.id,
                discovery_event = nil,
                position = copy_position(state.position),
            })
        end
        return result_ok({
            already_discovered = true,
            location_id = location.id,
            discovery_event = nil,
            position = copy_position(state.position),
        })
    end

    local discovery_event = WorldEvents.build_location_discovered(
        state,
        location,
        discovery_receipt_id
    )
    if not discovery_event.ok then
        return discovery_event
    end
    if state.event_receipts[discovery_event.value.event_id] ~= nil then
        return fail(
            WorldErrorCodes.WORLD_RECEIPT_CONFLICT,
            'DISCOVERY_EVENT_ALREADY_USED',
            { event_id = discovery_event.value.event_id }
        )
    end

    state.discovered[location.id] = {
        location_id = location.id,
        area_id = location.area_id,
        discovery_receipt_id = discovery_receipt_id,
    }
    state.event_receipts[discovery_event.value.event_id] = {
        event_id = discovery_event.value.event_id,
        event_type = discovery_event.value.event_type,
        receipt_id = discovery_receipt_id,
    }

    if also_enter then
        local entered = WorldState.enter_location(state, catalog, {
            location_id = location.id,
            marker_id = location.discovery_marker_id or location.safe_return_marker_id,
        })
        if not entered.ok then
            return entered
        end
    else
        state.world_revision = state.world_revision + 1
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        state.command_receipts[command_id] = {
            command_id = command_id,
            kind = 'DISCOVER',
            location_id = location.id,
            receipt_id = discovery_receipt_id,
        }
    end

    return result_ok({
        already_discovered = false,
        location_id = location.id,
        area_id = location.area_id,
        discovery_event = discovery_event.value,
        position = copy_position(state.position),
        world_revision = state.world_revision,
    })
end

function WorldState.set_flag(state, catalog, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local flag_id = raw_get(input, 'flag_id')
    local value = raw_get(input, 'value')
    local flag_receipt_id = raw_get(input, 'flag_receipt_id')
    local reason = raw_get(input, 'reason') or 'SET_FLAG'
    local command_id = raw_get(input, 'command_id')

    local receipt_check = validate_derived(flag_receipt_id, 'flag_receipt_id')
    if not receipt_check.ok then
        return invalid('FLAG_RECEIPT_INVALID')
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = state.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'SET_FLAG' then
            return result_ok({
                already_applied = true,
                command_replay = true,
                flag_id = prior.flag_id,
                flag_event = nil,
            })
        end
    end

    local flag = catalog:require_flag(flag_id)
    if not flag.ok then
        return flag
    end
    flag = flag.value

    local typed = validate_flag_value(flag, value)
    if not typed.ok then
        return typed
    end

    local old_value = state.flags[flag.id]
    if old_value == nil then
        old_value = flag.default_value
    end

    if values_equal(old_value, value) then
        return result_ok({
            already_applied = true,
            unchanged = true,
            flag_id = flag.id,
            old_value = old_value,
            new_value = value,
            flag_event = nil,
            world_revision = state.world_revision,
        })
    end

    local flag_event = WorldEvents.build_flag_changed(
        state,
        flag.id,
        old_value,
        value,
        reason,
        flag_receipt_id
    )
    if not flag_event.ok then
        return flag_event
    end
    if state.event_receipts[flag_event.value.event_id] ~= nil then
        return fail(
            WorldErrorCodes.WORLD_RECEIPT_CONFLICT,
            'FLAG_EVENT_ALREADY_USED',
            { event_id = flag_event.value.event_id }
        )
    end

    state.flags[flag.id] = value
    state.world_revision = state.world_revision + 1
    state.event_receipts[flag_event.value.event_id] = {
        event_id = flag_event.value.event_id,
        event_type = flag_event.value.event_type,
        receipt_id = flag_receipt_id,
    }
    if type_value(command_id) == 'string' and command_id ~= '' then
        state.command_receipts[command_id] = {
            command_id = command_id,
            kind = 'SET_FLAG',
            flag_id = flag.id,
            receipt_id = flag_receipt_id,
        }
    end

    return result_ok({
        already_applied = false,
        unchanged = false,
        flag_id = flag.id,
        old_value = old_value,
        new_value = value,
        flag_event = flag_event.value,
        world_revision = state.world_revision,
    })
end

function WorldState.is_discovered(state, location_id)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    return result_ok(state.discovered[location_id] ~= nil)
end

function WorldState.get_flag(state, catalog, flag_id)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    local flag = catalog:require_flag(flag_id)
    if not flag.ok then
        return flag
    end
    local value = state.flags[flag.value.id]
    if value == nil then
        value = flag.value.default_value
    end
    return result_ok({
        flag_id = flag.value.id,
        value = value,
        value_type = flag.value.value_type,
    })
end

function WorldState.get_position(state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    return result_ok(copy_position(state.position))
end

-- System 12 owns landing receipt generation and safe-ground position commit.
-- Canonical tuple identity matches system 26 TraversalRuntime.landing_tuple.
function WorldState.commit_traversal_landing(state, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local TraversalRuntime = require 'wzx.domain.traversal.runtime'
    local marker_id = raw_get(input, 'marker_id')
    local target_cell_id = raw_get(input, 'target_cell_id')
    local command_id = raw_get(input, 'active_segment_command_id')
        or raw_get(input, 'command_id')
    local mode = raw_get(input, 'mode') or 'JUMP'

    local marker_ok = RuntimeId.validate_content(marker_id, 'marker_', 'marker_id')
    if not marker_ok.ok then
        return fail(WorldErrorCodes.WORLD_MARKER_UNKNOWN, 'MARKER_ID_INVALID', {
            marker_id = marker_id,
        })
    end
    local cell_ok = RuntimeId.validate_content(
        target_cell_id,
        'traversal_cell_',
        'target_cell_id'
    )
    if not cell_ok.ok then
        return fail(WorldErrorCodes.WORLD_CELL_UNKNOWN, 'TARGET_CELL_INVALID', {
            target_cell_id = target_cell_id,
        })
    end

    local tuple_input = {
        player_save_scope = raw_get(input, 'player_save_scope') or 'player_default',
        traversal_session_id = raw_get(input, 'traversal_session_id'),
        active_segment_command_id = command_id,
        segment_sequence = raw_get(input, 'segment_sequence'),
        target_cell_id = target_cell_id,
        rules_version = raw_get(input, 'rules_version') or 1,
    }
    local derived = TraversalRuntime.landing_tuple(tuple_input)
    if not derived.ok then
        return fail(
            WorldErrorCodes.WORLD_ARGUMENT_INVALID,
            'LANDING_TUPLE_INVALID',
            {
                cause_code = derived.error and derived.error.code or 'UNKNOWN',
                cause_reason = derived.error
                    and derived.error.details
                    and derived.error.details.reason,
            }
        )
    end
    local landing_receipt_id = derived.value.landing_receipt_id
    local expected = raw_get(input, 'landing_receipt_id')
        or raw_get(input, 'expected_landing_receipt_id')
    if expected ~= nil and expected ~= landing_receipt_id then
        return fail(
            WorldErrorCodes.WORLD_LANDING_RECEIPT_CONFLICT,
            'LANDING_RECEIPT_MISMATCH',
            {
                expected = expected,
                actual = landing_receipt_id,
            }
        )
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior_command = state.command_receipts[command_id]
        if prior_command ~= nil and prior_command.kind == 'TRAVERSAL_LANDING' then
            if prior_command.receipt_id ~= landing_receipt_id then
                return fail(
                    WorldErrorCodes.WORLD_LANDING_RECEIPT_CONFLICT,
                    'COMMAND_LANDING_RECEIPT_MISMATCH',
                    {
                        command_id = command_id,
                        expected = prior_command.receipt_id,
                        actual = landing_receipt_id,
                    }
                )
            end
            return result_ok({
                already_committed = true,
                landing_receipt_id = landing_receipt_id,
                marker_id = prior_command.marker_id or marker_id,
                target_cell_id = prior_command.target_cell_id or target_cell_id,
                position = copy_position(state.position),
                world_revision = state.world_revision,
                mode = mode,
            })
        end
    end

    local prior_landing = state.landing_receipts[landing_receipt_id]
    if prior_landing ~= nil then
        return result_ok({
            already_committed = true,
            landing_receipt_id = landing_receipt_id,
            marker_id = prior_landing.marker_id,
            target_cell_id = prior_landing.target_cell_id,
            position = copy_position(state.position),
            world_revision = state.world_revision,
            mode = prior_landing.mode or mode,
        })
    end

    local location_id = raw_get(input, 'location_id') or state.position.location_id
    local area_id = raw_get(input, 'area_id') or state.position.area_id
    local facing = raw_get(input, 'facing_octant')
    if facing == nil then
        facing = state.position.facing_octant or 0
    elseif type_value(facing) ~= 'number'
        or facing ~= math.floor(facing)
        or facing < 0
        or facing > 7
    then
        return invalid('FACING_INVALID')
    end

    state.position = {
        area_id = area_id,
        location_id = location_id,
        current_marker_id = marker_id,
        last_safe_marker_id = marker_id,
        last_landing_receipt_id = landing_receipt_id,
        current_cell_id = target_cell_id,
        facing_octant = facing,
    }
    state.world_revision = state.world_revision + 1
    state.landing_receipts[landing_receipt_id] = {
        landing_receipt_id = landing_receipt_id,
        marker_id = marker_id,
        target_cell_id = target_cell_id,
        traversal_session_id = tuple_input.traversal_session_id,
        active_segment_command_id = command_id,
        segment_sequence = tuple_input.segment_sequence,
        mode = mode,
        world_revision = state.world_revision,
    }
    if type_value(command_id) == 'string' and command_id ~= '' then
        state.command_receipts[command_id] = {
            command_id = command_id,
            kind = 'TRAVERSAL_LANDING',
            receipt_id = landing_receipt_id,
            marker_id = marker_id,
            target_cell_id = target_cell_id,
        }
    end

    return result_ok({
        already_committed = false,
        landing_receipt_id = landing_receipt_id,
        marker_id = marker_id,
        target_cell_id = target_cell_id,
        position = copy_position(state.position),
        world_revision = state.world_revision,
        mode = mode,
        digest = derived.value.digest,
    })
end

function WorldState.get_traversal_context(state, options)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    options = options or {}
    local position = state.position or {}
    local origin_cell_id = position.current_cell_id or raw_get(options, 'default_origin_cell_id')
    if type_value(origin_cell_id) ~= 'string' then
        return fail(
            WorldErrorCodes.WORLD_CELL_UNKNOWN,
            'ORIGIN_CELL_UNKNOWN'
        )
    end
    return result_ok({
        actor_id = raw_get(options, 'actor_id') or 'char_hero',
        origin_cell_id = origin_cell_id,
        last_safe_marker_id = position.last_safe_marker_id,
        current_marker_id = position.current_marker_id,
        last_landing_receipt_id = position.last_landing_receipt_id,
        location_id = position.location_id,
        area_id = position.area_id,
        spatial_revision = raw_get(options, 'spatial_revision') or 0,
        world_revision = state.world_revision or 0,
        player_save_scope = raw_get(options, 'player_save_scope') or 'player_default',
        input_locked = raw_get(options, 'input_locked') == true,
        lock_reason = raw_get(options, 'lock_reason'),
    })
end

-- Load-time NORMALIZE_TRANSIENT_WORLD position rule (system 12).
-- Never trusts mid-air/water residual coords. Landing is kept only when
-- evidence says MATCHED; otherwise snap to last_safe_marker_id and drop
-- untrusted landing receipt / current_cell_id. In-memory only until next save.
function WorldState.normalize_transient_position(position, evidence)
    if type_value(position) ~= 'table' or get_metatable(position) ~= nil then
        return invalid('POSITION_REQUIRED')
    end
    if type_value(evidence) ~= 'table' then
        return invalid('EVIDENCE_REQUIRED')
    end

    local next_position = copy_position(position)
    local status = evidence.status
    local matched = evidence.matched == true

    if matched or status == 'MATCHED' then
        return result_ok({
            position = next_position,
            action = 'KEEP_LANDING',
            changed = false,
            evidence_status = status or 'MATCHED',
            last_landing_receipt_id = next_position.last_landing_receipt_id,
            last_safe_marker_id = next_position.last_safe_marker_id,
        })
    end

    if status == 'NO_LANDING' then
        local safe = next_position.last_safe_marker_id
        local changed = false
        if type_value(safe) == 'string'
            and safe ~= ''
            and next_position.current_marker_id ~= safe
        then
            next_position.current_marker_id = safe
            -- Drop residual cell when forced back to safe; exploration origin
            -- cells at the safe marker may remain when already aligned.
            next_position.current_cell_id = nil
            changed = true
        end
        return result_ok({
            position = next_position,
            action = changed and 'SNAP_TO_LAST_SAFE' or 'KEEP_SAFE',
            changed = changed,
            evidence_status = 'NO_LANDING',
            last_landing_receipt_id = nil,
            last_safe_marker_id = next_position.last_safe_marker_id,
        })
    end

    -- Evidence insufficient for last_landing_receipt_id: fall back to safe.
    local prior_receipt = next_position.last_landing_receipt_id
    local safe = next_position.last_safe_marker_id
    local changed = false
    if type_value(safe) == 'string' and safe ~= '' then
        if next_position.current_marker_id ~= safe then
            next_position.current_marker_id = safe
            changed = true
        end
    end
    if next_position.last_landing_receipt_id ~= nil then
        next_position.last_landing_receipt_id = nil
        changed = true
    end
    if next_position.current_cell_id ~= nil then
        next_position.current_cell_id = nil
        changed = true
    end

    return result_ok({
        position = next_position,
        action = 'SNAP_TO_LAST_SAFE',
        changed = changed,
        evidence_status = status or 'EVIDENCE_INSUFFICIENT',
        cleared_landing_receipt_id = prior_receipt,
        last_landing_receipt_id = nil,
        last_safe_marker_id = next_position.last_safe_marker_id,
    })
end

function WorldState.list_discovered(state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    local ids = sorted_ids(state.discovered)
    local rows = {}
    local index
    for index = 1, #ids do
        local row = state.discovered[ids[index]]
        rows[index] = {
            location_id = row.location_id,
            area_id = row.area_id,
            discovery_receipt_id = row.discovery_receipt_id,
        }
    end
    return result_ok(rows)
end

function WorldState.get_interactable_state(state, catalog, interactable_id)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    local interactable = catalog:require_interactable(interactable_id)
    if not interactable.ok then
        return interactable
    end
    interactable = interactable.value
    local row = ensure_interactable_row(state, interactable)
    return result_ok({
        interactable_id = row.interactable_id,
        state = row.state,
        receipt_id = row.receipt_id,
        reward_receipt_id = row.reward_receipt_id,
        interactable_type = interactable.interactable_type,
        location_id = interactable.location_id,
    })
end

function WorldState.open_chest(state, catalog, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local interactable_id = raw_get(input, 'interactable_id')
    local open_receipt_id = raw_get(input, 'open_receipt_id')
    local command_id = raw_get(input, 'command_id')

    local receipt_check = validate_derived(open_receipt_id, 'open_receipt_id')
    if not receipt_check.ok then
        return invalid('OPEN_RECEIPT_INVALID')
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = state.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'OPEN_CHEST' then
            return result_ok({
                already_opened = true,
                command_replay = true,
                interactable_id = prior.interactable_id,
                chest_event = nil,
            })
        end
    end

    local interactable = catalog:require_interactable(interactable_id)
    if not interactable.ok then
        return interactable
    end
    interactable = interactable.value
    if interactable.interactable_type ~= 'CHEST' then
        return fail(
            WorldErrorCodes.WORLD_INTERACTABLE_TYPE_MISMATCH,
            'CHEST_REQUIRED',
            {
                interactable_id = interactable.id,
                interactable_type = interactable.interactable_type,
            }
        )
    end

    local row = ensure_interactable_row(state, interactable)
    if row.state == 'OPENED' or row.state == 'REWARD_PENDING' then
        if row.receipt_id == open_receipt_id then
            return result_ok({
                already_opened = true,
                interactable_id = interactable.id,
                state = row.state,
                reward_id = interactable.action_ref_id,
                reward_receipt_id = row.reward_receipt_id,
                chest_event = nil,
            })
        end
        return fail(
            WorldErrorCodes.WORLD_INTERACTABLE_UNAVAILABLE,
            'CHEST_ALREADY_OPENED',
            {
                interactable_id = interactable.id,
                state = row.state,
            }
        )
    end
    if row.state ~= 'AVAILABLE' then
        return fail(
            WorldErrorCodes.WORLD_INTERACTABLE_UNAVAILABLE,
            'CHEST_NOT_AVAILABLE',
            {
                interactable_id = interactable.id,
                state = row.state,
            }
        )
    end

    local terminal_state = raw_get(input, 'terminal_state')
    if terminal_state == nil then
        terminal_state = 'OPENED'
    end
    if terminal_state ~= 'OPENED' and terminal_state ~= 'REWARD_PENDING' then
        return invalid('TERMINAL_STATE_INVALID', { terminal_state = terminal_state })
    end
    local reward_receipt_id = raw_get(input, 'reward_receipt_id') or open_receipt_id

    local chest_event = WorldEvents.build_chest_opened(
        state,
        interactable,
        open_receipt_id,
        terminal_state
    )
    if not chest_event.ok then
        return chest_event
    end
    if state.event_receipts[chest_event.value.event_id] ~= nil then
        return fail(
            WorldErrorCodes.WORLD_RECEIPT_CONFLICT,
            'CHEST_EVENT_ALREADY_USED',
            { event_id = chest_event.value.event_id }
        )
    end

    row.state = terminal_state
    row.receipt_id = open_receipt_id
    row.reward_receipt_id = reward_receipt_id
    state.world_revision = state.world_revision + 1
    state.event_receipts[chest_event.value.event_id] = {
        event_id = chest_event.value.event_id,
        event_type = chest_event.value.event_type,
        receipt_id = open_receipt_id,
    }
    if type_value(command_id) == 'string' and command_id ~= '' then
        state.command_receipts[command_id] = {
            command_id = command_id,
            kind = 'OPEN_CHEST',
            interactable_id = interactable.id,
            receipt_id = open_receipt_id,
        }
    end

    return result_ok({
        already_opened = false,
        interactable_id = interactable.id,
        state = terminal_state,
        reward_id = interactable.action_ref_id,
        reward_receipt_id = reward_receipt_id,
        chest_event = chest_event.value,
        world_revision = state.world_revision,
    })
end

function WorldState.resolve_search(state, catalog, input)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_REQUIRED')
    end
    if type_value(catalog) ~= 'table' then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local interactable_id = raw_get(input, 'interactable_id')
    local search_receipt_id = raw_get(input, 'search_receipt_id')
    local command_id = raw_get(input, 'command_id')

    local receipt_check = validate_derived(search_receipt_id, 'search_receipt_id')
    if not receipt_check.ok then
        return invalid('SEARCH_RECEIPT_INVALID')
    end

    if type_value(command_id) == 'string' and command_id ~= '' then
        local prior = state.command_receipts[command_id]
        if prior ~= nil and prior.kind == 'RESOLVE_SEARCH' then
            return result_ok({
                already_resolved = true,
                command_replay = true,
                interactable_id = prior.interactable_id,
                search_event = nil,
                flag_event = nil,
            })
        end
    end

    local interactable = catalog:require_interactable(interactable_id)
    if not interactable.ok then
        return interactable
    end
    interactable = interactable.value
    if interactable.interactable_type ~= 'SEARCH' then
        return fail(
            WorldErrorCodes.WORLD_INTERACTABLE_TYPE_MISMATCH,
            'SEARCH_REQUIRED',
            {
                interactable_id = interactable.id,
                interactable_type = interactable.interactable_type,
            }
        )
    end

    local row = ensure_interactable_row(state, interactable)
    if row.state == 'COMPLETED' or row.state == 'REWARD_PENDING' then
        if row.receipt_id == search_receipt_id then
            return result_ok({
                already_resolved = true,
                interactable_id = interactable.id,
                state = row.state,
                search_event = nil,
                flag_event = nil,
            })
        end
        return fail(
            WorldErrorCodes.WORLD_INTERACTABLE_UNAVAILABLE,
            'SEARCH_ALREADY_RESOLVED',
            {
                interactable_id = interactable.id,
                state = row.state,
            }
        )
    end
    if row.state ~= 'AVAILABLE' then
        return fail(
            WorldErrorCodes.WORLD_INTERACTABLE_UNAVAILABLE,
            'SEARCH_NOT_AVAILABLE',
            {
                interactable_id = interactable.id,
                state = row.state,
            }
        )
    end

    local search_event = WorldEvents.build_search_resolved(
        state,
        interactable,
        search_receipt_id
    )
    if not search_event.ok then
        return search_event
    end
    if state.event_receipts[search_event.value.event_id] ~= nil then
        return fail(
            WorldErrorCodes.WORLD_RECEIPT_CONFLICT,
            'SEARCH_EVENT_ALREADY_USED',
            { event_id = search_event.value.event_id }
        )
    end

    local flag_event = nil
    if interactable.result_type == 'FLAG' and interactable.flag_id ~= nil then
        local flag_receipt_id = raw_get(input, 'flag_receipt_id') or search_receipt_id
        local set = WorldState.set_flag(state, catalog, {
            flag_id = interactable.flag_id,
            value = interactable.flag_value,
            flag_receipt_id = flag_receipt_id,
            reason = 'SEARCH_RESULT',
        })
        if not set.ok then
            return set
        end
        flag_event = set.value.flag_event
    end

    row.state = 'COMPLETED'
    row.receipt_id = search_receipt_id
    -- set_flag may have already bumped revision; search completion still counts once more.
    state.world_revision = state.world_revision + 1
    state.event_receipts[search_event.value.event_id] = {
        event_id = search_event.value.event_id,
        event_type = search_event.value.event_type,
        receipt_id = search_receipt_id,
    }
    if type_value(command_id) == 'string' and command_id ~= '' then
        state.command_receipts[command_id] = {
            command_id = command_id,
            kind = 'RESOLVE_SEARCH',
            interactable_id = interactable.id,
            receipt_id = search_receipt_id,
        }
    end

    return result_ok({
        already_resolved = false,
        interactable_id = interactable.id,
        state = 'COMPLETED',
        result_type = interactable.result_type,
        result_ref = interactable.result_ref_id,
        search_event = search_event.value,
        flag_event = flag_event,
        world_revision = state.world_revision,
    })
end

return WorldState
