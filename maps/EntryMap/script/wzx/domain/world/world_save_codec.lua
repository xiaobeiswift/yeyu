local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local WorldErrorCodes = require 'wzx.domain.world.error_codes'
local WorldState = require 'wzx.domain.world.world_state'

local WorldSaveCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local CURRENT_SCHEMA_VERSION = 1
local MAX_DISCOVERED = 512
local MAX_FLAGS = 512
local MAX_INTERACTABLES = 1024
local MAX_EVENT_RECEIPTS = 2048
local MAX_SAFE_INTEGER = 9007199254740991

local BUNDLE_FIELDS = {
    world_metadata = true,
    world_position = true,
    world_discovered_locations = true,
    world_flags = true,
    world_event_receipts = true,
    world_interactable_states = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    world_revision = true,
}
local POSITION_FIELDS = {
    area_id = true,
    location_id = true,
    current_marker_id = true,
    last_safe_marker_id = true,
    facing_octant = true,
}
local DISCOVERED_FIELDS = {
    location_id = true,
    area_id = true,
    discovery_receipt_id = true,
}
local FLAG_FIELDS = {
    flag_id = true,
    flag_value = true,
}
local EVENT_FIELDS = {
    event_id = true,
    event_type = true,
    receipt_id = true,
}
local INTERACTABLE_FIELDS = {
    interactable_id = true,
    state = true,
    receipt_id = true,
}

local function failure(code, message_key, reason, details)
    local copied = {}
    local key
    local value
    if type_value(details) == 'table' then
        for key, value in raw_next, details do
            copied[key] = value
        end
    end
    copied.reason = reason
    return result_err(code, message_key, false, copied)
end

local function invalid(reason, details)
    return failure(
        WorldErrorCodes.WORLD_SAVE_INVALID,
        'error.world.save_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        WorldErrorCodes.WORLD_SAVE_LIMIT_EXCEEDED,
        'error.world.save_limit_exceeded',
        reason,
        details
    )
end

local function no_unknown_fields(value, allowed, path)
    if type_value(value) ~= 'table' then
        return invalid('TABLE_REQUIRED', { field = path })
    end
    local key
    for key in raw_next, value do
        if type_value(key) ~= 'string' or allowed[key] ~= true then
            return invalid('UNKNOWN_FIELD', { field = path .. '.' .. tostring(key) })
        end
    end
    return nil
end

