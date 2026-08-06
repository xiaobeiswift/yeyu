-- Game entry: Loading must start only after 游戏-初始化.
-- create_child UI made before init is wiped by the engine (looks like a one-frame flash).

local GameEntry = {}
local game_inited = false
local session_started = false
local starting_lock = false

local function info(msg)
    local text = '[WZX] ' .. tostring(msg)
    pcall(function()
        if log and log.info then
            log.info(text)
        end
    end)
    print(text)
end

local function warn(msg)
    local text = '[WZX] ' .. tostring(msg)
    pcall(function()
        if log and log.warn then
            log.warn(text)
        elseif log and log.info then
            log.info(text)
        end
    end)
    print(text)
end

local function start_loading_once(reason)
    local LoadingShell = require 'wzx.presentation.y3.loading_shell'

    if starting_lock then
        return true, 'starting_lock'
    end
    if session_started then
        return true, 'session_started'
    end
    if LoadingShell.is_boot_running and LoadingShell.is_boot_running() then
        session_started = true
        return true, 'already_running'
    end
    if LoadingShell.is_boot_finished and LoadingShell.is_boot_finished() then
        session_started = true
        return true, 'already_finished'
    end

    if not game_inited then
        return false, 'wait_game_init'
    end

    starting_lock = true

    local Kit = require 'wzx.presentation.y3.runtime_ui_kit'
    Kit.sanitize_startup_ui()

    -- Remount only if needed; avoid unmount/remount flash when already good.
    if LoadingShell.is_mounted and LoadingShell.is_mounted() then
        pcall(function()
            LoadingShell.unmount()
        end)
    end

    local ok, detail = LoadingShell.mount()
    if not ok then
        starting_lock = false
        warn('mount failed (' .. tostring(reason) .. '): ' .. tostring(detail))
        return false, detail
    end

    LoadingShell.on_finished(function()
        info('loading 100% — cover remains until next screen')
    end)

    local run_ok, run_detail = LoadingShell.run_boot_progress({
        duration = 6.0,
        hold = 1.5,
    })
    if not run_ok then
        starting_lock = false
        warn('progress failed: ' .. tostring(run_detail))
        return false, run_detail
    end

    session_started = true
    starting_lock = false
    info('loading started via ' .. tostring(reason) .. ' / ' .. tostring(run_detail))
    return true, run_detail or 'ok'
end

---@param options? { generation?: integer, skip_loading?: boolean }
function GameEntry.start(options)
    options = options or {}
    local Y3Runtime = require 'wzx.bootstrap.y3_runtime'
    local generation = options.generation
        or ((rawget(_G, 'WZX_RUNTIME_GENERATION') or 0) + 1)

    local started = Y3Runtime.start({ generation = generation })
    if not started.ok then
        warn('runtime start failed')
        return false, 'runtime_failed'
    end

    rawset(_G, 'WZX_RUNTIME_GENERATION', generation)
    rawset(_G, 'WZX_RUNTIME_HOST', started.value)
    info('runtime ready generation=' .. tostring(generation))

    if options.skip_loading then
        return true, 'runtime_only'
    end

    session_started = false
    game_inited = false
    starting_lock = false

    -- Real mount ONLY after 游戏-初始化 (pre-init create_child is wiped → one-frame flash).
    pcall(function()
        y3.game:event('游戏-初始化', function()
            game_inited = true
            info('游戏-初始化 → start loading')
            -- One short delay so engine finishes UI tree rebuild after the event.
            if y3.ltimer and y3.ltimer.wait then
                y3.ltimer.wait(0.05, function()
                    start_loading_once('游戏-初始化+0.05')
                end)
            else
                start_loading_once('游戏-初始化')
            end
        end)
    end)

    -- Fallback if init event already fired (hot reload) or was missed.
    pcall(function()
        if y3.ltimer and y3.ltimer.wait then
            y3.ltimer.wait(0.5, function()
                if session_started then
                    return
                end
                game_inited = true
                start_loading_once('fallback-0.5')
            end)
            y3.ltimer.wait(1.2, function()
                if session_started then
                    return
                end
                game_inited = true
                start_loading_once('fallback-1.2')
            end)
        end
    end)

    return true, 'started'
end

function GameEntry.mount_loading()
    if not game_inited then
        game_inited = true
    end
    return start_loading_once('mount_loading')
end

return GameEntry
