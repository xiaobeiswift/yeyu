local Harness = require 'wzx.tests.harness'
local Chapter01Dialogue = require 'wzx.config.content.dialogue.chapter_01'
local DialoguePlayer = require 'wzx.presentation.greybox.dialogue_player'
local DialogueTextTable = require 'wzx.presentation.greybox.dialogue_text_table'

local case = Harness.case
local assert = Harness.assert

local function reason_of(result)
    if result.ok then
        return 'ok'
    end
    local details = result.error and result.error.details
    if details and details.reason then
        return tostring(details.reason)
    end
    if result.error and result.error.code then
        return tostring(result.error.code)
    end
    return 'unknown'
end

return {
    case('chapter 01 text table resolves m02 arrive lines', function()
        local texts = DialogueTextTable.build_chapter_01()
        local line = DialogueTextTable.resolve(
            texts,
            'dlg.dialogue_main_02_ambush_arrive.l1'
        )
        assert.equal(line, '血味新鲜。人还在附近——或刚走。')
        assert.equal(
            DialogueTextTable.speaker_name(texts, 'npc_partner_liang_jibai'),
            '梁既白'
        )
    end),

    case('greybox player can play m02 arrive to completion', function()
        local sealed = Chapter01Dialogue.seal()
        assert.equal(sealed.ok, true, reason_of(sealed))
        local bound = DialoguePlayer.bind({ catalog = sealed.value })
        assert.equal(bound.ok, true, reason_of(bound))
        local player = bound.value

        local started = player:start('dialogue_main_02_ambush_arrive')
        assert.equal(started.ok, true, reason_of(started))
        assert.equal(started.value.active, true)
        assert.equal(started.value.speaker, '梁既白')
        assert.equal(started.value.body, '血味新鲜。人还在附近——或刚走。')

        local guard = 0
        local view = started
        while view.ok and view.value.active and guard < 20 do
            guard = guard + 1
            view = player:advance()
            assert.equal(view.ok, true, reason_of(view))
        end
        assert.equal(view.value.active, false)
        assert.equal(view.value.state, 'COMPLETED')
    end),

    case('greybox player can choose on m02 site graph', function()
        local sealed = Chapter01Dialogue.seal()
        local bound = DialoguePlayer.bind({ catalog = sealed.value })
        local player = bound.value
        local view = player:start('dialogue_main_02_ambush_site')
        assert.equal(view.ok, true, reason_of(view))

        local guard = 0
        while view.ok and view.value.state == 'WAITING_ADVANCE' and guard < 30 do
            guard = guard + 1
            view = player:advance()
            assert.equal(view.ok, true, reason_of(view))
        end
        assert.equal(view.value.state, 'WAITING_CHOICE')
        assert.equal(#view.value.choices, 3)

        view = player:choose(2)
        assert.equal(view.ok, true, reason_of(view))
        assert.equal(view.value.body, '真匪少见这么客气。假匪，常见。')
    end),
}
