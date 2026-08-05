-- Chapter 01 world areas / locations / search points (direction 3).

local WorldCatalog = require 'wzx.config.schema.world.catalog'

local Chapter01 = {}
local SV, RV = 1, 1

local function location(id, area_id, sort_order, neighbors)
    return {
        id = id,
        schema_version = SV,
        rules_version = RV,
        area_id = area_id,
        name_key = 'location.' .. id,
        discovery_marker_id = 'marker_' .. id:gsub('^location_', ''),
        safe_return_marker_id = 'marker_' .. id:gsub('^location_', ''),
        neighbor_location_ids = neighbors or {},
        map_sort_order = sort_order,
        discoverable = true,
    }
end

local function area(id, area_type, location_ids, entry_marker)
    return {
        id = id,
        schema_version = SV,
        rules_version = RV,
        area_type = area_type,
        name_key = 'area.' .. id,
        location_ids = location_ids,
        entry_marker_id = entry_marker,
        is_public_exploration = true,
    }
end

local function search(id, location_id, flag_id)
    return {
        id = id,
        schema_version = SV,
        rules_version = RV,
        interactable_type = 'SEARCH',
        location_id = location_id,
        marker_id = 'marker_' .. id:gsub('^interact_', ''),
        result_type = 'FLAG',
        flag_id = flag_id,
        flag_value = true,
        prompt_key = 'prompt.' .. id,
        persistence_policy = 'ONCE',
        initial_state = 'AVAILABLE',
    }
end

function Chapter01.build_source()
    return {
        flag_definitions = {
            {
                id = 'flag_ambush_searched',
                schema_version = SV,
                rules_version = RV,
                value_type = 'BOOLEAN',
                default_value = false,
                description_key = 'flag.ambush_searched',
            },
            {
                id = 'flag_ridge_kiln_searched',
                schema_version = SV,
                rules_version = RV,
                value_type = 'BOOLEAN',
                default_value = false,
                description_key = 'flag.ridge_kiln_searched',
            },
            {
                id = 'flag_ridge_stele_searched',
                schema_version = SV,
                rules_version = RV,
                value_type = 'BOOLEAN',
                default_value = false,
                description_key = 'flag.ridge_stele_searched',
            },
            {
                id = 'flag_cavern_plates_read',
                schema_version = SV,
                rules_version = RV,
                value_type = 'BOOLEAN',
                default_value = false,
                description_key = 'flag.cavern_plates_read',
            },
            {
                id = 'flag_side_bell_found',
                schema_version = SV,
                rules_version = RV,
                value_type = 'BOOLEAN',
                default_value = false,
                description_key = 'flag.side_bell_found',
            },
            {
                id = 'flag_side_hidden_stele',
                schema_version = SV,
                rules_version = RV,
                value_type = 'BOOLEAN',
                default_value = false,
                description_key = 'flag.side_hidden_stele',
            },
            {
                id = 'flag_official_trust',
                schema_version = SV,
                rules_version = RV,
                value_type = 'INTEGER',
                default_value = 0,
                description_key = 'flag.official_trust',
            },
            {
                id = 'flag_relay_trust',
                schema_version = SV,
                rules_version = RV,
                value_type = 'INTEGER',
                default_value = 0,
                description_key = 'flag.relay_trust',
            },
            {
                id = 'flag_public_truth',
                schema_version = SV,
                rules_version = RV,
                value_type = 'INTEGER',
                default_value = 0,
                description_key = 'flag.public_truth',
            },
        },
        location_definitions = {
            location(
                'location_mist_ferry_hall',
                'area_mist_ferry_post',
                10,
                { 'location_road_ambush' }
            ),
            location(
                'location_road_ambush',
                'area_mist_ferry_post',
                20,
                { 'location_mist_ferry_hall', 'location_blackwood_gate' }
            ),
            location(
                'location_blackwood_gate',
                'area_blackwood_ridge',
                30,
                { 'location_road_ambush', 'location_sunken_bell_court' }
            ),
            location(
                'location_sunken_bell_court',
                'area_sunken_bell_court',
                40,
                { 'location_blackwood_gate', 'location_bell_cavern' }
            ),
            location(
                'location_bell_cavern',
                'area_underground_bell_cavern',
                50,
                { 'location_sunken_bell_court' }
            ),
        },
        area_definitions = {
            area(
                'area_mist_ferry_post',
                'TOWN',
                { 'location_mist_ferry_hall', 'location_road_ambush' },
                'marker_mist_ferry_hall'
            ),
            area(
                'area_blackwood_ridge',
                'WILDERNESS',
                { 'location_blackwood_gate' },
                'marker_blackwood_gate'
            ),
            area(
                'area_sunken_bell_court',
                'WILDERNESS',
                { 'location_sunken_bell_court' },
                'marker_sunken_bell_court'
            ),
            area(
                'area_underground_bell_cavern',
                'DUNGEON',
                { 'location_bell_cavern' },
                'marker_bell_cavern'
            ),
        },
        interactable_definitions = {
            search(
                'interact_ambush_search',
                'location_road_ambush',
                'flag_ambush_searched'
            ),
            search(
                'interact_ridge_kiln',
                'location_blackwood_gate',
                'flag_ridge_kiln_searched'
            ),
            search(
                'interact_ridge_stele',
                'location_blackwood_gate',
                'flag_ridge_stele_searched'
            ),
            search(
                'interact_cavern_nameplate',
                'location_bell_cavern',
                'flag_cavern_plates_read'
            ),
            search(
                'interact_side_bell',
                'location_mist_ferry_hall',
                'flag_side_bell_found'
            ),
            search(
                'interact_side_hidden_stele',
                'location_blackwood_gate',
                'flag_side_hidden_stele'
            ),
        },
    }
end

function Chapter01.location_ids()
    return {
        'location_mist_ferry_hall',
        'location_road_ambush',
        'location_blackwood_gate',
        'location_sunken_bell_court',
        'location_bell_cavern',
    }
end

function Chapter01.interactable_ids()
    return {
        'interact_ambush_search',
        'interact_ridge_kiln',
        'interact_ridge_stele',
        'interact_cavern_nameplate',
        'interact_side_bell',
        'interact_side_hidden_stele',
    }
end

function Chapter01.seal()
    return WorldCatalog.seal(Chapter01.build_source())
end

return Chapter01
