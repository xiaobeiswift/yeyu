local Harness = require 'wzx.tests.harness'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CharacterLoadout = require 'wzx.domain.equipment.character_loadout'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local EnhancementPolicy = require 'wzx.domain.equipment.enhancement_policy'
local EquipmentCatalog = require 'wzx.config.schema.equipment.catalog'
local EquipmentInstance = require 'wzx.domain.equipment.equipment_instance'
local EquipmentReceiptCodec = require 'wzx.domain.equipment.equipment_receipt_codec'
local EquipmentSaveBridge = require 'wzx.application.use_cases.equipment.equipment_save_bridge'
local EquipmentSaveCodec = require 'wzx.domain.equipment.equipment_save_codec'
local EquipmentSectionRegistrar = require 'wzx.config.schema.equipment.section_registrar'
local EquipmentService = require 'wzx.application.use_cases.equipment.equipment_service'
local FakeEconomyStore = require 'wzx.adapters.fake.economy.fake_economy_store'
local FakeEquipmentStore = require 'wzx.adapters.fake.equipment.fake_equipment_store'
local FakeInventoryStore = require 'wzx.adapters.fake.inventory.fake_inventory_store'
local HydrateGameRuntime = require 'wzx.application.use_cases.save.hydrate_game_runtime'
local InventoryService = require 'wzx.application.use_cases.inventory.inventory_service'
local ItemCatalog = require 'wzx.config.schema.inventory.catalog'
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local StatContribution = require 'wzx.domain.contracts.stat_contribution'
local StatResolver = require 'wzx.domain.equipment.stat_resolver'
local TemperRule = require 'wzx.config.schema.equipment.temper_rule'

local case = Harness.case
local assert = Harness.assert

local function make_receipt_id(label)
    local derived = CanonicalReceiptHashV1.derive('equipment_test_receipt', {
        { name = 'label', type = 'STRING' },
    }, {
        label = label,
    })
    assert.equal(derived.ok, true)
    return derived.value.receipt_id
end

local function enhance_track(id, max_level)
    max_level = max_level or 3
    local rows = {}
    local index
    for index = 1, max_level do
        rows[index] = {
            target_level = index,
            stat_rate_bp = index * 500,
            copper_cost = index * 100,
            material_item_id = 'item_enhance_stone',
            material_count = index,
            required_player_chapter = 0,
        }
    end
    return {
        id = id,
        schema_version = 1,
        level_rows = rows,
    }
end

local function base_stat(id, flat_attack, flat_defense)
    local entries = {}
    if flat_attack ~= nil and flat_attack ~= 0 then
        entries[#entries + 1] = {
            entry_order = #entries + 1,
            stat_id = 'attack',
            flat_value = flat_attack,
            rate_basis_points = 0,
        }
    end
    if flat_defense ~= nil and flat_defense ~= 0 then
        entries[#entries + 1] = {
            entry_order = #entries + 1,
            stat_id = 'defense',
            flat_value = flat_defense,
            rate_basis_points = 0,
        }
    end
    return {
        id = id,
        schema_version = 1,
        entries = entries,
    }
end

local function affix_attack()
    return {
        id = 'affix_attack_flat',
        schema_version = 1,
        stat_id = 'attack',
        value_mode = 'FLAT',
        exclusive_group = 'power',
        allowed_slots = { 'ACCESSORY', 'BODY', 'HEAD', 'WEAPON' },
        allowed_routes = { 'BLADE', 'NONE', 'STAFF', 'SWORD', 'UNARMED' },
        tiers = {
            { tier = 1, min_value = 1, max_value = 5, step = 1 },
            { tier = 2, min_value = 6, max_value = 10, step = 1 },
        },
        public_snapshot_allowed = true,
    }
end

local function affix_defense()
    return {
        id = 'affix_defense_flat',
        schema_version = 1,
        stat_id = 'defense',
        value_mode = 'FLAT',
        exclusive_group = 'guard',
        allowed_slots = { 'ACCESSORY', 'BODY', 'HEAD', 'WEAPON' },
        allowed_routes = { 'BLADE', 'NONE', 'STAFF', 'SWORD', 'UNARMED' },
        tiers = {
            { tier = 1, min_value = 1, max_value = 3, step = 1 },
        },
        public_snapshot_allowed = true,
    }
end

