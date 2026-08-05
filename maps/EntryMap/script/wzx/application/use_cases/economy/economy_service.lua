local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local CurrencyLedger = require 'wzx.domain.economy.currency_ledger'
local EconomyErrorCodes = require 'wzx.domain.economy.error_codes'
local EconomySaveBridge = require 'wzx.application.use_cases.economy.economy_save_bridge'
local InventoryService = require 'wzx.application.use_cases.inventory.inventory_service'
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
local ZERO_DIGEST = string.rep('0', 64)

-- Minimal V1 spend purpose whitelist. Callers outside this set fail closed.
local SPEND_PURPOSE_WHITELIST = {
    SHOP_PURCHASE = true,
    CRAFT_COST = true,
    EQUIP_ENHANCE = true,
    MARTIAL_UPGRADE = true,
    FACTION_SPEND = true,
    EXCHANGE = true,
    QUEST_COST = true,
    COMPANION_GIFT = true,
}

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
    if state == nil then
        return result_ok({ status = 'SKIPPED' })
    end
    -- Parent sagas (e.g. quest completion multi-slot checkpoint) defer cloud
    -- writes by setting skip_save=true after in-memory owner mutations.
    if type_value(input) == 'table' and raw_get(input, 'skip_save') == true then
        return result_ok({
            status = 'SKIPPED',
            reason = 'SKIP_SAVE',
        })
    end
    local player_save_scope = raw_get(input, 'player_save_scope')
    if player_save_scope == nil then
        return result_ok({
            status = 'SKIPPED',
            reason = 'PLAYER_SAVE_SCOPE_MISSING',
        })
    end

    local economy_save = { status = 'SKIPPED' }
    if state.save_bridge ~= nil then
        local saved = state.save_bridge:persist_player_economy({
            player_save_scope = player_save_scope,
            player_ref = raw_get(input, 'player_ref') or player_save_scope,
            request_id = (raw_get(input, 'request_id') or 'request_economy')
                .. '_save',
            command_id = raw_get(input, 'command_id'),
            save_seed = raw_get(input, 'save_seed'),
            content_version = raw_get(input, 'content_version'),
        })
        if not saved.ok then
            return saved
        end
        economy_save = saved.value
    end

    -- Inventory mutations persist through InventoryService.grant_items when a
    -- save bridge is bound there; economy only writes currency + receipt sections.
    return result_ok({
        status = economy_save.status or 'SKIPPED',
        economy = economy_save,
        checkpoint_id = economy_save.checkpoint_id,
        created_save = economy_save.created_save,
        slot4_revision = economy_save.slot4_revision,
        slot5_revision = economy_save.slot5_revision,
        slot1_revision = economy_save.slot1_revision,
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
    local inventory_service = raw_get(options, 'inventory_service')
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
    if inventory_service ~= nil
        and not InventoryService.is_authority(inventory_service)
    then
        return invalid('INVENTORY_SERVICE_AUTHORITY_REQUIRED', {
            field = 'inventory_service',
        })
    end

    local view = set_metatable({}, Service)
    STATES[view] = {
        currency_catalog = currency_catalog,
        reward_catalog = reward_catalog,
        store = store,
        save_bridge = save_bridge,
        inventory_service = inventory_service,
    }
    return result_ok(view)
end

function EconomyService.is_authority(value)
    return type_value(value) == 'table' and STATES[value] ~= nil
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
        elseif leaf.entry_type == 'ITEM' then
            if state.inventory_service == nil then
                return fail(
                    EconomyErrorCodes.ECONOMY_ENTRY_UNSUPPORTED,
                    'ITEM_REQUIRES_INVENTORY_SERVICE',
                    { target_id = leaf.target_id },
                    false
                )
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

local function build_result_hash(
    prepared,
    economy_revision_after,
    inventory_revision_after,
    costs
)
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
        { name = 'inventory_revision_after', type = 'INTEGER' },
        { name = 'cost_digest', type = 'STRING' },
    }, {
        prepared_id = prepared.prepared_id,
        content_hash = prepared.content_hash,
        economy_revision_after = economy_revision_after,
        inventory_revision_after = inventory_revision_after or 0,
        cost_digest = cost_digest.value.digest,
    })
end

