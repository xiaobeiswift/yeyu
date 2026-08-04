local Harness = require 'wzx.tests.harness'
local DomainEvent = require 'wzx.domain.common.domain_event'
local DialogueCatalog = require 'wzx.config.schema.dialogue.catalog'
local DialogueSectionRegistrar = require 'wzx.config.schema.dialogue.section_registrar'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local DialogueSession = require 'wzx.domain.dialogue.dialogue_session'
local DialogueSaveCodec = require 'wzx.domain.dialogue.dialogue_save_codec'
local DialogueService = require 'wzx.application.use_cases.dialogue.dialogue_service'
local DialogueQuestBridge = require 'wzx.application.use_cases.dialogue.dialogue_quest_bridge'
local FakeDialogueStore = require 'wzx.adapters.fake.dialogue.fake_dialogue_store'
local QuestCatalog = require 'wzx.config.schema.quest.catalog'
local QuestService = require 'wzx.application.use_cases.quest.quest_service'

local case = Harness.case
local assert = Harness.assert

local function fixture_dialogue_source(mutate)
    local source = {
        choice_definitions = {
            {
                id = 'choice_help_yes',
                schema_version = 1,
                rules_version = 1,
                dialogue_id = 'dialogue_villager_help',
                choice_set_id = 'choiceset_help',
                entry_order = 1,
                text_key = 'choice.help.yes',
                next_node_id = 'dnode_help_accept',
                choice_memory_key = 'dmem_offered_help',
                choice_memory_value = true,
            },
            {
                id = 'choice_help_no',
                schema_version = 1,
                rules_version = 1,
                dialogue_id = 'dialogue_villager_help',
                choice_set_id = 'choiceset_help',
                entry_order = 2,
                text_key = 'choice.help.no',
                next_node_id = 'dnode_help_decline',
                choice_memory_key = 'dmem_offered_help',
                choice_memory_value = false,
            },
        },
        node_definitions = {
            {
                id = 'dnode_help_open',
                schema_version = 1,
                rules_version = 1,
                dialogue_id = 'dialogue_villager_help',
                node_type = 'LINE',
                next_node_id = 'dnode_help_choice',
                speaker_id = 'npc_villager',
                text_key = 'dlg.help.open',
            },
            {
                id = 'dnode_help_choice',
                schema_version = 1,
                rules_version = 1,
                dialogue_id = 'dialogue_villager_help',
                node_type = 'CHOICE',
                choice_set_id = 'choiceset_help',
                speaker_id = 'npc_villager',
                text_key = 'dlg.help.choice_prompt',
            },
            {
                id = 'dnode_help_accept',
                schema_version = 1,
                rules_version = 1,
                dialogue_id = 'dialogue_villager_help',
                node_type = 'LINE',
                next_node_id = 'dnode_help_end',
                speaker_id = 'npc_villager',
                text_key = 'dlg.help.accept',
            },
            {
                id = 'dnode_help_decline',
                schema_version = 1,
                rules_version = 1,
                dialogue_id = 'dialogue_villager_help',
                node_type = 'LINE',
                next_node_id = 'dnode_help_end',
                speaker_id = 'npc_villager',
                text_key = 'dlg.help.decline',
            },
            {
                id = 'dnode_help_end',
                schema_version = 1,
                rules_version = 1,
                dialogue_id = 'dialogue_villager_help',
                node_type = 'END',
                text_key = 'dlg.help.end',
                end_reason = 'COMPLETED',
            },
        },
        dialogue_definitions = {
            {
                id = 'dialogue_villager_help',
                schema_version = 1,
                graph_version = 1,
                rules_version = 1,
                start_node_id = 'dnode_help_open',
                node_ids = {
                    'dnode_help_open',
                    'dnode_help_choice',
                    'dnode_help_accept',
                    'dnode_help_decline',
                    'dnode_help_end',
                },
                completion_key = 'dcomp_villager_help',
                default_npc_id = 'npc_villager',
            },
        },
    }
    if mutate ~= nil then
        mutate(source)
    end
    return source
