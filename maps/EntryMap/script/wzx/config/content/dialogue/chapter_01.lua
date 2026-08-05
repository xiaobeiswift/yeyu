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

-- 通用构图：多说话人 LINE / NARRATION / CHOICE / END + choices
local function push_graph(source, graph)
    local dialogue_id = graph.dialogue_id
    local index

    if graph.choices ~= nil then
        for index = 1, #graph.choices do
            local c = graph.choices[index]
            source.choice_definitions[#source.choice_definitions + 1] = {
                id = c.id,
                schema_version = SV,
                rules_version = RV,
                dialogue_id = dialogue_id,
                choice_set_id = c.choice_set_id,
                entry_order = c.entry_order,
                text_key = c.text_key,
                next_node_id = c.next_node_id,
                choice_memory_key = c.choice_memory_key,
                choice_memory_value = c.choice_memory_value,
            }
        end
    end

    local node_ids = {}
    for index = 1, #graph.nodes do
        local n = graph.nodes[index]
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
        start_node_id = graph.start_node_id,
        node_ids = node_ids,
        completion_key = graph.completion_key,
        default_npc_id = graph.default_npc_id,
        interrupt_policy = graph.interrupt_policy or 'DENY',
        save_policy = graph.save_policy or 'CHECKPOINT_ONLY',
    }
end

local KE = 'npc_boss_ke_lishan'
local MENG = 'npc_boss_meng_jiansheng'
local LIANG = 'npc_partner_liang_jibai'
local SU = 'npc_partner_su_jianwei'
local HUO = 'npc_partner_huo_xiaoman'
local WEN = 'npc_partner_wen_hesheng'

-- M02 战前抵达：梁既白短句（线性）
local function push_main_02_arrive(source)
    push_linear(source, 'dialogue_main_02_ambush_arrive', LIANG, 2)
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

