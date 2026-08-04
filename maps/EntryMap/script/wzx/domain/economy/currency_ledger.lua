local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'

local CurrencyLedger = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_floor = math.floor
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_DELTA = 1000000000

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.economy.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(EconomyErrorCodes.ECONOMY_ARGUMENT_INVALID, reason, details)
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

local function ensure_account(accounts, currency_id)
    local account = accounts[currency_id]
    if account == nil then
        account = {
            balance = 0,
            reserved = 0,
            account_revision = 0,
        }
        accounts[currency_id] = account
    end
    return account
end

function CurrencyLedger.empty()
    return {
        economy_revision = 0,
        accounts = {},
    }
end

function CurrencyLedger.snapshot(state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('LEDGER_STATE_REQUIRED', { field = 'state' })
    end
    if not is_safe_integer(raw_get(state, 'economy_revision'), 0, MAX_SAFE_INTEGER) then
        return invalid('ECONOMY_REVISION_INVALID', { field = 'economy_revision' })
    end
    local accounts = raw_get(state, 'accounts')
    if type_value(accounts) ~= 'table' or get_metatable(accounts) ~= nil then
        return invalid('ACCOUNTS_TABLE_REQUIRED', { field = 'accounts' })
    end
    return result_ok({
        economy_revision = state.economy_revision,
        accounts = copy_accounts(accounts),
    })
end

function CurrencyLedger.get_account(state, currency_id)
    local snap = CurrencyLedger.snapshot(state)
    if not snap.ok then
        return snap
    end
    local checked = validate_content(currency_id, 'currency_', 'currency_id')
    if not checked.ok then
        return invalid('CURRENCY_ID_INVALID', { field = 'currency_id' })
    end
    local account = snap.value.accounts[currency_id]
    if account == nil then
        return result_ok({
            currency_id = currency_id,
            balance = 0,
            reserved = 0,
            available = 0,
            account_revision = 0,
        })
    end
    return result_ok({
        currency_id = currency_id,
        balance = account.balance,
        reserved = account.reserved,
        available = account.balance - account.reserved,
        account_revision = account.account_revision,
    })
end

local function normalize_delta_rows(rows, field_name)
    if type_value(rows) ~= 'table'
        or get_metatable(rows) ~= nil
        or not is_dense_array(rows)
    then
        return invalid('DENSE_ARRAY_REQUIRED', { field = field_name })
    end

    local merged = {}
    local index
    for index = 1, #rows do
        local row = rows[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return invalid('DELTA_ROW_TABLE_REQUIRED', {
                field = field_name .. '[' .. tostring(index) .. ']',
            })
        end
        local currency_id = raw_get(row, 'currency_id')
        local amount = raw_get(row, 'amount')
        local checked = validate_content(currency_id, 'currency_', 'currency_id')
        if not checked.ok then
            return invalid('CURRENCY_ID_INVALID', {
                field = field_name .. '[' .. tostring(index) .. '].currency_id',
            })
        end
        if not is_safe_integer(amount, 1, MAX_DELTA) then
            return invalid('AMOUNT_INVALID', {
                field = field_name .. '[' .. tostring(index) .. '].amount',
            })
        end
        local previous = merged[currency_id] or 0
        local next_amount = previous + amount
        if next_amount > MAX_SAFE_INTEGER then
            return invalid('AMOUNT_OVERFLOW', {
                field = field_name,
                currency_id = currency_id,
            })
        end
        merged[currency_id] = next_amount
    end

    local ordered = {}
    local currency_id
    for currency_id in raw_next, merged do
        ordered[#ordered + 1] = currency_id
    end
    table_sort(ordered, bytewise_string_less)

    local normalized = {}
    for index = 1, #ordered do
        currency_id = ordered[index]
        normalized[index] = {
            currency_id = currency_id,
            amount = merged[currency_id],
        }
    end
    return result_ok(normalized)
end

-- Public normalizer for application-layer request digests (merge + sort).
function CurrencyLedger.normalize_deltas(rows, field_name)
    return normalize_delta_rows(rows, field_name or 'deltas')
end

-- costs and rewards are dense arrays of { currency_id, amount }.
-- Catalog must expose :require(currency_id) -> Result definition.
function CurrencyLedger.plan_transaction(state, costs, rewards, catalog)
    local snap = CurrencyLedger.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require) ~= 'function' then
        return invalid('CURRENCY_CATALOG_REQUIRED', { field = 'catalog' })
    end

    local cost_rows = normalize_delta_rows(costs or {}, 'costs')
    if not cost_rows.ok then
        return cost_rows
    end
    local reward_rows = normalize_delta_rows(rewards or {}, 'rewards')
    if not reward_rows.ok then
        return reward_rows
    end

    local accounts = copy_accounts(snap.value.accounts)
    local cost_index
    for cost_index = 1, #cost_rows.value do
        local row = cost_rows.value[cost_index]
        local definition = catalog:require(row.currency_id)
        if not definition.ok then
            return definition
        end
        if definition.value.category == 'PREMIUM_PLATFORM' then
            -- Spending premium currency is allowed only through authorized sinks.
            -- Minimal slice still permits spend; grant path blocks premium minting.
        end
        local account = ensure_account(accounts, row.currency_id)
        local available = account.balance - account.reserved
        if available < row.amount then
            return fail(
                EconomyErrorCodes.ECONOMY_CURRENCY_INSUFFICIENT,
                'AVAILABLE_BELOW_COST',
                {
                    currency_id = row.currency_id,
                    available = available,
                    required = row.amount,
                }
            )
        end
    end

    for cost_index = 1, #reward_rows.value do
        local row = reward_rows.value[cost_index]
        local definition = catalog:require(row.currency_id)
        if not definition.ok then
            return definition
        end
        if definition.value.category == 'PREMIUM_PLATFORM' then
            return fail(
                EconomyErrorCodes.ECONOMY_SOURCE_NOT_AUTHORIZED,
                'PREMIUM_PLATFORM_MINT_FORBIDDEN',
                { currency_id = row.currency_id }
            )
        end
        local account = ensure_account(accounts, row.currency_id)
        local projected = account.balance + row.amount
        if projected > definition.value.balance_cap then
            return fail(
                EconomyErrorCodes.ECONOMY_CURRENCY_CAP_REACHED,
                'BALANCE_CAP_EXCEEDED',
                {
                    currency_id = row.currency_id,
                    balance = account.balance,
                    amount = row.amount,
                    balance_cap = definition.value.balance_cap,
                    overflow_policy = definition.value.overflow_policy,
                }
            )
        end
    end

    return result_ok({
        economy_revision = snap.value.economy_revision,
        costs = cost_rows.value,
        rewards = reward_rows.value,
    })
end

function CurrencyLedger.apply_plan(state, plan)
    local snap = CurrencyLedger.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(plan) ~= 'table' or get_metatable(plan) ~= nil then
        return invalid('PLAN_TABLE_REQUIRED', { field = 'plan' })
    end
    if raw_get(plan, 'economy_revision') ~= snap.value.economy_revision then
        return fail(
            EconomyErrorCodes.ECONOMY_TRANSACTION_INVALID,
            'LEDGER_REVISION_MISMATCH',
            {
                expected = plan.economy_revision,
                actual = snap.value.economy_revision,
            }
        )
    end

    local accounts = copy_accounts(snap.value.accounts)
    local costs = raw_get(plan, 'costs') or {}
    local rewards = raw_get(plan, 'rewards') or {}
    local index
    for index = 1, #costs do
        local row = costs[index]
        local account = ensure_account(accounts, row.currency_id)
        account.balance = account.balance - row.amount
        account.account_revision = account.account_revision + 1
    end
    for index = 1, #rewards do
        local row = rewards[index]
        local account = ensure_account(accounts, row.currency_id)
        account.balance = account.balance + row.amount
        account.account_revision = account.account_revision + 1
    end

    local changed = (#costs > 0) or (#rewards > 0)
    local next_revision = snap.value.economy_revision
    if changed then
        next_revision = next_revision + 1
    end

    return result_ok({
        economy_revision = next_revision,
        accounts = accounts,
    })
end

function CurrencyLedger.reserve_costs(state, costs, catalog)
    local plan = CurrencyLedger.plan_transaction(state, costs, {}, catalog)
    if not plan.ok then
        return plan
    end
    local snap = CurrencyLedger.snapshot(state)
    if not snap.ok then
        return snap
    end
    local accounts = copy_accounts(snap.value.accounts)
    local index
    for index = 1, #plan.value.costs do
        local row = plan.value.costs[index]
        local account = ensure_account(accounts, row.currency_id)
        account.reserved = account.reserved + row.amount
    end
    return result_ok({
        economy_revision = snap.value.economy_revision,
        accounts = accounts,
        reserved_costs = plan.value.costs,
    })
end

function CurrencyLedger.release_costs(state, costs)
    local snap = CurrencyLedger.snapshot(state)
    if not snap.ok then
        return snap
    end
    local cost_rows = normalize_delta_rows(costs or {}, 'costs')
    if not cost_rows.ok then
        return cost_rows
    end
    local accounts = copy_accounts(snap.value.accounts)
    local index
    for index = 1, #cost_rows.value do
        local row = cost_rows.value[index]
        local account = ensure_account(accounts, row.currency_id)
        if account.reserved < row.amount then
            return fail(
                EconomyErrorCodes.ECONOMY_TRANSACTION_INVALID,
                'RESERVED_BELOW_RELEASE',
                {
                    currency_id = row.currency_id,
                    reserved = account.reserved,
                    amount = row.amount,
                }
            )
        end
        account.reserved = account.reserved - row.amount
    end
    return result_ok({
        economy_revision = snap.value.economy_revision,
        accounts = accounts,
    })
end

function CurrencyLedger.commit_reserved(state, costs, rewards, catalog)
    local snap = CurrencyLedger.snapshot(state)
    if not snap.ok then
        return snap
    end
    local cost_rows = normalize_delta_rows(costs or {}, 'costs')
    if not cost_rows.ok then
        return cost_rows
    end
    local reward_rows = normalize_delta_rows(rewards or {}, 'rewards')
    if not reward_rows.ok then
        return reward_rows
    end
    if type_value(catalog) ~= 'table' or type_value(catalog.require) ~= 'function' then
        return invalid('CURRENCY_CATALOG_REQUIRED', { field = 'catalog' })
    end

    local accounts = copy_accounts(snap.value.accounts)
    local index
    for index = 1, #cost_rows.value do
        local row = cost_rows.value[index]
        local account = ensure_account(accounts, row.currency_id)
        if account.reserved < row.amount or account.balance < row.amount then
            return fail(
                EconomyErrorCodes.ECONOMY_CURRENCY_INSUFFICIENT,
                'RESERVED_COMMIT_INSUFFICIENT',
                {
                    currency_id = row.currency_id,
                    balance = account.balance,
                    reserved = account.reserved,
                    amount = row.amount,
                }
            )
        end
        account.reserved = account.reserved - row.amount
        account.balance = account.balance - row.amount
        account.account_revision = account.account_revision + 1
    end
    for index = 1, #reward_rows.value do
        local row = reward_rows.value[index]
        local definition = catalog:require(row.currency_id)
        if not definition.ok then
            return definition
        end
        if definition.value.category == 'PREMIUM_PLATFORM' then
            return fail(
                EconomyErrorCodes.ECONOMY_SOURCE_NOT_AUTHORIZED,
                'PREMIUM_PLATFORM_MINT_FORBIDDEN',
                { currency_id = row.currency_id }
            )
        end
        local account = ensure_account(accounts, row.currency_id)
        local projected = account.balance + row.amount
        if projected > definition.value.balance_cap then
            return fail(
                EconomyErrorCodes.ECONOMY_CURRENCY_CAP_REACHED,
                'BALANCE_CAP_EXCEEDED',
                {
                    currency_id = row.currency_id,
                    balance = account.balance,
                    amount = row.amount,
                    balance_cap = definition.value.balance_cap,
                }
            )
        end
        account.balance = projected
        account.account_revision = account.account_revision + 1
    end

    local changed = (#cost_rows.value > 0) or (#reward_rows.value > 0)
    local next_revision = snap.value.economy_revision
    if changed then
        next_revision = next_revision + 1
    end
    return result_ok({
        economy_revision = next_revision,
        accounts = accounts,
        costs = cost_rows.value,
        rewards = reward_rows.value,
    })
end

return CurrencyLedger
