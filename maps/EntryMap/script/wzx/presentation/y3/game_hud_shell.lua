-- Minimal in-world HUD host on empty GameHUD.
-- After character select enter: show identity strip + tip; map stays operable.
-- Full exploration chrome (quest / bag / combat) lands later on this host.

local LocalRunSession = require 'wzx.application.boot.local_run_session'
local Kit = require 'wzx.presentation.y3.runtime_ui_kit'

local GameHudShell = {}

local mounted = false
local host = nil
local player = nil
local on_return_cb = nil
local nodes = {
    title = nil,
    subtitle = nil,
    chapter = nil,
    tip = nil,
    btn_return = nil,
}

local function info(msg)
    local text = '[WZX][GameHUD] ' .. tostring(msg)
    pcall(function()
        if log and log.info then
            log.info(text)
        end
    end)
    print(text)
end

local function clear_nodes()
    local keys = { 'title', 'subtitle', 'chapter', 'tip', 'btn_return' }
    local i
    for i = 1, #keys do
        local k = keys[i]
        if nodes[k] then
            Kit.remove(nodes[k])
            nodes[k] = nil
        end
    end
end

---Place by screen percent (Y3: Y=0 bottom, Y=100 top).
local function place_pct(ui, x_pct, y_pct, w, h, z, ax, ay)
    if ui == nil then
        return
    end
    local p = player or Kit.get_player()
    ax = ax or 0
    ay = ay or 1
    pcall(function()
        if ui.set_anchor then
            ui:set_anchor(ax, ay)
        end
        if w and h and ui.set_ui_size then
            ui:set_ui_size(w, h)
        end
        if p and GameAPI and GameAPI.set_ui_comp_pos_percent then
            GameAPI.set_ui_comp_pos_percent(p.handle, ui.handle, x_pct, y_pct)
        elseif ui.set_pos then
            ui:set_pos(1920 * x_pct / 100, 1080 * (100 - y_pct) / 100)
        end
        if ui.set_visible then
            ui:set_visible(true)
        end
        if z and ui.set_z_order then
            ui:set_z_order(z)
        end
        if ui.set_intercepts_operations then
            -- Labels do not swallow map; buttons do.
            ui:set_intercepts_operations(false)
        end
    end)
end

local function style_label(ui, r, g, b, a)
    if ui == nil then
        return
    end
    pcall(function()
        if ui.set_text_color then
            ui:set_text_color(r, g, b, a or 255)
        end
        if ui.set_text_alignment then
            ui:set_text_alignment('左', '中')
        end
    end)
end

local function build_ui(view)
    clear_nodes()
    if host == nil then
        return false
    end

    view = view or {}
    local title_text = tostring(view.title or '雾州侠行')
    local subtitle_text = tostring(view.subtitle or '')
    local chapter_text = tostring(view.chapter or '')
    local tip_text = tostring(view.tip or '探索 · 开发中')

    local title = Kit.make_label(host, {
        x = 0, y = 0, w = 720, h = 40, text = title_text, font_size = 28,
    })
    place_pct(title, 1.5, 96, 720, 40, 80, 0, 1)
    style_label(title, 232, 208, 154, 255)

    local subtitle = Kit.make_label(host, {
        x = 0, y = 0, w = 720, h = 28, text = subtitle_text, font_size = 18,
    })
    place_pct(subtitle, 1.5, 92, 720, 28, 80, 0, 1)
    style_label(subtitle, 180, 190, 188, 255)

    local chapter = Kit.make_label(host, {
        x = 0, y = 0, w = 720, h = 28, text = chapter_text, font_size = 18,
    })
    place_pct(chapter, 1.5, 88.5, 720, 28, 80, 0, 1)
    style_label(chapter, 160, 175, 170, 255)

    local tip = Kit.make_label(host, {
        x = 0, y = 0, w = 900, h = 32, text = tip_text, font_size = 20,
    })
    place_pct(tip, 1.5, 4, 900, 32, 80, 0, 0)
    style_label(tip, 200, 195, 180, 230)

    local btn = Kit.make_button(host, {
        x = 0,
        y = 0,
        w = 280,
        h = 52,
        text = '返回角色选择',
        on_click = function()
            if type(on_return_cb) == 'function' then
                pcall(on_return_cb)
            end
        end,
    })
    place_pct(btn, 98.5, 96, 280, 52, 90, 1, 1)
    pcall(function()
        if btn and btn.set_intercepts_operations then
            btn:set_intercepts_operations(true)
        end
    end)

    nodes.title = title
    nodes.subtitle = subtitle
    nodes.chapter = chapter
    nodes.tip = tip
    nodes.btn_return = btn
    return title ~= nil
end

local function apply_view()
    local view_result = LocalRunSession.get_view()
    local view = view_result.ok and view_result.value or {}
    if nodes.title then
        Kit.set_label_text(nodes.title, tostring(view.title or ''))
        Kit.set_label_text(nodes.subtitle, tostring(view.subtitle or ''))
        Kit.set_label_text(nodes.chapter, tostring(view.chapter or ''))
        Kit.set_label_text(nodes.tip, tostring(view.tip or ''))
        return true
    end
    return build_ui(view)
end

---@param options? { on_return_to_slots?: fun(), session?: table }
---@return boolean ok
---@return string detail
function GameHudShell.mount(options)
    options = options or {}
    if type(y3) ~= 'table' or type(y3.ui) ~= 'table' then
        return false, 'y3_not_available'
    end

    player = Kit.get_player()
    if player == nil then
        return false, 'no_player'
    end

    -- Keep default prefab HUD off; our strip is enough for v1.
    Kit.set_default_hud_visible(player, true)
    -- Hide leftover boot boards; keep GameHUD.
    pcall(function()
        local names = { 'CommonTip', 'LoadingPanel', 'LogoPanel', 'save_slot', 'panel_1' }
        local i
        for i = 1, #names do
            local ok, board = pcall(function()
                return y3.ui.get_ui(player, names[i])
            end)
            if ok and board and board.set_visible then
                board:set_visible(false)
            end
        end
    end)

    local p, root, root_name = Kit.find_host_root()
    if root == nil then
        local ok, ui = pcall(function()
            return y3.ui.get_ui(player, 'GameHUD')
        end)
        if ok then
            root = ui
            root_name = 'GameHUD'
        end
    end
    if root == nil then
        return false, 'gamehud_missing'
    end
    host = root
    player = p or player

    pcall(function()
        host:set_visible(true)
        if host.set_z_order then
            host:set_z_order(500)
        end
        -- Must NOT swallow full-screen map input.
        if host.set_intercepts_operations then
            host:set_intercepts_operations(false)
        end
    end)

    on_return_cb = options.on_return_to_slots

    if not apply_view() then
        return false, 'build_failed'
    end

    mounted = true
    info('mounted on ' .. tostring(root_name))
    return true, 'mounted'
end

function GameHudShell.unmount()
    clear_nodes()
    if host then
        pcall(function()
            if host.set_intercepts_operations then
                host:set_intercepts_operations(false)
            end
        end)
    end
    host = nil
    player = nil
    on_return_cb = nil
    mounted = false
end

function GameHudShell.is_mounted()
    return mounted
end

function GameHudShell.refresh()
    if not mounted then
        return false
    end
    return apply_view()
end

return GameHudShell