local function affix_pool_basic()
    return {
        id = 'affixpool_basic',
        schema_version = 1,
        entries = {
            {
                entry_order = 1,
                affix_id = 'affix_attack_flat',
                tier = 1,
                weight = 100,
                rarity_min = 'COMMON',
                rarity_max = 'LEGEND',
            },
            {
                entry_order = 2,
                affix_id = 'affix_defense_flat',
                tier = 1,
                weight = 100,
                rarity_min = 'COMMON',
                rarity_max = 'LEGEND',
            },
        },
    }
end

local function temper_basic()
    return {
        id = 'temper_basic',
        schema_version = 1,
        reroll_mode = 'ONE_SLOT',
        copper_cost_base = 50,
        material_item_id = 'item_temper_dust',
        material_count = 1,
        cost_growth_bp_per_ordinal = 1000,
        max_roll_ordinal_for_cost = 10,
        allow_same_result = false,
    }
end

local function equip_def(overrides)
    local def = {
        id = 'equip_iron_sword',
        schema_version = 1,
        item_id = 'item_equip_iron_sword',
        slot = 'WEAPON',
        weapon_route = 'SWORD',
        weapon_kind = 'SWORD_WEAPON',
        rarity = 'COMMON',
        required_character_level = 1,
        allowed_character_tags = {},
        base_stat_set_id = 'equipstat_iron_sword',
        affix_pool_id = 'affixpool_basic',
        affix_count_min = 1,
        affix_count_max = 2,
        enhancement_track_id = 'enhance_basic',
        temper_rule_id = 'temper_basic',
        appearance_id = 'appearance_iron_sword',
        trade_policy = 'BOUND',
        deprecated = false,
    }
    if overrides ~= nil then
        local key
        local value
        for key, value in pairs(overrides) do
            def[key] = value
        end
    end
    return def
end

local function equip_body()
    local def = equip_def({
        id = 'equip_cloth_robe',
        item_id = 'item_equip_cloth_robe',
        slot = 'BODY',
        weapon_route = 'NONE',
        weapon_kind = 'NONE',
        base_stat_set_id = 'equipstat_cloth_robe',
        affix_count_min = 0,
        affix_count_max = 0,
        appearance_id = 'appearance_cloth_robe',
        required_character_level = 5,
    })
    -- Lua tables drop nil literals; clear optional refs explicitly.
    def.affix_pool_id = nil
    def.temper_rule_id = nil
    return def
end

local function build_catalog(extra)
    local source = {
        base_stat_sets = {
            base_stat('equipstat_iron_sword', 20, 2),
            base_stat('equipstat_cloth_robe', 0, 10),
        },
        affix_definitions = {
            affix_attack(),
            affix_defense(),
        },
        affix_pools = {
            affix_pool_basic(),
        },
        enhancement_tracks = {
            enhance_track('enhance_basic', 3),
        },
        temper_rules = {
            temper_basic(),
        },
        equipment_definitions = {
            equip_def(),
            equip_body(),
        },
    }
    if extra ~= nil then
        local key
        local value
        for key, value in pairs(extra) do
            source[key] = value
        end
    end
    local built = EquipmentCatalog.build(source)
    assert.equal(built.ok, true, built.error and (
        (built.error.details and built.error.details.reason)
        or built.error.code
        or 'catalog_build_failed'
    ))
    return built.value
end

local function prepare_draft(catalog, seed, equipment_id)
    return EquipmentInstance.prepare_instance(
        catalog,
        {
            equipment_id = equipment_id or 'equip_iron_sword',
            origin_type = 'LOOT',
            origin_ref = 'battle.intro.drop',
            creation_ordinal = 0,
            config_version = 1,
        },
        { seed = seed or 42 }
    )
end

local function materialize(catalog, seed, instance_id, equipment_id)
    local draft = prepare_draft(catalog, seed, equipment_id)
    assert.equal(draft.ok, true, draft.error and draft.error.code)
    local instance = EquipmentInstance.from_draft(draft.value, instance_id or 'eqinst_sword_001')
    assert.equal(instance.ok, true, instance.error and instance.error.code)
    return instance.value, draft.value
end