local function sorted_keys(map)
    local keys = {}
    local key
    for key in raw_next, map do
        keys[#keys + 1] = key
    end
    table_sort(keys, bytewise_string_less)
    return keys
end

function WorldSaveCodec.encode(state)
    if type_value(state) ~= 'table' then
        return invalid('STATE_REQUIRED')
    end
    if not is_integer(state.world_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('WORLD_REVISION_INVALID')
    end

    local position = state.position or {}
    local position_row = {
        area_id = position.area_id,
        location_id = position.location_id,
        current_marker_id = position.current_marker_id,
        last_safe_marker_id = position.last_safe_marker_id,
        facing_octant = position.facing_octant or 0,
    }

    local discovered_keys = sorted_keys(state.discovered or {})
    if #discovered_keys > MAX_DISCOVERED then
        return limit_exceeded('DISCOVERED_LIMIT', { count = #discovered_keys })
    end
    local discovered_rows = {}
    local index
    for index = 1, #discovered_keys do
        local key = discovered_keys[index]
        local row = state.discovered[key]
        discovered_rows[index] = {
            location_id = row.location_id or key,
            area_id = row.area_id,
            discovery_receipt_id = row.discovery_receipt_id,
        }
    end

    local flag_keys = sorted_keys(state.flags or {})
    if #flag_keys > MAX_FLAGS then
        return limit_exceeded('FLAG_LIMIT', { count = #flag_keys })
    end
    local flag_rows = {}
    for index = 1, #flag_keys do
        local key = flag_keys[index]
        flag_rows[index] = {
            flag_id = key,
            flag_value = state.flags[key],
        }
    end

    local event_keys = sorted_keys(state.event_receipts or {})
    if #event_keys > MAX_EVENT_RECEIPTS then
        return limit_exceeded('EVENT_RECEIPT_LIMIT', { count = #event_keys })
    end
    local event_rows = {}
    for index = 1, #event_keys do
        local key = event_keys[index]
        local row = state.event_receipts[key]
        event_rows[index] = {
            event_id = row.event_id or key,
            event_type = row.event_type,
            receipt_id = row.receipt_id,
        }
    end

    local interactable_keys = sorted_keys(state.interactables or {})
    if #interactable_keys > MAX_INTERACTABLES then
        return limit_exceeded('INTERACTABLE_LIMIT', { count = #interactable_keys })
    end
    local interactable_rows = {}
    for index = 1, #interactable_keys do
        local key = interactable_keys[index]
        local row = state.interactables[key]
        interactable_rows[index] = {
            interactable_id = row.interactable_id or key,
            state = row.state,
            receipt_id = row.receipt_id,
        }
    end

    return result_ok({
        world_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            world_revision = state.world_revision,
        },
        world_position = position_row,
        world_discovered_locations = discovered_rows,
        world_flags = flag_rows,
        world_event_receipts = event_rows,
        world_interactable_states = interactable_rows,
    })
end

function WorldSaveCodec.decode(bundle)
    if type_value(bundle) ~= 'table' then
        return invalid('BUNDLE_REQUIRED')
    end
    local unknown = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if unknown ~= nil then
        return unknown
    end

    local metadata = bundle.world_metadata
    if type_value(metadata) ~= 'table' then
        return invalid('METADATA_REQUIRED')
    end
    unknown = no_unknown_fields(metadata, METADATA_FIELDS, 'world_metadata')
    if unknown ~= nil then
        return unknown
    end
    if metadata.schema_version ~= CURRENT_SCHEMA_VERSION then
        return failure(
            WorldErrorCodes.WORLD_SAVE_VERSION_UNSUPPORTED,
            'error.world.save_version_unsupported',
            'SCHEMA_VERSION_UNSUPPORTED',
            { schema_version = metadata.schema_version }
        )
    end
    if not is_integer(metadata.world_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('WORLD_REVISION_INVALID')
    end

    local state = WorldState.empty()
    state.world_revision = metadata.world_revision

    local position = bundle.world_position or {}
    unknown = no_unknown_fields(position, POSITION_FIELDS, 'world_position')
    if unknown ~= nil then
        return unknown
    end
    if position.area_id ~= nil then
        local checked = validate_content(position.area_id, 'area_', 'area_id')
        if not checked.ok then
            return invalid('AREA_ID_INVALID')
        end
    end
    if position.location_id ~= nil then
        local checked = validate_content(position.location_id, 'location_', 'location_id')
        if not checked.ok then
            return invalid('LOCATION_ID_INVALID')
        end
    end
    if position.current_marker_id ~= nil then
        local checked = validate_content(position.current_marker_id, 'marker_', 'current_marker_id')
        if not checked.ok then
            return invalid('MARKER_ID_INVALID')
        end
    end
    if position.last_safe_marker_id ~= nil then
        local checked = validate_content(
            position.last_safe_marker_id,
            'marker_',
            'last_safe_marker_id'
        )
        if not checked.ok then
            return invalid('MARKER_ID_INVALID')
        end
    end
    local facing = position.facing_octant or 0
    if not is_integer(facing, 0, 7) then
        return invalid('FACING_INVALID')
    end
    state.position = {
        area_id = position.area_id,
        location_id = position.location_id,
        current_marker_id = position.current_marker_id,
        last_safe_marker_id = position.last_safe_marker_id,
        facing_octant = facing,
    }

    local discovered = bundle.world_discovered_locations or {}
    local index
    for index = 1, #discovered do
        local row = discovered[index]
        unknown = no_unknown_fields(
            row,
            DISCOVERED_FIELDS,
            'world_discovered_locations[' .. index .. ']'
        )
        if unknown ~= nil then
            return unknown
        end
        local loc_check = validate_content(row.location_id, 'location_', 'location_id')
        if not loc_check.ok then
            return invalid('LOCATION_ID_INVALID')
        end
        local area_check = validate_content(row.area_id, 'area_', 'area_id')
        if not area_check.ok then
            return invalid('AREA_ID_INVALID')
        end
        local receipt_check = validate_derived(
            row.discovery_receipt_id,
            'discovery_receipt_id'
        )
        if not receipt_check.ok then
            return invalid('DISCOVERY_RECEIPT_INVALID')
        end
        state.discovered[row.location_id] = {
            location_id = row.location_id,
            area_id = row.area_id,
            discovery_receipt_id = row.discovery_receipt_id,
        }
    end

    local flags = bundle.world_flags or {}
    for index = 1, #flags do
        local row = flags[index]
        unknown = no_unknown_fields(row, FLAG_FIELDS, 'world_flags[' .. index .. ']')
        if unknown ~= nil then
            return unknown
        end
        local flag_check = validate_content(row.flag_id, 'flag_', 'flag_id')
        if not flag_check.ok then
            return invalid('FLAG_ID_INVALID')
        end
        state.flags[row.flag_id] = row.flag_value
    end

    local events = bundle.world_event_receipts or {}
    for index = 1, #events do
        local row = events[index]
        unknown = no_unknown_fields(
            row,
            EVENT_FIELDS,
            'world_event_receipts[' .. index .. ']'
        )
        if unknown ~= nil then
            return unknown
        end
        local event_check = validate_derived(row.event_id, 'event_id')
        if not event_check.ok then
            return invalid('EVENT_ID_INVALID')
        end
        state.event_receipts[row.event_id] = {
            event_id = row.event_id,
            event_type = row.event_type,
            receipt_id = row.receipt_id,
        }
    end

    local interactables = bundle.world_interactable_states or {}
    for index = 1, #interactables do
        local row = interactables[index]
        unknown = no_unknown_fields(
            row,
            INTERACTABLE_FIELDS,
            'world_interactable_states[' .. index .. ']'
        )
        if unknown ~= nil then
            return unknown
        end
        local id_check = validate_content(row.interactable_id, 'interact_', 'interactable_id')
        if not id_check.ok then
            return invalid('INTERACTABLE_ID_INVALID')
        end
        if type_value(row.state) ~= 'string' or row.state == '' then
            return invalid('INTERACTABLE_STATE_INVALID')
        end
        if row.receipt_id ~= nil then
            local receipt_check = validate_derived(row.receipt_id, 'receipt_id')
            if not receipt_check.ok then
                return invalid('INTERACTABLE_RECEIPT_INVALID')
            end
        end
        state.interactables[row.interactable_id] = {
            interactable_id = row.interactable_id,
            state = row.state,
            receipt_id = row.receipt_id,
        }
    end

    return result_ok(state)
end

return WorldSaveCodec
