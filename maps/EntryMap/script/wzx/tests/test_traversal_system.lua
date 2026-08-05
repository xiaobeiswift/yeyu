local Harness = require 'wzx.tests.harness'
local TraversalCatalog = require 'wzx.config.schema.traversal.catalog'
local Reachability = require 'wzx.domain.traversal.reachability'
local TraversalRuntime = require 'wzx.domain.traversal.runtime'
local TraversalService = require 'wzx.application.use_cases.traversal.traversal_service'
local TraversalQuestBridge = require 'wzx.application.use_cases.traversal.traversal_quest_bridge'
local TraversalErrorCodes = require 'wzx.domain.traversal.error_codes'
local LightnessTraversalProfile = require 'wzx.domain.contracts.lightness_traversal_profile'
local WorldCatalog = require 'wzx.config.schema.world.catalog'
local WorldService = require 'wzx.application.use_cases.world.world_service'
local WorldSaveBridge = require 'wzx.application.use_cases.world.world_save_bridge'
local WorldState = require 'wzx.domain.world.world_state'
local WorldSaveCodec = require 'wzx.domain.world.world_save_codec'
local FakeWorldStore = require 'wzx.adapters.fake.world.fake_world_store'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local RecoveryJournal = require 'wzx.domain.save.recovery_journal'
local QuestCatalog = require 'wzx.config.schema.quest.catalog'
local QuestService = require 'wzx.application.use_cases.quest.quest_service'

local case = Harness.case
local assert = Harness.assert

local function profile_fixture(mutate)
    local profile = {
        character_id = 'char_hero',
        source_martial_id = 'martial_light_step',
        source_martial_level = 2,
        source_loadout_revision = 3,
        source_progress_revision = 5,
        rules_version = 1,
        capability_specs = {
            {
                capability_id = 'JUMP_BASIC',
                rank = 1,
                jump_range_cells = 2,
                water_range_cells = 0,
                max_rise_levels = 1,
                max_drop_levels = 1,
                max_route_cost = 2,
                movement_speed_bp = 10000,
            },
            {
                capability_id = 'JUMP_LONG',
                rank = 1,
                jump_range_cells = 4,
                water_range_cells = 0,
                max_rise_levels = 1,
                max_drop_levels = 2,
                max_route_cost = 4,
                movement_speed_bp = 10000,
            },
            {
                capability_id = 'WATER_WALK',
                rank = 1,
                jump_range_cells = 0,
                water_range_cells = 5,
                max_rise_levels = 0,
                max_drop_levels = 0,
                max_route_cost = 0,
                movement_speed_bp = 8000,
            },
        },
        range_query_radius_cells = 5,
        presentation_profile_id = 'traversal_presentation_ground',
        profile_hash = string.rep('a', 64),
    }
    if mutate ~= nil then
        mutate(profile)
    end
    local validated = LightnessTraversalProfile.validate(profile)
    assert.equal(validated.ok, true, 'profile fixture must validate')
    return validated.value
end

