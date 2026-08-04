local Harness = require 'wzx.tests.harness'
local CharacterReceiptCodec = require 'wzx.domain.character.character_receipt_codec'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'

local case = Harness.case
local assert = Harness.assert

local HASH_A = string.rep('a', 64)
local HASH_B = string.rep('b', 64)
local HASH_C = string.rep('c', 64)
local OWNER = 'owner_v1_' .. string.rep('c', 64)
local MAX_SAFE_INTEGER = 9007199254740991

local function codec(maximum_rows)
    local bound = CharacterReceiptCodec.bind({
        max_receipt_rows = maximum_rows or 16,
    })
    assert.equal(bound.ok, true)
    return bound.value
end

local function copy(value)
    if type(value) ~= 'table' then
        return value
    end
    local result = {}
    local key
    local child
    for key, child in pairs(value) do
        result[key] = copy(child)
    end
    return result
end

local function receipt_id(index)
    return 'creation:character:' .. tostring(index)
end

local function row(index, status, options)
    options = options or {}
    local id = receipt_id(index)
    local transport = CharacterReceiptCodec.derive_transport_request_key(id)
    assert.equal(transport.ok, true)

    local changed = options.changed
    if changed == nil then
        changed = true
    end
    local expected_revision = options.expected_revision or 0
    local value = {
        receipt_id = id,
        transaction_id = options.transaction_id or 'character_tx_' .. tostring(index),
        operation_type = options.operation_type or 'CREATE_OWNED_CHARACTER',
        payload_hash = HASH_A,
        expected_result_digest = options.expected_result_digest or HASH_B,
        transport_request_key = transport.value,
        status = status,
        expected_character_save_revision = expected_revision,
        target_character_save_revision = expected_revision + (changed and 1 or 0),
        character_state_changed = changed,
        receipt_revision = options.receipt_revision or index,
    }
    if status == 'COMMITTED'
        or status == 'FAILED_BEFORE_APPLY'
        or status == 'COMPENSATED'
    then
        value.result_schema_version = 1
        value.result_digest = HASH_B
        value.result_ref = 'character_result:' .. tostring(index)
    end
    return value
end

local function bundle(rows, revision)
    return {
        character_operation_metadata = {
            schema_version = 1,
            revision = revision or 10,
        },
        character_operation_receipts = rows or {},
    }
end

local function full_status_bundle()
    return bundle({
        row(1, 'PREPARED'),
        row(2, 'APPLYING', {
            operation_type = 'GRANT_CHARACTER_EXPERIENCE',
        }),
        row(3, 'COMMITTED', {
            operation_type = 'RENAME_PROTAGONIST',
        }),
        row(4, 'RECOVERY_REQUIRED'),
        row(5, 'FAILED_BEFORE_APPLY', { changed = false }),
        row(6, 'COMPENSATED'),
    }, 10)
end

local function save_envelope(payload)
    return {
        schema_version = 1,
        revision = 1,
        checkpoint_id = 'checkpoint:character:1',
        content_version = 'content-v1',
        owner_fingerprint = OWNER,
        payload_checksum = HASH_A,
        payload = payload,
    }
end