local create_pending_reward

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
    local item_grants = PreparedReward.to_item_grants(prepared)
    if not item_grants.ok then
        return item_grants
    end
    if #item_grants.value > 0 and state.inventory_service == nil then
        return fail(
            EconomyErrorCodes.ECONOMY_ENTRY_UNSUPPORTED,
            'ITEM_REQUIRES_INVENTORY_SERVICE',
            { item_count = #item_grants.value },
            false
        )
    end

    local overflow_policy = prepared.overflow_policy or 'REJECT'
    local defer_pending = overflow_policy == 'PENDING'

    -- Plan both owners before mutating either store.
    local inventory_plan = nil
    if #item_grants.value > 0 then
        local planned_items = state.inventory_service:plan_grant({
            items = item_grants.value,
            overflow_policy = 'REJECT',
        })
        if not planned_items.ok then
            if defer_pending
                and planned_items.error
                and (
                    planned_items.error.code == 'INVENTORY_FULL'
                    or planned_items.error.code == 'INVENTORY_ITEM_CAP_REACHED'
                )
            then
                return create_pending_reward(
                    self,
                    input,
                    prepared,
                    receipt_id,
                    request_hash,
                    purpose_type,
                    purpose_ref,
                    planned_items.error.code
                )
            end
            return planned_items
        end
        inventory_plan = planned_items.value
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
        if defer_pending
            and plan.error
            and plan.error.code == EconomyErrorCodes.ECONOMY_CURRENCY_CAP_REACHED
        then
            return create_pending_reward(
                self,
                input,
                prepared,
                receipt_id,
                request_hash,
                purpose_type,
                purpose_ref,
                plan.error.code
            )
        end
        return plan
    end

    local applied = CurrencyLedger.apply_plan(ledger.value, plan.value)
    if not applied.ok then
        return applied
    end
    local replaced = state.store:replace_ledger(applied.value)
    if not replaced.ok then
        return replaced
    end

    local inventory_result = nil
    local inventory_revision_after = 0
    if #item_grants.value > 0 then
        local granted_items = state.inventory_service:grant_items({
            items = item_grants.value,
            overflow_policy = 'REJECT',
            player_save_scope = raw_get(input, 'player_save_scope'),
            player_ref = raw_get(input, 'player_ref'),
            request_id = (raw_get(input, 'request_id') or 'request_economy')
                .. '_inventory',
            save_seed = raw_get(input, 'save_seed'),
            content_version = raw_get(input, 'content_version'),
            skip_save = raw_get(input, 'skip_save') == true,
        })
        if not granted_items.ok then
            return granted_items
        end
        inventory_result = granted_items.value
        inventory_revision_after = granted_items.value.inventory_revision
    end

    local result_hash = build_result_hash(
        prepared,
        applied.value.economy_revision,
        inventory_revision_after,
        {}
    )
    if not result_hash.ok then
        return result_hash
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
        inventory_revision = inventory_revision_after,
        source_occurrence_id = prepared.source_occurrence_id,
        rewards = rewards.value,
        item_grants = item_grants.value,
        inventory = inventory_result,
        inventory_plan = inventory_plan,
        save = save.value,
    })
end