local function catalog_source()
    return {
        spatial_revision = 7,
        grid_id = 'traversal_grid_demo',
        cell_definitions = {
            {
                id = 'traversal_cell_a1',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                x = 0,
                y = 0,
                layer = 0,
                height_level = 0,
                surface_type = 'GROUND',
                landing_safety = 'SAFE_GROUND',
                safe_marker_id = 'marker_a1',
                world_anchor_cm_x = 0,
                world_anchor_cm_y = 0,
                world_anchor_cm_z = 0,
            },
            {
                id = 'traversal_cell_b1',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                x = 2,
                y = 0,
                layer = 0,
                height_level = 0,
                surface_type = 'GROUND',
                landing_safety = 'SAFE_GROUND',
                safe_marker_id = 'marker_b1',
                world_anchor_cm_x = 200,
                world_anchor_cm_y = 0,
                world_anchor_cm_z = 0,
            },
            {
                id = 'traversal_cell_c1',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                x = 3,
                y = 0,
                layer = 0,
                height_level = 2,
                surface_type = 'GROUND',
                landing_safety = 'SAFE_GROUND',
                safe_marker_id = 'marker_c1',
                world_anchor_cm_x = 300,
                world_anchor_cm_y = 0,
                world_anchor_cm_z = 200,
            },
            {
                id = 'traversal_cell_far',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                x = 8,
                y = 0,
                layer = 0,
                height_level = 0,
                surface_type = 'GROUND',
                landing_safety = 'SAFE_GROUND',
                safe_marker_id = 'marker_far',
                world_anchor_cm_x = 800,
                world_anchor_cm_y = 0,
                world_anchor_cm_z = 0,
            },
            {
                id = 'traversal_cell_hidden',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                x = 1,
                y = 2,
                layer = 0,
                height_level = 0,
                surface_type = 'GROUND',
                landing_safety = 'SAFE_GROUND',
                safe_marker_id = 'marker_hidden',
                reveal_state = 'HIDDEN',
                world_anchor_cm_x = 100,
                world_anchor_cm_y = 200,
                world_anchor_cm_z = 0,
            },
            {
                id = 'traversal_cell_w1',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                x = 0,
                y = 1,
                layer = 0,
                height_level = 0,
                surface_type = 'WATER',
                landing_safety = 'NONE',
                world_anchor_cm_x = 0,
                world_anchor_cm_y = 100,
                world_anchor_cm_z = -20,
            },
            {
                id = 'traversal_cell_w2',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                x = 1,
                y = 1,
                layer = 0,
                height_level = 0,
                surface_type = 'WATER',
                landing_safety = 'NONE',
                world_anchor_cm_x = 100,
                world_anchor_cm_y = 100,
                world_anchor_cm_z = -20,
            },
            {
                id = 'traversal_cell_shore',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                x = 2,
                y = 1,
                layer = 0,
                height_level = 0,
                surface_type = 'GROUND',
                landing_safety = 'SAFE_GROUND',
                safe_marker_id = 'marker_shore',
                world_anchor_cm_x = 200,
                world_anchor_cm_y = 100,
                world_anchor_cm_z = 0,
            },
        },
        link_definitions = {
            {
                id = 'traversal_link_a1_b1',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                from_cell_id = 'traversal_cell_a1',
                to_cell_id = 'traversal_cell_b1',
                link_type = 'JUMP_DIRECT',
                horizontal_cost = 2,
                rise_levels = 0,
                drop_levels = 0,
                source_type = 'BAKED',
            },
            {
                id = 'traversal_link_a1_c1',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                from_cell_id = 'traversal_cell_a1',
                to_cell_id = 'traversal_cell_c1',
                link_type = 'JUMP_DIRECT',
                horizontal_cost = 3,
                rise_levels = 2,
                drop_levels = 0,
                source_type = 'MANUAL_OVERRIDE',
            },
            {
                id = 'traversal_link_a1_far',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                from_cell_id = 'traversal_cell_a1',
                to_cell_id = 'traversal_cell_far',
                link_type = 'JUMP_DIRECT',
                horizontal_cost = 8,
                rise_levels = 0,
                drop_levels = 0,
                source_type = 'BAKED',
            },
            {
                id = 'traversal_link_a1_hidden',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                from_cell_id = 'traversal_cell_a1',
                to_cell_id = 'traversal_cell_hidden',
                link_type = 'JUMP_DIRECT',
                horizontal_cost = 1,
                source_type = 'BAKED',
            },
            {
                id = 'traversal_link_enter_w1',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                from_cell_id = 'traversal_cell_a1',
                to_cell_id = 'traversal_cell_w1',
                link_type = 'WATER_ENTER',
                horizontal_cost = 1,
                water_zone_id = 'water_zone_pond',
            },
            {
                id = 'traversal_link_w1_w2',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                from_cell_id = 'traversal_cell_w1',
                to_cell_id = 'traversal_cell_w2',
                link_type = 'WATER_STEP',
                horizontal_cost = 1,
                water_zone_id = 'water_zone_pond',
            },
            {
                id = 'traversal_link_w2_shore',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                from_cell_id = 'traversal_cell_w2',
                to_cell_id = 'traversal_cell_shore',
                link_type = 'WATER_EXIT',
                horizontal_cost = 1,
                water_zone_id = 'water_zone_pond',
            },
            {
                id = 'traversal_link_w1_shore',
                schema_version = 1,
                grid_id = 'traversal_grid_demo',
                from_cell_id = 'traversal_cell_w1',
                to_cell_id = 'traversal_cell_shore',
                link_type = 'WATER_EXIT',
                horizontal_cost = 2,
                water_zone_id = 'water_zone_pond',
            },
        },
        rule_definitions = {
            {
                id = 'traversal_rule_jump',
                schema_version = 1,
                rules_version = 1,
                applies_to_link_types = { 'JUMP_DIRECT' },
                required_capability_any = { 'JUMP_BASIC', 'JUMP_LONG', 'JUMP_HIGH' },
                distance_budget_policy = 'JUMP_DUAL_LIMIT',
                landing_policy = 'SAFE_GROUND',
            },
            {
                id = 'traversal_rule_water',
                schema_version = 1,
                rules_version = 1,
                applies_to_link_types = { 'WATER_ENTER', 'WATER_STEP', 'WATER_EXIT' },
                required_capability_all = { 'WATER_WALK' },
                distance_budget_policy = 'WATER_SESSION_COST',
                landing_policy = 'WATER_SESSION',
            },
        },
        water_zone_definitions = {
            {
                id = 'water_zone_pond',
                schema_version = 1,
                rules_version = 1,
                grid_id = 'traversal_grid_demo',
                cell_ids = {
                    'traversal_cell_w1',
                    'traversal_cell_w2',
                },
                entry_link_ids = { 'traversal_link_enter_w1' },
                exit_link_ids = {
                    'traversal_link_w1_shore',
                    'traversal_link_w2_shore',
                },
                safe_shore_marker_ids = { 'marker_shore' },
                route_role = 'SIDE_ROUTE',
            },
        },
    }
end

local function seal_catalog()
    local sealed = TraversalCatalog.seal(catalog_source())
    assert.equal(sealed.ok, true, 'catalog must seal: '
        .. tostring(sealed.error and sealed.error.details and sealed.error.details.reason))
    return sealed.value
end

local function find_candidate(list, target_cell_id)
    local index
    for index = 1, #list do
        if list[index].target_cell_id == target_cell_id then
            return list[index]
        end
    end
    return nil
end

local function world_context(mutate)
    local context = {
        actor_id = 'char_hero',
        origin_cell_id = 'traversal_cell_a1',
        last_safe_marker_id = 'marker_a1',
        spatial_revision = 7,
        world_revision = 2,
        player_save_scope = 'player_demo',
        input_locked = false,
    }
    if mutate ~= nil then
        mutate(context)
    end
    return context
end