end

local function seal_dialogue(mutate)
    return DialogueCatalog.seal(fixture_dialogue_source(mutate))
end

local function seal_quest_talk()
    return QuestCatalog.seal({
        objective_definitions = {
            {
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
            },
        },
        stage_definitions = {
            {
                id = 'stage_side_01',
                schema_version = 1,
                rules_version = 1,
                quest_id = 'quest_side_talk',
                objective_ids = { 'objective_side_talk' },
                completion_mode = 'ALL',
                journal_text_key = 'stage.side_01',
            },
        },
        quest_definitions = {
            {
                id = 'quest_side_talk',
                schema_version = 1,
                definition_version = 1,
                rules_version = 1,
                category = 'SIDE',
                chapter_id = 'chapter_01',
                title_key = 'quest.side_talk.title',
                summary_key = 'quest.side_talk.summary',
                accept_policy = 'MANUAL_NPC',
                accept_ref_id = 'npc_villager',
                first_stage_id = 'stage_side_01',
                stage_ids = { 'stage_side_01' },
                reward_policy = 'NO_REWARD',
                abandon_policy = 'ALLOW_RESET_RUN',
                journal_sort_order = 20,
            },
        },
    })
end

return {
    case('catalog seals dialogue graph with choice cross refs', function()
        local sealed = seal_dialogue()
        assert.equal(sealed.ok, true, 'seal')
        local dialogue = sealed.value:require_dialogue('dialogue_villager_help')
        assert.equal(dialogue.ok, true)
        assert.equal(dialogue.value.start_node_id, 'dnode_help_open')
        local choices = sealed.value:list_choices_for_set(
            'dialogue_villager_help',
            'choiceset_help'
        )
        assert.equal(choices.ok, true)
        assert.equal(#choices.value, 2)
        assert.equal(choices.value[1].id, 'choice_help_yes')
    end),

    case('catalog rejects missing choice set members', function()
        local sealed = seal_dialogue(function(source)
            source.choice_definitions = {}
        end)
        assert.equal(sealed.ok, false)
        assert.equal(sealed.error.details.reason, 'CHOICE_SET_EMPTY')
    end),

    case('session start advance choose complete publishes durable events', function()
        local sealed = seal_dialogue()
        assert.equal(sealed.ok, true)
        local catalog = sealed.value
        local facts = DialogueSession.empty()

        local started = DialogueSession.start(facts, catalog, {
            session_id = 'dsess_help_01',
            dialogue_id = 'dialogue_villager_help',
            start_receipt_id = 'rcpt_start_help_01',
            command_id = 'cmd_start_help_01',
        })
        assert.equal(started.ok, true, 'start')
        assert.equal(started.value.node.node_type, 'LINE')
        assert.equal(started.value.session.state, 'WAITING_ADVANCE')

        local advanced = DialogueSession.advance(facts, catalog, {
            session_id = 'dsess_help_01',
            expected_revision = started.value.session.session_revision,
            node_id = 'dnode_help_open',
        })
        assert.equal(advanced.ok, true, 'advance')
        assert.equal(advanced.value.node.node_type, 'CHOICE')
        assert.equal(#advanced.value.node.choices, 2)

        local chosen = DialogueSession.choose(facts, catalog, {
            session_id = 'dsess_help_01',
            expected_revision = advanced.value.session.session_revision,
            choice_id = 'choice_help_yes',
            choice_receipt_id = 'rcpt_choice_help_01',
            command_id = 'cmd_choice_help_01',
        })
        assert.equal(chosen.ok, true, 'choose')
        assert.truthy(chosen.value.choice_event)
        assert.equal(chosen.value.choice_event.event_type, 'DialogueChoiceCommitted')
        assert.equal(DomainEvent.validate(chosen.value.choice_event).ok, true)
        assert.equal(facts.memories.dmem_offered_help, true)
        assert.equal(chosen.value.node.node_type, 'LINE')

        local to_end = DialogueSession.advance(facts, catalog, {
            session_id = 'dsess_help_01',
            expected_revision = chosen.value.session.session_revision,
        })
        assert.equal(to_end.ok, true)
        assert.equal(to_end.value.node.node_type, 'END')
        assert.equal(to_end.value.session.state, 'ENDING')

        local completed = DialogueSession.complete(facts, catalog, {
            session_id = 'dsess_help_01',
            completion_receipt_id = 'rcpt_complete_help_01',
            command_id = 'cmd_complete_help_01',
        })
        assert.equal(completed.ok, true, 'complete')
        assert.equal(completed.value.session.state, 'ENDED')
        assert.truthy(completed.value.completion_event)
        assert.equal(completed.value.completion_event.event_type, 'DialogueCompleted')
        assert.equal(DomainEvent.validate(completed.value.completion_event).ok, true)
        assert.equal(completed.value.completion_event.payload.dialogue_id, 'dialogue_villager_help')
        assert.equal(facts.completed.dcomp_villager_help.count, 1)
        assert.equal(facts.active_session, nil)
    end),

    case('busy session rejects second start', function()
        local sealed = seal_dialogue()
        local facts = DialogueSession.empty()
        DialogueSession.start(facts, sealed.value, {
            session_id = 'dsess_busy_01',
            dialogue_id = 'dialogue_villager_help',
            start_receipt_id = 'rcpt_start_busy_01',
        })
        local again = DialogueSession.start(facts, sealed.value, {
            session_id = 'dsess_busy_02',
            dialogue_id = 'dialogue_villager_help',
            start_receipt_id = 'rcpt_start_busy_02',
        })
        assert.equal(again.ok, false)
        assert.equal(again.error.code, 'DIALOGUE_BUSY')
    end),

    case('cancel is allowed at waiting advance', function()
        local sealed = seal_dialogue()
        local facts = DialogueSession.empty()
        DialogueSession.start(facts, sealed.value, {
            session_id = 'dsess_cancel_01',
            dialogue_id = 'dialogue_villager_help',
            start_receipt_id = 'rcpt_start_cancel_01',
        })
        local cancelled = DialogueSession.cancel(facts, {
            session_id = 'dsess_cancel_01',
        })
        assert.equal(cancelled.ok, true)
        assert.equal(cancelled.value.session.state, 'CANCELLED')
        assert.equal(facts.active_session, nil)
    end),

    case('save codec round-trips durable memories and completions', function()
        local sealed = seal_dialogue()
        local facts = DialogueSession.empty()
        DialogueSession.start(facts, sealed.value, {
            session_id = 'dsess_save_01',
            dialogue_id = 'dialogue_villager_help',
            start_receipt_id = 'rcpt_start_save_01',
        })
        DialogueSession.advance(facts, sealed.value, {
            session_id = 'dsess_save_01',
        })
        DialogueSession.choose(facts, sealed.value, {
            session_id = 'dsess_save_01',
            choice_id = 'choice_help_yes',
            choice_receipt_id = 'rcpt_choice_save_01',
        })
        DialogueSession.advance(facts, sealed.value, {
            session_id = 'dsess_save_01',
        })
        DialogueSession.complete(facts, sealed.value, {
            session_id = 'dsess_save_01',
            completion_receipt_id = 'rcpt_complete_save_01',
        })

        local encoded = DialogueSaveCodec.encode(facts)
        assert.equal(encoded.ok, true, 'encode')
        assert.equal(#encoded.value.dialogue_memories, 1)
        assert.equal(#encoded.value.dialogue_completed, 1)
        local decoded = DialogueSaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true, 'decode')
        assert.equal(decoded.value.memories.dmem_offered_help, true)
        assert.equal(decoded.value.completed.dcomp_villager_help.count, 1)
    end),

    case('section registrar installs slot-2 dialogue sections', function()
        local owners = SectionOwnerRegistry.new()
        assert.equal(owners.ok, true)
        local registered = DialogueSectionRegistrar.register({
            system_id = '13',
            section_owners = owners.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 4)
        local section = owners.value:get('dialogue_memories')
        assert.equal(section.ok, true)
        assert.equal(section.value.owner_system, '13')
        assert.equal(section.value.slot_id, 2)
    end),

    case('service with store runs full loop and persists facts', function()
        local sealed = seal_dialogue()
        assert.equal(sealed.ok, true)
        local store = FakeDialogueStore.new()
        assert.equal(store.ok, true)
        local service = DialogueService.bind({
            catalog = sealed.value,
            dialogue_store = store.value,
        })
        assert.equal(service.ok, true)

        local started = service.value:start({
            session_id = 'dsess_svc_01',
            dialogue_id = 'dialogue_villager_help',
            start_receipt_id = 'rcpt_start_svc_01',
            command_id = 'cmd_start_svc_01',
        })
        assert.equal(started.ok, true)
        assert.equal(started.value.persisted, true)

        local advanced = service.value:advance({
            session_id = 'dsess_svc_01',
            expected_revision = started.value.session.session_revision,
        })
        assert.equal(advanced.ok, true)

        local chosen = service.value:choose({
            session_id = 'dsess_svc_01',
            expected_revision = advanced.value.session.session_revision,
            choice_id = 'choice_help_no',
            choice_receipt_id = 'rcpt_choice_svc_01',
        })
        assert.equal(chosen.ok, true)
        assert.equal(chosen.value.choice_event.payload.choice_id, 'choice_help_no')

        local to_end = service.value:advance({
            session_id = 'dsess_svc_01',
            expected_revision = chosen.value.session.session_revision,
        })
        assert.equal(to_end.ok, true)

        local completed = service.value:complete({
            session_id = 'dsess_svc_01',
            completion_receipt_id = 'rcpt_complete_svc_01',
        })
        assert.equal(completed.ok, true)
        assert.equal(completed.value.session.state, 'ENDED')

        local memory = service.value:get_memory('dmem_offered_help')
        assert.equal(memory.ok, true)
        assert.equal(memory.value, false)

        local reloaded = store.value:get_facts()
        assert.equal(reloaded.ok, true)
        assert.equal(reloaded.value.completed.dcomp_villager_help.count, 1)
    end),

    case('bridge completes dialogue and advances quest TALK objective', function()
        local dialogue_sealed = seal_dialogue()
        local quest_sealed = seal_quest_talk()
        assert.equal(dialogue_sealed.ok, true)
        assert.equal(quest_sealed.ok, true)

        local dialogue = DialogueService.bind({ catalog = dialogue_sealed.value })
        local quest = QuestService.bind({ catalog = quest_sealed.value })
        assert.equal(dialogue.ok, true)
        assert.equal(quest.ok, true)

        local accepted = quest.value:accept({
            quest_id = 'quest_side_talk',
            run_id = 'qrun_talk_01',
            accept_receipt_id = 'rcpt_accept_talk_01',
        })
        assert.equal(accepted.ok, true)
        assert.equal(accepted.value.run.status, 'ACTIVE')

        local finished = DialogueQuestBridge.run_to_completion(
            dialogue.value,
            quest.value,
            {
                start = {
                    session_id = 'dsess_bridge_01',
                    dialogue_id = 'dialogue_villager_help',
                    start_receipt_id = 'rcpt_start_bridge_01',
                },
                choice_id = 'choice_help_yes',
                choice_receipt_id = 'rcpt_choice_bridge_01',
                completion_receipt_id = 'rcpt_complete_bridge_01',
            }
        )
        assert.equal(finished.ok, true, 'run_to_completion')
        assert.truthy(finished.value.completion_relay)
        assert.equal(finished.value.completion_relay.applied, true)

        local run_view = quest.value:get_run('qrun_talk_01')
        assert.equal(run_view.ok, true)
        assert.equal(run_view.value.run.status, 'READY_TO_TURN_IN')
        assert.equal(run_view.value.objectives[1].status, 'COMPLETE')
    end),
}
