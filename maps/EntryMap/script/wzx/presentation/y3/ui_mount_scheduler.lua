-- Defer presentation mounts until Y3 UI is available (after 游戏-初始化).
-- Hot reload: immediate + timer retries, because 游戏-初始化 will not fire again.

local UIMountScheduler = {}

local jobs = {}

local function log(msg)
    print('[WZX][UI调度] ' .. tostring(msg))
end

---Schedule a mount job that retries until success or attempts exhausted.
---@param name string
---@param try_fn fun(): boolean, string  -- returns ok, detail
function UIMountScheduler.schedule(name, try_fn)
    if type(name) ~= 'string' or type(try_fn) ~= 'function' then
        return
    end
    if jobs[name] and jobs[name].done then
        -- allow re-schedule after reset
    end
    jobs[name] = {
        done = false,
        attempts = 0,
        max_attempts = 12,
    }

    local function attempt(reason)
        local job = jobs[name]
        if job == nil or job.done then
            return
        end
        job.attempts = job.attempts + 1
        local ok, detail = false, 'error'
        local ran, a, b = pcall(try_fn)
        if not ran then
            detail = tostring(a)
            ok = false
        else
            ok = a == true
            detail = tostring(b or '')
        end
        if ok then
            job.done = true
            log(name .. ' 成功 (' .. tostring(reason) .. ') ' .. detail)
            return
        end
        log(
            name
                .. ' 第'
                .. tostring(job.attempts)
                .. '次失败 ('
                .. tostring(reason)
                .. '): '
                .. detail
        )
        if job.attempts >= job.max_attempts then
            log(name .. ' 放弃：UI 仍不可用')
        end
    end

    -- 1) immediate (works on hot-reload after init)
    attempt('immediate')

    -- 2) game init (works on cold start)
    pcall(function()
        y3.game:event('游戏-初始化', function()
            attempt('游戏-初始化')
        end)
    end)

    -- 3) timed retries (UI sometimes ready a few frames later)
    pcall(function()
        if y3.ltimer and y3.ltimer.wait then
            local delays = { 0.1, 0.3, 0.6, 1.0, 1.5, 2.0, 3.0 }
            local i
            for i = 1, #delays do
                local d = delays[i]
                y3.ltimer.wait(d, function()
                    attempt('timer-' .. tostring(d))
                end)
            end
        elseif y3.timer and y3.timer.wait then
            y3.timer.wait(1, function()
                attempt('timer-1')
            end)
        end
    end)
end

function UIMountScheduler.is_done(name)
    return jobs[name] and jobs[name].done == true
end

function UIMountScheduler.reset(name)
    if name then
        jobs[name] = nil
    else
        jobs = {}
    end
end

return UIMountScheduler
