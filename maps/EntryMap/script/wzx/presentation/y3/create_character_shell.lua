-- Create-character presentation for editor board maps/EntryMap/ui/create_character.
-- Appearance is owned by the editor board — this shell only binds clicks, text,
-- model showroom, and show/hide page switch with save_slot.
--
-- Board contract: assets/ui/create_character/BOARD_CONTRACT.md

local Kit = require 'wzx.presentation.y3.runtime_ui_kit'
local LocalRunSlotStore = require 'wzx.application.boot.local_run_slot_store'

local CreateCharacterShell = {}

local ROSTER = require 'wzx.config.content.create_character_roster'

local BOARD_NAME = 'create_character'
local STAT_MAX = 18
local STAT_ORDER = {
    { key = 'strength', label = '力' },
    { key = 'constitution', label = '骨' },
    { key = 'agility', label = '身' },
    { key = 'inner_power', label = '息' },
}

local ICON = {
    panel = 134282360,
    panel_selected = 134264868,
}

local mounted = false
local player = nil
local board = nil
local slot_index = 1
local selected_index = 1
local on_complete_cb = nil
local on_cancel_cb = nil
local events_bound = false
local hidden_boards = {}

local nodes = {
    title = nil,
    subtitle = nil,
    model = nil,
    glyph = nil,
    model_caption = nil,
    name = nil,
    role = nil,
    intro = nil,
    tip = nil,
    btn_back = nil,
    btn_confirm = nil,
    roster_btns = {},
    roster_labels = {},
    stat_labels = {},
    stat_bars = {},
    stat_vals = {},
}

local function info(msg)
    local text = '[WZX][立档] ' .. tostring(msg)
    pcall(function()
        if log and log.info then
            log.info(text)
        end
    end)
    print(text)
end

local function warn(msg)
    local text = '[WZX][立档] ' .. tostring(msg)
    pcall(function()
        if log and log.warn then
            log.warn(text)
        end
    end)
    print(text)
end

local function toast(msg, seconds)
    pcall(function()
        local p = player or Kit.get_player()
        if p and y3.ui and y3.ui.display_message then
            y3.ui.display_message(p, tostring(msg), seconds or 4)
        end
    end)
end

local function get_player()
    return Kit.get_player() or player
end

---@param path string absolute "create_character.a.b"
local function try_get_ui(path)
    local p = player or get_player()
    if p == nil or type(y3.ui.get_ui) ~= 'function' then
        return nil
    end
    local ok, ui = pcall(function()
        return y3.ui.get_ui(p, path)
    end)
    if ok then
        return ui
    end
    return nil
end

local function child(parent, name)
    if parent == nil then
        return nil
    end
    local ok, ui = pcall(function()
        return parent:get_child(name)
    end)
    if ok then
        return ui
    end
    return nil
end

local function set_visible(ui, show)
    Kit.set_visible(ui, show == true)
end

local function set_text(ui, text)
    Kit.set_label_text(ui, text)
end

local function set_image(ui, img)
    if ui == nil or img == nil then
        return
    end
    pcall(function()
        if ui.set_image then
            ui:set_image(img)
        end
    end)
end

