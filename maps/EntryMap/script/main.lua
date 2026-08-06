-- WZX engine entry. Same boot path for debug and release.

local is_debug = y3.game.is_debug_mode()

-- Never paint engine/WZX logs onto the game viewport.
y3.config.log.toGame = false
y3.config.log.toDialog = false

if is_debug then
    y3.config.log.level = 'debug'
else
    y3.config.log.level = 'info'
end

-- Console / Y3 Helper only; no on-screen print spam.
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
        -- Also mirror into engine log so we can diagnose boot without console.
        pcall(function()
            if log and log.info then
                log.info(message)
            end
        end)
    end
end

-- Hide engine performance overlay when API exists.
pcall(function()
    if GameAPI and GameAPI.api_enable_profile then
        GameAPI.api_enable_profile(false)
    end
end)

-- Note: do NOT clear display_message on 游戏-初始化 — Loading uses it for on-screen status.

pcall(function()
    y3.game:event('游戏-初始化', function()
        pcall(function()
            if GameAPI and GameAPI.api_enable_profile then
                GameAPI.api_enable_profile(false)
            end
        end)
    end)
end)

-- Official game boot (Loading first screen). Debug uses include for hot reload.
if is_debug then
    include 'wzx.bootstrap.dev_runtime'
else
    local GameEntry = require 'wzx.bootstrap.game_entry'
    local ok, detail = GameEntry.start()
    if not ok then
        print('[WZX] game entry failed: ' .. tostring(detail))
    end
end
