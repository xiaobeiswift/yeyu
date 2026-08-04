local MartialCatalog = require 'wzx.config.schema.martial.catalog'
local MartialAggregate = require 'wzx.domain.martial.martial_aggregate'
local LightnessProfileDeriver = require 'wzx.domain.martial.lightness_profile_deriver'
local MartialSaveCodec = require 'wzx.domain.martial.martial_save_codec'
local MartialErrorCodes = require 'wzx.domain.martial.error_codes'
local Result = require 'wzx.domain.common.result'

local MartialService = {}
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
    error_value('martial service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.martial.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(MartialErrorCodes.MARTIAL_ARGUMENT_INVALID, reason, details, false)
end

local function catalog_lookup(catalog, martial_id)
    local found = catalog:require_martial(martial_id)
    if not found.ok then
        return nil
    end
    return found.value
end

local function compatibility_lookup(catalog, rule_id)
    local found = catalog:require_compatibility_rule(rule_id)
    if not found.ok then
        return nil
    end
    return found.value
end

local function profile_lookup(catalog, profile_id)
    local found = catalog:require_lightness_profile(profile_id)
    if not found.ok then
        return nil
    end
    return found.value
end

local function remember_receipt(state, receipt_id, operation, payload_digest)
    local existing = state.receipts[receipt_id]
    if existing ~= nil then
        if existing.operation ~= operation or existing.payload_digest ~= payload_digest then
            return fail(
                MartialErrorCodes.MARTIAL_RECEIPT_REUSED,
                'RECEIPT_PAYLOAD_CONFLICT',
                {
                    receipt_id = receipt_id,
                    operation = operation,
                },
                false
            )
        end
        return result_ok({ replay = true, result = existing.result })
    end
    return result_ok({ replay = false })
end

local function store_receipt(state, receipt_id, operation, payload_digest, result_value)
    state.receipts[receipt_id] = {
        operation = operation,
        payload_digest = payload_digest,
        result = result_value,
    }
end

local function payload_key(parts)
    local chunks = {}
    local index
    for index = 1, #parts do
        local value = parts[index]
        if value == nil then
            chunks[index] = ''
        else
            chunks[index] = tostring(value)
        end
    end
    return table.concat(chunks, '|')
end

local function acquire_guard(state, needs_guard, command_id)
    if not needs_guard then
        return result_ok(nil)
    end
    if state.traversal_active == true then
        return fail(
            MartialErrorCodes.MARTIAL_TRAVERSAL_ACTIVE,
            'TRAVERSAL_ACTIVE',
            { command_id = command_id },
            false
        )
    end
    if type_value(state.traversal_guard_acquire) == 'function' then
        return state.traversal_guard_acquire(command_id)
    end
    return result_ok({ guard_token = 'guard_offline_' .. tostring(command_id) })
end

function MartialService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local catalog = raw_get(options, 'martial_catalog')
    if not MartialCatalog.is_authority(catalog) then
        return invalid('MARTIAL_CATALOG_AUTHORITY_REQUIRED', {
            field = 'martial_catalog',
        })
    end
    local empty = MartialAggregate.empty()
    if not empty.ok then
        return empty
    end
    local world_protagonist_id = raw_get(options, 'world_protagonist_id') or 'char_hero'
    local view = set_metatable({}, Service)
    STATES[view] = {
        catalog = catalog,
        book = empty.value,
        world_protagonist_id = world_protagonist_id,
        traversal_active = raw_get(options, 'traversal_active') == true,
        traversal_guard_acquire = raw_get(options, 'traversal_guard_acquire'),
        receipts = {},
    }
    return result_ok(view)
end

function MartialService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
end

function Service:set_traversal_active(active)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    state.traversal_active = active == true
    return result_ok(true)
end

function Service:get_book()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    return MartialAggregate.snapshot(state.book)
end

function Service:encode_save_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local snap = MartialAggregate.snapshot(state.book)
    if not snap.ok then
        return snap
    end
    return MartialSaveCodec.encode(snap.value)
end

function Service:load_save_bundle(bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local loaded = MartialSaveCodec.to_aggregate_state(bundle)
    if not loaded.ok then
        return loaded
    end
    state.book = loaded.value
    return result_ok({
        status = 'LOADED',
        book_revision = loaded.value.book_revision,
    })
end

function Service:grant_ownership(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local receipt_id = raw_get(input, 'receipt_id')
    local digest = payload_key({
        'grant',
        raw_get(input, 'martial_id'),
        raw_get(input, 'amount'),
        raw_get(input, 'source_type'),
        raw_get(input, 'source_reference'),
    })
    local remembered = remember_receipt(state, receipt_id, 'grant', digest)
    if not remembered.ok then
        return remembered
    end
    if remembered.value.replay then
        return result_ok(remembered.value.result)
    end

    local definition = state.catalog:require_martial(raw_get(input, 'martial_id'))
    if not definition.ok then
        return definition
    end
    local granted = MartialAggregate.grant_ownership(
        state.book,
        input,
        definition.value
    )
    if not granted.ok then
        return granted
    end
    state.book = granted.value
    local ownership = MartialAggregate.get_ownership(state.book, input.martial_id)
    local result = {
        status = 'COMMITTED',
        ownership = ownership.value,
        book_revision = state.book.book_revision,
        receipt_id = receipt_id,
    }
    store_receipt(state, receipt_id, 'grant', digest, result)
    return result_ok(result)
end

function Service:learn(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local receipt_id = raw_get(input, 'acquisition_receipt_id')
    local digest = payload_key({
        'learn',
        raw_get(input, 'character_id'),
        raw_get(input, 'martial_id'),
        raw_get(input, 'source_type'),
        raw_get(input, 'source_reference'),
    })
    local remembered = remember_receipt(state, receipt_id, 'learn', digest)
    if not remembered.ok then
        return remembered
    end
    if remembered.value.replay then
        return result_ok(remembered.value.result)
    end

    local definition = state.catalog:require_martial(raw_get(input, 'martial_id'))
    if not definition.ok then
        return definition
    end
    local rule = state.catalog:require_compatibility_rule(
        definition.value.compatibility_rule_id
    )
    if not rule.ok then
        return rule
    end
    local learned = MartialAggregate.learn(
        state.book,
        input,
        definition.value,
        rule.value
    )
    if not learned.ok then
        return learned
    end
    state.book = learned.value
    local progress = MartialAggregate.get_progress(
        state.book,
        input.character_id,
        input.martial_id
    )
    local ownership = MartialAggregate.get_ownership(state.book, input.martial_id)
    local result = {
        status = 'COMMITTED',
        progress = progress.value,
        ownership = ownership.value,
        unlocked_move_ids = definition.value.level_rows[1].unlocked_move_ids,
        book_revision = state.book.book_revision,
        receipt_id = receipt_id,
    }
    store_receipt(state, receipt_id, 'learn', digest, result)
    return result_ok(result)
end

function Service:upgrade(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local receipt_id = raw_get(input, 'receipt_id')
    local digest = payload_key({
        'upgrade',
        raw_get(input, 'character_id'),
        raw_get(input, 'martial_id'),
        raw_get(input, 'target_level'),
    })
    local remembered = remember_receipt(state, receipt_id, 'upgrade', digest)
    if not remembered.ok then
        return remembered
    end
    if remembered.value.replay then
        return result_ok(remembered.value.result)
    end

    local definition = state.catalog:require_martial(raw_get(input, 'martial_id'))
    if not definition.ok then
        return definition
    end

    local character_id = raw_get(input, 'character_id')
    local martial_id = raw_get(input, 'martial_id')
    local loadout = MartialAggregate.get_loadout(state.book, character_id)
    if not loadout.ok then
        return loadout
    end
    local needs_guard = character_id == state.world_protagonist_id
        and loadout.value.lightness_martial_id == martial_id
        and definition.value.category == 'LIGHTNESS'
    local guard = acquire_guard(state, needs_guard, receipt_id)
    if not guard.ok then
        return guard
    end

    local upgraded = MartialAggregate.upgrade(state.book, input, definition.value)
    if not upgraded.ok then
        return upgraded
    end
    state.book = upgraded.value
    local progress = MartialAggregate.get_progress(state.book, character_id, martial_id)
    local profile = nil
    if needs_guard then
        local derived = LightnessProfileDeriver.derive(
            state.book,
            state.world_protagonist_id,
            state.world_protagonist_id,
            function(id)
                return catalog_lookup(state.catalog, id)
            end,
            function(id)
                return profile_lookup(state.catalog, id)
            end
        )
        if derived.ok then
            profile = derived.value
        end
    end
    local result = {
        status = 'COMMITTED',
        progress = progress.value,
        unlocked_move_ids = definition.value.level_rows[progress.value.level].unlocked_move_ids,
        book_revision = state.book.book_revision,
        receipt_id = receipt_id,
        lightness_profile = profile,
        guard_token = guard.value and guard.value.guard_token or nil,
    }
    store_receipt(state, receipt_id, 'upgrade', digest, result)
    return result_ok(result)
end

function Service:commit_loadout(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local receipt_id = raw_get(input, 'receipt_id')
    local digest = payload_key({
        'loadout',
        raw_get(input, 'character_id'),
        raw_get(input, 'routine_martial_id'),
        raw_get(input, 'internal_martial_id'),
        raw_get(input, 'lightness_martial_id'),
        raw_get(input, 'ai_profile_id'),
    })
    local remembered = remember_receipt(state, receipt_id, 'loadout', digest)
    if not remembered.ok then
        return remembered
    end
    if remembered.value.replay then
        return result_ok(remembered.value.result)
    end

    local character_id = raw_get(input, 'character_id')
    local current = MartialAggregate.get_loadout(state.book, character_id)
    if not current.ok then
        return current
    end
    local next_lightness = raw_get(input, 'lightness_martial_id')
    local needs_guard = character_id == state.world_protagonist_id
        and current.value.lightness_martial_id ~= next_lightness
    local guard = acquire_guard(state, needs_guard, receipt_id)
    if not guard.ok then
        return guard
    end

    local committed = MartialAggregate.commit_loadout(
        state.book,
        input,
        function(id)
            return catalog_lookup(state.catalog, id)
        end,
        function(id)
            return compatibility_lookup(state.catalog, id)
        end
    )
    if not committed.ok then
        return committed
    end
    state.book = committed.value
    local loadout = MartialAggregate.get_loadout(state.book, character_id)
    local contributions = MartialAggregate.equipped_contributions(
        state.book,
        character_id,
        function(id)
            return catalog_lookup(state.catalog, id)
        end
    )
    local profile = nil
    if character_id == state.world_protagonist_id then
        local derived = LightnessProfileDeriver.derive(
            state.book,
            state.world_protagonist_id,
            state.world_protagonist_id,
            function(id)
                return catalog_lookup(state.catalog, id)
            end,
            function(id)
                return profile_lookup(state.catalog, id)
            end
        )
        if derived.ok then
            profile = derived.value
        end
    end
    local result = {
        status = 'COMMITTED',
        loadout = loadout.value,
        contributions = contributions.ok and contributions.value or {},
        book_revision = state.book.book_revision,
        receipt_id = receipt_id,
        lightness_profile = profile,
        guard_token = guard.value and guard.value.guard_token or nil,
    }
    store_receipt(state, receipt_id, 'loadout', digest, result)
    return result_ok(result)
end

function Service:get_lightness_traversal_profile(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    input = input or {}
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    return LightnessProfileDeriver.derive(
        state.book,
        state.world_protagonist_id,
        raw_get(input, 'character_id') or state.world_protagonist_id,
        function(id)
            return catalog_lookup(state.catalog, id)
        end,
        function(id)
            return profile_lookup(state.catalog, id)
        end,
        {
            expected_loadout_revision = raw_get(input, 'expected_loadout_revision'),
            expected_progress_revision = raw_get(input, 'expected_progress_revision'),
        }
    )
end

return MartialService