local function resolve_nodes()
    board = try_get_ui(BOARD_NAME)
    if board == nil then
        return false, 'board_missing:' .. BOARD_NAME
    end

    local layout_title = child(board, 'layout_title')
    local layout_roster = child(board, 'layout_roster')
    local layout_stage = child(board, 'layout_stage')
    local layout_detail = child(board, 'layout_detail')
    local layout_button = child(board, 'layout_button')
    local layout_tip = child(board, 'layout_tip')

    nodes.title = child(layout_title, 'label_title')
        or try_get_ui(BOARD_NAME .. '.layout_title.label_title')
        or child(board, 'label_title')
    nodes.subtitle = child(layout_title, 'label_subtitle')
        or try_get_ui(BOARD_NAME .. '.layout_title.label_subtitle')
        or child(board, 'label_subtitle')

    nodes.model = child(layout_stage, 'model_preview')
        or try_get_ui(BOARD_NAME .. '.layout_stage.model_preview')
        or child(board, 'model_preview')
    nodes.glyph = child(layout_stage, 'label_glyph')
        or try_get_ui(BOARD_NAME .. '.layout_stage.label_glyph')
    nodes.model_caption = child(layout_stage, 'label_model_caption')
        or try_get_ui(BOARD_NAME .. '.layout_stage.label_model_caption')

    nodes.name = child(layout_detail, 'label_name')
        or try_get_ui(BOARD_NAME .. '.layout_detail.label_name')
        or child(board, 'label_name')
    nodes.role = child(layout_detail, 'label_role')
        or try_get_ui(BOARD_NAME .. '.layout_detail.label_role')
    nodes.intro = child(layout_detail, 'label_intro')
        or try_get_ui(BOARD_NAME .. '.layout_detail.label_intro')
        or child(board, 'label_intro')

    nodes.btn_back = child(layout_button, 'button_返回')
        or try_get_ui(BOARD_NAME .. '.layout_button.button_返回')
        or child(board, 'button_返回')
    nodes.btn_confirm = child(layout_button, 'button_确认立档')
        or try_get_ui(BOARD_NAME .. '.layout_button.button_确认立档')
        or child(board, 'button_确认立档')

    nodes.tip = child(layout_tip, 'label_tip')
        or try_get_ui(BOARD_NAME .. '.layout_tip.label_tip')
        or child(board, 'label_tip')

    nodes.roster_btns = {}
    nodes.roster_labels = {}
    local max_roster = math.min(6, #ROSTER)
    if max_roster < 1 then
        max_roster = 6
    end
    local i
    for i = 1, max_roster do
        local btn = child(layout_roster, 'roster_btn_' .. tostring(i))
            or try_get_ui(BOARD_NAME .. '.layout_roster.roster_btn_' .. tostring(i))
            or child(board, 'roster_btn_' .. tostring(i))
        local label = child(layout_roster, 'roster_label_' .. tostring(i))
            or try_get_ui(BOARD_NAME .. '.layout_roster.roster_label_' .. tostring(i))
        nodes.roster_btns[i] = btn
        nodes.roster_labels[i] = label
    end

    nodes.stat_labels = {}
    nodes.stat_bars = {}
    nodes.stat_vals = {}
    for i = 1, 4 do
        nodes.stat_labels[i] = child(layout_detail, 'label_stat_' .. tostring(i))
            or try_get_ui(BOARD_NAME .. '.layout_detail.label_stat_' .. tostring(i))
        nodes.stat_bars[i] = child(layout_detail, 'bar_stat_' .. tostring(i))
            or try_get_ui(BOARD_NAME .. '.layout_detail.bar_stat_' .. tostring(i))
        nodes.stat_vals[i] = child(layout_detail, 'label_stat_val_' .. tostring(i))
            or try_get_ui(BOARD_NAME .. '.layout_detail.label_stat_val_' .. tostring(i))
    end

    -- Minimum required for a usable page.
    local roster_ok = 0
    for i = 1, #nodes.roster_btns do
        if nodes.roster_btns[i] ~= nil then
            roster_ok = roster_ok + 1
        end
    end
    if nodes.btn_back == nil or nodes.btn_confirm == nil then
        return false, 'buttons_missing'
    end
    if roster_ok < 1 then
        return false, 'roster_missing'
    end
    if nodes.name == nil and nodes.intro == nil and nodes.model == nil then
        return false, 'content_missing'
    end

    info(string.format(
        'nodes ok roster=%d model=%s name=%s',
        roster_ok,
        tostring(nodes.model ~= nil),
        tostring(nodes.name ~= nil)
    ))
    return true, 'ok'
end

local function apply_showroom(entry)
    if nodes.model == nil or entry == nil or entry.model_id == nil then
        return
    end
    local ok = false
    pcall(function()
        if nodes.model.set_ui_model_id then
            nodes.model:set_ui_model_id(entry.model_id)
            ok = true
        end
    end)
    if not ok and player and GameAPI and GameAPI.set_ui_model_id then
        pcall(function()
            GameAPI.set_ui_model_id(player.handle, nodes.model.handle, entry.model_id, 'idle')
            ok = true
        end)
    end
    pcall(function()
        if nodes.model.set_show_room_background_color then
            nodes.model:set_show_room_background_color(10, 16, 14, 0)
        end
        if nodes.model.change_showroom_fov then
            nodes.model:change_showroom_fov(30)
        end
        if nodes.model.change_showroom_cposition then
            nodes.model:change_showroom_cposition(0, 100, 260)
        end
        if nodes.model.change_showroom_crotation then
            nodes.model:change_showroom_crotation(-10, 0, 160)
        end
        if nodes.model.set_ui_model_focus_pos then
            nodes.model:set_ui_model_focus_pos(0, 70, 0)
        end
    end)
    if not ok then
        warn('model set failed id=' .. tostring(entry.model_id))
    end
end

local function apply_stats(entry)
    local stats = (entry and entry.stats) or {}
    local i
    for i = 1, #STAT_ORDER do
        local def = STAT_ORDER[i]
        local raw = stats[def.key] or 0
        if raw < 0 then raw = 0 end
        if raw > STAT_MAX then raw = STAT_MAX end
        if nodes.stat_labels[i] then
            set_text(nodes.stat_labels[i], def.label)
        end
        if nodes.stat_vals[i] then
            set_text(nodes.stat_vals[i], tostring(raw))
        end
        if nodes.stat_bars[i] then
            local fill_w = math.floor(200 * (raw / STAT_MAX))
            if fill_w < 2 and raw > 0 then fill_w = 2 end
            pcall(function()
                if nodes.stat_bars[i].set_ui_size then
                    local h = 12
                    pcall(function()
                        -- keep height if engine exposes get; else fixed
                    end)
                    nodes.stat_bars[i]:set_ui_size(fill_w, h)
                end
            end)
        end
    end
end

local function apply_selection()
    local entry = ROSTER[selected_index]
    if entry == nil then
        return
    end
    local i
    for i = 1, #nodes.roster_btns do
        local btn = nodes.roster_btns[i]
        local e = ROSTER[i]
        local selected = (i == selected_index)
        if btn then
            set_image(btn, selected and ICON.panel_selected or ICON.panel)
            pcall(function()
                if btn.set_btn_status_image and y3.const and y3.const.UIButtonStatus then
                    local st = y3.const.UIButtonStatus
                    btn:set_btn_status_image(st['常态'] or 1, selected and ICON.panel_selected or ICON.panel)
                    btn:set_btn_status_image(st['悬浮'] or 2, ICON.panel_selected)
                end
            end)
            if e and nodes.roster_labels[i] == nil then
                Kit.set_button_label(btn, (e.glyph or '') .. ' ' .. (e.catalog_name or ''))
            end
        end
        if nodes.roster_labels[i] and e then
            set_text(nodes.roster_labels[i], (e.glyph or '·') .. '  ' .. (e.catalog_name or ''))
        end
    end

    set_text(nodes.title, '山 径 立 档')
    set_text(nodes.subtitle, '角色位 ' .. tostring(slot_index) .. ' · 点选风骨后确认')
    set_text(nodes.name, entry.catalog_name or '')
    set_text(nodes.role, (entry.role or '') .. '  ·  ' .. (entry.tag or ''))
    set_text(nodes.intro, entry.intro or '')
    set_text(nodes.glyph, entry.glyph or '·')
    set_text(nodes.model_caption, (entry.catalog_name or '') .. ' · 预览')
    set_text(nodes.tip, '确认后写入本地槽 · 可再进入')
    apply_stats(entry)
    apply_showroom(entry)
end

local function enter_exclusive_page()
    hidden_boards = {}
    local p = player or get_player()
    if p == nil then
        return
    end
    local names = { 'save_slot', 'GameHUD', 'LoadingPanel', 'LogoPanel', 'panel_1' }
    local i
    for i = 1, #names do
        local name = names[i]
        if name ~= BOARD_NAME then
            local ui = try_get_ui(name)
            if ui then
                pcall(function()
                    if ui.set_visible then
                        ui:set_visible(false)
                    end
                    if ui.set_intercepts_operations then
                        ui:set_intercepts_operations(false)
                    end
                end)
                hidden_boards[#hidden_boards + 1] = name
            end
        end
    end
end

local function leave_exclusive_page()
    -- save_slot shell re-shows itself in callbacks; only ensure create board is off.
    set_visible(board, false)
    pcall(function()
        if board and board.set_intercepts_operations then
            board:set_intercepts_operations(false)
        end
    end)
    hidden_boards = {}
end

local function confirm_create()
    local entry = ROSTER[selected_index]
    if entry == nil then
        set_text(nodes.tip, '请先选择一位')
        return
    end
    local store = LocalRunSlotStore.shared()
    local created = store:create(slot_index, {
        overwrite = true,
        display_name = entry.catalog_name,
        chapter_hint = entry.chapter_hint or '卷一 · 开局',
        updated_label = '刚刚',
        play_time_label = '0 分',
        run_id = 'run_local_' .. tostring(slot_index) .. '_' .. tostring(entry.id),
        character_id = entry.id,
    })
    if not created.ok then
        local reason = 'unknown'
        if created.error and created.error.details and created.error.details.reason then
            reason = tostring(created.error.details.reason)
        end
        set_text(nodes.tip, '立档失败：' .. reason)
        toast('立档失败：' .. reason, 5)
        return
    end
    info('created slot=' .. tostring(slot_index) .. ' id=' .. tostring(entry.id))
    local payload = {
        slot_index = slot_index,
        character_id = entry.id,
        display_name = entry.catalog_name,
        chapter_hint = entry.chapter_hint,
    }
    CreateCharacterShell.unmount()
    if type(on_complete_cb) == 'function' then
        pcall(on_complete_cb, payload)
    end
end

local function cancel_create()
    info('cancel slot=' .. tostring(slot_index))
    CreateCharacterShell.unmount()
    if type(on_cancel_cb) == 'function' then
        pcall(on_cancel_cb)
    end
end

local function bind_events()
    if events_bound then
        return true
    end
    local i
    for i = 1, #nodes.roster_btns do
        local idx = i
        local btn = nodes.roster_btns[i]
        if btn then
            Kit.on_click(btn, function()
                selected_index = idx
                apply_selection()
            end)
        end
    end
    Kit.on_click(nodes.btn_back, cancel_create)
    Kit.on_click(nodes.btn_confirm, confirm_create)
    events_bound = true
    return true
end

---@param options { slot_index: number, on_complete?: fun(payload: table), on_cancel?: fun() }
---@return boolean ok
---@return string detail
function CreateCharacterShell.mount(options)
    options = options or {}
    if type(y3) ~= 'table' or type(y3.ui) ~= 'table' then
        return false, 'y3_not_available'
    end

    if mounted then
        CreateCharacterShell.unmount()
    end

    player = get_player()
    if player == nil then
        return false, 'no_player'
    end

    slot_index = options.slot_index or 1
    if type(slot_index) ~= 'number' or slot_index < 1 or slot_index > 5 then
        return false, 'slot_index_invalid'
    end

    on_complete_cb = options.on_complete
    on_cancel_cb = options.on_cancel
    selected_index = 1
    events_bound = false

    Kit.sanitize_startup_ui(player)

    local ok_nodes, detail = resolve_nodes()
    if not ok_nodes then
        toast(
            '缺少编辑器画板 create_character（' .. tostring(detail) .. '）',
            6
        )
        warn('resolve failed: ' .. tostring(detail))
        return false, detail
    end

    -- Init roster button labels from catalog.
    local i
    for i = 1, #nodes.roster_btns do
        local e = ROSTER[i]
        local btn = nodes.roster_btns[i]
        if e and btn and nodes.roster_labels[i] == nil then
            Kit.set_button_label(btn, (e.glyph or '') .. ' ' .. (e.catalog_name or ''))
        end
        if e and nodes.roster_labels[i] then
            set_text(nodes.roster_labels[i], (e.glyph or '·') .. '  ' .. (e.catalog_name or ''))
        end
        if btn then
            set_visible(btn, e ~= nil)
        end
        if nodes.roster_labels[i] then
            set_visible(nodes.roster_labels[i], e ~= nil)
        end
    end

    bind_events()
    enter_exclusive_page()

    pcall(function()
        board:set_visible(true)
        if board.set_z_order then
            board:set_z_order(9500)
        end
        if board.set_intercepts_operations then
            board:set_intercepts_operations(true)
        end
        if board.set_alpha then
            board:set_alpha(1)
        end
    end)

    apply_selection()
    mounted = true
    info('mounted editor board create_character slot=' .. tostring(slot_index))
    toast('立档 · 位' .. tostring(slot_index), 2)
    return true, 'mounted'
end

function CreateCharacterShell.unmount()
    leave_exclusive_page()
    board = nil
    player = nil
    on_complete_cb = nil
    on_cancel_cb = nil
    events_bound = false
    nodes = {
        title = nil,
        subtitle = nil,
        model = nil,
        glyph = nil,
        model_caption = nil,
        name = nil,
        role = nil,
        intro = nil,
        tip = nil,
        btn_back = nil,
        btn_confirm = nil,
        roster_btns = {},
        roster_labels = {},
        stat_labels = {},
        stat_bars = {},
        stat_vals = {},
    }
    mounted = false
end

function CreateCharacterShell.is_mounted()
    return mounted
end

function CreateCharacterShell.get_roster()
    return ROSTER
end

function CreateCharacterShell.board_name()
    return BOARD_NAME
end

return CreateCharacterShell
