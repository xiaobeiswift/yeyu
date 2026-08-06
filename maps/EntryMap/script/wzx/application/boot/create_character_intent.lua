-- Intent bridge data for EntryMap ↔ CreateCharacter (pure app; no engine refs).
-- Presentation/bootstrap performs level switch after write/read.

local Result = require 'wzx.domain.common.result'
local MapIds = require 'wzx.config.map_ids'
local BootIntentStore = require 'wzx.application.boot.boot_intent_store'
local LocalRunSlotStore = require 'wzx.application.boot.local_run_slot_store'

local CreateCharacterIntent = {}

local REASON_GO = 'GO_CREATE_CHARACTER'
local REASON_BACK = 'BACK_FROM_CREATE_CHARACTER'

-- Same-map session cache (CreateCharacter map after peek_go).
local SESSION = nil

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err('CREATE_CHARACTER_INTENT_INVALID', 'error.boot.create_intent_invalid', false, details)
end

local function snapshot_slots(store)
    local listed = store:list()
    if not listed.ok then
        return {}
    end
    local out = {}
    local i
    for i = 1, #listed.value do
        local s = listed.value[i]
        out[i] = {
            slot_index = s.slot_index,
            empty = s.empty,
            display_name = s.display_name,
            chapter_hint = s.chapter_hint,
            updated_label = s.updated_label,
            play_time_label = s.play_time_label,
            run_id = s.run_id,
            character_id = s.character_id,
        }
    end
    return out
end

local function restore_slots(snapshot)
    if type(snapshot) ~= 'table' then
        return
    end
    LocalRunSlotStore.reset_shared()
    local store = LocalRunSlotStore.shared()
    local i
    for i = 1, #snapshot do
        local s = snapshot[i]
        if type(s) == 'table' and s.empty == false then
            store:create(s.slot_index or i, {
                overwrite = true,
                display_name = s.display_name,
                chapter_hint = s.chapter_hint,
                updated_label = s.updated_label,
                play_time_label = s.play_time_label,
                run_id = s.run_id,
                character_id = s.character_id,
            })
        end
    end
end

---Prepare GO intent for empty slot. Caller switches level to CREATE_CHARACTER.
---@param slot_index number
---@return table Result { level_id, slot_index }
function CreateCharacterIntent.prepare_go(slot_index)
    if type(slot_index) ~= 'number'
        or slot_index < 1
        or slot_index > LocalRunSlotStore.slot_count()
        or slot_index ~= math.floor(slot_index)
    then
        return invalid('SLOT_INDEX_INVALID', { slot_index = slot_index })
    end
    local store = LocalRunSlotStore.shared()
    local got = store:get(slot_index)
    if not got.ok then
        return got
    end
    if got.value.empty ~= true then
        return invalid('SLOT_NOT_EMPTY', { slot_index = slot_index })
    end

    local intent = {
        reason = REASON_GO,
        slot_index = slot_index,
        slots_snapshot = snapshot_slots(store),
        map_from = MapIds.ENTRY,
        map_to = MapIds.CREATE_CHARACTER,
    }
    if not BootIntentStore.write(intent) then
        return invalid('INTENT_WRITE_FAILED')
    end
    return Result.ok({
        level_id = MapIds.CREATE_CHARACTER,
        slot_index = slot_index,
    })
end

---CreateCharacter map: load GO intent into session + restore slots.
---@return table|nil
function CreateCharacterIntent.peek_go()
    if type(SESSION) == 'table' then
        return SESSION
    end
    local intent = BootIntentStore.read_and_clear()
    if type(intent) == 'table' then
        SESSION = intent
        if type(intent.slots_snapshot) == 'table' then
            restore_slots(intent.slots_snapshot)
        end
        return SESSION
    end
    return nil
end

function CreateCharacterIntent.get_target_slot()
    if type(SESSION) == 'table' and type(SESSION.slot_index) == 'number' then
        return SESSION.slot_index
    end
    return 1
end

---Write BACK intent after create. Caller switches to ENTRY.
---@param character table
---@return table Result { level_id, slot_index }
function CreateCharacterIntent.prepare_complete(character)
    character = character or {}
    if type(character.display_name) ~= 'string' or character.display_name == '' then
        return invalid('DISPLAY_NAME_REQUIRED')
    end
    local slot_index = CreateCharacterIntent.get_target_slot()
    local store = LocalRunSlotStore.shared()
    local created = store:create(slot_index, {
        overwrite = true,
        display_name = character.display_name,
        chapter_hint = character.chapter_hint or '卷一 · 开局',
        updated_label = character.updated_label or '刚刚',
        play_time_label = character.play_time_label or '0 分',
        run_id = character.run_id,
        character_id = character.character_id,
    })
    if not created.ok then
        return created
    end

    local intent = {
        reason = REASON_BACK,
        slot_index = slot_index,
        slots_snapshot = snapshot_slots(store),
        selected_slot_index = slot_index,
        created_display_name = character.display_name,
        map_from = MapIds.CREATE_CHARACTER,
        map_to = MapIds.ENTRY,
    }
    if not BootIntentStore.write(intent) then
        return invalid('INTENT_WRITE_FAILED')
    end
    SESSION = nil
    return Result.ok({
        level_id = MapIds.ENTRY,
        slot_index = slot_index,
    })
end

---Write BACK intent after cancel. Caller switches to ENTRY.
---@return table Result { level_id }
function CreateCharacterIntent.prepare_cancel()
    local prior = SESSION
    local snapshot = prior and prior.slots_snapshot
        or snapshot_slots(LocalRunSlotStore.shared())
    local intent = {
        reason = REASON_BACK,
        slot_index = prior and prior.slot_index or 1,
        slots_snapshot = snapshot,
        selected_slot_index = prior and prior.slot_index or 1,
        cancelled = true,
        map_from = MapIds.CREATE_CHARACTER,
        map_to = MapIds.ENTRY,
    }
    if not BootIntentStore.write(intent) then
        return invalid('INTENT_WRITE_FAILED')
    end
    SESSION = nil
    return Result.ok({
        level_id = MapIds.ENTRY,
        cancelled = true,
    })
end

---EntryMap boot: apply BACK intent if present.
---@return table|nil
function CreateCharacterIntent.consume_return_on_entry()
    local intent = BootIntentStore.read_and_clear()
    if type(intent) ~= 'table' then
        return nil
    end
    if intent.reason == REASON_BACK then
        if type(intent.slots_snapshot) == 'table' then
            restore_slots(intent.slots_snapshot)
        end
        return intent
    end
    if intent.reason == REASON_GO and type(intent.slots_snapshot) == 'table' then
        restore_slots(intent.slots_snapshot)
    end
    return nil
end

CreateCharacterIntent.REASON_GO = REASON_GO
CreateCharacterIntent.REASON_BACK = REASON_BACK
CreateCharacterIntent.MapIds = MapIds

return CreateCharacterIntent
