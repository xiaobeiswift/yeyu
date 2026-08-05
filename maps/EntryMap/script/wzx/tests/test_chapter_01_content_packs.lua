local Harness = require 'wzx.tests.harness'
local QuestChapter01 = require 'wzx.config.content.quest.chapter_01'
local DialogueChapter01 = require 'wzx.config.content.dialogue.chapter_01'
local WorldChapter01 = require 'wzx.config.content.world.chapter_01'
local EncounterChapter01 = require 'wzx.config.content.encounter.chapter_01'
local RewardChapter01 = require 'wzx.config.content.reward.chapter_01'
local Bundle = require 'wzx.config.content.chapter_01_bundle'
local DialogueSession = require 'wzx.domain.dialogue.dialogue_session'

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
    case('dialogue pack seals and covers quest talk targets', function()
        local sealed = DialogueChapter01.seal()
        assert.equal(sealed.ok, true, reason_of(sealed))
        local ids = DialogueChapter01.dialogue_ids()
        local index
        for index = 1, #ids do
            local d = sealed.value:require_dialogue(ids[index])
            assert.equal(d.ok, true, ids[index])
        end
    end),

    case('main 09 proof choice graph has three ordered choices', function()
        local sealed = DialogueChapter01.seal()
        assert.equal(sealed.ok, true, reason_of(sealed))
        local choices = sealed.value:list_choices_for_set(
            'dialogue_main_09_proof_choice',
            'choiceset_main_09_proof'
        )
        assert.equal(choices.ok, true, reason_of(choices))
        assert.equal(#choices.value, 3)
        assert.equal(choices.value[1].choice_memory_value, 'official')
        assert.equal(choices.value[2].choice_memory_value, 'relay')
        assert.equal(choices.value[3].choice_memory_value, 'public')
    end),

    case('dialogue session can complete a linear chapter dialogue', function()
        local sealed = DialogueChapter01.seal()
        assert.equal(sealed.ok, true, reason_of(sealed))
        local facts = DialogueSession.empty()
        local started = DialogueSession.start(facts, sealed.value, {
            dialogue_id = 'dialogue_main_01_post_hire',
            session_id = 'dsess_ch01_main_01',
            start_receipt_id = 'rcpt_start_ch01_main_01',
            command_id = 'cmd_dlg_ch01_main_01',
        })
        assert.equal(started.ok, true, reason_of(started))
        assert.equal(started.value.session.state, 'WAITING_ADVANCE')

        local revision = started.value.session.session_revision
        local guard = 0
        while facts.active_session ~= nil and guard < 20 do
            guard = guard + 1
            local state = facts.active_session.state
            if state == 'WAITING_ADVANCE' or state == 'ENDING' then
                if state == 'ENDING' then
                    local completed = DialogueSession.complete(facts, sealed.value, {
                        session_id = 'dsess_ch01_main_01',
                        completion_receipt_id = 'rcpt_complete_ch01_main_01',
                        command_id = 'cmd_complete_ch01_main_01',
                    })
                    assert.equal(completed.ok, true, reason_of(completed))
                    break
                end
                local advanced = DialogueSession.advance(facts, sealed.value, {
                    session_id = 'dsess_ch01_main_01',
                    expected_revision = revision,
                })
                assert.equal(advanced.ok, true, reason_of(advanced))
                revision = advanced.value.session.session_revision
            else
                break
            end
        end
        assert.equal(facts.active_session, nil)
        assert.equal(facts.completed.dcomp_main_01_post_hire ~= nil, true)
    end),

    case('world pack seals locations and search interactables', function()
        local sealed = WorldChapter01.seal()
        assert.equal(sealed.ok, true, reason_of(sealed))
        local locs = WorldChapter01.location_ids()
        local index
        for index = 1, #locs do
            local loc = sealed.value:require_location(locs[index])
            assert.equal(loc.ok, true, locs[index])
        end
        local interacts = WorldChapter01.interactable_ids()
        for index = 1, #interacts do
            local it = sealed.value:require_interactable(interacts[index])
            assert.equal(it.ok, true, interacts[index])
            assert.equal(it.value.interactable_type, 'SEARCH')
        end
    end),

    case('encounter pack seals ambush and two bosses', function()
        local sealed = EncounterChapter01.seal()
        assert.equal(sealed.ok, true, reason_of(sealed))
        local ids = EncounterChapter01.encounter_ids()
        local index
        for index = 1, #ids do
            local enc = sealed.value:require_encounter(ids[index])
            assert.equal(enc.ok, true, ids[index])
        end
        local ke = sealed.value:require_encounter('encounter_main_05_ke_lishan')
        assert.equal(ke.value.encounter_type, 'BOSS')
        assert.equal(ke.value.boss_controller_id, 'bossctl_ke_lishan')
        local meng = sealed.value:require_encounter('encounter_main_08_meng_jiansheng')
        assert.equal(meng.value.boss_controller_id, 'bossctl_meng_jiansheng')
    end),

    case('reward pack builds copper placeholders for quest rewards', function()
        local built = RewardChapter01.build()
        assert.equal(built.ok, true, reason_of(built))
        local ids = RewardChapter01.reward_ids()
        assert.equal(#ids >= 12, true)
        local index
        for index = 1, #ids do
            assert.equal(built.value:contains(ids[index]), true, ids[index])
        end
    end),

    case('bundle seals all packs and quest targets resolve', function()
        local sealed = Bundle.seal_all()
        assert.equal(sealed.ok, true, reason_of(sealed))
        local packs = sealed.value
        local targets = Bundle.collect_quest_targets(packs.quest)
        assert.equal(targets.ok, true, reason_of(targets))

        local dialogue_id
        for dialogue_id in pairs(targets.value.dialogue) do
            local d = packs.dialogue:require_dialogue(dialogue_id)
            assert.equal(d.ok, true, 'missing dialogue ' .. dialogue_id)
        end

        local location_id
        for location_id in pairs(targets.value.location) do
            local loc = packs.world:require_location(location_id)
            assert.equal(loc.ok, true, 'missing location ' .. location_id)
        end

        local interact_id
        for interact_id in pairs(targets.value.interact) do
            local it = packs.world:require_interactable(interact_id)
            assert.equal(it.ok, true, 'missing interact ' .. interact_id)
        end

        local encounter_id
        for encounter_id in pairs(targets.value.encounter) do
            local enc = packs.encounter:require_encounter(encounter_id)
            assert.equal(enc.ok, true, 'missing encounter ' .. encounter_id)
        end

        local reward_id
        for reward_id in pairs(targets.value.reward) do
            assert.equal(
                packs.reward:contains(reward_id),
                true,
                'missing reward ' .. reward_id
            )
        end
    end),

    case('quest catalog still seals independently', function()
        local sealed = QuestChapter01.seal()
        assert.equal(sealed.ok, true, reason_of(sealed))
        assert.equal(#QuestChapter01.main_quest_ids(), 9)
        assert.equal(#QuestChapter01.side_quest_ids(), 6)
    end),
}
