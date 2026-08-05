-- Drive the map's built-in CommonTip layer (has real button textures).
-- IMPORTANT: Y3 only allows get_ui AFTER 游戏-初始化. Call bind() then, not at require time.

local CommonTipPanel = {}

local LAYER_UID = '33f0362d-5a70-45e2-850b-d89082015a64'
local LAYER_NAME = 'CommonTip'

local bound = false
local player = nil
local layer = nil
local block = nil
local bg = nil
local title = nil
local content = nil
local wait = nil
local btn_left = nil
local btn_mid = nil
local btn_right = nil

local handlers = {
    left = nil,
    mid = nil,
    right = nil,
}
local events_bound = false
local last_error = nil

local function log(msg)
    print('[WZX][CommonTip] ' .. tostring(msg))
end

function CommonTipPanel.last_error()
    return last_error
end

local function resolve_player()
    local candidates = {}
    pcall(function()
        if y3.player.get_local then
            candidates[#candidates + 1] = y3.player.get_local()
        end
    end)
    pcall(function()
        if y3.player.LOCAL_PLAYER then
            candidates[#candidates + 1] = y3.player.LOCAL_PLAYER
        end
    end)
    pcall(function()
        if GameAPI and GameAPI.get_client_role and y3.player.get_by_handle then
            candidates[#candidates + 1] = y3.player.get_by_handle(GameAPI.get_client_role())
        end
    end)
    pcall(function()
        candidates[#candidates + 1] = y3.player(1)
    end)
    local index
    for index = 1, #candidates do
        if candidates[index] ~= nil then
            return candidates[index]
        end
    end
    return nil
end

local function try_get_ui_path(p, path)
    local ok, ui_or_err = pcall(function()
        return y3.ui.get_ui(p, path)
    end)
    if ok and ui_or_err ~= nil then
        return ui_or_err, nil
    end
    return nil, tostring(ui_or_err)
end

local function try_get_by_handle(p, handle)
    local ok, ui_or_err = pcall(function()
        return y3.ui.get_by_handle(p, handle)
    end)
    if ok and ui_or_err ~= nil then
        return ui_or_err, nil
    end
    return nil, tostring(ui_or_err)
end

local function try_get_child(parent, name)
    if parent == nil then
        return nil
    end
    local ok, child = pcall(function()
        return parent:get_child(name)
    end)
    if ok and child ~= nil then
        return child
    end
    return nil
end

local function set_visible(ui, visible)
    if ui == nil then
        return
    end
    pcall(function()
        ui:set_visible(visible == true)
    end)
end

local function set_text(ui, text)
    if ui == nil then
        return
    end
    pcall(function()
        ui:set_text(tostring(text or ''))
    end)
end

local function set_btn_text(btn, text)
    if btn == nil then
        return
    end
    text = tostring(text or '')
    pcall(function()
        if btn.set_btn_status_string and y3.const and y3.const.UIButtonStatus then
            local st = y3.const.UIButtonStatus
            btn:set_btn_status_string(st['常态'] or 1, text)
            btn:set_btn_status_string(st['悬浮'] or 2, text)
            btn:set_btn_status_string(st['按下'] or 3, text)
            btn:set_btn_status_string(st['禁用'] or 4, text)
        end
    end)
    pcall(function()
        if btn.set_text then
            btn:set_text(text)
        end
    end)
end

local function set_btn_enable(btn, enable)
    if btn == nil then
        return
    end
    pcall(function()
        if btn.set_button_enable then
            btn:set_button_enable(enable == true)
        end
    end)
end

local function fire(which)
    local fn = handlers[which]
    if type(fn) == 'function' then
        pcall(fn)
    end
end

local function bind_button_clicks()
    if events_bound then
        return true
    end
    local any = false
    local function bind_one(btn, which)
        if btn == nil then
            return
        end
        local bound_ok = false
        pcall(function()
            if btn.add_local_event then
                btn:add_local_event('左键-点击', function()
                    fire(which)
                end)
                bound_ok = true
            end
        end)
        if not bound_ok then
            pcall(function()
                if btn.add_fast_event then
                    btn:add_fast_event('左键-点击', function()
                        fire(which)
                    end)
                    bound_ok = true
                end
            end)
        end
        if not bound_ok then
            pcall(function()
                local event_name = 'wzx_common_tip_' .. which
                btn:add_event('左键-点击', event_name, { which = which })
                y3.game:event('界面-消息', event_name, function()
                    fire(which)
                end)
                bound_ok = true
            end)
        end
        if bound_ok then
            any = true
        else
            log('click bind failed for ' .. which)
        end
    end
    bind_one(btn_left, 'left')
    bind_one(btn_mid, 'mid')
    bind_one(btn_right, 'right')
    events_bound = any
    return any
end

local function resolve_layer(p)
    local errs = {}
    local ui, err

    ui, err = try_get_ui_path(p, LAYER_NAME)
    if ui then
        return ui, 'path:' .. LAYER_NAME
    end
    errs[#errs + 1] = 'path CommonTip: ' .. tostring(err)

    ui, err = try_get_by_handle(p, LAYER_UID)
    if ui then
        return ui, 'uid'
    end
    errs[#errs + 1] = 'uid: ' .. tostring(err)

    -- Some builds expose layer via prefab id proxy
    ui, err = try_get_by_handle(p, LAYER_NAME)
    if ui then
        return ui, 'handle-name'
    end
    errs[#errs + 1] = 'handle-name: ' .. tostring(err)

    last_error = table.concat(errs, ' | ')
    return nil, nil
end

local function resolve_children()
    -- Prefer absolute paths; fallback get_child from layer/bg
    local function path_or_child(abs_path, parent, child_name)
        local ui = select(1, try_get_ui_path(player, abs_path))
        if ui then
            return ui
        end
        return try_get_child(parent, child_name)
    end

    block = path_or_child('CommonTip.block', layer, 'block')
    bg = path_or_child('CommonTip.bg', layer, 'bg')
    wait = path_or_child('CommonTip.wait', layer, 'wait')

    title = path_or_child('CommonTip.bg.title', bg, 'title')
    content = path_or_child('CommonTip.bg.content', bg, 'content')
    btn_mid = path_or_child('CommonTip.bg.btn_mid', bg, 'btn_mid')
    btn_left = path_or_child('CommonTip.bg.btn_left', bg, 'btn_left')
    btn_right = path_or_child('CommonTip.bg.btn_right', bg, 'btn_right')
end

---Bind to CommonTip. Must run after 游戏-初始化 (or late enough that UI exists).
---@return boolean ok
---@return string reason
function CommonTipPanel.bind()
    if bound and layer ~= nil and btn_mid ~= nil then
        return true, 'already'
    end
    last_error = nil

    if type(y3) ~= 'table' or type(y3.ui) ~= 'table' then
        last_error = 'y3_missing'
        return false, last_error
    end

    player = resolve_player()
    if player == nil then
        last_error = 'no_player'
        return false, last_error
    end

    local how
    layer, how = resolve_layer(player)
    if layer == nil then
        if last_error == nil then
            last_error = 'CommonTip_not_found'
        end
        log('bind fail: ' .. last_error)
        return false, 'CommonTip_not_found'
    end
    log('layer ok via ' .. tostring(how))

    resolve_children()

    if title == nil or content == nil or btn_mid == nil then
        last_error = string.format(
            'children_missing title=%s content=%s mid=%s left=%s right=%s bg=%s',
            tostring(title ~= nil),
            tostring(content ~= nil),
            tostring(btn_mid ~= nil),
            tostring(btn_left ~= nil),
            tostring(btn_right ~= nil),
            tostring(bg ~= nil)
        )
        log('bind fail: ' .. last_error)
        -- Soft fail: if at least mid exists later retry; hard fail now
        bound = false
        return false, 'CommonTip_children_missing'
    end

    set_visible(wait, false)
    bind_button_clicks()
    bound = true
    last_error = nil
    log('bound OK (CommonTip with textures)')
    return true, 'ok'
end

function CommonTipPanel.is_bound()
    return bound == true
end

function CommonTipPanel.show(opts)
    opts = opts or {}
    if not bound then
        local ok = CommonTipPanel.bind()
        if not ok then
            return false
        end
    end

    -- mode:
    --   modal (default): full dialog + dim block
    --   skip_bar: only mid button, no dim block / no dialog bg (for video overlay)
    --   video_veil: 仅全屏深色 block 蒙版（已验证能显示），无对话框
    local mode = opts.mode or 'modal'

    if mode == 'video_veil' then
        handlers.left = nil
        handlers.mid = nil
        handlers.right = nil
        set_visible(wait, false)
        set_visible(bg, false)
        set_visible(title, false)
        set_visible(content, false)
        set_visible(btn_left, false)
        set_visible(btn_mid, false)
        set_visible(btn_right, false)
        if block then
            pcall(function()
                if block.set_ui_size then
                    block:set_ui_size(1920, 1080)
                end
                if block.set_pos then
                    block:set_pos(960, 540)
                end
                -- 深黑蒙版：block 自带 color，再压不透明度
                if block.set_alpha then
                    -- 越接近 1 越不透明；目标盖住视频
                    block:set_alpha(opts.veil_alpha or 0.88)
                end
                if block.set_z_order then
                    block:set_z_order(9000)
                end
                block:set_visible(true)
            end)
        end
        pcall(function()
            if layer then
                layer:set_visible(true)
                if layer.set_z_order then
                    layer:set_z_order(8500)
                end
            end
        end)
        log('video_veil on')
        return block ~= nil
    end

    set_text(title, opts.title or '雾州侠行')
    set_text(content, opts.content or '')

    local function apply_btn(btn, key, cfg)
        if cfg == nil or cfg.text == nil or cfg.text == '' then
            handlers[key] = nil
            set_visible(btn, false)
            return
        end
        handlers[key] = cfg.on_click
        set_btn_text(btn, cfg.text)
        set_btn_enable(btn, true)
        set_visible(btn, true)
    end

    apply_btn(btn_left, 'left', opts.left)
    apply_btn(btn_mid, 'mid', opts.mid)
    apply_btn(btn_right, 'right', opts.right)

    set_visible(wait, false)

    if mode == 'skip_bar' then
        -- Don't cover full-screen video: no dark block, no dialog plate.
        set_visible(block, false)
        set_visible(bg, false)
        set_visible(title, false)
        set_visible(content, false)
        -- mid button stays visible if provided (may sit at default dialog pos)
        set_visible(layer, true)
        return true
    end

    set_visible(title, true)
    set_visible(content, true)
    set_visible(block, opts.hide_block ~= true)
    set_visible(bg, true)
    set_visible(layer, true)
    return true
end

function CommonTipPanel.hide()
    if layer ~= nil then
        set_visible(layer, false)
    end
    handlers.left = nil
    handlers.mid = nil
    handlers.right = nil
end

function CommonTipPanel.release()
    CommonTipPanel.hide()
    handlers.left = nil
    handlers.mid = nil
    handlers.right = nil
    -- Keep bound=true so remount can reuse nodes after hide;
    -- full reset only if needed externally.
end

---Reset so next bind() re-resolves (e.g. after map reload).
function CommonTipPanel.reset()
    CommonTipPanel.hide()
    bound = false
    events_bound = false
    player = nil
    layer = nil
    block = nil
    bg = nil
    title = nil
    content = nil
    wait = nil
    btn_left = nil
    btn_mid = nil
    btn_right = nil
    handlers.left = nil
    handlers.mid = nil
    handlers.right = nil
end

return CommonTipPanel
