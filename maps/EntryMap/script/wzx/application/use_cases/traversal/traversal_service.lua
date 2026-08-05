-- Application facade for system 26 offline lightness traversal.

local Result = require 'wzx.domain.common.result'
local TraversalRuntime = require 'wzx.domain.traversal.runtime'
local TraversalErrorCodes = require 'wzx.domain.traversal.error_codes'
local LightnessTraversalProfile = require 'wzx.domain.contracts.lightness_traversal_profile'

local TraversalService = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('traversal service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

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

local function is_catalog(value)
    return type_value(value) == 'table'
        and type_value(value.require_cell) == 'function'
        and type_value(value.outgoing_links) == 'function'
        and type_value(value.spatial_revision) == 'function'
end

local function is_world_service(value)
    return type_value(value) == 'table'
        and type_value(value.commit_traversal_landing) == 'function'
        and type_value(value.get_traversal_context) == 'function'
end

function TraversalService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'catalog')
    local profile_provider = raw_get(options, 'profile_provider')
    local world_context_provider = raw_get(options, 'world_context_provider')
    local position_commit = raw_get(options, 'position_commit')
    local world_service = raw_get(options, 'world_service')
    local world_context_options = raw_get(options, 'world_context_options')

    if not is_catalog(catalog) then
        return invalid('TRAVERSAL_CATALOG_REQUIRED', { field = 'catalog' })
    end
    if type_value(profile_provider) ~= 'function' then
        return invalid('PROFILE_PROVIDER_REQUIRED', { field = 'profile_provider' })
    end
    if world_service ~= nil then
        if not is_world_service(world_service) then
            return invalid('WORLD_SERVICE_INVALID', { field = 'world_service' })
        end
        if world_context_provider == nil then
            world_context_provider = function()
                local opts = {}
                if type_value(world_context_options) == 'table' then
                    local key
                    local value
                    for key, value in pairs(world_context_options) do
                        opts[key] = value
                    end
                end
                if opts.spatial_revision == nil then
                    opts.spatial_revision = catalog:spatial_revision()
                end
                return world_service:get_traversal_context(opts)
            end
        end
        if position_commit == nil then
            position_commit = function(payload)
                return world_service:commit_traversal_landing({
                    player_save_scope = payload.tuple and payload.tuple.player_save_scope
                        or payload.player_save_scope,
                    traversal_session_id = payload.tuple
                        and payload.tuple.traversal_session_id
                        or payload.traversal_session_id,
                    active_segment_command_id = payload.tuple
                        and payload.tuple.active_segment_command_id
                        or payload.active_segment_command_id,
                    segment_sequence = payload.tuple
                        and payload.tuple.segment_sequence
                        or payload.segment_sequence,
                    target_cell_id = payload.target_cell_id
                        or (payload.tuple and payload.tuple.target_cell_id),
                    rules_version = payload.tuple and payload.tuple.rules_version
                        or payload.rules_version,
                    marker_id = payload.marker_id,
                    landing_receipt_id = payload.landing_receipt_id,
                    mode = payload.mode,
                    location_id = payload.location_id,
                    area_id = payload.area_id,
                })
            end
        end
    end
    if type_value(world_context_provider) ~= 'function' then
        return invalid(
            'WORLD_CONTEXT_PROVIDER_REQUIRED',
            { field = 'world_context_provider' }
        )
    end
    if position_commit ~= nil and type_value(position_commit) ~= 'function' then
        return invalid('POSITION_COMMIT_INVALID', { field = 'position_commit' })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        profile_provider = profile_provider,
        world_context_provider = world_context_provider,
        position_commit = position_commit,
        world_service = world_service,
        runtime = TraversalRuntime.empty(),
    }
    return result_ok(view)
end

function TraversalService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

local function load_profile(state)
    local profile = state.profile_provider()
    if type_value(profile) == 'table' and profile.ok ~= nil then
        if not profile.ok then
            return profile
        end
        profile = profile.value
    end
    local validated = LightnessTraversalProfile.validate(profile)
    if not validated.ok then
        return fail(
            TraversalErrorCodes.TRAVERSAL_BUILD_INVALID,
            'PROFILE_INVALID',
            {
                cause_code = validated.error and validated.error.code or 'UNKNOWN',
            }
        )
    end
    return result_ok(validated.value)
end

local function load_world_context(state)
    local context = state.world_context_provider()
    if type_value(context) == 'table' and context.ok ~= nil then
        if not context.ok then
            return context
        end
        context = context.value
    end
    if type_value(context) ~= 'table' then
        return invalid('WORLD_CONTEXT_INVALID')
    end
    return result_ok(context)
end

function Service:open_targeting(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local profile = load_profile(state)
    if not profile.ok then
        return profile
    end
    local world = load_world_context(state)
    if not world.ok then
        return world
    end
    return TraversalRuntime.open_targeting(
        state.runtime,
        state.catalog,
        profile.value,
        world.value,
        input
    )
end

function Service:cancel_targeting(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return TraversalRuntime.cancel_targeting(state.runtime, input)
end

function Service:request_traversal(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local profile = load_profile(state)
    if not profile.ok then
        return profile
    end
    local world = load_world_context(state)
    if not world.ok then
        return world
    end
    return TraversalRuntime.request_traversal(
        state.runtime,
        state.catalog,
        profile.value,
        world.value,
        input
    )
end

function Service:complete_segment(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local world = load_world_context(state)
    if not world.ok then
        return world
    end
    return TraversalRuntime.complete_segment(
        state.runtime,
        state.catalog,
        world.value,
        input,
        state.position_commit
    )
end

function Service:recover(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local world = load_world_context(state)
    if not world.ok then
        return world
    end
    return TraversalRuntime.recover(state.runtime, world.value, input)
end

function Service:snapshot()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return result_ok(TraversalRuntime.snapshot(state.runtime))
end

return TraversalService
