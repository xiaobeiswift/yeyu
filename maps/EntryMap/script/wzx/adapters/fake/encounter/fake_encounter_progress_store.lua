local EncounterProgress = require 'wzx.domain.encounter.encounter_progress'
local EncounterSaveCodec = require 'wzx.domain.encounter.encounter_save_codec'
local Result = require 'wzx.domain.common.result'

local FakeEncounterProgressStore = {}
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
    error_value('fake encounter progress store is read-only', 2)
end
Store.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'INVALID_ARGUMENT',
        'error.encounter.fake_store_invalid',
        false,
        details
    )
end

local function copy_snapshot(snapshot)
    local rows = {}
    local key
    local value
    for key, value in raw_next, (snapshot.rows or {}) do
        rows[key] = {
            encounter_id = value.encounter_id,
            discovered = value.discovered == true,
            first_clear = value.first_clear == true,
            completion_count = value.completion_count,
            last_completion_fact_revision = value.last_completion_fact_revision,
            rules_version = value.rules_version,
        }
    end
    local receipts = {}
    for key, value in raw_next, (snapshot.settlement_receipts or {}) do
        receipts[key] = {
            settlement_receipt_id = value.settlement_receipt_id,
            encounter_id = value.encounter_id,
            run_id = value.run_id,
            status = value.status,
        }
    end
    return {
        progress_revision = snapshot.progress_revision or 0,
        rows = rows,
        settlement_receipts = receipts,
    }
end

function FakeEncounterProgressStore.new(options)
    options = options or {}
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED')
    end
    local seed = raw_get(options, 'snapshot')
    local snapshot
    if seed == nil then
        snapshot = EncounterProgress.empty()
    else
        snapshot = copy_snapshot(seed)
    end
    local view = set_metatable({}, Store)
    STATES[view] = {
        snapshot = snapshot,
    }
    return result_ok(view)
end

function Store:get_snapshot()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return result_ok(copy_snapshot(state.snapshot))
end

function Store:replace_snapshot(snapshot)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(snapshot) ~= 'table' or get_metatable(snapshot) ~= nil then
        return invalid('SNAPSHOT_REQUIRED')
    end
    state.snapshot = copy_snapshot(snapshot)
    return result_ok(copy_snapshot(state.snapshot))
end

function Store:get_row(encounter_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return EncounterProgress.get_row(state.snapshot, encounter_id)
end

function Store:is_first_clear_already(encounter_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return EncounterProgress.is_first_clear_already(state.snapshot, encounter_id)
end

function Store:mark_discovered(encounter_id, rules_version)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local applied = EncounterProgress.mark_discovered(
        state.snapshot,
        encounter_id,
        rules_version
    )
    if not applied.ok then
        return applied
    end
    state.snapshot = applied.value.snapshot
    return result_ok({
        changed = applied.value.changed,
        row = applied.value.row,
        progress_revision = state.snapshot.progress_revision,
    })
end

function Store:record_victory(input)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local applied = EncounterProgress.record_victory(state.snapshot, input)
    if not applied.ok then
        return applied
    end
    state.snapshot = applied.value.snapshot
    return result_ok({
        already_applied = applied.value.already_applied,
        first_clear_awarded = applied.value.first_clear_awarded,
        row = applied.value.row,
        progress_revision = state.snapshot.progress_revision,
    })
end

function Store:export_save_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return EncounterSaveCodec.encode(state.snapshot)
end

function Store:import_save_bundle(bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local decoded = EncounterSaveCodec.decode(bundle)
    if not decoded.ok then
        return decoded
    end
    state.snapshot = copy_snapshot(decoded.value)
    return result_ok(copy_snapshot(state.snapshot))
end

return FakeEncounterProgressStore
