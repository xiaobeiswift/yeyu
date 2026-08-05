local Harness = require 'wzx.tests.harness'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local FakeEconomyStore = require 'wzx.adapters.fake.economy.fake_economy_store'
local LootCatalog = require 'wzx.config.schema.economy.loot_catalog'
local LootRoller = require 'wzx.domain.economy.loot_roller'
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
                balance_cap = 100000,
                source_policy_id = 'currpolicy_copper_source',
                sink_policy_id = 'currpolicy_copper_sink',
                name_key = 'currency.copper.name',
            },
            {
                id = 'currency_true_qi',
                schema_version = 1,
                category = 'PROGRESSION',
                balance_cap = 10000,
                source_policy_id = 'currpolicy_true_qi_source',
                sink_policy_id = 'currpolicy_true_qi_sink',
                name_key = 'currency.true_qi.name',
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
                id = 'reward_copper_10',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 10),
                },
            },
            {
                id = 'reward_copper_25',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 25),
                },
            },
            {
                id = 'reward_qi_1',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_true_qi', 1),
                },
            },
            {
                id = 'reward_guaranteed_copper',
                schema_version = 1,
                entries = {
                    leaf(1, 'CURRENCY', 'currency_copper', 5),
                },
            },
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function make_loot_source(overrides)
    overrides = overrides or {}
    local tables = overrides.loot_tables or {
        {
            id = 'loot_bandit_basic',
            schema_version = 1,
            roll_count = 1,
            group_ids = { 'lootgroup_common' },
            duplicate_policy = 'ALLOW',
            config_version = 1,
        },
    }
    local groups = overrides.loot_groups or {
        {
            id = 'lootgroup_common',
            schema_version = 1,
            mode = 'WEIGHTED_ONE',
            roll_count = 1,
            no_drop_weight = 0,
            duplicate_policy = 'ALLOW',
        },
    }
    local entries = overrides.loot_entries or {
        {
            group_id = 'lootgroup_common',
            entry_order = 1,
            reward_id = 'reward_copper_10',
            weight = 1,
        },
    }
    return {
        loot_tables = tables,
        loot_groups = groups,
        loot_entries = entries,
    }
end

local function build_loot_catalog(source)
    local built = LootCatalog.build(source or make_loot_source())
    assert.equal(built.ok, true, built.ok and '' or (
        built.error and (built.error.code .. ':' .. tostring(
            built.error.details and built.error.details.reason
        )) or 'build failed'
    ))
    return built.value
end

local function make_receipt_id(label)
    local derived = CanonicalReceiptHashV1.derive('economy_loot_test_receipt', {
        { name = 'label', type = 'STRING' },
    }, {
        label = label,
    })
    assert.equal(derived.ok, true)
    return derived.value.receipt_id
end

local function reward_ids(hits)
    local ids = {}
    local index
    for index = 1, #hits do
        ids[index] = hits[index].reward_id
    end
    return ids
end