-- M05 柯砺山战后：半卷 + 伤者三处置 + 收束沉钟院
local function push_main_05_aftermath(source)
    local p = 'dnode_main_05_aft'
    local set_id = 'choiceset_main_05_wounded'
    local mem = 'dmem_main_05_wounded_custody'
    push_graph(source, {
        dialogue_id = 'dialogue_main_05_aftermath',
        default_npc_id = KE,
        completion_key = 'dcomp_main_05_aftermath',
        start_node_id = p .. '_ke1',
        choices = {
            {
                id = 'choice_main_05_official',
                choice_set_id = set_id,
                entry_order = 1,
                text_key = 'choice.main_05.official',
                next_node_id = p .. '_off1',
                choice_memory_key = mem,
                choice_memory_value = 'official',
            },
            {
                id = 'choice_main_05_relay',
                choice_set_id = set_id,
                entry_order = 2,
                text_key = 'choice.main_05.relay',
                next_node_id = p .. '_rel1',
                choice_memory_key = mem,
                choice_memory_value = 'relay',
            },
            {
                id = 'choice_main_05_huo',
                choice_set_id = set_id,
                entry_order = 3,
                text_key = 'choice.main_05.huo',
                next_node_id = p .. '_huo1',
                choice_memory_key = mem,
                choice_memory_value = 'huo',
            },
        },
        nodes = {
            { id = p .. '_ke1', node_type = 'LINE', next_node_id = p .. '_ke2', speaker_id = KE, text_key = 'dlg.main_05.aft.ke1' },
            { id = p .. '_ke2', node_type = 'LINE', next_node_id = p .. '_huo_q', speaker_id = KE, text_key = 'dlg.main_05.aft.ke2' },
            { id = p .. '_huo_q', node_type = 'LINE', next_node_id = p .. '_ke3', speaker_id = HUO, text_key = 'dlg.main_05.aft.huo_q' },
            { id = p .. '_ke3', node_type = 'LINE', next_node_id = p .. '_ke4', speaker_id = KE, text_key = 'dlg.main_05.aft.ke3' },
            { id = p .. '_ke4', node_type = 'LINE', next_node_id = p .. '_huo_r', speaker_id = KE, text_key = 'dlg.main_05.aft.ke4' },
            { id = p .. '_huo_r', node_type = 'LINE', next_node_id = p .. '_liang1', speaker_id = HUO, text_key = 'dlg.main_05.aft.huo_r' },
            { id = p .. '_liang1', node_type = 'LINE', next_node_id = p .. '_liang2', speaker_id = LIANG, text_key = 'dlg.main_05.aft.liang1' },
            { id = p .. '_liang2', node_type = 'LINE', next_node_id = p .. '_choice', speaker_id = LIANG, text_key = 'dlg.main_05.aft.liang2' },
            { id = p .. '_choice', node_type = 'CHOICE', choice_set_id = set_id, speaker_id = LIANG, text_key = 'dlg.main_05.aft.choice_prompt' },
            -- 交官府
            { id = p .. '_off1', node_type = 'LINE', next_node_id = p .. '_off2', speaker_id = LIANG, text_key = 'dlg.main_05.aft.off1' },
            { id = p .. '_off2', node_type = 'LINE', next_node_id = p .. '_off3', speaker_id = HUO, text_key = 'dlg.main_05.aft.off2' },
            { id = p .. '_off3', node_type = 'LINE', next_node_id = p .. '_off4', speaker_id = KE, text_key = 'dlg.main_05.aft.off3' },
            { id = p .. '_off4', node_type = 'LINE', next_node_id = p .. '_close1', speaker_id = SU, text_key = 'dlg.main_05.aft.off4' },
            -- 交百驿会
            { id = p .. '_rel1', node_type = 'LINE', next_node_id = p .. '_rel2', speaker_id = LIANG, text_key = 'dlg.main_05.aft.rel1' },
            { id = p .. '_rel2', node_type = 'LINE', next_node_id = p .. '_rel3', speaker_id = HUO, text_key = 'dlg.main_05.aft.rel2' },
            { id = p .. '_rel3', node_type = 'LINE', next_node_id = p .. '_rel4', speaker_id = KE, text_key = 'dlg.main_05.aft.rel3' },
            { id = p .. '_rel4', node_type = 'LINE', next_node_id = p .. '_close1', speaker_id = WEN, text_key = 'dlg.main_05.aft.rel4' },
            -- 交霍小满的人
            { id = p .. '_huo1', node_type = 'LINE', next_node_id = p .. '_huo2', speaker_id = HUO, text_key = 'dlg.main_05.aft.huo1' },
            { id = p .. '_huo2', node_type = 'LINE', next_node_id = p .. '_huo3', speaker_id = LIANG, text_key = 'dlg.main_05.aft.huo2' },
            { id = p .. '_huo3', node_type = 'LINE', next_node_id = p .. '_huo4', speaker_id = HUO, text_key = 'dlg.main_05.aft.huo3' },
            { id = p .. '_huo4', node_type = 'LINE', next_node_id = p .. '_huo5', speaker_id = KE, text_key = 'dlg.main_05.aft.huo4' },
            { id = p .. '_huo5', node_type = 'LINE', next_node_id = p .. '_close1', speaker_id = HUO, text_key = 'dlg.main_05.aft.huo5' },
            -- 共同收束
            { id = p .. '_close1', node_type = 'LINE', next_node_id = p .. '_close2', speaker_id = LIANG, text_key = 'dlg.main_05.aft.close1' },
            { id = p .. '_close2', node_type = 'LINE', next_node_id = p .. '_close3', speaker_id = SU, text_key = 'dlg.main_05.aft.close2' },
            { id = p .. '_close3', node_type = 'LINE', next_node_id = p .. '_close4', speaker_id = HUO, text_key = 'dlg.main_05.aft.close3' },
            { id = p .. '_close4', node_type = 'LINE', next_node_id = p .. '_ke_last', speaker_id = LIANG, text_key = 'dlg.main_05.aft.close4' },
            { id = p .. '_ke_last', node_type = 'LINE', next_node_id = p .. '_end', speaker_id = KE, text_key = 'dlg.main_05.aft.ke_last' },
            { id = p .. '_end', node_type = 'END', text_key = 'dlg.main_05.aft.end', end_reason = 'COMPLETED' },
        },
    })
