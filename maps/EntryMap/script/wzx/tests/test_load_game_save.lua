local Harness = require 'wzx.tests.harness'
local CreateNewSave = require 'wzx.application.use_cases.save.create_new_save'
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local RecoverOrphanCheckpoint = require 'wzx.application.use_cases.save.recover_orphan_checkpoint'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local SaveCheckpoint = require 'wzx.application.use_cases.save.save_checkpoint'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'
local SlotRevisionVector = require 'wzx.domain.save.slot_revision_vector'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local PendingCheckpointIntent = require 'wzx.domain.save.pending_checkpoint_intent'
local OrphanForwardRecovery = require 'wzx.domain.save.orphan_forward_recovery'

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

    case('normalize keeps landing when slot2 receipt matches slot5 recovery', function()
        local stack = build_stack()
        local created = create_fresh(stack)
        local landing_receipt = 'receipt_traversal_landing_v1_' .. string.rep('a', 64)
        local checkpoint = stack.coordinator:allocate_checkpoint_id('checkpoint')
        assert.equal(checkpoint.ok, true)

        local saved = stack.checkpoint:save({
            player_ref = 'player001',
            player_save_scope = 'player001',
            command_id = 'cmd_ckpt_landing_match',
            request_id = 'request_ckpt_landing_match',
            checkpoint_id = checkpoint.value,
            base_slot1_revision = created.slot1_revision,
            base_manifest = created.manifest,
            player_profile = created.player_profile,
            settings_profile = created.settings_profile,
            dirty_slots = {
                {
                    slot_id = 2,
                    expected_revision = 0,
                    payload = {
                        world_metadata = {
                            schema_version = 1,
                            world_revision = 2,
                        },
                        world_position = {
                            area_id = 'area_ridge',
                            location_id = 'location_ridge',
                            current_marker_id = 'marker_b1',
                            last_safe_marker_id = 'marker_b1',
                            last_landing_receipt_id = landing_receipt,
                            current_cell_id = 'traversal_cell_b1',
                            facing_octant = 0,
                        },
                        world_discovered_locations = {},
                        world_flags = {},
                        world_event_receipts = {},
                        world_interactable_states = {},
                    },
                },
                {
                    slot_id = 5,
                    expected_revision = 0,
                    payload = {
                        save_recovery_transactions = {
                            {
                                transaction_id = 'recovery_tx_landing_1',
                                transaction_type = 'TRAVERSAL_LANDING',
                                state = 'COMMITTED',
                                business_receipt_id = landing_receipt,
                                target_checkpoint_id = checkpoint.value,
                                owner_slot_id = 2,
                                owner_section_key = 'world_position',
                                command_id = 'cmd_jump_match',
                                outcome_digest = string.rep('b', 64),
                                retry_count = 0,
                            },
                        },
                    },
                },
            },
        }, stack.invoke)
        assert.equal(saved.ok, true, saved.error and saved.error.code)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_norm_match',
            request_id = 'request_load_norm_match',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.transient_world.action, 'KEEP_LANDING')
        assert.equal(loaded.value.transient_world.changed, false)
        assert.equal(loaded.value.transient_world.traversal_session, 'DISCARDED')
        local position = loaded.value.loaded_envelopes[2].payload.world_position
        assert.equal(position.last_landing_receipt_id, landing_receipt)
        assert.equal(position.current_marker_id, 'marker_b1')
        assert.equal(position.current_cell_id, 'traversal_cell_b1')
    end),

    case('normalize snaps to last_safe when landing evidence is missing', function()
        local stack = build_stack()
        local created = create_fresh(stack)
        local landing_receipt = 'receipt_traversal_landing_v1_' .. string.rep('c', 64)

        local saved = stack.checkpoint:save({
            player_ref = 'player001',
            player_save_scope = 'player001',
            command_id = 'cmd_ckpt_landing_orphan',
            request_id = 'request_ckpt_landing_orphan',
            base_slot1_revision = created.slot1_revision,
            base_manifest = created.manifest,
            player_profile = created.player_profile,
            settings_profile = created.settings_profile,
            dirty_slots = {
                {
                    slot_id = 2,
                    expected_revision = 0,
                    payload = {
                        world_metadata = {
                            schema_version = 1,
                            world_revision = 3,
                        },
                        world_position = {
                            area_id = 'area_ridge',
                            location_id = 'location_ridge',
                            current_marker_id = 'marker_air_temp',
                            last_safe_marker_id = 'marker_a1',
                            last_landing_receipt_id = landing_receipt,
                            current_cell_id = 'traversal_cell_midair',
                            facing_octant = 2,
                        },
                        world_discovered_locations = {},
                        world_flags = {},
                        world_event_receipts = {},
                        world_interactable_states = {},
                    },
                },
                -- Slot 5 intentionally has no recovery row for this receipt.
                {
                    slot_id = 5,
                    expected_revision = 0,
                    payload = {
                        save_recovery_transactions = {},
                    },
                },
            },
        }, stack.invoke)
        assert.equal(saved.ok, true, saved.error and saved.error.code)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_norm_snap',
            request_id = 'request_load_norm_snap',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.transient_world.action, 'SNAP_TO_LAST_SAFE')
        assert.equal(loaded.value.transient_world.changed, true)
        assert.equal(
            loaded.value.transient_world.evidence_status,
            'RECEIPT_WITHOUT_RECOVERY_ROW'
        )
        assert.equal(
            loaded.value.transient_world.cleared_landing_receipt_id,
            landing_receipt
        )
        local position = loaded.value.loaded_envelopes[2].payload.world_position
        assert.equal(position.current_marker_id, 'marker_a1')
        assert.equal(position.last_safe_marker_id, 'marker_a1')
        assert.equal(position.last_landing_receipt_id, nil)
        assert.equal(position.current_cell_id, nil)
        assert.equal(position.facing_octant, 2)
    end),

    case('checkpoint auto-writes pending intent when only slot 3 is dirty', function()
        local stack = build_stack()
        local created = create_fresh(stack)
        local saved = stack.checkpoint:save({
            player_ref = 'player001',
            player_save_scope = 'player001',
            command_id = 'cmd_ckpt_auto_intent',
            request_id = 'request_ckpt_auto_intent',
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
                    },
                },
            },
        }, stack.invoke)
        assert.equal(saved.ok, true, saved.error and saved.error.code)
        assert.equal(saved.value.pending_intent_written, true)
        -- Slot 5 is co-written as the intent carrier.
        assert.equal(saved.value.dirty_slot_count, 2)
        assert.equal(saved.value.manifest.slot_revision_entries.slot_5_revision, 1)
        assert.equal(
            saved.value.pending_intent.target_checkpoint_id,
            saved.value.checkpoint_id
        )
        assert.equal(saved.value.pending_intent.slot_3_dirty, true)
        assert.equal(saved.value.pending_intent.slot_5_dirty, true)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_auto_intent',
            request_id = 'request_load_auto_intent',
        }, stack.invoke)
        assert.equal(loaded.ok, true)
        assert.equal(loaded.value.mode, 'READY')
        local intent = loaded.value.loaded_envelopes[5].payload.save_pending_checkpoint
        assert.equal(intent ~= nil, true)
        assert.equal(intent.command_id, 'cmd_ckpt_auto_intent')
        assert.equal(intent.state, 'DATA_WRITTEN')
    end),

    case('checkpoint crash before manifest recovers via auto pending intent', function()
        local stack = build_stack()
        local created = create_fresh(stack)
        local snapshot = stack.store:get_committed_snapshot()
        local old_slot1 = snapshot.player001[1]
        -- Deep-ish copy of the committed slot-1 envelope for crash rollback.
        local rolled_back = {
            schema_version = old_slot1.schema_version,
            revision = old_slot1.revision,
            checkpoint_id = old_slot1.checkpoint_id,
            content_version = old_slot1.content_version,
            owner_fingerprint = old_slot1.owner_fingerprint,
            payload_checksum = old_slot1.payload_checksum,
            written_at = old_slot1.written_at,
            payload = old_slot1.payload,
        }

        local saved = stack.checkpoint:save({
            player_ref = 'player001',
            player_save_scope = 'player001',
            command_id = 'cmd_ckpt_crash',
            request_id = 'request_ckpt_crash',
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
                    },
                },
            },
        }, stack.invoke)
        assert.equal(saved.ok, true, saved.error and saved.error.code)
        assert.equal(saved.value.pending_intent_written, true)

        -- Simulate Manifest-last crash: data slots kept, slot 1 rolled back.
        stack.store:force_commit_envelope('player001', 1, rolled_back)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_crash_forward',
            request_id = 'request_load_crash_forward',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(
            loaded.value.mode,
            'READY',
            loaded.value.orphan_forward and loaded.value.orphan_forward.reason
        )
        assert.equal(loaded.value.committed_manifest_checkpoint, saved.value.checkpoint_id)
        assert.equal(loaded.value.manifest.recovery_epoch, 1)
        assert.equal(loaded.value.loaded_envelopes[3] ~= nil, true)
        assert.equal(loaded.value.loaded_envelopes[5] ~= nil, true)
        assert.equal(
            loaded.value.load_report.orphan_forward.action,
            'FORWARD_MANIFEST'
        )
    end),

    case('orphan without pending intent stays recovery required', function()
        local stack = build_stack()
        local created = create_fresh(stack)
        local orphan_cp = stack.coordinator:allocate_checkpoint_id('checkpoint')
        assert.equal(orphan_cp.ok, true)
        local orphan_tx = stack.coordinator:allocate_transaction_id('orphan')
        assert.equal(orphan_tx.ok, true)
        local written = stack.coordinator:write_slots({
            player_ref = 'player001',
            checkpoint_id = orphan_cp.value,
            transaction_id = orphan_tx.value,
            request_id = 'request_orphan_no_intent',
            slot_writes = {
                {
                    slot_id = 3,
                    expected_revision = 0,
                    payload = {
                        character_metadata = {
                            schema_version = 1,
                            revision = 1,
                        },
                        character_rows = {},
                    },
                },
            },
        }, stack.invoke)
        assert.equal(written.ok, true)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_orphan_no_intent',
            request_id = 'request_load_orphan_no_intent',
        }, stack.invoke)
        assert.equal(loaded.ok, true)
        assert.equal(loaded.value.mode, 'RECOVERY_REQUIRED')
        assert.equal(loaded.value.orphan_forward.reason, 'PENDING_INTENT_MISSING')
        assert.equal(
            loaded.value.committed_manifest_checkpoint,
            created.checkpoint_id
        )
    end),

    case('orphan with matching pending intent forwards manifest-last on load', function()
        local stack = build_stack()
        local created = create_fresh(stack)
        local target_cp = stack.coordinator:allocate_checkpoint_id('checkpoint')
        assert.equal(target_cp.ok, true)

        local slot3_payload = {
            character_metadata = {
                schema_version = 1,
                revision = 1,
            },
            character_rows = {},
        }
        local slot3_envelope = SaveEnvelope.build({
            player_save_scope = 'player001',
            revision = 1,
            checkpoint_id = target_cp.value,
            content_version = 'content-v1',
            payload = slot3_payload,
            schema_version = 1,
        })
        assert.equal(slot3_envelope.ok, true, slot3_envelope.error and slot3_envelope.error.code)

        local intent = PendingCheckpointIntent.build({
            command_id = 'cmd_orphan_forward_1',
            target_checkpoint_id = target_cp.value,
            base_manifest_checkpoint_id = created.checkpoint_id,
            base_slot1_revision = created.slot1_revision,
            state = 'DATA_WRITTEN',
            dirty_slot_proofs = {
                {
                    slot_id = 3,
                    schema_version = 1,
                    revision = 1,
                    payload_checksum = slot3_envelope.value.payload_checksum,
                },
                {
                    slot_id = 5,
                    schema_version = 1,
                    revision = 1,
                    -- carrier: omit checksum, bind from observed envelope
                },
            },
        })
        assert.equal(intent.ok, true, intent.error and intent.error.details and intent.error.details.reason)
        local intent_section = PendingCheckpointIntent.to_section(intent.value)
        assert.equal(intent_section.ok, true)

        local slot5_payload = {
            save_pending_checkpoint = intent_section.value,
        }

        local data_tx = stack.coordinator:allocate_transaction_id('orphan_data')
        assert.equal(data_tx.ok, true)
        local written = stack.coordinator:write_slots({
            player_ref = 'player001',
            checkpoint_id = target_cp.value,
            transaction_id = data_tx.value,
            request_id = 'request_orphan_with_intent',
            slot_writes = {
                {
                    slot_id = 3,
                    expected_revision = 0,
                    payload = slot3_payload,
                },
                {
                    slot_id = 5,
                    expected_revision = 0,
                    payload = slot5_payload,
                },
            },
        }, stack.invoke)
        assert.equal(written.ok, true, written.error and written.error.code)
        assert.equal(written.value.status, 'COMMITTED')

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_orphan_forward',
            request_id = 'request_load_orphan_forward',
        }, stack.invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY', loaded.value.orphan_forward and loaded.value.orphan_forward.reason)
        assert.equal(loaded.value.writable, true)
        assert.equal(loaded.value.committed_manifest_checkpoint, target_cp.value)
        assert.equal(loaded.value.manifest.checkpoint_id, target_cp.value)
        assert.equal(loaded.value.manifest.recovery_epoch, 1)
        assert.equal(loaded.value.loaded_envelopes[3] ~= nil, true)
        assert.equal(loaded.value.loaded_envelopes[5] ~= nil, true)
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_3_revision,
            1
        )
        assert.equal(
            loaded.value.manifest.slot_revision_entries.slot_3_checkpoint_id,
            target_cp.value
        )
        assert.equal(
            loaded.value.load_report.orphan_forward.action,
            'FORWARD_MANIFEST'
        )

        -- Second load is clean READY with no recovery.
        local reloaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_orphan_forward_2',
            request_id = 'request_load_orphan_forward_2',
        }, stack.invoke)
        assert.equal(reloaded.ok, true)
        assert.equal(reloaded.value.mode, 'READY')
        assert.equal(reloaded.value.committed_manifest_checkpoint, target_cp.value)
        assert.equal(reloaded.value.load_report.orphan_forward, nil)
    end),

    case('recover orphan checkpoint use case forwards when intent matches', function()
        local stack = build_stack()
        local created = create_fresh(stack)
        local recover = RecoverOrphanCheckpoint.bind({
            coordinator = stack.coordinator,
        })
        assert.equal(recover.ok, true)

        local target_cp = stack.coordinator:allocate_checkpoint_id('checkpoint')
        assert.equal(target_cp.ok, true)
        local slot3_payload = {
            character_metadata = { schema_version = 1, revision = 1 },
            character_rows = {},
        }
        local slot3_envelope = SaveEnvelope.build({
            player_save_scope = 'player001',
            revision = 1,
            checkpoint_id = target_cp.value,
            content_version = 'content-v1',
            payload = slot3_payload,
        })
        assert.equal(slot3_envelope.ok, true)
        local intent = PendingCheckpointIntent.build({
            command_id = 'cmd_recover_explicit',
            target_checkpoint_id = target_cp.value,
            base_manifest_checkpoint_id = created.checkpoint_id,
            base_slot1_revision = created.slot1_revision,
            dirty_slot_proofs = {
                {
                    slot_id = 3,
                    schema_version = 1,
                    revision = 1,
                    payload_checksum = slot3_envelope.value.payload_checksum,
                },
                {
                    slot_id = 5,
                    schema_version = 1,
                    revision = 1,
                },
            },
        })
        assert.equal(intent.ok, true)
        local intent_section = PendingCheckpointIntent.to_section(intent.value)
        assert.equal(intent_section.ok, true)
        local data_tx = stack.coordinator:allocate_transaction_id('orphan_data2')
        local written = stack.coordinator:write_slots({
            player_ref = 'player001',
            checkpoint_id = target_cp.value,
            transaction_id = data_tx.value,
            request_id = 'request_orphan_explicit',
            slot_writes = {
                { slot_id = 3, expected_revision = 0, payload = slot3_payload },
                {
                    slot_id = 5,
                    expected_revision = 0,
                    payload = {
                        save_pending_checkpoint = intent_section.value,
                    },
                },
            },
        }, stack.invoke)
        assert.equal(written.ok, true)

        local recovered = recover.value:recover({
            player_ref = 'player001',
            player_save_scope = 'player001',
            request_id = 'request_recover_explicit',
        }, stack.invoke)
        assert.equal(recovered.ok, true, recovered.error and recovered.error.code)
        assert.equal(recovered.value.action, 'FORWARD_MANIFEST')
        assert.equal(recovered.value.checkpoint_id, target_cp.value)
        assert.equal(recovered.value.recovery_epoch, 1)

        local loaded = stack.load:load({
            player_ref = 'player001',
            session_instance_id = 'session_after_recover',
            request_id = 'request_load_after_recover',
        }, stack.invoke)
        assert.equal(loaded.ok, true)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(loaded.value.committed_manifest_checkpoint, target_cp.value)
    end),

    case('orphan forward evaluator rejects partial dirty proofs', function()
        local intent = PendingCheckpointIntent.build({
            command_id = 'cmd_partial',
            target_checkpoint_id = 'checkpoint_target_1',
            base_manifest_checkpoint_id = 'checkpoint_base_1',
            base_slot1_revision = 1,
            dirty_slot_proofs = {
                {
                    slot_id = 3,
                    schema_version = 1,
                    revision = 1,
                    payload_checksum = string.rep('a', 64),
                },
                {
                    slot_id = 4,
                    schema_version = 1,
                    revision = 1,
                    payload_checksum = string.rep('b', 64),
                },
            },
        })
        assert.equal(intent.ok, true)
        local evaluated = OrphanForwardRecovery.evaluate({
            manifest = {
                save_format_version = 1,
                created_revision = 1,
                slot_revision_entries = SlotRevisionVector.empty_entries(),
                checkpoint_id = 'checkpoint_base_1',
                save_seed = 1,
                feature_flag_snapshot = {},
                recovery_epoch = 0,
            },
            intent = intent.value,
            observations = {
                [3] = {
                    slot_id = 3,
                    revision = 1,
                    checkpoint_id = 'checkpoint_target_1',
                    payload_checksum = string.rep('a', 64),
                    schema_version = 1,
                },
                -- slot 4 intentionally missing
            },
        })
        assert.equal(evaluated.ok, true)
        assert.equal(evaluated.value.action, 'RECOVERY_REQUIRED')
        assert.equal(evaluated.value.reason, 'DIRTY_SLOT_MISSING')
        assert.equal(evaluated.value.slot_id, 4)
    end),
}
