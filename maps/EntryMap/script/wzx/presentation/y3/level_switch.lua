-- Presentation boundary: switch_level + intent glue (may touch y3.*).

local LevelSwitch = {}

local function info(msg)
    print('[WZX][Level] ' .. tostring(msg))
end

---@param level_id string
---@return boolean
function LevelSwitch.to(level_id)
    if type(level_id) ~= 'string' or level_id == '' then
        return false
    end
    if type(y3) ~= 'table' or type(y3.game) ~= 'table' or type(y3.game.switch_level) ~= 'function' then
        return false
    end
    local ok = pcall(function()
        y3.game.switch_level(level_id)
    end)
    if ok then
        info('switch_level → ' .. level_id)
    end
    return ok == true
end

---save_slot「新建」: prepare GO intent then switch.
---@param slot_index number
---@return boolean ok
---@return string detail
function LevelSwitch.go_create_character(slot_index)
    local CreateCharacterIntent =
        require 'wzx.application.boot.create_character_intent'
    local prepared = CreateCharacterIntent.prepare_go(slot_index)
    if not prepared.ok then
        local reason = 'prepare_failed'
        if prepared.error
            and prepared.error.details
            and prepared.error.details.reason
        then
            reason = tostring(prepared.error.details.reason)
        end
        return false, reason
    end
    if not LevelSwitch.to(prepared.value.level_id) then
        return false, 'SWITCH_LEVEL_FAILED'
    end
    return true, 'switched'
end

---CreateCharacter complete → EntryMap.
---@param character table
---@return boolean ok
---@return string detail
function LevelSwitch.complete_create_character(character)
    local CreateCharacterIntent =
        require 'wzx.application.boot.create_character_intent'
    local prepared = CreateCharacterIntent.prepare_complete(character)
    if not prepared.ok then
        local reason = 'prepare_failed'
        if prepared.error
            and prepared.error.details
            and prepared.error.details.reason
        then
            reason = tostring(prepared.error.details.reason)
        end
        return false, reason
    end
    if not LevelSwitch.to(prepared.value.level_id) then
        return false, 'SWITCH_LEVEL_FAILED'
    end
    return true, 'returned'
end

---CreateCharacter cancel → EntryMap.
---@return boolean ok
---@return string detail
function LevelSwitch.cancel_create_character()
    local CreateCharacterIntent =
        require 'wzx.application.boot.create_character_intent'
    local prepared = CreateCharacterIntent.prepare_cancel()
    if not prepared.ok then
        return false, 'prepare_failed'
    end
    if not LevelSwitch.to(prepared.value.level_id) then
        return false, 'SWITCH_LEVEL_FAILED'
    end
    return true, 'cancelled'
end

return LevelSwitch
