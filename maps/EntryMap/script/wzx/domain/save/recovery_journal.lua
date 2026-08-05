-- System 18 owns save_recovery_transactions (slot 5).
-- Rows only REFERENCE business receipt ids; they never re-derive domain identity.
-- Traversal landing evidence: business_receipt_id == world_position.last_landing_receipt_id.

local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'

local RecoveryJournal = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_derived = RuntimeId.validate_derived

local CURRENT_SCHEMA_VERSION = 1
local MAX_ROWS = 256
local MAX_SAFE_INTEGER = 9007199254740991
local ZERO_DIGEST = string.rep('0', 64)

local TRANSACTION_TYPES = {
    TRAVERSAL_LANDING = true,
}

local STATES = {
    PREPARED = true,
    APPLYING = true,
    COMMITTED = true,
    RECOVERY_REQUIRED = true,
    FAILED_BEFORE_APPLY = true,
    COMPENSATED = true,
}

local ROW_FIELDS = {
    transaction_id = true,
    transaction_type = true,
    state = true,
    business_receipt_id = true,
    target_checkpoint_id = true,
    owner_slot_id = true,
    owner_section_key = true,
    command_id = true,
    outcome_digest = true,
    retry_count = true,
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
        SaveErrorCodes.SAVE_ARGUMENT_INVALID,
        'error.save.recovery_journal_invalid',
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
            return invalid('UNKNOWN_FIELD', {
                field = path .. '.' .. tostring(key),
            })
        end
    end
    return nil
end

local function is_sha256(value)
    return type_value(value) == 'string'
        and #value == 64
        and string.match(value, '^[a-f0-9]+$') ~= nil
end

local function row_less(left, right)
    if left.business_receipt_id ~= right.business_receipt_id then
        return bytewise_string_less(
            left.business_receipt_id,
            right.business_receipt_id
        )
    end
    return bytewise_string_less(left.transaction_id, right.transaction_id)
end

local function validate_row(row, path)
    local unknown = no_unknown_fields(row, ROW_FIELDS, path)
    if unknown ~= nil then
        return unknown
    end
    local transaction_id = validate_component(
        raw_get(row, 'transaction_id'),
        'transaction_id'
    )
    if not transaction_id.ok then
        return invalid('TRANSACTION_ID_INVALID', { field = path .. '.transaction_id' })
    end
    local transaction_type = raw_get(row, 'transaction_type')
    if type_value(transaction_type) ~= 'string'
        or TRANSACTION_TYPES[transaction_type] ~= true
    then
        return invalid('TRANSACTION_TYPE_INVALID', {
            field = path .. '.transaction_type',
            value = transaction_type,
        })
    end
    local state = raw_get(row, 'state')
    if type_value(state) ~= 'string' or STATES[state] ~= true then
        return invalid('STATE_INVALID', {
            field = path .. '.state',
            value = state,
        })
    end
    local business_receipt_id = validate_derived(
        raw_get(row, 'business_receipt_id'),
        'business_receipt_id'
    )
    if not business_receipt_id.ok then
        return invalid('BUSINESS_RECEIPT_ID_INVALID', {
            field = path .. '.business_receipt_id',
        })
    end
    local target_checkpoint_id = validate_derived(
        raw_get(row, 'target_checkpoint_id'),
        'target_checkpoint_id'
    )
    if not target_checkpoint_id.ok then
        return invalid('TARGET_CHECKPOINT_ID_INVALID', {
            field = path .. '.target_checkpoint_id',
        })
    end
    if not is_integer(raw_get(row, 'owner_slot_id'), 2, 5) then
        return invalid('OWNER_SLOT_ID_INVALID', {
            field = path .. '.owner_slot_id',
        })
    end
    local owner_section_key = raw_get(row, 'owner_section_key')
    if type_value(owner_section_key) ~= 'string'
        or owner_section_key == ''
        or #owner_section_key > 96
    then
        return invalid('OWNER_SECTION_KEY_INVALID', {
            field = path .. '.owner_section_key',
        })
    end
    local command_id = validate_component(raw_get(row, 'command_id'), 'command_id')
    if not command_id.ok then
        return invalid('COMMAND_ID_INVALID', { field = path .. '.command_id' })
    end
    local outcome_digest = raw_get(row, 'outcome_digest')
    if outcome_digest == nil then
        outcome_digest = ZERO_DIGEST
    elseif not is_sha256(outcome_digest) then
        return invalid('OUTCOME_DIGEST_INVALID', {
            field = path .. '.outcome_digest',
        })
    end
    if not is_integer(raw_get(row, 'retry_count'), 0, MAX_SAFE_INTEGER) then
        return invalid('RETRY_COUNT_INVALID', { field = path .. '.retry_count' })
    end
    return result_ok({
        transaction_id = transaction_id.value,
        transaction_type = transaction_type,
        state = state,
        business_receipt_id = business_receipt_id.value,
        target_checkpoint_id = target_checkpoint_id.value,
        owner_slot_id = row.owner_slot_id,
        owner_section_key = owner_section_key,
        command_id = command_id.value,
        outcome_digest = outcome_digest,
        retry_count = row.retry_count,
    })
end

function RecoveryJournal.validate_rows(rows)
    if rows == nil then
        return result_ok({})
    end
    if type_value(rows) ~= 'table' then
        return invalid('ROWS_TABLE_REQUIRED', { field = 'save_recovery_transactions' })
    end
    local count = #rows
    if count > MAX_ROWS then
        return failure(
            SaveErrorCodes.SAVE_CORRUPT,
            'error.save.recovery_journal_limit_exceeded',
            'ROW_LIMIT_EXCEEDED',
            { count = count, max = MAX_ROWS }
        )
    end
    local validated = {}
    local seen_receipt = {}
    local index
    for index = 1, count do
        local row = rows[index]
        local path = 'save_recovery_transactions[' .. index .. ']'
        if type_value(row) ~= 'table' then
            return invalid('ROW_TABLE_REQUIRED', { field = path })
        end
        local checked = validate_row(row, path)
        if not checked.ok then
            return checked
        end
        local receipt = checked.value.business_receipt_id
        if seen_receipt[receipt] then
            return invalid('DUPLICATE_BUSINESS_RECEIPT', {
                field = path .. '.business_receipt_id',
                business_receipt_id = receipt,
            })
        end
        seen_receipt[receipt] = true
        validated[index] = checked.value
    end
    table_sort(validated, row_less)
    return result_ok(validated)
end

function RecoveryJournal.build_traversal_landing_row(input)
    if type_value(input) ~= 'table' then
        return invalid('INPUT_REQUIRED')
    end
    local transaction_id = validate_component(
        raw_get(input, 'transaction_id'),
        'transaction_id'
    )
    if not transaction_id.ok then
        return invalid('TRANSACTION_ID_INVALID', { field = 'transaction_id' })
    end
    local business_receipt_id = validate_derived(
        raw_get(input, 'business_receipt_id')
            or raw_get(input, 'landing_receipt_id'),
        'business_receipt_id'
    )
    if not business_receipt_id.ok then
        return invalid('BUSINESS_RECEIPT_ID_INVALID', {
            field = 'business_receipt_id',
        })
    end
    local target_checkpoint_id = validate_derived(
        raw_get(input, 'target_checkpoint_id'),
        'target_checkpoint_id'
    )
    if not target_checkpoint_id.ok then
        return invalid('TARGET_CHECKPOINT_ID_INVALID', {
            field = 'target_checkpoint_id',
        })
    end
    local command_id = validate_component(
        raw_get(input, 'command_id'),
        'command_id'
    )
    if not command_id.ok then
        return invalid('COMMAND_ID_INVALID', { field = 'command_id' })
    end
    local outcome_digest = raw_get(input, 'outcome_digest') or ZERO_DIGEST
    if not is_sha256(outcome_digest) then
        return invalid('OUTCOME_DIGEST_INVALID', { field = 'outcome_digest' })
    end
    local retry_count = raw_get(input, 'retry_count') or 0
    if not is_integer(retry_count, 0, MAX_SAFE_INTEGER) then
        return invalid('RETRY_COUNT_INVALID', { field = 'retry_count' })
    end
    local state = raw_get(input, 'state') or 'COMMITTED'
    if STATES[state] ~= true then
        return invalid('STATE_INVALID', { field = 'state' })
    end
    return result_ok({
        transaction_id = transaction_id.value,
        transaction_type = 'TRAVERSAL_LANDING',
        state = state,
        business_receipt_id = business_receipt_id.value,
        target_checkpoint_id = target_checkpoint_id.value,
        owner_slot_id = 2,
        owner_section_key = 'world_position',
        command_id = command_id.value,
        outcome_digest = outcome_digest,
        retry_count = retry_count,
    })
end

-- Upsert by business_receipt_id. Same receipt + same identity fields is no-op;
-- conflicting identity for same receipt fails closed.
function RecoveryJournal.upsert_row(existing_rows, row)
    local validated_existing = RecoveryJournal.validate_rows(existing_rows)
    if not validated_existing.ok then
        return validated_existing
    end
    local validated_row = validate_row(row, 'row')
    if not validated_row.ok then
        return validated_row
    end
    validated_row = validated_row.value

    local next_rows = {}
    local index
    local replaced = false
    for index = 1, #validated_existing.value do
        local prior = validated_existing.value[index]
        if prior.business_receipt_id == validated_row.business_receipt_id then
            if prior.transaction_id ~= validated_row.transaction_id
                or prior.command_id ~= validated_row.command_id
                or prior.target_checkpoint_id ~= validated_row.target_checkpoint_id
                or prior.outcome_digest ~= validated_row.outcome_digest
                or prior.state ~= validated_row.state
            then
                -- Idempotent re-commit of the same landing may only restate
                -- matching evidence. Changing identity is a conflict.
                if prior.transaction_id == validated_row.transaction_id
                    and prior.command_id == validated_row.command_id
                    and prior.business_receipt_id == validated_row.business_receipt_id
                    and prior.owner_slot_id == validated_row.owner_slot_id
                    and prior.owner_section_key == validated_row.owner_section_key
                then
                    -- Allow state/checkpoint/digest refresh only when transaction
                    -- and command stay bound to the same business receipt.
                    next_rows[#next_rows + 1] = validated_row
                    replaced = true
                else
                    return invalid('RECOVERY_ROW_CONFLICT', {
                        business_receipt_id = validated_row.business_receipt_id,
                        prior_transaction_id = prior.transaction_id,
                        next_transaction_id = validated_row.transaction_id,
                    })
                end
            else
                next_rows[#next_rows + 1] = prior
                replaced = true
            end
        else
            next_rows[#next_rows + 1] = prior
        end
    end
    if not replaced then
        if #next_rows >= MAX_ROWS then
            return failure(
                SaveErrorCodes.SAVE_CORRUPT,
                'error.save.recovery_journal_limit_exceeded',
                'ROW_LIMIT_EXCEEDED',
                { count = #next_rows + 1, max = MAX_ROWS }
            )
        end
        next_rows[#next_rows + 1] = validated_row
    end
    table_sort(next_rows, row_less)
    return result_ok({
        rows = next_rows,
        upserted = true,
        replaced = replaced,
        row = validated_row,
    })
end

function RecoveryJournal.find_by_business_receipt(rows, business_receipt_id)
    local validated = RecoveryJournal.validate_rows(rows)
    if not validated.ok then
        return validated
    end
    local receipt = validate_derived(business_receipt_id, 'business_receipt_id')
    if not receipt.ok then
        return invalid('BUSINESS_RECEIPT_ID_INVALID', {
            field = 'business_receipt_id',
        })
    end
    local index
    for index = 1, #validated.value do
        local row = validated.value[index]
        if row.business_receipt_id == receipt.value then
            return result_ok(row)
        end
    end
    return result_ok(nil)
end

-- Evidence pair for landing recovery: slot2 last_landing_receipt_id must equal
-- a COMMITTED TRAVERSAL_LANDING recovery row business_receipt_id when present.
function RecoveryJournal.reconcile_landing_evidence(position, rows)
    if type_value(position) ~= 'table' then
        return invalid('POSITION_REQUIRED')
    end
    local last = raw_get(position, 'last_landing_receipt_id')
    if last == nil then
        return result_ok({
            status = 'NO_LANDING',
            matched = false,
        })
    end
    local found = RecoveryJournal.find_by_business_receipt(rows, last)
    if not found.ok then
        return found
    end
    if found.value == nil then
        return result_ok({
            status = 'RECEIPT_WITHOUT_RECOVERY_ROW',
            matched = false,
            last_landing_receipt_id = last,
        })
    end
    if found.value.transaction_type ~= 'TRAVERSAL_LANDING' then
        return result_ok({
            status = 'RECOVERY_TYPE_MISMATCH',
            matched = false,
            last_landing_receipt_id = last,
            transaction_type = found.value.transaction_type,
        })
    end
    if found.value.state ~= 'COMMITTED' then
        return result_ok({
            status = 'RECOVERY_NOT_COMMITTED',
            matched = false,
            last_landing_receipt_id = last,
            state = found.value.state,
            transaction_id = found.value.transaction_id,
        })
    end
    if found.value.owner_slot_id ~= 2
        or found.value.owner_section_key ~= 'world_position'
    then
        return result_ok({
            status = 'RECOVERY_OWNER_MISMATCH',
            matched = false,
            last_landing_receipt_id = last,
            owner_slot_id = found.value.owner_slot_id,
            owner_section_key = found.value.owner_section_key,
        })
    end
    return result_ok({
        status = 'MATCHED',
        matched = true,
        last_landing_receipt_id = last,
        transaction_id = found.value.transaction_id,
        target_checkpoint_id = found.value.target_checkpoint_id,
        command_id = found.value.command_id,
    })
end

RecoveryJournal.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION
RecoveryJournal.MAX_ROWS = MAX_ROWS
RecoveryJournal.ZERO_DIGEST = ZERO_DIGEST

return RecoveryJournal
