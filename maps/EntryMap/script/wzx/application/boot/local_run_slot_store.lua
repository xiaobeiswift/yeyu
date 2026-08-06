-- Lightweight local run slots for boot UI (5 character slots).
-- Not the cloud SaveStore envelope path; only feeds BootFlow / save_slot shell.

local Result = require 'wzx.domain.common.result'

local LocalRunSlotStore = {}
local STATES = setmetatable({}, { __mode = 'k' })

local SLOT_COUNT = 5

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err('BOOT_SLOT_INVALID', 'error.boot.slot_invalid', false, details)
end

local function empty_slot(index)
    return {
        slot_index = index,
        empty = true,
        display_name = '空槽 ' .. tostring(index),
        chapter_hint = nil,
        updated_label = nil,
        play_time_label = nil,
    }
end

function LocalRunSlotStore.new()
    local store = {}
    setmetatable(store, { __index = LocalRunSlotStore })
    local slots = {}
    local index
    for index = 1, SLOT_COUNT do
        slots[index] = empty_slot(index)
    end
    STATES[store] = { slots = slots }
    return store
end

function LocalRunSlotStore.slot_count()
    return SLOT_COUNT
end

function LocalRunSlotStore:list()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_REQUIRED')
    end
    local listed = {}
    local index
    for index = 1, SLOT_COUNT do
        local s = state.slots[index]
        listed[index] = {
            slot_index = s.slot_index,
            empty = s.empty,
            display_name = s.display_name,
            chapter_hint = s.chapter_hint,
            updated_label = s.updated_label,
            play_time_label = s.play_time_label,
        }
    end
    return Result.ok(listed)
end

function LocalRunSlotStore:create(slot_index, options)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_REQUIRED')
    end
    if type(slot_index) ~= 'number'
        or slot_index < 1
        or slot_index > SLOT_COUNT
        or slot_index ~= math.floor(slot_index)
    then
        return invalid('SLOT_INDEX_INVALID', { slot_index = slot_index })
    end
    options = options or {}
    if state.slots[slot_index].empty ~= true and options.overwrite ~= true then
        return invalid('SLOT_OCCUPIED', { slot_index = slot_index })
    end
    state.slots[slot_index] = {
        slot_index = slot_index,
        empty = false,
        display_name = options.display_name or ('雾津行 · 槽' .. tostring(slot_index)),
        chapter_hint = options.chapter_hint or '卷一 · 开局',
        updated_label = options.updated_label or '刚刚',
        play_time_label = options.play_time_label or '0 分',
        run_id = options.run_id or ('run_local_' .. tostring(slot_index)),
    }
    return Result.ok(state.slots[slot_index])
end

function LocalRunSlotStore:get(slot_index)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_REQUIRED')
    end
    if type(slot_index) ~= 'number' or slot_index < 1 or slot_index > SLOT_COUNT then
        return invalid('SLOT_INDEX_INVALID', { slot_index = slot_index })
    end
    return Result.ok(state.slots[slot_index])
end

function LocalRunSlotStore:clear(slot_index)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_REQUIRED')
    end
    if type(slot_index) ~= 'number' or slot_index < 1 or slot_index > SLOT_COUNT then
        return invalid('SLOT_INDEX_INVALID', { slot_index = slot_index })
    end
    state.slots[slot_index] = empty_slot(slot_index)
    return Result.ok(state.slots[slot_index])
end

return LocalRunSlotStore
