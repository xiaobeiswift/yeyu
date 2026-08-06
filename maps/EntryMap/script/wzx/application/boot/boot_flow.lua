-- Title / backend / slot boot flow for UI shells.
-- Official cloud uses the same screens; availability comes from PlatformBackendStatus.

local Result = require 'wzx.domain.common.result'
local PlatformBackendStatus = require 'wzx.application.boot.platform_backend_status'
local LocalRunSlotStore = require 'wzx.application.boot.local_run_slot_store'

local BootFlow = {}
local STATES = setmetatable({}, { __mode = 'k' })

local SCREEN = {
    TITLE = 'TITLE',
    BACKEND = 'BACKEND',
    SLOTS = 'SLOTS',
    OFFICIAL_BLOCKED = 'OFFICIAL_BLOCKED',
    ENTERED = 'ENTERED',
}

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err('BOOT_FLOW_INVALID', 'error.boot.flow_invalid', false, details)
end

local function build_view(state)
    local backends = PlatformBackendStatus.list_backends(state.platform_options)
    local view = {
        screen = state.screen,
        title = '雾州侠行',
        subtitle = '开局',
        backends = backends,
        selected_backend_id = state.selected_backend_id,
        selected_slot_index = state.selected_slot_index,
        slots = {},
        active_backend = nil,
        message = state.message,
        hint = state.hint,
        entered = state.screen == SCREEN.ENTERED,
        entered_payload = state.entered_payload,
    }

    local index
    for index = 1, #backends do
        if backends[index].backend_id == state.selected_backend_id then
            view.active_backend = backends[index]
            break
        end
    end

    if state.screen == SCREEN.SLOTS and state.local_slots ~= nil then
        local listed = state.local_slots:list()
        if listed.ok then
            view.slots = listed.value
        end
    end

    if state.screen == SCREEN.TITLE then
        view.hint = '点击「开始游戏」'
    elseif state.screen == SCREEN.BACKEND then
        view.hint = '点击本地档进入；官方云档当前锁定'
    elseif state.screen == SCREEN.SLOTS then
        view.hint = '点选角色位 · 空位可新建 · 有档可进入'
    elseif state.screen == SCREEN.OFFICIAL_BLOCKED then
        view.hint = '官方云档未验证 · 点返回'
    elseif state.screen == SCREEN.ENTERED then
        view.hint = '已进入 · 对话界面可点'
    end

    return view
end

function BootFlow.bind(options)
    options = options or {}
    if type(options) ~= 'table' then
        return invalid('OPTIONS_REQUIRED')
    end
    local flow = {}
    local local_slots = options.local_slots or LocalRunSlotStore.new()
    STATES[flow] = {
        screen = SCREEN.TITLE,
        selected_backend_id = nil,
        selected_slot_index = 1,
        local_slots = local_slots,
        platform_options = options.platform_options or {
            feature_flags = { cloud_save = false },
            platform_adapters_verified = false,
            validation_status = 'UNVERIFIED',
        },
        message = nil,
        hint = nil,
        entered_payload = nil,
    }
    setmetatable(flow, { __index = BootFlow })
    return Result.ok(flow)
end

function BootFlow:get_view()
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    return Result.ok(build_view(state))
end

function BootFlow:go_title()
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    state.screen = SCREEN.TITLE
    state.message = nil
    state.entered_payload = nil
    return self:get_view()
end

function BootFlow:start()
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    state.screen = SCREEN.BACKEND
    state.message = nil
    return self:get_view()
end

---Skip title/backend and open the local character-select slots screen.
---Used by save_slot shell after Loading (UI has no backend tabs).
function BootFlow:open_local_slots()
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    state.selected_backend_id = 'local_dev'
    state.screen = SCREEN.SLOTS
    state.selected_slot_index = 1
    state.message = nil
    state.entered_payload = nil
    return self:get_view()
end

function BootFlow:select_backend(backend_id)
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    if backend_id == 'local_dev' then
        state.selected_backend_id = 'local_dev'
        state.screen = SCREEN.SLOTS
        state.selected_slot_index = 1
        state.message = nil
        return self:get_view()
    end
    if backend_id == 'official_cloud' then
        state.selected_backend_id = 'official_cloud'
        local status = PlatformBackendStatus.official_cloud(state.platform_options)
        if status.available then
            -- Future: list cloud slots via SaveStore
            state.screen = SCREEN.SLOTS
            state.message = '官方云档可用（待接槽位列表）'
            return self:get_view()
        end
        state.screen = SCREEN.OFFICIAL_BLOCKED
        state.message = status.banner
            .. '\n原因：'
            .. tostring(status.blocked_reason)
            .. '\n下一步：'
            .. tostring(status.next_step)
        return self:get_view()
    end
    return invalid('BACKEND_UNKNOWN', { backend_id = backend_id })
end

