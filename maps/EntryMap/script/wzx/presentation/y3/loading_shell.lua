-- Loading on custom panel_1 (engine LoadingPanel is auto-dismissed / wiped).
-- Must mount AFTER 游戏-初始化: runtime create_child nodes created before init get destroyed.

local Kit = require 'wzx.presentation.y3.runtime_ui_kit'

local LoadingShell = {}

local mounted = false
local visible = false
local progress = 0
local tip_text = '雾州侠行 · 加载中…'
local last_tip = nil
local last_pct = nil
local progress_timer = nil
local watchdog_timer = nil
local on_finished_cb = nil
local generation = 0
local boot_running = false
local boot_finished = false

local nodes = {
    host = nil,
    bg = nil,
    tip = nil,
    percent = nil,
    track = nil,
    fill = nil,
}

local BG_ICON_ID = 134230791
-- Bottom HUD. Y3 set_ui_comp_pos_percent: Y=0 is bottom, Y=100 is top.
local BAR_W, BAR_H = 1200, 18
local BAR_X_PCT, BAR_Y_PCT = 50, 6 -- bar center
local BAR_LEFT_PCT = (1920 - BAR_W) / 2 / 1920 * 100 -- ~18.75
local BAR_RIGHT_PCT = BAR_LEFT_PCT + BAR_W / 1920 * 100 -- ~81.25
-- Text sits just above the bar, left/right edges flush with bar ends.
local TEXT_Y_PCT = 9.5
local TIP_X_PCT, TIP_Y_PCT = BAR_LEFT_PCT, TEXT_Y_PCT
local PCT_X_PCT, PCT_Y_PCT = BAR_RIGHT_PCT, TEXT_Y_PCT

local function info(msg)
    local text = '[WZX][Loading] ' .. tostring(msg)
    pcall(function()
        if log and log.info then
            log.info(text)
        end
    end)
    print(text)
end

local function clear_timer(t)
    if t == nil then
        return nil
    end
    pcall(function()
        if t.remove then
            t:remove()
        end
    end)
    return nil
end

local function get_player()
    local player = Kit.get_player()
    if player == nil then
        pcall(function()
            player = y3.player(1)
        end)
    end
    return player
end

local function clear_float_message()
    pcall(function()
        local player = get_player()
        if player and y3.ui and y3.ui.display_message then
            y3.ui.display_message(player, '', 0.01)
        end
    end)
end

local function get_ui(player, name)
    local ok, ui = pcall(function()
        return y3.ui.get_ui(player, name)
    end)
    if ok then
        return ui
    end
    return nil
end

local function node_dead(ui)
    -- Only treat explicit nil as dead. is_removed() is flaky and caused rebuild flashes.
    return ui == nil
end

---Engine LoadingPanel must stay fully off (it draws a second bar near the top).
local function suppress_engine_loading(player)
    local board = get_ui(player, 'LoadingPanel')
    if board == nil then
        return
    end
    pcall(function()
        if board.set_visible then
            board:set_visible(false)
        end
        if board.set_alpha then
            board:set_alpha(0)
        end
        if board.set_z_order then
            board:set_z_order(0)
        end
    end)
    -- Also hide its progress bar child if queryable
    pcall(function()
        local bar = board.get_child and board:get_child('loading_bar_percent')
        if bar and bar.set_visible then
            bar:set_visible(false)
        end
        local bg = board.get_child and board:get_child('loading_background')
        if bg and bg.set_visible then
            bg:set_visible(false)
        end
    end)
end

---Place by screen percent (0-100). More reliable for bottom HUD than raw set_pos.
---@param ax number anchor x 0-1
---@param ay number anchor y 0-1
local function place_pct(ui, x_pct, y_pct, w, h, z, ax, ay)
    if ui == nil then
        return
    end
    local player = get_player()
    ax = ax or 0.5
    ay = ay or 0.5
    pcall(function()
        if ui.set_anchor then
            ui:set_anchor(ax, ay)
        end
        if w and h and ui.set_ui_size then
            ui:set_ui_size(w, h)
        end
        if player and GameAPI and GameAPI.set_ui_comp_pos_percent then
            GameAPI.set_ui_comp_pos_percent(player.handle, ui.handle, x_pct, y_pct)
        elseif ui.set_pos then
            -- fallback: treat percent as design coords
            ui:set_pos(1920 * x_pct / 100, 1080 * y_pct / 100)
        end
        if ui.set_visible then
            ui:set_visible(true)
        end
        if z and ui.set_z_order then
            ui:set_z_order(z)
        end
    end)