end

-- M07 钟下遗证（紧凑完整体：名牌 → 信物 → 听痕 → 导向 M08）
local function push_main_07_proof(source)
    local p = 'dnode_main_07'
    local set_plate = 'choiceset_main_07_plate'
    local set_token = 'choiceset_main_07_token'
    local mem_plate = 'dmem_main_07_plate_angle'
    local mem_token = 'dmem_main_07_token_angle'
    push_graph(source, {
        dialogue_id = 'dialogue_main_07_proof_under_bell',
        default_npc_id = WEN,
        completion_key = 'dcomp_main_07_proof_under_bell',
        start_node_id = p .. '_a1',
        choices = {
            {
                id = 'choice_main_07_plate_practical',
                choice_set_id = set_plate,
                entry_order = 1,
                text_key = 'choice.main_07.plate.practical',
                next_node_id = p .. '_plate_pr',
                choice_memory_key = mem_plate,
                choice_memory_value = 'practical',
            },
            {
                id = 'choice_main_07_plate_challenge',
                choice_set_id = set_plate,
                entry_order = 2,
                text_key = 'choice.main_07.plate.challenge',
                next_node_id = p .. '_plate_ch',
                choice_memory_key = mem_plate,
                choice_memory_value = 'challenge',
            },
            {
                id = 'choice_main_07_plate_observe',
                choice_set_id = set_plate,
                entry_order = 3,
                text_key = 'choice.main_07.plate.observe',
                next_node_id = p .. '_plate_ob',
                choice_memory_key = mem_plate,
                choice_memory_value = 'observe',
            },
            {
                id = 'choice_main_07_token_practical',
                choice_set_id = set_token,
                entry_order = 1,
                text_key = 'choice.main_07.token.practical',
                next_node_id = p .. '_tok_pr',
                choice_memory_key = mem_token,
                choice_memory_value = 'practical',
            },
            {
                id = 'choice_main_07_token_challenge',
                choice_set_id = set_token,
                entry_order = 2,
                text_key = 'choice.main_07.token.challenge',
                next_node_id = p .. '_tok_ch',
                choice_memory_key = mem_token,
                choice_memory_value = 'challenge',
            },
            {
                id = 'choice_main_07_token_observe',
                choice_set_id = set_token,
                entry_order = 3,
                text_key = 'choice.main_07.token.observe',
                next_node_id = p .. '_tok_ob',
                choice_memory_key = mem_token,
                choice_memory_value = 'observe',
            },
        },
        nodes = {
            -- 入窟
            { id = p .. '_a1', node_type = 'LINE', next_node_id = p .. '_a2', speaker_id = WEN, text_key = 'dlg.main_07.a1' },
            { id = p .. '_a2', node_type = 'LINE', next_node_id = p .. '_a3', speaker_id = LIANG, text_key = 'dlg.main_07.a2' },
            { id = p .. '_a3', node_type = 'LINE', next_node_id = p .. '_a4', speaker_id = HUO, text_key = 'dlg.main_07.a3' },
            { id = p .. '_a4', node_type = 'LINE', next_node_id = p .. '_b1', speaker_id = SU, text_key = 'dlg.main_07.a4' },
            -- 名牌
            { id = p .. '_b1', node_type = 'LINE', next_node_id = p .. '_b2', speaker_id = WEN, text_key = 'dlg.main_07.b1' },
            { id = p .. '_b2', node_type = 'LINE', next_node_id = p .. '_b3', speaker_id = WEN, text_key = 'dlg.main_07.b2' },
            { id = p .. '_b3', node_type = 'LINE', next_node_id = p .. '_b4', speaker_id = HUO, text_key = 'dlg.main_07.b3' },
            { id = p .. '_b4', node_type = 'LINE', next_node_id = p .. '_b5', speaker_id = LIANG, text_key = 'dlg.main_07.b4' },
            { id = p .. '_b5', node_type = 'LINE', next_node_id = p .. '_plate_choice', speaker_id = SU, text_key = 'dlg.main_07.b5' },
            { id = p .. '_plate_choice', node_type = 'CHOICE', choice_set_id = set_plate, speaker_id = WEN, text_key = 'dlg.main_07.plate_prompt' },
            { id = p .. '_plate_pr', node_type = 'LINE', next_node_id = p .. '_c2', speaker_id = WEN, text_key = 'dlg.main_07.plate.pr' },
            { id = p .. '_plate_ch', node_type = 'LINE', next_node_id = p .. '_c2', speaker_id = WEN, text_key = 'dlg.main_07.plate.ch' },
            { id = p .. '_plate_ob', node_type = 'LINE', next_node_id = p .. '_c2', speaker_id = SU, text_key = 'dlg.main_07.plate.ob' },
            -- 信物对上
            { id = p .. '_c2', node_type = 'LINE', next_node_id = p .. '_c3', speaker_id = LIANG, text_key = 'dlg.main_07.c2' },
            { id = p .. '_c3', node_type = 'LINE', next_node_id = p .. '_c4', speaker_id = HUO, text_key = 'dlg.main_07.c3' },
            { id = p .. '_c4', node_type = 'LINE', next_node_id = p .. '_c5', speaker_id = SU, text_key = 'dlg.main_07.c4' },
            { id = p .. '_c5', node_type = 'LINE', next_node_id = p .. '_c6', speaker_id = WEN, text_key = 'dlg.main_07.c5' },
            { id = p .. '_c6', node_type = 'LINE', next_node_id = p .. '_token_choice', speaker_id = WEN, text_key = 'dlg.main_07.c6' },
            { id = p .. '_token_choice', node_type = 'CHOICE', choice_set_id = set_token, speaker_id = WEN, text_key = 'dlg.main_07.token_prompt' },
            { id = p .. '_tok_pr', node_type = 'LINE', next_node_id = p .. '_d1', speaker_id = LIANG, text_key = 'dlg.main_07.token.pr' },
            { id = p .. '_tok_ch', node_type = 'LINE', next_node_id = p .. '_d1', speaker_id = HUO, text_key = 'dlg.main_07.token.ch' },
            { id = p .. '_tok_ob', node_type = 'LINE', next_node_id = p .. '_d1', speaker_id = SU, text_key = 'dlg.main_07.token.ob' },
            -- 听痕
            { id = p .. '_d1', node_type = 'NARRATION', next_node_id = p .. '_d2', text_key = 'dlg.main_07.d1' },
            { id = p .. '_d2', node_type = 'LINE', next_node_id = p .. '_d3', speaker_id = WEN, text_key = 'dlg.main_07.d2' },
            { id = p .. '_d3', node_type = 'LINE', next_node_id = p .. '_d4', speaker_id = LIANG, text_key = 'dlg.main_07.d3' },
            { id = p .. '_d4', node_type = 'LINE', next_node_id = p .. '_d5', speaker_id = HUO, text_key = 'dlg.main_07.d4' },
            { id = p .. '_d5', node_type = 'LINE', next_node_id = p .. '_d6', speaker_id = SU, text_key = 'dlg.main_07.d5' },
            { id = p .. '_d6', node_type = 'LINE', next_node_id = p .. '_e1', speaker_id = WEN, text_key = 'dlg.main_07.d6' },
            -- 收束
            { id = p .. '_e1', node_type = 'LINE', next_node_id = p .. '_e2', speaker_id = LIANG, text_key = 'dlg.main_07.e1' },
            { id = p .. '_e2', node_type = 'LINE', next_node_id = p .. '_e3', speaker_id = WEN, text_key = 'dlg.main_07.e2' },
            { id = p .. '_e3', node_type = 'LINE', next_node_id = p .. '_e4', speaker_id = HUO, text_key = 'dlg.main_07.e3' },
            { id = p .. '_e4', node_type = 'LINE', next_node_id = p .. '_e5', speaker_id = SU, text_key = 'dlg.main_07.e4' },
            { id = p .. '_e5', node_type = 'LINE', next_node_id = p .. '_end', speaker_id = LIANG, text_key = 'dlg.main_07.e5' },
            { id = p .. '_end', node_type = 'END', text_key = 'dlg.main_07.end', end_reason = 'COMPLETED' },
        },
    })
