-- Chapter 01 dialogue graphs (direction 3). Quest TALK targets hang here.

local DialogueCatalog = require 'wzx.config.schema.dialogue.catalog'

local Chapter01 = {}
local SV, RV, GV = 1, 1, 1

local function push_linear(source, dialogue_id, npc_id, line_count)
    line_count = line_count or 2
    local node_ids = {}
    local prefix = dialogue_id:gsub('^dialogue_', 'dnode_')

    local index
    for index = 1, line_count do
        local node_id = prefix .. '_l' .. tostring(index)
        node_ids[#node_ids + 1] = node_id
        local next_id
        if index < line_count then
            next_id = prefix .. '_l' .. tostring(index + 1)
        else
            next_id = prefix .. '_end'
        end
        source.node_definitions[#source.node_definitions + 1] = {
            id = node_id,
            schema_version = SV,
            rules_version = RV,
            dialogue_id = dialogue_id,
            node_type = 'LINE',
            next_node_id = next_id,
            speaker_id = npc_id,
            text_key = 'dlg.' .. dialogue_id .. '.l' .. tostring(index),
        }
    end

    local end_id = prefix .. '_end'
    node_ids[#node_ids + 1] = end_id
    source.node_definitions[#source.node_definitions + 1] = {
        id = end_id,
        schema_version = SV,
        rules_version = RV,
        dialogue_id = dialogue_id,
        node_type = 'END',
        text_key = 'dlg.' .. dialogue_id .. '.end',
        end_reason = 'COMPLETED',
    }

    source.dialogue_definitions[#source.dialogue_definitions + 1] = {
        id = dialogue_id,
        schema_version = SV,
        graph_version = GV,
        rules_version = RV,
        start_node_id = node_ids[1],
        node_ids = node_ids,
        completion_key = 'dcomp_' .. dialogue_id:gsub('^dialogue_', ''),
        default_npc_id = npc_id,
    }
end

-- M02 战前抵达：梁既白短句（线性）
local function push_main_02_arrive(source)
    push_linear(source, 'dialogue_main_02_ambush_arrive', 'npc_partner_liang_jibai', 2)
end

-- M02 战后现场调查：总览 → 搜匣 → 三选一回应 → 腰牌 → 离开
local function push_main_02_ambush_site(source)
    local dialogue_id = 'dialogue_main_02_ambush_site'
    local npc_id = 'npc_partner_liang_jibai'
    local prefix = 'dnode_main_02_site'
    local choice_set_id = 'choiceset_main_02_site_angle'
    local mem_key = 'dmem_main_02_player_angle'

    source.choice_definitions[#source.choice_definitions + 1] = {
        id = 'choice_main_02_practical',
        schema_version = SV,
        rules_version = RV,
        dialogue_id = dialogue_id,
        choice_set_id = choice_set_id,
        entry_order = 1,
        text_key = 'choice.main_02.practical',
        next_node_id = prefix .. '_reply_practical',
        choice_memory_key = mem_key,
        choice_memory_value = 'practical',
    }
    source.choice_definitions[#source.choice_definitions + 1] = {
        id = 'choice_main_02_challenge',
        schema_version = SV,
        rules_version = RV,
        dialogue_id = dialogue_id,
        choice_set_id = choice_set_id,
        entry_order = 2,
        text_key = 'choice.main_02.challenge',
        next_node_id = prefix .. '_reply_challenge',
        choice_memory_key = mem_key,
        choice_memory_value = 'challenge',
    }
    source.choice_definitions[#source.choice_definitions + 1] = {
        id = 'choice_main_02_observe',
        schema_version = SV,
        rules_version = RV,
        dialogue_id = dialogue_id,
        choice_set_id = choice_set_id,
        entry_order = 3,
        text_key = 'choice.main_02.observe',
        next_node_id = prefix .. '_reply_observe',
        choice_memory_key = mem_key,
        choice_memory_value = 'observe',
    }

    local nodes = {
        -- 战后总览
        {
            id = prefix .. '_overview_1',
            node_type = 'LINE',
            next_node_id = prefix .. '_overview_2',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.overview_1',
        },
        {
            id = prefix .. '_overview_2',
            node_type = 'LINE',
            next_node_id = prefix .. '_overview_3',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.overview_2',
        },
        {
            id = prefix .. '_overview_3',
            node_type = 'LINE',
            next_node_id = prefix .. '_search_1',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.overview_3',
        },
        -- 搜索文书匣后
        {
            id = prefix .. '_search_1',
            node_type = 'LINE',
            next_node_id = prefix .. '_search_2',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.search_1',
        },
        {
            id = prefix .. '_search_2',
            node_type = 'LINE',
            next_node_id = prefix .. '_choice',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.search_2',
        },
        {
            id = prefix .. '_choice',
            node_type = 'CHOICE',
            choice_set_id = choice_set_id,
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.choice_prompt',
        },
        {
            id = prefix .. '_reply_practical',
            node_type = 'LINE',
            next_node_id = prefix .. '_badge_1',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.reply_practical',
        },
        {
            id = prefix .. '_reply_challenge',
            node_type = 'LINE',
            next_node_id = prefix .. '_badge_1',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.reply_challenge',
        },
        {
            id = prefix .. '_reply_observe',
            node_type = 'LINE',
            next_node_id = prefix .. '_badge_1',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.reply_observe',
        },
        -- 腰牌
        {
            id = prefix .. '_badge_1',
            node_type = 'LINE',
            next_node_id = prefix .. '_badge_2',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.badge_1',
        },
        {
            id = prefix .. '_badge_2',
            node_type = 'LINE',
            next_node_id = prefix .. '_leave',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.badge_2',
        },
        {
            id = prefix .. '_leave',
            node_type = 'LINE',
            next_node_id = prefix .. '_end',
            speaker_id = npc_id,
            text_key = 'dlg.main_02.site.leave',
        },
        {
            id = prefix .. '_end',
            node_type = 'END',
            text_key = 'dlg.main_02.site.end',
            end_reason = 'COMPLETED',
        },
    }

    local node_ids = {}
    local index
    for index = 1, #nodes do
        local n = nodes[index]
        node_ids[index] = n.id
        source.node_definitions[#source.node_definitions + 1] = {
            id = n.id,
            schema_version = SV,
            rules_version = RV,
            dialogue_id = dialogue_id,
            node_type = n.node_type,
            next_node_id = n.next_node_id,
            choice_set_id = n.choice_set_id,
            speaker_id = n.speaker_id,
            text_key = n.text_key,
            end_reason = n.end_reason,
        }
    end

    source.dialogue_definitions[#source.dialogue_definitions + 1] = {
        id = dialogue_id,
        schema_version = SV,
        graph_version = GV,
        rules_version = RV,
        start_node_id = prefix .. '_overview_1',
        node_ids = node_ids,
        completion_key = 'dcomp_main_02_ambush_site',
        default_npc_id = npc_id,
        interrupt_policy = 'DENY',
        save_policy = 'CHECKPOINT_ONLY',
    }
end

local function push_choice_dialogue(source)
    local dialogue_id = 'dialogue_main_09_proof_choice'
    local npc_id = 'npc_post_master'
    local prefix = 'dnode_main_09'

    source.choice_definitions[#source.choice_definitions + 1] = {
        id = 'choice_main_09_official',
        schema_version = SV,
        rules_version = RV,
        dialogue_id = dialogue_id,
        choice_set_id = 'choiceset_main_09_proof',
        entry_order = 1,
        text_key = 'choice.main_09.official',
        next_node_id = prefix .. '_official',
        choice_memory_key = 'dmem_proof_holder',
        choice_memory_value = 'official',
    }
    source.choice_definitions[#source.choice_definitions + 1] = {
        id = 'choice_main_09_relay',
        schema_version = SV,
        rules_version = RV,
        dialogue_id = dialogue_id,
        choice_set_id = 'choiceset_main_09_proof',
        entry_order = 2,
        text_key = 'choice.main_09.relay',
        next_node_id = prefix .. '_relay',
        choice_memory_key = 'dmem_proof_holder',
        choice_memory_value = 'relay',
    }
    source.choice_definitions[#source.choice_definitions + 1] = {
        id = 'choice_main_09_public',
        schema_version = SV,
        rules_version = RV,
        dialogue_id = dialogue_id,
        choice_set_id = 'choiceset_main_09_proof',
        entry_order = 3,
        text_key = 'choice.main_09.public',
        next_node_id = prefix .. '_public',
        choice_memory_key = 'dmem_proof_holder',
        choice_memory_value = 'public',
    }

    local nodes = {
        {
            id = prefix .. '_open',
            node_type = 'LINE',
            next_node_id = prefix .. '_choice',
            speaker_id = npc_id,
            text_key = 'dlg.main_09.open',
        },
        {
            id = prefix .. '_choice',
            node_type = 'CHOICE',
            choice_set_id = 'choiceset_main_09_proof',
            speaker_id = npc_id,
            text_key = 'dlg.main_09.choice_prompt',
        },
        {
            id = prefix .. '_official',
            node_type = 'LINE',
            next_node_id = prefix .. '_end',
            speaker_id = npc_id,
            text_key = 'dlg.main_09.official',
        },
        {
            id = prefix .. '_relay',
            node_type = 'LINE',
            next_node_id = prefix .. '_end',
            speaker_id = npc_id,
            text_key = 'dlg.main_09.relay',
        },
        {
            id = prefix .. '_public',
            node_type = 'LINE',
            next_node_id = prefix .. '_end',
            speaker_id = npc_id,
            text_key = 'dlg.main_09.public',
        },
        {
            id = prefix .. '_end',
            node_type = 'END',
            text_key = 'dlg.main_09.end',
            end_reason = 'COMPLETED',
        },
    }

    local node_ids = {}
    local index
    for index = 1, #nodes do
        local n = nodes[index]
        node_ids[index] = n.id
        source.node_definitions[#source.node_definitions + 1] = {
            id = n.id,
            schema_version = SV,
            rules_version = RV,
            dialogue_id = dialogue_id,
            node_type = n.node_type,
            next_node_id = n.next_node_id,
            choice_set_id = n.choice_set_id,
            speaker_id = n.speaker_id,
            text_key = n.text_key,
            end_reason = n.end_reason,
        }
    end

    source.dialogue_definitions[#source.dialogue_definitions + 1] = {
        id = dialogue_id,
        schema_version = SV,
        graph_version = GV,
        rules_version = RV,
        start_node_id = prefix .. '_open',
        node_ids = node_ids,
        completion_key = 'dcomp_main_09_proof_choice',
        default_npc_id = npc_id,
        interrupt_policy = 'DENY',
        save_policy = 'CHECKPOINT_ONLY',
    }
end

function Chapter01.build_source()
    local source = {
        choice_definitions = {},
        node_definitions = {},
        dialogue_definitions = {},
    }

    push_linear(source, 'dialogue_main_01_post_hire', 'npc_post_master', 3)
    push_main_02_arrive(source)
    push_main_02_ambush_site(source)
    push_linear(source, 'dialogue_main_03_su_join', 'npc_partner_su_jianwei', 2)
    push_linear(source, 'dialogue_main_04_huo_join', 'npc_partner_huo_xiaoman', 2)
    push_linear(source, 'dialogue_main_05_ke_confront', 'npc_boss_ke_lishan', 3)
    push_linear(source, 'dialogue_main_06_wen_join', 'npc_partner_wen_hesheng', 2)
    push_choice_dialogue(source)

    push_linear(source, 'dialogue_side_01_return_bell', 'npc_post_boy', 2)
    push_linear(source, 'dialogue_side_03_axle_done', 'npc_relay_carter', 2)
    push_linear(source, 'dialogue_side_04_formation', 'npc_partner_liang_jibai', 2)
    push_linear(source, 'dialogue_side_06_night_talk', 'npc_partner_huo_xiaoman', 2)

    return source
end

function Chapter01.dialogue_ids()
    return {
        'dialogue_main_01_post_hire',
        'dialogue_main_02_ambush_arrive',
        'dialogue_main_02_ambush_site',
        'dialogue_main_03_su_join',
        'dialogue_main_04_huo_join',
        'dialogue_main_05_ke_confront',
        'dialogue_main_06_wen_join',
        'dialogue_main_09_proof_choice',
        'dialogue_side_01_return_bell',
        'dialogue_side_03_axle_done',
        'dialogue_side_04_formation',
        'dialogue_side_06_night_talk',
    }
end

function Chapter01.seal()
    return DialogueCatalog.seal(Chapter01.build_source())
end

return Chapter01