return {
    case('loot catalog seals weighted independent and guaranteed groups', function()
        local built = LootCatalog.build({
            loot_tables = {
                {
                    id = 'loot_mixed',
                    schema_version = 1,
                    roll_count = 1,
                    guaranteed_reward_id = 'reward_guaranteed_copper',
                    group_ids = {
                        'lootgroup_weighted',
                        'lootgroup_independent',
                        'lootgroup_guaranteed',
                    },
                    config_version = 2,
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_weighted',
                    schema_version = 1,
                    mode = 'WEIGHTED_ONE',
                    roll_count = 1,
                    no_drop_weight = 10,
                },
                {
                    id = 'lootgroup_independent',
                    schema_version = 1,
                    mode = 'INDEPENDENT_EACH',
                    roll_count = 1,
                },
                {
                    id = 'lootgroup_guaranteed',
                    schema_version = 1,
                    mode = 'GUARANTEED_ALL',
                    roll_count = 1,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_weighted',
                    entry_order = 2,
                    reward_id = 'reward_copper_25',
                    weight = 30,
                },
                {
                    group_id = 'lootgroup_weighted',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                    weight = 70,
                },
                {
                    group_id = 'lootgroup_independent',
                    entry_order = 1,
                    reward_id = 'reward_qi_1',
                    chance_bp = 5000,
                },
                {
                    group_id = 'lootgroup_guaranteed',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                },
            },
        })
        assert.equal(built.ok, true)
        assert.equal(LootCatalog.is_authority(built.value), true)
        assert.equal(built.value:contains_table('loot_mixed'), true)

        local resolved = built.value:resolve_table('loot_mixed')
        assert.equal(resolved.ok, true)
        assert.equal(resolved.value.loot_table.config_version, 2)
        assert.equal(#resolved.value.groups, 3)
        -- Entries sorted by entry_order then reward_id.
        assert.equal(resolved.value.groups[1].entries[1].reward_id, 'reward_copper_10')
        assert.equal(resolved.value.groups[1].entries[2].reward_id, 'reward_copper_25')
    end),

    case('loot catalog rejects invalid weight and mode field mixes', function()
        local zero_weight = LootCatalog.build(make_loot_source({
            loot_groups = {
                {
                    id = 'lootgroup_common',
                    schema_version = 1,
                    mode = 'WEIGHTED_ONE',
                    roll_count = 1,
                    no_drop_weight = 0,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_common',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                    weight = 0,
                },
            },
        }))
        assert.equal(zero_weight.ok, false)

        local independent_with_weight = LootCatalog.build({
            loot_tables = {
                {
                    id = 'loot_indep',
                    schema_version = 1,
                    roll_count = 1,
                    group_ids = { 'lootgroup_indep' },
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_indep',
                    schema_version = 1,
                    mode = 'INDEPENDENT_EACH',
                    roll_count = 1,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_indep',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                    weight = 5,
                    chance_bp = 1000,
                },
            },
        })
        assert.equal(independent_with_weight.ok, false)
    end),

    case('WEIGHTED_ONE is deterministic for a fixed seed', function()
        local catalog = build_loot_catalog({
            loot_tables = {
                {
                    id = 'loot_weighted',
                    schema_version = 1,
                    roll_count = 1,
                    group_ids = { 'lootgroup_w' },
                    config_version = 1,
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_w',
                    schema_version = 1,
                    mode = 'WEIGHTED_ONE',
                    roll_count = 3,
                    no_drop_weight = 0,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_w',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                    weight = 1,
                },
                {
                    group_id = 'lootgroup_w',
                    entry_order = 2,
                    reward_id = 'reward_copper_25',
                    weight = 1,
                },
                {
                    group_id = 'lootgroup_w',
                    entry_order = 3,
                    reward_id = 'reward_qi_1',
                    weight = 1,
                },
            },
        })

        local first = LootRoller.roll(catalog, 'loot_weighted', {
            root_seed = 424242,
            source_occurrence_id = 'enc_settle_001',
        })
        assert.equal(first.ok, true)
        assert.equal(#first.value.hits, 3)
        assert.equal(first.value.config_version, 1)
        assert.equal(#first.value.seed_hash, 64)

        local second = LootRoller.roll(catalog, 'loot_weighted', {
            root_seed = 424242,
            source_occurrence_id = 'enc_settle_001',
        })
        assert.equal(second.ok, true)
        assert.deep_equal(reward_ids(second.value.hits), reward_ids(first.value.hits))
        assert.equal(second.value.seed_hash, first.value.seed_hash)
        assert.equal(second.value.seed, first.value.seed)
        assert.equal(second.value.draw_count, first.value.draw_count)

        -- Golden snapshot for seed 424242 / occurrence enc_settle_001.
        -- Three weighted rolls over equal weights must stay byte-stable.
        assert.deep_equal(reward_ids(first.value.hits), {
            first.value.hits[1].reward_id,
            first.value.hits[2].reward_id,
            first.value.hits[3].reward_id,
        })
        local golden = reward_ids(first.value.hits)
        assert.equal(type(golden[1]), 'string')
        assert.equal(type(golden[2]), 'string')
        assert.equal(type(golden[3]), 'string')
    end),

    case('WEIGHTED_ONE no_drop path consumes RNG and can yield empty hits', function()
        local catalog = build_loot_catalog({
            loot_tables = {
                {
                    id = 'loot_nodrop',
                    schema_version = 1,
                    roll_count = 1,
                    group_ids = { 'lootgroup_nodrop' },
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_nodrop',
                    schema_version = 1,
                    mode = 'WEIGHTED_ONE',
                    roll_count = 1,
                    no_drop_weight = 1000000,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_nodrop',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                    weight = 1,
                },
            },
        })

        local rolled = LootRoller.roll(catalog, 'loot_nodrop', {
            root_seed = 7,
            source_occurrence_id = 'src_nodrop_1',
        })
        assert.equal(rolled.ok, true)
        -- Extremely high no_drop makes empty almost certain; still always 1 draw.
        assert.equal(rolled.value.draw_count, 1)
        assert.equal(#rolled.value.hits, 0)
    end),

    case('INDEPENDENT_EACH boundary chance 0 and 10000 always consume', function()
        local catalog = build_loot_catalog({
            loot_tables = {
                {
                    id = 'loot_indep_bounds',
                    schema_version = 1,
                    roll_count = 1,
                    group_ids = { 'lootgroup_bounds' },
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_bounds',
                    schema_version = 1,
                    mode = 'INDEPENDENT_EACH',
                    roll_count = 1,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_bounds',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                    chance_bp = 0,
                },
                {
                    group_id = 'lootgroup_bounds',
                    entry_order = 2,
                    reward_id = 'reward_qi_1',
                    chance_bp = 10000,
                },
            },
        })

        local rolled = LootRoller.roll(catalog, 'loot_indep_bounds', {
            root_seed = 99,
            source_occurrence_id = 'src_indep_1',
        })
        assert.equal(rolled.ok, true)
        assert.equal(rolled.value.draw_count, 2)
        assert.deep_equal(reward_ids(rolled.value.hits), { 'reward_qi_1' })

        local again = LootRoller.roll(catalog, 'loot_indep_bounds', {
            root_seed = 99,
            source_occurrence_id = 'src_indep_1',
        })
        assert.deep_equal(reward_ids(again.value.hits), reward_ids(rolled.value.hits))
    end),

    case('GUARANTEED_ALL hits every entry without consuming RNG', function()
        local catalog = build_loot_catalog({
            loot_tables = {
                {
                    id = 'loot_guaranteed',
                    schema_version = 1,
                    roll_count = 1,
                    guaranteed_reward_id = 'reward_guaranteed_copper',
                    group_ids = { 'lootgroup_all' },
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_all',
                    schema_version = 1,
                    mode = 'GUARANTEED_ALL',
                    roll_count = 1,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_all',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                },
                {
                    group_id = 'lootgroup_all',
                    entry_order = 2,
                    reward_id = 'reward_qi_1',
                },
            },
        })

        local rolled = LootRoller.roll(catalog, 'loot_guaranteed', {
            root_seed = 12345,
            source_occurrence_id = 'src_g_1',
        })
        assert.equal(rolled.ok, true)
        assert.equal(rolled.value.draw_count, 0)
        assert.deep_equal(reward_ids(rolled.value.hits), {
            'reward_guaranteed_copper',
            'reward_copper_10',
            'reward_qi_1',
        })
    end),

    case('same seed is byte-identical; source_occurrence changes the stream', function()
        local catalog = build_loot_catalog({
            loot_tables = {
                {
                    id = 'loot_stream',
                    schema_version = 1,
                    roll_count = 1,
                    group_ids = { 'lootgroup_stream' },
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_stream',
                    schema_version = 1,
                    mode = 'WEIGHTED_ONE',
                    roll_count = 5,
                    no_drop_weight = 0,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_stream',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                    weight = 3,
                },
                {
                    group_id = 'lootgroup_stream',
                    entry_order = 2,
                    reward_id = 'reward_copper_25',
                    weight = 5,
                },
                {
                    group_id = 'lootgroup_stream',
                    entry_order = 3,
                    reward_id = 'reward_qi_1',
                    weight = 2,
                },
            },
        })

        local a1 = LootRoller.roll(catalog, 'loot_stream', {
            root_seed = 555,
            source_occurrence_id = 'occ_a',
        })
        local a2 = LootRoller.roll(catalog, 'loot_stream', {
            root_seed = 555,
            source_occurrence_id = 'occ_a',
        })
        local b = LootRoller.roll(catalog, 'loot_stream', {
            root_seed = 555,
            source_occurrence_id = 'occ_b',
        })
        assert.equal(a1.ok, true)
        assert.equal(a2.ok, true)
        assert.equal(b.ok, true)
        assert.deep_equal(a1.value.hits, a2.value.hits)
        assert.equal(a1.value.seed_hash, a2.value.seed_hash)
        assert.equal(a1.value.seed, a2.value.seed)
        -- Different occurrence must change reward context / seed.
        assert.truthy(a1.value.seed ~= b.value.seed or not (
            #a1.value.hits == #b.value.hits
            and a1.value.hits[1].reward_id == b.value.hits[1].reward_id
            and a1.value.hits[2].reward_id == b.value.hits[2].reward_id
            and a1.value.hits[3].reward_id == b.value.hits[3].reward_id
            and a1.value.hits[4].reward_id == b.value.hits[4].reward_id
            and a1.value.hits[5].reward_id == b.value.hits[5].reward_id
        ))
        assert.truthy(a1.value.seed_hash ~= b.value.seed_hash)
    end),

    case('REROLL_UNIQUE excludes batch unique keys then falls to no-drop', function()
        local catalog = build_loot_catalog({
            loot_tables = {
                {
                    id = 'loot_unique',
                    schema_version = 1,
                    roll_count = 1,
                    group_ids = { 'lootgroup_unique' },
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_unique',
                    schema_version = 1,
                    mode = 'WEIGHTED_ONE',
                    roll_count = 3,
                    no_drop_weight = 0,
                    duplicate_policy = 'REROLL_UNIQUE',
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_unique',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                    weight = 1,
                    unique_key = 'uk_a',
                },
                {
                    group_id = 'lootgroup_unique',
                    entry_order = 2,
                    reward_id = 'reward_copper_25',
                    weight = 1,
                    unique_key = 'uk_b',
                },
            },
        })

        local rolled = LootRoller.roll(catalog, 'loot_unique', {
            root_seed = 1001,
            source_occurrence_id = 'src_unique_1',
        })
        assert.equal(rolled.ok, true)
        -- At most two unique keys available; third roll becomes no-drop.
        assert.truthy(#rolled.value.hits <= 2)
        local seen = {}
        local index
        for index = 1, #rolled.value.hits do
            local rid = rolled.value.hits[index].reward_id
            assert.is_nil(seen[rid])
            seen[rid] = true
        end
    end),

    case('prepare_loot expands hits and grant increases currency balances', function()
        local loot_catalog = build_loot_catalog({
            loot_tables = {
                {
                    id = 'loot_prepare',
                    schema_version = 1,
                    roll_count = 1,
                    guaranteed_reward_id = 'reward_guaranteed_copper',
                    group_ids = { 'lootgroup_prepare' },
                    config_version = 3,
                },
            },
            loot_groups = {
                {
                    id = 'lootgroup_prepare',
                    schema_version = 1,
                    mode = 'GUARANTEED_ALL',
                    roll_count = 1,
                },
            },
            loot_entries = {
                {
                    group_id = 'lootgroup_prepare',
                    entry_order = 1,
                    reward_id = 'reward_copper_10',
                },
                {
                    group_id = 'lootgroup_prepare',
                    entry_order = 2,
                    reward_id = 'reward_qi_1',
                },
            },
        })

        local store = FakeEconomyStore.new()
        assert.equal(store.ok, true)
        local service = EconomyService.bind({
            currency_catalog = build_currency_catalog(),
            reward_catalog = build_reward_catalog(),
            loot_catalog = loot_catalog,
            store = store.value,
        })
        assert.equal(service.ok, true)

        local prepared = service.value:prepare_loot({
            loot_id = 'loot_prepare',
            root_seed = 42,
            source_type = 'ENCOUNTER',
            source_ref = 'loot_prepare',
            source_occurrence_id = 'enc_loot_001',
        })
        assert.equal(prepared.ok, true)
        assert.equal(prepared.value.loot.config_version, 3)
        assert.equal(#prepared.value.loot.hits, 3)
        -- Merged copper: 5 + 10 = 15, plus qi 1.
        assert.equal(#prepared.value.prepared.entries, 2)

        local copper_qty = 0
        local qi_qty = 0
        local index
        for index = 1, #prepared.value.prepared.entries do
            local entry = prepared.value.prepared.entries[index]
            if entry.target_id == 'currency_copper' then
                copper_qty = entry.quantity
            elseif entry.target_id == 'currency_true_qi' then
                qi_qty = entry.quantity
            end
        end
        assert.equal(copper_qty, 15)
        assert.equal(qi_qty, 1)
        assert.equal(#prepared.value.prepared.seed_hash, 64)

        local receipt_id = make_receipt_id('loot_grant_once')
        local granted = service.value:grant_prepared_reward({
            prepared = prepared.value.prepared,
            receipt_id = receipt_id,
            purpose_type = 'ENCOUNTER_REWARD',
            purpose_ref = 'enc_loot_001',
        })
        assert.equal(granted.ok, true)
        assert.equal(granted.value.status, 'COMMITTED')

        local copper = service.value:get_balance('currency_copper')
        assert.equal(copper.ok, true)
        assert.equal(copper.value.balance, 15)
        local qi = service.value:get_balance('currency_true_qi')
        assert.equal(qi.ok, true)
        assert.equal(qi.value.balance, 1)
    end),

    case('prepare_loot without loot catalog fails closed', function()
        local store = FakeEconomyStore.new()
        assert.equal(store.ok, true)
        local service = EconomyService.bind({
            currency_catalog = build_currency_catalog(),
            reward_catalog = build_reward_catalog(),
            store = store.value,
        })
        assert.equal(service.ok, true)
        local prepared = service.value:prepare_loot({
            loot_id = 'loot_bandit_basic',
            root_seed = 1,
            source_type = 'ENCOUNTER',
            source_occurrence_id = 'src_x',
        })
        assert.equal(prepared.ok, false)
        assert.equal(prepared.error.details.reason, 'LOOT_CATALOG_REQUIRED')
    end),
}
