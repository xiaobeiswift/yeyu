-- Development entry: foundation host only. No greybox UI auto-mount.
-- Presentation shells (boot/dialogue) stay in repo for later rebuild; they are not started here.

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
print('[WZX] Foundation V1 development runtime ready; clean UI slate (no auto greybox)')

-- Drop any previously loaded presentation modules so hot-reload cannot re-show old panels.
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
}
for module_index = 1, #clear_list do
    package.loaded[clear_list[module_index]] = nil
end

local function sanitize_now()
    pcall(function()
        local Kit = require 'wzx.presentation.y3.runtime_ui_kit'
        if Kit.sanitize_startup_ui then
            Kit.sanitize_startup_ui()
        end
    end)
end

sanitize_now()
pcall(function()
    y3.game:event('游戏-初始化', function()
        sanitize_now()
        print('[WZX] clean slate: all preset boards hidden, no CommonTip / boot / dialogue UI')
    end)
end)
