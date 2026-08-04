local Harness = require 'wzx.tests.harness'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local EconomyReceiptCodec = require 'wzx.domain.economy.economy_receipt_codec'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local FakeEconomyStore = require 'wzx.adapters.fake.economy.fake_economy_store'
local FakeInventoryStore = require 'wzx.adapters.fake.inventory.fake_inventory_store'
local InventoryService = require 'wzx.application.use_cases.inventory.inventory_service'
local ItemCatalog = require 'wzx.config.schema.inventory.catalog'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'

local case = Harness.case
local assert = Harness.assert

local function leaf(order, entry_type, target_id, quantity)
    return {
        entry_order = order,
        entry_type = entry_type,
        target_id = target_id,
        quantity_min = quantity,
        quantity_max = quantity,
    }
end

local function build_currency_catalog()
    local built = CurrencyCatalog.build({
        currency_definitions = {
            {
                id = 'currency_copper',
                schema_version = 1,
                category = 'SOFT',
                balance_cap = 1000,
                source_policy_id = 'currpolicy_copper_source',
                sink_policy_id = 'currpolicy_copper_sink',
                name_key = 'currency.copper.name',
            },
            {
                id = 'currency_true_qi',
                schema_version = 1,
                category = 'PROGRESSION',
                balance_cap = 100,
                source_policy_id = 'currpolicy_true_qi_source',
                sink_policy_id = 'currpolicy_true_qi_sink',
                name_key = 'currency.true_qi.name',
            },
            {
                id = 'currency_premium_jade',
                schema_version = 1,
                category = 'PREMIUM_PLATFORM',
                balance_cap = 50,
                source_policy_id = 'currpolicy_premium_source',
                sink_policy_id = 'currpolicy_premium_sink',
                name_key = 'currency.premium_jade.name',
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function build_reward_catalog()
    local built = RewardCatalog.build({
        reward_bundles = {
            {
                id = 'reward_quest_copper',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 30),
                    leaf(2, 'CURRENCY', 'currency_true_qi', 2),
                },
            },
            {
                id = 'reward_with_item',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 5),
                    leaf(2, 'ITEM', 'item_healing_salve', 1),
                },
            },
            {
                id = 'reward_premium',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_premium_jade', 1),
                },
            },
            {
                id = 'reward_nested_currency',
                schema_version = 1,
                entries = {
                    {
                        entry_order = 1,
                        entry_type = 'REWARD_BUNDLE',
                        target_id = 'reward_nested_leaf',
                        quantity_min = 1,
                        quantity_max = 1,
                    },
                    leaf(2, 'CURRENCY', 'currency_copper', 10),
                },
            },
            {
                id = 'reward_nested_leaf',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 7),
                },
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function build_item_catalog()
    local built = ItemCatalog.build({
        item_definitions = {
            {
                id = 'item_healing_salve',
                schema_version = 1,
                category = 'CONSUMABLE',
                name_key = 'item.healing_salve.name',
                max_stack = 20,
                ownership_cap = 200,
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function bind_service(options)
    options = options or {}
    local store = FakeEconomyStore.new()
    assert.equal(store.ok, true)
    local inventory_service = nil
    if options.with_inventory == true then
        local inventory_store = FakeInventoryStore.new()
        assert.equal(inventory_store.ok, true)
        local bound_inventory = InventoryService.bind({
            item_catalog = build_item_catalog(),
            store = inventory_store.value,
        })
        assert.equal(bound_inventory.ok, true)
        inventory_service = bound_inventory.value
    end
    local service = EconomyService.bind({
        currency_catalog = build_currency_catalog(),
        reward_catalog = build_reward_catalog(),
        store = store.value,
        inventory_service = inventory_service,
    })
    assert.equal(service.ok, true)
    return service.value, store.value, inventory_service
end

local function make_receipt_id(label)
    local derived = CanonicalReceiptHashV1.derive('economy_test_receipt', {
        { name = 'label', type = 'STRING' },
    }, {
        label = label,
    })
    assert.equal(derived.ok, true)
    return derived.value.receipt_id
end

return {
    case('prepare and grant currency reward is idempotent by receipt and source', function()
        local service, store = bind_service()
        local prepared = service:prepare_reward({
            reward_id = 'reward_quest_copper',
            source_type = 'QUEST',
            source_ref = 'reward_quest_copper',
            source_occurrence_id = 'quest_run_001',
        })
        assert.equal(prepared.ok, true)
        assert.equal(#prepared.value.entries, 2)
        assert.equal(prepared.value.entries[1].target_id, 'currency_copper')
        assert.equal(prepared.value.entries[1].quantity, 30)

        local receipt_id = make_receipt_id('grant_once')
        local granted = service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = receipt_id,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_intro',
        })
        assert.equal(granted.ok, true)
        assert.equal(granted.value.status, 'COMMITTED')
        assert.equal(granted.value.already_committed, false)

        local copper = service:get_balance('currency_copper')
        assert.equal(copper.ok, true)
        assert.equal(copper.value.balance, 30)
        local qi = service:get_balance('currency_true_qi')
        assert.equal(qi.ok, true)
        assert.equal(qi.value.balance, 2)

        local replay = service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = receipt_id,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_intro',
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.already_committed, true)
        copper = service:get_balance('currency_copper')
        assert.equal(copper.value.balance, 30)

        local other_receipt = make_receipt_id('grant_other')
        local conflict = service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = other_receipt,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_intro',
        })
        assert.equal(conflict.ok, false)
        assert.equal(conflict.error.code, 'ECONOMY_SOURCE_ALREADY_GRANTED')

        local bundles = store:export_save_bundles()
        assert.equal(bundles.ok, true)
        local receipt_decoded = EconomyReceiptCodec.decode(bundles.value.slot5)
        assert.equal(receipt_decoded.ok, true)
        assert.truthy(receipt_decoded.value.receipts[receipt_id])
        assert.equal(
            receipt_decoded.value.source_occurrences.quest_run_001.receipt_id,
            receipt_id
        )

        local restored = FakeEconomyStore.new()
        assert.equal(restored.ok, true)
        local imported = restored.value:import_save_bundles(
            bundles.value.slot4,
            bundles.value.slot5
        )
        assert.equal(imported.ok, true)
        local restored_service = EconomyService.bind({
            currency_catalog = build_currency_catalog(),
            reward_catalog = build_reward_catalog(),
            store = restored.value,
        })
        assert.equal(restored_service.ok, true)
        local restored_balance = restored_service.value:get_balance('currency_copper')
        assert.equal(restored_balance.ok, true)
        assert.equal(restored_balance.value.balance, 30)
    end),

    case('prepare rejects item leaves without inventory and premium mint', function()
        local service = bind_service()
        local with_item = service:prepare_reward({
            reward_id = 'reward_with_item',
            source_type = 'QUEST',
            source_ref = 'reward_with_item',
            source_occurrence_id = 'quest_item_001',
        })
        assert.equal(with_item.ok, false)
        assert.equal(with_item.error.code, 'ECONOMY_ENTRY_UNSUPPORTED')

        local premium = service:prepare_reward({
            reward_id = 'reward_premium',
            source_type = 'QUEST',
            source_ref = 'reward_premium',
            source_occurrence_id = 'quest_premium_001',
        })
        assert.equal(premium.ok, true)
        local grant_premium = service:grant_prepared_reward({
            prepared = premium.value,
            receipt_id = make_receipt_id('premium'),
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_premium',
        })
        assert.equal(grant_premium.ok, false)
        assert.equal(grant_premium.error.code, 'ECONOMY_SOURCE_NOT_AUTHORIZED')
    end),

    case('prepare and grant mixed currency plus item through inventory service', function()
        local service, _, inventory = bind_service({ with_inventory = true })
        local prepared = service:prepare_reward({
            reward_id = 'reward_with_item',
            source_type = 'QUEST',
            source_ref = 'reward_with_item',
            source_occurrence_id = 'quest_item_grant_001',
        })
        assert.equal(prepared.ok, true, prepared.error and prepared.error.code)
        assert.equal(#prepared.value.entries, 2)

        local granted = service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = make_receipt_id('mixed_item'),
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_mixed',
        })
        assert.equal(granted.ok, true, granted.error and granted.error.code)
        assert.equal(granted.value.status, 'COMMITTED')
        assert.equal(#granted.value.item_grants, 1)
        assert.equal(granted.value.item_grants[1].item_id, 'item_healing_salve')

        local copper = service:get_balance('currency_copper')
        assert.equal(copper.value.balance, 5)
        local salve = inventory:get_count('item_healing_salve')
        assert.equal(salve.ok, true)
        assert.equal(salve.value.count, 1)
        assert.equal(granted.value.inventory_revision, salve.value.inventory_revision)
    end),

    case('nested currency leaves merge and reserve-commit-release works', function()
        local service = bind_service()
        local prepared = service:prepare_reward({
            reward_id = 'reward_nested_currency',
            source_type = 'QUEST',
            source_ref = 'reward_nested_currency',
            source_occurrence_id = 'quest_nested_001',
        })
        assert.equal(prepared.ok, true)
        assert.equal(#prepared.value.entries, 1)
        assert.equal(prepared.value.entries[1].quantity, 17)

        local granted = service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = make_receipt_id('nested'),
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_nested',
        })
        assert.equal(granted.ok, true)
        local copper = service:get_balance('currency_copper')
        assert.equal(copper.value.balance, 17)

        local reserved = service:reserve({
            costs = { { currency_id = 'currency_copper', amount = 5 } },
            rewards = { { currency_id = 'currency_true_qi', amount = 1 } },
            purpose_type = 'SHOP_PURCHASE',
            purpose_ref = 'shop_demo',
        })
        assert.equal(reserved.ok, true)
        copper = service:get_balance('currency_copper')
        assert.equal(copper.value.balance, 17)
        assert.equal(copper.value.reserved, 5)
        assert.equal(copper.value.available, 12)

        local released = service:release_reservation({
            reservation_id = reserved.value.reservation_id,
        })
        assert.equal(released.ok, true)
        copper = service:get_balance('currency_copper')
        assert.equal(copper.value.reserved, 0)
        assert.equal(copper.value.available, 17)

        local reserved2 = service:reserve({
            costs = { { currency_id = 'currency_copper', amount = 5 } },
            rewards = { { currency_id = 'currency_true_qi', amount = 1 } },
            purpose_type = 'SHOP_PURCHASE',
            purpose_ref = 'shop_demo',
        })
        assert.equal(reserved2.ok, true)
        local committed = service:commit_reservation({
            reservation_id = reserved2.value.reservation_id,
            receipt_id = make_receipt_id('shop_commit'),
            source_occurrence_id = 'shop_buy_001',
        })
        assert.equal(committed.ok, true)
        copper = service:get_balance('currency_copper')
        local qi = service:get_balance('currency_true_qi')
        assert.equal(copper.value.balance, 12)
        assert.equal(copper.value.reserved, 0)
        assert.equal(qi.value.balance, 1)
    end),

    case('receipt payload mismatch fails closed', function()
        local service = bind_service()
        local prepared = service:prepare_reward({
            reward_id = 'reward_quest_copper',
            source_type = 'QUEST',
            source_ref = 'reward_quest_copper',
            source_occurrence_id = 'quest_mismatch_001',
        })
        assert.equal(prepared.ok, true)
        local receipt_id = make_receipt_id('mismatch')
        local granted = service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = receipt_id,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_a',
        })
        assert.equal(granted.ok, true)

        local again = service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = receipt_id,
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_b',
        })
        assert.equal(again.ok, false)
        assert.equal(again.error.code, 'ECONOMY_RECEIPT_CONFLICT')
    end),

    case('pending overflow defers full inventory grant and claim delivers items', function()
        local inventory_store = FakeInventoryStore.new({ capacity_limit = 1 })
        assert.equal(inventory_store.ok, true)
        local inventory = InventoryService.bind({
            item_catalog = build_item_catalog(),
            store = inventory_store.value,
        })
        assert.equal(inventory.ok, true)
        -- Fill the only capacity slot.
        local fill = inventory.value:grant_items({
            items = { { item_id = 'item_healing_salve', amount = 20 } },
        })
        assert.equal(fill.ok, true)

        local store = FakeEconomyStore.new()
        assert.equal(store.ok, true)
        local service = EconomyService.bind({
            currency_catalog = build_currency_catalog(),
            reward_catalog = build_reward_catalog(),
            store = store.value,
            inventory_service = inventory.value,
        })
        assert.equal(service.ok, true)

        local prepared = service.value:prepare_reward({
            reward_id = 'reward_with_item',
            source_type = 'QUEST',
            source_ref = 'reward_with_item',
            source_occurrence_id = 'quest_pending_001',
            overflow_policy = 'PENDING',
        })
        assert.equal(prepared.ok, true)
        local deferred = service.value:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = make_receipt_id('pending_item'),
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_pending',
        })
        assert.equal(deferred.ok, true, deferred.error and deferred.error.code)
        assert.equal(deferred.value.status, 'PENDING')
        assert.equal(deferred.value.reason, 'INVENTORY_FULL')

        -- Free capacity then claim.
        local consumed = inventory.value:consume_items({
            costs = { { item_id = 'item_healing_salve', amount = 20 } },
        })
        assert.equal(consumed.ok, true)
        local claimed = service.value:claim_pending_reward({
            pending_id = deferred.value.pending_id,
        })
        assert.equal(claimed.ok, true, claimed.error and claimed.error.code)
        assert.equal(claimed.value.status, 'COMMITTED')
        local salve = inventory.value:get_count('item_healing_salve')
        assert.equal(salve.value.count, 1)
        local copper = service.value:get_balance('currency_copper')
        assert.equal(copper.value.balance, 5)
    end),

    case('spend resources debits currency with receipt and source idempotency', function()
        local service = bind_service()
        local prepared = service:prepare_reward({
            reward_id = 'reward_quest_copper',
            source_type = 'QUEST',
            source_ref = 'reward_quest_copper',
            source_occurrence_id = 'quest_fund_spend_001',
        })
        assert.equal(prepared.ok, true)
        local funded = service:grant_prepared_reward({
            prepared = prepared.value,
            receipt_id = make_receipt_id('fund_spend'),
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_fund',
        })
        assert.equal(funded.ok, true)

        local spend_receipt = make_receipt_id('spend_once')
        local spent = service:spend_resources({
            costs = {
                { currency_id = 'currency_copper', amount = 10 },
                { currency_id = 'currency_copper', amount = 5 },
            },
            purpose_type = 'SHOP_PURCHASE',
            purpose_ref = 'shop_demo_item',
            receipt_id = spend_receipt,
            source_occurrence_id = 'shop_buy_spend_001',
        })
        assert.equal(spent.ok, true, spent.error and spent.error.code)
        assert.equal(spent.value.status, 'COMMITTED')
        assert.equal(spent.value.already_committed, false)
        assert.equal(#spent.value.costs, 1)
        assert.equal(spent.value.costs[1].amount, 15)

        local copper = service:get_balance('currency_copper')
        assert.equal(copper.value.balance, 15)

        local replay = service:spend_resources({
            costs = {
                { currency_id = 'currency_copper', amount = 15 },
            },
            purpose_type = 'SHOP_PURCHASE',
            purpose_ref = 'shop_demo_item',
            receipt_id = spend_receipt,
            source_occurrence_id = 'shop_buy_spend_001',
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.already_committed, true)
        copper = service:get_balance('currency_copper')
        assert.equal(copper.value.balance, 15)

        local other_receipt = make_receipt_id('spend_other')
        local source_conflict = service:spend_resources({
            costs = {
                { currency_id = 'currency_copper', amount = 15 },
            },
            purpose_type = 'SHOP_PURCHASE',
            purpose_ref = 'shop_demo_item',
            receipt_id = other_receipt,
            source_occurrence_id = 'shop_buy_spend_001',
        })
        assert.equal(source_conflict.ok, false)
        assert.equal(source_conflict.error.code, 'ECONOMY_SOURCE_ALREADY_GRANTED')

        local insufficient = service:spend_resources({
            costs = {
                { currency_id = 'currency_copper', amount = 100 },
            },
            purpose_type = 'SHOP_PURCHASE',
            purpose_ref = 'shop_demo_expensive',
            receipt_id = make_receipt_id('spend_insufficient'),
            source_occurrence_id = 'shop_buy_spend_002',
        })
        assert.equal(insufficient.ok, false)
        assert.equal(insufficient.error.code, 'ECONOMY_CURRENCY_INSUFFICIENT')

        local bad_purpose = service:spend_resources({
            costs = {
                { currency_id = 'currency_copper', amount = 1 },
            },
            purpose_type = 'NOT_A_REAL_PURPOSE',
            purpose_ref = 'x',
            receipt_id = make_receipt_id('spend_bad_purpose'),
            source_occurrence_id = 'shop_buy_spend_003',
        })
        assert.equal(bad_purpose.ok, false)
        assert.equal(bad_purpose.error.details.reason, 'PURPOSE_TYPE_NOT_WHITELISTED')
    end),
}