local function bind_service(options)
    options = options or {}
    local catalog = options.catalog or seal_catalog()
    local profile = options.profile or profile_fixture()
    local context = options.context or world_context()
    local commits = options.commits or {}
    local bound = TraversalService.bind({
        catalog = catalog,
        profile_provider = function()
            return profile
        end,
        world_context_provider = function()
            return context
        end,
        position_commit = options.position_commit or function(payload)
            commits[#commits + 1] = payload
            return {
                ok = true,
                value = {
                    landing_receipt_id = payload.landing_receipt_id,
                    marker_id = payload.marker_id,
                },
            }
        end,
    })
    assert.equal(bound.ok, true, 'service bind must succeed')
    return bound.value, catalog, profile, context, commits
end

return {
    case('catalog seals demo grid and rejects blocked jump edges', function()
        local catalog = seal_catalog()
        assert.equal(catalog:spatial_revision(), 7)
        assert.equal(catalog:grid_id(), 'traversal_grid_demo')
        local cell = catalog:require_cell('traversal_cell_a1')
        assert.equal(cell.ok, true)
        assert.equal(cell.value.safe_marker_id, 'marker_a1')

        local broken = catalog_source()
        broken.link_definitions[#broken.link_definitions + 1] = {
            id = 'traversal_link_block_a1_b1',
            schema_version = 1,
            grid_id = 'traversal_grid_demo',
            from_cell_id = 'traversal_cell_a1',
            to_cell_id = 'traversal_cell_b1',
            link_type = 'BLOCK',
            horizontal_cost = 0,
        }
        local sealed = TraversalCatalog.seal(broken)
        assert.equal(sealed.ok, false)
        assert.equal(sealed.error.code, TraversalErrorCodes.TRAVERSAL_CONFIG_BROKEN)
    end),

    case('jump candidates are deterministic and hide secret cells', function()
        local catalog = seal_catalog()
        local profile = profile_fixture()
        local first = Reachability.compute(catalog, profile, {
            origin_cell_id = 'traversal_cell_a1',
            spatial_revision = 7,
            world_revision = 2,
        })
        assert.equal(first.ok, true)
        local second = Reachability.compute(catalog, profile, {
            origin_cell_id = 'traversal_cell_a1',
            spatial_revision = 7,
            world_revision = 2,
        })
        assert.equal(second.ok, true)
        assert.equal(first.value.candidate_set_hash, second.value.candidate_set_hash)

        local hidden = find_candidate(first.value.candidates, 'traversal_cell_hidden')
        assert.equal(hidden, nil, 'hidden cells must not leak')

        local near = find_candidate(first.value.valid_candidates, 'traversal_cell_b1')
        assert.truthy(near)
        assert.equal(near.mode, 'JUMP')
        assert.equal(near.capability_id, 'JUMP_BASIC')

        local high = find_candidate(first.value.candidates, 'traversal_cell_c1')
        assert.truthy(high)
        assert.equal(high.validity, 'INVALID')
        assert.equal(high.invalid_reason, 'HEIGHT_EXCEEDED')

        local far = find_candidate(first.value.candidates, 'traversal_cell_far')
        assert.truthy(far)
        assert.equal(far.validity, 'INVALID')
        assert.equal(far.invalid_reason, 'OUT_OF_RANGE')

        local water = find_candidate(first.value.valid_candidates, 'traversal_cell_w1')
        assert.truthy(water)
        assert.equal(water.mode, 'WATER_ENTER')
    end),

    case('jump open request complete lands through position commit', function()
        local service, _, _, _, commits = bind_service()
        local opened = service:open_targeting({
            request_id = 'req_jump_1',
        })
        assert.equal(opened.ok, true)
        assert.equal(opened.value.targeting.scope, 'GROUND_OR_ENTRY')
        assert.truthy(opened.value.valid_count >= 1)

        local opened_again = service:open_targeting({
            request_id = 'req_jump_1',
        })
        assert.equal(opened_again.ok, true)
        assert.equal(
            opened_again.value.candidate_set_hash,
            opened.value.candidate_set_hash
        )

        local requested = service:request_traversal({
            command_id = 'cmd_jump_1',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_b1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(requested.ok, true, tostring(requested.error and requested.error.code))
        assert.equal(requested.value.mode, 'JUMP')
        assert.equal(requested.value.traversal.state, 'AUTHORIZED')

        local completed = service:complete_segment({
            traversal_session_id = requested.value.traversal.traversal_session_id,
            movement_token = requested.value.movement_token,
            segment_sequence = requested.value.segment_sequence,
        })
        assert.equal(completed.ok, true)
        assert.equal(completed.value.status, 'COMMITTED')
        assert.equal(completed.value.marker_id, 'marker_b1')
        assert.equal(#commits, 1)
        assert.equal(commits[1].marker_id, 'marker_b1')
        assert.equal(completed.value.events[1].event_type, 'TraversalLanded')

        local snap = service:snapshot()
        assert.equal(snap.ok, true)
        assert.equal(snap.value.targeting, nil)
        assert.equal(snap.value.traversal, nil)

        local replay = service:request_traversal({
            command_id = 'cmd_jump_1',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_b1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(replay.ok, true)
        assert.equal(
            replay.value.traversal.traversal_session_id,
            requested.value.traversal.traversal_session_id
        )
    end),

    case('stale source vector rejects request and forces refresh', function()
        local service, _, profile, context = bind_service()
        local opened = service:open_targeting({ request_id = 'req_stale' })
        assert.equal(opened.ok, true)

        local stale_vector = {
            spatial_revision = opened.value.source_vector.spatial_revision,
            world_revision = opened.value.source_vector.world_revision,
            source_loadout_revision = opened.value.source_vector.source_loadout_revision,
            source_progress_revision = opened.value.source_vector.source_progress_revision,
            profile_hash = opened.value.source_vector.profile_hash,
            rules_version = opened.value.source_vector.rules_version,
        }
        stale_vector.world_revision = stale_vector.world_revision + 1
        local rejected = service:request_traversal({
            command_id = 'cmd_stale',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_b1',
            source_vector = stale_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(rejected.ok, false)
        assert.equal(rejected.error.code, TraversalErrorCodes.TRAVERSAL_SOURCE_STALE)

        -- Mutate live context so recompute diverges even with original vector.
        context.world_revision = context.world_revision + 1
        local diverged = service:request_traversal({
            command_id = 'cmd_diverge',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_b1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(diverged.ok, false)
        assert.equal(diverged.error.code, TraversalErrorCodes.TRAVERSAL_SOURCE_STALE)
        assert.equal(profile.character_id, 'char_hero')
    end),

    case('water enter step and exit consume budget and land once', function()
        local service, _, _, context, commits = bind_service()
        local opened = service:open_targeting({ request_id = 'req_water_open' })
        assert.equal(opened.ok, true)

        local enter = service:request_traversal({
            command_id = 'cmd_water_enter',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_w1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(enter.ok, true)
        assert.equal(enter.value.mode, 'WATER_ENTER')

        local entered = service:complete_segment({
            traversal_session_id = enter.value.traversal.traversal_session_id,
            movement_token = enter.value.movement_token,
            segment_sequence = 1,
        })
        assert.equal(entered.ok, true)
        assert.equal(entered.value.status, 'ON_WATER_IDLE')
        assert.equal(entered.value.events[1].event_type, 'WaterWalkEntered')
        assert.equal(entered.value.remaining_water_cells, 4)
        assert.equal(#commits, 0)

        local nested = service:open_targeting({
            request_id = 'req_water_nested',
            parent_traversal_session_id = enter.value.traversal.traversal_session_id,
        })
        assert.equal(nested.ok, true, tostring(nested.error and nested.error.code))
        assert.equal(nested.value.targeting.scope, 'WATER_SEGMENT')

        local step = service:request_traversal({
            command_id = 'cmd_water_step',
            targeting_session_id = nested.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_w2',
            source_vector = nested.value.source_vector,
            candidate_set_hash = nested.value.candidate_set_hash,
        })
        assert.equal(step.ok, true)
        assert.equal(step.value.mode, 'WATER_STEP')

        local advanced = service:complete_segment({
            traversal_session_id = enter.value.traversal.traversal_session_id,
            movement_token = step.value.movement_token,
            segment_sequence = step.value.segment_sequence,
        })
        assert.equal(advanced.ok, true)
        assert.equal(advanced.value.events[1].event_type, 'WaterWalkAdvanced')
        assert.equal(advanced.value.remaining_water_cells, 3)

        local nested_exit = service:open_targeting({
            request_id = 'req_water_exit',
            parent_traversal_session_id = enter.value.traversal.traversal_session_id,
        })
        assert.equal(nested_exit.ok, true)
        local exit = service:request_traversal({
            command_id = 'cmd_water_exit',
            targeting_session_id = nested_exit.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_shore',
            source_vector = nested_exit.value.source_vector,
            candidate_set_hash = nested_exit.value.candidate_set_hash,
        })
        assert.equal(exit.ok, true)
        assert.equal(exit.value.mode, 'WATER_EXIT')

        local exited = service:complete_segment({
            traversal_session_id = enter.value.traversal.traversal_session_id,
            movement_token = exit.value.movement_token,
            segment_sequence = exit.value.segment_sequence,
        })
        assert.equal(exited.ok, true)
        assert.equal(exited.value.status, 'COMMITTED')
        assert.equal(#commits, 1)
        assert.equal(commits[1].marker_id, 'marker_shore')
        assert.equal(exited.value.events[1].event_type, 'TraversalLanded')
        assert.equal(exited.value.events[2].event_type, 'WaterWalkExited')

        local snap = service:snapshot()
        assert.equal(snap.value.traversal, nil)
        assert.equal(context.origin_cell_id, 'traversal_cell_a1')
    end),

    case('cancel nested targeting keeps water session idle', function()
        local service = bind_service()
        local opened = service:open_targeting({ request_id = 'req_cancel_enter' })
        local enter = service:request_traversal({
            command_id = 'cmd_cancel_enter',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_w1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(enter.ok, true)
        local entered = service:complete_segment({
            traversal_session_id = enter.value.traversal.traversal_session_id,
            movement_token = enter.value.movement_token,
            segment_sequence = 1,
        })
        assert.equal(entered.ok, true)

        local nested = service:open_targeting({
            request_id = 'req_cancel_nested',
            parent_traversal_session_id = enter.value.traversal.traversal_session_id,
        })
        assert.equal(nested.ok, true)
        local cancelled = service:cancel_targeting({
            targeting_session_id = nested.value.targeting.targeting_session_id,
        })
        assert.equal(cancelled.ok, true)
        assert.equal(cancelled.value.resume_state, 'ON_WATER_IDLE')

        local snap = service:snapshot()
        assert.equal(snap.value.targeting, nil)
        assert.equal(snap.value.traversal.state, 'ON_WATER_IDLE')
    end),

    case('recover clears temporary sessions back to last safe', function()
        local service = bind_service()
        local opened = service:open_targeting({ request_id = 'req_recover' })
        assert.equal(opened.ok, true)
        local recovered = service:recover({
            recovery_id = 'recovery_1',
            reason = 'TEST_INTERRUPT',
        })
        assert.equal(recovered.ok, true)
        assert.equal(recovered.value.safe_marker_id, 'marker_a1')
        assert.equal(recovered.value.had_targeting, true)
        local snap = service:snapshot()
        assert.equal(snap.value.targeting, nil)
        assert.equal(snap.value.traversal, nil)

        local again = service:recover({
            recovery_id = 'recovery_1',
            reason = 'TEST_INTERRUPT',
        })
        assert.equal(again.ok, true)
        assert.equal(again.value.safe_marker_id, 'marker_a1')
    end),

    case('missing capability cannot open targeting', function()
        local empty_profile = profile_fixture(function(profile)
            profile.capability_specs = {}
            profile.source_martial_id = nil
            profile.source_martial_level = 0
            profile.range_query_radius_cells = 0
        end)
        local service = bind_service({ profile = empty_profile })
        local opened = service:open_targeting({ request_id = 'req_no_cap' })
        assert.equal(opened.ok, false)
        assert.equal(opened.error.code, TraversalErrorCodes.TRAVERSAL_CAPABILITY_MISSING)
    end),

    case('landing tuple is stable for identical segment inputs', function()
        local first = TraversalRuntime.landing_tuple({
            player_save_scope = 'player_demo',
            traversal_session_id = 'traversal_cmd_1',
            active_segment_command_id = 'cmd_1',
            segment_sequence = 1,
            target_cell_id = 'traversal_cell_b1',
            rules_version = 1,
        })
        local second = TraversalRuntime.landing_tuple({
            player_save_scope = 'player_demo',
            traversal_session_id = 'traversal_cmd_1',
            active_segment_command_id = 'cmd_1',
            segment_sequence = 1,
            target_cell_id = 'traversal_cell_b1',
            rules_version = 1,
        })
        assert.equal(first.ok, true)
        assert.equal(second.ok, true)
        assert.equal(first.value.landing_receipt_id, second.value.landing_receipt_id)
        assert.equal(first.value.digest, second.value.digest)
    end),

    case('world owns landing commit and updates safe marker cell', function()
        local world_catalog = WorldCatalog.seal({
            flag_definitions = {},
            location_definitions = {
                {
                    id = 'location_ridge',
                    schema_version = 1,
                    rules_version = 1,
                    area_id = 'area_ridge',
                    name_key = 'location.ridge',
                    discovery_marker_id = 'marker_a1',
                    safe_return_marker_id = 'marker_a1',
                },
            },
            area_definitions = {
                {
                    id = 'area_ridge',
                    schema_version = 1,
                    rules_version = 1,
                    area_type = 'WILDERNESS',
                    name_key = 'area.ridge',
                    location_ids = { 'location_ridge' },
                    entry_marker_id = 'marker_a1',
                },
            },
            interactable_definitions = {},
        })
        assert.equal(world_catalog.ok, true)
        local world = WorldService.bind({ catalog = world_catalog.value })
        assert.equal(world.ok, true)
        local boot = world.value:bootstrap_position({
            location_id = 'location_ridge',
            marker_id = 'marker_a1',
            current_cell_id = 'traversal_cell_a1',
        })
        assert.equal(boot.ok, true)

        local traversal_catalog = seal_catalog()
        local profile = profile_fixture()
        local bound = TraversalService.bind({
            catalog = traversal_catalog,
            profile_provider = function()
                return profile
            end,
            world_service = world.value,
            world_context_options = {
                actor_id = 'char_hero',
                default_origin_cell_id = 'traversal_cell_a1',
                player_save_scope = 'player_demo',
            },
        })
        assert.equal(bound.ok, true)
        local service = bound.value

        local opened = service:open_targeting({ request_id = 'req_world_jump' })
        assert.equal(opened.ok, true, tostring(opened.error and opened.error.code))
        local requested = service:request_traversal({
            command_id = 'cmd_world_jump',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_b1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(requested.ok, true)
        local completed = service:complete_segment({
            traversal_session_id = requested.value.traversal.traversal_session_id,
            movement_token = requested.value.movement_token,
            segment_sequence = 1,
        })
        assert.equal(completed.ok, true, tostring(completed.error and completed.error.code))
        assert.equal(completed.value.status, 'COMMITTED')
        assert.equal(completed.value.events[1].event_type, 'TraversalLanded')
        assert.truthy(completed.value.events[1].event_id)

        local position = world.value:get_position()
        assert.equal(position.ok, true)
        assert.equal(position.value.current_marker_id, 'marker_b1')
        assert.equal(position.value.last_safe_marker_id, 'marker_b1')
        assert.equal(position.value.current_cell_id, 'traversal_cell_b1')
        assert.equal(position.value.last_landing_receipt_id, completed.value.landing_receipt_id)

        local replay = world.value:commit_traversal_landing({
            player_save_scope = 'player_demo',
            traversal_session_id = requested.value.traversal.traversal_session_id,
            active_segment_command_id = 'cmd_world_jump',
            segment_sequence = 1,
            target_cell_id = 'traversal_cell_b1',
            rules_version = 1,
            marker_id = 'marker_b1',
            mode = 'JUMP',
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.already_committed, true)
        assert.equal(replay.value.landing_receipt_id, completed.value.landing_receipt_id)

        local state = WorldState.empty()
        state.world_revision = 3
        state.position = position.value
        local encoded = WorldSaveCodec.encode(state)
        assert.equal(encoded.ok, true)
        assert.equal(
            encoded.value.world_position.last_landing_receipt_id,
            completed.value.landing_receipt_id
        )
        assert.equal(encoded.value.world_position.current_cell_id, 'traversal_cell_b1')
        local decoded = WorldSaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true)
        assert.equal(
            decoded.value.position.last_landing_receipt_id,
            completed.value.landing_receipt_id
        )
    end),

    case('jump landing advances TRAVERSAL_LANDING quest objective', function()
        local world_catalog = WorldCatalog.seal({
            flag_definitions = {},
            location_definitions = {
                {
                    id = 'location_ridge',
                    schema_version = 1,
                    rules_version = 1,
                    area_id = 'area_ridge',
                    name_key = 'location.ridge',
                    discovery_marker_id = 'marker_a1',
                    safe_return_marker_id = 'marker_a1',
                },
            },
            area_definitions = {
                {
                    id = 'area_ridge',
                    schema_version = 1,
                    rules_version = 1,
                    area_type = 'WILDERNESS',
                    name_key = 'area.ridge',
                    location_ids = { 'location_ridge' },
                    entry_marker_id = 'marker_a1',
                },
            },
            interactable_definitions = {},
        })
        assert.equal(world_catalog.ok, true)
        local world = WorldService.bind({ catalog = world_catalog.value })
        assert.equal(world.ok, true)
        assert.equal(world.value:bootstrap_position({
            location_id = 'location_ridge',
            marker_id = 'marker_a1',
            current_cell_id = 'traversal_cell_a1',
        }).ok, true)

        local quest_catalog = QuestCatalog.seal({
            objective_definitions = {
                {
                    id = 'objective_land_b1',
                    schema_version = 1,
                    rules_version = 1,
                    stage_id = 'stage_light_01',
                    objective_type = 'TRAVERSAL_LANDING',
                    target_id = 'traversal_cell_b1',
                    required_count = 1,
                    progress_semantics = 'ONCE_FACT',
                    event_type = 'TraversalLanded',
                    description_key = 'obj.land_b1.desc',
                    completed_key = 'obj.land_b1.done',
                },
            },
            stage_definitions = {
                {
                    id = 'stage_light_01',
                    schema_version = 1,
                    rules_version = 1,
                    quest_id = 'quest_light_jump',
                    objective_ids = { 'objective_land_b1' },
                    completion_mode = 'ALL',
                    journal_text_key = 'stage.light_01',
                },
            },
            quest_definitions = {
                {
                    id = 'quest_light_jump',
                    schema_version = 1,
                    definition_version = 1,
                    rules_version = 1,
                    category = 'SIDE',
                    chapter_id = 'chapter_01',
                    title_key = 'quest.light_jump.title',
                    summary_key = 'quest.light_jump.summary',
                    accept_policy = 'MANUAL_NPC',
                    accept_ref_id = 'npc_guide',
                    first_stage_id = 'stage_light_01',
                    stage_ids = { 'stage_light_01' },
                    reward_policy = 'NO_REWARD',
                    abandon_policy = 'ALLOW_RESET_RUN',
                    journal_sort_order = 50,
                },
            },
        })
        assert.equal(quest_catalog.ok, true, tostring(
            quest_catalog.error and quest_catalog.error.details and quest_catalog.error.details.reason
        ))
        local quest = QuestService.bind({ catalog = quest_catalog.value })
        assert.equal(quest.ok, true)
        local accepted = quest.value:accept({
            quest_id = 'quest_light_jump',
            run_id = 'qrun_light_jump_01',
            accept_receipt_id = 'receipt_accept_light_jump',
            command_id = 'cmd_accept_light',
        })
        assert.equal(accepted.ok, true, tostring(accepted.error and accepted.error.code))

        local traversal = TraversalService.bind({
            catalog = seal_catalog(),
            profile_provider = function()
                return profile_fixture()
            end,
            world_service = world.value,
            world_context_options = {
                actor_id = 'char_hero',
                default_origin_cell_id = 'traversal_cell_a1',
                player_save_scope = 'player_demo',
            },
        })
        assert.equal(traversal.ok, true)
        local opened = traversal.value:open_targeting({ request_id = 'req_quest_jump' })
        assert.equal(opened.ok, true)
        local requested = traversal.value:request_traversal({
            command_id = 'cmd_quest_jump',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_b1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(requested.ok, true)

        local bridged = TraversalQuestBridge.complete_and_relay(
            traversal.value,
            quest.value,
            {
                traversal_session_id = requested.value.traversal.traversal_session_id,
                movement_token = requested.value.movement_token,
                segment_sequence = 1,
            }
        )
        assert.equal(bridged.ok, true, tostring(bridged.error and bridged.error.code))
        assert.equal(bridged.value.quest_relay.applied_count, 1)
        assert.equal(bridged.value.complete.events[1].event_type, 'TraversalLanded')

        local detail = quest.value:get_run('qrun_light_jump_01')
        assert.equal(detail.ok, true)
        assert.equal(detail.value.run.status, 'READY_TO_TURN_IN')
        assert.equal(detail.value.objectives[1].status, 'COMPLETE')
    end),

    case('water enter and exit advance matching quest objectives', function()
        local world_catalog = WorldCatalog.seal({
            flag_definitions = {},
            location_definitions = {
                {
                    id = 'location_ridge',
                    schema_version = 1,
                    rules_version = 1,
                    area_id = 'area_ridge',
                    name_key = 'location.ridge',
                    discovery_marker_id = 'marker_a1',
                    safe_return_marker_id = 'marker_a1',
                },
            },
            area_definitions = {
                {
                    id = 'area_ridge',
                    schema_version = 1,
                    rules_version = 1,
                    area_type = 'WILDERNESS',
                    name_key = 'area.ridge',
                    location_ids = { 'location_ridge' },
                    entry_marker_id = 'marker_a1',
                },
            },
            interactable_definitions = {},
        })
        assert.equal(world_catalog.ok, true)
        local world = WorldService.bind({ catalog = world_catalog.value })
        assert.equal(world.ok, true)
        assert.equal(world.value:bootstrap_position({
            location_id = 'location_ridge',
            marker_id = 'marker_a1',
            current_cell_id = 'traversal_cell_a1',
        }).ok, true)

        local quest_catalog = QuestCatalog.seal({
            objective_definitions = {
                {
                    id = 'objective_enter_pond',
                    schema_version = 1,
                    rules_version = 1,
                    stage_id = 'stage_water_01',
                    objective_type = 'WATER_WALK_ENTER',
                    target_id = 'water_zone_pond',
                    required_count = 1,
                    progress_semantics = 'ONCE_FACT',
                    event_type = 'WaterWalkEntered',
                    description_key = 'obj.enter_pond.desc',
                    completed_key = 'obj.enter_pond.done',
                },
                {
                    id = 'objective_exit_pond',
                    schema_version = 1,
                    rules_version = 1,
                    stage_id = 'stage_water_02',
                    objective_type = 'WATER_WALK_EXIT',
                    target_id = 'water_zone_pond',
                    required_count = 1,
                    progress_semantics = 'ONCE_FACT',
                    event_type = 'WaterWalkExited',
                    description_key = 'obj.exit_pond.desc',
                    completed_key = 'obj.exit_pond.done',
                },
            },
            stage_definitions = {
                {
                    id = 'stage_water_01',
                    schema_version = 1,
                    rules_version = 1,
                    quest_id = 'quest_water_walk',
                    objective_ids = { 'objective_enter_pond' },
                    completion_mode = 'ALL',
                    next_stage_id = 'stage_water_02',
                    journal_text_key = 'stage.water_01',
                },
                {
                    id = 'stage_water_02',
                    schema_version = 1,
                    rules_version = 1,
                    quest_id = 'quest_water_walk',
                    objective_ids = { 'objective_exit_pond' },
                    completion_mode = 'ALL',
                    journal_text_key = 'stage.water_02',
                },
            },
            quest_definitions = {
                {
                    id = 'quest_water_walk',
                    schema_version = 1,
                    definition_version = 1,
                    rules_version = 1,
                    category = 'SIDE',
                    chapter_id = 'chapter_01',
                    title_key = 'quest.water_walk.title',
                    summary_key = 'quest.water_walk.summary',
                    accept_policy = 'MANUAL_NPC',
                    accept_ref_id = 'npc_guide',
                    first_stage_id = 'stage_water_01',
                    stage_ids = { 'stage_water_01', 'stage_water_02' },
                    reward_policy = 'NO_REWARD',
                    abandon_policy = 'ALLOW_RESET_RUN',
                    journal_sort_order = 60,
                },
            },
        })
        assert.equal(quest_catalog.ok, true)
        local quest = QuestService.bind({ catalog = quest_catalog.value })
        assert.equal(quest.ok, true)
        assert.equal(quest.value:accept({
            quest_id = 'quest_water_walk',
            run_id = 'qrun_water_walk_01',
            accept_receipt_id = 'receipt_accept_water',
            command_id = 'cmd_accept_water',
        }).ok, true)

        local service = TraversalService.bind({
            catalog = seal_catalog(),
            profile_provider = function()
                return profile_fixture()
            end,
            world_service = world.value,
            world_context_options = {
                actor_id = 'char_hero',
                default_origin_cell_id = 'traversal_cell_a1',
                player_save_scope = 'player_demo',
            },
        })
        assert.equal(service.ok, true)
        service = service.value

        local opened = service:open_targeting({ request_id = 'req_water_quest_open' })
        assert.equal(opened.ok, true)
        local enter = service:request_traversal({
            command_id = 'cmd_water_quest_enter',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_w1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(enter.ok, true)
        local entered = TraversalQuestBridge.complete_and_relay(service, quest.value, {
            traversal_session_id = enter.value.traversal.traversal_session_id,
            movement_token = enter.value.movement_token,
            segment_sequence = 1,
        })
        assert.equal(entered.ok, true)
        assert.equal(entered.value.quest_relay.applied_count, 1)

        -- Direct exit from w1 to shore without intermediate step.
        local nested = service:open_targeting({
            request_id = 'req_water_quest_exit',
            parent_traversal_session_id = enter.value.traversal.traversal_session_id,
        })
        assert.equal(nested.ok, true)
        local exit = service:request_traversal({
            command_id = 'cmd_water_quest_exit',
            targeting_session_id = nested.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_shore',
            source_vector = nested.value.source_vector,
            candidate_set_hash = nested.value.candidate_set_hash,
        })
        assert.equal(exit.ok, true)
        local exited = TraversalQuestBridge.complete_and_relay(service, quest.value, {
            traversal_session_id = enter.value.traversal.traversal_session_id,
            movement_token = exit.value.movement_token,
            segment_sequence = exit.value.segment_sequence,
        })
        assert.equal(exited.ok, true)
        assert.equal(exited.value.complete.status, 'COMMITTED')
        assert.equal(exited.value.complete.events[1].event_type, 'TraversalLanded')
        assert.equal(exited.value.complete.events[2].event_type, 'WaterWalkExited')
        assert.truthy(exited.value.quest_relay.applied_count >= 1)

        local position = world.value:get_position()
        assert.equal(position.value.current_marker_id, 'marker_shore')
        assert.equal(position.value.current_cell_id, 'traversal_cell_shore')
    end),

    case('landing commits critical slot2 checkpoint with last_landing_receipt_id', function()
        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)
        local world_store = FakeWorldStore.new()
        assert.equal(world_store.ok, true)
        local save_bridge = WorldSaveBridge.bind({
            store = world_store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 260001,
        })
        assert.equal(save_bridge.ok, true)

        local world_catalog = WorldCatalog.seal({
            flag_definitions = {},
            location_definitions = {
                {
                    id = 'location_ridge',
                    schema_version = 1,
                    rules_version = 1,
                    area_id = 'area_ridge',
                    name_key = 'location.ridge',
                    discovery_marker_id = 'marker_a1',
                    safe_return_marker_id = 'marker_a1',
                },
            },
            area_definitions = {
                {
                    id = 'area_ridge',
                    schema_version = 1,
                    rules_version = 1,
                    area_type = 'WILDERNESS',
                    name_key = 'area.ridge',
                    location_ids = { 'location_ridge' },
                    entry_marker_id = 'marker_a1',
                },
            },
            interactable_definitions = {},
        })
        assert.equal(world_catalog.ok, true)
        local world = WorldService.bind({
            catalog = world_catalog.value,
            world_store = world_store.value,
            save_bridge = save_bridge.value,
        })
        assert.equal(world.ok, true)
        assert.equal(world.value:bootstrap_position({
            location_id = 'location_ridge',
            marker_id = 'marker_a1',
            current_cell_id = 'traversal_cell_a1',
        }).ok, true)

        local traversal = TraversalService.bind({
            catalog = seal_catalog(),
            profile_provider = function()
                return profile_fixture()
            end,
            world_service = world.value,
            world_context_options = {
                actor_id = 'char_hero',
                default_origin_cell_id = 'traversal_cell_a1',
                player_save_scope = 'player_landing_ckpt',
            },
        })
        assert.equal(traversal.ok, true)
        local opened = traversal.value:open_targeting({
            request_id = 'req_landing_ckpt',
        })
        assert.equal(opened.ok, true)
        local requested = traversal.value:request_traversal({
            command_id = 'cmd_landing_ckpt',
            targeting_session_id = opened.value.targeting.targeting_session_id,
            target_cell_id = 'traversal_cell_b1',
            source_vector = opened.value.source_vector,
            candidate_set_hash = opened.value.candidate_set_hash,
        })
        assert.equal(requested.ok, true)
        local completed = traversal.value:complete_segment({
            traversal_session_id = requested.value.traversal.traversal_session_id,
            movement_token = requested.value.movement_token,
            segment_sequence = 1,
        })
        assert.equal(completed.ok, true, tostring(completed.error and completed.error.code))
        assert.equal(completed.value.status, 'COMMITTED')
        assert.truthy(completed.value.landing_receipt_id)

        local position = world.value:get_position()
        assert.equal(position.ok, true)
        assert.equal(position.value.current_marker_id, 'marker_b1')
        assert.equal(
            position.value.last_landing_receipt_id,
            completed.value.landing_receipt_id
        )

        -- Domain commit returns save status via position_commit path (world service).
        local direct = world.value:commit_traversal_landing({
            player_save_scope = 'player_landing_ckpt',
            traversal_session_id = requested.value.traversal.traversal_session_id,
            active_segment_command_id = 'cmd_landing_ckpt',
            segment_sequence = 1,
            target_cell_id = 'traversal_cell_b1',
            rules_version = 1,
            marker_id = 'marker_b1',
            mode = 'JUMP',
            request_id = 'request_replay_landing',
        })
        assert.equal(direct.ok, true)
        assert.equal(direct.value.already_committed, true)
        assert.equal(direct.value.save.status, 'SKIPPED')
        assert.equal(direct.value.save.reason, 'ALREADY_COMMITTED')

        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)
        local loaded = load.value:load({
            player_ref = 'player_landing_ckpt',
            session_instance_id = 'session_landing_ckpt_1',
            request_id = 'request_load_landing_ckpt_1',
        }, invoke)
        assert.equal(loaded.ok, true, tostring(loaded.error and loaded.error.code))
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.loaded_envelopes[2] ~= nil, true)
        local slot2 = loaded.value.loaded_envelopes[2].payload
        assert.equal(slot2.world_position.current_marker_id, 'marker_b1')
        assert.equal(slot2.world_position.last_safe_marker_id, 'marker_b1')
        assert.equal(slot2.world_position.current_cell_id, 'traversal_cell_b1')
        assert.equal(
            slot2.world_position.last_landing_receipt_id,
            completed.value.landing_receipt_id
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_2_revision,
            loaded.value.loaded_envelopes[2].revision
        )

        -- Slot 5 recovery journal references the same landing receipt (owner 18).
        assert.equal(loaded.value.loaded_envelopes[5] ~= nil, true)
        local slot5 = loaded.value.loaded_envelopes[5].payload
        assert.equal(type(slot5.save_recovery_transactions), 'table')
        assert.equal(#slot5.save_recovery_transactions, 1)
        local recovery = slot5.save_recovery_transactions[1]
        assert.equal(recovery.transaction_type, 'TRAVERSAL_LANDING')
        assert.equal(recovery.state, 'COMMITTED')
        assert.equal(recovery.business_receipt_id, completed.value.landing_receipt_id)
        assert.equal(recovery.owner_slot_id, 2)
        assert.equal(recovery.owner_section_key, 'world_position')
        assert.equal(recovery.command_id, 'cmd_landing_ckpt')
        assert.equal(
            recovery.target_checkpoint_id,
            loaded.value.loaded_envelopes[2].checkpoint_id
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_5_revision,
            loaded.value.loaded_envelopes[5].revision
        )

        local evidence = RecoveryJournal.reconcile_landing_evidence(
            slot2.world_position,
            slot5.save_recovery_transactions
        )
        assert.equal(evidence.ok, true)
        assert.equal(evidence.value.matched, true)
        assert.equal(evidence.value.status, 'MATCHED')
        assert.equal(
            evidence.value.last_landing_receipt_id,
            completed.value.landing_receipt_id
        )
        assert.equal(loaded.value.transient_world.action, 'KEEP_LANDING')
        assert.equal(loaded.value.transient_world.traversal_session, 'DISCARDED')
        assert.equal(
            loaded.value.transient_world.last_landing_receipt_id,
            completed.value.landing_receipt_id
        )

        -- Fresh world service hydrates from encoded store after checkpoint export.
        local exported = world_store.value:export_save_bundle()
        assert.equal(exported.ok, true)
        assert.equal(
            exported.value.world_position.last_landing_receipt_id,
            completed.value.landing_receipt_id
        )
    end),

    case('recovery journal upsert is receipt-keyed and rejects identity conflicts', function()
        local built = RecoveryJournal.build_traversal_landing_row({
            transaction_id = 'recovery_tx_1',
            landing_receipt_id = 'receipt_traversal_landing_v1_' .. string.rep('a', 64),
            target_checkpoint_id = 'checkpoint:1',
            command_id = 'cmd_jump_1',
            outcome_digest = string.rep('b', 64),
        })
        assert.equal(built.ok, true, tostring(built.error and built.error.details and built.error.details.reason))

        local first = RecoveryJournal.upsert_row({}, built.value)
        assert.equal(first.ok, true)
        assert.equal(#first.value.rows, 1)
        assert.equal(first.value.replaced, false)

        local same = RecoveryJournal.upsert_row(first.value.rows, built.value)
        assert.equal(same.ok, true)
        assert.equal(#same.value.rows, 1)
        assert.equal(same.value.replaced, true)

        local conflict = RecoveryJournal.build_traversal_landing_row({
            transaction_id = 'recovery_tx_2',
            landing_receipt_id = built.value.business_receipt_id,
            target_checkpoint_id = 'checkpoint:2',
            command_id = 'cmd_jump_2',
            outcome_digest = string.rep('c', 64),
        })
        assert.equal(conflict.ok, true)
        local rejected = RecoveryJournal.upsert_row(first.value.rows, conflict.value)
        assert.equal(rejected.ok, false)
        assert.equal(rejected.error.details.reason, 'RECOVERY_ROW_CONFLICT')

        local missing = RecoveryJournal.reconcile_landing_evidence({
            last_landing_receipt_id = built.value.business_receipt_id,
        }, {})
        assert.equal(missing.ok, true)
        assert.equal(missing.value.matched, false)
        assert.equal(missing.value.status, 'RECEIPT_WITHOUT_RECOVERY_ROW')
    end),
}