function BootFlow:select_slot(slot_index)
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    if state.screen ~= SCREEN.SLOTS then
        return invalid('NOT_ON_SLOTS')
    end
    if type(slot_index) ~= 'number'
        or slot_index < 1
        or slot_index > LocalRunSlotStore.slot_count()
    then
        return invalid('SLOT_INDEX_INVALID', { slot_index = slot_index })
    end
    state.selected_slot_index = slot_index
    state.message = '已选角色位 ' .. tostring(slot_index)
    return self:get_view()
end

function BootFlow:create_slot(slot_index)
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    if state.screen ~= SCREEN.SLOTS or state.selected_backend_id ~= 'local_dev' then
        return invalid('CREATE_LOCAL_ONLY')
    end
    slot_index = slot_index or state.selected_slot_index
    local created = state.local_slots:create(slot_index, { overwrite = true })
    if not created.ok then
        return created
    end
    state.selected_slot_index = slot_index
    state.message = '已新建：' .. created.value.display_name
    return self:get_view()
end

function BootFlow:delete_slot(slot_index)
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    if state.screen ~= SCREEN.SLOTS or state.selected_backend_id ~= 'local_dev' then
        return invalid('DELETE_LOCAL_ONLY')
    end
    slot_index = slot_index or state.selected_slot_index
    local cleared = state.local_slots:clear(slot_index)
    if not cleared.ok then
        return cleared
    end
    state.message = '已清空角色位 ' .. tostring(slot_index)
    return self:get_view()
end

function BootFlow:confirm_enter()
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    if state.screen ~= SCREEN.SLOTS then
        return invalid('NOT_ON_SLOTS')
    end
    if state.selected_backend_id ~= 'local_dev' then
        return invalid('ENTER_BACKEND_BLOCKED')
    end
    local slot = state.local_slots:get(state.selected_slot_index)
    if not slot.ok then
        return slot
    end
    if slot.value.empty then
        state.message = '空位不能进入。先点「新建」。'
        return self:get_view()
    end
    state.screen = SCREEN.ENTERED
    state.entered_payload = {
        backend_id = 'local_dev',
        slot_index = slot.value.slot_index,
        run_id = slot.value.run_id,
        display_name = slot.value.display_name,
        chapter_hint = slot.value.chapter_hint,
    }
    state.message = '进入：' .. slot.value.display_name
    return self:get_view()
end

function BootFlow:back()
    local state = STATES[self]
    if state == nil then
        return invalid('FLOW_REQUIRED')
    end
    if state.screen == SCREEN.BACKEND or state.screen == SCREEN.OFFICIAL_BLOCKED then
        state.screen = SCREEN.TITLE
        state.message = nil
    elseif state.screen == SCREEN.SLOTS then
        state.screen = SCREEN.BACKEND
        state.message = nil
    elseif state.screen == SCREEN.ENTERED then
        state.screen = SCREEN.SLOTS
        state.entered_payload = nil
        state.message = '已返回角色选择'
    end
    return self:get_view()
end

function BootFlow.format_screen(view)
    if view == nil then
        return ''
    end
    local lines = {
        '======== ' .. (view.title or '雾州侠行') .. ' ========',
    }
    if view.screen == 'TITLE' then
        lines[#lines + 1] = '开局菜单（UI 已按官方/本地双后端设计）'
        lines[#lines + 1] = view.hint or ''
    elseif view.screen == 'BACKEND' then
        lines[#lines + 1] = '选择存档后端：'
        local index
        for index = 1, #view.backends do
            local b = view.backends[index]
            local mark = b.available and '[可进]' or '[锁定]'
            lines[#lines + 1] = tostring(index)
                .. '. '
                .. b.display_name
                .. ' '
                .. mark
                .. ' · '
                .. (b.banner or '')
        end
        lines[#lines + 1] = view.hint or ''
    elseif view.screen == 'OFFICIAL_BLOCKED' then
        lines[#lines + 1] = '【官方云档】'
        lines[#lines + 1] = view.message or ''
        lines[#lines + 1] = view.hint or ''
    elseif view.screen == 'SLOTS' then
        lines[#lines + 1] = '存档槽（'
            .. tostring(view.selected_backend_id)
            .. '）'
        local index
        for index = 1, #view.slots do
            local s = view.slots[index]
            local cursor = (s.slot_index == view.selected_slot_index) and '>' or ' '
            local body
            if s.empty then
                body = '（空）'
            else
                body = s.display_name
                    .. ' | '
                    .. tostring(s.chapter_hint or '')
                    .. ' | '
                    .. tostring(s.updated_label or '')
            end
            lines[#lines + 1] = cursor .. ' 槽' .. tostring(s.slot_index) .. ' ' .. body
        end
        if view.message then
            lines[#lines + 1] = view.message
        end
        lines[#lines + 1] = view.hint or ''
    elseif view.screen == 'ENTERED' then
        lines[#lines + 1] = view.message or '已进入'
        lines[#lines + 1] = view.hint or ''
    end
    return table.concat(lines, '\n')
end

BootFlow.SCREEN = SCREEN

return BootFlow
