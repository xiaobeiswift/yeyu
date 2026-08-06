-- Presentation boundary: switch_level + intent glue (may touch y3.*).

local LevelSwitch = {}

local switching = false

local function info(msg)
    print('[WZX][Level] ' .. tostring(msg))
end

local function warn(msg)
    print('[WZX][Level] WARN ' .. tostring(msg))
end

---@param level_id string UUID string required by engine convert_level_id
---@return boolean
function LevelSwitch.to(level_id)
    if type(level_id) ~= 'string' or level_id == '' then
        return false
    end
    -- Decimal header.map ids look like long digit strings and crash convert_level_id.
    if level_id:match('^%d+$') then
        warn('refusing decimal level id (need UUID): ' .. level_id)
        return false
    end
    if type(y3) ~= 'table' or type(y3.game) ~= 'table' or type(y3.game.switch_level) ~= 'function' then
        return false
    end
    if switching then
        warn('switch already in flight')
        return false
    end
    switching = true
    -- Prefer GameAPI with skip_loading_ui: default LoadingPanel uses modern stock art (e.g. 106407).
    local ok, err = pcall(function()
        if GameAPI and GameAPI.request_switch_level then
            -- (level_id, load_same_world?, skip_loading_ui?)
            GameAPI.request_switch_level(level_id, false, true)
        else
            y3.game.switch_level(level_id)
        end
    end)
    if ok then
        info('switch_level → ' .. level_id .. ' (skip_loading_ui)')
    else
        switching = false
        warn('switch_level error: ' .. tostring(err))
    end
    return ok == true
end

---save_slot「新建」: prepare GO intent then switch.
---@param slot_index number
---@return boolean ok
---@return string detail
function LevelSwitch.go_create_character(slot_index)
    if switching then
        return false, 'SWITCH_IN_FLIGHT'
    end
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
