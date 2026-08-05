local Harness = require 'wzx.tests.harness'
local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local FakePartyStore = require 'wzx.adapters.fake.party.fake_party_store'
local HydrateGameRuntime = require 'wzx.application.use_cases.save.hydrate_game_runtime'
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local PartyReceiptCodec = require 'wzx.domain.party.party_receipt_codec'
local PartySaveBridge = require 'wzx.application.use_cases.party.party_save_bridge'
local PartySectionRegistrar = require 'wzx.config.schema.party.section_registrar'
local PartyService = require 'wzx.application.use_cases.party.party_service'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'

local case = Harness.case
local assert = Harness.assert

local HASH_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
local HASH_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

local function make_receipt_id(label)
    local derived = CanonicalReceiptHashV1.derive('party_test_receipt', {
        { name = 'label', type = 'STRING' },
    }, {
        label = label,
    })
    assert.equal(derived.ok, true)
    return derived.value.receipt_id
end

local function members_two()
    return {
        {
            character_id = 'char_hero',
            position_index = 1,
            entry_order = 1,
        },
        {
            character_id = 'char_ally',
            position_index = 4,
            entry_order = 2,
            role_tag_override = 'SUPPORT',
        },
    }
end

local function base_receipt(operation_type, extras)
    local row = {
        receipt_id = make_receipt_id(operation_type .. '_base'),
        request_hash = HASH_A,
        result_hash = HASH_B,
        status = 'COMMITTED',
        operation_type = operation_type,
        party_context = 'PVE_MAIN',
        party_save_revision_after = 1,
    }
    if extras ~= nil then
        local key
        local value
        for key, value in next, extras do
            row[key] = value
        end
    end
    return row
end

