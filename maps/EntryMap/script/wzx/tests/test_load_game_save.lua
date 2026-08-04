local Harness = require 'wzx.tests.harness'
local CreateNewSave = require 'wzx.application.use_cases.save.create_new_save'
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local SaveCheckpoint = require 'wzx.application.use_cases.save.save_checkpoint'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'
local SlotRevisionVector = require 'wzx.domain.save.slot_revision_vector'

local case = Harness.case
local assert = Harness.assert

local function build_stack()
    local store = MemorySaveStore.new()
    local bound = SaveCoordinator.bind({ save_store = store })
    assert.equal(bound.ok, true)
    local coordinator = bound.value
    local invoke = SaveCoordinator.fake_invoke(store)
    local create = CreateNewSave.bind({ coordinator = coordinator })
    local load = LoadGameSave.bind({ coordinator = coordinator })
    local checkpoint = SaveCheckpoint.bind({ coordinator = coordinator })
    assert.equal(create.ok, true)
    assert.equal(load.ok, true)
    assert.equal(checkpoint.ok, true)
    return {
        store = store,
        coordinator = coordinator,
        invoke = invoke,
        create = create.value,
        load = load.value,
        checkpoint = checkpoint.value,
    }
end

local function create_fresh(stack, player_ref)
    player_ref = player_ref or 'player001'
    local created = stack.create:create({
        player_ref = player_ref,
        player_save_scope = player_ref,
        command_id = 'cmd_new_save_1',
        save_seed = 424242,
        request_id = 'request_new_save_1',
    }, stack.invoke)
    assert.equal(created.ok, true, created.error and created.error.code)
    assert.equal(created.value.status, 'COMMITTED')
    return created.value
end