end

local function place_fullscreen(ui)
    if ui == nil then
        return
    end
    local player = get_player()
    pcall(function()
        if ui.set_ui_size then
            ui:set_ui_size(1920, 1080)
        end
        if ui.set_anchor then
            ui:set_anchor(0.5, 0.5)
        end
        if player and GameAPI and GameAPI.set_ui_comp_pos_percent then
            GameAPI.set_ui_comp_pos_percent(player.handle, ui.handle, 50, 50)
        elseif ui.set_pos then
            ui:set_pos(960, 540)
        end
        if ui.set_visible then
            ui:set_visible(true)
        end
        if ui.set_z_order then
            ui:set_z_order(1)
        end
    end)
end

local function try_set_image(ui, img)
    if ui == nil or img == nil then
        return false
    end
    return pcall(function()
        ui:set_image(img)
    end) == true
end

local function hold_host()
    if node_dead(nodes.host) then
        return false
    end
    pcall(function()
        nodes.host:set_visible(true)
        if nodes.host.set_z_order then
            nodes.host:set_z_order(9999)
        end
        if nodes.host.set_intercepts_operations then
            nodes.host:set_intercepts_operations(true)
        end
    end)
    if not node_dead(nodes.bg) then
        pcall(function()
            nodes.bg:set_visible(true)
        end)
    end
    return true
end

local function build_ui(host)
    -- Drop previous handles (may be dead after 游戏-初始化 wipe)
    nodes.bg = nil
    nodes.tip = nil
    nodes.percent = nil
    nodes.track = nil
    nodes.fill = nil

    local bg = Kit.create_child(host, '图片')
    place_fullscreen(bg)
    if bg then
        if not try_set_image(bg, BG_ICON_ID) then
            try_set_image(bg, 'ui/' .. tostring(BG_ICON_ID))
        end
    end

    -- Tip left-aligned to bar left; percent right-aligned to bar right; both above bar.
    local tip = Kit.make_label(host, {
        x = 0, y = 0, w = 700, h = 36, text = tip_text, font_size = 26,
    })
    place_pct(tip, TIP_X_PCT, TIP_Y_PCT, 700, 36, 50, 0, 0.5)
    pcall(function()
        if tip and tip.set_text_color then
            tip:set_text_color(235, 225, 205, 255)
        end
        if tip and tip.set_text_alignment then
            tip:set_text_alignment('左', '中')
        end
    end)

    local percent = Kit.make_label(host, {
        x = 0, y = 0, w = 160, h = 36, text = '0%', font_size = 26,
    })
    place_pct(percent, PCT_X_PCT, PCT_Y_PCT, 160, 36, 50, 1, 0.5)
    pcall(function()
        if percent and percent.set_text_color then
            percent:set_text_color(235, 225, 205, 255)
        end
        if percent and percent.set_text_alignment then
            percent:set_text_alignment('右', '中')
        end
    end)

    local track = Kit.create_child(host, '图片')
    place_pct(track, BAR_X_PCT, BAR_Y_PCT, BAR_W, BAR_H, 40, 0.5, 0.5)
    if track then
        if not try_set_image(track, 106409) then
            try_set_image(track, 110020)
        end
        pcall(function()
            if track.set_image_color then
                track:set_image_color(28, 26, 34, 230)
            end
        end)
    end

    local fill = Kit.create_child(host, '图片')
    -- Grow from left edge of the track
    place_pct(fill, BAR_LEFT_PCT, BAR_Y_PCT, 1, BAR_H, 45, 0, 0.5)
    if fill then
        if not try_set_image(fill, 106408) then
            try_set_image(fill, 110020)
        end
        pcall(function()
            if fill.set_image_color then
                fill:set_image_color(210, 175, 110, 255)
            end
        end)
    end

    nodes.bg = bg
    nodes.tip = tip
    nodes.percent = percent
    nodes.track = track
    nodes.fill = fill
    last_tip = nil
    last_pct = nil

    info(string.format(
        'build_ui bg=%s tip=%s fill=%s',
        tostring(bg ~= nil),
        tostring(tip ~= nil),
        tostring(fill ~= nil)
    ))
    return bg ~= nil