return {
    case('catalog seals equipment definitions and rejects broken references', function()
        local catalog = build_catalog()
        assert.equal(EquipmentCatalog.is_authority(catalog), true)
        assert.equal(catalog:contains('equipment_definitions', 'equip_iron_sword'), true)
        assert.equal(catalog:contains('base_stat_sets', 'equipstat_iron_sword'), true)
        assert.equal(catalog:contains('affix_pools', 'affixpool_basic'), true)
        assert.equal(catalog:contains('enhancement_tracks', 'enhance_basic'), true)
        assert.equal(catalog:contains('temper_rules', 'temper_basic'), true)

        local missing = catalog:require_equipment('equip_missing')
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'EQUIPMENT_UNKNOWN')

        local broken = EquipmentCatalog.build({
            base_stat_sets = {
                base_stat('equipstat_iron_sword', 20),
            },
            affix_definitions = {
                affix_attack(),
            },
            affix_pools = {},
            enhancement_tracks = {
                enhance_track('enhance_basic', 2),
            },
            temper_rules = {},
            equipment_definitions = {
                equip_def({
                    affix_pool_id = 'affixpool_missing',
                    affix_count_min = 1,
                    affix_count_max = 1,
                    temper_rule_id = nil,
                }),
            },
        })
        assert.equal(broken.ok, false)
        assert.equal(broken.error.details.reason, 'REFERENCE_NOT_FOUND')

        local temper = TemperRule.validate(temper_basic())
        assert.equal(temper.ok, true)
        assert.equal(temper.value.reroll_mode, 'ONE_SLOT')
    end),

    case('same seed and source produce identical affix draft', function()
        local catalog = build_catalog()
        local first = prepare_draft(catalog, 12345)
        local second = prepare_draft(catalog, 12345)
        assert.equal(first.ok, true, first.error and first.error.code)
        assert.equal(second.ok, true)
        assert.equal(first.value.draft_hash, second.value.draft_hash)
        assert.equal(first.value.roll_seed_hash, second.value.roll_seed_hash)
        assert.equal(#first.value.affixes, #second.value.affixes)
        local index
        for index = 1, #first.value.affixes do
            local left = first.value.affixes[index]
            local right = second.value.affixes[index]
            assert.equal(left.affix_id, right.affix_id)
            assert.equal(left.tier, right.tier)
            assert.equal(left.rolled_value, right.rolled_value)
            assert.equal(left.slot_index, right.slot_index)
            assert.equal(left.roll_ordinal, 0)
        end
        assert.equal(first.value.enhancement_level, 0)

        local different = prepare_draft(catalog, 99999)
        assert.equal(different.ok, true)
        -- Different seed should usually diverge; hash must not silently match both.
        -- Allow rare collision only if affix payload also matches (still deterministic).
        if different.value.draft_hash == first.value.draft_hash then
            assert.equal(#different.value.affixes, #first.value.affixes)
        end
    end),

    case('equip and unequip enforce slot exclusivity and level gate', function()
        local catalog = build_catalog()
        local sword = materialize(catalog, 7, 'eqinst_sword_001', 'equip_iron_sword')
        local robe_draft = EquipmentInstance.prepare_instance(
            catalog,
            {
                equipment_id = 'equip_cloth_robe',
                origin_type = 'QUEST',
                origin_ref = 'quest.tailor.reward',
                creation_ordinal = 1,
                config_version = 1,
            },
            { seed = 11 }
        )
        assert.equal(robe_draft.ok, true, robe_draft.error and robe_draft.error.code)
        local robe = EquipmentInstance.from_draft(robe_draft.value, 'eqinst_robe_001')
        assert.equal(robe.ok, true)

        local loadout = CharacterLoadout.empty('char_hero')
        assert.equal(loadout.ok, true)
        local instances = {
            eqinst_sword_001 = sword,
            eqinst_robe_001 = robe.value,
        }

        local low = CharacterLoadout.equip(
            loadout.value,
            instances,
            catalog,
            { character_level = 1, weapon_route = 'SWORD', character_tags = {} },
            'eqinst_robe_001'
        )
        assert.equal(low.ok, false)
        assert.equal(low.error.code, 'EQUIPMENT_CHARACTER_LEVEL_TOO_LOW')

        local equipped_sword = CharacterLoadout.equip(
            loadout.value,
            instances,
            catalog,
            { character_level = 10, weapon_route = 'SWORD', character_tags = {} },
            'eqinst_sword_001'
        )
        assert.equal(equipped_sword.ok, true, equipped_sword.error and equipped_sword.error.code)
        assert.equal(equipped_sword.value.loadout.weapon_instance_id, 'eqinst_sword_001')
        assert.equal(
            equipped_sword.value.instances.eqinst_sword_001.owner_character_id,
            'char_hero'
        )
        assert.equal(equipped_sword.value.loadout.loadout_revision, 1)

        local route_mismatch = CharacterLoadout.equip(
            CharacterLoadout.empty('char_hero').value,
            { eqinst_sword_001 = sword },
            catalog,
            { character_level = 10, weapon_route = 'BLADE', character_tags = {} },
            'eqinst_sword_001'
        )
        assert.equal(route_mismatch.ok, false)
        assert.equal(route_mismatch.error.code, 'EQUIPMENT_WEAPON_ROUTE_MISMATCH')

        local equipped_robe = CharacterLoadout.equip(
            equipped_sword.value.loadout,
            equipped_sword.value.instances,
            catalog,
            { character_level = 10, weapon_route = 'SWORD', character_tags = {} },
            'eqinst_robe_001'
        )
        assert.equal(equipped_robe.ok, true, equipped_robe.error and equipped_robe.error.code)
        assert.equal(equipped_robe.value.loadout.body_instance_id, 'eqinst_robe_001')
        assert.equal(equipped_robe.value.loadout.weapon_instance_id, 'eqinst_sword_001')

        local unequipped = CharacterLoadout.unequip(
            equipped_robe.value.loadout,
            equipped_robe.value.instances,
            'WEAPON'
        )
        assert.equal(unequipped.ok, true)
        assert.equal(unequipped.value.loadout.weapon_instance_id, nil)
        assert.equal(unequipped.value.instances.eqinst_sword_001.owner_character_id, nil)
        assert.equal(unequipped.value.loadout.body_instance_id, 'eqinst_robe_001')

        local empty_slot = CharacterLoadout.unequip(
            unequipped.value.loadout,
            unequipped.value.instances,
            'WEAPON'
        )
        assert.equal(empty_slot.ok, false)
        assert.equal(empty_slot.error.code, 'EQUIPMENT_SLOT_EMPTY')
    end),

    case('calculate_contributions is deterministic and canonical', function()
        local catalog = build_catalog()
        local sword = materialize(catalog, 42, 'eqinst_sword_001', 'equip_iron_sword')
        local enhanced = EnhancementPolicy.enhance(sword, catalog)
        assert.equal(enhanced.ok, true, enhanced.error and enhanced.error.code)
        sword = enhanced.value.instance
        assert.equal(sword.enhancement_level, 1)

        local loadout = CharacterLoadout.empty('char_hero')
        assert.equal(loadout.ok, true)
        local equipped = CharacterLoadout.equip(
            loadout.value,
            { eqinst_sword_001 = sword },
            catalog,
            { character_level = 10, weapon_route = 'SWORD', character_tags = {} },
            'eqinst_sword_001'
        )
        assert.equal(equipped.ok, true)

        local first = StatResolver.calculate_contributions(
            equipped.value.loadout,
            equipped.value.instances,
            catalog
        )
        local second = StatResolver.calculate_contributions(
            equipped.value.loadout,
            equipped.value.instances,
            catalog
        )
        assert.equal(first.ok, true, first.error and first.error.code)
        assert.equal(second.ok, true)
        assert.equal(#first.value, #second.value)
        assert.truthy(#first.value >= 1)

        local index
        for index = 1, #first.value do
            local contrib = first.value[index]
            assert.equal(contrib.source_type, 'EQUIPMENT')
            local validated = StatContribution.validate(contrib)
            assert.equal(validated.ok, true, validated.error and validated.error.code)
            assert.equal(contrib.stable_order_key, second.value[index].stable_order_key)
            assert.equal(contrib.value, second.value[index].value)
            if index > 1 then
                local prev = first.value[index - 1]
                -- Priorities must be non-decreasing after sort.
                assert.truthy(prev.priority <= contrib.priority)
            end
        end

        -- base attack 20, enhance +500bp => floor(20*10500/10000)=21, enhance delta=1
        local found_base = false
        local found_enhance = false
        for index = 1, #first.value do
            local c = first.value[index]
            if c.source_id == 'eqinst_sword_001:base' and c.target_stat == 'attack' and c.operation == 'ADD_FLAT' then
                assert.equal(c.value, 20)
                found_base = true
            end
            if c.source_id == 'eqinst_sword_001:enhance' and c.target_stat == 'attack' then
                assert.equal(c.value, 1)
                found_enhance = true
            end
        end
        assert.equal(found_base, true)
        assert.equal(found_enhance, true)
    end),

    case('enhance to max level is rejected and planned_cost is returned before max', function()
        local catalog = build_catalog()
        local sword = materialize(catalog, 3, 'eqinst_sword_max', 'equip_iron_sword')
        assert.equal(sword.enhancement_level, 0)

        local step1 = EnhancementPolicy.enhance(sword, catalog)
        assert.equal(step1.ok, true, step1.error and step1.error.code)
        assert.equal(step1.value.to_level, 1)
        assert.equal(step1.value.planned_cost.copper_cost, 100)
        assert.equal(step1.value.planned_cost.material_item_id, 'item_enhance_stone')
        assert.equal(step1.value.planned_cost.material_count, 1)
        assert.equal(step1.value.instance.enhancement_level, 1)

        local step2 = EnhancementPolicy.enhance(step1.value.instance, catalog)
        assert.equal(step2.ok, true)
        assert.equal(step2.value.planned_cost.copper_cost, 200)

        local step3 = EnhancementPolicy.enhance(step2.value.instance, catalog)
        assert.equal(step3.ok, true)
        assert.equal(step3.value.instance.enhancement_level, 3)

        local over = EnhancementPolicy.enhance(step3.value.instance, catalog)
        assert.equal(over.ok, false)
        assert.equal(over.error.code, 'EQUIPMENT_ENHANCE_MAX_LEVEL')

        local plan = EnhancementPolicy.plan_enhance(step3.value.instance, catalog)
        assert.equal(plan.ok, false)
        assert.equal(plan.error.code, 'EQUIPMENT_ENHANCE_MAX_LEVEL')
    end),

    case('equipment save codec round-trips instances loadouts and affixes', function()
        local catalog = build_catalog()
        local sword = materialize(catalog, 11, 'eqinst_sword_save', 'equip_iron_sword')
        sword.owner_character_id = 'char_hero'
        sword.instance_revision = 2
        local loadout = CharacterLoadout.empty('char_hero')
        assert.equal(loadout.ok, true)
        loadout = loadout.value
        loadout.weapon_instance_id = 'eqinst_sword_save'
        loadout.loadout_revision = 1

        local encoded = EquipmentSaveCodec.encode({
            equipment_save_revision = 4,
            instances = { sword },
            loadouts = { loadout },
            tombstones = {},
        })
        assert.equal(encoded.ok, true, encoded.error and encoded.error.details and encoded.error.details.reason)
        assert.equal(#encoded.value.equipment_instance_rows, 1)
        assert.equal(#encoded.value.equipment_affix_rows >= 1, true)
        assert.equal(#encoded.value.character_loadout_rows, 1)
        assert.equal(#encoded.value.equipment_tombstone_rows, 0)

        local decoded = EquipmentSaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true, decoded.error and decoded.error.details and decoded.error.details.reason)
        assert.equal(decoded.value.equipment_save_revision, 4)
        assert.equal(decoded.value.instances[1].instance_id, 'eqinst_sword_save')
        assert.equal(decoded.value.instances[1].owner_character_id, 'char_hero')
        assert.equal(#decoded.value.instances[1].affixes, #sword.affixes)
        assert.equal(decoded.value.loadouts[1].weapon_instance_id, 'eqinst_sword_save')
    end),

    case('section registrar installs slot-4 equipment and slot-5 receipt sections', function()
        local owners = SectionOwnerRegistry.new()
        assert.equal(owners.ok, true)
        local registered = EquipmentSectionRegistrar.register({
            system_id = '08',
            section_owners = owners.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 8)
        local meta = owners.value:get('equipment_metadata')
        assert.equal(meta.ok, true)
        assert.equal(meta.value.slot_id, 4)
        assert.equal(meta.value.owner_system, '08')
        local receipts = owners.value:get('equipment_operation_receipts')
        assert.equal(receipts.ok, true)
        assert.equal(receipts.value.slot_id, 5)
        assert.equal(receipts.value.owner_system, '08')
    end),

    case('equipment service checkpoints create and equip then hydrate resumes loadout', function()
        local catalog = build_catalog()
        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)
        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)

        local store = FakeEquipmentStore.new()
        assert.equal(store.ok, true)
        local bridge = EquipmentSaveBridge.bind({
            store = store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 808001,
        })
        assert.equal(bridge.ok, true)
        local service = EquipmentService.bind({
            catalog = catalog,
            store = store.value,
            save_bridge = bridge.value,
        })
        assert.equal(service.ok, true)

        local created = service.value:create_instance({
            equipment_id = 'equip_iron_sword',
            origin_type = 'LOOT',
            origin_ref = 'battle.intro.drop',
            creation_ordinal = 0,
            config_version = 1,
            seed = 55,
            instance_id = 'eqinst_sword_persist',
            player_save_scope = 'player_equip_001',
            request_id = 'request_equip_create',
            command_id = 'cmd_equip_create',
        })
        assert.equal(created.ok, true, created.error and created.error.code)
        assert.equal(created.value.save.status, 'COMMITTED')
        assert.equal(created.value.save.created_save, true)

        local equipped = service.value:equip({
            character_id = 'char_hero',
            instance_id = 'eqinst_sword_persist',
            character_context = {
                character_level = 10,
                weapon_route = 'SWORD',
                character_tags = {},
            },
            player_save_scope = 'player_equip_001',
            request_id = 'request_equip_wear',
            command_id = 'cmd_equip_wear',
        })
        assert.equal(equipped.ok, true, equipped.error and equipped.error.code)
        assert.equal(equipped.value.slot, 'WEAPON')
        assert.equal(equipped.value.save.status, 'COMMITTED')
        assert.equal(equipped.value.loadout.weapon_instance_id, 'eqinst_sword_persist')

        local loaded = load.value:load({
            player_ref = 'player_equip_001',
            session_instance_id = 'session_equip_1',
            request_id = 'request_load_equip_1',
        }, invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(
            #loaded.value.loaded_envelopes[4].payload.equipment_instance_rows,
            1
        )
        assert.equal(
            loaded.value.loaded_envelopes[4].payload.character_loadout_rows[1].weapon_instance_id,
            'eqinst_sword_persist'
        )

        local fresh_store = FakeEquipmentStore.new()
        assert.equal(fresh_store.ok, true)
        local hydrate = HydrateGameRuntime.bind({})
        assert.equal(hydrate.ok, true)
        local hydrated = hydrate.value:hydrate({
            load_result = loaded.value,
            player_save_scope = 'player_equip_001',
            targets = {
                equipment_store = fresh_store.value,
            },
        })
        assert.equal(hydrated.ok, true, hydrated.error and hydrated.error.code)
        local equipment_status
        local index
        for index = 1, #hydrated.value.systems do
            if hydrated.value.systems[index].system_id == 'equipment' then
                equipment_status = hydrated.value.systems[index].status
            end
        end
        assert.equal(equipment_status, 'HYDRATED')

        local resumed = EquipmentService.bind({
            catalog = catalog,
            store = fresh_store.value,
        })
        assert.equal(resumed.ok, true)
        local loadout = resumed.value:get_loadout('char_hero')
        assert.equal(loadout.ok, true)
        assert.equal(loadout.value.weapon_instance_id, 'eqinst_sword_persist')
        assert.equal(loadout.value.loadout_revision >= 1, true)

        local instance = resumed.value:get_instance('eqinst_sword_persist')
        assert.equal(instance.ok, true)
        assert.equal(instance.value.owner_character_id, 'char_hero')
        assert.equal(instance.value.equipment_id, 'equip_iron_sword')

        local unequipped = resumed.value:unequip({
            character_id = 'char_hero',
            slot = 'WEAPON',
        })
        assert.equal(unequipped.ok, true)
        assert.equal(unequipped.value.save.status, 'SKIPPED')
        assert.equal(
            resumed.value:get_loadout('char_hero').value.weapon_instance_id,
            nil
        )
    end),

    case('enhance debits copper and material with receipt idempotency and hydrate', function()
        local catalog = build_catalog()

        local currency_catalog = CurrencyCatalog.build({
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
            },
        })
        assert.equal(currency_catalog.ok, true)
        local reward_catalog = RewardCatalog.build({
            reward_bundles = {
                {
                    id = 'reward_fund_copper',
                    schema_version = 1,
                    entries = {
                        {
                            entry_order = 1,
                            entry_type = 'CURRENCY',
                            target_id = 'currency_copper',
                            quantity_min = 500,
                            quantity_max = 500,
                        },
                    },
                },
            },
        })
        assert.equal(reward_catalog.ok, true)
        local economy_store = FakeEconomyStore.new()
        assert.equal(economy_store.ok, true)
        local economy = EconomyService.bind({
            currency_catalog = currency_catalog.value,
            reward_catalog = reward_catalog.value,
            store = economy_store.value,
        })
        assert.equal(economy.ok, true)

        local item_catalog = ItemCatalog.build({
            item_definitions = {
                {
                    id = 'item_enhance_stone',
                    schema_version = 1,
                    category = 'MATERIAL',
                    name_key = 'item.enhance_stone.name',
                    max_stack = 99,
                    ownership_cap = 999,
                    rarity = 'COMMON',
                },
            },
        })
        assert.equal(item_catalog.ok, true)
        local inventory_store = FakeInventoryStore.new()
        assert.equal(inventory_store.ok, true)
        local inventory = InventoryService.bind({
            item_catalog = item_catalog.value,
            store = inventory_store.value,
        })
        assert.equal(inventory.ok, true)

        local funded = economy.value:prepare_reward({
            reward_id = 'reward_fund_copper',
            source_type = 'QUEST',
            source_ref = 'reward_fund_copper',
            source_occurrence_id = 'quest_fund_enhance_001',
        })
        assert.equal(funded.ok, true)
        local granted = economy.value:grant_prepared_reward({
            prepared = funded.value,
            receipt_id = make_receipt_id('fund_enhance_copper'),
            purpose_type = 'QUEST_REWARD',
            purpose_ref = 'quest_fund_enhance',
        })
        assert.equal(granted.ok, true, granted.error and granted.error.code)
        local stones = inventory.value:grant_items({
            grants = { { item_id = 'item_enhance_stone', amount = 10 } },
        })
        assert.equal(stones.ok, true, stones.error and stones.error.code)

        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)
        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)

        local equip_store = FakeEquipmentStore.new()
        assert.equal(equip_store.ok, true)
        local bridge = EquipmentSaveBridge.bind({
            store = equip_store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 808002,
        })
        assert.equal(bridge.ok, true)
        local service = EquipmentService.bind({
            catalog = catalog,
            store = equip_store.value,
            save_bridge = bridge.value,
            economy_service = economy.value,
            inventory_service = inventory.value,
        })
        assert.equal(service.ok, true)

        local created = service.value:create_instance({
            equipment_id = 'equip_iron_sword',
            origin_type = 'LOOT',
            origin_ref = 'battle.intro.drop',
            creation_ordinal = 0,
            config_version = 1,
            seed = 77,
            instance_id = 'eqinst_sword_enhance',
            player_save_scope = 'player_enhance_001',
            request_id = 'request_enhance_create',
            command_id = 'cmd_enhance_create',
            skip_save = true,
        })
        assert.equal(created.ok, true, created.error and created.error.code)

        local receipt_id = make_receipt_id('enhance_once')
        local enhanced = service.value:enhance({
            instance_id = 'eqinst_sword_enhance',
            receipt_id = receipt_id,
            player_chapter = 1,
            player_save_scope = 'player_enhance_001',
            request_id = 'request_enhance_1',
            command_id = 'cmd_enhance_1',
        })
        assert.equal(enhanced.ok, true, enhanced.error and enhanced.error.code)
        assert.equal(enhanced.value.status, 'COMMITTED')
        assert.equal(enhanced.value.already_committed, false)
        assert.equal(enhanced.value.from_level, 0)
        assert.equal(enhanced.value.to_level, 1)
        assert.equal(enhanced.value.planned_cost.copper_cost, 100)
        assert.equal(enhanced.value.planned_cost.material_count, 1)
        assert.equal(enhanced.value.instance.enhancement_level, 1)
        assert.equal(enhanced.value.save.status, 'COMMITTED')
        assert.equal(enhanced.value.save.slot5_revision ~= nil, true)

        local copper = economy.value:get_balance('currency_copper')
        assert.equal(copper.ok, true)
        assert.equal(copper.value.balance, 400)
        local stone_count = inventory.value:get_count('item_enhance_stone')
        assert.equal(stone_count.ok, true)
        assert.equal(stone_count.value.count, 9)

        local replay = service.value:enhance({
            instance_id = 'eqinst_sword_enhance',
            receipt_id = receipt_id,
            player_chapter = 1,
            player_save_scope = 'player_enhance_001',
            request_id = 'request_enhance_1_replay',
            command_id = 'cmd_enhance_1_replay',
        })
        assert.equal(replay.ok, true, replay.error and replay.error.code)
        assert.equal(replay.value.already_committed, true)
        copper = economy.value:get_balance('currency_copper')
        assert.equal(copper.value.balance, 400)
        stone_count = inventory.value:get_count('item_enhance_stone')
        assert.equal(stone_count.value.count, 9)
        assert.equal(
            service.value:get_instance('eqinst_sword_enhance').value.enhancement_level,
            1
        )

        local receipt_bundle = equip_store.value:export_receipt_bundle()
        assert.equal(receipt_bundle.ok, true)
        local decoded = EquipmentReceiptCodec.decode(receipt_bundle.value)
        assert.equal(decoded.ok, true, decoded.error and decoded.error.details and decoded.error.details.reason)
        assert.equal(decoded.value.receipts[receipt_id] ~= nil, true)
        assert.equal(decoded.value.receipts[receipt_id].to_level, 1)

        local loaded = load.value:load({
            player_ref = 'player_enhance_001',
            session_instance_id = 'session_enhance_1',
            request_id = 'request_load_enhance_1',
        }, invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(
            loaded.value.loaded_envelopes[4].payload.equipment_instance_rows[1].enhancement_level,
            1
        )
        assert.equal(
            #loaded.value.loaded_envelopes[5].payload.equipment_operation_receipts,
            1
        )

        local fresh_store = FakeEquipmentStore.new()
        assert.equal(fresh_store.ok, true)
        local hydrate = HydrateGameRuntime.bind({})
        assert.equal(hydrate.ok, true)
        local hydrated = hydrate.value:hydrate({
            load_result = loaded.value,
            player_save_scope = 'player_enhance_001',
            targets = {
                equipment_store = fresh_store.value,
            },
        })
        assert.equal(hydrated.ok, true, hydrated.error and hydrated.error.code)

        local resumed = EquipmentService.bind({
            catalog = catalog,
            store = fresh_store.value,
            economy_service = economy.value,
            inventory_service = inventory.value,
        })
        assert.equal(resumed.ok, true)
        local resumed_instance = resumed.value:get_instance('eqinst_sword_enhance')
        assert.equal(resumed_instance.ok, true)
        assert.equal(resumed_instance.value.enhancement_level, 1)
        local resumed_receipt = fresh_store.value:get_receipt(receipt_id)
        assert.equal(resumed_receipt.ok, true)
        assert.equal(resumed_receipt.value ~= nil, true)
        assert.equal(resumed_receipt.value.to_level, 1)

        -- Same receipt on hydrated store returns already_committed without re-debit.
        local replay_after_hydrate = resumed.value:enhance({
            instance_id = 'eqinst_sword_enhance',
            receipt_id = receipt_id,
            player_chapter = 1,
            skip_save = true,
        })
        assert.equal(replay_after_hydrate.ok, true)
        assert.equal(replay_after_hydrate.value.already_committed, true)
        copper = economy.value:get_balance('currency_copper')
        assert.equal(copper.value.balance, 400)
    end),

    case('enhance rejects insufficient copper before mutating instance', function()
        local catalog = build_catalog()
        local currency_catalog = CurrencyCatalog.build({
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
            },
        })
        assert.equal(currency_catalog.ok, true)
        local reward_catalog = RewardCatalog.build({
            reward_bundles = {},
        })
        assert.equal(reward_catalog.ok, true)
        local economy = EconomyService.bind({
            currency_catalog = currency_catalog.value,
            reward_catalog = reward_catalog.value,
            store = FakeEconomyStore.new().value,
        })
        assert.equal(economy.ok, true)
        local inventory = InventoryService.bind({
            item_catalog = ItemCatalog.build({
                item_definitions = {
                    {
                        id = 'item_enhance_stone',
                        schema_version = 1,
                        category = 'MATERIAL',
                        name_key = 'item.enhance_stone.name',
                        max_stack = 99,
                        ownership_cap = 999,
                    },
                },
            }).value,
            store = FakeInventoryStore.new().value,
        })
        assert.equal(inventory.ok, true)
        assert.equal(inventory.value:grant_items({
            grants = { { item_id = 'item_enhance_stone', amount = 5 } },
        }).ok, true)

        local equip_store = FakeEquipmentStore.new()
        assert.equal(equip_store.ok, true)
        local service = EquipmentService.bind({
            catalog = catalog,
            store = equip_store.value,
            economy_service = economy.value,
            inventory_service = inventory.value,
        })
        assert.equal(service.ok, true)
        assert.equal(service.value:create_instance({
            equipment_id = 'equip_iron_sword',
            origin_type = 'LOOT',
            origin_ref = 'battle.intro.drop',
            creation_ordinal = 0,
            config_version = 1,
            seed = 9,
            instance_id = 'eqinst_sword_poor',
            skip_save = true,
        }).ok, true)

        local failed = service.value:enhance({
            instance_id = 'eqinst_sword_poor',
            receipt_id = make_receipt_id('enhance_poor'),
            player_chapter = 1,
            skip_save = true,
        })
        assert.equal(failed.ok, false)
        assert.equal(failed.error.code, 'ECONOMY_CURRENCY_INSUFFICIENT')
        assert.equal(
            service.value:get_instance('eqinst_sword_poor').value.enhancement_level,
            0
        )
        assert.equal(inventory.value:get_count('item_enhance_stone').value.count, 5)
    end),
}
