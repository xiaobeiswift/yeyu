local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'

local EconomySaveCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content

local CURRENT_SCHEMA_VERSION = 1
local MAX_CURRENCY_ROWS = 64
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_BALANCE = 2000000000

local BUNDLE_FIELDS = {
    economy_metadata = true,
    currency_balance_rows = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    economy_revision = true,
}
local BALANCE_ROW_FIELDS = {
    currency_id = true,
    balance = true,
    account_revision = true,
}
local SNAPSHOT_FIELDS = {
    economy_revision = true,
    accounts = true,
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
        EconomyErrorCodes.ECONOMY_SAVE_INVALID,
        'error.economy.save_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        EconomyErrorCodes.ECONOMY_SAVE_LIMIT_EXCEEDED,
        'error.economy.save_limit_exceeded',
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
        if type_value(key) ~= 'string' or not allowed[key] then
            return invalid('UNKNOWN_FIELD', {
                field = path == '$' and tostring(key) or (path .. '.' .. tostring(key)),
            })
        end
    end
    return nil
end

function EconomySaveCodec.encode(snapshot)
    local err = no_unknown_fields(snapshot, SNAPSHOT_FIELDS, '$')
    if err ~= nil then
        return err
    end
    if not is_integer(snapshot.economy_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('ECONOMY_REVISION_INVALID', { field = 'economy_revision' })
    end
    if type_value(snapshot.accounts) ~= 'table' then
        return invalid('ACCOUNTS_TABLE_REQUIRED', { field = 'accounts' })
    end

    local currency_ids = {}
    local currency_id
    for currency_id in raw_next, snapshot.accounts do
        currency_ids[#currency_ids + 1] = currency_id
    end
    table_sort(currency_ids, bytewise_string_less)
    if #currency_ids > MAX_CURRENCY_ROWS then
        return limit_exceeded('CURRENCY_ROW_LIMIT', {
            count = #currency_ids,
            max_currency_rows = MAX_CURRENCY_ROWS,
        })
    end

    local rows = {}
    local index
    for index = 1, #currency_ids do
        currency_id = currency_ids[index]
        local checked = validate_content(currency_id, 'currency_', 'currency_id')
        if not checked.ok then
            return invalid('CURRENCY_ID_INVALID', { currency_id = currency_id })
        end
        local account = snapshot.accounts[currency_id]
        if type_value(account) ~= 'table' then
            return invalid('ACCOUNT_TABLE_REQUIRED', { currency_id = currency_id })
        end
        local account_err = no_unknown_fields(account, {
            balance = true,
            reserved = true,
            account_revision = true,
        }, 'accounts.' .. currency_id)
        if account_err ~= nil then
            return account_err
        end
        if not is_integer(account.balance, 0, MAX_BALANCE) then
            return invalid('BALANCE_INVALID', { currency_id = currency_id })
        end
        if not is_integer(account.reserved, 0, MAX_BALANCE) then
            return invalid('RESERVED_INVALID', { currency_id = currency_id })
        end
        if account.reserved ~= 0 then
            -- Permanent saves must not keep runtime reservations.
            return invalid('RESERVED_MUST_BE_ZERO_ON_SAVE', {
                currency_id = currency_id,
                reserved = account.reserved,
            })
        end
        if not is_integer(account.account_revision, 0, MAX_SAFE_INTEGER) then
            return invalid('ACCOUNT_REVISION_INVALID', { currency_id = currency_id })
        end
        if account.balance == 0 and account.account_revision == 0 then
            -- Skip empty zero accounts to keep payload compact.
        else
            rows[#rows + 1] = {
                currency_id = currency_id,
                balance = account.balance,
                account_revision = account.account_revision,
            }
        end
    end

    return result_ok({
        economy_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            economy_revision = snapshot.economy_revision,
        },
        currency_balance_rows = rows,
    })
end

function EconomySaveCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    local metadata = bundle.economy_metadata
    err = no_unknown_fields(metadata, METADATA_FIELDS, 'economy_metadata')
    if err ~= nil then
        return err
    end
    if metadata.schema_version ~= CURRENT_SCHEMA_VERSION then
        return failure(
            EconomyErrorCodes.ECONOMY_SAVE_VERSION_UNSUPPORTED,
            'error.economy.save_version_unsupported',
            'SCHEMA_VERSION_UNSUPPORTED',
            {
                actual = metadata.schema_version,
                current = CURRENT_SCHEMA_VERSION,
            }
        )
    end
    if not is_integer(metadata.economy_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('ECONOMY_REVISION_INVALID', { field = 'economy_revision' })
    end

    local rows = bundle.currency_balance_rows
    if type_value(rows) ~= 'table' then
        return invalid('CURRENCY_BALANCE_ROWS_REQUIRED', {
            field = 'currency_balance_rows',
        })
    end
    local count = #rows
    if count > MAX_CURRENCY_ROWS then
        return limit_exceeded('CURRENCY_ROW_LIMIT', {
            count = count,
            max_currency_rows = MAX_CURRENCY_ROWS,
        })
    end

    local accounts = {}
    local previous_id = nil
    local index
    for index = 1, count do
        local row = rows[index]
        err = no_unknown_fields(row, BALANCE_ROW_FIELDS, 'currency_balance_rows[' .. index .. ']')
        if err ~= nil then
            return err
        end
        local checked = validate_content(row.currency_id, 'currency_', 'currency_id')
        if not checked.ok then
            return invalid('CURRENCY_ID_INVALID', {
                field = 'currency_balance_rows[' .. index .. '].currency_id',
            })
        end
        if previous_id ~= nil and not bytewise_string_less(previous_id, row.currency_id) then
            return invalid('CURRENCY_ROWS_NOT_SORTED_UNIQUE', {
                previous = previous_id,
                current = row.currency_id,
            })
        end
        if not is_integer(row.balance, 0, MAX_BALANCE) then
            return invalid('BALANCE_INVALID', {
                field = 'currency_balance_rows[' .. index .. '].balance',
            })
        end
        if not is_integer(row.account_revision, 0, MAX_SAFE_INTEGER) then
            return invalid('ACCOUNT_REVISION_INVALID', {
                field = 'currency_balance_rows[' .. index .. '].account_revision',
            })
        end
        accounts[row.currency_id] = {
            balance = row.balance,
            reserved = 0,
            account_revision = row.account_revision,
        }
        previous_id = row.currency_id
    end

    return result_ok({
        economy_revision = metadata.economy_revision,
        accounts = accounts,
    })
end

return EconomySaveCodec
