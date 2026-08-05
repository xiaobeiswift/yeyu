-- Pure domain companion roster entry: discovery / recruitment / availability.
-- Compatible with Lua 5.1 and Y3 Lua 5.4 common subset; no y3 / time / random.

local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local CompanionErrorCodes = require 'wzx.domain.companion.error_codes'

local CompanionRoster = {}
local get_metatable = getmetatable
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local MAX_SAFE_INTEGER = 9007199254740991

local DISCOVERY_ORDER = {
    HIDDEN = 0,
    DISCOVERED = 1,
    RECRUITABLE = 2,
    RECRUITED = 3,
}

local DISCOVERY_STATES = {
    HIDDEN = true,
    DISCOVERED = true,
    RECRUITABLE = true,
    RECRUITED = true,
}

local AVAILABILITY_STATES = {
    AVAILABLE = true,
    TEMPORARILY_UNAVAILABLE = true,
}

local SOURCE_TYPES = {
    STORY = true,
    SIDE_QUEST = true,
    EXPLORATION = true,
    EVENT = true,
    ENTITLEMENT = true,
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.companion.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(CompanionErrorCodes.COMPANION_ARGUMENT_INVALID, reason, details)
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function copy_string_list(rows)
    if rows == nil then
        return {}
    end
    local copied = {}
    local index
    for index = 1, #rows do
        copied[index] = rows[index]
    end
    return copied
end

local function copy_entry(entry)
    return {
        companion_id = entry.companion_id,
        discovery_state = entry.discovery_state,
        availability_state = entry.availability_state,
        availability_reason_id = entry.availability_reason_id,
        recruitment_source_type = entry.recruitment_source_type,
        recruitment_source_ref = entry.recruitment_source_ref,
        recruited_receipt_id = entry.recruited_receipt_id,
        affection_points = entry.affection_points,
        affection_rank = entry.affection_rank,
        resolved_event_ids = copy_string_list(entry.resolved_event_ids),
        claimed_rank_rewards = copy_string_list(entry.claimed_rank_rewards),
        revision = entry.revision,
        last_affection_receipt_id = entry.last_affection_receipt_id,
        last_affection_result = entry.last_affection_result,
    }
end

local function validate_entry_shape(entry)
    if type_value(entry) ~= 'table' or get_metatable(entry) ~= nil then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'ENTRY_TABLE_REQUIRED',
            { field = 'entry' }
        )
    end
    local companion_id = raw_get(entry, 'companion_id')
    local checked = validate_content(companion_id, 'char_', 'companion_id')
    if not checked.ok then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'COMPANION_ID_INVALID',
            { field = 'companion_id' }
        )
    end
    local discovery = raw_get(entry, 'discovery_state')
    if DISCOVERY_STATES[discovery] ~= true then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'DISCOVERY_STATE_INVALID',
            { field = 'discovery_state', discovery_state = discovery }
        )
    end
    if not is_safe_integer(raw_get(entry, 'affection_points'), 0, 10000) then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'AFFECTION_POINTS_INVALID',
            { field = 'affection_points' }
        )
    end
    if not is_safe_integer(raw_get(entry, 'affection_rank'), 0, 5) then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'AFFECTION_RANK_INVALID',
            { field = 'affection_rank' }
        )
    end
    if not is_safe_integer(raw_get(entry, 'revision'), 0, MAX_SAFE_INTEGER) then
        return fail(
            CompanionErrorCodes.COMPANION_ENTRY_INVALID,
            'REVISION_INVALID',
            { field = 'revision' }
        )
    end
    if discovery == 'RECRUITED' then
        local availability = raw_get(entry, 'availability_state')
        if AVAILABILITY_STATES[availability] ~= true then
            return fail(
                CompanionErrorCodes.COMPANION_ENTRY_INVALID,
                'AVAILABILITY_STATE_INVALID',
                { field = 'availability_state' }
            )
        end
        local receipt = raw_get(entry, 'recruited_receipt_id')
        if type_value(receipt) ~= 'string' or receipt == '' then
            return fail(
                CompanionErrorCodes.COMPANION_ENTRY_INVALID,
                'RECRUITED_RECEIPT_REQUIRED',
                { field = 'recruited_receipt_id' }
            )
        end
    end
    return result_ok(true)
