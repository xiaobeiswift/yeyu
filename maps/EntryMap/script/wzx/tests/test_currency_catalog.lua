local Harness = require 'wzx.tests.harness'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local CurrencyDefinition = require 'wzx.config.schema.economy.currency_definition'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local EconomySectionRegistrar = require 'wzx.config.schema.economy.section_registrar'

local case = Harness.case
local assert = Harness.assert

local function copper()
    return {
        id = 'currency_copper',
        schema_version = 1,
        category = 'SOFT',
        balance_cap = 1000000,
        source_policy_id = 'currpolicy_copper_source',
        sink_policy_id = 'currpolicy_copper_sink',
        name_key = 'currency.copper.name',
        icon_id = 'icon_currency_copper',
    }
end

local function true_qi()
    return {
        id = 'currency_true_qi',
        schema_version = 1,
        category = 'PROGRESSION',
        balance_cap = 500000,
        overflow_policy = 'REJECT',
        source_policy_id = 'currpolicy_true_qi_source',
        sink_policy_id = 'currpolicy_true_qi_sink',
        name_key = 'currency.true_qi.name',
        deprecated = false,
    }
end

local function premium()
    return {
        id = 'currency_premium_jade',
        schema_version = 1,
        category = 'PREMIUM_PLATFORM',
        balance_cap = 100000,
        source_policy_id = 'currpolicy_premium_source',
        sink_policy_id = 'currpolicy_premium_sink',
        name_key = 'currency.premium_jade.name',
    }
end

return {
    case('currency definition normalizes defaults and rejects clamp compensation', function()
        local ok = CurrencyDefinition.validate(copper())
        assert.equal(ok.ok, true)
        assert.equal(ok.value.overflow_policy, 'REJECT')
        assert.equal(ok.value.display_precision, 0)
        assert.equal(ok.value.negative_allowed, false)
        assert.equal(ok.value.deprecated, false)

        local clamp = copper()
        clamp.overflow_policy = 'CLAMP_WITH_COMPENSATION'
        local bad = CurrencyDefinition.validate(clamp)
        assert.equal(bad.ok, false)
        assert.equal(bad.error.details.reason, 'CLAMP_WITH_COMPENSATION_DISABLED_IN_V1')
    end),

    case('currency catalog seals definitions and require fails closed', function()
        local built = CurrencyCatalog.build({
            currency_definitions = {
                copper(),
                true_qi(),
                premium(),
            },
        })
        assert.equal(built.ok, true)
        assert.equal(CurrencyCatalog.is_authority(built.value), true)
        assert.equal(built.value:contains('currency_copper'), true)

        local required = built.value:require('currency_true_qi')
        assert.equal(required.ok, true)
        assert.equal(required.value.category, 'PROGRESSION')

        local missing = built.value:require('currency_missing')
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'ECONOMY_CURRENCY_UNKNOWN')
    end),

    case('currency catalog rejects unknown fields and duplicate ids', function()
        local unknown = CurrencyCatalog.build({
            currency_definitions = { copper() },
            unexpected = true,
        })
        assert.equal(unknown.ok, false)

        local duplicate = CurrencyCatalog.build({
            currency_definitions = {
                copper(),
                copper(),
            },
        })
        assert.equal(duplicate.ok, false)
    end),

    case('economy section registrar owns slot 4 and slot 5 sections', function()
        local registry = SectionOwnerRegistry.new()
        assert.equal(registry.ok, true)
        local registered = EconomySectionRegistrar.register({
            system_id = '10',
            section_owners = registry.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 5)

        local meta = registry.value:get('economy_metadata')
        assert.equal(meta.ok, true)
        assert.equal(meta.value.slot_id, 4)
        assert.equal(meta.value.owner_system, '10')

        local receipts = registry.value:get('economy_reward_receipts')
        assert.equal(receipts.ok, true)
        assert.equal(receipts.value.slot_id, 5)
    end),
}