return {
    case('load confirmed absent when no slot 1 exists', function()
        local stack = build_stack()
        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session001',
            request_id = 'request_load_absent',
        }, stack.invoke)
        assert.equal(loaded.ok, true)
        assert.equal(loaded.value.mode, 'CONFIRMED_ABSENT')
        assert.equal(loaded.value.load_report.slots[1].fetch_status, 'CONFIRMED_ABSENT')
    end),

    case('create new save then load ready with absent data slots', function()
        local stack = build_stack()
        local created = create_fresh(stack)
        assert.equal(created.slot1_revision, 1)
        assert.equal(
            created.manifest.slot_revision_entries.slot_3_revision,
            0
        )
        assert.equal(
            created.manifest.slot_revision_entries.slot_3_checkpoint_id,
            SlotRevisionVector.ABSENT_CHECKPOINT_ID
        )

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_ready_1',
            request_id = 'request_load_ready_1',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.writable, true)
        assert.equal(loaded.value.player_save_scope, 'player001')
        assert.equal(loaded.value.save_seed, 424242)
        assert.equal(loaded.value.slot1_revision, 1)
        assert.equal(loaded.value.loaded_envelopes[1] ~= nil, true)
        assert.equal(loaded.value.loaded_envelopes[3], nil)
        assert.equal(loaded.value.committed_manifest_checkpoint, created.checkpoint_id)
    end),

    case('manifest-last checkpoint writes data then loads ready with slot 3/4/5', function()
        local stack = build_stack()
        local created = create_fresh(stack)

        local saved = stack.checkpoint:save({
            player_ref = 'player001',
            player_save_scope = 'player001',
            command_id = 'cmd_ckpt_1',
            request_id = 'request_ckpt_1',
            base_slot1_revision = created.slot1_revision,
            base_manifest = created.manifest,
            player_profile = created.player_profile,
            settings_profile = created.settings_profile,
            dirty_slots = {
                {
                    slot_id = 3,
                    expected_revision = 0,
                    payload = {
                        character_metadata = {
                            schema_version = 1,
                            revision = 1,
                        },
                        character_rows = {},
                        character_talent_rows = {},
                    },
                },
                {
                    slot_id = 4,
                    expected_revision = 0,
                    payload = {
                        economy_metadata = {
                            schema_version = 1,
                            economy_revision = 1,
                        },
                        currency_balance_rows = {
                            {
                                currency_id = 'currency_copper',
                                balance = 30,
                                account_revision = 1,
                            },
                        },
                    },
                },
                {
                    slot_id = 5,
                    expected_revision = 0,
                    payload = {
                        character_operation_metadata = {
                            schema_version = 1,
                            revision = 1,
                        },
                        character_operation_receipts = {},
                    },
                },
            },
        }, stack.invoke)
        assert.equal(saved.ok, true, saved.error and saved.error.code)
        assert.equal(saved.value.status, 'COMMITTED')
        assert.equal(saved.value.dirty_slot_count, 3)
        assert.equal(saved.value.slot1_revision, 2)
        assert.equal(saved.value.manifest.slot_revision_entries.slot_3_revision, 1)
        assert.equal(saved.value.manifest.slot_revision_entries.slot_4_revision, 1)
        assert.equal(saved.value.manifest.slot_revision_entries.slot_5_revision, 1)
        assert.equal(
            saved.value.manifest.checkpoint_id,
            saved.value.checkpoint_id
        )

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_ready_2',
            request_id = 'request_load_ready_2',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.slot1_revision, 2)
        assert.equal(loaded.value.loaded_envelopes[3].revision, 1)
        assert.equal(loaded.value.loaded_envelopes[4].revision, 1)
        assert.equal(loaded.value.loaded_envelopes[5].revision, 1)
        assert.equal(
            loaded.value.loaded_envelopes[4].payload.currency_balance_rows[1].balance,
            30
        )
        assert.equal(
            loaded.value.committed_manifest_checkpoint,
            saved.value.checkpoint_id
        )
    end),

    case('orphan data slot without manifest-last enters recovery required', function()
        local stack = build_stack()
        local created = create_fresh(stack)

        -- Simulate crash after data write, before Manifest-last: write slot 3
        -- directly with a new checkpoint that Manifest does not reference.
        local orphan_cp = stack.coordinator:allocate_checkpoint_id('checkpoint')
        local orphan_tx = stack.coordinator:allocate_transaction_id('orphan')
        assert.equal(orphan_cp.ok, true)
        assert.equal(orphan_tx.ok, true)
        local orphan_write = stack.coordinator:write_slots({
            player_ref = 'player001',
            checkpoint_id = orphan_cp.value,
            transaction_id = orphan_tx.value,
            request_id = 'request_orphan_data',
            slot_writes = {
                {
                    slot_id = 3,
                    expected_revision = 0,
                    payload = {
                        character_metadata = {
                            schema_version = 1,
                            revision = 9,
                        },
                        character_rows = {},
                    },
                },
            },
        }, stack.invoke)
        assert.equal(orphan_write.ok, true)
        assert.equal(orphan_write.value.status, 'COMMITTED')

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_orphan_1',
            request_id = 'request_load_orphan_1',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'RECOVERY_REQUIRED')
        assert.equal(loaded.value.writable, false)
        assert.equal(#loaded.value.orphan_slots, 1)
        assert.equal(loaded.value.orphan_slots[1], 3)
        assert.equal(
            loaded.value.committed_manifest_checkpoint,
            created.checkpoint_id
        )
        -- Slot 3 must not be adopted into loaded_envelopes.
        assert.equal(loaded.value.loaded_envelopes[3], nil)
    end),

    case('create rejects when slot 1 already exists', function()
        local stack = build_stack()
        create_fresh(stack)
        local again = stack.create:create({
            player_ref = 'player001',
            player_save_scope = 'player001',
            command_id = 'cmd_new_save_2',
            save_seed = 1,
            request_id = 'request_new_save_2',
        }, stack.invoke)
        assert.equal(again.ok, false)
        assert.equal(again.error.code, 'SAVE_EXISTENCE_UNKNOWN')
        assert.equal(again.error.details.reason, 'SLOT1_ALREADY_PRESENT')
    end),

    case('corrupt slot 1 checksum fails closed', function()
        local stack = build_stack()
        create_fresh(stack)
        local snapshot = stack.store:get_committed_snapshot()
        local envelope = snapshot.player001[1]
        -- Tamper only the stored checksum while leaving payload bytes intact.
        envelope.payload_checksum = string.rep('f', 64)
        stack.store:force_commit_envelope('player001', 1, envelope)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_corrupt_1',
            request_id = 'request_load_corrupt_1',
        }, stack.invoke)
        assert.equal(loaded.ok, false)
        assert.equal(loaded.error.code, 'SAVE_CORRUPT')
    end),
}