end

function CompanionRoster.create_entry(companion_id, initial_discovery_state)
    local checked = validate_content(companion_id, 'char_', 'companion_id')
    if not checked.ok then
        return invalid('COMPANION_ID_INVALID', { field = 'companion_id' })
    end
    if initial_discovery_state == nil then
        initial_discovery_state = 'HIDDEN'
    end
    if DISCOVERY_STATES[initial_discovery_state] ~= true then
        return fail(
            CompanionErrorCodes.COMPANION_DISCOVERY_STATE_INVALID,
            'DISCOVERY_STATE_UNKNOWN',
            { discovery_state = initial_discovery_state }
        )
    end
    if initial_discovery_state == 'RECRUITED' then
        return fail(
            CompanionErrorCodes.COMPANION_DISCOVERY_STATE_INVALID,
            'INITIAL_RECRUITED_FORBIDDEN',
            { discovery_state = initial_discovery_state }
        )
    end

    return result_ok({
        companion_id = companion_id,
        discovery_state = initial_discovery_state,
        availability_state = nil,
        availability_reason_id = nil,
        recruitment_source_type = nil,
        recruitment_source_ref = nil,
        recruited_receipt_id = nil,
        affection_points = 0,
        affection_rank = 0,
        resolved_event_ids = {},
        claimed_rank_rewards = {},
        revision = 0,
        last_affection_receipt_id = nil,
        last_affection_result = nil,
    })
end

function CompanionRoster.snapshot(entry)
    local validated = validate_entry_shape(entry)
    if not validated.ok then
        return validated
    end
    return result_ok(copy_entry(entry))
end

function CompanionRoster.advance_discovery(entry, target_state)
    local validated = validate_entry_shape(entry)
    if not validated.ok then
        return validated
    end
    if DISCOVERY_STATES[target_state] ~= true then
        return fail(
            CompanionErrorCodes.COMPANION_DISCOVERY_STATE_INVALID,
            'TARGET_STATE_UNKNOWN',
            { target_state = target_state }
        )
    end
    if target_state == 'RECRUITED' then
        return fail(
            CompanionErrorCodes.COMPANION_DISCOVERY_STATE_INVALID,
            'USE_RECRUIT_FOR_RECRUITED',
            { target_state = target_state }
        )
    end

    local current_order = DISCOVERY_ORDER[entry.discovery_state]
    local target_order = DISCOVERY_ORDER[target_state]
    if target_order < current_order then
        return fail(
            CompanionErrorCodes.COMPANION_DISCOVERY_REGRESSION,
            'DISCOVERY_CANNOT_REGRESS',
            {
                current = entry.discovery_state,
                target = target_state,
            }
        )
    end
    if target_order == current_order then
        return result_ok(copy_entry(entry))
    end

    local next_entry = copy_entry(entry)
    next_entry.discovery_state = target_state
    next_entry.revision = entry.revision + 1
    return result_ok(next_entry)
end

