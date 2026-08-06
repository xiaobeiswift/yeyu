-- Boot for maps/CreateCharacter: stage map for 立档 (unit showcase later).
-- Shared wzx lives under EntryMap/script; CreateCharacter main prepends that path.

local CreateCharacterEntry = {}

local function info(msg)
    local text = '[WZX][立档图] ' .. tostring(msg)
    pcall(function()
        if log and log.info then
            log.info(text)
        end
    end)
    print(text)
end

local function warn(msg)
    local text = '[WZX][立档图] ' .. tostring(msg)
    pcall(function()
        if log and log.warn then
            log.warn(text)
        end
    end)
    print(text)
end

---@param options? { generation?: integer }
function CreateCharacterEntry.start(options)
    options = options or {}
    info('start create-character stage')

    local CreateCharacterIntent = require 'wzx.application.boot.create_character_intent'
    local intent = CreateCharacterIntent.peek_go()
    local slot_index = CreateCharacterIntent.get_target_slot()
    if intent and intent.reason == CreateCharacterIntent.REASON_GO then
        info('target empty slot=' .. tostring(slot_index))
    else
        warn('no GO intent — default slot=' .. tostring(slot_index))
    end

    -- Lock map input; hide stock LoadingPanel/Logo if engine still flashes them.
    pcall(function()
        local Kit = require 'wzx.presentation.y3.runtime_ui_kit'
        local player = Kit.get_player()
        Kit.sanitize_startup_ui(player)
        if player and type(y3.ui) == 'table' and type(y3.ui.get_ui) == 'function' then
            local names = { 'LoadingPanel', 'LogoPanel', 'CommonTip' }
            local i
            for i = 1, #names do
                local ok_ui, board = pcall(function()
                    return y3.ui.get_ui(player, names[i])
                end)
                if ok_ui and board and board.set_visible then
                    board:set_visible(false)
                end
            end
        end
        if player and y3.camera and y3.camera.disable_camera_move then
            y3.camera.disable_camera_move(player)
        end
        if player and player.set_mouse_click_selection then
            player:set_mouse_click_selection(false)
            player:set_mouse_drag_selection(false)
            player:set_mouse_wheel(false)
        end
    end)

    -- Temporary on-screen controls until create_character_shell lands.
    pcall(function()
        local player = y3.player(1)
        if player and y3.ui and y3.ui.display_message then
            y3.ui.display_message(
                player,
                '立档台 · 位'
                    .. tostring(slot_index)
                    .. ' · 空格确认占位立档 · ESC 返回',
                8
            )
        end
    end)

    pcall(function()
        if not (y3.game and y3.game.event) then
            return
        end
        local LevelSwitch = require 'wzx.presentation.y3.level_switch'
        y3.game:event('键盘-按下', 'SPACE', function()
            local ok_done, detail_done = LevelSwitch.complete_create_character({
                display_name = '旅人' .. tostring(slot_index),
                character_id = 'hero_placeholder',
                chapter_hint = '卷一 · 开局',
            })
            if not ok_done then
                warn('complete failed: ' .. tostring(detail_done))
            end
        end)
        y3.game:event('键盘-按下', 'ESCAPE', function()
            LevelSwitch.cancel_create_character()
        end)
    end)

    return true, 'create_character_stage'
end

return CreateCharacterEntry
