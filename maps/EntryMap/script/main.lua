-- WZX engine entry. Gameplay systems are registered only after their contracts pass.

local is_debug = y3.game.is_debug_mode()

-- Never paint engine/WZX logs onto the game viewport.
-- y3's default print() still calls print_to_game in debug mode; override below.
y3.config.log.toGame = false
y3.config.log.toDialog = false

if is_debug then
    y3.config.log.level = 'debug'
else
    y3.config.log.level = 'info'
end

-- Keep console / Y3 Helper; skip viewport tips.
-- (Y3 debug print always paints the game window; project override ignores that path.)
do
    local consoleprint = rawget(_G, 'consoleprint')
    ---@diagnostic disable-next-line: lowercase-global
    function print(...)
        local n = select('#', ...)
        local parts = {}
        local i
        for i = 1, n do
            parts[i] = tostring(select(i, ...))
        end
        local message = table.concat(parts, '\t')
        if type(consoleprint) == 'function' then
            pcall(consoleprint, message)
        end
        pcall(function()
            if y3.develop and y3.develop.helper and y3.develop.helper.print then
                y3.develop.helper.print(message)
            end
        end)
    end
end

-- Hide engine performance overlay (延迟/帧数/Drawcall/...) when API exists.
pcall(function()
    if GameAPI and GameAPI.api_enable_profile then
        GameAPI.api_enable_profile(false)
    end
end)

-- Clear any tip text left from previous session / early prints.
pcall(function()
    if y3.ui and y3.ui.display_message and y3.player and y3.player.get_local then
        y3.ui.display_message(y3.player.get_local(), '', 0.01)
    end
end)

-- Re-assert after game init (some engines re-enable profile/debug HUD on start).
pcall(function()
    y3.game:event('游戏-初始化', function()
        pcall(function()
            if GameAPI and GameAPI.api_enable_profile then
                GameAPI.api_enable_profile(false)
            end
        end)
        pcall(function()
            if y3.ui and y3.ui.display_message and y3.player and y3.player.get_local then
                y3.ui.display_message(y3.player.get_local(), '', 0.01)
            end
        end)
    end)
end)

if is_debug then
    include 'wzx.bootstrap.dev_runtime'
else
    local runtime = require 'wzx.bootstrap.y3_runtime'
    local started = runtime.start()
    if started.ok then
        print('[WZX] Foundation V1 runtime ready; gameplay and unverified platform features are disabled')
    else
        print('[WZX] Runtime bootstrap failed: ' .. tostring(started.error.code))
    end
end