create_pending_reward = function(
    self,
    input,
    prepared,
    receipt_id,
    request_hash,
    purpose_type,
    purpose_ref,
    reason
)
    local state = STATES[self]
    if type_value(state.store.put_pending_reward) ~= 'function'
        or type_value(state.store.get_pending_reward) ~= 'function'
    then
        return fail(
            EconomyErrorCodes.ECONOMY_ENTRY_UNSUPPORTED,
            'PENDING_STORE_REQUIRED',
            { reason = reason },
            false
        )
    end

    local pending_id_derived = canonical_derive('economy_pending_reward', {
        { name = 'receipt_id', type = 'STRING' },
        { name = 'request_hash', type = 'STRING' },
    }, {
        receipt_id = receipt_id,
        request_hash = request_hash,
    })
    if not pending_id_derived.ok then
        return pending_id_derived
    end
    -- pending_id must be a component (max 64); use digest.
    local pending_id = pending_id_derived.value.digest

    local existing = state.store:get_pending_reward(pending_id)
    if not existing.ok then
        return existing
    end
    if existing.value ~= nil then
        if existing.value.request_hash ~= request_hash then
            return fail(
                EconomyErrorCodes.ECONOMY_RECEIPT_CONFLICT,
                'PENDING_REQUEST_MISMATCH',
                { pending_id = pending_id },
                false
            )
        end
        return result_ok({
            status = 'PENDING',
            already_pending = true,
            pending_id = pending_id,
            receipt_id = receipt_id,
            request_hash = request_hash,
            reason = existing.value.reason,
            source_occurrence_id = prepared.source_occurrence_id,
        })
    end

    local entries = {}
    local index
    for index = 1, #prepared.entries do
        local entry = prepared.entries[index]
        entries[index] = {
            entry_type = entry.entry_type,
            target_id = entry.target_id,
            quantity = entry.quantity,
            target_character_id = entry.target_character_id,
            entry_order = entry.entry_order,
        }
    end

    local stored = state.store:put_pending_reward({
        pending_id = pending_id,
        receipt_id = receipt_id,
        request_hash = request_hash,
        purpose_type = purpose_type,
        purpose_ref = purpose_ref,
        source_occurrence_id = prepared.source_occurrence_id,
        reason = reason,
        status = 'AVAILABLE',
        prepared_id = prepared.prepared_id,
        content_hash = prepared.content_hash,
        source_type = prepared.source_type,
        source_ref = prepared.source_ref,
        config_version = prepared.config_version,
        overflow_policy = prepared.overflow_policy or 'PENDING',
        seed_hash = prepared.seed_hash,
        entries = entries,
    })
    if not stored.ok then
        return stored
    end

    if type_value(state.store.put_source_occurrence) == 'function' then
        local marked = state.store:put_source_occurrence({
            source_occurrence_id = prepared.source_occurrence_id,
            receipt_id = receipt_id,
            status = 'PENDING',
        })
        if not marked.ok then
            return marked
        end
    end

    return result_ok({
        status = 'PENDING',
        already_pending = false,
        pending_id = pending_id,
        receipt_id = receipt_id,
        request_hash = request_hash,
        reason = reason,
        source_occurrence_id = prepared.source_occurrence_id,
    })
end

