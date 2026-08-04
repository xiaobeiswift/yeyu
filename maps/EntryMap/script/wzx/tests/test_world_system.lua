local Harness = require 'wzx.tests.harness'
local DomainEvent = require 'wzx.domain.common.domain_event'
local WorldCatalog = require 'wzx.config.schema.world.catalog'
local WorldSectionRegistrar = require 'wzx.config.schema.world.section_registrar'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local WorldState = require 'wzx.domain.world.world_state'
local WorldSaveCodec = require 'wzx.domain.world.world_save_codec'
local WorldService = require 'wzx.application.use_cases.world.world_service'
local WorldQuestBridge = require 'wzx.application.use_cases.world.world_quest_bridge'
local FakeWorldStore = require 'wzx.adapters.fake.world.fake_world_store'
local QuestCatalog = require 'wzx.config.schema.quest.catalog'
local QuestService = require 'wzx.application.use_cases.quest.quest_service'

local case = Harness.case
local assert = Harness.assert

local function fixture_world_source(mutate)
    local source = {
        flag_definitions = {
            {
                id = 'flag_bridge_repaired',
                schema_version = 1,
                rules_version = 1,
                value_type = 'BOOLEAN',
                default_value = false,
                description_key = 'flag.bridge_repaired',
            },
            {
                id = 'flag_inn_trust',
                schema_version = 1,
                rules_version = 1,
                value_type = 'INTEGER',
                default_value = 0,
            },
        },
        location_definitions = {
            {
                id = 'location_wutan_gate',
                schema_version = 1,
                rules_version = 1,
                area_id = 'area_wutan',
                name_key = 'location.wutan_gate',
                discovery_marker_id = 'marker_wutan_gate',
                safe_return_marker_id = 'marker_wutan_gate',
                neighbor_location_ids = { 'location_wutan_inn' },
                map_sort_order = 10,
            },
            {
                id = 'location_wutan_inn',
                schema_version = 1,
                rules_version = 1,
                area_id = 'area_wutan',
                name_key = 'location.wutan_inn',
                discovery_marker_id = 'marker_wutan_inn',
                safe_return_marker_id = 'marker_wutan_inn',
                neighbor_location_ids = { 'location_wutan_gate' },
                map_sort_order = 20,
            },
            {
                id = 'location_mist_ridge',
                schema_version = 1,
                rules_version = 1,
                area_id = 'area_mist_road',
                name_key = 'location.mist_ridge',
                discovery_marker_id = 'marker_mist_ridge',
                safe_return_marker_id = 'marker_mist_ridge',
                map_sort_order = 30,
            },
        },
        area_definitions = {
            {
                id = 'area_wutan',
                schema_version = 1,
                rules_version = 1,
                area_type = 'TOWN',
                name_key = 'area.wutan',
                location_ids = {
                    'location_wutan_gate',
                    'location_wutan_inn',
                },
                entry_marker_id = 'marker_wutan_gate',
            },
            {
                id = 'area_mist_road',
                schema_version = 1,
                rules_version = 1,
                area_type = 'WILDERNESS',
                name_key = 'area.mist_road',
                location_ids = { 'location_mist_ridge' },
                entry_marker_id = 'marker_mist_ridge',
            },
        },
    }
    if mutate ~= nil then
        mutate(source)
    end
    return source
end

local function seal_world(mutate)
    return WorldCatalog.seal(fixture_world_source(mutate))
end

