local Harness = require 'wzx.tests.harness'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'
local SaveStore = require 'wzx.application.ports.save_store'

local case = Harness.case
local assert = Harness.assert

local function build_coordinator()
    local store = MemorySaveStore.new()
    local bound = SaveCoordinator.bind({ save_store = store })
    assert.equal(bound.ok, true)
    assert.equal(store:get_contract(), SaveStore)
    return bound.value, SaveCoordinator.fake_invoke(store), store
end

return {
    case('payload checksum is deterministic and envelope build seals owner fingerprint', function()
        local first = SaveEnvelope.compute_payload_checksum({
            marker = 'alpha',
            rows = { 1, 2, 3 },
        })
        local second = SaveEnvelope.compute_payload_checksum({
            rows = { 1, 2, 3 },
            marker = 'alpha',
        })
        assert.equal(first.ok, true)
        assert.equal(second.ok, true)
        assert.equal(first.value, second.value)

        local envelope = SaveEnvelope.build({
            player_save_scope = 'player001',
            revision = 1,
            checkpoint_id = 'checkpoint:1',
            payload = { section = { value = 7 } },
        })
        assert.equal(envelope.ok, true)
        assert.equal(envelope.value.revision, 1)
        assert.equal(
            envelope.value.owner_fingerprint:sub(1, 9),
            'owner_v1_'
        )
        assert.equal(#envelope.value.payload_checksum, 64)
        local rebuilt = SaveEnvelope.compute_payload_checksum(
            envelope.value.payload
        )
        assert.equal(rebuilt.ok, true)
        assert.equal(envelope.value.payload_checksum, rebuilt.value)
    end),

    case('write slots stages then commits and load returns the envelope', function()
        local coordinator, invoke = build_coordinator()
        local transaction = coordinator:allocate_transaction_id('savetx')
        local checkpoint = coordinator:allocate_checkpoint_id('checkpoint')
        assert.equal(transaction.ok, true)
        assert.equal(checkpoint.ok, true)

        local written = coordinator:write_slots({
            player_ref = 'player001',
            checkpoint_id = checkpoint.value,
            transaction_id = transaction.value,
            request_id = 'request_save_1',
            slot_writes = {
                {
                    slot_id = 3,
                    expected_revision = 0,
                    payload = {
                        character_metadata = { schema_version = 1, revision = 1 },
                        character_rows = {},
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
        }, invoke)
        assert.equal(written.ok, true, written.error and written.error.code)
        assert.equal(written.value.status, 'COMMITTED')
        assert.equal(#written.value.slot_results, 2)
        assert.equal(written.value.slot_results[1].slot_id, 3)
        assert.equal(written.value.slot_results[2].slot_id, 5)

        local loaded = coordinator:load_slot({
            player_ref = 'player001',
            slot_id = 3,
            request_id = 'request_load_3',
        }, invoke)
        assert.equal(loaded.ok, true)
        assert.equal(loaded.value.revision, 1)
        assert.equal(loaded.value.checkpoint_id, checkpoint.value)
        assert.equal(
            loaded.value.dto.payload.character_metadata.revision,
            1
        )
    end),

    case('revision conflict rejects stage without overwriting authority', function()
        local coordinator, invoke = build_coordinator()
        local first_tx = coordinator:allocate_transaction_id('savetx')
        local first_cp = coordinator:allocate_checkpoint_id('checkpoint')
        local first = coordinator:write_slots({
            player_ref = 'player001',
            checkpoint_id = first_cp.value,
            transaction_id = first_tx.value,
            request_id = 'request_save_1',
            slot_writes = {
                {
                    slot_id = 3,
                    expected_revision = 0,
                    payload = { marker = 'v1' },
                },
            },
        }, invoke)
        assert.equal(first.ok, true)

        local second_tx = coordinator:allocate_transaction_id('savetx')
        local second_cp = coordinator:allocate_checkpoint_id('checkpoint')
        local conflict = coordinator:write_slots({
            player_ref = 'player001',
            checkpoint_id = second_cp.value,
            transaction_id = second_tx.value,
            request_id = 'request_save_2',
            slot_writes = {
                {
                    slot_id = 3,
                    expected_revision = 0,
                    payload = { marker = 'stale' },
                },
            },
        }, invoke)
        assert.equal(conflict.ok, false)
        assert.equal(conflict.error.code, 'SAVE_REVISION_CONFLICT')

        local loaded = coordinator:load_slot({
            player_ref = 'player001',
            slot_id = 3,
            request_id = 'request_load_check',
        }, invoke)
        assert.equal(loaded.ok, true)
        assert.equal(loaded.value.dto.payload.marker, 'v1')
        assert.equal(loaded.value.revision, 1)
    end),

    case('reconcile confirms committed slots without re-writing', function()
        local coordinator, invoke, store = build_coordinator()
        local transaction = coordinator:allocate_transaction_id('savetx')
        local checkpoint = coordinator:allocate_checkpoint_id('checkpoint')
        local written = coordinator:write_slots({
            player_ref = 'player001',
            checkpoint_id = checkpoint.value,
            transaction_id = transaction.value,
            request_id = 'request_save_1',
            slot_writes = {
                {
                    slot_id = 3,
                    expected_revision = 0,
                    payload = { marker = 'ok' },
                },
            },
        }, invoke)
        assert.equal(written.ok, true)

        local reconciled = coordinator:reconcile_write(
            written.value.pending,
            invoke,
            { request_id = 'request_reconcile_1' }
        )
        assert.equal(reconciled.ok, true)
        assert.equal(reconciled.value.status, 'COMMITTED')
        assert.equal(reconciled.value.reconciled, true)
        assert.equal(reconciled.value.slot_results[1].target_revision, 1)

        local snapshot = store:get_committed_snapshot()
        assert.equal(snapshot.player001[3].payload.marker, 'ok')
    end),

    case('missing slot load is SAVE_NOT_FOUND', function()
        local coordinator, invoke = build_coordinator()
        local missing = coordinator:load_slot({
            player_ref = 'player001',
            slot_id = 3,
            request_id = 'request_load_missing',
        }, invoke)
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'SAVE_NOT_FOUND')
    end),
}
