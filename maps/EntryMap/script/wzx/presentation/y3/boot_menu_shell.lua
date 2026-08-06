-- Clickable boot menu via map CommonTip (real textures). Keyboard fallback kept.

local BootFlow = require 'wzx.application.boot.boot_flow'
local OfficialCloudGate = require 'wzx.adapters.y3.official_cloud_gate'
local CommonTip = require 'wzx.presentation.y3.common_tip_panel'

local BootMenuShell = {}

local mounted = false
local flow = nil
local triggers = {}
local on_entered_cb = nil
local ui_ready = false

local function shell_log(msg)
    print('[WZX][开局] ' .. tostring(msg))
end

local function bind_trigger(trg)
    if trg ~= nil then
        triggers[#triggers + 1] = trg
    end
end

local function present(view_result)
    if not view_result.ok then
        local reason = 'unknown'
        if view_result.error and view_result.error.details and view_result.error.details.reason then
            reason = tostring(view_result.error.details.reason)
        end
        if ui_ready then
            CommonTip.show({
                title = '开局失败',
                content = reason,
                mid = {
                    text = '关闭',
                    on_click = function()
                        CommonTip.hide()
                    end,
                },
            })
        end
        return
    end

    local view = view_result.value

    if view.entered then
        if ui_ready then
            CommonTip.hide()
        end
        if on_entered_cb then
            pcall(on_entered_cb, view.entered_payload)
        end
        return
    end

    if not ui_ready then
        -- Keyboard-only path already works via present not needed for display
        shell_log('UI 未就绪，仅键盘；screen=' .. tostring(view.screen))
        return
    end

    if view.screen == 'TITLE' then
        CommonTip.show({
            title = view.title or '雾州侠行',
            content = '欢迎。\n点「开始」进入存档选择。\n（这是游戏内对话框，不是日志）',
            mid = {
                text = '开 始',
                on_click = function()
                    BootMenuShell._act(function()
                        return flow:start()
                    end)
                end,
            },
        })
        return
    end

    if view.screen == 'BACKEND' then
        CommonTip.show({
            title = '选择存档',
            content = '本地开发档：现在可进\n官方云档：尚未验证，会提示锁定原因',
            left = {
                text = '本地档',
                on_click = function()
                    BootMenuShell._act(function()
                        return flow:select_backend('local_dev')
                    end)
                end,
            },
            mid = {
                text = '官方云档',
                on_click = function()
                    BootMenuShell._act(function()
                        return flow:select_backend('official_cloud')
                    end)
                end,
            },
            right = {
                text = '返 回',
                on_click = function()
                    BootMenuShell._act(function()
                        return flow:back()
                    end)
                end,
            },
        })
        return
    end

    if view.screen == 'OFFICIAL_BLOCKED' then
        CommonTip.show({
            title = '官方云档锁定',
            content = tostring(view.message or '官方云档暂不可用'),
            mid = {
                text = '返 回',
                on_click = function()
                    BootMenuShell._act(function()
                        return flow:back()
                    end)
                end,
            },
        })
        return
    end

    if view.screen == 'SLOTS' then
        local lines = { '点「切换」改选中槽；空槽先「新建」再「进入」。', '' }
        local index
        for index = 1, #view.slots do
            local s = view.slots[index]
            local mark = (s.slot_index == view.selected_slot_index) and '▶' or ' '
            local body
            if s.empty then
                body = '（空）'
            else
                body = tostring(s.display_name or '')
            end
            lines[#lines + 1] = mark .. ' 槽' .. tostring(s.slot_index) .. ' ' .. body
        end
        if view.message and view.message ~= '' then
            lines[#lines + 1] = ''
            lines[#lines + 1] = tostring(view.message)
        end
        CommonTip.show({
            title = '本地存档',
            content = table.concat(lines, '\n'),
            left = {
                text = '切 换',
                on_click = function()
                    BootMenuShell._act(function()
                        local v = flow:get_view()
                        if not v.ok then
                            return v
                        end
                        local cur = v.value.selected_slot_index or 1
                        local slot_n = #v.value.slots
                        if slot_n < 1 then
                            slot_n = 5
                        end
                        local next_i = cur + 1
                        if next_i > slot_n then
                            next_i = 1
                        end
                        return flow:select_slot(next_i)
                    end)
                end,
            },
            mid = {
                text = '进 入',
                on_click = function()
                    BootMenuShell._act(function()
                        return flow:confirm_enter()
                    end)
                end,
            },
            right = {
                text = '新 建',
                on_click = function()
                    BootMenuShell._act(function()
                        return flow:create_slot()
                    end)
                end,
            },
        })
        return
    end
end

function BootMenuShell._act(fn)
    if flow == nil then
        return
    end
    present(fn())
end

local function bind_keyboard_fallback()
    if type(y3) ~= 'table' or type(y3.game) ~= 'table' then
        return
    end
    local function act(fn)
        return function()
            if flow == nil then
                return
            end
            present(fn())
        end
    end

    bind_trigger(y3.game:event('键盘-按下', 'SPACE', act(function()
        local view = flow:get_view()
        if view.ok and view.value.screen == 'TITLE' then
            return flow:start()
        end
        if view.ok and view.value.screen == 'SLOTS' then
            return flow:confirm_enter()
        end
        return flow:get_view()
    end)))
    bind_trigger(y3.game:event('键盘-按下', 'ENTER', act(function()
        local view = flow:get_view()
        if view.ok and view.value.screen == 'TITLE' then
            return flow:start()
        end
        if view.ok and view.value.screen == 'SLOTS' then
            return flow:confirm_enter()
        end
        return flow:get_view()
    end)))
    bind_trigger(y3.game:event('键盘-按下', 'NUM_1', act(function()
        local view = flow:get_view()
        if not view.ok then
            return view
        end
        if view.value.screen == 'BACKEND' then
            return flow:select_backend('local_dev')
        end
        if view.value.screen == 'SLOTS' then
            return flow:select_slot(1)
        end
        return view
    end)))
    bind_trigger(y3.game:event('键盘-按下', 'NUM_2', act(function()
        local view = flow:get_view()
        if not view.ok then
            return view
        end
        if view.value.screen == 'BACKEND' then
            return flow:select_backend('official_cloud')
        end
        if view.value.screen == 'SLOTS' then
            return flow:select_slot(2)
        end
        return view
    end)))
    bind_trigger(y3.game:event('键盘-按下', 'NUM_3', act(function()
        local view = flow:get_view()
        if view.ok and view.value.screen == 'SLOTS' then
            return flow:select_slot(3)
        end
        return view
    end)))
    bind_trigger(y3.game:event('键盘-按下', 'N', act(function()
        local view = flow:get_view()
        if view.ok and view.value.screen == 'SLOTS' then
            return flow:create_slot()
        end
        return flow:get_view()
    end)))
    bind_trigger(y3.game:event('键盘-按下', 'D', act(function()
        local view = flow:get_view()
        if view.ok and view.value.screen == 'SLOTS' then
            return flow:delete_slot()
        end
        return flow:get_view()
    end)))
    bind_trigger(y3.game:event('键盘-按下', 'ESCAPE', act(function()
        return flow:back()
    end)))
end

function BootMenuShell.mount(options)
    options = options or {}
    if mounted then
        return true, 'already_mounted'
    end
    if type(y3) ~= 'table' or type(y3.game) ~= 'table' then
        return false, 'y3_not_available'
    end

    on_entered_cb = options.on_entered

    local bound = BootFlow.bind({
        platform_options = OfficialCloudGate.platform_options(),
    })
    if not bound.ok then
        shell_log('boot flow bind failed')
        return false, 'boot_bind_failed'
    end
    flow = bound.value

    local ok_ui, reason = CommonTip.bind()
    ui_ready = ok_ui == true
    if not ui_ready then
        local detail = ''
        if CommonTip.last_error then
            detail = tostring(CommonTip.last_error() or '')
        end
        shell_log(
            'CommonTip 绑定失败: '
                .. tostring(reason)
                .. ' '
                .. detail
                .. '（若刚启动，会由调度器在游戏初始化后重试）'
        )
    else
        shell_log('已绑定 CommonTip，对话框应出现在屏幕中间')
    end

    bind_keyboard_fallback()
    mounted = true
    present(flow:get_view())
    return true, ui_ready and 'mounted_ui' or 'mounted_keyboard_only'
end

function BootMenuShell.unmount()
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
    flow = nil
    on_entered_cb = nil
    mounted = false
end

function BootMenuShell.is_mounted()
    return mounted
end

return BootMenuShell
