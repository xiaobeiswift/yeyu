local Harness = require 'wzx.tests.harness'
local QuestCatalog = require 'wzx.config.schema.quest.catalog'
local QuestSectionRegistrar = require 'wzx.config.schema.quest.section_registrar'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local QuestSession = require 'wzx.domain.quest.quest_session'
local QuestSaveCodec = require 'wzx.domain.quest.quest_save_codec'
local QuestService = require 'wzx.application.use_cases.quest.quest_service'
local FakeQuestStore = require 'wzx.adapters.fake.quest.fake_quest_store'

local case = Harness.case
local assert = Harness.assert

local function fixture_quest_source(mutate)
    local source = {
        objective_definitions = {
            {
                id = 'objective_clear_ambush',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_main_01',
                objective_type = 'COMPLETE_ENCOUNTER',
                target_id = 'encounter_road_ambush',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'EncounterCompleted',
                description_key = 'obj.clear_ambush.desc',
                completed_key = 'obj.clear_ambush.done',
            },
            {
                id = 'objective_defeat_bandit',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_main_02',
                objective_type = 'DEFEAT_ENEMY',
                target_id = 'enemy_bandit',
                required_count = 2,
                progress_semantics = 'ACCUMULATE_AFTER_ACCEPT',
                event_type = 'EncounterCompleted',
                description_key = 'obj.defeat_bandit.desc',
                completed_key = 'obj.defeat_bandit.done',
            },
        },
        stage_definitions = {
            {
                id = 'stage_main_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_main_wutan_01',
                objective_ids = { 'objective_clear_ambush' },
                completion_mode = 'ALL',
                next_stage_id = 'stage_main_02',
                journal_text_key = 'stage.main_01',
            },
            {
                id = 'stage_main_02',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_main_wutan_01',
                objective_ids = { 'objective_defeat_bandit' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.main_02',
            },
        },
        quest_definitions = {
            {
                id = 'quest_main_wutan_01',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'MAIN',
                chapter_id = 'chapter_01',
                title_key = 'quest.main_wutan_01.title',
                summary_key = 'quest.main_wutan_01.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_guide_chen',
                first_stage_id = 'stage_main_01',
                stage_ids = { 'stage_main_01', 'stage_main_02' },
                reward_policy = 'AUTO_ON_COMPLETE',
                reward_id = 'reward_quest_main_01',
                journal_sort_order = 10,
            },
            {
                id = 'quest_side_no_reward',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'SIDE',
                chapter_id = 'chapter_01',
                title_key = 'quest.side_no_reward.title',
                summary_key = 'quest.side_no_reward.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_villager',
                first_stage_id = 'stage_side_01',
                stage_ids = { 'stage_side_01' },
                reward_policy = 'NO_REWARD',
                abandon_policy = 'ALLOW_RESET_RUN',
                journal_sort_order = 100,
            },
        },
    }
    -- side stage/objective added for abandon tests
    source.objective_definitions[#source.objective_definitions + 1] = {
        id = 'objective_side_talk',
        schema_version = 1,
        rules_version = 1,
        stage_id = 'stage_side_01',
        objective_type = 'TALK',
        target_id = 'dialogue_villager_help',
        required_count = 1,
        progress_semantics = 'ONCE_FACT',
        event_type = 'DialogueCompleted',
        description_key = 'obj.side_talk.desc',
        completed_key = 'obj.side_talk.done',
    }
    source.stage_definitions[#source.stage_definitions + 1] = {
        id = 'stage_side_01',
        schema_version = 1,
        rules_version = 1,
        quest_id = 'quest_side_no_reward',
        objective_ids = { 'objective_side_talk' },
        completion_mode = 'ALL',
        journal_text_key = 'stage.side_01',
    }
    if mutate ~= nil then
        mutate(source)
    end
    return source
end

local function seal_quest(mutate)
    return QuestCatalog.seal(fixture_quest_source(mutate))
end

local function encounter_completed(event_id, encounter_id, defeated)
    return {
        event_id = event_id,
        event_type = 'EncounterCompleted',
        schema_version = 1,
        aggregate_id = 'agg_encounter_01',
        revision = 1,
        payload = {
            encounter_id = encounter_id,
            result = 'ATTACKER_WIN',
            settlement_receipt_id = 'rcpt_settle_' .. event_id,
            defeated_entries = defeated or {},
        },
    }
end

return {
    case('catalog seals quest stages and objectives with cross refs', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true, 'seal')
        local quest = sealed.value:require_quest('quest_main_wutan_01')
        assert.equal(quest.ok, true)
        assert.equal(quest.value.first_stage_id, 'stage_main_01')
        assert.equal(#quest.value.stage_ids, 2)
    end),

    case('catalog rejects objective stage mismatch', function()
        local sealed = seal_quest(function(source)
            source.objective_definitions[1].stage_id = 'stage_main_02'
        end)
        assert.equal(sealed.ok, false)
        assert.equal(sealed.error.details.reason, 'OBJECTIVE_STAGE_MISMATCH')
    end),

    case('accept creates active run and initial objectives', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local session = QuestSession.empty()
        local accepted = QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_01',
            accept_receipt_id = 'rcpt_accept_main_01',
            command_id = 'cmd_accept_main_01',
        })
        assert.equal(accepted.ok, true, 'accept')
        assert.equal(accepted.value.run.status, 'ACTIVE')
        assert.equal(accepted.value.run.current_stage_id, 'stage_main_01')
        assert.equal(#accepted.value.objectives, 1)
        assert.equal(accepted.value.objectives[1].progress, 0)
    end),

    case('second accept of same quest is rejected', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local session = QuestSession.empty()
        QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_01',
            accept_receipt_id = 'rcpt_accept_main_01',
        })
        local again = QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_02',
            accept_receipt_id = 'rcpt_accept_main_02',
        })
        assert.equal(again.ok, false)
        assert.equal(again.error.code, 'QUEST_ALREADY_ACTIVE')
    end),

    case('encounter completed advances stage then accumulates defeats', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local catalog = sealed.value
        local session = QuestSession.empty()
        QuestSession.accept(session, catalog, {
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_01',
            accept_receipt_id = 'rcpt_accept_main_01',
        })

        local first = QuestSession.consume_fact(
            session,
            catalog,
            encounter_completed('evt_enc_clear_01', 'encounter_road_ambush', {
                { enemy_id = 'enemy_bandit', count = 2 },
            })
        )
        assert.equal(first.ok, true, 'first fact')
        assert.equal(first.value.applied, true)
        local run_view = QuestSession.get_run(session, 'qrun_main_01')
        assert.equal(run_view.ok, true)
        assert.equal(run_view.value.run.current_stage_id, 'stage_main_02')
        assert.equal(run_view.value.run.status, 'ACTIVE')

        -- Stage 2 starts at 0; same event must not carry into new stage (V1 default).
        local stage2_obj = nil
        local index
        for index = 1, #run_view.value.objectives do
            if run_view.value.objectives[index].objective_id == 'objective_defeat_bandit' then
                stage2_obj = run_view.value.objectives[index]
            end
        end
        assert.truthy(stage2_obj)
        assert.equal(stage2_obj.progress, 0)

        local second = QuestSession.consume_fact(
            session,
            catalog,
            encounter_completed('evt_enc_clear_02', 'encounter_road_ambush', {
                { enemy_id = 'enemy_bandit', count = 2 },
            })
        )
        assert.equal(second.ok, true)
        run_view = QuestSession.get_run(session, 'qrun_main_01')
        assert.equal(run_view.value.run.status, 'READY_TO_TURN_IN')
        for index = 1, #run_view.value.objectives do
            if run_view.value.objectives[index].objective_id == 'objective_defeat_bandit' then
                assert.equal(run_view.value.objectives[index].progress, 2)
                assert.equal(run_view.value.objectives[index].status, 'COMPLETE')
            end
        end
    end),

    case('duplicate event id is ignored', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local catalog = sealed.value
        local session = QuestSession.empty()
        QuestSession.accept(session, catalog, {
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_01',
            accept_receipt_id = 'rcpt_accept_main_01',
        })
        local event = encounter_completed('evt_dup_01', 'encounter_road_ambush')
        local first = QuestSession.consume_fact(session, catalog, event)
        assert.equal(first.ok, true)
        assert.equal(first.value.duplicate, false)
        local second = QuestSession.consume_fact(session, catalog, event)
        assert.equal(second.ok, true)
        assert.equal(second.value.duplicate, true)
        assert.equal(second.value.applied, false)
    end),

    case('main quest abandon is denied', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local session = QuestSession.empty()
        QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_01',
            accept_receipt_id = 'rcpt_accept_main_01',
        })
        local abandoned = QuestSession.abandon(session, { run_id = 'qrun_main_01' })
        assert.equal(abandoned.ok, false)
        assert.equal(abandoned.error.code, 'QUEST_ABANDON_DENIED')
    end),

    case('side quest can abandon', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local session = QuestSession.empty()
        QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_side_01',
            accept_receipt_id = 'rcpt_accept_side_01',
        })
        local abandoned = QuestSession.abandon(session, { run_id = 'qrun_side_01' })
        assert.equal(abandoned.ok, true)
        assert.equal(abandoned.value.run.status, 'ABANDONED')
    end),

    case('save codec round-trips session', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local session = QuestSession.empty()
        QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_01',
            accept_receipt_id = 'rcpt_accept_main_01',
        })
        QuestSession.consume_fact(
            session,
            sealed.value,
            encounter_completed('evt_save_01', 'encounter_road_ambush')
        )
        local encoded = QuestSaveCodec.encode(session)
        assert.equal(encoded.ok, true, 'encode')
        local decoded = QuestSaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true, 'decode')
        assert.equal(decoded.value.session_revision, session.session_revision)
        assert.equal(decoded.value.runs.qrun_main_01.current_stage_id, 'stage_main_02')
        assert.truthy(decoded.value.event_receipts.evt_save_01)
    end),

    case('section registrar installs slot-2 quest sections', function()
        local owners = SectionOwnerRegistry.new()
        assert.equal(owners.ok, true)
        local registered = QuestSectionRegistrar.register({
            system_id = '14',
            section_owners = owners.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 4)
        local section = owners.value:get('quest_runs')
        assert.equal(section.ok, true)
        assert.equal(section.value.owner_system, '14')
        assert.equal(section.value.slot_id, 2)
    end),

    case('service completes quest with store persistence', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local store = FakeQuestStore.new()
        assert.equal(store.ok, true)

        local service = QuestService.bind({
            catalog = sealed.value,
            quest_store = store.value,
        })
        assert.equal(service.ok, true)

        local accepted = service.value:accept({
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_side_01',
            accept_receipt_id = 'rcpt_accept_side_01',
            command_id = 'cmd_side_01',
        })
        assert.equal(accepted.ok, true)
        local consumed = service.value:consume_fact({
            event_id = 'evt_talk_01',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_dialogue_01',
            revision = 1,
            payload = {
                dialogue_id = 'dialogue_villager_help',
            },
        })
        assert.equal(consumed.ok, true)
        local completed = service.value:complete({
            run_id = 'qrun_side_01',
            completion_receipt_id = 'rcpt_complete_side_01',
            command_id = 'cmd_complete_side_01',
        })
        assert.equal(completed.ok, true, 'complete')
        assert.equal(completed.value.run.status, 'COMPLETED')
        assert.equal(completed.value.already_completed, false)

        local journal = service.value:get_journal()
        assert.equal(journal.ok, true)
        assert.equal(#journal.value.entries >= 1, true)

        local reloaded = store.value:get_session()
        assert.equal(reloaded.ok, true)
        assert.equal(reloaded.value.runs.qrun_side_01.status, 'COMPLETED')
    end),

    case('service replay complete is idempotent by receipt', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)
        service.value:accept({
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_side_01',
            accept_receipt_id = 'rcpt_accept_side_01',
        })
        service.value:consume_fact({
            event_id = 'evt_talk_02',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_dialogue_02',
            revision = 1,
            payload = { dialogue_id = 'dialogue_villager_help' },
        })
        local first = service.value:complete({
            run_id = 'qrun_side_01',
            completion_receipt_id = 'rcpt_complete_side_02',
        })
        assert.equal(first.ok, true)
        local second = service.value:complete({
            run_id = 'qrun_side_01',
            completion_receipt_id = 'rcpt_complete_side_02',
        })
        assert.equal(second.ok, true)
        assert.equal(second.value.already_completed, true)
    end),
}