end

-- M08 守院人对峙（开战前三选一，均进战）
local function push_main_08_confront(source)
    local p = 'dnode_main_08_con'
    local set_id = 'choiceset_main_08_prefight'
    local mem = 'dmem_main_08_prefight_angle'
    push_graph(source, {
        dialogue_id = 'dialogue_main_08_meng_confront',
        default_npc_id = MENG,
        completion_key = 'dcomp_main_08_meng_confront',
        start_node_id = p .. '_a1',
        choices = {
            {
                id = 'choice_main_08_practical',
                choice_set_id = set_id,
                entry_order = 1,
                text_key = 'choice.main_08.practical',
                next_node_id = p .. '_pr1',
                choice_memory_key = mem,
                choice_memory_value = 'practical',
            },
            {
                id = 'choice_main_08_challenge',
                choice_set_id = set_id,
                entry_order = 2,
                text_key = 'choice.main_08.challenge',
                next_node_id = p .. '_ch1',
                choice_memory_key = mem,
                choice_memory_value = 'challenge',
            },
            {
                id = 'choice_main_08_observe',
                choice_set_id = set_id,
                entry_order = 3,
                text_key = 'choice.main_08.observe',
                next_node_id = p .. '_ob1',
                choice_memory_key = mem,
                choice_memory_value = 'observe',
            },
        },
        nodes = {
            { id = p .. '_a1', node_type = 'LINE', next_node_id = p .. '_a2', speaker_id = MENG, text_key = 'dlg.main_08.con.a1' },
            { id = p .. '_a2', node_type = 'LINE', next_node_id = p .. '_a3', speaker_id = MENG, text_key = 'dlg.main_08.con.a2' },
            { id = p .. '_a3', node_type = 'LINE', next_node_id = p .. '_a4', speaker_id = MENG, text_key = 'dlg.main_08.con.a3' },
            { id = p .. '_a4', node_type = 'LINE', next_node_id = p .. '_a5', speaker_id = MENG, text_key = 'dlg.main_08.con.a4' },
            { id = p .. '_a5', node_type = 'LINE', next_node_id = p .. '_a6', speaker_id = WEN, text_key = 'dlg.main_08.con.a5' },
            { id = p .. '_a6', node_type = 'LINE', next_node_id = p .. '_a7', speaker_id = MENG, text_key = 'dlg.main_08.con.a6' },
            { id = p .. '_a7', node_type = 'LINE', next_node_id = p .. '_a8', speaker_id = HUO, text_key = 'dlg.main_08.con.a7' },
            { id = p .. '_a8', node_type = 'LINE', next_node_id = p .. '_a9', speaker_id = MENG, text_key = 'dlg.main_08.con.a8' },
            { id = p .. '_a9', node_type = 'LINE', next_node_id = p .. '_a10', speaker_id = LIANG, text_key = 'dlg.main_08.con.a9' },
            { id = p .. '_a10', node_type = 'LINE', next_node_id = p .. '_a11', speaker_id = MENG, text_key = 'dlg.main_08.con.a10' },
            { id = p .. '_a11', node_type = 'LINE', next_node_id = p .. '_a12', speaker_id = SU, text_key = 'dlg.main_08.con.a11' },
            { id = p .. '_a12', node_type = 'LINE', next_node_id = p .. '_a13', speaker_id = MENG, text_key = 'dlg.main_08.con.a12' },
            { id = p .. '_a13', node_type = 'LINE', next_node_id = p .. '_a14', speaker_id = MENG, text_key = 'dlg.main_08.con.a13' },
            { id = p .. '_a14', node_type = 'LINE', next_node_id = p .. '_choice', speaker_id = MENG, text_key = 'dlg.main_08.con.a14' },
            { id = p .. '_choice', node_type = 'CHOICE', choice_set_id = set_id, speaker_id = MENG, text_key = 'dlg.main_08.con.choice_prompt' },
            -- 务实
            { id = p .. '_pr1', node_type = 'LINE', next_node_id = p .. '_pr2', speaker_id = MENG, text_key = 'dlg.main_08.con.pr1' },
            { id = p .. '_pr2', node_type = 'LINE', next_node_id = p .. '_pr3', speaker_id = MENG, text_key = 'dlg.main_08.con.pr2' },
            { id = p .. '_pr3', node_type = 'LINE', next_node_id = p .. '_end', speaker_id = MENG, text_key = 'dlg.main_08.con.pr3' },
            -- 挑战
            { id = p .. '_ch1', node_type = 'LINE', next_node_id = p .. '_ch2', speaker_id = MENG, text_key = 'dlg.main_08.con.ch1' },
            { id = p .. '_ch2', node_type = 'LINE', next_node_id = p .. '_ch3', speaker_id = MENG, text_key = 'dlg.main_08.con.ch2' },
            { id = p .. '_ch3', node_type = 'LINE', next_node_id = p .. '_ch4', speaker_id = MENG, text_key = 'dlg.main_08.con.ch3' },
            { id = p .. '_ch4', node_type = 'LINE', next_node_id = p .. '_end', speaker_id = MENG, text_key = 'dlg.main_08.con.ch4' },
            -- 观察
            { id = p .. '_ob1', node_type = 'LINE', next_node_id = p .. '_ob2', speaker_id = MENG, text_key = 'dlg.main_08.con.ob1' },
            { id = p .. '_ob2', node_type = 'LINE', next_node_id = p .. '_ob3', speaker_id = MENG, text_key = 'dlg.main_08.con.ob2' },
            { id = p .. '_ob3', node_type = 'LINE', next_node_id = p .. '_ob4', speaker_id = MENG, text_key = 'dlg.main_08.con.ob3' },
            { id = p .. '_ob4', node_type = 'LINE', next_node_id = p .. '_end', speaker_id = MENG, text_key = 'dlg.main_08.con.ob4' },
            { id = p .. '_end', node_type = 'END', text_key = 'dlg.main_08.con.end', end_reason = 'COMPLETED' },
        },
    })
