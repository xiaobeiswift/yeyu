-- Greybox dialogue controller: pure Lua, no y3.* .
-- Drives DialogueService and resolves text for presentation shells.

local DialogueService = require 'wzx.application.use_cases.dialogue.dialogue_service'
local DialogueTextTable = require 'wzx.presentation.greybox.dialogue_text_table'
local Result = require 'wzx.domain.common.result'

local DialoguePlayer = {}
local STATES = setmetatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return Result.err('GREYBOX_DIALOGUE_INVALID', 'error.greybox.dialogue_invalid', false, details)
end

local function next_ids(state)
    state.seq = state.seq + 1
    local n = tostring(state.seq)
    return {
        session_id = 'dsess_greybox_' .. n,
        start_receipt_id = 'rcpt_grey_start_' .. n,
        advance_command_id = 'cmd_grey_adv_' .. n,
        choice_receipt_id = 'rcpt_grey_choice_' .. n,
        choice_command_id = 'cmd_grey_choice_' .. n,
        complete_receipt_id = 'rcpt_grey_complete_' .. n,
        complete_command_id = 'cmd_grey_complete_' .. n,
        start_command_id = 'cmd_grey_start_' .. n,
        cancel_command_id = 'cmd_grey_cancel_' .. n,
    }
end

local function view_from_result(state, result_value)
    local session = result_value.session
    local node = result_value.node
    if session == nil then
        return {
            active = false,
            state = 'IDLE',
            lines = {},
            choices = {},
            dialogue_id = nil,
        }
    end

    local speaker = ''
    local body = ''
    local choices = {}
    if node ~= nil then
        speaker = DialogueTextTable.speaker_name(state.texts, node.speaker_id)
        body = DialogueTextTable.resolve(state.texts, node.text_key)
        if node.choices ~= nil then
            local index
            for index = 1, #node.choices do
                local c = node.choices[index]
                choices[#choices + 1] = {
                    index = index,
                    choice_id = c.choice_id,
                    text = DialogueTextTable.resolve(state.texts, c.text_key),
                    text_key = c.text_key,
                }
            end
        end
    end

    return {
        active = true,
        state = session.state,
        dialogue_id = session.dialogue_id,
        session_id = session.session_id,
        session_revision = session.session_revision,
        speaker = speaker,
        body = body,
        text_key = node and node.text_key or nil,
        node_type = node and node.node_type or nil,
        choices = choices,
        ready_to_complete = result_value.ready_to_complete == true,
        ended = result_value.ended == true,
    }
end

local function capture_view(state, service_result)
    if not service_result.ok then
        return service_result
    end
    local view = view_from_result(state, service_result.value)
    state.last_view = view
    -- After END complete, service may clear session — re-query
    if view.ready_to_complete and view.state == 'ENDING' then
        return Result.ok(view)
    end
    return Result.ok(view)
end

function DialoguePlayer.bind(options)
    options = options or {}
    if type(options) ~= 'table' then
        return invalid('OPTIONS_REQUIRED')
    end
    local catalog = options.catalog
    if type(catalog) ~= 'table' or type(catalog.require_dialogue) ~= 'function' then
        return invalid('CATALOG_REQUIRED')
    end
    local service = DialogueService.bind({
        catalog = catalog,
        dialogue_store = options.dialogue_store,
    })
    if not service.ok then
        return service
    end
    local texts = options.texts
    if texts == nil then
        texts = DialogueTextTable.build_chapter_01()
    end
    local player = {}
    setmetatable(player, { __index = DialoguePlayer })
    STATES[player] = {
        service = service.value,
        texts = texts,
        seq = 0,
        last_view = {
            active = false,
            state = 'IDLE',
            lines = {},
            choices = {},
        },
        last_ids = nil,
    }
    return Result.ok(player)
end

function DialoguePlayer.is_authority(value)
    return type(value) == 'table' and STATES[value] ~= nil
end

function DialoguePlayer:get_view()
    local state = STATES[self]
    if state == nil then
        return invalid('PLAYER_REQUIRED')
    end
    local active = state.service:get_active()
    if not active.ok then
        return active
    end
    if active.value == nil then
        state.last_view = {
            active = false,
            state = 'IDLE',
            choices = {},
        }
        return Result.ok(state.last_view)
    end
    -- Rebuild minimal view from active session + catalog node
    local catalog = nil
    -- Use last_view if revision matches
    if state.last_view.active
        and state.last_view.session_id == active.value.session_id
        and state.last_view.session_revision == active.value.session_revision
    then
        return Result.ok(state.last_view)
    end
    -- Force refresh by reading service state through a no-op path is hard;
    -- caller should keep last_view from start/advance/choose.
    state.last_view.session_id = active.value.session_id
    state.last_view.session_revision = active.value.session_revision
    state.last_view.state = active.value.state
    state.last_view.dialogue_id = active.value.dialogue_id
    state.last_view.active = true
    return Result.ok(state.last_view)
