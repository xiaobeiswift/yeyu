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
            facing_octant = 0,
        },
        discovered = {},
        flags = {},
        event_receipts = {},
        command_receipts = {},
    }
end

local function copy_position(position)
    return {
        area_id = position.area_id,
        location_id = position.location_id,
        current_marker_id = position.current_marker_id,
        last_safe_marker_id = position.last_safe_marker_id,
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

return WorldState
