-- Debug hot-reload entry only. Real game boot is wzx.bootstrap.game_entry.

local previous = rawget(_G, 'WZX_RUNTIME_HOST')
local ReloadGuard = require 'wzx.bootstrap.reload_guard'
local stopped = ReloadGuard.stop_previous(previous)
if not stopped.ok then
    print('[WZX] reload blocked: previous runtime is still authoritative')
    return
end
rawset(_G, 'WZX_RUNTIME_HOST', nil)

-- Bust reloadable modules so include() picks up latest sources.
package.loaded['wzx.bootstrap.reload_manifest'] = nil
local reload_modules = require 'wzx.bootstrap.reload_manifest'
local module_index
for module_index = 1, #reload_modules do
    package.loaded[reload_modules[module_index]] = nil
end
package.loaded['wzx.bootstrap.reload_manifest'] = nil

local clear_list = {
    'wzx.bootstrap.game_entry',
    'wzx.presentation.y3.ui_mount_scheduler',
    'wzx.presentation.y3.common_tip_panel',
    'wzx.presentation.y3.runtime_ui_kit',
    'wzx.presentation.y3.loading_shell',
    'wzx.presentation.y3.loading_frame_ids',
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

local generation = (rawget(_G, 'WZX_RUNTIME_GENERATION') or 0) + 1
local GameEntry = require 'wzx.bootstrap.game_entry'
local ok, detail = GameEntry.start({ generation = generation })
if not ok then
    print('[WZX] game entry failed: ' .. tostring(detail))
end