end

local function apply_progress()
    local player = get_player()
    if player then
        suppress_engine_loading(player)
    end
    hold_host()

    if node_dead(nodes.bg) or node_dead(nodes.host) then
        info('apply_progress: nodes missing at ' .. tostring(math.floor(progress)) .. '%')
        return false
    end

    local p = progress
    if p < 0 then
        p = 0
    end
    if p > 100 then
        p = 100
    end
    progress = p
    local pct = math.floor(p + 0.5)

    if nodes.percent and pct ~= last_pct then
        Kit.set_label_text(nodes.percent, string.format('%d%%', pct))
        last_pct = pct
    end
    if nodes.tip and tip_text ~= last_tip then
        Kit.set_label_text(nodes.tip, tip_text)
        last_tip = tip_text
    end

    -- Only resize fill width; keep left edge anchored at bar start.
    if nodes.fill then
        local w = math.floor(BAR_W * (p / 100) + 0.5)
        if p > 0 and w < 4 then
            w = 4
        end
        if w < 1 then
            w = 1
        end
        pcall(function()
            if nodes.fill.set_ui_size then
                nodes.fill:set_ui_size(w, BAR_H)
            end
            if nodes.fill.set_visible then
                nodes.fill:set_visible(p > 0)
            end
        end)
        -- Re-assert bottom position (size change can drift in some builds)
        place_pct(nodes.fill, BAR_LEFT_PCT, BAR_Y_PCT, w, BAR_H, 45, 0, 0.5)
    end
    return true
end

local function stop_progress()
    progress_timer = clear_timer(progress_timer)
    boot_running = false
end

local function stop_watchdog()
    watchdog_timer = clear_timer(watchdog_timer)
end

local function start_watchdog()
    stop_watchdog()
    if not (y3.ltimer and y3.ltimer.loop) then
        return
    end
    local gen = generation
    -- Only suppress engine LoadingPanel + keep host on top. Never rebuild here.
    watchdog_timer = y3.ltimer.loop(0.5, function()
        if gen ~= generation or not mounted then
            return
        end
        local player = get_player()
        if player then
            suppress_engine_loading(player)
        end
        hold_host()
    end)
end

---@return boolean ok
---@return string detail
function LoadingShell.mount()
    if type(y3) ~= 'table' or type(y3.ui) ~= 'table' then
        return false, 'y3_not_available'
    end

    local player = get_player()
    if player == nil then
        return false, 'no_player'
    end

    Kit.set_default_hud_visible(player, true)
    clear_float_message()
    suppress_engine_loading(player)

    -- Always rebuild after mount call (init may have wiped prior create_child tree).
    local host = get_ui(player, 'panel_1')
    if host == nil then
        host = get_ui(player, 'GameHUD')
    end
    if host == nil then
        return false, 'host_missing'
    end

    nodes.host = host
    pcall(function()
        host:set_visible(true)
        if host.set_z_order then
            host:set_z_order(9999)
        end
        if host.set_intercepts_operations then
            host:set_intercepts_operations(true)
        end
    end)

    if not build_ui(host) then
        return false, 'bg_create_failed'
    end

    mounted = true
    visible = true
    progress = 0
    tip_text = '雾州侠行 · 加载中…'
    last_tip = nil
    last_pct = nil
    boot_running = false
    boot_finished = false

    apply_progress()
    start_watchdog()
    info('mounted custom host after game ready')
    return true, 'mounted'
end