return {
    case('receipt-derived transport identity matches its golden vector', function()
        local transport = CharacterReceiptCodec.derive_transport_request_key(
            'creation:character:1'
        )
        assert.equal(transport.ok, true)
        assert.equal(
            transport.value,
            'a5d3ea3cafc990ba904c36053e87a2e17ff22792d8e685a800323e591e2d9437'
        )
        assert.is_nil(CharacterReceiptCodec.derive_transaction_id)

        assert.error_reason(
            CharacterReceiptCodec.derive_transport_request_key('bad::receipt'),
            'RECEIPT_ID_INVALID'
        )
    end),

    case('bound codec is read-only and rejects malformed limits', function()
        local bound = CharacterReceiptCodec.bind({ max_receipt_rows = 4 })
        assert.equal(bound.ok, true)
        assert.equal(getmetatable(bound.value), false)
        assert.throws(function()
            bound.value.validate_current = function() end
        end, 'read-only')

        assert.error_reason(
            CharacterReceiptCodec.bind({ max_receipt_rows = 0 }),
            'MAX_RECEIPT_ROWS_INVALID'
        )
        assert.error_reason(
            CharacterReceiptCodec.bind({ max_receipt_rows = 1, extra = true }),
            'UNKNOWN_FIELD'
        )
        assert.error_reason(
            CharacterReceiptCodec.bind(setmetatable(
                { max_receipt_rows = 1 },
                { __metatable = 'locked' }
            )),
            'PLAIN_TABLE_REQUIRED'
        )
    end),

    case('all receipt states validate in a three-level SaveEnvelope payload', function()
        local authority = codec()
        local source = full_status_bundle()
        local validated = authority:validate_current(source)
        assert.equal(validated.ok, true)
        assert.equal(#validated.value.character_operation_receipts, 6)
        assert.equal(
            validated.value.character_operation_receipts[5].character_state_changed,
            false
        )
        local payload = copy(validated.value)
        payload.other_owner_metadata = {
            schema_version = 1,
            revision = 7,
        }
        assert.equal(SaveEnvelope.validate(save_envelope(payload)).ok, true)
        assert.equal(SaveEnvelope.copy(save_envelope(payload)).ok, true)

        local wrapped = save_envelope({
            character_operations = validated.value,
        })
        local rejected = SaveEnvelope.validate(wrapped)
        assert.error_reason(rejected, 'PAYLOAD_INVALID')
        assert.equal(
            rejected.error.details.cause.details.reason,
            'MAXIMUM_TABLE_DEPTH_EXCEEDED'
        )
    end),

    case('validation and migration return isolated deterministic copies', function()
        local authority = codec()
        local source = full_status_bundle()
        local validated = authority:validate_current(source)
        assert.equal(validated.ok, true)
        assert.truthy(validated.value ~= source)
        assert.truthy(
            validated.value.character_operation_metadata
                ~= source.character_operation_metadata
        )
        assert.truthy(
            validated.value.character_operation_receipts
                ~= source.character_operation_receipts
        )
        assert.truthy(
            validated.value.character_operation_receipts[1]
                ~= source.character_operation_receipts[1]
        )

        source.character_operation_receipts[1].payload_hash = HASH_B
        assert.equal(
            validated.value.character_operation_receipts[1].payload_hash,
            HASH_A
        )
        validated.value.character_operation_receipts[1].status = 'MUTATED'
        assert.equal(source.character_operation_receipts[1].status, 'PREPARED')

        source = full_status_bundle()
        local migrated = authority:migrate_to_current(source)
        assert.equal(migrated.ok, true)
        assert.deep_equal(migrated.value.bundle, source)
        assert.deep_equal(migrated.value.report, {
            from_version = 1,
            to_version = 1,
            changed = false,
            applied_migration_ids = {},
            diagnostics = {},
        })
        local repeated = authority:migrate_to_current(migrated.value.bundle)
        assert.equal(repeated.ok, true)
        assert.deep_equal(repeated.value, migrated.value)
        migrated.value.bundle.character_operation_metadata.revision = 99
        assert.equal(source.character_operation_metadata.revision, 10)
    end),

    case('bundle metadata and rows are exact and future versions fail closed', function()
        local authority = codec()
        local source = full_status_bundle()
        source.extra = true
        assert.error_reason(authority:validate_current(source), 'UNKNOWN_FIELD')

        source = full_status_bundle()
        source.character_operation_metadata.extra = true
        assert.error_reason(authority:validate_current(source), 'UNKNOWN_FIELD')

        source = full_status_bundle()
        source.character_operation_receipts[1].extra = true
        assert.error_reason(authority:validate_current(source), 'UNKNOWN_FIELD')

        source = full_status_bundle()
        source.character_operation_receipts[1].payload_hash = nil
        assert.error_reason(authority:validate_current(source), 'FIELD_REQUIRED')

        source = full_status_bundle()
        source.character_operation_metadata.schema_version = 2
        assert.error_code(
            authority:migrate_to_current(source),
            'CHARACTER_RECEIPT_VERSION_UNSUPPORTED'
        )

        local invalid_versions = {
            0,
            1.5,
            '1',
            false,
        }
        local index
        for index = 1, #invalid_versions do
            source = full_status_bundle()
            source.character_operation_metadata.schema_version = invalid_versions[index]
            assert.error_code(
                authority:validate_current(source),
                'CHARACTER_RECEIPT_VERSION_UNSUPPORTED'
            )
        end
        source = full_status_bundle()
        source.character_operation_metadata.schema_version = nil
        assert.error_code(
            authority:validate_current(source),
            'CHARACTER_RECEIPT_VERSION_UNSUPPORTED'
        )

        source = full_status_bundle()
        source.character_operation_metadata.schema_version = function() end
        local unsupported = authority:validate_current(source)
        assert.error_code(unsupported, 'CHARACTER_RECEIPT_VERSION_UNSUPPORTED')
        assert.equal(unsupported.error.details.actual_type, 'function')
        assert.is_nil(unsupported.error.details.actual)

        local calls = 0
        local hostile_version = setmetatable({}, {
            __index = function()
                calls = calls + 1
                error('hostile schema version invoked')
            end,
            __metatable = 'locked-hostile-version',
        })
        source = full_status_bundle()
        source.character_operation_metadata.schema_version = hostile_version
        unsupported = authority:validate_current(source)
        assert.error_code(unsupported, 'CHARACTER_RECEIPT_VERSION_UNSUPPORTED')
        assert.equal(unsupported.error.details.actual_type, 'table')
        assert.is_nil(unsupported.error.details.actual)
        assert.equal(calls, 0)
    end),

    case('row limits and dense array shape fail closed', function()
        local authority = codec(2)
        assert.error_code(
            authority:validate_current(bundle({
                row(1, 'PREPARED'),
                row(2, 'APPLYING'),
                row(3, 'COMMITTED'),
            }, 4)),
            'CHARACTER_RECEIPT_LIMIT_EXCEEDED'
        )

        local sparse = {
            [1] = row(1, 'PREPARED'),
            [3] = row(3, 'COMMITTED'),
        }
        assert.error_code(
            codec(4):validate_current(bundle(sparse, 4)),
            'CHARACTER_RECEIPT_INVALID'
        )

        local mixed = { row(1, 'PREPARED') }
        mixed.named = row(2, 'APPLYING')
        assert.error_reason(
            codec(4):validate_current(bundle(mixed, 4)),
            'RECEIPT_ROWS_DENSE_ARRAY_REQUIRED'
        )
    end),

    case('hostile metatables are rejected without invoking metamethods', function()
        local authority = codec()
        local calls = 0
        local hostile = {
            __index = function()
                calls = calls + 1
                error('hostile index invoked')
            end,
            __pairs = function()
                calls = calls + 1
                error('hostile pairs invoked')
            end,
            __len = function()
                calls = calls + 1
                error('hostile length invoked')
            end,
            __metatable = 'locked-hostile-metatable',
        }

        local source = setmetatable(full_status_bundle(), hostile)
        assert.error_reason(authority:validate_current(source), 'PLAIN_TABLE_REQUIRED')
        assert.equal(calls, 0)

        source = full_status_bundle()
        setmetatable(source.character_operation_metadata, hostile)
        assert.error_reason(authority:validate_current(source), 'PLAIN_TABLE_REQUIRED')
        assert.equal(calls, 0)

        source = full_status_bundle()
        setmetatable(source.character_operation_receipts, hostile)
        assert.error_reason(
            authority:validate_current(source),
            'RECEIPT_ROWS_PLAIN_ARRAY_REQUIRED'
        )
        assert.equal(calls, 0)

        source = full_status_bundle()
        setmetatable(source.character_operation_receipts[1], hostile)
        assert.error_reason(authority:validate_current(source), 'PLAIN_TABLE_REQUIRED')
        assert.equal(calls, 0)
    end),

    case('receipt identities and bytewise ordering are authoritative', function()
        local authority = codec()
        local source = bundle({
            row(2, 'APPLYING'),
            row(1, 'PREPARED'),
        }, 4)
        assert.error_reason(authority:validate_current(source), 'RECEIPT_ORDER_INVALID')

        source = bundle({
            row(1, 'PREPARED'),
            copy(row(1, 'PREPARED')),
        }, 4)
        assert.error_reason(authority:validate_current(source), 'RECEIPT_ORDER_INVALID')

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].transport_request_key = HASH_B
        assert.error_reason(
            authority:validate_current(source),
            'TRANSPORT_REQUEST_KEY_MISMATCH'
        )

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].transaction_id = 'character_tx:wrong'
        assert.error_reason(
            authority:validate_current(source),
            'TRANSACTION_ID_INVALID'
        )

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].transaction_id = string.rep('x', 65)
        assert.error_reason(
            authority:validate_current(source),
            'TRANSACTION_ID_INVALID'
        )

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].receipt_id = 'receipt_001'
        source.character_operation_receipts[1].transaction_id = 'receipt_001'
        source.character_operation_receipts[1].transport_request_key =
            CharacterReceiptCodec.derive_transport_request_key('receipt_001').value
        assert.error_reason(
            authority:validate_current(source),
            'TRANSACTION_IDENTITY_REUSED'
        )

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].transaction_id =
            source.character_operation_receipts[1].transport_request_key
        assert.error_reason(
            authority:validate_current(source),
            'TRANSACTION_IDENTITY_REUSED'
        )

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].transaction_id = HASH_A
        assert.error_reason(
            authority:validate_current(source),
            'TRANSACTION_IDENTITY_REUSED'
        )

        source = bundle({
            row(1, 'PREPARED', { transaction_id = 'external_saga_42' }),
        }, 4)
        assert.equal(authority:validate_current(source).ok, true)

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].receipt_id = 'bad::receipt'
        assert.error_reason(authority:validate_current(source), 'RECEIPT_ID_INVALID')
    end),

    case('receipt persistence identity roles remain pairwise distinct', function()
        local authority = codec()
        local statuses = {
            'PREPARED',
            'APPLYING',
            'COMMITTED',
            'RECOVERY_REQUIRED',
            'FAILED_BEFORE_APPLY',
            'COMPENSATED',
        }
        local collisions = {
            {
                left = 'receipt_id',
                right = 'payload_hash',
                value = HASH_A,
            },
            {
                left = 'receipt_id',
                right = 'expected_result_digest',
                value = HASH_B,
            },
            {
                left = 'payload_hash',
                right = 'expected_result_digest',
                value = HASH_A,
            },
        }
        local status_index
        local collision_index
        for status_index = 1, #statuses do
            for collision_index = 1, #collisions do
                local collision = collisions[collision_index]
                local source = bundle({ row(1, statuses[status_index]) }, 4)
                local receipt = source.character_operation_receipts[1]
                receipt[collision.left] = collision.value
                receipt[collision.right] = collision.value
                if collision.left == 'receipt_id' then
                    local transport =
                        CharacterReceiptCodec.derive_transport_request_key(collision.value)
                    assert.equal(transport.ok, true)
                    receipt.transport_request_key = transport.value
                end
                if statuses[status_index] == 'COMMITTED' then
                    receipt.result_digest = receipt.expected_result_digest
                end

                local rejected = authority:validate_current(source)
                assert.error_reason(
                    rejected,
                    'PERSISTENCE_IDENTITY_REUSE_FORBIDDEN'
                )
                assert.equal(rejected.error.details.left, collision.left)
                assert.equal(rejected.error.details.right, collision.right)
            end
        end
    end),

    case('receipt history forbids cross-row identity role reuse', function()
        local authority = codec()
        local source = bundle({
            row(1, 'PREPARED'),
            row(2, 'APPLYING'),
        }, 4)
        local first = source.character_operation_receipts[1]
        first.receipt_id = HASH_A
        first.payload_hash = HASH_C
        first.transport_request_key =
            CharacterReceiptCodec.derive_transport_request_key(HASH_A).value
        local rejected = authority:validate_current(source)
        assert.error_reason(
            rejected,
            'PERSISTENCE_IDENTITY_REUSE_FORBIDDEN'
        )
        assert.equal(rejected.error.details.left, 'receipt_id')
        assert.equal(rejected.error.details.right, 'payload_hash')
        assert.equal(rejected.error.details.left_row_index, 1)
        assert.equal(rejected.error.details.right_row_index, 2)

        source = bundle({
            row(1, 'PREPARED'),
            row(2, 'APPLYING'),
        }, 4)
        first = source.character_operation_receipts[1]
        local second = source.character_operation_receipts[2]
        first.receipt_id = 'receipt_001'
        first.transaction_id = 'receipt_002'
        first.transport_request_key =
            CharacterReceiptCodec.derive_transport_request_key('receipt_001').value
        second.receipt_id = 'receipt_002'
        second.transport_request_key =
            CharacterReceiptCodec.derive_transport_request_key('receipt_002').value
        rejected = authority:validate_current(source)
        assert.error_reason(
            rejected,
            'PERSISTENCE_IDENTITY_REUSE_FORBIDDEN'
        )
        assert.equal(rejected.error.details.left, 'transaction_id')
        assert.equal(rejected.error.details.right, 'receipt_id')
        assert.equal(rejected.error.details.left_row_index, 1)
        assert.equal(rejected.error.details.right_row_index, 2)
    end),

    case('receipt history permits same-role reuse across steps', function()
        local authority = codec()
        local source = bundle({
            row(1, 'PREPARED', { transaction_id = 'shared_transaction' }),
            row(2, 'COMMITTED', { transaction_id = 'shared_transaction' }),
        }, 4)
        local validated = authority:validate_current(source)
        assert.equal(validated.ok, true)
        assert.equal(
            validated.value.character_operation_receipts[1].transaction_id,
            'shared_transaction'
        )
        assert.equal(
            validated.value.character_operation_receipts[2].result_digest,
            validated.value.character_operation_receipts[2].expected_result_digest
        )
    end),

    case('operation status hashes and revision transitions are exact', function()
        local authority = codec()
        local source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].operation_type = 'DELETE_CHARACTER'
        assert.error_reason(authority:validate_current(source), 'OPERATION_TYPE_INVALID')

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].status = 'FAILED'
        assert.error_reason(authority:validate_current(source), 'STATUS_INVALID')

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].payload_hash = string.rep('A', 64)
        assert.error_reason(authority:validate_current(source), 'PAYLOAD_HASH_INVALID')

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].expected_result_digest = nil
        assert.error_reason(authority:validate_current(source), 'FIELD_REQUIRED')

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].expected_result_digest =
            string.rep('A', 64)
        assert.error_reason(
            authority:validate_current(source),
            'EXPECTED_RESULT_DIGEST_INVALID'
        )

        source = bundle({ row(1, 'COMMITTED') }, 4)
        source.character_operation_receipts[1].expected_result_digest = HASH_C
        assert.error_reason(
            authority:validate_current(source),
            'EXPECTED_RESULT_DIGEST_MISMATCH'
        )

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].character_state_changed = 1
        assert.error_reason(
            authority:validate_current(source),
            'CHARACTER_STATE_CHANGED_INVALID'
        )

        source = bundle({ row(1, 'COMMITTED', {
            operation_type = 'RENAME_PROTAGONIST',
            changed = false,
        }) }, 4)
        assert.error_reason(
            authority:validate_current(source),
            'COMMITTED_OPERATION_REQUIRES_STATE_CHANGE'
        )

        source = bundle({ row(1, 'PREPARED') }, 4)
        source.character_operation_receipts[1].target_character_save_revision = 0
        assert.error_reason(
            authority:validate_current(source),
            'CHARACTER_SAVE_REVISION_TRANSITION_INVALID'
        )

        source = bundle({ row(1, 'PREPARED') }, 0)
        assert.error_reason(authority:validate_current(source), 'RECEIPT_REVISION_INVALID')

        source = bundle({ row(1, 'PREPARED') }, MAX_SAFE_INTEGER)
        source.character_operation_receipts[1].expected_character_save_revision =
            MAX_SAFE_INTEGER
        source.character_operation_receipts[1].target_character_save_revision =
            MAX_SAFE_INTEGER
        assert.error_reason(
            authority:validate_current(source),
            'CHARACTER_SAVE_REVISION_TRANSITION_INVALID'
        )
    end),

    case('terminal result triples are all present and forbidden before terminal state', function()
        local authority = codec()
        local terminal_statuses = {
            'COMMITTED',
            'FAILED_BEFORE_APPLY',
            'COMPENSATED',
        }
        local index
        local source
        for index = 1, #terminal_statuses do
            source = bundle({ row(1, terminal_statuses[index]) }, 4)
            source.character_operation_receipts[1].result_ref = nil
            assert.error_reason(
                authority:validate_current(source),
                'TERMINAL_RESULT_FIELDS_REQUIRED'
            )
        end

        local non_terminal_statuses = {
            'PREPARED',
            'APPLYING',
            'RECOVERY_REQUIRED',
        }
        for index = 1, #non_terminal_statuses do
            source = bundle({ row(1, non_terminal_statuses[index]) }, 4)
            source.character_operation_receipts[1].result_schema_version = 1
            source.character_operation_receipts[1].result_digest = HASH_B
            source.character_operation_receipts[1].result_ref = 'character_result:1'
            assert.error_reason(
                authority:validate_current(source),
                'NON_TERMINAL_RESULT_FIELDS_FORBIDDEN'
            )
        end

        source = bundle({ row(1, 'COMMITTED') }, 4)
        source.character_operation_receipts[1].result_digest = string.rep('B', 64)
        assert.error_reason(authority:validate_current(source), 'RESULT_DIGEST_INVALID')

        source = bundle({ row(1, 'COMMITTED') }, 4)
        source.character_operation_receipts[1].result_ref = 'bad::result'
        assert.error_reason(authority:validate_current(source), 'RESULT_REF_INVALID')
    end),

    case('bound receipt validators retain the captured transport derivation', function()
        local authority = codec()
        local source = bundle({ row(1, 'PREPARED') }, 4)
        local original = CharacterReceiptCodec.derive_transport_request_key
        local ok, failure = xpcall(function()
            CharacterReceiptCodec.derive_transport_request_key = function()
                return { ok = true, value = HASH_B }
            end
            assert.equal(authority:validate_current(source).ok, true)
        end, debug.traceback)
        CharacterReceiptCodec.derive_transport_request_key = original
        if not ok then
            error(failure)
        end
    end),

    case('captured validators and hash functions cannot be monkey patched after bind', function()
        local ReceiptHash = require 'wzx.domain.common.canonical_receipt_hash_v1'
        local RuntimeId = require 'wzx.domain.common.runtime_id'
        local TableShape = require 'wzx.domain.common.table_shape'
        local Ordered = require 'wzx.domain.common.ordered'
        local originals = {
            derive = ReceiptHash.derive,
            validate_derived = RuntimeId.validate_derived,
            validate_component = RuntimeId.validate_component,
            validate_source_reference = RuntimeId.validate_source_reference,
            is_integer = TableShape.is_integer,
            bytewise_string_less = Ordered.bytewise_string_less,
        }

        local ok, failure = xpcall(function()
            ReceiptHash.derive = function()
                return { ok = true, value = { digest = HASH_B } }
            end
            RuntimeId.validate_derived = function(value)
                return { ok = true, value = value }
            end
            RuntimeId.validate_component = function(value)
                return { ok = true, value = value }
            end
            RuntimeId.validate_source_reference = function(value)
                return { ok = true, value = value }
            end
            TableShape.is_integer = function()
                return true
            end
            Ordered.bytewise_string_less = function()
                return true
            end

            local derived = CharacterReceiptCodec.derive_transport_request_key(
                'creation:character:1'
            )
            assert.equal(
                derived.value,
                'a5d3ea3cafc990ba904c36053e87a2e17ff22792d8e685a800323e591e2d9437'
            )
            assert.error_reason(
                CharacterReceiptCodec.derive_transport_request_key('bad::receipt'),
                'RECEIPT_ID_INVALID'
            )

            local authority = codec()
            local source = bundle({
                row(2, 'APPLYING'),
                row(1, 'PREPARED'),
            }, 4)
            assert.error_reason(
                authority:validate_current(source),
                'RECEIPT_ORDER_INVALID'
            )

            source = bundle({ row(1, 'COMMITTED') }, 4)
            source.character_operation_receipts[1].result_ref = 'bad::result'
            assert.error_reason(
                authority:validate_current(source),
                'RESULT_REF_INVALID'
            )

            source = bundle({ row(1, 'PREPARED') }, 4)
            source.character_operation_receipts[1].transaction_id = 'forged:tx'
            assert.error_reason(
                authority:validate_current(source),
                'TRANSACTION_ID_INVALID'
            )

            source = bundle({ row(1, 'PREPARED') }, 4)
            source.character_operation_receipts[1].receipt_revision = 1.5
            assert.error_reason(
                authority:validate_current(source),
                'RECEIPT_REVISION_INVALID'
            )
        end, debug.traceback)

        ReceiptHash.derive = originals.derive
        RuntimeId.validate_derived = originals.validate_derived
        RuntimeId.validate_component = originals.validate_component
        RuntimeId.validate_source_reference = originals.validate_source_reference
        TableShape.is_integer = originals.is_integer
        Ordered.bytewise_string_less = originals.bytewise_string_less
        if not ok then
            error(failure)
        end
    end),

    case('bound receipt codec retains trusted traversal and scalar primitives', function()
        local authority = codec()
        local source = bundle({ row(1, 'PREPARED') }, 4)
        local unknown = bundle({ row(1, 'PREPARED') }, 4)
        unknown.character_operation_receipts[1].hidden = true
        local invalid_hash = bundle({ row(1, 'PREPARED') }, 4)
        invalid_hash.character_operation_receipts[1].payload_hash =
            string.rep('g', 64)
        local originals = {
            next = _G.next,
            floor = math.floor,
            match = string.match,
        }

        local ok, failure = xpcall(function()
            _G.next = function()
                return nil
            end
            math.floor = function()
                error('dynamic math.floor must not be invoked')
            end
            string.match = function()
                return true
            end

            local checked = authority:validate_current(source)
            assert.equal(checked.ok, true)
            assert.equal(#checked.value.character_operation_receipts, 1)
            assert.error_reason(
                authority:validate_current(unknown),
                'UNKNOWN_FIELD'
            )
            assert.error_reason(
                authority:validate_current(invalid_hash),
                'PAYLOAD_HASH_INVALID'
            )
        end, debug.traceback)

        _G.next = originals.next
        math.floor = originals.floor
        string.match = originals.match
        if not ok then
            error(failure)
        end
    end),
}
