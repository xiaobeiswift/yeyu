local Harness = require 'wzx.tests.harness'
local FakeInventoryStore = require 'wzx.adapters.fake.inventory.fake_inventory_store'
local Inventory = require 'wzx.domain.inventory.inventory'
local InventorySaveCodec = require 'wzx.domain.inventory.inventory_save_codec'
local InventoryService = require 'wzx.application.use_cases.inventory.inventory_service'
local ItemCatalog = require 'wzx.config.schema.inventory.catalog'
local ItemDefinition = require 'wzx.config.schema.inventory.item_definition'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local InventorySectionRegistrar = require 'wzx.config.schema.inventory.section_registrar'

local case = Harness.case
local assert = Harness.assert

local function salve()
    return {
        id = 'item_healing_salve',
        schema_version = 1,
        category = 'CONSUMABLE',
        name_key = 'item.healing_salve.name',
        max_stack = 20,
        ownership_cap = 200,
        rarity = 'COMMON',
        discard_policy = 'ALLOW',
    }
end

local function ore()
    return {
        id = 'item_iron_ore',
        schema_version = 1,
        category = 'MATERIAL',
        name_key = 'item.iron_ore.name',
        max_stack = 99,
        ownership_cap = 999,
        rarity = 'COMMON',
    }
end

local function quest_token()
    return {
        id = 'item_quest_seal',
        schema_version = 1,
        category = 'QUEST',
        name_key = 'item.quest_seal.name',
        max_stack = 1,
        ownership_cap = 1,
        rarity = 'FINE',
    }
end

local function build_catalog()
    local built = ItemCatalog.build({
        item_definitions = {
            salve(),
            ore(),
            quest_token(),
        },
    })
    assert.equal(built.ok, true)
    return built.value
end

local function bind_service(capacity_limit)
    local store = FakeInventoryStore.new({ capacity_limit = capacity_limit })
    assert.equal(store.ok, true)
    local service = InventoryService.bind({
        item_catalog = build_catalog(),
        store = store.value,
    })
    assert.equal(service.ok, true)
    return service.value, store.value
end

return {
    case('item definition defaults and quest constraints', function()
        local ok = ItemDefinition.validate(salve())
        assert.equal(ok.ok, true)
        assert.equal(ok.value.capacity_policy, 'NORMAL')
        assert.equal(ok.value.bind_policy, 'ACCOUNT_BOUND')

        local quest = ItemDefinition.validate(quest_token())
        assert.equal(quest.ok, true)
        assert.equal(quest.value.capacity_policy, 'KEY_ITEM_FREE')
        assert.equal(quest.value.discard_policy, 'DENY')

        local bad_quest = quest_token()
        bad_quest.discard_policy = 'ALLOW'
        local rejected = ItemDefinition.validate(bad_quest)
        assert.equal(rejected.ok, false)
    end),

    case('catalog seals and section registrar owns slot 4 inventory sections', function()
        local catalog = build_catalog()
        assert.equal(ItemCatalog.is_authority(catalog), true)
        assert.equal(catalog:contains('item_healing_salve'), true)
        local missing = catalog:require('item_missing')
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'INVENTORY_ITEM_UNKNOWN')

        local registry = SectionOwnerRegistry.new()
        assert.equal(registry.ok, true)
        local registered = InventorySectionRegistrar.register({
            system_id = '09',
            section_owners = registry.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 2)
        local meta = registry.value:get('inventory_metadata')
        assert.equal(meta.ok, true)
        assert.equal(meta.value.owner_system, '09')
        assert.equal(meta.value.slot_id, 4)
    end),

    case('stack grant consume capacity and save codec round-trip', function()
        local catalog = build_catalog()
        local empty = Inventory.empty(2)
        assert.equal(empty.ok, true)

        -- max_stack 20: 21 units use 2 slots, fills capacity 2.
        local plan = Inventory.plan_grant(empty.value, {
            { item_id = 'item_healing_salve', amount = 21 },
        }, catalog, 'REJECT')
        assert.equal(plan.ok, true)
        local applied = Inventory.apply_plan(empty.value, plan.value)
        assert.equal(applied.ok, true)
        assert.equal(applied.value.stacks.item_healing_salve, 21)

        local full = Inventory.plan_grant(applied.value, {
            { item_id = 'item_iron_ore', amount = 1 },
        }, catalog, 'REJECT')
        assert.equal(full.ok, false)
        assert.equal(full.error.code, 'INVENTORY_FULL')

        -- Quest free capacity still fits.
        local quest_plan = Inventory.plan_grant(applied.value, {
            { item_id = 'item_quest_seal', amount = 1 },
        }, catalog, 'REJECT')
        assert.equal(quest_plan.ok, true)

        local encoded = InventorySaveCodec.encode(applied.value)
        assert.equal(encoded.ok, true)
        local decoded = InventorySaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true)
        assert.equal(decoded.value.stacks.item_healing_salve, 21)
        assert.equal(decoded.value.inventory_revision, 1)
    end),

    case('inventory service grants consumes and enforces ownership cap', function()
        local service = bind_service(60)
        local granted = service:grant_items({
            items = {
                { item_id = 'item_healing_salve', amount = 5 },
                { item_id = 'item_healing_salve', amount = 7 },
            },
        })
        assert.equal(granted.ok, true)
        assert.equal(granted.value.grants[1].amount, 12)
        local count = service:get_count('item_healing_salve')
        assert.equal(count.value.count, 12)

        local consumed = service:consume_items({
            costs = {
                { item_id = 'item_healing_salve', amount = 4 },
            },
        })
        assert.equal(consumed.ok, true)
        count = service:get_count('item_healing_salve')
        assert.equal(count.value.count, 8)

        local insufficient = service:consume_items({
            costs = {
                { item_id = 'item_healing_salve', amount = 100 },
            },
        })
        assert.equal(insufficient.ok, false)
        assert.equal(insufficient.error.code, 'INVENTORY_ITEM_INSUFFICIENT')

        local cap = service:grant_items({
            items = {
                { item_id = 'item_healing_salve', amount = 200 },
            },
        })
        assert.equal(cap.ok, false)
        assert.equal(cap.error.code, 'INVENTORY_ITEM_CAP_REACHED')
    end),
}