end

function DialoguePlayer:start(dialogue_id)
    local state = STATES[self]
    if state == nil then
        return invalid('PLAYER_REQUIRED')
    end
    if type(dialogue_id) ~= 'string' or dialogue_id == '' then
        return invalid('DIALOGUE_ID_REQUIRED')
    end

    local active = state.service:get_active()
    if active.ok and active.value ~= nil then
        local ids = state.last_ids or next_ids(state)
        state.service:cancel({
            session_id = active.value.session_id,
            command_id = ids.cancel_command_id,
        })
    end

    local ids = next_ids(state)
    state.last_ids = ids
    local started = state.service:start({
        dialogue_id = dialogue_id,
        session_id = ids.session_id,
        start_receipt_id = ids.start_receipt_id,
        command_id = ids.start_command_id,
    })
    return capture_view(state, started)
end

function DialoguePlayer:advance()
    local state = STATES[self]
    if state == nil then
        return invalid('PLAYER_REQUIRED')
    end
    local active = state.service:get_active()
    if not active.ok then
        return active
    end
    if active.value == nil then
        return invalid('NO_ACTIVE_SESSION')
    end
    local session = active.value
    if session.state == 'ENDING' then
        local ids = state.last_ids or next_ids(state)
        local completed = state.service:complete({
            session_id = session.session_id,
            completion_receipt_id = ids.complete_receipt_id,
            command_id = ids.complete_command_id,
        })
        if not completed.ok then
            return completed
        end
        state.last_view = {
            active = false,
            state = 'COMPLETED',
            dialogue_id = session.dialogue_id,
            choices = {},
            body = '（对话结束）',
            speaker = '',
        }
        return Result.ok(state.last_view)
    end
    if session.state ~= 'WAITING_ADVANCE' then
        return invalid('NOT_WAITING_ADVANCE', { state = session.state })
    end
    local advanced = state.service:advance({
        session_id = session.session_id,
        expected_revision = session.session_revision,
    })
    local viewed = capture_view(state, advanced)
    if not viewed.ok then
        return viewed
    end
    if viewed.value.state == 'ENDING' then
        return self:advance()
    end
    return viewed
end

function DialoguePlayer:choose(choice_index)
    local state = STATES[self]
    if state == nil then
        return invalid('PLAYER_REQUIRED')
    end
    local active = state.service:get_active()
    if not active.ok then
        return active
    end
    if active.value == nil then
        return invalid('NO_ACTIVE_SESSION')
    end
    local session = active.value
    if session.state ~= 'WAITING_CHOICE' then
        return invalid('NOT_WAITING_CHOICE', { state = session.state })
    end
    local view = state.last_view
    if view == nil or view.choices == nil or view.choices[choice_index] == nil then
        return invalid('CHOICE_INDEX_INVALID', { index = choice_index })
    end
    local choice = view.choices[choice_index]
    local ids = state.last_ids or next_ids(state)
    ids = next_ids(state)
    state.last_ids = ids
    local chosen = state.service:choose({
        session_id = session.session_id,
        choice_id = choice.choice_id,
        choice_receipt_id = ids.choice_receipt_id,
        expected_revision = session.session_revision,
        command_id = ids.choice_command_id,
    })
    local viewed = capture_view(state, chosen)
    if not viewed.ok then
        return viewed
    end
    if viewed.value.state == 'ENDING' then
        return self:advance()
    end
    return viewed
end

function DialoguePlayer:format_prompt(view)
    if view == nil or not view.active then
        if view and view.state == 'COMPLETED' then
            return '【对话结束】按 F 再开一段'
        end
        return '【灰盒】F 开始 · 空格继续 · 选项到了再按 Q/W/E'
    end
    local lines = {}
    if view.speaker and view.speaker ~= '' then
        lines[#lines + 1] = '【' .. view.speaker .. '】'
    end
    if view.body and view.body ~= '' then
        lines[#lines + 1] = view.body
    end
    if view.state == 'WAITING_CHOICE' and view.choices ~= nil then
        local index
        for index = 1, #view.choices do
            local c = view.choices[index]
            local key = ({ 'Q', 'W', 'E' })[index] or tostring(index)
            lines[#lines + 1] = key .. ') ' .. (c.text or c.choice_id)
        end
        lines[#lines + 1] = '>>> 现在选：Q / W / E <<<'
    elseif view.state == 'WAITING_ADVANCE' or view.state == 'ENDING' then
        lines[#lines + 1] = '（空格：继续；还没到选项）'
    end
    return table.concat(lines, '\n')
end

return DialoguePlayer
