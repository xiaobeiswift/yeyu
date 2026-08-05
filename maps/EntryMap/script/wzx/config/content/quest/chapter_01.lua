-- Chapter 01 quest content (direction 3 freeze).
-- Hand-authored interim package aligned with design/data-source/quest/chapter_01_freeze.md.
-- Not generated Lua; do not place under config/generated.

local QuestCatalog = require 'wzx.config.schema.quest.catalog'

local Chapter01 = {}

local CHAPTER_ID = 'chapter_01_bell_below_no_name'
local SCHEMA_VERSION = 1
local RULES_VERSION = 1
local DEFINITION_VERSION = 1

local function objective(spec)
    return {
        id = spec.id,
        schema_version = SCHEMA_VERSION,
        rules_version = RULES_VERSION,
        stage_id = spec.stage_id,
        objective_type = spec.objective_type,
        target_id = spec.target_id,
        target_tag = spec.target_tag,
        required_count = spec.required_count or 1,
        progress_semantics = spec.progress_semantics,
        event_type = spec.event_type,
        optional = spec.optional == true,
        hidden_until_progress = spec.hidden_until_progress == true,
        include_pre_accept = spec.include_pre_accept == true,
        guide_ref_id = spec.guide_ref_id,
        description_key = 'objective.' .. spec.id .. '.desc',
        completed_key = 'objective.' .. spec.id .. '.done',
        deprecated = false,
    }
end

local function stage(spec)
    return {
        id = spec.id,
        schema_version = SCHEMA_VERSION,
        rules_version = RULES_VERSION,
        quest_id = spec.quest_id,
        objective_ids = spec.objective_ids,
        completion_mode = spec.completion_mode or 'ALL',
        completion_count = spec.completion_count,
        next_stage_id = spec.next_stage_id,
        checkpoint = spec.checkpoint == true,
        journal_text_key = 'stage.' .. spec.id .. '.journal',
        deprecated = false,
    }
end

local function quest(spec)
    local row = {
        id = spec.id,
        schema_version = SCHEMA_VERSION,
        definition_version = DEFINITION_VERSION,
        rules_version = RULES_VERSION,
        category = spec.category,
        chapter_id = CHAPTER_ID,
        title_key = 'quest.' .. spec.id .. '.title',
        summary_key = 'quest.' .. spec.id .. '.summary',
        visibility_policy = spec.visibility_policy or 'VISIBLE_WHEN_AVAILABLE',
        accept_policy = spec.accept_policy,
        accept_ref_id = spec.accept_ref_id,
        prerequisite_quest_id = spec.prerequisite_quest_id,
        first_stage_id = spec.first_stage_id,
        stage_ids = spec.stage_ids,
        reward_policy = spec.reward_policy or 'AUTO_ON_COMPLETE',
        turn_in_npc_id = spec.turn_in_npc_id,
        reward_id = spec.reward_id,
        abandon_policy = spec.abandon_policy,
        failure_policy = spec.failure_policy or 'NO_FAIL',
        journal_sort_order = spec.journal_sort_order,
        deprecated = false,
    }
    if row.category == 'MAIN' then
        row.abandon_policy = 'DENY'
    elseif row.abandon_policy == nil then
        row.abandon_policy = 'ALLOW_RESET_RUN'
    end
    if row.reward_policy == 'NO_REWARD' then
        row.reward_id = nil
    end
    return row
end

