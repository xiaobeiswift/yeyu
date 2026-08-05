-- Merges interim chapter-01 ZH maps for greybox display only.
-- Not a localization system authority; runtime system 19 will replace this later.

local DialogueTextTable = {}

local function merge_into(target, source)
    if type(source) ~= 'table' then
        return
    end
    local key
    local value
    for key, value in pairs(source) do
        if type(key) == 'string' and type(value) == 'string' then
            target[key] = value
        end
    end
end

function DialogueTextTable.build_chapter_01()
    local table_value = {
        -- Speaker labels (display only)
        ['speaker.npc_partner_liang_jibai'] = '梁既白',
        ['speaker.npc_partner_su_jianwei'] = '苏见微',
        ['speaker.npc_partner_huo_xiaoman'] = '霍小满',
        ['speaker.npc_partner_wen_hesheng'] = '闻鹤生',
        ['speaker.npc_boss_ke_lishan'] = '柯砺山',
        ['speaker.npc_boss_meng_jiansheng'] = '孟缄声',
        ['speaker.npc_post_master'] = '驿丞',
        ['speaker.npc_post_boy'] = '驿卒',
        ['speaker.npc_relay_carter'] = '车夫',
        -- Linear skeleton fillers (placeholder packs)
        ['dlg.dialogue_main_01_post_hire.l1'] = '夜雾里投驿，先登记。',
        ['dlg.dialogue_main_01_post_hire.l2'] = '驿道上出事了，你若敢去，我雇你护送。',
        ['dlg.dialogue_main_01_post_hire.l3'] = '别信一种说法。去看看现场。',
        ['dlg.dialogue_main_01_post_hire.end'] = '',
        ['dlg.dialogue_main_03_su_join.l1'] = '别碰他刀上的油。黑、黏，气味像旧钟膛。',
        ['dlg.dialogue_main_03_su_join.l2'] = '我是洗霜庐的苏见微。人我先稳住。你们若追刀，我跟着。',
        ['dlg.dialogue_main_03_su_join.end'] = '',
        ['dlg.dialogue_main_04_huo_join.l1'] = '岭上不是没有匪——是「匪」这个字，盖住了两种人。',
        ['dlg.dialogue_main_04_huo_join.l2'] = '我叫霍小满。问清楚，我带路。',
        ['dlg.dialogue_main_04_huo_join.end'] = '',
        ['dlg.dialogue_main_05_ke_confront.l1'] = '官道上死的人，我知道。抄本也在我这。',
        ['dlg.dialogue_main_05_ke_confront.l2'] = '与其再交回去，不如我来拿。拿不住，就烧。',
        ['dlg.dialogue_main_05_ke_confront.l3'] = '行路的，选吧。劝我，或者动手。结果一样。',
        ['dlg.dialogue_main_05_ke_confront.end'] = '',
        ['dlg.dialogue_main_06_wen_join.l1'] = '沉钟院的门，不该在这种夜里开。',
        ['dlg.dialogue_main_06_wen_join.l2'] = '我是闻鹤生。记事实的人。我跟你们下窟。',
        ['dlg.dialogue_main_06_wen_join.end'] = '',
    }

    merge_into(table_value, require 'wzx.config.content.dialogue.chapter_01_m02_zh')
    merge_into(table_value, require 'wzx.config.content.dialogue.chapter_01_m05_zh')
    merge_into(table_value, require 'wzx.config.content.dialogue.chapter_01_m07_zh')
    merge_into(table_value, require 'wzx.config.content.dialogue.chapter_01_m08_zh')
    return table_value
end

function DialogueTextTable.resolve(table_value, text_key)
    if type(text_key) ~= 'string' or text_key == '' then
        return ''
    end
    if type(table_value) ~= 'table' then
        return text_key
    end
    local found = table_value[text_key]
    if type(found) == 'string' and found ~= '' then
        return found
    end
    if type(found) == 'string' then
        return ''
    end
    return '[' .. text_key .. ']'
end

function DialogueTextTable.speaker_name(table_value, speaker_id)
    if type(speaker_id) ~= 'string' or speaker_id == '' then
        return ''
    end
    return DialogueTextTable.resolve(table_value, 'speaker.' .. speaker_id)
end

return DialogueTextTable