local function seal_quest_reach()
    return QuestCatalog.seal({
        objective_definitions = {
            {
                id = 'objective_reach_ridge',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_side_01',
                objective_type = 'REACH_LOCATION',
                target_id = 'location_mist_ridge',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'LocationDiscovered',
                description_key = 'obj.reach_ridge.desc',
                completed_key = 'obj.reach_ridge.done',
            },
        },
        stage_definitions = {
            {
                id = 'stage_side_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_side_scout',
                objective_ids = { 'objective_reach_ridge' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.side_01',
            },
        },
        quest_definitions = {
            {
                id = 'quest_side_scout',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'SIDE',
                chapter_id = 'chapter_01',
                title_key = 'quest.side_scout.title',
                summary_key = 'quest.side_scout.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_guide_chen',
                first_stage_id = 'stage_side_01',
                stage_ids = { 'stage_side_01' },
                reward_policy = 'NO_REWARD',
                abandon_policy = 'ALLOW_RESET_RUN',
                journal_sort_order = 30,
            },
        },
    })
end

return {
    case('catalog seals areas locations and flags with cross refs', function()
        local sealed = seal_world()
        assert.equal(sealed.ok, true, 'seal')
        local area = sealed.value:require_area('area_wutan')
        assert.equal(area.ok, true)
        assert.equal(#area.value.location_ids, 2)
        local location = sealed.value:require_location('location_wutan_inn')
        assert.equal(location.ok, true)
        assert.equal(location.value.area_id, 'area_wutan')
        local flag = sealed.value:require_flag('flag_bridge_repaired')
        assert.equal(flag.ok, true)
        assert.equal(flag.value.default_value, false)
    end),

    case('catalog rejects location area mismatch', function()
        local sealed = seal_world(function(source)
            source.location_definitions[1].area_id = 'area_mist_road'
        end)
        assert.equal(sealed.ok, false)
        assert.equal(sealed.error.details.reason, 'LOCATION_AREA_MISMATCH')
    end),

    case('discover location publishes durable event and updates position', function()
        local sealed = seal_world()
        assert.equal(sealed.ok, true)
        local state = WorldState.empty()
        WorldState.bootstrap_position(state, sealed.value, {
            location_id = 'location_wutan_gate',
        })

        local discovered = WorldState.discover_location(state, sealed.value, {
            location_id = 'location_mist_ridge',
            discovery_receipt_id = 'rcpt_discover_ridge_01',
            command_id = 'cmd_discover_ridge_01',
        })
        assert.equal(discovered.ok, true, 'discover')
        assert.equal(discovered.value.already_discovered, false)
        assert.truthy(discovered.value.discovery_event)
        assert.equal(discovered.value.discovery_event.event_type, 'LocationDiscovered')
        assert.equal(
            discovered.value.discovery_event.payload.location_id,
            'location_mist_ridge'
        )
        assert.equal(DomainEvent.validate(discovered.value.discovery_event).ok, true)
        assert.equal(discovered.value.position.location_id, 'location_mist_ridge')
        assert.equal(state.discovered.location_mist_ridge ~= nil, true)

        local again = WorldState.discover_location(state, sealed.value, {
            location_id = 'location_mist_ridge',
            discovery_receipt_id = 'rcpt_discover_ridge_02',
        })
        assert.equal(again.ok, true)
        assert.equal(again.value.already_discovered, true)
        assert.equal(again.value.discovery_event, nil)
    end),

    case('set flag publishes WorldFlagChanged and rejects type mismatch', function()
        local sealed = seal_world()
        local state = WorldState.empty()
        local set = WorldState.set_flag(state, sealed.value, {
            flag_id = 'flag_bridge_repaired',
            value = true,
            flag_receipt_id = 'rcpt_flag_bridge_01',
            reason = 'QUEST_RESULT',
        })
        assert.equal(set.ok, true)
        assert.equal(set.value.old_value, false)
        assert.equal(set.value.new_value, true)
        assert.equal(set.value.flag_event.event_type, 'WorldFlagChanged')
        assert.equal(DomainEvent.validate(set.value.flag_event).ok, true)

        local bad = WorldState.set_flag(state, sealed.value, {
            flag_id = 'flag_bridge_repaired',
            value = 1,
            flag_receipt_id = 'rcpt_flag_bridge_bad',
        })
        assert.equal(bad.ok, false)
        assert.equal(bad.error.code, 'WORLD_FLAG_TYPE_MISMATCH')

        local same = WorldState.set_flag(state, sealed.value, {
            flag_id = 'flag_bridge_repaired',
            value = true,
            flag_receipt_id = 'rcpt_flag_bridge_02',
        })
        assert.equal(same.ok, true)
        assert.equal(same.value.unchanged, true)
        assert.equal(same.value.flag_event, nil)
    end),

    case('save codec round-trips position discovered and flags', function()
        local sealed = seal_world()
        local state = WorldState.empty()
        WorldState.bootstrap_position(state, sealed.value, {
            location_id = 'location_wutan_gate',
        })
        WorldState.discover_location(state, sealed.value, {
            location_id = 'location_wutan_inn',
            discovery_receipt_id = 'rcpt_discover_inn_01',
        })
        WorldState.set_flag(state, sealed.value, {
            flag_id = 'flag_inn_trust',
            value = 3,
            flag_receipt_id = 'rcpt_flag_trust_01',
        })

        local encoded = WorldSaveCodec.encode(state)
        assert.equal(encoded.ok, true, 'encode')
        assert.equal(#encoded.value.world_discovered_locations, 1)
        assert.equal(#encoded.value.world_flags, 1)
        local decoded = WorldSaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true, 'decode')
        assert.equal(decoded.value.position.location_id, 'location_wutan_inn')
        assert.equal(decoded.value.discovered.location_wutan_inn ~= nil, true)
        assert.equal(decoded.value.flags.flag_inn_trust, 3)
    end),

    case('section registrar installs slot-2 world sections', function()
        local owners = SectionOwnerRegistry.new()
        assert.equal(owners.ok, true)
        local registered = WorldSectionRegistrar.register({
            system_id = '12',
            section_owners = owners.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 5)
        local section = owners.value:get('world_position')
        assert.equal(section.ok, true)
        assert.equal(section.value.owner_system, '12')
        assert.equal(section.value.slot_id, 2)
    end),

    case('service with store discovers and persists', function()
        local sealed = seal_world()
        local store = FakeWorldStore.new()
        assert.equal(store.ok, true)
        local service = WorldService.bind({
            catalog = sealed.value,
            world_store = store.value,
        })
        assert.equal(service.ok, true)

        local boot = service.value:bootstrap_position({
            location_id = 'location_wutan_gate',
        })
        assert.equal(boot.ok, true)

        local discovered = service.value:discover_location({
            location_id = 'location_mist_ridge',
            discovery_receipt_id = 'rcpt_svc_discover_01',
            command_id = 'cmd_svc_discover_01',
        })
        assert.equal(discovered.ok, true)
        assert.equal(discovered.value.persisted, true)
        assert.equal(discovered.value.discovery_event.payload.area_id, 'area_mist_road')

        local is_found = service.value:is_discovered('location_mist_ridge')
        assert.equal(is_found.ok, true)
        assert.equal(is_found.value, true)

        local reloaded = store.value:get_state()
        assert.equal(reloaded.ok, true)
        assert.equal(reloaded.value.position.location_id, 'location_mist_ridge')
    end),

    case('bridge discovery advances quest REACH_LOCATION objective', function()
        local world_sealed = seal_world()
        local quest_sealed = seal_quest_reach()
        assert.equal(world_sealed.ok, true)
        assert.equal(quest_sealed.ok, true)

        local world = WorldService.bind({ catalog = world_sealed.value })
        local quest = QuestService.bind({ catalog = quest_sealed.value })
        assert.equal(world.ok, true)
        assert.equal(quest.ok, true)

        quest.value:accept({
            quest_id = 'quest_side_scout',
            run_id = 'qrun_scout_01',
            accept_receipt_id = 'rcpt_accept_scout_01',
        })

        local bundled = WorldQuestBridge.discover_and_relay(
            world.value,
            quest.value,
            {
                location_id = 'location_mist_ridge',
                discovery_receipt_id = 'rcpt_discover_scout_01',
            }
        )
        assert.equal(bundled.ok, true, 'discover_and_relay')
        assert.equal(bundled.value.quest_relay.applied, true)

        local run_view = quest.value:get_run('qrun_scout_01')
        assert.equal(run_view.ok, true)
        assert.equal(run_view.value.run.status, 'READY_TO_TURN_IN')
        assert.equal(run_view.value.objectives[1].status, 'COMPLETE')

        local again = WorldQuestBridge.relay_discovery(
            quest.value,
            bundled.value.discover
        )
        assert.equal(again.ok, true)
        assert.equal(again.value.duplicate, true)
        assert.equal(again.value.applied, false)
    end),
}