end

-- M08 战后：残页嘱托 + 短选项 + 出窟
local function push_main_08_aftermath(source)
    local p = 'dnode_main_08_aft'
    local set_id = 'choiceset_main_08_aftermath'
    local mem = 'dmem_main_08_aftermath_angle'
    push_graph(source, {
        dialogue_id = 'dialogue_main_08_meng_aftermath',
        default_npc_id = SU,
        completion_key = 'dcomp_main_08_meng_aftermath',
        start_node_id = p .. '_d1',
        choices = {
            {
                id = 'choice_main_08_aft_practical',
                choice_set_id = set_id,
                entry_order = 1,
                text_key = 'choice.main_08.aft.practical',
                next_node_id = p .. '_pr',
                choice_memory_key = mem,
                choice_memory_value = 'practical',
            },
            {
                id = 'choice_main_08_aft_challenge',
                choice_set_id = set_id,
                entry_order = 2,
                text_key = 'choice.main_08.aft.challenge',
                next_node_id = p .. '_ch',
                choice_memory_key = mem,
                choice_memory_value = 'challenge',
            },
            {
                id = 'choice_main_08_aft_observe',
                choice_set_id = set_id,
                entry_order = 3,
                text_key = 'choice.main_08.aft.observe',
                next_node_id = p .. '_ob',
                choice_memory_key = mem,
                choice_memory_value = 'observe',
            },
        },
        nodes = {
            { id = p .. '_d1', node_type = 'LINE', next_node_id = p .. '_d2', speaker_id = SU, text_key = 'dlg.main_08.aft.d1' },
            { id = p .. '_d2', node_type = 'LINE', next_node_id = p .. '_d3', speaker_id = MENG, text_key = 'dlg.main_08.aft.d2' },
            { id = p .. '_d3', node_type = 'NARRATION', next_node_id = p .. '_d4', text_key = 'dlg.main_08.aft.d3' },
            { id = p .. '_d4', node_type = 'LINE', next_node_id = p .. '_d5', speaker_id = WEN, text_key = 'dlg.main_08.aft.d4' },
            { id = p .. '_d5', node_type = 'LINE', next_node_id = p .. '_d6', speaker_id = MENG, text_key = 'dlg.main_08.aft.d5' },
            { id = p .. '_d6', node_type = 'LINE', next_node_id = p .. '_d7', speaker_id = WEN, text_key = 'dlg.main_08.aft.d6' },
            { id = p .. '_d7', node_type = 'LINE', next_node_id = p .. '_d8', speaker_id = HUO, text_key = 'dlg.main_08.aft.d7' },
            { id = p .. '_d8', node_type = 'LINE', next_node_id = p .. '_d9', speaker_id = LIANG, text_key = 'dlg.main_08.aft.d8' },
            { id = p .. '_d9', node_type = 'LINE', next_node_id = p .. '_choice', speaker_id = SU, text_key = 'dlg.main_08.aft.d9' },
            { id = p .. '_choice', node_type = 'CHOICE', choice_set_id = set_id, speaker_id = SU, text_key = 'dlg.main_08.aft.choice_prompt' },
            { id = p .. '_pr', node_type = 'LINE', next_node_id = p .. '_e1', speaker_id = LIANG, text_key = 'dlg.main_08.aft.pr' },
            { id = p .. '_ch', node_type = 'LINE', next_node_id = p .. '_e1', speaker_id = HUO, text_key = 'dlg.main_08.aft.ch' },
            { id = p .. '_ob', node_type = 'LINE', next_node_id = p .. '_e1', speaker_id = SU, text_key = 'dlg.main_08.aft.ob' },
            { id = p .. '_e1', node_type = 'LINE', next_node_id = p .. '_e2', speaker_id = WEN, text_key = 'dlg.main_08.aft.e1' },
            { id = p .. '_e2', node_type = 'LINE', next_node_id = p .. '_e3', speaker_id = HUO, text_key = 'dlg.main_08.aft.e2' },
            { id = p .. '_e3', node_type = 'LINE', next_node_id = p .. '_e4', speaker_id = LIANG, text_key = 'dlg.main_08.aft.e3' },
            { id = p .. '_e4', node_type = 'LINE', next_node_id = p .. '_end', speaker_id = SU, text_key = 'dlg.main_08.aft.e4' },
            { id = p .. '_end', node_type = 'END', text_key = 'dlg.main_08.aft.end', end_reason = 'COMPLETED' },
        },
    })
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
    push_linear(source, 'dialogue_main_03_su_join', SU, 2)
    push_linear(source, 'dialogue_main_04_huo_join', HUO, 2)
    push_linear(source, 'dialogue_main_05_ke_confront', KE, 3)
    push_main_05_aftermath(source)
    push_linear(source, 'dialogue_main_06_wen_join', WEN, 2)
    push_main_07_proof(source)
    push_main_08_confront(source)
    push_main_08_aftermath(source)
    push_choice_dialogue(source)

    push_linear(source, 'dialogue_side_01_return_bell', 'npc_post_boy', 2)
    push_linear(source, 'dialogue_side_03_axle_done', 'npc_relay_carter', 2)
    push_linear(source, 'dialogue_side_04_formation', LIANG, 2)
    push_linear(source, 'dialogue_side_06_night_talk', HUO, 2)

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
        'dialogue_main_05_aftermath',
        'dialogue_main_06_wen_join',
        'dialogue_main_07_proof_under_bell',
        'dialogue_main_08_meng_confront',
        'dialogue_main_08_meng_aftermath',
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