local function validate_evidence(evidence)
    if type_value(evidence) ~= 'table' or get_metatable(evidence) ~= nil then
        return fail(
            CompanionErrorCodes.COMPANION_RECRUITMENT_EVIDENCE_INVALID,
            'EVIDENCE_TABLE_REQUIRED',
            { field = 'evidence' }
        )
    end
    local source_type = raw_get(evidence, 'source_type')
    if SOURCE_TYPES[source_type] ~= true then
        return fail(
            CompanionErrorCodes.COMPANION_RECRUITMENT_EVIDENCE_INVALID,
            'SOURCE_TYPE_INVALID',
            { field = 'source_type', source_type = source_type }
        )
    end
    local source_ref = raw_get(evidence, 'source_ref')
    if type_value(source_ref) ~= 'string' or source_ref == '' then
        return fail(
            CompanionErrorCodes.COMPANION_RECRUITMENT_EVIDENCE_INVALID,
            'SOURCE_REF_INVALID',
            { field = 'source_ref' }
        )
    end
    local receipt_id = raw_get(evidence, 'receipt_id')
    local checked_receipt = validate_derived(receipt_id, 'receipt_id')
    if not checked_receipt.ok then
        return fail(
            CompanionErrorCodes.COMPANION_RECRUITMENT_EVIDENCE_INVALID,
            'RECEIPT_ID_INVALID',
            { field = 'receipt_id' }
        )
    end
    return result_ok({
        source_type = source_type,
        source_ref = source_ref,
        receipt_id = receipt_id,
    })
end

function CompanionRoster.recruit(entry, evidence)
    local validated = validate_entry_shape(entry)
    if not validated.ok then
        return validated
    end
    local checked_evidence = validate_evidence(evidence)
    if not checked_evidence.ok then
        return checked_evidence
    end
    local normalized = checked_evidence.value

    if entry.discovery_state == 'RECRUITED' then
        if entry.recruited_receipt_id == normalized.receipt_id then
            -- Same receipt: idempotent original outcome.
            return result_ok({
                entry = copy_entry(entry),
                already_recruited = false,
                idempotent = true,
            })
        end
        -- Different receipt: already owned, no state change.
        return result_ok({
            entry = copy_entry(entry),
            already_recruited = true,
            idempotent = false,
        })
    end

    local next_entry = copy_entry(entry)
    next_entry.discovery_state = 'RECRUITED'
    next_entry.availability_state = 'AVAILABLE'
    next_entry.availability_reason_id = nil
    next_entry.recruitment_source_type = normalized.source_type
    next_entry.recruitment_source_ref = normalized.source_ref
    next_entry.recruited_receipt_id = normalized.receipt_id
    next_entry.revision = entry.revision + 1

    return result_ok({
        entry = next_entry,
        already_recruited = false,
        idempotent = false,
    })
end

function CompanionRoster.set_availability(entry, availability_state, reason_id)
    local validated = validate_entry_shape(entry)
    if not validated.ok then
        return validated
    end
    if entry.discovery_state ~= 'RECRUITED' then
        return fail(
            CompanionErrorCodes.COMPANION_NOT_RECRUITED,
            'AVAILABILITY_REQUIRES_RECRUITED',
            { discovery_state = entry.discovery_state }
        )
    end
    if AVAILABILITY_STATES[availability_state] ~= true then
        return fail(
            CompanionErrorCodes.COMPANION_AVAILABILITY_INVALID,
            'AVAILABILITY_STATE_UNKNOWN',
            { availability_state = availability_state }
        )
    end
    if reason_id ~= nil then
        if type_value(reason_id) ~= 'string' or reason_id == '' then
            return invalid('REASON_ID_INVALID', { field = 'reason_id' })
        end
    end
    if availability_state == 'AVAILABLE' then
        reason_id = nil
    end

    if entry.availability_state == availability_state
        and entry.availability_reason_id == reason_id
    then
        return result_ok(copy_entry(entry))
    end

    local next_entry = copy_entry(entry)
    next_entry.availability_state = availability_state
    next_entry.availability_reason_id = reason_id
    next_entry.revision = entry.revision + 1
    return result_ok(next_entry)
end

CompanionRoster.DISCOVERY_STATES = DISCOVERY_STATES
CompanionRoster.AVAILABILITY_STATES = AVAILABILITY_STATES
CompanionRoster.SOURCE_TYPES = SOURCE_TYPES
CompanionRoster.DISCOVERY_ORDER = DISCOVERY_ORDER

return CompanionRoster