function Service:claim_pending_reward(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    if type_value(state.store.get_pending_reward) ~= 'function'
        or type_value(state.store.update_pending_reward_status) ~= 'function'
    then
        return invalid('PENDING_STORE_REQUIRED')
    end

    local pending_id = raw_get(input, 'pending_id')
    if type_value(pending_id) ~= 'string'
        or #pending_id ~= 64
        or string.match(pending_id, '^[a-f0-9]+$') == nil
    then
        return invalid('PENDING_ID_INVALID', { field = 'pending_id' })
    end

    local pending = state.store:get_pending_reward(pending_id)
    if not pending.ok then
        return pending
    end
    if pending.value == nil then
        return fail(
            EconomyErrorCodes.ECONOMY_PENDING_REWARD_NOT_FOUND,
            'PENDING_MISSING',
            { pending_id = pending_id },
            false
        )
    end
    if pending.value.status == 'CLAIMED' then
        return fail(
            EconomyErrorCodes.ECONOMY_PENDING_REWARD_CLAIMED,
            'PENDING_ALREADY_CLAIMED',
            { pending_id = pending_id },
            false
        )
    end

    -- Integrity check against the original deferred prepared content.
    local original_overflow = pending.value.overflow_policy
    if original_overflow == 'REJECT' then
        original_overflow = 'PENDING'
    end
    local integrity = PreparedReward.build({
        source_type = pending.value.source_type,
        source_ref = pending.value.source_ref,
        source_occurrence_id = pending.value.source_occurrence_id,
        config_version = pending.value.config_version,
        overflow_policy = original_overflow,
        seed_hash = pending.value.seed_hash,
        entries = pending.value.entries,
    })
    if not integrity.ok then
        return integrity
    end
    if integrity.value.content_hash ~= pending.value.content_hash then
        return fail(
            EconomyErrorCodes.ECONOMY_PREPARED_STALE,
            'PENDING_CONTENT_HASH_MISMATCH',
            {
                pending_id = pending_id,
                expected = pending.value.content_hash,
                actual = integrity.value.content_hash,
            },
            false
        )
    end

    -- Claim always attempts hard delivery with REJECT overflow.
    local claim_prepared = PreparedReward.build({
        source_type = pending.value.source_type,
        source_ref = pending.value.source_ref,
        source_occurrence_id = pending.value.source_occurrence_id,
        config_version = pending.value.config_version,
        overflow_policy = 'REJECT',
        seed_hash = pending.value.seed_hash,
        entries = pending.value.entries,
    })
    if not claim_prepared.ok then
        return claim_prepared
    end

    local granted = self:grant_prepared_reward({
        prepared = claim_prepared.value,
        receipt_id = pending.value.receipt_id,
        purpose_type = pending.value.purpose_type,
        purpose_ref = pending.value.purpose_ref,
        player_save_scope = raw_get(input, 'player_save_scope'),
        player_ref = raw_get(input, 'player_ref'),
        request_id = raw_get(input, 'request_id') or 'request_claim_pending',
        save_seed = raw_get(input, 'save_seed'),
        content_version = raw_get(input, 'content_version'),
    })
    if not granted.ok then
        return granted
    end
    if granted.value.status ~= 'COMMITTED' then
        return fail(
            EconomyErrorCodes.ECONOMY_TRANSACTION_INVALID,
            'CLAIM_DID_NOT_COMMIT',
            {
                pending_id = pending_id,
                status = granted.value.status,
            },
            false
        )
    end

    state.store:update_pending_reward_status(pending_id, 'CLAIMED')
    return result_ok({
        status = 'COMMITTED',
        pending_id = pending_id,
        receipt_id = pending.value.receipt_id,
        grant = granted.value,
        already_committed = granted.value.already_committed == true,
    })
end

local function derive_costs_digest(costs)
    local digest = ZERO_DIGEST
    local index
    for index = 1, #costs do
        local row = costs[index]
        local chained = canonical_derive('economy_cost_row', {
            { name = 'previous_digest', type = 'STRING' },
            { name = 'ordinal', type = 'INTEGER' },
            { name = 'currency_id', type = 'STRING' },
            { name = 'amount', type = 'INTEGER' },
        }, {
            previous_digest = digest,
            ordinal = index,
            currency_id = row.currency_id,
            amount = row.amount,
        })
        if not chained.ok then
            return chained
        end
        digest = chained.value.digest
    end
    return result_ok(digest)
end

local function validate_spend_purpose(purpose_type, purpose_ref)
    if type_value(purpose_type) ~= 'string'
        or purpose_type == ''
        or string.match(purpose_type, '^[A-Z][A-Z0-9_]*$') == nil
    then
        return invalid('PURPOSE_TYPE_INVALID', { field = 'purpose_type' })
    end
    if SPEND_PURPOSE_WHITELIST[purpose_type] ~= true then
        return fail(
            EconomyErrorCodes.ECONOMY_ARGUMENT_INVALID,
            'PURPOSE_TYPE_NOT_WHITELISTED',
            { purpose_type = purpose_type },
            false
        )
    end
    if type_value(purpose_ref) ~= 'string'
        or purpose_ref == ''
        or #purpose_ref > 96
    then
        return invalid('PURPOSE_REF_INVALID', { field = 'purpose_ref' })
    end
    return result_ok({
        purpose_type = purpose_type,
        purpose_ref = purpose_ref,
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

-- One-shot currency spend with receipt/source idempotency.
-- Item costs remain system 09; this slice only debits currency balances.
-- Receipt replay must not re-check live balances (already-spent funds).
function Service:spend_resources(input)
    local state = STATES[self]
    if state == nil then
        return invalid('SERVICE_AUTHORITY_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local receipt_id = raw_get(input, 'receipt_id')
    local checked_receipt = validate_derived(receipt_id, 'receipt_id')
    if not checked_receipt.ok then
        return invalid('RECEIPT_ID_INVALID', { field = 'receipt_id' })
    end

    local purpose = validate_spend_purpose(
        raw_get(input, 'purpose_type'),
        raw_get(input, 'purpose_ref')
    )
    if not purpose.ok then
        return purpose
    end

    local source_occurrence_id = raw_get(input, 'source_occurrence_id')
    local checked_source = validate_component(
        source_occurrence_id,
        'source_occurrence_id'
    )
    if not checked_source.ok then
        return invalid('SOURCE_OCCURRENCE_ID_INVALID', {
            field = 'source_occurrence_id',
        })
    end

    local costs_input = raw_get(input, 'costs')
    if type_value(costs_input) ~= 'table' or get_metatable(costs_input) ~= nil then
        return invalid('COSTS_TABLE_REQUIRED', { field = 'costs' })
    end

    local normalized_costs = CurrencyLedger.normalize_deltas(costs_input, 'costs')
    if not normalized_costs.ok then
        return normalized_costs
    end
    if #normalized_costs.value == 0 then
        return invalid('COSTS_EMPTY', { field = 'costs' })
    end

    local cost_index
    for cost_index = 1, #normalized_costs.value do
        local definition = state.currency_catalog:require(
            normalized_costs.value[cost_index].currency_id
        )
        if not definition.ok then
            return definition
        end
    end

    local costs_digest = derive_costs_digest(normalized_costs.value)
    if not costs_digest.ok then
        return costs_digest
    end
    local request = canonical_derive('economy_spend_request', {
        { name = 'purpose_type', type = 'STRING' },
        { name = 'purpose_ref', type = 'STRING' },
        { name = 'source_occurrence_id', type = 'STRING' },
        { name = 'cost_count', type = 'INTEGER' },
        { name = 'costs_digest', type = 'STRING' },
    }, {
        purpose_type = purpose.value.purpose_type,
        purpose_ref = purpose.value.purpose_ref,
        source_occurrence_id = checked_source.value,
        cost_count = #normalized_costs.value,
        costs_digest = costs_digest.value,
    })
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
            costs = copy_costs(normalized_costs.value),
            save = save.value,
        })
    end

    if type_value(state.store.get_source_occurrence) == 'function' then
        local existing_source = state.store:get_source_occurrence(
            checked_source.value
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
                        source_occurrence_id = checked_source.value,
                        existing_receipt_id = existing_source.value.receipt_id,
                    },
                    false
                )
            end
        end
    end

    local ledger = state.store:get_ledger()
    if not ledger.ok then
        return ledger
    end

    if raw_get(input, 'expected_economy_revision') ~= nil
        and raw_get(input, 'expected_economy_revision') ~= ledger.value.economy_revision
    then
        return fail(
            EconomyErrorCodes.ECONOMY_TRANSACTION_INVALID,
            'ECONOMY_REVISION_MISMATCH',
            {
                expected = raw_get(input, 'expected_economy_revision'),
                actual = ledger.value.economy_revision,
            },
            false
        )
    end

    if raw_get(input, 'quote_token') ~= nil then
        local quoted = self:quote({
            costs = normalized_costs.value,
            rewards = {},
            purpose_type = purpose.value.purpose_type,
            purpose_ref = purpose.value.purpose_ref,
        })
        if not quoted.ok then
            return quoted
        end
        if quoted.value.quote_token ~= raw_get(input, 'quote_token') then
            return fail(
                EconomyErrorCodes.ECONOMY_PREPARED_STALE,
                'PREVIEW_STALE',
                {
                    expected = raw_get(input, 'quote_token'),
                    actual = quoted.value.quote_token,
                },
                false
            )
        end
    end

    local plan = CurrencyLedger.plan_transaction(
        ledger.value,
        normalized_costs.value,
        {},
        state.currency_catalog
    )
    if not plan.ok then
        return plan
    end

    local applied = CurrencyLedger.apply_plan(ledger.value, plan.value)
    if not applied.ok then
        return applied
    end

    local result_hash = canonical_derive('economy_spend_result', {
        { name = 'request_hash', type = 'STRING' },
        { name = 'economy_revision_after', type = 'INTEGER' },
        { name = 'costs_digest', type = 'STRING' },
    }, {
        request_hash = request_hash,
        economy_revision_after = applied.value.economy_revision,
        costs_digest = costs_digest.value,
    })
    if not result_hash.ok then
        return result_hash
    end

    local replaced = state.store:replace_ledger(applied.value)
    if not replaced.ok then
        return replaced
    end

    local stored = state.store:put_committed_receipt({
        receipt_id = receipt_id,
        source_occurrence_id = checked_source.value,
        request_hash = request_hash,
        result_hash = result_hash.value.digest,
        status = 'COMMITTED',
        purpose_type = purpose.value.purpose_type,
        purpose_ref = purpose.value.purpose_ref,
        economy_revision_after = applied.value.economy_revision,
    })
    if not stored.ok then
        return stored
    end
    if stored.value.already_present then
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
                costs = copy_costs(normalized_costs.value),
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
        source_occurrence_id = checked_source.value,
        costs = copy_costs(normalized_costs.value),
        save = save.value,
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
