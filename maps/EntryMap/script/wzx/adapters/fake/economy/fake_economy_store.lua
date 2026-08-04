local CurrencyLedger = require 'wzx.domain.economy.currency_ledger'
local EconomyReceiptCodec = require 'wzx.domain.economy.economy_receipt_codec'
local EconomySaveCodec = require 'wzx.domain.economy.economy_save_codec'
local Result = require 'wzx.domain.common.result'

local FakeEconomyStore = {}
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
    error_value('fake economy store is read-only', 2)
end
Store.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'INVALID_ARGUMENT',
        'error.economy.fake_store_invalid',
        false,
        details
    )
end

local function copy_accounts(accounts)
    local copied = {}
    local currency_id
    local account
    for currency_id, account in raw_next, accounts do
        copied[currency_id] = {
            balance = account.balance,
            reserved = account.reserved,
            account_revision = account.account_revision,
        }
    end
    return copied
end

local function copy_receipt(receipt)
    return {
        receipt_id = receipt.receipt_id,
        source_occurrence_id = receipt.source_occurrence_id,
        request_hash = receipt.request_hash,
        result_hash = receipt.result_hash,
        status = receipt.status,
        purpose_type = receipt.purpose_type,
        purpose_ref = receipt.purpose_ref,
        economy_revision_after = receipt.economy_revision_after,
    }
end

local function copy_source(row)
    return {
        source_occurrence_id = row.source_occurrence_id,
        receipt_id = row.receipt_id,
        status = row.status,
    }
end

local function copy_pending(row)
    local entries = {}
    local index
    for index = 1, #(row.entries or {}) do
        local entry = row.entries[index]
        entries[index] = {
            entry_type = entry.entry_type,
            target_id = entry.target_id,
            quantity = entry.quantity,
            target_character_id = entry.target_character_id,
            entry_order = entry.entry_order,
        }
    end
    return {
        pending_id = row.pending_id,
        receipt_id = row.receipt_id,
        request_hash = row.request_hash,
        purpose_type = row.purpose_type,
        purpose_ref = row.purpose_ref,
        source_occurrence_id = row.source_occurrence_id,
        reason = row.reason,
        status = row.status,
        prepared_id = row.prepared_id,
        content_hash = row.content_hash,
        source_type = row.source_type,
        source_ref = row.source_ref,
        config_version = row.config_version,
        overflow_policy = row.overflow_policy,
        seed_hash = row.seed_hash,
        entries = entries,
    }
end

function FakeEconomyStore.new()
    local view = set_metatable({}, Store)
    STATES[view] = {
        ledger = CurrencyLedger.empty(),
        receipt_revision = 0,
        receipts = {},
        source_occurrences = {},
        reservations = {},
        reservation_counter = 0,
        pending_rewards = {},
        pending_counter = 0,
    }
    return result_ok(view)
end

function Store:get_ledger()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return CurrencyLedger.snapshot(state.ledger)
end

function Store:replace_ledger(ledger)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local snap = CurrencyLedger.snapshot(ledger)
    if not snap.ok then
        return snap
    end
    state.ledger = {
        economy_revision = snap.value.economy_revision,
        accounts = copy_accounts(snap.value.accounts),
    }
    return result_ok({
        economy_revision = state.ledger.economy_revision,
    })
end

