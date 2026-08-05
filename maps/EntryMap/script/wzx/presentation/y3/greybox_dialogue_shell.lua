-- Clickable dialogue via CommonTip. Keyboard fallback kept.

local Chapter01Dialogue = require 'wzx.config.content.dialogue.chapter_01'
local DialoguePlayer = require 'wzx.presentation.greybox.dialogue_player'
local CommonTip = require 'wzx.presentation.y3.common_tip_panel'

local GreyboxDialogueShell = {}

local mounted = false
local player_logic = nil
local triggers = {}
local default_dialogue_id = 'dialogue_main_02_ambush_site'
local ui_ready = false

local UNIT_NAME_DIALOGUES = {
    ['梁既白'] = 'dialogue_main_02_ambush_site',
    ['驿丞'] = 'dialogue_main_01_post_hire',
    ['苏见微'] = 'dialogue_main_03_su_join',
    ['霍小满'] = 'dialogue_main_04_huo_join',
    ['柯砺山'] = 'dialogue_main_05_ke_confront',
    ['闻鹤生'] = 'dialogue_main_06_wen_join',
    ['孟缄声'] = 'dialogue_main_08_meng_confront',
    ['钟下'] = 'dialogue_main_07_proof_under_bell',
}

local function shell_log(msg)
    print('[WZX][对话] ' .. tostring(msg))
end