function LoadingShell.unmount()
    generation = generation + 1
    stop_progress()
    stop_watchdog()
    boot_finished = false

    local keys = { 'bg', 'tip', 'percent', 'track', 'fill' }
    local i
    for i = 1, #keys do
        local k = keys[i]
        if nodes[k] then
            Kit.remove(nodes[k])
            nodes[k] = nil
        end
    end
    if nodes.host and not node_dead(nodes.host) then
        pcall(function()
            if nodes.host.set_intercepts_operations then
                nodes.host:set_intercepts_operations(false)
            end
        end)
    end
    nodes.host = nil
    mounted = false
    visible = false
    on_finished_cb = nil
end

---@param show boolean
function LoadingShell.set_visible(show)
    visible = show == true
    if visible then
        hold_host()
        apply_progress()
        start_watchdog()
    else
        stop_progress()
        stop_watchdog()
    end
end

function LoadingShell.is_mounted()
    return mounted
end

function LoadingShell.is_visible()
    return visible
end

function LoadingShell.is_boot_running()
    return boot_running == true
end

function LoadingShell.is_boot_finished()
    return boot_finished == true
end

---@param value number
---@param tip? string
function LoadingShell.set_progress(value, tip)
    if type(value) == 'number' then
        progress = value
    end
    if tip ~= nil then
        tip_text = tostring(tip)
    end
    apply_progress()
end

---@param cb fun()
function LoadingShell.on_finished(cb)
    on_finished_cb = cb
end

local function phase_for(p, fixed_tip)
    if fixed_tip then
        return tostring(fixed_tip)
    end
    if p < 20 then
        return '唤醒雾钟…'
    end
    if p < 45 then
        return '整理行囊…'
    end
    if p < 70 then
        return '勾连存档…'
    end
    if p < 95 then
        return '校准罗盘…'
    end
    return '即将启程…'
end

---@param options? { duration?: number, tip?: string, hold?: number }
function LoadingShell.run_boot_progress(options)
    options = options or {}
    if boot_running then
        return true, 'already_running'
    end

    if not mounted then
        local ok, detail = LoadingShell.mount()
        if not ok then
            return false, detail
        end
    else
        hold_host()
    end

    local fixed_tip = options.tip
    progress_timer = clear_timer(progress_timer)

    local duration = options.duration or 6.0
    if duration < 3.0 then
        duration = 3.0
    end
    local hold = options.hold or 1.5
    if hold < 0.8 then
        hold = 0.8
    end

    local steps = 20
    local step_dt = duration / steps
    local gen = generation
    progress = 0
    boot_running = true
    boot_finished = false
    tip_text = phase_for(0, fixed_tip)
    last_tip = nil
    last_pct = nil
    apply_progress()
    start_watchdog()

    local function finish()
        if gen ~= generation then
            return
        end
        progress = 100
        tip_text = phase_for(100, fixed_tip)
        last_tip = nil
        last_pct = nil
        hold_host()
        apply_progress()
        boot_running = false
        boot_finished = true
        info('100% done — cover stays on panel_1')
        if type(on_finished_cb) == 'function' then
            pcall(on_finished_cb)
        end
    end

    if not (y3.ltimer and y3.ltimer.loop_count) then
        finish()
        return true, 'boot_instant'
    end

    -- Second-based loop_count (simple, predictable). Watchdog rebuilds wiped UI.
    progress_timer = y3.ltimer.loop_count(step_dt, steps, function(timer, count)
        if gen ~= generation then
            boot_running = false
            return
        end
        local step_i = count or 0
        if step_i < 1 then
            step_i = 1
        end
        local p = (step_i / steps) * 100
        if p > 100 then
            p = 100
        end
        progress = p
        tip_text = phase_for(p, fixed_tip)
        pcall(apply_progress)
        if step_i % 5 == 0 then
            info(string.format('progress %d%% %s', math.floor(p), tip_text))
        end
        if step_i >= steps then
            progress_timer = nil
            if y3.ltimer.wait then
                progress_timer = y3.ltimer.wait(hold, function()
                    finish()
                end)
            else
                finish()
            end
        end
    end)

    return true, 'boot_running'
end

LoadingShell.play_demo = LoadingShell.run_boot_progress

return LoadingShell
