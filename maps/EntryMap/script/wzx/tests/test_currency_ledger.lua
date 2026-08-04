local Harness = require 'wzx.tests.harness'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local CurrencyLedger = require 'wzx.domain.economy.currency_ledger'
local EconomySaveCodec = require 'wzx.domain.economy.economy_save_codec'

local case = Harness.case
local assert = Harness.assert

local function build_catalog()
    local built = CurrencyCatalog.build({
        currency_definitions = {
            {
                id = 'currency_copper',
                schema_version = 1,
                category = 'SOFT',
                balance_cap = 100,
                source_policy_id = 'currpolicy_copper_source',
                sink_policy_id = 'currpolicy_copper_sink',
                name_key = 'currency.copper.name',
            },
            {
                id = 'currency_true_qi',
                schema_version = 1,
                category = 'PROGRESSION',
                balance_cap = 50,
                source_policy_id = 'currpolicy_true_qi_source',
                sink_policy_id = 'currpolicy_true_qi_sink',
                name_key = 'currency.true_qi.name',
            },
            {
                id = 'currency_premium_jade',
                schema_version = 1,
                category = 'PREMIUM_PLATFORM',
                balance_cap = 20,
                source_policy_id = 'currpolicy_premium_source',
                sink_policy_id = 'currpolicy_premium_sink',
                name_key = 'currency.premium_jade.name',
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

return {
    case('ledger grants, spends, and enforces cap/insufficient', function()
        local catalog = build_catalog()
        local state = CurrencyLedger.empty()

        local plan = CurrencyLedger.plan_transaction(
            state,
            {},
            {
                { currency_id = 'currency_copper', amount = 40 },
                { currency_id = 'currency_true_qi', amount = 5 },
            },
            catalog
        )
        assert.equal(plan.ok, true)
        local applied = CurrencyLedger.apply_plan(state, plan.value)
        assert.equal(applied.ok, true)
        assert.equal(applied.value.economy_revision, 1)
        assert.equal(applied.value.accounts.currency_copper.balance, 40)
        assert.equal(applied.value.accounts.currency_true_qi.balance, 5)

        local over_cap = CurrencyLedger.plan_transaction(
            applied.value,
            {},
            { { currency_id = 'currency_copper', amount = 70 } },
            catalog
        )
        assert.equal(over_cap.ok, false)
        assert.equal(over_cap.error.code, 'ECONOMY_CURRENCY_CAP_REACHED')

        local spend = CurrencyLedger.plan_transaction(
            applied.value,
            { { currency_id = 'currency_copper', amount = 15 } },
            {},
            catalog
        )
        assert.equal(spend.ok, true)
        local spent = CurrencyLedger.apply_plan(applied.value, spend.value)
        assert.equal(spent.ok, true)
        assert.equal(spent.value.accounts.currency_copper.balance, 25)
        assert.equal(spent.value.economy_revision, 2)

        local insufficient = CurrencyLedger.plan_transaction(
            spent.value,
            { { currency_id = 'currency_copper', amount = 26 } },
            {},
            catalog
        )
        assert.equal(insufficient.ok, false)
        assert.equal(insufficient.error.code, 'ECONOMY_CURRENCY_INSUFFICIENT')
    end),

    case('ledger blocks premium platform minting and merges sorted deltas', function()
        local catalog = build_catalog()
        local state = CurrencyLedger.empty()

        local premium = CurrencyLedger.plan_transaction(
            state,
            {},
            { { currency_id = 'currency_premium_jade', amount = 1 } },
            catalog
        )
        assert.equal(premium.ok, false)
        assert.equal(premium.error.code, 'ECONOMY_SOURCE_NOT_AUTHORIZED')

        local plan = CurrencyLedger.plan_transaction(
            state,
            {},
            {
                { currency_id = 'currency_true_qi', amount = 3 },
                { currency_id = 'currency_copper', amount = 2 },
                { currency_id = 'currency_copper', amount = 4 },
            },
            catalog
        )
        assert.equal(plan.ok, true)
        assert.equal(#plan.value.rewards, 2)
        assert.equal(plan.value.rewards[1].currency_id, 'currency_copper')
        assert.equal(plan.value.rewards[1].amount, 6)
        assert.equal(plan.value.rewards[2].currency_id, 'currency_true_qi')
        assert.equal(plan.value.rewards[2].amount, 3)
    end),

    case('reserve and commit release keep available non-negative', function()
        local catalog = build_catalog()
        local state = CurrencyLedger.empty()
        local funded = CurrencyLedger.apply_plan(
            state,
            CurrencyLedger.plan_transaction(
                state,
                {},
                { { currency_id = 'currency_copper', amount = 30 } },
                catalog
            ).value
        )
        assert.equal(funded.ok, true)

        local reserved = CurrencyLedger.reserve_costs(
            funded.value,
            { { currency_id = 'currency_copper', amount = 10 } },
            catalog
        )
        assert.equal(reserved.ok, true)
        assert.equal(reserved.value.accounts.currency_copper.balance, 30)
        assert.equal(reserved.value.accounts.currency_copper.reserved, 10)

        local available = CurrencyLedger.get_account(reserved.value, 'currency_copper')
        assert.equal(available.ok, true)
        assert.equal(available.value.available, 20)

        local committed = CurrencyLedger.commit_reserved(
            reserved.value,
            { { currency_id = 'currency_copper', amount = 10 } },
            { { currency_id = 'currency_true_qi', amount = 2 } },
            catalog
        )
        assert.equal(committed.ok, true)
        assert.equal(committed.value.accounts.currency_copper.balance, 20)
        assert.equal(committed.value.accounts.currency_copper.reserved, 0)
        assert.equal(committed.value.accounts.currency_true_qi.balance, 2)
    end),

    case('economy save codec round-trips and rejects non-zero reserved', function()
        local snapshot = {
            economy_revision = 3,
            accounts = {
                currency_copper = {
                    balance = 12,
                    reserved = 0,
                    account_revision = 2,
                },
                currency_true_qi = {
                    balance = 0,
                    reserved = 0,
                    account_revision = 0,
                },
            },
        }
        local encoded = EconomySaveCodec.encode(snapshot)
        assert.equal(encoded.ok, true)
        assert.equal(encoded.value.economy_metadata.economy_revision, 3)
        assert.equal(#encoded.value.currency_balance_rows, 1)
        assert.equal(encoded.value.currency_balance_rows[1].currency_id, 'currency_copper')

        local decoded = EconomySaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true)
        assert.equal(decoded.value.economy_revision, 3)
        assert.equal(decoded.value.accounts.currency_copper.balance, 12)
        assert.equal(decoded.value.accounts.currency_copper.reserved, 0)

        snapshot.accounts.currency_copper.reserved = 1
        local bad = EconomySaveCodec.encode(snapshot)
        assert.equal(bad.ok, false)
        assert.equal(bad.error.details.reason, 'RESERVED_MUST_BE_ZERO_ON_SAVE')
    end),
}
