local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local CurrencyLedger = require 'wzx.domain.economy.currency_ledger'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'
local EconomySaveBridge = require 'wzx.application.use_cases.economy.economy_save_bridge'
local PreparedReward = require 'wzx.domain.economy.prepared_reward'
local Result = require 'wzx.domain.common.result'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'
local RuntimeId = require 'wzx.domain.common.runtime_id'

local EconomyService = {}
local canonical_derive = CanonicalReceiptHashV1.derive
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('economy service is read-only', 2)
end
Service.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.economy.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(EconomyErrorCodes.ECONOMY_ARGUMENT_INVALID, reason, details, false)
end

local function copy_costs(rows)
    local copied = {}
    local index
    for index = 1, #rows do
        copied[index] = {
            currency_id = rows[index].currency_id,
            amount = rows[index].amount,
        }
    end
    return copied
end

local function maybe_persist_save(self, input)
    local state = STATES[self]
    if state == nil or state.save_bridge == nil then
        return result_ok({ status = 'SKIPPED' })
    end
    local player_save_scope = raw_get(input, 'player_save_scope')
    if player_save_scope == nil then
        return result_ok({
            status = 'SKIPPED',
            reason = 'PLAYER_SAVE_SCOPE_MISSING',
        })
    end
    return state.save_bridge:persist_player_economy({
        player_save_scope = player_save_scope,
        player_ref = raw_get(input, 'player_ref') or player_save_scope,
        request_id = (raw_get(input, 'request_id') or 'request_economy')
            .. '_save',
        command_id = raw_get(input, 'command_id'),
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
end

function EconomyService.bind(options)
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
    end
    local currency_catalog = raw_get(options, 'currency_catalog')
    local reward_catalog = raw_get(options, 'reward_catalog')
    local store = raw_get(options, 'store')
    local save_bridge = raw_get(options, 'save_bridge')
    if not CurrencyCatalog.is_authority(currency_catalog) then
        return invalid('CURRENCY_CATALOG_REQUIRED', { field = 'currency_catalog' })
    end
    if not RewardCatalog.is_authority(reward_catalog) then
        return invalid('REWARD_CATALOG_REQUIRED', { field = 'reward_catalog' })
    end
    if type_value(store) ~= 'table'
        or type_value(store.get_ledger) ~= 'function'
        or type_value(store.replace_ledger) ~= 'function'
        or type_value(store.get_receipt) ~= 'function'
        or type_value(store.put_committed_receipt) ~= 'function'
    then
        return invalid('STORE_REQUIRED', { field = 'store' })
    end
    if save_bridge ~= nil and not EconomySaveBridge.is_authority(save_bridge) then
        return invalid('SAVE_BRIDGE_AUTHORITY_REQUIRED', {
            field = 'save_bridge',
        })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        currency_catalog = currency_catalog,
        reward_catalog = reward_catalog,
        store = store,
        save_bridge = save_bridge,
    }
    return result_ok(view)
end

function Service:get_balance(currency_id)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    local definition = state.currency_catalog:require(currency_id)
    if not definition.ok then
        return definition
    end
    local ledger = state.store:get_ledger()
    if not ledger.ok then
        return ledger
    end
    local account = CurrencyLedger.get_account(ledger.value, currency_id)
    if not account.ok then
        return account
    end
    return result_ok({
        currency_id = currency_id,
        balance = account.value.balance,
        reserved = account.value.reserved,
        available = account.value.available,
        balance_cap = definition.value.balance_cap,
        account_revision = account.value.account_revision,
        economy_revision = ledger.value.economy_revision,
        category = definition.value.category,
    })
end

function Service:prepare_reward(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local reward_id = raw_get(input, 'reward_id')
    local source_type = raw_get(input, 'source_type')
    local source_ref = raw_get(input, 'source_ref')
    local source_occurrence_id = raw_get(input, 'source_occurrence_id')
    local overflow_policy = raw_get(input, 'overflow_policy')

    local checked_reward = validate_content(reward_id, 'reward_', 'reward_id')
    if not checked_reward.ok then
        return invalid('REWARD_ID_INVALID', { field = 'reward_id' })
    end

    local expanded = state.reward_catalog:expand_leaves(reward_id)
    if not expanded.ok then
        return expanded
    end

    local bundle = state.reward_catalog:get(reward_id)
    if not bundle.ok then
        return bundle
    end
    if overflow_policy == nil then
        overflow_policy = bundle.value.overflow_policy or 'REJECT'
    end

    local leaves = expanded.value
    local index
    for index = 1, #leaves do
        local leaf = leaves[index]
        if leaf.entry_type == 'CURRENCY' then
            local definition = state.currency_catalog:require(leaf.target_id)
            if not definition.ok then
                return definition
            end
        end
    end

    local prepared = PreparedReward.build({
        source_type = source_type,
        source_ref = source_ref or reward_id,
        source_occurrence_id = source_occurrence_id,
        config_version = 1,
        overflow_policy = overflow_policy,
        entries = leaves,
    })
    if not prepared.ok then
        return prepared
    end
    return result_ok(prepared.value)
end

local function build_result_hash(prepared, economy_revision_after, costs)
    costs = costs or {}
    local cost_digest = canonical_derive('economy_cost_summary', {
        { name = 'cost_count', type = 'INTEGER' },
        { name = 'first_currency_id', type = 'STRING' },
        { name = 'first_amount', type = 'INTEGER' },
    }, {
        cost_count = #costs,
        first_currency_id = costs[1] and costs[1].currency_id or '',
        first_amount = costs[1] and costs[1].amount or 0,
    })
    if not cost_digest.ok then
        return cost_digest
    end
    return canonical_derive('economy_grant_result', {
        { name = 'prepared_id', type = 'STRING' },
        { name = 'content_hash', type = 'STRING' },
        { name = 'economy_revision_after', type = 'INTEGER' },
        { name = 'cost_digest', type = 'STRING' },
    }, {
        prepared_id = prepared.prepared_id,
        content_hash = prepared.content_hash,
        economy_revision_after = economy_revision_after,
        cost_digest = cost_digest.value.digest,
    })
end

function Service:grant_prepared_reward(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local prepared = raw_get(input, 'prepared')
    local receipt_id = raw_get(input, 'receipt_id')
    local purpose_type = raw_get(input, 'purpose_type') or 'REWARD_GRANT'
    local purpose_ref = raw_get(input, 'purpose_ref')

    local checked_receipt = validate_derived(receipt_id, 'receipt_id')
    if not checked_receipt.ok then
        return invalid('RECEIPT_ID_INVALID', { field = 'receipt_id' })
    end
    if purpose_ref == nil and prepared ~= nil then
        purpose_ref = prepared.source_ref
    end

    local verified = PreparedReward.verify_content_hash(prepared)
    if not verified.ok then
        return verified
    end
    prepared = verified.value

    local request = PreparedReward.derive_request_hash(
        prepared,
        purpose_type,
        purpose_ref
    )
    if not request.ok then
        return request
    end
    local request_hash = request.value.digest

    local existing_receipt = state.store:get_receipt(receipt_id)
    if not existing_receipt.ok then
        return existing_receipt
    end
    if existing_receipt.value ~= nil then
        if existing_receipt.value.request_hash ~= request_hash then
            return fail(
                EconomyErrorCodes.ECONOMY_RECEIPT_CONFLICT,
                'RECEIPT_PAYLOAD_MISMATCH',
                {
                    receipt_id = receipt_id,
                    expected_request_hash = existing_receipt.value.request_hash,
                    actual_request_hash = request_hash,
                },
                false
            )
        end
        local save = maybe_persist_save(self, input)
        if not save.ok then
            return save
        end
        return result_ok({
            status = 'COMMITTED',
            already_committed = true,
            receipt_id = receipt_id,
            request_hash = existing_receipt.value.request_hash,
            result_hash = existing_receipt.value.result_hash,
            economy_revision = existing_receipt.value.economy_revision_after,
            source_occurrence_id = existing_receipt.value.source_occurrence_id,
            save = save.value,
        })
    end

    if type_value(state.store.get_source_occurrence) == 'function' then
        local existing_source = state.store:get_source_occurrence(
            prepared.source_occurrence_id
        )
        if not existing_source.ok then
            return existing_source
        end
        if existing_source.value ~= nil then
            if existing_source.value.receipt_id ~= receipt_id then
                return fail(
                    EconomyErrorCodes.ECONOMY_SOURCE_ALREADY_GRANTED,
                    'SOURCE_OCCURRENCE_ALREADY_COMMITTED',
                    {
                        source_occurrence_id = prepared.source_occurrence_id,
                        existing_receipt_id = existing_source.value.receipt_id,
                    },
                    false
                )
            end
        end
    end

    local rewards = PreparedReward.to_currency_rewards(prepared)
    if not rewards.ok then
        return rewards
    end

    local ledger = state.store:get_ledger()
    if not ledger.ok then
        return ledger
    end
    local plan = CurrencyLedger.plan_transaction(
        ledger.value,
        {},
        rewards.value,
        state.currency_catalog
    )
    if not plan.ok then
        return plan
    end
    local applied = CurrencyLedger.apply_plan(ledger.value, plan.value)
    if not applied.ok then
        return applied
    end

    local result_hash = build_result_hash(prepared, applied.value.economy_revision, {})
    if not result_hash.ok then
        return result_hash
    end

    local replaced = state.store:replace_ledger(applied.value)
    if not replaced.ok then
        return replaced
    end

    local stored = state.store:put_committed_receipt({
        receipt_id = receipt_id,
        source_occurrence_id = prepared.source_occurrence_id,
        request_hash = request_hash,
        result_hash = result_hash.value.digest,
        status = 'COMMITTED',
        purpose_type = purpose_type,
        purpose_ref = purpose_ref,
        economy_revision_after = applied.value.economy_revision,
    })
    if not stored.ok then
        return stored
    end
    if stored.value.already_present then
        -- Concurrent same-key race in fake store: treat as idempotent if hash matches.
        if stored.value.receipt ~= nil
            and stored.value.receipt.request_hash == request_hash
        then
            local save = maybe_persist_save(self, input)
            if not save.ok then
                return save
            end
            return result_ok({
                status = 'COMMITTED',
                already_committed = true,
                receipt_id = receipt_id,
                request_hash = stored.value.receipt.request_hash,
                result_hash = stored.value.receipt.result_hash,
                economy_revision = stored.value.receipt.economy_revision_after,
                source_occurrence_id = stored.value.receipt.source_occurrence_id,
                save = save.value,
            })
        end
        return fail(
            EconomyErrorCodes.ECONOMY_RECEIPT_CONFLICT,
            'RECEIPT_STORE_CONFLICT',
            { receipt_id = receipt_id },
            false
        )
    end

    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        already_committed = false,
        receipt_id = receipt_id,
        request_hash = request_hash,
        result_hash = result_hash.value.digest,
        economy_revision = applied.value.economy_revision,
        source_occurrence_id = prepared.source_occurrence_id,
        rewards = rewards.value,
        save = save.value,
    })
end

function Service:quote(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local ledger = state.store:get_ledger()
    if not ledger.ok then
        return ledger
    end
    local plan = CurrencyLedger.plan_transaction(
        ledger.value,
        raw_get(input, 'costs') or {},
        raw_get(input, 'rewards') or {},
        state.currency_catalog
    )
    if not plan.ok then
        return plan
    end
    local quote_hash = canonical_derive('economy_quote', {
        { name = 'economy_revision', type = 'INTEGER' },
        { name = 'cost_count', type = 'INTEGER' },
        { name = 'reward_count', type = 'INTEGER' },
        { name = 'purpose_type', type = 'STRING' },
        { name = 'purpose_ref', type = 'STRING' },
    }, {
        economy_revision = plan.value.economy_revision,
        cost_count = #plan.value.costs,
        reward_count = #plan.value.rewards,
        purpose_type = raw_get(input, 'purpose_type') or 'EXCHANGE',
        purpose_ref = raw_get(input, 'purpose_ref') or 'none',
    })
    if not quote_hash.ok then
        return quote_hash
    end
    return result_ok({
        economy_revision = plan.value.economy_revision,
        costs = plan.value.costs,
        rewards = plan.value.rewards,
        quote_token = quote_hash.value.digest,
    })
end

function Service:reserve(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    if type_value(state.store.create_reservation) ~= 'function'
        or type_value(state.store.get_reservation) ~= 'function'
    then
        return invalid('RESERVATION_STORE_REQUIRED')
    end

    local quote = self:quote(input)
    if not quote.ok then
        return quote
    end
    if raw_get(input, 'quote_token') ~= nil
        and raw_get(input, 'quote_token') ~= quote.value.quote_token
    then
        return fail(
            EconomyErrorCodes.ECONOMY_PREPARED_STALE,
            'PREVIEW_STALE',
            {
                expected = input.quote_token,
                actual = quote.value.quote_token,
            },
            false
        )
    end

    local ledger = state.store:get_ledger()
    if not ledger.ok then
        return ledger
    end
    local reserved = CurrencyLedger.reserve_costs(
        ledger.value,
        quote.value.costs,
        state.currency_catalog
    )
    if not reserved.ok then
        return reserved
    end
    local replaced = state.store:replace_ledger(reserved.value)
    if not replaced.ok then
        return replaced
    end

    local request_hash = canonical_derive('economy_reserve_request', {
        { name = 'quote_token', type = 'STRING' },
        { name = 'purpose_type', type = 'STRING' },
        { name = 'purpose_ref', type = 'STRING' },
    }, {
        quote_token = quote.value.quote_token,
        purpose_type = raw_get(input, 'purpose_type') or 'EXCHANGE',
        purpose_ref = raw_get(input, 'purpose_ref') or 'none',
    })
    if not request_hash.ok then
        return request_hash
    end

    local created = state.store:create_reservation({
        costs = copy_costs(quote.value.costs),
        rewards = copy_costs(quote.value.rewards),
        purpose_type = raw_get(input, 'purpose_type') or 'EXCHANGE',
        purpose_ref = raw_get(input, 'purpose_ref') or 'none',
        request_hash = request_hash.value.digest,
        economy_revision = quote.value.economy_revision,
    })
    if not created.ok then
        return created
    end
    return result_ok({
        reservation_id = created.value.reservation_id,
        status = 'RESERVED',
        quote_token = quote.value.quote_token,
        costs = quote.value.costs,
        rewards = quote.value.rewards,
        economy_revision = quote.value.economy_revision,
    })
end

function Service:commit_reservation(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local reservation_id = raw_get(input, 'reservation_id')
    local receipt_id = raw_get(input, 'receipt_id')
    if type_value(reservation_id) ~= 'string' or reservation_id == '' then
        return invalid('RESERVATION_ID_REQUIRED', { field = 'reservation_id' })
    end
    local checked_receipt = validate_derived(receipt_id, 'receipt_id')
    if not checked_receipt.ok then
        return invalid('RECEIPT_ID_INVALID', { field = 'receipt_id' })
    end
    if type_value(state.store.get_reservation) ~= 'function'
        or type_value(state.store.update_reservation_status) ~= 'function'
    then
        return invalid('RESERVATION_STORE_REQUIRED')
    end

    local reservation = state.store:get_reservation(reservation_id)
    if not reservation.ok then
        return reservation
    end
    if reservation.value == nil then
        return fail(
            EconomyErrorCodes.ECONOMY_RESERVATION_NOT_FOUND,
            'RESERVATION_MISSING',
            { reservation_id = reservation_id },
            false
        )
    end
    if reservation.value.status == 'COMMITTED' then
        return fail(
            EconomyErrorCodes.ECONOMY_TRANSACTION_ALREADY_COMMITTED,
            'RESERVATION_ALREADY_COMMITTED',
            { reservation_id = reservation_id },
            false
        )
    end
    if reservation.value.status ~= 'RESERVED' then
        return fail(
            EconomyErrorCodes.ECONOMY_TRANSACTION_INVALID,
            'RESERVATION_NOT_ACTIVE',
            {
                reservation_id = reservation_id,
                status = reservation.value.status,
            },
            false
        )
    end

    local existing_receipt = state.store:get_receipt(receipt_id)
    if not existing_receipt.ok then
        return existing_receipt
    end
    if existing_receipt.value ~= nil then
        if existing_receipt.value.request_hash ~= reservation.value.request_hash then
            return fail(
                EconomyErrorCodes.ECONOMY_RECEIPT_CONFLICT,
                'RECEIPT_PAYLOAD_MISMATCH',
                { receipt_id = receipt_id },
                false
            )
        end
        return result_ok({
            status = 'COMMITTED',
            already_committed = true,
            receipt_id = receipt_id,
            reservation_id = reservation_id,
            result_hash = existing_receipt.value.result_hash,
            economy_revision = existing_receipt.value.economy_revision_after,
        })
    end

    local ledger = state.store:get_ledger()
    if not ledger.ok then
        return ledger
    end
    local committed = CurrencyLedger.commit_reserved(
        ledger.value,
        reservation.value.costs,
        reservation.value.rewards,
        state.currency_catalog
    )
    if not committed.ok then
        return committed
    end
    local replaced = state.store:replace_ledger(committed.value)
    if not replaced.ok then
        return replaced
    end

    local result_hash = canonical_derive('economy_reservation_result', {
        { name = 'reservation_id', type = 'STRING' },
        { name = 'request_hash', type = 'STRING' },
        { name = 'economy_revision_after', type = 'INTEGER' },
    }, {
        reservation_id = reservation_id,
        request_hash = reservation.value.request_hash,
        economy_revision_after = committed.value.economy_revision,
    })
    if not result_hash.ok then
        return result_hash
    end

    local source_occurrence_id = raw_get(input, 'source_occurrence_id')
    if source_occurrence_id == nil then
        source_occurrence_id = reservation_id
    end
    local checked_source = validate_component(source_occurrence_id, 'source_occurrence_id')
    if not checked_source.ok then
        -- reservation_id uses reservation_N which is valid component.
        return invalid('SOURCE_OCCURRENCE_ID_INVALID', {
            field = 'source_occurrence_id',
        })
    end

    local stored = state.store:put_committed_receipt({
        receipt_id = receipt_id,
        source_occurrence_id = source_occurrence_id,
        request_hash = reservation.value.request_hash,
        result_hash = result_hash.value.digest,
        status = 'COMMITTED',
        purpose_type = reservation.value.purpose_type,
        purpose_ref = reservation.value.purpose_ref,
        economy_revision_after = committed.value.economy_revision,
    })
    if not stored.ok then
        return stored
    end

    state.store:update_reservation_status(reservation_id, 'COMMITTED')
    local save = maybe_persist_save(self, input)
    if not save.ok then
        return save
    end
    return result_ok({
        status = 'COMMITTED',
        already_committed = false,
        receipt_id = receipt_id,
        reservation_id = reservation_id,
        result_hash = result_hash.value.digest,
        economy_revision = committed.value.economy_revision,
        costs = committed.value.costs,
        rewards = committed.value.rewards,
        save = save.value,
    })
end

function Service:release_reservation(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local reservation_id = raw_get(input, 'reservation_id')
    if type_value(reservation_id) ~= 'string' or reservation_id == '' then
        return invalid('RESERVATION_ID_REQUIRED', { field = 'reservation_id' })
    end
    if type_value(state.store.get_reservation) ~= 'function'
        or type_value(state.store.update_reservation_status) ~= 'function'
    then
        return invalid('RESERVATION_STORE_REQUIRED')
    end

    local reservation = state.store:get_reservation(reservation_id)
    if not reservation.ok then
        return reservation
    end
    if reservation.value == nil then
        return fail(
            EconomyErrorCodes.ECONOMY_RESERVATION_NOT_FOUND,
            'RESERVATION_MISSING',
            { reservation_id = reservation_id },
            false
        )
    end
    if reservation.value.status == 'COMMITTED' then
        return fail(
            EconomyErrorCodes.ECONOMY_TRANSACTION_ALREADY_COMMITTED,
            'RESERVATION_ALREADY_COMMITTED',
            { reservation_id = reservation_id },
            false
        )
    end
    if reservation.value.status == 'RELEASED' then
        return result_ok({
            reservation_id = reservation_id,
            status = 'RELEASED',
            already_released = true,
        })
    end

    local ledger = state.store:get_ledger()
    if not ledger.ok then
        return ledger
    end
    local released = CurrencyLedger.release_costs(ledger.value, reservation.value.costs)
    if not released.ok then
        return released
    end
    local replaced = state.store:replace_ledger(released.value)
    if not replaced.ok then
        return replaced
    end
    state.store:update_reservation_status(reservation_id, 'RELEASED')
    return result_ok({
        reservation_id = reservation_id,
        status = 'RELEASED',
        already_released = false,
    })
end

return EconomyService
