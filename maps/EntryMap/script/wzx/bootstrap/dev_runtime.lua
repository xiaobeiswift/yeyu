local previous = rawget(_G, 'WZX_RUNTIME_HOST')
local ReloadGuard = require 'wzx.bootstrap.reload_guard'
local stopped = ReloadGuard.stop_previous(previous)
if not stopped.ok then
    print('[WZX] reload blocked: previous development runtime is still authoritative')
    return
end
rawset(_G, 'WZX_RUNTIME_HOST', nil)

package.loaded['wzx.bootstrap.reload_manifest'] = nil
local reload_modules = require 'wzx.bootstrap.reload_manifest'
local module_index
for module_index = 1, #reload_modules do
    package.loaded[reload_modules[module_index]] = nil
end
package.loaded['wzx.bootstrap.reload_manifest'] = nil

local Y3Runtime = require 'wzx.bootstrap.y3_runtime'
local generation = (rawget(_G, 'WZX_RUNTIME_GENERATION') or 0) + 1
local started = Y3Runtime.start({ generation = generation })
if not started.ok then
    print('[WZX] Foundation V1 development runtime failed: ' .. tostring(started.error.code))
    return
end

rawset(_G, 'WZX_RUNTIME_GENERATION', generation)
rawset(_G, 'WZX_RUNTIME_HOST', started.value)
print('[WZX] Foundation V1 development runtime ready; platform features remain disabled')

local clear_list = {
    'wzx.presentation.y3.ui_mount_scheduler',
    'wzx.presentation.y3.common_tip_panel',
    'wzx.presentation.y3.runtime_ui_kit',
    'wzx.presentation.y3.boot_menu_shell',
    'wzx.presentation.y3.greybox_dialogue_shell',
    'wzx.presentation.greybox.dialogue_player',
    'wzx.presentation.greybox.dialogue_text_table',
    'wzx.application.boot.boot_flow',
    'wzx.application.boot.local_run_slot_store',
    'wzx.application.boot.platform_backend_status',
    'wzx.adapters.y3.official_cloud_gate',
    'wzx.config.content.dialogue.chapter_01',
    'wzx.config.content.dialogue.chapter_01_m02_zh',
    'wzx.config.content.dialogue.chapter_01_m05_zh',
    'wzx.config.content.dialogue.chapter_01_m07_zh',
    'wzx.config.content.dialogue.chapter_01_m08_zh',
}
for module_index = 1, #clear_list do
    package.loaded[clear_list[module_index]] = nil
end

pcall(function()
    local tip = require 'wzx.presentation.y3.common_tip_panel'
    if tip.reset then
        tip.reset()
    end
end)

local dialogue_mounted = false

local function mount_dialogue_after_enter(payload)
    if dialogue_mounted then
        return true, 'already'
    end
    local shell = require 'wzx.presentation.y3.greybox_dialogue_shell'
    if shell.is_mounted and shell.is_mounted() then
        shell.unmount()
    end
    local ok_mount, mode = shell.mount()
    if not ok_mount then
        return false, tostring(mode)
    end
    local CommonTip = require 'wzx.presentation.y3.common_tip_panel'
    if not CommonTip.is_bound or not CommonTip.is_bound() then
        return false, 'dialogue_common_tip_not_bound:' .. tostring(mode)
    end
    dialogue_mounted = true
    print('[WZX] Entered run; dialogue UI ready')
    if payload then
        print(
            '[WZX] Run slot='
                .. tostring(payload.slot_index)
                .. ' name='
                .. tostring(payload.display_name)
        )
    end
    return true, mode
end

local function mount_boot_ui()
    local CommonTip = require 'wzx.presentation.y3.common_tip_panel'
    local ok_bind, bind_reason = CommonTip.bind()
    if not ok_bind then
        return false, 'bind:' .. tostring(bind_reason)
    end

    local boot = require 'wzx.presentation.y3.boot_menu_shell'
    if boot.is_mounted and boot.is_mounted() then
        boot.unmount()
    end
    local ok_mount, mode = boot.mount({
        on_entered = function(payload)
            pcall(function()
                local b = require 'wzx.presentation.y3.boot_menu_shell'
                if b.is_mounted and b.is_mounted() then
                    b.unmount()
                end
            end)
            local Scheduler = require 'wzx.presentation.y3.ui_mount_scheduler'
            Scheduler.reset('dialogue')
            Scheduler.schedule('dialogue', function()
                return mount_dialogue_after_enter(payload)
            end)
        end,
    })
    if not ok_mount then
        return false, 'boot_mount:' .. tostring(mode)
    end
    if not CommonTip.is_bound() then
        return false, 'boot_mounted_but_tip_unbound:' .. tostring(mode)
    end
    print('[WZX] Boot UI ready — 选本地档进入')
    return true, mode
end

local Scheduler = require 'wzx.presentation.y3.ui_mount_scheduler'
Scheduler.reset()
print('[WZX] 链路：开局菜单 → 对话')
Scheduler.schedule('boot', mount_boot_ui)
