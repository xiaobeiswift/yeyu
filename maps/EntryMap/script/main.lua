-- WZX engine entry. Gameplay systems are registered only after their contracts pass.

local is_debug = y3.game.is_debug_mode()
-- Never paint engine/WZX logs onto the game viewport.
-- Debug still goes to console / lua_player01.log via print + file logger.
y3.config.log.toGame = false
if is_debug then
    y3.config.log.level = 'debug'
else
    y3.config.log.level = 'info'
end
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
