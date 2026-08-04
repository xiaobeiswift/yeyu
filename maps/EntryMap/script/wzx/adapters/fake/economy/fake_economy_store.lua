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

function FakeEconomyStore.new()
    local view = set_metatable({}, Store)
    STATES[view] = {
        ledger = CurrencyLedger.empty(),
        receipt_revision = 0,
        receipts = {},
        source_occurrences = {},
        reservations = {},
        reservation_counter = 0,
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
        return result_ok({
            already_present = true,
            source = copy_source(existing_source),
            receipt = state.receipts[existing_source.receipt_id]
                and copy_receipt(state.receipts[existing_source.receipt_id])
                or nil,
        })
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
    local slot5 = EconomyReceiptCodec.encode({
        receipt_revision = state.receipt_revision,
        receipts = state.receipts,
        source_occurrences = state.source_occurrences,
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