function Store:get_receipt(receipt_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local receipt = state.receipts[receipt_id]
    if receipt == nil then
        return result_ok(nil)
    end
    return result_ok(copy_receipt(receipt))
end

function Store:get_source_occurrence(source_occurrence_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local row = state.source_occurrences[source_occurrence_id]
    if row == nil then
        return result_ok(nil)
    end
    return result_ok(copy_source(row))
end

function Store:put_committed_receipt(receipt)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(receipt) ~= 'table' or get_metatable(receipt) ~= nil then
        return invalid('RECEIPT_TABLE_REQUIRED', { field = 'receipt' })
    end
    local receipt_id = raw_get(receipt, 'receipt_id')
    local source_occurrence_id = raw_get(receipt, 'source_occurrence_id')
    if type_value(receipt_id) ~= 'string' or receipt_id == '' then
        return invalid('RECEIPT_ID_REQUIRED')
    end
    if type_value(source_occurrence_id) ~= 'string' or source_occurrence_id == '' then
        return invalid('SOURCE_OCCURRENCE_ID_REQUIRED')
    end

    local existing = state.receipts[receipt_id]
    if existing ~= nil then
        return result_ok({
            already_present = true,
            receipt = copy_receipt(existing),
        })
    end
    local existing_source = state.source_occurrences[source_occurrence_id]
    if existing_source ~= nil then
        -- Allow PENDING -> COMMITTED upgrade for the same receipt (claim path).
        if existing_source.receipt_id ~= receipt_id
            or existing_source.status == 'COMMITTED'
        then
            return result_ok({
                already_present = true,
                source = copy_source(existing_source),
                receipt = state.receipts[existing_source.receipt_id]
                    and copy_receipt(state.receipts[existing_source.receipt_id])
                    or nil,
            })
        end
    end

    state.receipts[receipt_id] = copy_receipt(receipt)
    state.source_occurrences[source_occurrence_id] = {
        source_occurrence_id = source_occurrence_id,
        receipt_id = receipt_id,
        status = 'COMMITTED',
    }
    state.receipt_revision = state.receipt_revision + 1
    return result_ok({
        already_present = false,
        receipt = copy_receipt(state.receipts[receipt_id]),
        receipt_revision = state.receipt_revision,
    })
end

function Store:put_source_occurrence(row)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
        return invalid('SOURCE_TABLE_REQUIRED')
    end
    local source_occurrence_id = raw_get(row, 'source_occurrence_id')
    local receipt_id = raw_get(row, 'receipt_id')
    local status = raw_get(row, 'status') or 'PENDING'
    if type_value(source_occurrence_id) ~= 'string' or source_occurrence_id == '' then
        return invalid('SOURCE_OCCURRENCE_ID_REQUIRED')
    end
    if type_value(receipt_id) ~= 'string' or receipt_id == '' then
        return invalid('RECEIPT_ID_REQUIRED')
    end
    local existing = state.source_occurrences[source_occurrence_id]
    if existing ~= nil and existing.receipt_id ~= receipt_id then
        return result_ok({
            already_present = true,
            source = copy_source(existing),
        })
    end
    state.source_occurrences[source_occurrence_id] = {
        source_occurrence_id = source_occurrence_id,
        receipt_id = receipt_id,
        status = status,
    }
    return result_ok({
        already_present = existing ~= nil,
        source = copy_source(state.source_occurrences[source_occurrence_id]),
    })
end

function Store:put_pending_reward(pending)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(pending) ~= 'table' or get_metatable(pending) ~= nil then
        return invalid('PENDING_TABLE_REQUIRED', { field = 'pending' })
    end
    local pending_id = raw_get(pending, 'pending_id')
    if type_value(pending_id) ~= 'string' or pending_id == '' then
        return invalid('PENDING_ID_REQUIRED')
    end
    if state.pending_rewards[pending_id] ~= nil then
        return result_ok({
            already_present = true,
            pending = copy_pending(state.pending_rewards[pending_id]),
        })
    end
    local count = 0
    local key
    for key in raw_next, state.pending_rewards do
        if state.pending_rewards[key].status == 'AVAILABLE' then
            count = count + 1
        end
    end
    if count >= 64 then
        return result_err(
            'ECONOMY_PENDING_REWARD_LIMIT',
            'error.economy.pending_reward_limit',
            false,
            { reason = 'PENDING_REWARD_LIMIT', count = count }
        )
    end
    state.pending_rewards[pending_id] = copy_pending(pending)
    state.receipt_revision = state.receipt_revision + 1
    return result_ok({
        already_present = false,
        pending = copy_pending(state.pending_rewards[pending_id]),
    })
end

function Store:get_pending_reward(pending_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local row = state.pending_rewards[pending_id]
    if row == nil then
        return result_ok(nil)
    end
    return result_ok(copy_pending(row))
end

function Store:update_pending_reward_status(pending_id, status)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local row = state.pending_rewards[pending_id]
    if row == nil then
        return result_ok(nil)
    end
    row.status = status
    return result_ok(copy_pending(row))
end

function Store:create_reservation(payload)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    if type_value(payload) ~= 'table' or get_metatable(payload) ~= nil then
        return invalid('RESERVATION_TABLE_REQUIRED')
    end
    state.reservation_counter = state.reservation_counter + 1
    local reservation_id = 'reservation_' .. tostring(state.reservation_counter)
    state.reservations[reservation_id] = {
        reservation_id = reservation_id,
        status = 'RESERVED',
        costs = payload.costs,
        rewards = payload.rewards,
        purpose_type = payload.purpose_type,
        purpose_ref = payload.purpose_ref,
        request_hash = payload.request_hash,
        economy_revision = payload.economy_revision,
    }
    return result_ok({
        reservation_id = reservation_id,
        status = 'RESERVED',
    })
end

function Store:get_reservation(reservation_id)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local reservation = state.reservations[reservation_id]
    if reservation == nil then
        return result_ok(nil)
    end
    return result_ok({
        reservation_id = reservation.reservation_id,
        status = reservation.status,
        costs = reservation.costs,
        rewards = reservation.rewards,
        purpose_type = reservation.purpose_type,
        purpose_ref = reservation.purpose_ref,
        request_hash = reservation.request_hash,
        economy_revision = reservation.economy_revision,
    })
end

function Store:update_reservation_status(reservation_id, status)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local reservation = state.reservations[reservation_id]
    if reservation == nil then
        return result_ok(nil)
    end
    reservation.status = status
    return result_ok({
        reservation_id = reservation_id,
        status = status,
    })
end

function Store:export_save_bundles()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local ledger = CurrencyLedger.snapshot(state.ledger)
    if not ledger.ok then
        return ledger
    end
    local slot4 = EconomySaveCodec.encode(ledger.value)
    if not slot4.ok then
        return slot4
    end
    -- Minimal save slice only persists COMMITTED receipts/sources.
    -- In-memory PENDING rows remain available until claim in-process.
    local committed_receipts = {}
    local receipt_id
    local receipt
    for receipt_id, receipt in raw_next, state.receipts do
        if receipt.status == 'COMMITTED' then
            committed_receipts[receipt_id] = receipt
        end
    end
    local committed_sources = {}
    local source_id
    local source
    for source_id, source in raw_next, state.source_occurrences do
        if source.status == 'COMMITTED' then
            committed_sources[source_id] = source
        end
    end
    local slot5 = EconomyReceiptCodec.encode({
        receipt_revision = state.receipt_revision,
        receipts = committed_receipts,
        source_occurrences = committed_sources,
    })
    if not slot5.ok then
        return slot5
    end
    return result_ok({
        slot4 = slot4.value,
        slot5 = slot5.value,
    })
end

function Store:import_save_bundles(slot4_bundle, slot5_bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local decoded4 = EconomySaveCodec.decode(slot4_bundle)
    if not decoded4.ok then
        return decoded4
    end
    local decoded5 = EconomyReceiptCodec.decode(slot5_bundle)
    if not decoded5.ok then
        return decoded5
    end
    state.ledger = {
        economy_revision = decoded4.value.economy_revision,
        accounts = copy_accounts(decoded4.value.accounts),
    }
    state.receipt_revision = decoded5.value.receipt_revision
    state.receipts = {}
    state.source_occurrences = {}
    local receipt_id
    local receipt
    for receipt_id, receipt in raw_next, decoded5.value.receipts do
        state.receipts[receipt_id] = copy_receipt(receipt)
    end
    local source_id
    local source
    for source_id, source in raw_next, decoded5.value.source_occurrences do
        state.source_occurrences[source_id] = copy_source(source)
    end
    state.reservations = {}
    return result_ok(true)
end

return FakeEconomyStore
