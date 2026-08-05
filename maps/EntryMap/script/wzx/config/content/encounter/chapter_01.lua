-- Chapter 01 encounters: road ambush + Ke Lishan + Meng Jiansheng (direction 3).

local EncounterCatalog = require 'wzx.config.schema.encounter.catalog'

local Chapter01 = {}
local SV, RV = 1, 1

local function formula_basic()
    return {
        id = 'formula_ch01_enemy',
        formula_version = 1,
        base_hp = 40,
        hp_per_level = 8,
        hp_per_constitution = 4,
        base_attack = 8,
        attack_per_level = 2,
        attack_per_strength = 1,
        attack_per_inner_power_milli = 0,
        base_defense = 2,
        defense_per_level = 1,
        defense_per_constitution = 1,
        base_speed = 80,
        speed_per_agility = 2,
        base_accuracy = 7000,
        accuracy_per_agility = 20,
        base_evasion = 0,
        evasion_per_agility = 5,
        base_max_qi = 100,
        max_qi_per_inner_power = 0,
        effect_accuracy_per_inner_power = 0,
        effect_resistance_per_constitution = 5,
    }
end

local function rank_multipliers()
    return {
        NORMAL = 10000,
        ELITE = 12000,
        BOSS = 15000,
        SUMMON = 8000,
        MECHANIC_OBJECT = 10000,
    }
end

local function basic_move(move_id, attack_ratio_bp)
    return {
        move_id = move_id,
        move_type = 'BASIC',
        qi_cost = 0,
        action_cooldown = 0,
        on_hit_qi_gain = 5,
        damage = {
            damage_type = 'PHYSICAL',
            attack_ratio_bp = attack_ratio_bp or 10000,
            flat_damage = 0,
            hit_mode = 'UNMISSABLE',
            variance_min_bp = 10000,
            variance_max_bp = 10000,
            can_crit = false,
            can_block = false,
            minimum_damage = 1,
        },
    }
end

local function active_move(move_id, qi_cost)
    return {
        move_id = move_id,
        move_type = 'ACTIVE',
        qi_cost = qi_cost or 30,
        action_cooldown = 2,
        on_hit_qi_gain = 0,
        damage = {
            damage_type = 'PHYSICAL',
            attack_ratio_bp = 14000,
            flat_damage = 0,
            hit_mode = 'UNMISSABLE',
            variance_min_bp = 10000,
            variance_max_bp = 10000,
            can_crit = false,
            can_block = false,
            minimum_damage = 1,
        },
    }
end

