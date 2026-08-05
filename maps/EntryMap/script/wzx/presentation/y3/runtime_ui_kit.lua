-- Runtime UI helpers for clickable panels built under existing Y3 layers.
-- No editor prefab required; domain stays free of y3.* (this file is the engine boundary).

local RuntimeUIKit = {}

local ROOT_CANDIDATES = {
    'GameHUD',
    'LoadingPanel',
    'LogoPanel',
    'CommonTip',
}

local function shell_log(msg)
    print('[WZX][UI] ' .. tostring(msg))
end

function RuntimeUIKit.get_player()
    if type(y3) ~= 'table' or type(y3.player) ~= 'function' then
        return nil
    end
    local ok, player = pcall(function()
        return y3.player(1)
    end)
    if ok then
        return player
    end
    return nil
end

---Find a stable host layer already present on the map.
---@return any|nil player
---@return any|nil root_ui
---@return string|nil root_name
function RuntimeUIKit.find_host_root()
    local player = RuntimeUIKit.get_player()
    if player == nil or type(y3.ui) ~= 'table' or type(y3.ui.get_ui) ~= 'function' then
        return nil, nil, nil
    end
    local index
    for index = 1, #ROOT_CANDIDATES do
        local name = ROOT_CANDIDATES[index]
        local ok, ui = pcall(function()
            return y3.ui.get_ui(player, name)
        end)
        if ok and ui ~= nil then
            return player, ui, name
        end
    end
    return player, nil, nil
end

---@param player any
---@param prefer_hide boolean
function RuntimeUIKit.set_default_hud_visible(player, prefer_hide)
    if player == nil or type(y3.ui) ~= 'table' then
        return
    end
    pcall(function()
        if type(y3.ui.set_prefab_ui_visible) == 'function' then
            -- false = hide default MOBA HUD so our panels are readable
            y3.ui.set_prefab_ui_visible(player, not prefer_hide)
        end
    end)
end

---@param ui any
---@param x number
---@param y number
---@param w number
---@param h number
function RuntimeUIKit.place(ui, x, y, w, h)
    if ui == nil then
        return ui
    end
    pcall(function()
        if w and h and ui.set_ui_size then
            ui:set_ui_size(w, h)
        end
        if ui.set_pos then
            ui:set_pos(x, y)
        end
    end)
    return ui
end

---@param parent any
---@param comp_type string
---@return any|nil
function RuntimeUIKit.create_child(parent, comp_type)
    if parent == nil or type(parent.create_child) ~= 'function' then
        return nil
    end
    local ok, child = pcall(function()
        return parent:create_child(comp_type)
    end)
    if ok then
        return child
    end
    return nil
end

---@param ui any
---@param text string
function RuntimeUIKit.set_label_text(ui, text)
    if ui == nil then
        return
    end
    text = tostring(text or '')
    pcall(function()
        if ui.set_text then
            ui:set_text(text)
        end
    end)
    pcall(function()
        if ui.set_font_size then
            ui:set_font_size(22)
        end
    end)
end

---@param btn any
---@param text string
function RuntimeUIKit.set_button_label(btn, text)
    if btn == nil then
        return
    end
    text = tostring(text or '')
    -- Prefer button status strings (engine default button chrome)
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

---@param ui any
---@param visible boolean
function RuntimeUIKit.set_visible(ui, visible)
    if ui == nil then
        return
    end
    pcall(function()
        if ui.set_visible then
            ui:set_visible(visible == true)
        end
    end)
end

---@param ui any
---@param enable boolean
function RuntimeUIKit.set_button_enable(ui, enable)
    if ui == nil then
        return
    end
    pcall(function()
        if ui.set_button_enable then
            ui:set_button_enable(enable == true)
        end
    end)
end

---Bind left-click. Prefer local event (instant, single-player safe).
---@param ui any
---@param callback fun()
---@return boolean
function RuntimeUIKit.on_click(ui, callback)
    if ui == nil or type(callback) ~= 'function' then
        return false
    end
    local bound = false
    pcall(function()
        if ui.add_local_event then
            ui:add_local_event('左键-点击', function()
                pcall(callback)
            end)
            bound = true
        end
    end)
    if bound then
        return true
    end
    pcall(function()
        if ui.add_fast_event then
            ui:add_fast_event('左键-点击', function()
                pcall(callback)
            end)
            bound = true
        end
    end)
    return bound
end

---@param ui any
function RuntimeUIKit.remove(ui)
    if ui == nil then
        return
    end
    pcall(function()
        if ui.remove then
            ui:remove()
        end
    end)
end

---Build a simple labeled button under parent.
---@param parent any
---@param opts { x:number, y:number, w:number, h:number, text:string, on_click:fun() }
---@return any|nil btn
function RuntimeUIKit.make_button(parent, opts)
    opts = opts or {}
    local btn = RuntimeUIKit.create_child(parent, '按钮')
    if btn == nil then
        return nil
    end
    RuntimeUIKit.place(btn, opts.x or 0, opts.y or 0, opts.w or 280, opts.h or 56)
    RuntimeUIKit.set_button_label(btn, opts.text or '')
    RuntimeUIKit.set_button_enable(btn, true)
    pcall(function()
        if btn.set_intercepts_operations then
            btn:set_intercepts_operations(true)
        end
        if btn.set_z_order then
            btn:set_z_order(50)
        end
    end)
    if type(opts.on_click) == 'function' then
        local ok_bind = RuntimeUIKit.on_click(btn, opts.on_click)
        if not ok_bind then
            shell_log('button click bind failed: ' .. tostring(opts.text))
        end
    end
    return btn
end

---Build a multi-line text label.
---@param parent any
---@param opts { x:number, y:number, w:number, h:number, text:string, font_size:number }
---@return any|nil
function RuntimeUIKit.make_label(parent, opts)
    opts = opts or {}
    local label = RuntimeUIKit.create_child(parent, '文本')
    if label == nil then
        return nil
    end
    RuntimeUIKit.place(label, opts.x or 0, opts.y or 0, opts.w or 600, opts.h or 40)
    RuntimeUIKit.set_label_text(label, opts.text or '')
    pcall(function()
        if label.set_font_size then
            label:set_font_size(opts.font_size or 22)
        end
        if label.set_z_order then
            label:set_z_order(40)
        end
    end)
    return label
end

---Full-screen-ish panel container under host root.
---@param root any
---@param name_tag string
---@return any|nil panel
function RuntimeUIKit.make_panel(root, name_tag)
    local panel = RuntimeUIKit.create_child(root, '图片')
    if panel == nil then
        panel = RuntimeUIKit.create_child(root, '空节点')
    end
    if panel == nil then
        shell_log('make_panel failed under host for ' .. tostring(name_tag))
        return nil
    end
    -- Cover most of 1920x1080 design; anchors may vary by host layer.
    RuntimeUIKit.place(panel, 0, 0, 1920, 1080)
    pcall(function()
        if panel.set_z_order then
            panel:set_z_order(200)
        end
        if panel.set_intercepts_operations then
            panel:set_intercepts_operations(true)
        end
        if panel.set_alpha then
            panel:set_alpha(0.92)
        end
        -- Darken if possible (no texture required for color overlay on some builds)
        if panel.set_image_color then
            panel:set_image_color(20, 18, 28, 230)
        end
    end)
    RuntimeUIKit.set_visible(panel, true)
    return panel
end

return RuntimeUIKit
