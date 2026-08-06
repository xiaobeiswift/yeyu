-- Active local-dev run after character select.
-- Lightweight: not cloud SaveStore / CreateNewSave. Holds session snapshot for HUD
-- and future hydrate wiring.

local Result = require 'wzx.domain.common.result'

local LocalRunSession = {}

local active = nil

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err('LOCAL_RUN_SESSION_INVALID', 'error.boot.session_invalid', false, details)
end

local function copy_session(session)
    if session == nil then
        return nil
    end
    return {
        backend_id = session.backend_id,
        slot_index = session.slot_index,
        run_id = session.run_id,
        display_name = session.display_name,
        chapter_hint = session.chapter_hint,
        phase = session.phase,
        started = session.started,
    }
end

---Start a run from BootFlow entered_payload.
---@param payload table
---@return table Result
function LocalRunSession.start(payload)
    if type(payload) ~= 'table' then
        return invalid('PAYLOAD_REQUIRED')
    end
    if payload.backend_id ~= nil and payload.backend_id ~= 'local_dev' then
        return invalid('BACKEND_NOT_LOCAL', { backend_id = payload.backend_id })
    end
    local slot_index = payload.slot_index
    if type(slot_index) ~= 'number'
        or slot_index < 1
        or slot_index > 5
        or slot_index ~= math.floor(slot_index)
    then
        return invalid('SLOT_INDEX_INVALID', { slot_index = slot_index })
    end
    local run_id = payload.run_id
    if type(run_id) ~= 'string' or run_id == '' then
        run_id = 'run_local_' .. tostring(slot_index)
    end
    local display_name = payload.display_name
    if type(display_name) ~= 'string' or display_name == '' then
        display_name = '槽 ' .. tostring(slot_index)
    end

    active = {
        backend_id = 'local_dev',
        slot_index = slot_index,
        run_id = run_id,
        display_name = display_name,
        chapter_hint = payload.chapter_hint,
        phase = 'EXPLORING',
        started = true,
    }
    return Result.ok(copy_session(active))
end

function LocalRunSession.stop()
    active = nil
    return Result.ok(true)
end

function LocalRunSession.is_active()
    return active ~= nil and active.started == true
end

function LocalRunSession.get()
    if active == nil then
        return invalid('NO_ACTIVE_SESSION')
    end
    return Result.ok(copy_session(active))
end

---HUD-friendly view model.
function LocalRunSession.get_view()
    if active == nil then
        return Result.ok({
            active = false,
            title = '雾州侠行',
            subtitle = '未进入存档',
            tip = '请先选择角色',
        })
    end
    local chapter = active.chapter_hint
    if type(chapter) ~= 'string' or chapter == '' then
        chapter = '卷一 · 探索'
    end
    return Result.ok({
        active = true,
        title = active.display_name,
        subtitle = '位 '
            .. tostring(active.slot_index)
            .. ' · '
            .. tostring(active.run_id),
        chapter = chapter,
        phase = active.phase,
        tip = '探索 · 开发中（地图可操作）',
        slot_index = active.slot_index,
        run_id = active.run_id,
        display_name = active.display_name,
        backend_id = active.backend_id,
    })
end

return LocalRunSession