local function bind_trigger(trg)
    if trg ~= nil then
        triggers[#triggers + 1] = trg
    end
end

local function present(view_result)
    if not ui_ready then
        return
    end

    if not view_result.ok then
        local reason = 'unknown'
        if view_result.error and view_result.error.details and view_result.error.details.reason then
            reason = tostring(view_result.error.details.reason)
        elseif view_result.error and view_result.error.code then
            reason = tostring(view_result.error.code)
        end
        CommonTip.show({
            title = '对话失败',
            content = reason,
            mid = {
                text = '关 闭',
                on_click = function()
                    CommonTip.hide()
                end,
            },
        })
        return
    end

    local view = view_result.value
    if not view.active then
        CommonTip.show({
            title = '对话',
            content = '点「开始」进入第一章现场调查。',
            mid = {
                text = '开 始',
                on_click = function()
                    present(player_logic:start(default_dialogue_id))
                end,
            },
        })
        return
    end

    local speaker = view.speaker
    if speaker == nil or speaker == '' then
        speaker = '……'
    end
    local body = tostring(view.body or '')

    if view.state == 'WAITING_CHOICE' and view.choices and #view.choices > 0 then
        local lines = { speaker, '', body, '', '请点下方选项：' }
        local index
        for index = 1, #view.choices do
            local c = view.choices[index]
            lines[#lines + 1] = tostring(c.index or index) .. '. ' .. tostring(c.text or '')
        end
        local c1 = view.choices[1]
        local c2 = view.choices[2]
        local c3 = view.choices[3]
        local opts = {
            title = '选择',
            content = table.concat(lines, '\n'),
        }
        if c1 then
            opts.left = {
                text = '选项1',
                on_click = function()
                    present(player_logic:choose(c1.index or 1))
                end,
            }
        end
        if c2 then
            opts.mid = {
                text = '选项2',
                on_click = function()
                    present(player_logic:choose(c2.index or 2))
                end,
            }
        end
        if c3 then
            opts.right = {
                text = '选项3',
                on_click = function()
                    present(player_logic:choose(c3.index or 3))
                end,
            }
        elseif c1 and not c2 then
            -- single choice: use mid
            opts.left = nil
            opts.mid = {
                text = '确认',
                on_click = function()
                    present(player_logic:choose(c1.index or 1))
                end,
            }
        end
        -- 2 choices: left + mid
        if c1 and c2 and not c3 then
            opts.right = nil
        end
        CommonTip.show(opts)
        return
    end

    local mid_text = '继 续'
    if view.ended or view.ready_to_complete then
        mid_text = '结 束'
    end
    CommonTip.show({
        title = speaker,
        content = body,
        mid = {
            text = mid_text,
            on_click = function()
                if player_logic == nil then
                    return
                end
                local cur = player_logic:get_view()
                if not cur.ok or not cur.value.active then
                    present(player_logic:start(default_dialogue_id))
                    return
                end
                if cur.value.state == 'WAITING_CHOICE' then
                    present(cur)
                    return
                end
                present(player_logic:advance())
            end,
        },
    })
end

local function start_dialogue(dialogue_id)
    if player_logic == nil then
        return
    end
    present(player_logic:start(dialogue_id or default_dialogue_id))
end

local function on_advance()
    if player_logic == nil then
        return
    end
    local view = player_logic:get_view()
    if not view.ok or not view.value.active then
        start_dialogue(default_dialogue_id)
        return
    end
    if view.value.state == 'WAITING_CHOICE' then
        present(view)
        return
    end
    present(player_logic:advance())
end

local function on_choose(index)
    if player_logic == nil then
        return
    end
    local view = player_logic:get_view()
    if not view.ok or not view.value.active then
        return
    end
    if view.value.state ~= 'WAITING_CHOICE' then
        present(view)
        return
    end
    present(player_logic:choose(index))
end

local function resolve_dialogue_from_unit(unit)
    if unit == nil then
        return nil
    end
    local name = ''
    pcall(function()
        name = unit:get_name() or ''
    end)
    if name == '' then
        return nil
    end
    local key
    local dialogue_id
    for key, dialogue_id in pairs(UNIT_NAME_DIALOGUES) do
        if string.find(name, key, 1, true) then
            return dialogue_id
        end
    end
    return nil
end

local function bind_keyboard_fallback()
    if type(y3) ~= 'table' or type(y3.game) ~= 'table' then
        return
    end
    bind_trigger(y3.game:event('键盘-按下', 'F', function()
        start_dialogue(default_dialogue_id)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'SPACE', function()
        on_advance()
    end))
    bind_trigger(y3.game:event('键盘-按下', 'Q', function()
        on_choose(1)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'W', function()
        on_choose(2)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'E', function()
        on_choose(3)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'F1', function()
        on_choose(1)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'F2', function()
        on_choose(2)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'F3', function()
        on_choose(3)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'NUM_1', function()
        on_choose(1)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'NUM_2', function()
        on_choose(2)
    end))
    bind_trigger(y3.game:event('键盘-按下', 'NUM_3', function()
        on_choose(3)
    end))

    pcall(function()
        bind_trigger(y3.game:event('本地-选中-单位', function(trg, data)
            local unit = data and (data.unit or data['unit'])
            local dialogue_id = resolve_dialogue_from_unit(unit)
            if dialogue_id ~= nil then
                start_dialogue(dialogue_id)
            end
        end))
    end)
end

function GreyboxDialogueShell.mount(options)
    options = options or {}
    if mounted then
        return true, 'already_mounted'
    end
    if type(y3) ~= 'table' or type(y3.game) ~= 'table' then
        return false, 'y3_not_available'
    end

    local sealed = Chapter01Dialogue.seal()
    if not sealed.ok then
        shell_log('catalog seal failed')
        return false, 'catalog_seal_failed'
    end

    local bound = DialoguePlayer.bind({ catalog = sealed.value })
    if not bound.ok then
        shell_log('player bind failed')
        return false, 'player_bind_failed'
    end
    player_logic = bound.value
    if options.default_dialogue_id then
        default_dialogue_id = options.default_dialogue_id
    end

    local ok_ui, reason = CommonTip.bind()
    ui_ready = ok_ui == true
    if not ui_ready then
        shell_log('CommonTip 绑定失败: ' .. tostring(reason))
    else
        shell_log('对话已接到 CommonTip，应能看见对话框')
    end

    bind_keyboard_fallback()
    mounted = true
    present({
        ok = true,
        value = {
            active = false,
            state = 'IDLE',
            choices = {},
        },
    })
    return true, ui_ready and 'mounted_ui' or 'mounted_keyboard_only'
end

function GreyboxDialogueShell.unmount()
    local index
    for index = 1, #triggers do
        pcall(function()
            local trg = triggers[index]
            if trg and trg.remove then
                trg:remove()
            end
        end)
    end
    triggers = {}
    if ui_ready then
        CommonTip.release()
    end
    ui_ready = false
    player_logic = nil
    mounted = false
end

function GreyboxDialogueShell.is_mounted()
    return mounted
end

return GreyboxDialogueShell
