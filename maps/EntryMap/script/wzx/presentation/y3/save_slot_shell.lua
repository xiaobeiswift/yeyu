-- Character-select presentation for maps/EntryMap/ui/save_slot.json.
-- Appearance is owned by the editor board/prefab — this shell only binds
-- click handlers, empty/filled text, selection visibility, and map input lock.

local BootFlow = require 'wzx.application.boot.boot_flow'
local LocalRunSlotStore = require 'wzx.application.boot.local_run_slot_store'
local OfficialCloudGate = require 'wzx.adapters.y3.official_cloud_gate'
local Kit = require 'wzx.presentation.y3.runtime_ui_kit'

local SaveSlotShell = {}

local BOARD_NAME = 'save_slot'

-- Frame swap for selection only (IDs match board-bound v2 assets).
local ICON = {
    panel = 134282360,
    panel_selected = 134264868,
}

local DEFAULT_TIP = '点选角色位 · 空位可新建 · 有档可进入'

local mounted = false
local flow = nil
local board = nil
local player = nil
local on_entered_cb = nil
local events_bound = false
local map_input_locked = false
-- [slot_index] = nodes + last_empty / last_selected to avoid thrashing art
local card_nodes = {}
local btn = {
    back = nil,
    delete = nil,
    create = nil,
    enter = nil,
}
local message_label = nil
local swallow_nodes = {}

local function info(msg)
    local text = '[WZX][SaveSlot] ' .. tostring(msg)
    pcall(function()
        if log and log.info then
            log.info(text)
        end
    end)
    print(text)
end

local function warn(msg)
    local text = '[WZX][SaveSlot] ' .. tostring(msg)
    pcall(function()
        if log and log.warn then
            log.warn(text)
        elseif log and log.info then
            log.info(text)
        end
    end)
    print(text)
end

local function get_player()
    return Kit.get_player()
end

---@param path string absolute board path "save_slot.a.b"
local function try_get_ui(path)
    local p = player or get_player()
    if p == nil or type(y3) ~= 'table' or type(y3.ui) ~= 'table' or type(y3.ui.get_ui) ~= 'function' then
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

---@param parent any
---@param name string
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

local function set_image(ui, img)
    if ui == nil or img == nil then
        return
    end
    pcall(function()
        ui:set_image(img)
    end)
end

local function set_visible(ui, show)
    Kit.set_visible(ui, show == true)
end

local function set_text(ui, text)
    Kit.set_label_text(ui, text)
end

local function set_button_enable(ui, enable)
    Kit.set_button_enable(ui, enable)
end

---Swallow pointer events so they don't fall through to the world/camera.
local function set_swallow(ui, intercepts)
    if ui == nil then
        return
    end
    pcall(function()
        if ui.set_intercepts_operations then
            ui:set_intercepts_operations(intercepts == true)
        end
    end)
end

---Disable world interaction while the character panel is up.
---UI swallow alone is not enough: empty gaps and camera drag still hit the map.
local function lock_map_input(p)
    p = p or player or get_player()
    if p == nil then
        return
    end
    pcall(function()
        if y3.camera and y3.camera.disable_camera_move then
            y3.camera.disable_camera_move(p)
        end
    end)
    pcall(function()
        if p.set_mouse_click_selection then
            p:set_mouse_click_selection(false)
        end
    end)
    pcall(function()
        if p.set_mouse_drag_selection then
            p:set_mouse_drag_selection(false)
        end
    end)
    pcall(function()
        if p.set_mouse_wheel then
            p:set_mouse_wheel(false)
        end
    end)
    -- Drop any current selection so map units don't stay "commandable".
    pcall(function()
        if p.select_unit and y3.unit_group and y3.unit_group.create then
            p:select_unit(y3.unit_group.create())
        end
    end)
    map_input_locked = true
end