function Chapter01.build_source()
    local objectives = {}
    local stages = {}
    local quests = {}

    local function add_objective(spec)
        objectives[#objectives + 1] = objective(spec)
    end
    local function add_stage(spec)
        stages[#stages + 1] = stage(spec)
    end
    local function add_quest(spec)
        quests[#quests + 1] = quest(spec)
    end

    -- ── Main 01 夜投雾津 ──────────────────────────────────────────
    add_objective({
        id = 'objective_main_01_reach_hall',
        stage_id = 'stage_main_01_arrive',
        objective_type = 'REACH_LOCATION',
        target_id = 'location_mist_ferry_hall',
        progress_semantics = 'ONCE_FACT',
        event_type = 'LocationDiscovered',
        guide_ref_id = 'location_mist_ferry_hall',
    })
    add_objective({
        id = 'objective_main_01_talk_hire',
        stage_id = 'stage_main_01_hire',
        objective_type = 'TALK',
        target_id = 'dialogue_main_01_post_hire',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_post_master',
    })
    add_stage({
        id = 'stage_main_01_arrive',
        quest_id = 'quest_main_01_night_ferry',
        objective_ids = { 'objective_main_01_reach_hall' },
        next_stage_id = 'stage_main_01_hire',
        checkpoint = true,
    })
    add_stage({
        id = 'stage_main_01_hire',
        quest_id = 'quest_main_01_night_ferry',
        objective_ids = { 'objective_main_01_talk_hire' },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_01_night_ferry',
        category = 'MAIN',
        accept_policy = 'AUTO_EVENT',
        first_stage_id = 'stage_main_01_arrive',
        stage_ids = { 'stage_main_01_arrive', 'stage_main_01_hire' },
        reward_id = 'reward_main_01',
        journal_sort_order = 10,
    })

    -- ── Main 02 驿道灭口 ──────────────────────────────────────────
    add_objective({
        id = 'objective_main_02_reach_ambush',
        stage_id = 'stage_main_02_site',
        objective_type = 'REACH_LOCATION',
        target_id = 'location_road_ambush',
        progress_semantics = 'ONCE_FACT',
        event_type = 'LocationDiscovered',
        guide_ref_id = 'location_road_ambush',
    })
    add_objective({
        id = 'objective_main_02_clear_ambush',
        stage_id = 'stage_main_02_fight',
        objective_type = 'COMPLETE_ENCOUNTER',
        target_id = 'encounter_main_02_road_ambush',
        progress_semantics = 'ONCE_FACT',
        event_type = 'EncounterCompleted',
        guide_ref_id = 'location_road_ambush',
    })
    add_objective({
        id = 'objective_main_02_search_site',
        stage_id = 'stage_main_02_fight',
        objective_type = 'SEARCH_POINT',
        target_id = 'interact_ambush_search',
        progress_semantics = 'ONCE_FACT',
        event_type = 'SearchPointResolved',
        guide_ref_id = 'interact_ambush_search',
    })
    add_stage({
        id = 'stage_main_02_site',
        quest_id = 'quest_main_02_road_silencing',
        objective_ids = { 'objective_main_02_reach_ambush' },
        next_stage_id = 'stage_main_02_fight',
        checkpoint = true,
    })
    add_stage({
        id = 'stage_main_02_fight',
        quest_id = 'quest_main_02_road_silencing',
        objective_ids = {
            'objective_main_02_clear_ambush',
            'objective_main_02_search_site',
        },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_02_road_silencing',
        category = 'MAIN',
        accept_policy = 'AUTO_EVENT',
        prerequisite_quest_id = 'quest_main_01_night_ferry',
        first_stage_id = 'stage_main_02_site',
        stage_ids = { 'stage_main_02_site', 'stage_main_02_fight' },
        reward_id = 'reward_main_02',
        journal_sort_order = 20,
    })

    -- ── Main 03 雾病与黑木 ────────────────────────────────────────
    add_objective({
        id = 'objective_main_03_reach_gate',
        stage_id = 'stage_main_03_gate',
        objective_type = 'REACH_LOCATION',
        target_id = 'location_blackwood_gate',
        progress_semantics = 'ONCE_FACT',
        event_type = 'LocationDiscovered',
        guide_ref_id = 'location_blackwood_gate',
    })
    add_objective({
        id = 'objective_main_03_talk_su',
        stage_id = 'stage_main_03_rescue',
        objective_type = 'TALK',
        target_id = 'dialogue_main_03_su_join',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_partner_su_jianwei',
    })
    add_stage({
        id = 'stage_main_03_gate',
        quest_id = 'quest_main_03_mist_and_wood',
        objective_ids = { 'objective_main_03_reach_gate' },
        next_stage_id = 'stage_main_03_rescue',
        checkpoint = true,
    })
    add_stage({
        id = 'stage_main_03_rescue',
        quest_id = 'quest_main_03_mist_and_wood',
        objective_ids = { 'objective_main_03_talk_su' },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_03_mist_and_wood',
        category = 'MAIN',
        accept_policy = 'AUTO_EVENT',
        prerequisite_quest_id = 'quest_main_02_road_silencing',
        first_stage_id = 'stage_main_03_gate',
        stage_ids = { 'stage_main_03_gate', 'stage_main_03_rescue' },
        reward_id = 'reward_main_03',
        journal_sort_order = 30,
    })

    -- ── Main 04 岭上没有匪 ────────────────────────────────────────
    add_objective({
        id = 'objective_main_04_search_kiln',
        stage_id = 'stage_main_04_probe',
        objective_type = 'SEARCH_POINT',
        target_id = 'interact_ridge_kiln',
        progress_semantics = 'ONCE_FACT',
        event_type = 'SearchPointResolved',
        guide_ref_id = 'interact_ridge_kiln',
    })
    add_objective({
        id = 'objective_main_04_search_stele',
        stage_id = 'stage_main_04_probe',
        objective_type = 'SEARCH_POINT',
        target_id = 'interact_ridge_stele',
        progress_semantics = 'ONCE_FACT',
        event_type = 'SearchPointResolved',
        guide_ref_id = 'interact_ridge_stele',
    })
    add_objective({
        id = 'objective_main_04_gap_jump',
        stage_id = 'stage_main_04_jump',
        objective_type = 'TRAVERSAL_LANDING',
        target_id = 'traversal_cell_ridge_gap_landing',
        progress_semantics = 'ONCE_FACT',
        event_type = 'TraversalLanded',
        guide_ref_id = 'traversal_cell_ridge_gap_landing',
    })
    add_objective({
        id = 'objective_main_04_talk_huo',
        stage_id = 'stage_main_04_jump',
        objective_type = 'TALK',
        target_id = 'dialogue_main_04_huo_join',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_partner_huo_xiaoman',
    })
    add_stage({
        id = 'stage_main_04_probe',
        quest_id = 'quest_main_04_no_bandits',
        objective_ids = {
            'objective_main_04_search_kiln',
            'objective_main_04_search_stele',
        },
        next_stage_id = 'stage_main_04_jump',
        checkpoint = true,
    })
    add_stage({
        id = 'stage_main_04_jump',
        quest_id = 'quest_main_04_no_bandits',
        objective_ids = {
            'objective_main_04_gap_jump',
            'objective_main_04_talk_huo',
        },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_04_no_bandits',
        category = 'MAIN',
        accept_policy = 'AUTO_EVENT',
        prerequisite_quest_id = 'quest_main_03_mist_and_wood',
        first_stage_id = 'stage_main_04_probe',
        stage_ids = { 'stage_main_04_probe', 'stage_main_04_jump' },
        reward_id = 'reward_main_04',
        journal_sort_order = 40,
    })

    -- ── Main 05 夺证之人 ──────────────────────────────────────────
    add_objective({
        id = 'objective_main_05_confront',
        stage_id = 'stage_main_05_confront',
        objective_type = 'TALK',
        target_id = 'dialogue_main_05_ke_confront',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_boss_ke_lishan',
    })
    add_objective({
        id = 'objective_main_05_boss',
        stage_id = 'stage_main_05_boss',
        objective_type = 'COMPLETE_ENCOUNTER',
        target_id = 'encounter_main_05_ke_lishan',
        progress_semantics = 'ONCE_FACT',
        event_type = 'EncounterCompleted',
        guide_ref_id = 'npc_boss_ke_lishan',
    })
    add_stage({
        id = 'stage_main_05_confront',
        quest_id = 'quest_main_05_proof_taker',
        objective_ids = { 'objective_main_05_confront' },
        next_stage_id = 'stage_main_05_boss',
        checkpoint = true,
    })
    add_stage({
        id = 'stage_main_05_boss',
        quest_id = 'quest_main_05_proof_taker',
        objective_ids = { 'objective_main_05_boss' },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_05_proof_taker',
        category = 'MAIN',
        accept_policy = 'AUTO_EVENT',
        prerequisite_quest_id = 'quest_main_04_no_bandits',
        first_stage_id = 'stage_main_05_confront',
        stage_ids = { 'stage_main_05_confront', 'stage_main_05_boss' },
        reward_id = 'reward_main_05',
        journal_sort_order = 50,
    })

    -- ── Main 06 子夜旧钟 ──────────────────────────────────────────
    add_objective({
        id = 'objective_main_06_reach_court',
        stage_id = 'stage_main_06_court',
        objective_type = 'REACH_LOCATION',
        target_id = 'location_sunken_bell_court',
        progress_semantics = 'ONCE_FACT',
        event_type = 'LocationDiscovered',
        guide_ref_id = 'location_sunken_bell_court',
    })
    add_objective({
        id = 'objective_main_06_talk_wen',
        stage_id = 'stage_main_06_enter',
        objective_type = 'TALK',
        target_id = 'dialogue_main_06_wen_join',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_partner_wen_hesheng',
    })
    add_stage({
        id = 'stage_main_06_court',
        quest_id = 'quest_main_06_midnight_bell',
        objective_ids = { 'objective_main_06_reach_court' },
        next_stage_id = 'stage_main_06_enter',
        checkpoint = true,
    })
    add_stage({
        id = 'stage_main_06_enter',
        quest_id = 'quest_main_06_midnight_bell',
        objective_ids = { 'objective_main_06_talk_wen' },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_06_midnight_bell',
        category = 'MAIN',
        accept_policy = 'AUTO_EVENT',
        prerequisite_quest_id = 'quest_main_05_proof_taker',
        first_stage_id = 'stage_main_06_court',
        stage_ids = { 'stage_main_06_court', 'stage_main_06_enter' },
        reward_id = 'reward_main_06',
        journal_sort_order = 60,
    })

    -- ── Main 07 钟下遗证 ──────────────────────────────────────────
    add_objective({
        id = 'objective_main_07_reach_cavern',
        stage_id = 'stage_main_07_cavern',
        objective_type = 'REACH_LOCATION',
        target_id = 'location_bell_cavern',
        progress_semantics = 'ONCE_FACT',
        event_type = 'LocationDiscovered',
        guide_ref_id = 'location_bell_cavern',
    })
    add_objective({
        id = 'objective_main_07_search_plates',
        stage_id = 'stage_main_07_proof',
        objective_type = 'SEARCH_POINT',
        target_id = 'interact_cavern_nameplate',
        progress_semantics = 'ONCE_FACT',
        event_type = 'SearchPointResolved',
        guide_ref_id = 'interact_cavern_nameplate',
    })
    add_stage({
        id = 'stage_main_07_cavern',
        quest_id = 'quest_main_07_proof_under_bell',
        objective_ids = { 'objective_main_07_reach_cavern' },
        next_stage_id = 'stage_main_07_proof',
        checkpoint = true,
    })
    add_stage({
        id = 'stage_main_07_proof',
        quest_id = 'quest_main_07_proof_under_bell',
        objective_ids = { 'objective_main_07_search_plates' },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_07_proof_under_bell',
        category = 'MAIN',
        accept_policy = 'AUTO_EVENT',
        prerequisite_quest_id = 'quest_main_06_midnight_bell',
        first_stage_id = 'stage_main_07_cavern',
        stage_ids = { 'stage_main_07_cavern', 'stage_main_07_proof' },
        reward_id = 'reward_main_07',
        journal_sort_order = 70,
    })

    -- ── Main 08 守院人 ────────────────────────────────────────────
    add_objective({
        id = 'objective_main_08_boss',
        stage_id = 'stage_main_08_boss',
        objective_type = 'COMPLETE_ENCOUNTER',
        target_id = 'encounter_main_08_meng_jiansheng',
        progress_semantics = 'ONCE_FACT',
        event_type = 'EncounterCompleted',
        guide_ref_id = 'npc_boss_meng_jiansheng',
    })
    add_stage({
        id = 'stage_main_08_boss',
        quest_id = 'quest_main_08_last_warden',
        objective_ids = { 'objective_main_08_boss' },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_08_last_warden',
        category = 'MAIN',
        accept_policy = 'AUTO_EVENT',
        prerequisite_quest_id = 'quest_main_07_proof_under_bell',
        first_stage_id = 'stage_main_08_boss',
        stage_ids = { 'stage_main_08_boss' },
        reward_id = 'reward_main_08',
        journal_sort_order = 80,
    })

    -- ── Main 09 证物交谁 ──────────────────────────────────────────
    add_objective({
        id = 'objective_main_09_choice',
        stage_id = 'stage_main_09_choice',
        objective_type = 'TALK',
        target_id = 'dialogue_main_09_proof_choice',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_post_master',
    })
    add_stage({
        id = 'stage_main_09_choice',
        quest_id = 'quest_main_09_who_holds_proof',
        objective_ids = { 'objective_main_09_choice' },
        checkpoint = true,
    })
    add_quest({
        id = 'quest_main_09_who_holds_proof',
        category = 'MAIN',
        accept_policy = 'MANUAL_NPC',
        accept_ref_id = 'npc_post_master',
        prerequisite_quest_id = 'quest_main_08_last_warden',
        first_stage_id = 'stage_main_09_choice',
        stage_ids = { 'stage_main_09_choice' },
        reward_id = 'reward_main_09',
        journal_sort_order = 90,
    })

    -- ── Side 01 雾里寻铃 ──────────────────────────────────────────
    add_objective({
        id = 'objective_side_01_search_bell',
        stage_id = 'stage_side_01_search',
        objective_type = 'SEARCH_POINT',
        target_id = 'interact_side_bell',
        progress_semantics = 'ONCE_FACT',
        event_type = 'SearchPointResolved',
        guide_ref_id = 'interact_side_bell',
    })
    add_objective({
        id = 'objective_side_01_turn_in',
        stage_id = 'stage_side_01_turn_in',
        objective_type = 'TALK',
        target_id = 'dialogue_side_01_return_bell',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_post_boy',
    })
    add_stage({
        id = 'stage_side_01_search',
        quest_id = 'quest_side_01_find_bell',
        objective_ids = { 'objective_side_01_search_bell' },
        next_stage_id = 'stage_side_01_turn_in',
    })
    add_stage({
        id = 'stage_side_01_turn_in',
        quest_id = 'quest_side_01_find_bell',
        objective_ids = { 'objective_side_01_turn_in' },
    })
    add_quest({
        id = 'quest_side_01_find_bell',
        category = 'SIDE',
        accept_policy = 'MANUAL_NPC',
        accept_ref_id = 'npc_post_boy',
        prerequisite_quest_id = 'quest_main_01_night_ferry',
        first_stage_id = 'stage_side_01_search',
        stage_ids = { 'stage_side_01_search', 'stage_side_01_turn_in' },
        reward_id = 'reward_side_01',
        journal_sort_order = 110,
    })

    -- ── Side 02 乌檀取脂 ──────────────────────────────────────────
    add_objective({
        id = 'objective_side_02_own_resin',
        stage_id = 'stage_side_02_gather',
        objective_type = 'OWN_ITEM',
        target_id = 'item_black_resin',
        required_count = 3,
        progress_semantics = 'CURRENT_SNAPSHOT',
        include_pre_accept = false,
        guide_ref_id = 'location_blackwood_gate',
    })
    add_objective({
        id = 'objective_side_02_deliver',
        stage_id = 'stage_side_02_deliver',
        objective_type = 'DELIVER_ITEM',
        target_id = 'item_black_resin',
        required_count = 3,
        progress_semantics = 'DELIVER_AT_TURN_IN',
        guide_ref_id = 'npc_partner_su_jianwei',
    })
    add_stage({
        id = 'stage_side_02_gather',
        quest_id = 'quest_side_02_black_resin',
        objective_ids = { 'objective_side_02_own_resin' },
        next_stage_id = 'stage_side_02_deliver',
    })
    add_stage({
        id = 'stage_side_02_deliver',
        quest_id = 'quest_side_02_black_resin',
        objective_ids = { 'objective_side_02_deliver' },
    })
    add_quest({
        id = 'quest_side_02_black_resin',
        category = 'SIDE',
        accept_policy = 'MANUAL_NPC',
        accept_ref_id = 'npc_partner_su_jianwei',
        prerequisite_quest_id = 'quest_main_03_mist_and_wood',
        first_stage_id = 'stage_side_02_gather',
        stage_ids = { 'stage_side_02_gather', 'stage_side_02_deliver' },
        reward_policy = 'TURN_IN_NPC',
        turn_in_npc_id = 'npc_partner_su_jianwei',
        reward_id = 'reward_side_02',
        journal_sort_order = 120,
    })

    -- ── Side 03 断轴重铆 ──────────────────────────────────────────
    add_objective({
        id = 'objective_side_03_own_rivet',
        stage_id = 'stage_side_03_parts',
        objective_type = 'OWN_ITEM',
        target_id = 'item_axle_rivet',
        required_count = 1,
        progress_semantics = 'CURRENT_SNAPSHOT',
        guide_ref_id = 'npc_relay_carter',
    })
    add_objective({
        id = 'objective_side_03_talk_done',
        stage_id = 'stage_side_03_fix',
        objective_type = 'TALK',
        target_id = 'dialogue_side_03_axle_done',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_relay_carter',
    })
    add_stage({
        id = 'stage_side_03_parts',
        quest_id = 'quest_side_03_axle_rivet',
        objective_ids = { 'objective_side_03_own_rivet' },
        next_stage_id = 'stage_side_03_fix',
    })
    add_stage({
        id = 'stage_side_03_fix',
        quest_id = 'quest_side_03_axle_rivet',
        objective_ids = { 'objective_side_03_talk_done' },
    })
    add_quest({
        id = 'quest_side_03_axle_rivet',
        category = 'SIDE',
        accept_policy = 'MANUAL_NPC',
        accept_ref_id = 'npc_relay_carter',
        prerequisite_quest_id = 'quest_main_02_road_silencing',
        first_stage_id = 'stage_side_03_parts',
        stage_ids = { 'stage_side_03_parts', 'stage_side_03_fix' },
        reward_id = 'reward_side_03',
        journal_sort_order = 130,
    })

    -- ── Side 04 三步护行 ──────────────────────────────────────────
    add_objective({
        id = 'objective_side_04_talk_drill',
        stage_id = 'stage_side_04_drill',
        objective_type = 'TALK',
        target_id = 'dialogue_side_04_formation',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'npc_partner_liang_jibai',
    })
    add_stage({
        id = 'stage_side_04_drill',
        quest_id = 'quest_side_04_three_steps',
        objective_ids = { 'objective_side_04_talk_drill' },
    })
    add_quest({
        id = 'quest_side_04_three_steps',
        category = 'SIDE',
        accept_policy = 'MANUAL_NPC',
        accept_ref_id = 'npc_partner_liang_jibai',
        prerequisite_quest_id = 'quest_main_03_mist_and_wood',
        first_stage_id = 'stage_side_04_drill',
        stage_ids = { 'stage_side_04_drill' },
        reward_policy = 'NO_REWARD',
        journal_sort_order = 140,
    })

    -- ── Side 05 石门后的碑 ────────────────────────────────────────
    add_objective({
        id = 'objective_side_05_search',
        stage_id = 'stage_side_05_find',
        objective_type = 'SEARCH_POINT',
        target_id = 'interact_side_hidden_stele',
        progress_semantics = 'ONCE_FACT',
        event_type = 'SearchPointResolved',
        guide_ref_id = 'interact_side_hidden_stele',
    })
    add_stage({
        id = 'stage_side_05_find',
        quest_id = 'quest_side_05_stele_behind_door',
        objective_ids = { 'objective_side_05_search' },
    })
    add_quest({
        id = 'quest_side_05_stele_behind_door',
        category = 'SIDE',
        visibility_policy = 'HIDDEN_UNTIL_REVEALED',
        accept_policy = 'AUTO_CONDITION',
        prerequisite_quest_id = 'quest_main_04_no_bandits',
        first_stage_id = 'stage_side_05_find',
        stage_ids = { 'stage_side_05_find' },
        reward_policy = 'NO_REWARD',
        journal_sort_order = 150,
    })

    -- ── Side 06 夜谈刀剑 ──────────────────────────────────────────
    add_objective({
        id = 'objective_side_06_talk',
        stage_id = 'stage_side_06_camp',
        objective_type = 'TALK',
        target_id = 'dialogue_side_06_night_talk',
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        guide_ref_id = 'location_blackwood_gate',
    })
    add_stage({
        id = 'stage_side_06_camp',
        quest_id = 'quest_side_06_night_talk',
        objective_ids = { 'objective_side_06_talk' },
    })
    add_quest({
        id = 'quest_side_06_night_talk',
        category = 'SIDE',
        accept_policy = 'AUTO_EVENT',
        prerequisite_quest_id = 'quest_main_05_proof_taker',
        first_stage_id = 'stage_side_06_camp',
        stage_ids = { 'stage_side_06_camp' },
        reward_policy = 'NO_REWARD',
        journal_sort_order = 160,
    })

    return {
        objective_definitions = objectives,
        stage_definitions = stages,
        quest_definitions = quests,
    }
end

function Chapter01.main_quest_ids()
    return {
        'quest_main_01_night_ferry',
        'quest_main_02_road_silencing',
        'quest_main_03_mist_and_wood',
        'quest_main_04_no_bandits',
        'quest_main_05_proof_taker',
        'quest_main_06_midnight_bell',
        'quest_main_07_proof_under_bell',
        'quest_main_08_last_warden',
        'quest_main_09_who_holds_proof',
    }
end

function Chapter01.side_quest_ids()
    return {
        'quest_side_01_find_bell',
        'quest_side_02_black_resin',
        'quest_side_03_axle_rivet',
        'quest_side_04_three_steps',
        'quest_side_05_stele_behind_door',
        'quest_side_06_night_talk',
    }
end

function Chapter01.seal()
    return QuestCatalog.seal(Chapter01.build_source())
end

return Chapter01