function Chapter01.build_source()
    return {
        enemy_stat_profiles = {
            {
                id = 'statprof_ch01_normal',
                schema_version = SV,
                rules_version = RV,
                base_primary = {
                    strength = 8,
                    constitution = 8,
                    agility = 6,
                    inner_power = 4,
                },
                growth_per_level_milli = {
                    strength = 400,
                    constitution = 400,
                    agility = 300,
                    inner_power = 100,
                },
                formula = formula_basic(),
                flat_combat_contributions = {},
                rank_multiplier_bp = rank_multipliers(),
                level_min = 1,
                level_max = 30,
                initial_qi = 0,
            },
            {
                id = 'statprof_ch01_boss',
                schema_version = SV,
                rules_version = RV,
                base_primary = {
                    strength = 14,
                    constitution = 16,
                    agility = 8,
                    inner_power = 8,
                },
                growth_per_level_milli = {
                    strength = 500,
                    constitution = 600,
                    agility = 300,
                    inner_power = 200,
                },
                formula = formula_basic(),
                flat_combat_contributions = {},
                rank_multiplier_bp = rank_multipliers(),
                level_min = 1,
                level_max = 40,
                initial_qi = 20,
            },
        },
        enemy_move_sets = {
            {
                id = 'moveset_ch01_blade',
                schema_version = SV,
                rules_version = RV,
                basic_move = basic_move('move_ch01_blade_slash'),
                active_moves = {},
            },
            {
                id = 'moveset_ch01_ke',
                schema_version = SV,
                rules_version = RV,
                basic_move = basic_move('move_ch01_ke_cut', 11000),
                active_moves = {
                    active_move('move_ch01_ke_mark', 25),
                },
            },
            {
                id = 'moveset_ch01_meng',
                schema_version = SV,
                rules_version = RV,
                basic_move = basic_move('move_ch01_meng_strike', 10500),
                active_moves = {
                    active_move('move_ch01_meng_silence', 35),
                },
            },
        },
        enemy_definitions = {
            {
                id = 'enemy_ch01_silencer',
                schema_version = SV,
                rules_version = RV,
                enemy_class = 'NORMAL',
                display_name_key = 'enemy.ch01_silencer.name',
                description_key = 'enemy.ch01_silencer.desc',
                stat_profile_id = 'statprof_ch01_normal',
                move_set_id = 'moveset_ch01_blade',
                ai_profile_id = 'ai_ch01_melee',
                default_tags = { 'human', 'silencer' },
                loot_table_id = 'loot_ch01_silencer',
                model_asset_id = 'asset_model_ch01_silencer',
                portrait_asset_id = 'asset_portrait_ch01_silencer',
            },
            {
                id = 'enemy_ch01_shield',
                schema_version = SV,
                rules_version = RV,
                enemy_class = 'NORMAL',
                display_name_key = 'enemy.ch01_shield.name',
                description_key = 'enemy.ch01_shield.desc',
                stat_profile_id = 'statprof_ch01_normal',
                move_set_id = 'moveset_ch01_blade',
                ai_profile_id = 'ai_ch01_guard',
                default_tags = { 'human', 'shield' },
                loot_table_id = 'loot_ch01_shield',
                model_asset_id = 'asset_model_ch01_shield',
                portrait_asset_id = 'asset_portrait_ch01_shield',
            },
            {
                id = 'enemy_boss_ke_lishan',
                schema_version = SV,
                rules_version = RV,
                enemy_class = 'BOSS',
                display_name_key = 'enemy.ke_lishan.name',
                description_key = 'enemy.ke_lishan.desc',
                stat_profile_id = 'statprof_ch01_boss',
                move_set_id = 'moveset_ch01_ke',
                ai_profile_id = 'ai_ch01_ke_p1',
                default_tags = { 'boss', 'grey_smoke', 'human' },
                model_asset_id = 'asset_model_ke_lishan',
                portrait_asset_id = 'asset_portrait_ke_lishan',
            },
            {
                id = 'enemy_boss_meng_jiansheng',
                schema_version = SV,
                rules_version = RV,
                enemy_class = 'BOSS',
                display_name_key = 'enemy.meng_jiansheng.name',
                description_key = 'enemy.meng_jiansheng.desc',
                stat_profile_id = 'statprof_ch01_boss',
                move_set_id = 'moveset_ch01_meng',
                ai_profile_id = 'ai_ch01_meng_p1',
                default_tags = { 'boss', 'human', 'warden' },
                model_asset_id = 'asset_model_meng_jiansheng',
                portrait_asset_id = 'asset_portrait_meng_jiansheng',
            },
        },
        wave_definitions = {
            {
                id = 'wave_main_02_ambush',
                schema_version = SV,
                rules_version = RV,
                wave_index = 1,
                spawn_rows = {
                    {
                        spawn_id = 'spawn_main_02_a',
                        enemy_id = 'enemy_ch01_silencer',
                        level = 3,
                        position_index = 0,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 1,
                    },
                    {
                        spawn_id = 'spawn_main_02_b',
                        enemy_id = 'enemy_ch01_silencer',
                        level = 3,
                        position_index = 2,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 2,
                    },
                },
                presentation_cue_id = 'cue_main_02_ambush',
            },
            {
                id = 'wave_main_05_ke',
                schema_version = SV,
                rules_version = RV,
                wave_index = 1,
                spawn_rows = {
                    {
                        spawn_id = 'spawn_main_05_shield_a',
                        enemy_id = 'enemy_ch01_shield',
                        level = 5,
                        position_index = 0,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 1,
                    },
                    {
                        spawn_id = 'spawn_main_05_shield_b',
                        enemy_id = 'enemy_ch01_shield',
                        level = 5,
                        position_index = 2,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 2,
                    },
                    {
                        spawn_id = 'spawn_main_05_ke',
                        enemy_id = 'enemy_boss_ke_lishan',
                        level = 6,
                        position_index = 4,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 3,
                    },
                },
                presentation_cue_id = 'cue_main_05_ke',
            },
            {
                id = 'wave_main_08_meng',
                schema_version = SV,
                rules_version = RV,
                wave_index = 1,
                spawn_rows = {
                    {
                        spawn_id = 'spawn_main_08_meng',
                        enemy_id = 'enemy_boss_meng_jiansheng',
                        level = 8,
                        position_index = 4,
                        initial_status_ids = {},
                        counts_for_victory = true,
                        spawn_order = 1,
                    },
                },
                presentation_cue_id = 'cue_main_08_meng',
            },
        },
        boss_phase_definitions = {
            {
                id = 'bossphase_ke_1',
                schema_version = SV,
                rules_version = RV,
                phase_index = 1,
                trigger = 'HP_AT_OR_BELOW_BP',
                trigger_value = 10000,
                presentation_cue_id = 'cue_ke_phase_1',
            },
            {
                id = 'bossphase_ke_2',
                schema_version = SV,
                rules_version = RV,
                phase_index = 2,
                trigger = 'HP_AT_OR_BELOW_BP',
                trigger_value = 5000,
                add_move_ids = { 'move_ch01_ke_mark' },
                ai_profile_override_id = 'ai_ch01_ke_p2',
                presentation_cue_id = 'cue_ke_phase_2',
            },
            {
                id = 'bossphase_meng_1',
                schema_version = SV,
                rules_version = RV,
                phase_index = 1,
                trigger = 'HP_AT_OR_BELOW_BP',
                trigger_value = 10000,
                presentation_cue_id = 'cue_meng_phase_1',
            },
            {
                id = 'bossphase_meng_2',
                schema_version = SV,
                rules_version = RV,
                phase_index = 2,
                trigger = 'HP_AT_OR_BELOW_BP',
                trigger_value = 4000,
                add_move_ids = { 'move_ch01_meng_silence' },
                ai_profile_override_id = 'ai_ch01_meng_p2',
                presentation_cue_id = 'cue_meng_phase_2',
            },
        },
        boss_controller_definitions = {
            {
                id = 'bossctl_ke_lishan',
                schema_version = SV,
                rules_version = RV,
                boss_spawn_id = 'spawn_main_05_ke',
                phase_ids = { 'bossphase_ke_1', 'bossphase_ke_2' },
                enrage_action_index = 40,
                boss_bar_style_id = 'bossbar_ke',
            },
            {
                id = 'bossctl_meng_jiansheng',
                schema_version = SV,
                rules_version = RV,
                boss_spawn_id = 'spawn_main_08_meng',
                phase_ids = { 'bossphase_meng_1', 'bossphase_meng_2' },
                enrage_action_index = 45,
                boss_bar_style_id = 'bossbar_meng',
            },
        },
        encounter_definitions = {
            {
                id = 'encounter_main_02_road_ambush',
                schema_version = SV,
                rules_version = RV,
                encounter_type = 'STORY',
                name_key = 'encounter.main_02.name',
                description_key = 'encounter.main_02.desc',
                area_id = 'area_mist_ferry_post',
                location_id = 'loc_road_ambush',
                wave_ids = { 'wave_main_02_ambush' },
                seed_policy = 'FIXED',
                fixed_seed = 201,
                first_clear_reward_bundle_id = 'reward_enc_main_02',
                completion_fact_id = 'fact_main_02_ambush_cleared',
            },
            {
                id = 'encounter_main_05_ke_lishan',
                schema_version = SV,
                rules_version = RV,
                encounter_type = 'BOSS',
                name_key = 'encounter.main_05.name',
                description_key = 'encounter.main_05.desc',
                area_id = 'area_blackwood_ridge',
                location_id = 'loc_ke_camp',
                wave_ids = { 'wave_main_05_ke' },
                boss_controller_id = 'bossctl_ke_lishan',
                seed_policy = 'FIXED',
                fixed_seed = 205,
                first_clear_reward_bundle_id = 'reward_enc_main_05',
                completion_fact_id = 'fact_main_05_ke_cleared',
            },
            {
                id = 'encounter_main_08_meng_jiansheng',
                schema_version = SV,
                rules_version = RV,
                encounter_type = 'BOSS',
                name_key = 'encounter.main_08.name',
                description_key = 'encounter.main_08.desc',
                area_id = 'area_underground_bell_cavern',
                location_id = 'loc_bell_cavern',
                wave_ids = { 'wave_main_08_meng' },
                boss_controller_id = 'bossctl_meng_jiansheng',
                seed_policy = 'FIXED',
                fixed_seed = 208,
                first_clear_reward_bundle_id = 'reward_enc_main_08',
                completion_fact_id = 'fact_main_08_meng_cleared',
            },
        },
    }
end

function Chapter01.encounter_ids()
    return {
        'encounter_main_02_road_ambush',
        'encounter_main_05_ke_lishan',
        'encounter_main_08_meng_jiansheng',
    }
end

function Chapter01.seal()
    return EncounterCatalog.seal(Chapter01.build_source())
end

return Chapter01