return {
    case('party receipt codec round-trips all four operation types', function()
        local receipts = {}
        local commit = base_receipt('COMMIT_FORMATION', {
            receipt_id = make_receipt_id('codec_commit'),
            formation_revision_after = 2,
            active_preset_id = 'preset_party_1',
        })
        local save = base_receipt('SAVE_PARTY_PRESET', {
            receipt_id = make_receipt_id('codec_save'),
            preset_id = 'preset_party_save',
            party_save_revision_after = 3,
        })
        local apply = base_receipt('APPLY_PARTY_PRESET', {
            receipt_id = make_receipt_id('codec_apply'),
            preset_id = 'preset_party_apply',
            formation_revision_after = 4,
            active_preset_id = 'preset_party_apply',
            party_save_revision_after = 4,
        })
        local delete = base_receipt('DELETE_PARTY_PRESET', {
            receipt_id = make_receipt_id('codec_delete'),
            preset_id = 'preset_party_delete',
            party_save_revision_after = 5,
        })
        receipts[commit.receipt_id] = commit
        receipts[save.receipt_id] = save
        receipts[apply.receipt_id] = apply
        receipts[delete.receipt_id] = delete

        local encoded = PartyReceiptCodec.encode({
            receipt_revision = 4,
            receipts = receipts,
        })
        assert.equal(encoded.ok, true, encoded.error and encoded.error.details and encoded.error.details.reason)
        assert.equal(encoded.value.party_operation_metadata.schema_version, 1)
        assert.equal(encoded.value.party_operation_metadata.receipt_revision, 4)
        assert.equal(#encoded.value.party_operation_receipts, 4)

        local decoded = PartyReceiptCodec.decode(encoded.value)
        assert.equal(decoded.ok, true, decoded.error and decoded.error.details and decoded.error.details.reason)
        assert.equal(decoded.value.receipt_revision, 4)
        assert.equal(decoded.value.receipts[commit.receipt_id].operation_type, 'COMMIT_FORMATION')
        assert.equal(decoded.value.receipts[commit.receipt_id].formation_revision_after, 2)
        assert.equal(decoded.value.receipts[save.receipt_id].preset_id, 'preset_party_save')
        assert.equal(
            decoded.value.receipts[apply.receipt_id].active_preset_id,
            'preset_party_apply'
        )
        assert.equal(
            decoded.value.receipts[delete.receipt_id].operation_type,
            'DELETE_PARTY_PRESET'
        )
        assert.equal(decoded.value.receipts[delete.receipt_id].formation_revision_after, nil)
    end),

    case('party receipt codec rejects unknown fields and mixed operation fields', function()
        local bad_type = base_receipt('COMMIT_FORMATION', {
            receipt_id = make_receipt_id('bad_type'),
            formation_revision_after = 1,
            operation_type = 'UNKNOWN_OP',
        })
        local encoded_bad = PartyReceiptCodec.encode({
            receipt_revision = 1,
            receipts = { [bad_type.receipt_id] = bad_type },
        })
        assert.equal(encoded_bad.ok, false)
        assert.equal(encoded_bad.error.code, 'PARTY_RECEIPT_INVALID')

        local mixed_commit = base_receipt('COMMIT_FORMATION', {
            receipt_id = make_receipt_id('mixed_commit'),
            formation_revision_after = 1,
            preset_id = 'preset_party_x',
        })
        local encoded_mixed = PartyReceiptCodec.encode({
            receipt_revision = 1,
            receipts = { [mixed_commit.receipt_id] = mixed_commit },
        })
        assert.equal(encoded_mixed.ok, false)
        assert.equal(
            encoded_mixed.error.details.reason,
            'PRESET_ID_FORBIDDEN'
        )

        local mixed_save = base_receipt('SAVE_PARTY_PRESET', {
            receipt_id = make_receipt_id('mixed_save'),
            preset_id = 'preset_party_y',
            formation_revision_after = 2,
        })
        local encoded_save = PartyReceiptCodec.encode({
            receipt_revision = 1,
            receipts = { [mixed_save.receipt_id] = mixed_save },
        })
        assert.equal(encoded_save.ok, false)
        assert.equal(
            encoded_save.error.details.reason,
            'FORMATION_REVISION_FORBIDDEN'
        )

        local with_unknown = base_receipt('COMMIT_FORMATION', {
            receipt_id = make_receipt_id('unknown_field'),
            formation_revision_after = 1,
            extra_field = true,
        })
        local encoded_unknown = PartyReceiptCodec.encode({
            receipt_revision = 1,
            receipts = { [with_unknown.receipt_id] = with_unknown },
        })
        assert.equal(encoded_unknown.ok, false)
        assert.equal(encoded_unknown.error.details.reason, 'UNKNOWN_FIELD')
    end),

    case('commit_formation with receipt_id is idempotent on replay', function()
        local store = FakePartyStore.new({ party_context = 'PVE_MAIN' })
        assert.equal(store.ok, true)
        local service = PartyService.bind({
            party_context = 'PVE_MAIN',
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
            party_store = store.value,
        })
        assert.equal(service.ok, true)

        local receipt_id = make_receipt_id('commit_once')
        local first = service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
            receipt_id = receipt_id,
            skip_save = true,
        })
        assert.equal(first.ok, true, first.error and first.error.code)
        assert.equal(first.value.already_committed, false)
        assert.equal(first.value.revision, 1)
        assert.equal(first.value.receipt_id, receipt_id)

        local replay = service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
            receipt_id = receipt_id,
            skip_save = true,
        })
        assert.equal(replay.ok, true, replay.error and replay.error.code)
        assert.equal(replay.value.already_committed, true)
        assert.equal(replay.value.revision, 1)

        local formation = service.value:get_formation()
        assert.equal(formation.ok, true)
        assert.equal(formation.value.revision, 1)
        assert.equal(#formation.value.member_rows, 2)

        local stored = store.value:get_receipt(receipt_id)
        assert.equal(stored.ok, true)
        assert.equal(stored.value ~= nil, true)
        assert.equal(stored.value.operation_type, 'COMMIT_FORMATION')
        assert.equal(stored.value.formation_revision_after, 1)
    end),

    case('save apply and delete preset each write receipts and replay', function()
        local store = FakePartyStore.new({ party_context = 'PVE_MAIN' })
        assert.equal(store.ok, true)
        local service = PartyService.bind({
            party_context = 'PVE_MAIN',
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
            party_store = store.value,
        })
        assert.equal(service.ok, true)
        assert.equal(service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
        }).ok, true)

        local save_receipt = make_receipt_id('preset_save')
        local saved = service.value:save_preset({
            preset_id = 'preset_party_rcpt',
            display_name = '收据',
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            receipt_id = save_receipt,
            skip_save = true,
        })
        assert.equal(saved.ok, true, saved.error and saved.error.code)
        assert.equal(saved.value.already_committed, false)
        assert.equal(saved.value.preset.preset_id, 'preset_party_rcpt')

        local save_replay = service.value:save_preset({
            preset_id = 'preset_party_rcpt',
            display_name = '收据',
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            receipt_id = save_receipt,
            skip_save = true,
        })
        assert.equal(save_replay.ok, true, save_replay.error and save_replay.error.code)
        assert.equal(save_replay.value.already_committed, true)

        local apply_receipt = make_receipt_id('preset_apply')
        local applied = service.value:apply_preset({
            preset_id = 'preset_party_rcpt',
            expected_formation_revision = 1,
            receipt_id = apply_receipt,
            skip_save = true,
        })
        assert.equal(applied.ok, true, applied.error and applied.error.code)
        assert.equal(applied.value.already_committed, false)
        assert.equal(applied.value.formation.active_preset_id, 'preset_party_rcpt')

        local apply_replay = service.value:apply_preset({
            preset_id = 'preset_party_rcpt',
            expected_formation_revision = 1,
            receipt_id = apply_receipt,
            skip_save = true,
        })
        assert.equal(apply_replay.ok, true, apply_replay.error and apply_replay.error.code)
        assert.equal(apply_replay.value.already_committed, true)

        local delete_receipt = make_receipt_id('preset_delete')
        local deleted = service.value:delete_preset({
            preset_id = 'preset_party_rcpt',
            expected_revision = 1,
            receipt_id = delete_receipt,
            skip_save = true,
        })
        assert.equal(deleted.ok, true, deleted.error and deleted.error.code)
        assert.equal(deleted.value.already_committed, false)
        assert.equal(deleted.value.cleared_active_preset, true)

        local delete_replay = service.value:delete_preset({
            preset_id = 'preset_party_rcpt',
            expected_revision = 1,
            receipt_id = delete_receipt,
            skip_save = true,
        })
        assert.equal(delete_replay.ok, true, delete_replay.error and delete_replay.error.code)
        assert.equal(delete_replay.value.already_committed, true)

        local listed = service.value:list_presets()
        assert.equal(listed.ok, true)
        assert.equal(#listed.value, 0)
    end),

    case('same receipt_id with different request yields conflict', function()
        local store = FakePartyStore.new({ party_context = 'PVE_MAIN' })
        assert.equal(store.ok, true)
        local service = PartyService.bind({
            party_context = 'PVE_MAIN',
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
            party_store = store.value,
        })
        assert.equal(service.ok, true)

        local receipt_id = make_receipt_id('conflict_commit')
        local first = service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
            receipt_id = receipt_id,
            skip_save = true,
        })
        assert.equal(first.ok, true, first.error and first.error.code)

        local conflict = service.value:commit_formation({
            member_rows = {
                {
                    character_id = 'char_hero',
                    position_index = 0,
                    entry_order = 1,
                },
            },
            leader_character_id = 'char_hero',
            expected_revision = 1,
            receipt_id = receipt_id,
            skip_save = true,
        })
        assert.equal(conflict.ok, false)
        assert.equal(conflict.error.code, 'PARTY_RECEIPT_CONFLICT')

        local formation = service.value:get_formation()
        assert.equal(formation.ok, true)
        assert.equal(formation.value.revision, 1)
        assert.equal(#formation.value.member_rows, 2)
    end),

    case('section registrar registers slot-5 party operation sections', function()
        local owners = SectionOwnerRegistry.new()
        assert.equal(owners.ok, true)
        local registered = PartySectionRegistrar.register({
            system_id = '03',
            section_owners = owners.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 7)
        local meta = owners.value:get('party_operation_metadata')
        assert.equal(meta.ok, true)
        assert.equal(meta.value.slot_id, 5)
        assert.equal(meta.value.codec_id, 'codec_party_receipt_bundle_v1')
        local rows = owners.value:get('party_operation_receipts')
        assert.equal(rows.ok, true)
        assert.equal(rows.value.slot_id, 5)
    end),

    case('save bridge writes slot 3+5 and hydrate restores receipts', function()
        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)
        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)

        local store = FakePartyStore.new({ party_context = 'PVE_MAIN' })
        assert.equal(store.ok, true)
        local bridge = PartySaveBridge.bind({
            store = store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 303005,
        })
        assert.equal(bridge.ok, true)
        local service = PartyService.bind({
            party_context = 'PVE_MAIN',
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
            party_store = store.value,
            save_bridge = bridge.value,
        })
        assert.equal(service.ok, true)

        local receipt_id = make_receipt_id('bridge_commit')
        local committed = service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
            receipt_id = receipt_id,
            player_save_scope = 'player_party_rcpt_001',
            request_id = 'request_party_rcpt_commit',
            command_id = 'cmd_party_rcpt_commit',
        })
        assert.equal(committed.ok, true, committed.error and committed.error.code)
        assert.equal(committed.value.save.status, 'COMMITTED')
        assert.equal(committed.value.save.slot3_revision, 1)
        assert.equal(committed.value.save.slot5_revision ~= nil, true)

        local loaded = load.value:load({
            player_ref = 'player_party_rcpt_001',
            session_instance_id = 'session_party_rcpt_1',
            request_id = 'request_load_party_rcpt_1',
        }, invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(
            #loaded.value.loaded_envelopes[5].payload.party_operation_receipts,
            1
        )
        assert.equal(
            loaded.value.loaded_envelopes[5].payload.party_operation_receipts[1].receipt_id,
            receipt_id
        )

        local fresh_store = FakePartyStore.new()
        assert.equal(fresh_store.ok, true)
        local hydrate = HydrateGameRuntime.bind({})
        assert.equal(hydrate.ok, true)
        local hydrated = hydrate.value:hydrate({
            load_result = loaded.value,
            player_save_scope = 'player_party_rcpt_001',
            targets = {
                party_store = fresh_store.value,
            },
        })
        assert.equal(hydrated.ok, true, hydrated.error and hydrated.error.code)

        local restored = fresh_store.value:get_receipt(receipt_id)
        assert.equal(restored.ok, true)
        assert.equal(restored.value ~= nil, true)
        assert.equal(restored.value.operation_type, 'COMMIT_FORMATION')
        assert.equal(restored.value.formation_revision_after, 1)

        local resumed = PartyService.bind({
            party_context = 'PVE_MAIN',
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
            party_store = fresh_store.value,
        })
        assert.equal(resumed.ok, true)
        local replay = resumed.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
            receipt_id = receipt_id,
            skip_save = true,
        })
        assert.equal(replay.ok, true, replay.error and replay.error.code)
        assert.equal(replay.value.already_committed, true)
    end),
}