local function unlock_map_input(p)
    if not map_input_locked then
        return
    end
    p = p or player or get_player()
    if p == nil then
        map_input_locked = false
        return
    end
    pcall(function()
        if y3.camera and y3.camera.enable_camera_move then
            y3.camera.enable_camera_move(p)
        end
    end)
    pcall(function()
        if p.set_mouse_click_selection then
            p:set_mouse_click_selection(true)
        end
    end)
    pcall(function()
        if p.set_mouse_drag_selection then
            p:set_mouse_drag_selection(true)
        end
    end)
    pcall(function()
        if p.set_mouse_wheel then
            p:set_mouse_wheel(true)
        end
    end)
    map_input_locked = false
end

local function harden_ui_block()
    swallow_nodes = {}
    local function track(ui)
        if ui ~= nil then
            swallow_nodes[#swallow_nodes + 1] = ui
            set_swallow(ui, true)
        end
    end

    track(board)
    local layout_main = child(board, 'layout_main')
    local layout_slot = child(board, 'layout_slot')
    local layout_button = child(board, 'layout_button')
    local layout_tip = child(board, 'layout_提示')
    track(layout_main)
    track(layout_slot)
    track(layout_button)
    track(layout_tip)
    track(child(layout_main, 'image_bg'))
    -- Do not retouch z_order / colors / images — board owns layout.
end

local function resolve_nodes()
    board = try_get_ui(BOARD_NAME)
    if board == nil then
        return false, 'board_missing'
    end

    local layout_slot = child(board, 'layout_slot')
    local layout_button = child(board, 'layout_button')
    local layout_tip = child(board, 'layout_提示')
    -- Title / deco / bg / fonts: leave exactly as the editor board defines.
    message_label = child(layout_tip, 'Lable_提示')
        or try_get_ui(BOARD_NAME .. '.layout_提示.Lable_提示')

    card_nodes = {}
    local index
    for index = 1, 5 do
        local card_name = 'save_slot_card_' .. tostring(index)
        local root = child(layout_slot, card_name)
            or try_get_ui(BOARD_NAME .. '.layout_slot.' .. card_name)
        if root == nil then
            return false, 'card_missing_' .. tostring(index)
        end
        local tishi = child(root, 'tishi')
        card_nodes[index] = {
            root = root,
            frame = child(root, 'frame'),
            empty_icon = child(root, 'empty_icon'),
            portrait = child(root, 'portrait'),
            ring = child(root, 'portrait_ring'),
            selected_mark = child(root, 'selected_mark'),
            name = child(tishi, 'name') or child(root, 'name'),
            chapter = child(tishi, 'chapter') or child(root, 'chapter'),
            time = child(tishi, 'time') or child(root, 'time'),
            last_empty = nil,
            last_selected = nil,
        }
        -- Do not rewrite index/title art — board already has 位 一…五.
    end

    btn.back = child(layout_button, 'button_返回')
        or try_get_ui(BOARD_NAME .. '.layout_button.button_返回')
    btn.delete = child(layout_button, 'button_删除')
        or try_get_ui(BOARD_NAME .. '.layout_button.button_删除')
    btn.create = child(layout_button, 'button_新建')
        or try_get_ui(BOARD_NAME .. '.layout_button.button_新建')
    btn.enter = child(layout_button, 'button_进入')
        or try_get_ui(BOARD_NAME .. '.layout_button.button_进入')

    if btn.back == nil or btn.create == nil or btn.enter == nil or btn.delete == nil then
        return false, 'buttons_missing'
    end
    return true, 'ok'
end

---Sync card state without rebinding static board art (icons / fonts / colors).
local function apply_card(slot_index, slot, selected)
    local nodes = card_nodes[slot_index]
    if nodes == nil then
        return
    end
    local empty = slot == nil or slot.empty == true

    if nodes.last_selected ~= selected then
        -- Selection chrome only; unselected keeps board frame image.
        if selected then
            set_image(nodes.frame, ICON.panel_selected)
        else
            set_image(nodes.frame, ICON.panel)
        end
        -- selected_mark is authored on the board; show only when selected.
        set_visible(nodes.selected_mark, selected)
        set_visible(nodes.ring, selected and not empty)
        nodes.last_selected = selected
    else
        set_visible(nodes.ring, selected and not empty)
    end

    if nodes.last_empty ~= empty then
        set_visible(nodes.empty_icon, empty)
        set_visible(nodes.portrait, not empty)
        nodes.last_empty = empty
    end

    if empty then
        -- Match board default empty copy; never re-set icon image IDs.
        set_text(nodes.name, '空 位')
        set_text(nodes.chapter, '尚未立档')
        set_text(nodes.time, '点击新建角色')
    else
        set_text(nodes.name, tostring(slot.display_name or '未命名'))
        set_text(nodes.chapter, tostring(slot.chapter_hint or ''))
        local time_line = slot.play_time_label or slot.updated_label or ''
        if slot.play_time_label and slot.updated_label then
            time_line = tostring(slot.play_time_label) .. ' · ' .. tostring(slot.updated_label)
        end
        set_text(nodes.time, tostring(time_line))
    end
end

local function apply_view(view)
    if view == nil then
        return
    end

    if view.entered then
        set_visible(board, false)
        unlock_map_input(player)
        if type(on_entered_cb) == 'function' then
            pcall(on_entered_cb, view.entered_payload)
        end
        return
    end

    if view.screen ~= 'SLOTS' then
        -- This shell only owns the character-select screen.
        set_visible(board, view.screen == 'SLOTS')
        if view.screen == 'SLOTS' then
            lock_map_input(player)
        else
            unlock_map_input(player)
        end
        return
    end

    set_visible(board, true)
    lock_map_input(player)

    local slots = view.slots or {}
    local selected = view.selected_slot_index or 1
    local selected_slot = slots[selected]
    local empty_selected = selected_slot == nil or selected_slot.empty == true

    local index
    for index = 1, 5 do
        apply_card(index, slots[index], index == selected)
    end

    set_button_enable(btn.create, empty_selected)
    set_button_enable(btn.enter, not empty_selected)
    set_button_enable(btn.delete, not empty_selected)
    set_button_enable(btn.back, true)

    local msg = view.message
    if msg == nil or msg == '' then
        msg = view.hint
    end
    if msg == nil or msg == '' then
        msg = DEFAULT_TIP
    end
    set_text(message_label, msg)
end

local function present(result)
    if result == nil then
        return
    end
    if not result.ok then
        local reason = 'unknown'
        if result.error and result.error.details and result.error.details.reason then
            reason = tostring(result.error.details.reason)
        elseif result.error and result.error.code then
            reason = tostring(result.error.code)
        end
        warn('action failed: ' .. reason)
        if message_label then
            set_text(message_label, '操作失败：' .. reason)
        end
        return
    end
    apply_view(result.value)
end

local function act(fn)
    if flow == nil then
        return
    end
    present(fn())
end

local function bind_events()
    if events_bound then
        return true
    end

    local index
    for index = 1, 5 do
        local slot_i = index
        local root = card_nodes[index] and card_nodes[index].root
        if root then
            local ok = Kit.on_click(root, function()
                act(function()
                    return flow:select_slot(slot_i)
                end)
            end)
            if not ok then
                -- Prefer frame as click target if root is not interactive.
                Kit.on_click(card_nodes[index].frame, function()
                    act(function()
                        return flow:select_slot(slot_i)
                    end)
                end)
            end
        end
    end

    Kit.on_click(btn.back, function()
        act(function()
            -- No title screen yet: stay on character select.
            local view = flow:get_view()
            if not view.ok then
                return view
            end
            if view.value.screen ~= 'SLOTS' then
                return flow:open_local_slots()
            end
            local idx = view.value.selected_slot_index or 1
            return flow:select_slot(idx)
        end)
    end)

    Kit.on_click(btn.delete, function()
        act(function()
            return flow:delete_slot()
        end)
    end)

    Kit.on_click(btn.create, function()
        -- Empty slot → same-map create_character shell (UI model showroom).
        local view = flow:get_view()
        if not view.ok then
            present(view)
            return
        end
        local slot_index = view.value.selected_slot_index or 1
        local slots = view.value.slots or {}
        local selected = slots[slot_index]
        if selected and selected.empty == false then
            present(flow:select_slot(slot_index))
            set_text(message_label, '有档位请先删除再新建')
            return
        end

        local CreateCharacterShell = require 'wzx.presentation.y3.create_character_shell'
        -- Full page switch: shell builds on panel_1 then hides save_slot (not a translucent overlay).
        local ok_cc, detail_cc = CreateCharacterShell.mount({
            slot_index = slot_index,
            on_complete = function(payload)
                -- Shell already restored save_slot visibility on unmount.
                harden_ui_block()
                lock_map_input(player)
                set_visible(board, true)
                pcall(function()
                    if board and board.set_z_order then
                        board:set_z_order(9000)
                    end
                end)
                if flow then
                    present(flow:select_slot(payload and payload.slot_index or slot_index))
                end
                local name = payload and payload.display_name or '新角色'
                set_text(message_label, '已立档：' .. tostring(name) .. ' · 可点「进入」')
                info('page back ← 立档 complete name=' .. tostring(name))
            end,
            on_cancel = function()
                harden_ui_block()
                lock_map_input(player)
                set_visible(board, true)
                pcall(function()
                    if board and board.set_z_order then
                        board:set_z_order(9000)
                    end
                end)
                if flow then
                    present(flow:get_view())
                end
                set_text(message_label, '已返回角色选择')
                info('page back ← 立档 cancel')
            end,
        })
        if not ok_cc then
            set_visible(board, true)
            set_text(message_label, '无法打开立档页：' .. tostring(detail_cc))
            warn('create_character mount failed: ' .. tostring(detail_cc))
            return
        end
        info('page switch → 立档 slot=' .. tostring(slot_index))
    end)

    Kit.on_click(btn.enter, function()
        act(function()
            return flow:confirm_enter()
        end)
    end)

    events_bound = true
    return true
end

---@param options? { on_entered?: fun(payload: table), flow?: table }
---@return boolean ok
---@return string detail
function SaveSlotShell.mount(options)
    options = options or {}
    if type(y3) ~= 'table' or type(y3.ui) ~= 'table' then
        return false, 'y3_not_available'
    end

    player = get_player()
    if player == nil then
        return false, 'no_player'
    end

    Kit.sanitize_startup_ui(player)
    Kit.set_default_hud_visible(player, true)

    local ok_nodes, detail = resolve_nodes()
    if not ok_nodes then
        return false, detail
    end

    if options.flow ~= nil then
        flow = options.flow
    else
        local bound = BootFlow.bind({
            platform_options = OfficialCloudGate.platform_options(),
            -- Keep slots when player returns from GameHUD.
            local_slots = options.local_slots or LocalRunSlotStore.shared(),
        })
        if not bound.ok then
            return false, 'boot_bind_failed'
        end
        flow = bound.value
    end

    on_entered_cb = options.on_entered
    events_bound = false
    bind_events()

    pcall(function()
        board:set_visible(true)
        if board.set_z_order then
            board:set_z_order(9000)
        end
    end)
    harden_ui_block()
    lock_map_input(player)

    -- Hide loading cover host if still intercepting clicks.
    pcall(function()
        local loading_host = try_get_ui('panel_1')
        if loading_host and loading_host.set_intercepts_operations then
            loading_host:set_intercepts_operations(false)
        end
    end)

    present(flow:open_local_slots())
    mounted = true
    info('mounted character select (map input locked)')
    return true, 'mounted'
end

function SaveSlotShell.unmount()
    local p = player
    if board then
        set_visible(board, false)
        local index
        for index = 1, #swallow_nodes do
            set_swallow(swallow_nodes[index], false)
        end
    end
    unlock_map_input(p)
    board = nil
    player = nil
    flow = nil
    on_entered_cb = nil
    events_bound = false
    card_nodes = {}
    btn = { back = nil, delete = nil, create = nil, enter = nil }
    message_label = nil
    swallow_nodes = {}
    mounted = false
end

function SaveSlotShell.is_mounted()
    return mounted
end

function SaveSlotShell.get_flow()
    return flow
end

---Refresh from current flow view (e.g. after external store change).
function SaveSlotShell.refresh()
    if flow == nil then
        return false
    end
    present(flow:get_view())
    return true
end

return SaveSlotShell
