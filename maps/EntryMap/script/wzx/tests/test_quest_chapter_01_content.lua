local Harness = require 'wzx.tests.harness'
local Chapter01 = require 'wzx.config.content.quest.chapter_01'
local QuestSession = require 'wzx.domain.quest.quest_session'

local case = Harness.case
local assert = Harness.assert

return {
    case('chapter 01 catalog seals with full main and side set', function()
        local sealed = Chapter01.seal()
        assert.equal(sealed.ok, true, sealed.ok and 'ok' or tostring(sealed.error and sealed.error.details and sealed.error.details.reason))
        local catalog = sealed.value

        local mains = Chapter01.main_quest_ids()
        assert.equal(#mains, 9)
        local index
        for index = 1, #mains do
            local quest = catalog:require_quest(mains[index])
            assert.equal(quest.ok, true, mains[index])
            assert.equal(quest.value.category, 'MAIN')
            assert.equal(quest.value.chapter_id, 'chapter_01_bell_below_no_name')
            assert.equal(quest.value.abandon_policy, 'DENY')
            assert.equal(quest.value.failure_policy, 'NO_FAIL')
        end

        local sides = Chapter01.side_quest_ids()
        assert.equal(#sides, 6)
        for index = 1, #sides do
            local quest = catalog:require_quest(sides[index])
            assert.equal(quest.ok, true, sides[index])
            assert.equal(quest.value.category, 'SIDE')
        end
    end),

    case('main chain prerequisites form a single path', function()
        local sealed = Chapter01.seal()
        assert.equal(sealed.ok, true)
        local catalog = sealed.value
        local mains = Chapter01.main_quest_ids()

        local first = catalog:require_quest(mains[1])
        assert.equal(first.ok, true)
        assert.equal(first.value.prerequisite_quest_id, nil)

        local index
        for index = 2, #mains do
            local quest = catalog:require_quest(mains[index])
            assert.equal(quest.ok, true, mains[index])
            assert.equal(quest.value.prerequisite_quest_id, mains[index - 1], mains[index])
        end
    end),

    case('accept first main quest creates active run', function()
        local sealed = Chapter01.seal()
        assert.equal(sealed.ok, true)
        local session = QuestSession.empty()
        local accepted = QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_main_01_night_ferry',
            run_id = 'qrun_ch01_main_01',
            accept_receipt_id = 'rcpt_ch01_main_01',
            command_id = 'cmd_ch01_main_01',
            -- AUTO_EVENT 主线须绑定来源事件（开场/连锁），禁止无源接取
            source_event_id = 'event_boot_chapter_01',
        })
        assert.equal(accepted.ok, true, 'accept main 01')
        assert.equal(accepted.value.run.status, 'ACTIVE')
        assert.equal(accepted.value.run.current_stage_id, 'stage_main_01_arrive')
        assert.equal(#accepted.value.objectives, 1)
    end),

    case('side hidden stele uses reveal visibility', function()
        local sealed = Chapter01.seal()
        assert.equal(sealed.ok, true)
        local quest = sealed.value:require_quest('quest_side_05_stele_behind_door')
        assert.equal(quest.ok, true)
        assert.equal(quest.value.visibility_policy, 'HIDDEN_UNTIL_REVEALED')
        assert.equal(quest.value.prerequisite_quest_id, 'quest_main_04_no_bandits')
    end),

    case('mandatory ridge jump objective is traversal landing', function()
        local sealed = Chapter01.seal()
        assert.equal(sealed.ok, true)
        local objective = sealed.value:require_objective('objective_main_04_gap_jump')
        assert.equal(objective.ok, true)
        assert.equal(objective.value.objective_type, 'TRAVERSAL_LANDING')
        assert.equal(objective.value.target_id, 'traversal_cell_ridge_gap_landing')
        assert.equal(objective.value.event_type, 'TraversalLanded')
    end),

    case('boss encounters are wired on main 05 and 08', function()
        local sealed = Chapter01.seal()
        assert.equal(sealed.ok, true)
        local ke = sealed.value:require_objective('objective_main_05_boss')
        local meng = sealed.value:require_objective('objective_main_08_boss')
        assert.equal(ke.ok, true)
        assert.equal(meng.ok, true)
        assert.equal(ke.value.target_id, 'encounter_main_05_ke_lishan')
        assert.equal(meng.value.target_id, 'encounter_main_08_meng_jiansheng')
    end),
}
