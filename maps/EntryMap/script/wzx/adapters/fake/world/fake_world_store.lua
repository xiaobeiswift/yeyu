local WorldState = require 'wzx.domain.world.world_state'
local WorldSaveCodec = require 'wzx.domain.world.world_save_codec'
local Result = require 'wzx.domain.common.result'

local FakeWorldStore = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Store = {}
Store.__index = Store
Store.__newindex = function()
    error_value('fake world store is read-only', 2)
end
Store.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'INVALID_ARGUMENT',
        'error.world.fake_store_invalid',
        false,
        details
    )
end

local function copy_map(source)
    local out = {}
    local key
    local value
    for key, value in raw_next, source do
        if type_value(value) == 'table' then
            local nested = {}
            local nested_key
            local nested_value
            for nested_key, nested_value in raw_next, value do
                nested[nested_key] = nested_value
            end
            out[key] = nested
        else
            out[key] = value
        end
    end
    return out
end

local function copy_state(state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('STATE_TABLE_REQUIRED')
    end
    local position = state.position or {}
    return result_ok({
        world_revision = state.world_revision or 0,
        position = {
            area_id = position.area_id,
            location_id = position.location_id,
            current_marker_id = position.current_marker_id,
            last_safe_marker_id = position.last_safe_marker_id,
            facing_octant = position.facing_octant or 0,
        },
        discovered = copy_map(state.discovered or {}),
        flags = copy_map(state.flags or {}),
        event_receipts = copy_map(state.event_receipts or {}),
        command_receipts = copy_map(state.command_receipts or {}),
    })
end

function FakeWorldStore.new(options)
    options = options or {}
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED')
    end
    local seed = raw_get(options, 'state')
    local state
    if seed == nil then
        state = WorldState.empty()
    else
        local copied = copy_state(seed)
        if not copied.ok then
            return copied
        end
        state = copied.value
    end
    local view = set_metatable({}, Store)
    STATES[view] = {
        state = state,
    }
    return result_ok(view)
end

function Store:get_state()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return copy_state(state.state)
end

function Store:replace_state(world_state)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local copied = copy_state(world_state)
    if not copied.ok then
        return copied
    end
    state.state = copied.value
    return result_ok(true)
end

function Store:encode_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return WorldSaveCodec.encode(state.state)
end

return FakeWorldStore
