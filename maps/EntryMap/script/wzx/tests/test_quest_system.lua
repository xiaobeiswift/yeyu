local Harness = require 'wzx.tests.harness'
local QuestCatalog = require 'wzx.config.schema.quest.catalog'
local QuestSectionRegistrar = require 'wzx.config.schema.quest.section_registrar'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local QuestSession = require 'wzx.domain.quest.quest_session'
local QuestSaveCodec = require 'wzx.domain.quest.quest_save_codec'
local QuestService = require 'wzx.application.use_cases.quest.quest_service'
local QuestSaveBridge = require 'wzx.application.use_cases.quest.quest_save_bridge'
local FakeQuestStore = require 'wzx.adapters.fake.quest.fake_quest_store'
local CurrencyCatalog = require 'wzx.config.schema.economy.catalog'
local RewardCatalog = require 'wzx.config.schema.reward.catalog'
local EconomyService = require 'wzx.application.use_cases.economy.economy_service'
local FakeEconomyStore = require 'wzx.adapters.fake.economy.fake_economy_store'
local ItemCatalog = require 'wzx.config.schema.inventory.catalog'
local InventoryService = require 'wzx.application.use_cases.inventory.inventory_service'
local FakeInventoryStore = require 'wzx.adapters.fake.inventory.fake_inventory_store'
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'

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
        assert.equal(registered.value, 6)
        local section = owners.value:get('quest_runs')
        assert.equal(section.ok, true)
        assert.equal(section.value.owner_system, '14')
        assert.equal(section.value.slot_id, 2)
        local tracked = owners.value:get('tracked_quest_runs')
        assert.equal(tracked.ok, true)
        assert.equal(tracked.value.slot_id, 2)
        local revealed = owners.value:get('revealed_hidden_quests')
        assert.equal(revealed.ok, true)
        assert.equal(revealed.value.owner_system, '14')
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

    case('complete reward saga grants currency then marks completed', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)

        local currency_catalog = CurrencyCatalog.build({
            currency_definitions = {
                {
                    id = 'currency_copper',
                    schema_version = 1,
                    category = 'SOFT',
                    balance_cap = 100000,
                    source_policy_id = 'currpolicy_copper_source',
                    sink_policy_id = 'currpolicy_copper_sink',
                    name_key = 'currency.copper.name',
                },
            },
        })
        assert.equal(currency_catalog.ok, true)
        local reward_catalog = RewardCatalog.build({
            reward_bundles = {
                {
                    id = 'reward_quest_main_01',
                    schema_version = 1,
                    entries = {
                        {
                            entry_order = 1,
                            entry_type = 'CURRENCY',
                            target_id = 'currency_copper',
                            quantity_min = 50,
                            quantity_max = 50,
                        },
                    },
                },
            },
        })
        assert.equal(reward_catalog.ok, true)
        local economy_store = FakeEconomyStore.new()
        assert.equal(economy_store.ok, true)
        local economy = EconomyService.bind({
            currency_catalog = currency_catalog.value,
            reward_catalog = reward_catalog.value,
            store = economy_store.value,
        })
        assert.equal(economy.ok, true)

        local service = QuestService.bind({
            catalog = sealed.value,
            economy_service = economy.value,
        })
        assert.equal(service.ok, true)

        assert.equal(service.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_reward_01',
            accept_receipt_id = 'rcpt_accept_main_reward_01',
            command_id = 'cmd_accept_main_reward_01',
        }).ok, true)

        assert.equal(service.value:consume_fact(
            encounter_completed('evt_main_clear_01', 'encounter_road_ambush', {
                { enemy_id = 'enemy_bandit', count = 2 },
            })
        ).ok, true)
        assert.equal(service.value:consume_fact(
            encounter_completed('evt_main_defeat_01', 'encounter_road_ambush', {
                { enemy_id = 'enemy_bandit', count = 2 },
            })
        ).ok, true)

        local ready = service.value:get_run('qrun_main_reward_01')
        assert.equal(ready.ok, true)
        assert.equal(ready.value.run.status, 'READY_TO_TURN_IN')

        local completed = service.value:complete({
            run_id = 'qrun_main_reward_01',
            completion_receipt_id = 'rcpt_complete_main_reward_01',
            reward_receipt_id = 'rcpt_reward_main_01',
            command_id = 'cmd_complete_main_reward_01',
            player_save_scope = 'player_quest_reward',
        })
        assert.equal(completed.ok, true, tostring(completed.error and completed.error.code))
        assert.equal(completed.value.already_completed, false)
        assert.equal(completed.value.run.status, 'COMPLETED')
        assert.equal(completed.value.reward.status, 'COMMITTED')
        assert.equal(completed.value.reward.receipt_id, 'rcpt_reward_main_01')
        assert.equal(completed.value.reward_receipt_id, 'rcpt_reward_main_01')
        assert.equal(completed.value.run.reward_receipt_id, 'rcpt_reward_main_01')

        local balance = economy.value:get_balance('currency_copper')
        assert.equal(balance.ok, true)
        assert.equal(balance.value.balance, 50)

        local replay = service.value:complete({
            run_id = 'qrun_main_reward_01',
            completion_receipt_id = 'rcpt_complete_main_reward_01',
            reward_receipt_id = 'rcpt_reward_main_01',
            command_id = 'cmd_complete_main_reward_01',
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.already_completed, true)
        assert.equal(replay.value.command_replay, true)
        assert.equal(replay.value.reward.already_committed, true)
        assert.equal(replay.value.reward.receipt_id, 'rcpt_reward_main_01')

        -- Replay must not double-grant.
        local balance_after = economy.value:get_balance('currency_copper')
        assert.equal(balance_after.value.balance, 50)
    end),

    case('reward failure leaves run ready and does not complete', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({
            catalog = sealed.value,
            -- needs reward but no economy service bound
        })
        assert.equal(service.ok, true)
        assert.equal(service.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_main_fail_01',
            accept_receipt_id = 'rcpt_accept_main_fail_01',
        }).ok, true)
        assert.equal(service.value:consume_fact(
            encounter_completed('evt_main_fail_clear', 'encounter_road_ambush', {
                { enemy_id = 'enemy_bandit', count = 2 },
            })
        ).ok, true)
        assert.equal(service.value:consume_fact(
            encounter_completed('evt_main_fail_defeat', 'encounter_road_ambush', {
                { enemy_id = 'enemy_bandit', count = 2 },
            })
        ).ok, true)

        local failed = service.value:complete({
            run_id = 'qrun_main_fail_01',
            completion_receipt_id = 'rcpt_complete_main_fail_01',
        })
        assert.equal(failed.ok, false)
        assert.equal(failed.error.code, 'QUEST_REWARD_REQUIRED')

        local still_ready = service.value:get_run('qrun_main_fail_01')
        assert.equal(still_ready.ok, true)
        assert.equal(still_ready.value.run.status, 'READY_TO_TURN_IN')
        assert.equal(still_ready.value.run.completion_receipt_id, nil)
    end),

    case('turn in npc mismatch is rejected before reward grant', function()
        local sealed = seal_quest(function(source)
            source.quest_definitions[#source.quest_definitions + 1] = {
                id = 'quest_side_turn_in',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'SIDE',
                chapter_id = 'chapter_01',
                title_key = 'quest.side_turn_in.title',
                summary_key = 'quest.side_turn_in.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_villager',
                first_stage_id = 'stage_turn_in_01',
                stage_ids = { 'stage_turn_in_01' },
                reward_policy = 'TURN_IN_NPC',
                turn_in_npc_id = 'npc_quest_giver',
                reward_id = 'reward_quest_main_01',
                abandon_policy = 'ALLOW_RESET_RUN',
                journal_sort_order = 110,
            }
            source.objective_definitions[#source.objective_definitions + 1] = {
                id = 'objective_turn_in_talk',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_turn_in_01',
                objective_type = 'TALK',
                target_id = 'dialogue_villager_help',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'DialogueCompleted',
                description_key = 'obj.turn_in_talk.desc',
                completed_key = 'obj.turn_in_talk.done',
            }
            source.stage_definitions[#source.stage_definitions + 1] = {
                id = 'stage_turn_in_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_side_turn_in',
                objective_ids = { 'objective_turn_in_talk' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.turn_in_01',
            }
        end)
        assert.equal(sealed.ok, true, tostring(
            sealed.error and sealed.error.details and sealed.error.details.reason
        ))

        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)
        assert.equal(service.value:accept({
            quest_id = 'quest_side_turn_in',
            run_id = 'qrun_turn_in_01',
            accept_receipt_id = 'rcpt_accept_turn_in_01',
        }).ok, true)
        assert.equal(service.value:consume_fact({
            event_id = 'evt_turn_in_talk',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_turn_in',
            revision = 1,
            payload = { dialogue_id = 'dialogue_villager_help' },
        }).ok, true)

        local mismatched = service.value:complete({
            run_id = 'qrun_turn_in_01',
            completion_receipt_id = 'rcpt_complete_turn_in_01',
            turn_in_npc_id = 'npc_wrong_person',
        })
        assert.equal(mismatched.ok, false)
        assert.equal(mismatched.error.code, 'QUEST_TURN_IN_INVALID')

        local matched_without_economy = service.value:complete({
            run_id = 'qrun_turn_in_01',
            completion_receipt_id = 'rcpt_complete_turn_in_01',
            turn_in_npc_id = 'npc_quest_giver',
        })
        assert.equal(matched_without_economy.ok, false)
        assert.equal(matched_without_economy.error.code, 'QUEST_REWARD_REQUIRED')
        local still = service.value:get_run('qrun_turn_in_01')
        assert.equal(still.value.run.status, 'READY_TO_TURN_IN')
    end),

    case('deliver item snapshot refresh and turn-in consumes costs', function()
        local sealed = seal_quest(function(source)
            source.quest_definitions[#source.quest_definitions + 1] = {
                id = 'quest_side_deliver',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'SIDE',
                chapter_id = 'chapter_01',
                title_key = 'quest.side_deliver.title',
                summary_key = 'quest.side_deliver.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_villager',
                first_stage_id = 'stage_deliver_01',
                stage_ids = { 'stage_deliver_01' },
                reward_policy = 'NO_REWARD',
                abandon_policy = 'ALLOW_RESET_RUN',
                journal_sort_order = 120,
            }
            source.objective_definitions[#source.objective_definitions + 1] = {
                id = 'objective_deliver_ore',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_deliver_01',
                objective_type = 'DELIVER_ITEM',
                target_id = 'item_iron_ore',
                required_count = 3,
                progress_semantics = 'DELIVER_AT_TURN_IN',
                description_key = 'obj.deliver_ore.desc',
                completed_key = 'obj.deliver_ore.done',
            }
            source.stage_definitions[#source.stage_definitions + 1] = {
                id = 'stage_deliver_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_side_deliver',
                objective_ids = { 'objective_deliver_ore' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.deliver_01',
            }
        end)
        assert.equal(sealed.ok, true, tostring(
            sealed.error and sealed.error.details and sealed.error.details.reason
        ))

        local item_catalog = ItemCatalog.build({
            item_definitions = {
                {
                    id = 'item_iron_ore',
                    schema_version = 1,
                    category = 'MATERIAL',
                    name_key = 'item.iron_ore.name',
                    max_stack = 99,
                    ownership_cap = 999,
                    rarity = 'COMMON',
                },
            },
        })
        assert.equal(item_catalog.ok, true)
        local inv_store = FakeInventoryStore.new({ capacity_limit = 20 })
        assert.equal(inv_store.ok, true)
        local inventory = InventoryService.bind({
            item_catalog = item_catalog.value,
            store = inv_store.value,
        })
        assert.equal(inventory.ok, true)

        local service = QuestService.bind({
            catalog = sealed.value,
            inventory_service = inventory.value,
        })
        assert.equal(service.ok, true)

        assert.equal(service.value:accept({
            quest_id = 'quest_side_deliver',
            run_id = 'qrun_deliver_01',
            accept_receipt_id = 'rcpt_accept_deliver_01',
        }).ok, true)

        -- Without enough items, snapshot keeps objective incomplete.
        local low = service.value:refresh_snapshot_objectives({
            run_id = 'qrun_deliver_01',
        })
        assert.equal(low.ok, true)
        assert.equal(low.value.run.status, 'ACTIVE')
        local not_ready = service.value:complete({
            run_id = 'qrun_deliver_01',
            completion_receipt_id = 'rcpt_complete_deliver_early',
        })
        assert.equal(not_ready.ok, false)
        assert.equal(not_ready.error.code, 'QUEST_PHASE_INVALID')

        assert.equal(inventory.value:grant_items({
            items = { { item_id = 'item_iron_ore', amount = 3 } },
        }).ok, true)

        local ready = service.value:refresh_snapshot_objectives({
            run_id = 'qrun_deliver_01',
        })
        assert.equal(ready.ok, true)
        assert.equal(ready.value.run.status, 'READY_TO_TURN_IN')

        local completed = service.value:complete({
            run_id = 'qrun_deliver_01',
            completion_receipt_id = 'rcpt_complete_deliver_01',
            command_id = 'cmd_complete_deliver_01',
        })
        assert.equal(completed.ok, true, tostring(completed.error and completed.error.code))
        assert.equal(completed.value.run.status, 'COMPLETED')
        assert.equal(completed.value.delivery.status, 'COMMITTED')
        assert.equal(#completed.value.delivery.costs, 1)
        assert.equal(completed.value.delivery.costs[1].item_id, 'item_iron_ore')
        assert.equal(completed.value.delivery.costs[1].amount, 3)
        assert.equal(completed.value.events[1].event_type, 'QuestCompleted')
        assert.equal(completed.value.events[1].payload.reward_state, 'SKIPPED')

        local remaining = inventory.value:get_count('item_iron_ore')
        assert.equal(remaining.ok, true)
        assert.equal(remaining.value.count, 0)

        -- Losing items after READY but before turn-in regresses status.
        local service2 = QuestService.bind({
            catalog = sealed.value,
            inventory_service = inventory.value,
        })
        assert.equal(service2.value:accept({
            quest_id = 'quest_side_deliver',
            run_id = 'qrun_deliver_02',
            accept_receipt_id = 'rcpt_accept_deliver_02',
        }).ok, true)
        assert.equal(inventory.value:grant_items({
            items = { { item_id = 'item_iron_ore', amount = 3 } },
        }).ok, true)
        assert.equal(service2.value:refresh_snapshot_objectives({
            run_id = 'qrun_deliver_02',
        }).value.run.status, 'READY_TO_TURN_IN')
        assert.equal(inventory.value:consume_items({
            items = { { item_id = 'item_iron_ore', amount = 2 } },
        }).ok, true)
        local regressed = service2.value:refresh_snapshot_objectives({
            run_id = 'qrun_deliver_02',
        })
        assert.equal(regressed.ok, true)
        assert.equal(regressed.value.run.status, 'ACTIVE')
        assert.equal(regressed.value.changes[1].regressed, true)
    end),

    case('deliver turn-in fails closed when inventory is insufficient', function()
        local sealed = seal_quest(function(source)
            source.quest_definitions[#source.quest_definitions + 1] = {
                id = 'quest_side_deliver_fail',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'SIDE',
                chapter_id = 'chapter_01',
                title_key = 'quest.side_deliver_fail.title',
                summary_key = 'quest.side_deliver_fail.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_villager',
                first_stage_id = 'stage_deliver_fail_01',
                stage_ids = { 'stage_deliver_fail_01' },
                reward_policy = 'NO_REWARD',
                abandon_policy = 'ALLOW_RESET_RUN',
                journal_sort_order = 121,
            }
            source.objective_definitions[#source.objective_definitions + 1] = {
                id = 'objective_deliver_ore_fail',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_deliver_fail_01',
                objective_type = 'DELIVER_ITEM',
                target_id = 'item_iron_ore',
                required_count = 2,
                progress_semantics = 'DELIVER_AT_TURN_IN',
                description_key = 'obj.deliver_ore_fail.desc',
                completed_key = 'obj.deliver_ore_fail.done',
            }
            source.stage_definitions[#source.stage_definitions + 1] = {
                id = 'stage_deliver_fail_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_side_deliver_fail',
                objective_ids = { 'objective_deliver_ore_fail' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.deliver_fail_01',
            }
        end)
        assert.equal(sealed.ok, true)

        local item_catalog = ItemCatalog.build({
            item_definitions = {
                {
                    id = 'item_iron_ore',
                    schema_version = 1,
                    category = 'MATERIAL',
                    name_key = 'item.iron_ore.name',
                    max_stack = 99,
                    ownership_cap = 999,
                    rarity = 'COMMON',
                },
            },
        })
        assert.equal(item_catalog.ok, true)
        local inv_store = FakeInventoryStore.new({ capacity_limit = 20 })
        assert.equal(inv_store.ok, true)
        local inventory = InventoryService.bind({
            item_catalog = item_catalog.value,
            store = inv_store.value,
        })
        assert.equal(inventory.ok, true)
        local service = QuestService.bind({
            catalog = sealed.value,
            inventory_service = inventory.value,
        })
        assert.equal(service.ok, true)
        assert.equal(service.value:accept({
            quest_id = 'quest_side_deliver_fail',
            run_id = 'qrun_deliver_fail',
            accept_receipt_id = 'rcpt_accept_deliver_fail',
        }).ok, true)

        -- Force READY via explicit counts without actually holding items.
        local forced = service.value:refresh_snapshot_objectives({
            run_id = 'qrun_deliver_fail',
            item_counts = { item_iron_ore = 2 },
        })
        assert.equal(forced.ok, true)
        assert.equal(forced.value.run.status, 'READY_TO_TURN_IN')

        local failed = service.value:complete({
            run_id = 'qrun_deliver_fail',
            completion_receipt_id = 'rcpt_complete_deliver_fail',
        })
        assert.equal(failed.ok, false)
        assert.equal(failed.error.code, 'QUEST_DELIVERY_FAILED')
        local still = service.value:get_run('qrun_deliver_fail')
        assert.equal(still.value.run.status, 'READY_TO_TURN_IN')
    end),

    case('accept rejects missing prerequisite quest', function()
        local sealed = seal_quest(function(source)
            source.objective_definitions[#source.objective_definitions + 1] = {
                id = 'objective_chain_talk',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_chain_01',
                objective_type = 'TALK',
                target_id = 'dialogue_chain_next',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'DialogueCompleted',
                description_key = 'obj.chain_talk.desc',
                completed_key = 'obj.chain_talk.done',
            }
            source.stage_definitions[#source.stage_definitions + 1] = {
                id = 'stage_chain_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_main_wutan_02',
                objective_ids = { 'objective_chain_talk' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.chain_01',
            }
            source.quest_definitions[#source.quest_definitions + 1] = {
                id = 'quest_main_wutan_02',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'MAIN',
                chapter_id = 'chapter_01',
                title_key = 'quest.main_wutan_02.title',
                summary_key = 'quest.main_wutan_02.summary',
                accept_policy = 'AUTO_EVENT',
                prerequisite_quest_id = 'quest_side_no_reward',
                first_stage_id = 'stage_chain_01',
                stage_ids = { 'stage_chain_01' },
                reward_policy = 'NO_REWARD',
                journal_sort_order = 11,
            }
        end)
        assert.equal(sealed.ok, true, tostring(sealed.error and sealed.error.details and sealed.error.details.reason))
        local session = QuestSession.empty()
        local denied = QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_main_wutan_02',
            run_id = 'qrun_chain_early',
            accept_receipt_id = 'rcpt_chain_early',
            source_event_id = 'quest:completed:fake',
        })
        assert.equal(denied.ok, false)
        assert.equal(denied.error.code, 'QUEST_PREREQUISITE_MISSING')
    end),

    case('AUTO_EVENT accept requires source_event_id', function()
        local sealed = seal_quest(function(source)
            source.objective_definitions[#source.objective_definitions + 1] = {
                id = 'objective_auto_talk',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_auto_01',
                objective_type = 'TALK',
                target_id = 'dialogue_auto',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'DialogueCompleted',
                description_key = 'obj.auto_talk.desc',
                completed_key = 'obj.auto_talk.done',
            }
            source.stage_definitions[#source.stage_definitions + 1] = {
                id = 'stage_auto_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_auto_followup',
                objective_ids = { 'objective_auto_talk' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.auto_01',
            }
            source.quest_definitions[#source.quest_definitions + 1] = {
                id = 'quest_auto_followup',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'MAIN',
                chapter_id = 'chapter_01',
                title_key = 'quest.auto_followup.title',
                summary_key = 'quest.auto_followup.summary',
                accept_policy = 'AUTO_EVENT',
                first_stage_id = 'stage_auto_01',
                stage_ids = { 'stage_auto_01' },
                reward_policy = 'NO_REWARD',
                journal_sort_order = 12,
            }
        end)
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)
        local missing_source = service.value:accept({
            quest_id = 'quest_auto_followup',
            run_id = 'qrun_auto_manual',
            accept_receipt_id = 'rcpt_auto_manual',
        })
        assert.equal(missing_source.ok, false)
        assert.equal(missing_source.error.code, 'QUEST_ACCEPT_DENIED')
        assert.equal(missing_source.error.details.reason, 'AUTO_EVENT_SOURCE_REQUIRED')
    end),

    case('complete auto-accepts AUTO_EVENT chain successor via AcceptQuest', function()
        local sealed = seal_quest(function(source)
            source.objective_definitions[#source.objective_definitions + 1] = {
                id = 'objective_chain_next_talk',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_main_chain_02',
                objective_type = 'TALK',
                target_id = 'dialogue_main_next',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'DialogueCompleted',
                description_key = 'obj.chain_next.desc',
                completed_key = 'obj.chain_next.done',
            }
            source.stage_definitions[#source.stage_definitions + 1] = {
                id = 'stage_main_chain_02',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_main_wutan_02',
                objective_ids = { 'objective_chain_next_talk' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.main_chain_02',
            }
            source.quest_definitions[#source.quest_definitions + 1] = {
                id = 'quest_main_wutan_02',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'MAIN',
                chapter_id = 'chapter_01',
                title_key = 'quest.main_wutan_02.title',
                summary_key = 'quest.main_wutan_02.summary',
                accept_policy = 'AUTO_EVENT',
                prerequisite_quest_id = 'quest_side_no_reward',
                first_stage_id = 'stage_main_chain_02',
                stage_ids = { 'stage_main_chain_02' },
                reward_policy = 'NO_REWARD',
                journal_sort_order = 11,
            }
        end)
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)

        assert.equal(service.value:accept({
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_side_chain_src',
            accept_receipt_id = 'rcpt_accept_side_chain',
            command_id = 'cmd_accept_side_chain',
        }).ok, true)
        assert.equal(service.value:consume_fact({
            event_id = 'evt_side_chain_talk',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_side_chain',
            revision = 1,
            payload = { dialogue_id = 'dialogue_villager_help' },
        }).ok, true)

        local completed = service.value:complete({
            run_id = 'qrun_side_chain_src',
            completion_receipt_id = 'rcpt_complete_side_chain',
            command_id = 'cmd_complete_side_chain',
            chain_bindings = {
                quest_main_wutan_02 = {
                    run_id = 'qrun_main_chain_02',
                    accept_receipt_id = 'rcpt_accept_main_chain_02',
                    command_id = 'cmd_accept_main_chain_02',
                },
            },
        })
        assert.equal(completed.ok, true, tostring(completed.error and completed.error.code))
        assert.equal(completed.value.run.status, 'COMPLETED')
        assert.equal(completed.value.events[1].event_type, 'QuestCompleted')
        assert.equal(#completed.value.chain_accepts, 1)
        assert.equal(completed.value.chain_accepts[1].accepted, true)
        assert.equal(completed.value.chain_accepts[1].quest_id, 'quest_main_wutan_02')
        assert.equal(completed.value.chain_accepts[1].run.run_id, 'qrun_main_chain_02')
        assert.equal(completed.value.chain_accepts[1].run.status, 'ACTIVE')
        assert.equal(
            completed.value.chain_accepts[1].source_event_id,
            completed.value.events[1].event_id
        )
        -- MAIN chain successor auto-tracks slot 1 via TrackQuest.
        assert.equal(completed.value.chain_accepts[1].auto_track.applied, true)
        assert.equal(completed.value.chain_accepts[1].auto_track.tracking_position, 1)
        assert.equal(completed.value.chain_accepts[1].auto_track.run_id, 'qrun_main_chain_02')
        local chain_tracked = service.value:get_tracked().value.tracked
        assert.equal(#chain_tracked, 1)
        assert.equal(chain_tracked[1].run_id, 'qrun_main_chain_02')
        assert.equal(chain_tracked[1].tracking_position, 1)

        local chained = service.value:get_run('qrun_main_chain_02')
        assert.equal(chained.ok, true)
        assert.equal(chained.value.run.quest_id, 'quest_main_wutan_02')
        assert.equal(chained.value.run.status, 'ACTIVE')
        assert.equal(chained.value.run.source_event_id, completed.value.events[1].event_id)

        -- Replay complete does not create a second chain run.
        local replay = service.value:complete({
            run_id = 'qrun_side_chain_src',
            completion_receipt_id = 'rcpt_complete_side_chain',
            command_id = 'cmd_complete_side_chain',
            chain_bindings = {
                quest_main_wutan_02 = {
                    run_id = 'qrun_main_chain_02',
                    accept_receipt_id = 'rcpt_accept_main_chain_02',
                    command_id = 'cmd_accept_main_chain_02',
                },
            },
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.already_completed, true)
        assert.equal(#replay.value.chain_accepts, 1)
        assert.equal(replay.value.chain_accepts[1].already_accepted, true)
        assert.equal(replay.value.chain_accepts[1].run.run_id, 'qrun_main_chain_02')
    end),

    case('catalog rejects unknown prerequisite_quest_id', function()
        local sealed = seal_quest(function(source)
            source.quest_definitions[1].prerequisite_quest_id = 'quest_missing_prereq'
        end)
        assert.equal(sealed.ok, false)
        assert.equal(sealed.error.details.reason, 'REFERENCE_NOT_FOUND')
    end),

    case('evaluate availability derives locked available and completed', function()
        local sealed = seal_quest(function(source)
            source.objective_definitions[#source.objective_definitions + 1] = {
                id = 'objective_chain_avail',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_chain_avail',
                objective_type = 'TALK',
                target_id = 'dialogue_chain_avail',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'DialogueCompleted',
                description_key = 'obj.chain_avail.desc',
                completed_key = 'obj.chain_avail.done',
            }
            source.stage_definitions[#source.stage_definitions + 1] = {
                id = 'stage_chain_avail',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_main_wutan_02',
                objective_ids = { 'objective_chain_avail' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.chain_avail',
            }
            source.quest_definitions[#source.quest_definitions + 1] = {
                id = 'quest_main_wutan_02',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'MAIN',
                chapter_id = 'chapter_01',
                title_key = 'quest.main_wutan_02.title',
                summary_key = 'quest.main_wutan_02.summary',
                accept_policy = 'AUTO_EVENT',
                prerequisite_quest_id = 'quest_side_no_reward',
                first_stage_id = 'stage_chain_avail',
                stage_ids = { 'stage_chain_avail' },
                reward_policy = 'NO_REWARD',
                journal_sort_order = 11,
            }
        end)
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)

        local side = service.value:evaluate_availability('quest_side_no_reward')
        assert.equal(side.ok, true)
        assert.equal(side.value.status, 'AVAILABLE')
        assert.equal(side.value.can_accept, true)

        local locked = service.value:evaluate_availability('quest_main_wutan_02')
        assert.equal(locked.ok, true)
        assert.equal(locked.value.status, 'LOCKED')
        assert.equal(locked.value.can_accept, false)
        assert.equal(locked.value.reason, 'PREREQUISITE_QUEST_INCOMPLETE')

        assert.equal(service.value:accept({
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_avail_side',
            accept_receipt_id = 'rcpt_avail_side',
        }).ok, true)
        local active = service.value:evaluate_availability('quest_side_no_reward')
        assert.equal(active.value.status, 'ACTIVE')
        assert.equal(active.value.can_accept, false)

        service.value:consume_fact({
            event_id = 'evt_avail_talk',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_avail',
            revision = 1,
            payload = { dialogue_id = 'dialogue_villager_help' },
        })
        assert.equal(service.value:complete({
            run_id = 'qrun_avail_side',
            completion_receipt_id = 'rcpt_avail_complete',
            chain_bindings = {
                quest_main_wutan_02 = {
                    run_id = 'qrun_avail_chain',
                    accept_receipt_id = 'rcpt_avail_chain',
                    command_id = 'cmd_avail_chain',
                },
            },
        }).ok, true)

        local completed = service.value:evaluate_availability('quest_side_no_reward')
        assert.equal(completed.value.status, 'COMPLETED')
        assert.equal(completed.value.can_accept, false)

        local chained = service.value:evaluate_availability('quest_main_wutan_02')
        assert.equal(chained.value.status, 'ACTIVE')
        assert.equal(chained.value.run_id, 'qrun_avail_chain')
    end),

    case('hidden until revealed stays hidden until reveal_hidden_quest', function()
        local sealed = seal_quest(function(source)
            source.objective_definitions[#source.objective_definitions + 1] = {
                id = 'objective_hidden_talk',
                schema_version = 1,
                rules_version = 1,
                stage_id = 'stage_hidden_01',
                objective_type = 'TALK',
                target_id = 'dialogue_hidden',
                required_count = 1,
                progress_semantics = 'ONCE_FACT',
                event_type = 'DialogueCompleted',
                description_key = 'obj.hidden.desc',
                completed_key = 'obj.hidden.done',
            }
            source.stage_definitions[#source.stage_definitions + 1] = {
                id = 'stage_hidden_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_hidden_secret',
                objective_ids = { 'objective_hidden_talk' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.hidden_01',
            }
            source.quest_definitions[#source.quest_definitions + 1] = {
                id = 'quest_hidden_secret',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'HIDDEN',
                chapter_id = 'chapter_01',
                title_key = 'quest.hidden.title',
                summary_key = 'quest.hidden.summary',
                visibility_policy = 'HIDDEN_UNTIL_REVEALED',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_hidden_guide',
                first_stage_id = 'stage_hidden_01',
                stage_ids = { 'stage_hidden_01' },
                reward_policy = 'NO_REWARD',
                journal_sort_order = 200,
            }
        end)
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)

        local hidden = service.value:evaluate_availability('quest_hidden_secret')
        assert.equal(hidden.ok, true)
        assert.equal(hidden.value.status, 'HIDDEN')
        assert.equal(hidden.value.can_accept, false)
        assert.equal(hidden.value.reason, 'NOT_REVEALED')

        local revealed = service.value:reveal_hidden_quest('quest_hidden_secret')
        assert.equal(revealed.ok, true)
        assert.equal(revealed.value.already_revealed, false)

        local available = service.value:evaluate_availability('quest_hidden_secret', {
            entry_kind = 'NPC',
            entry_ref = 'npc_hidden_guide',
        })
        assert.equal(available.ok, true)
        assert.equal(available.value.status, 'AVAILABLE')
        assert.equal(available.value.can_accept, true)

        local wrong_npc = service.value:evaluate_availability('quest_hidden_secret', {
            entry_kind = 'NPC',
            entry_ref = 'npc_wrong',
        })
        assert.equal(wrong_npc.value.can_accept, false)
        assert.equal(wrong_npc.value.reason, 'ENTRY_REF_MISMATCH')
    end),

    case('list availability is ordered and includes catalog quests', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)
        local listed = service.value:list_availability()
        assert.equal(listed.ok, true)
        assert.equal(#listed.value.entries >= 2, true)
        -- journal_sort_order: main 10 before side 100
        assert.equal(listed.value.entries[1].quest_id, 'quest_main_wutan_01')
        assert.equal(listed.value.entries[1].status, 'AVAILABLE')
    end),

    case('MAIN accept auto-tracks slot 1; side does not; no preemption', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)
        assert.equal(service.value:get_auto_track_main().value.auto_track_main, true)

        local side_first = service.value:accept({
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_auto_side',
            accept_receipt_id = 'rcpt_auto_side',
        })
        assert.equal(side_first.ok, true)
        assert.equal(side_first.value.auto_track.applied, false)
        assert.equal(side_first.value.auto_track.reason, 'NOT_MAIN')
        assert.equal(#service.value:get_tracked().value.tracked, 0)

        -- Occupy slot 1 with side so MAIN accept must not preempt.
        assert.equal(service.value:track({
            run_id = 'qrun_auto_side',
            tracking_position = 1,
            command_id = 'cmd_auto_side_1',
        }).ok, true)

        local main_blocked = service.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_auto_main',
            accept_receipt_id = 'rcpt_auto_main',
        })
        assert.equal(main_blocked.ok, true)
        assert.equal(main_blocked.value.auto_track.applied, false)
        assert.equal(main_blocked.value.auto_track.reason, 'SLOT_OCCUPIED')
        assert.equal(main_blocked.value.auto_track.occupant_run_id, 'qrun_auto_side')
        local tracked_blocked = service.value:get_tracked().value.tracked
        assert.equal(#tracked_blocked, 1)
        assert.equal(tracked_blocked[1].run_id, 'qrun_auto_side')

        -- Free slot 1; disable preference then re-enable via set.
        assert.equal(service.value:track({
            tracking_position = 1,
            command_id = 'cmd_auto_clear_1',
        }).ok, true)
        assert.equal(service.value:set_auto_track_main(false).ok, true)
        -- Main already active; abandon denied. Use a second service for clean MAIN accept.
        local service2 = QuestService.bind({
            catalog = sealed.value,
            auto_track_main = false,
        })
        assert.equal(service2.ok, true)
        local disabled = service2.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_auto_main_off',
            accept_receipt_id = 'rcpt_auto_main_off',
        })
        assert.equal(disabled.ok, true)
        assert.equal(disabled.value.auto_track.applied, false)
        assert.equal(disabled.value.auto_track.reason, 'DISABLED')
        assert.equal(#service2.value:get_tracked().value.tracked, 0)

        assert.equal(service2.value:set_auto_track_main(true).ok, true)
        -- Already accepted: re-accept fails; track manually proves preference is on.
        assert.equal(service2.value:track({
            run_id = 'qrun_auto_main_off',
            tracking_position = 1,
        }).ok, true)

        local service3 = QuestService.bind({ catalog = sealed.value })
        assert.equal(service3.ok, true)
        local auto_on = service3.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_auto_main_on',
            accept_receipt_id = 'rcpt_auto_main_on',
            command_id = 'cmd_auto_main_on',
        })
        assert.equal(auto_on.ok, true)
        assert.equal(auto_on.value.auto_track.applied, true)
        assert.equal(auto_on.value.auto_track.tracking_position, 1)
        assert.equal(auto_on.value.auto_track.run_id, 'qrun_auto_main_on')
        local tracked_on = service3.value:get_tracked().value.tracked
        assert.equal(#tracked_on, 1)
        assert.equal(tracked_on[1].tracking_position, 1)
        assert.equal(tracked_on[1].run_id, 'qrun_auto_main_on')

        -- Command replay does not re-apply auto track side effects.
        local replay = service3.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_auto_main_on',
            accept_receipt_id = 'rcpt_auto_main_on',
            command_id = 'cmd_auto_main_on',
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.command_replay, true)
        assert.equal(replay.value.auto_track.applied, false)
        assert.equal(replay.value.auto_track.reason, 'REPLAY_OR_EXISTING')
        assert.equal(#service3.value:get_tracked().value.tracked, 1)
    end),

    case('track quest occupies positions 1-3 and journal sorts tracked first', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        -- Disable auto track so this case exercises explicit TrackQuest only.
        local service = QuestService.bind({
            catalog = sealed.value,
            auto_track_main = false,
        })
        assert.equal(service.ok, true)

        assert.equal(service.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_track_main',
            accept_receipt_id = 'rcpt_track_main',
        }).ok, true)
        assert.equal(service.value:accept({
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_track_side',
            accept_receipt_id = 'rcpt_track_side',
        }).ok, true)

        local tracked = service.value:track({
            run_id = 'qrun_track_side',
            tracking_position = 1,
            command_id = 'cmd_track_side_1',
        })
        assert.equal(tracked.ok, true, tostring(tracked.error and tracked.error.code))
        assert.equal(tracked.value.tracking_position, 1)
        assert.equal(tracked.value.run_id, 'qrun_track_side')
        assert.equal(#tracked.value.tracked, 1)

        local main_track = service.value:track({
            run_id = 'qrun_track_main',
            tracking_position = 2,
            command_id = 'cmd_track_main_2',
        })
        assert.equal(main_track.ok, true)
        assert.equal(#main_track.value.tracked, 2)

        -- Move side from 1 to 3.
        local moved = service.value:track({
            run_id = 'qrun_track_side',
            tracking_position = 3,
            command_id = 'cmd_track_side_3',
        })
        assert.equal(moved.ok, true)
        assert.equal(moved.value.moved_from_position, 1)
        assert.equal(#moved.value.tracked, 2)

        local journal = service.value:get_journal()
        assert.equal(journal.ok, true)
        assert.equal(#journal.value.tracked, 2)
        -- Position 2 main before position 3 side.
        assert.equal(journal.value.tracked[1].tracking_position, 2)
        assert.equal(journal.value.tracked[1].run_id, 'qrun_track_main')
        assert.equal(journal.value.entries[1].run_id, 'qrun_track_main')
        assert.equal(journal.value.entries[1].tracking_position, 2)

        local replay = service.value:track({
            run_id = 'qrun_track_side',
            tracking_position = 3,
            command_id = 'cmd_track_side_3',
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.command_replay, true)

        -- Clear slot 2.
        local cleared = service.value:track({
            tracking_position = 2,
            command_id = 'cmd_untrack_2',
        })
        assert.equal(cleared.ok, true)
        assert.equal(cleared.value.cleared, true)
        assert.equal(#cleared.value.tracked, 1)
    end),

    case('complete and abandon clear tracking slots', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local service = QuestService.bind({ catalog = sealed.value })
        assert.equal(service.ok, true)

        -- Complete (NO_REWARD side) clears tracking.
        assert.equal(service.value:accept({
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_track_clear_side',
            accept_receipt_id = 'rcpt_track_clear_side',
        }).ok, true)
        assert.equal(service.value:track({
            run_id = 'qrun_track_clear_side',
            tracking_position = 1,
        }).ok, true)
        assert.equal(#service.value:get_tracked().value.tracked, 1)
        assert.equal(service.value:consume_fact({
            event_id = 'evt_track_clear_talk',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_track_clear',
            revision = 1,
            payload = { dialogue_id = 'dialogue_villager_help' },
        }).ok, true)
        local completed = service.value:complete({
            run_id = 'qrun_track_clear_side',
            completion_receipt_id = 'rcpt_track_clear_side_done',
        })
        assert.equal(completed.ok, true)
        assert.equal(#service.value:get_tracked().value.tracked, 0)

        -- Abandon clears tracking.
        assert.equal(service.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_track_clear_main',
            accept_receipt_id = 'rcpt_track_clear_main',
        }).ok, true)
        -- Cannot re-accept completed side; abandon main is denied. Use domain
        -- session with a fresh side-like abandon via ALLOW_RESET after... side completed.
        -- Track main then abandon denied is not useful; track via domain on a
        -- re-created abandoned-reset path: abandon is only for open non-main.
        -- Accept is blocked for completed side. Just abandon-deny check on main:
        assert.equal(service.value:track({
            run_id = 'qrun_track_clear_main',
            tracking_position = 1,
        }).ok, true)
        local abandoned = service.value:abandon({
            run_id = 'qrun_track_clear_main',
        })
        assert.equal(abandoned.ok, false)
        assert.equal(abandoned.error.code, 'QUEST_ABANDON_DENIED')
        -- Main still tracked (abandon failed).
        assert.equal(#service.value:get_tracked().value.tracked, 1)

        -- Domain-level abandon clear: use empty session with side only.
        local session = QuestSession.empty()
        QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_ab_clear',
            accept_receipt_id = 'rcpt_ab_clear',
        })
        QuestSession.track(session, {
            run_id = 'qrun_ab_clear',
            tracking_position = 2,
        })
        local ab = QuestSession.abandon(session, { run_id = 'qrun_ab_clear' })
        assert.equal(ab.ok, true)
        assert.equal(#ab.value.cleared_tracking_positions, 1)
        assert.equal(#ab.value.tracked, 0)
    end),

    case('track rejects terminal run and invalid position', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local session = QuestSession.empty()
        QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_term',
            accept_receipt_id = 'rcpt_term',
        })
        QuestSession.consume_fact(session, sealed.value, {
            event_id = 'evt_term',
            event_type = 'DialogueCompleted',
            schema_version = 1,
            aggregate_id = 'agg_term',
            revision = 1,
            payload = { dialogue_id = 'dialogue_villager_help' },
        })
        QuestSession.complete(session, sealed.value, {
            run_id = 'qrun_term',
            completion_receipt_id = 'rcpt_term_complete',
        })
        local bad = QuestSession.track(session, {
            run_id = 'qrun_term',
            tracking_position = 1,
        })
        assert.equal(bad.ok, false)
        assert.equal(bad.error.code, 'QUEST_PHASE_INVALID')

        local pos = QuestSession.track(session, {
            run_id = 'qrun_term',
            tracking_position = 4,
        })
        assert.equal(pos.ok, false)
        assert.equal(pos.error.details.reason, 'TRACKING_POSITION_INVALID')
    end),

    case('save codec round-trips tracked quest runs', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)
        local session = QuestSession.empty()
        QuestSession.accept(session, sealed.value, {
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_codec_track',
            accept_receipt_id = 'rcpt_codec_track',
        })
        QuestSession.track(session, {
            run_id = 'qrun_codec_track',
            tracking_position = 2,
        })
        local encoded = QuestSaveCodec.encode(session)
        assert.equal(encoded.ok, true, tostring(encoded.error and encoded.error.details and encoded.error.details.reason))
        assert.equal(#encoded.value.tracked_quest_runs, 1)
        assert.equal(encoded.value.tracked_quest_runs[1].tracking_position, 2)
        local decoded = QuestSaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true)
        assert.equal(decoded.value.tracked_run_ids[2], 'qrun_codec_track')
    end),

    case('quest save bridge writes slot 2 and reloads READY', function()
        local sealed = seal_quest()
        assert.equal(sealed.ok, true)

        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)

        local store = FakeQuestStore.new()
        assert.equal(store.ok, true)
        local bridge = QuestSaveBridge.bind({
            store = store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 140001,
        })
        assert.equal(bridge.ok, true)

        local service = QuestService.bind({
            catalog = sealed.value,
            quest_store = store.value,
            save_bridge = bridge.value,
            auto_track_main = true,
        })
        assert.equal(service.ok, true)

        local accepted = service.value:accept({
            quest_id = 'quest_main_wutan_01',
            run_id = 'qrun_slot2_main',
            accept_receipt_id = 'rcpt_slot2_main',
            command_id = 'cmd_slot2_main',
            player_save_scope = 'player_quest_01',
            request_id = 'request_quest_accept_slot2',
        })
        assert.equal(accepted.ok, true, tostring(accepted.error and accepted.error.code))
        assert.equal(accepted.value.save.status, 'COMMITTED')
        assert.equal(accepted.value.save.created_save, true)
        assert.equal(accepted.value.auto_track.applied, true)
        assert.equal(accepted.value.save.slot2_revision, 1)

        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)
        local loaded = load.value:load({
            player_ref = 'player_quest_01',
            session_instance_id = 'session_quest_slot2',
            request_id = 'request_load_quest_slot2',
        }, invoke)
        assert.equal(loaded.ok, true, tostring(loaded.error and loaded.error.code))
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.writable, true)
        assert.equal(loaded.value.loaded_envelopes[2] ~= nil, true)
        local payload = loaded.value.loaded_envelopes[2].payload
        assert.equal(payload.quest_metadata.session_revision >= 1, true)
        assert.equal(#payload.quest_runs, 1)
        assert.equal(payload.quest_runs[1].run_id, 'qrun_slot2_main')
        assert.equal(payload.quest_runs[1].status, 'ACTIVE')
        assert.equal(#payload.tracked_quest_runs, 1)
        assert.equal(payload.tracked_quest_runs[1].tracking_position, 1)
        assert.equal(payload.tracked_quest_runs[1].run_id, 'qrun_slot2_main')
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_2_revision,
            loaded.value.loaded_envelopes[2].revision
        )

        -- Second accept without scope skips cloud write; explicit track with scope advances slot 2.
        local side = service.value:accept({
            quest_id = 'quest_side_no_reward',
            run_id = 'qrun_slot2_side',
            accept_receipt_id = 'rcpt_slot2_side',
            command_id = 'cmd_slot2_side',
        })
        assert.equal(side.ok, true)
        assert.equal(side.value.save.status, 'SKIPPED')
        assert.equal(side.value.save.reason, 'PLAYER_SAVE_SCOPE_MISSING')

        local tracked = service.value:track({
            run_id = 'qrun_slot2_side',
            tracking_position = 2,
            command_id = 'cmd_slot2_track_side',
            player_save_scope = 'player_quest_01',
            request_id = 'request_quest_track_slot2',
        })
        assert.equal(tracked.ok, true)
        assert.equal(tracked.value.save.status, 'COMMITTED')
        assert.equal(tracked.value.save.created_save, false)
        assert.equal(tracked.value.save.slot2_revision, 2)

        local reloaded = load.value:load({
            player_ref = 'player_quest_01',
            session_instance_id = 'session_quest_slot2_b',
            request_id = 'request_load_quest_slot2_b',
        }, invoke)
        assert.equal(reloaded.ok, true)
        assert.equal(reloaded.value.mode, 'READY')
        local payload2 = reloaded.value.loaded_envelopes[2].payload
        assert.equal(#payload2.quest_runs, 2)
        assert.equal(#payload2.tracked_quest_runs, 2)
    end),
}
