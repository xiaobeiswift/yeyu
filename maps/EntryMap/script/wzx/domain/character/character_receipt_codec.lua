local CanonicalCodec = require 'wzx.domain.common.canonical_value_codec_v1'
local Ordered = require 'wzx.domain.common.ordered'
local ReceiptHash = require 'wzx.domain.common.canonical_receipt_hash_v1'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local CharacterReceiptCodec = {}

local SCHEMA_VERSION = 1
local MAX_SAFE_INTEGER = TableShape.MAX_SAFE_INTEGER
local bytewise_string_less = Ordered.bytewise_string_less
local derive_receipt_hash = ReceiptHash.derive
local result_err = Result.err
local result_ok = Result.ok
local math_floor = math.floor
local raw_next = next
local string_match = string.match
local validate_component_id = RuntimeId.validate_component
local validate_derived_id = RuntimeId.validate_derived
local validate_source_reference = RuntimeId.validate_source_reference
local is_integer = TableShape.is_integer

local BUNDLE_FIELDS = {
    character_operation_metadata = true,
    character_operation_receipts = true,
}

local METADATA_FIELDS = {
    schema_version = true,
    revision = true,
}

local ROW_FIELDS = {
    receipt_id = true,
    transaction_id = true,
    operation_type = true,
    payload_hash = true,
    expected_result_digest = true,
    transport_request_key = true,
    status = true,
    expected_character_save_revision = true,
    target_character_save_revision = true,
    character_state_changed = true,
    receipt_revision = true,
    result_schema_version = true,
    result_digest = true,
    result_ref = true,
}

local REQUIRED_ROW_FIELDS = {
    'receipt_id',
    'transaction_id',
    'operation_type',
    'payload_hash',
    'expected_result_digest',
    'transport_request_key',
    'status',
    'expected_character_save_revision',
    'target_character_save_revision',
    'character_state_changed',
    'receipt_revision',
}

local OPERATION_TYPES = {
    CREATE_OWNED_CHARACTER = true,
    GRANT_CHARACTER_EXPERIENCE = true,
    RENAME_PROTAGONIST = true,
}

local STATUSES = {
    PREPARED = true,
    APPLYING = true,
    COMMITTED = true,
    RECOVERY_REQUIRED = true,
    FAILED_BEFORE_APPLY = true,
    COMPENSATED = true,
}

local TERMINAL_RESULT_STATUSES = {
    COMMITTED = true,
    FAILED_BEFORE_APPLY = true,
    COMPENSATED = true,
}

local RECEIPT_ID_FIELDS = {
    {
        name = 'receipt_id',
        type = CanonicalCodec.TYPE_STRING,
    },
}

local TRANSPORT_NAMESPACE = 'character_repository_idempotency'

local Codec = {}
Codec.__index = Codec
Codec.__newindex = function()
    error('character receipt codec is read-only', 2)
end
Codec.__metatable = false

local STATES = setmetatable({}, { __mode = 'k' })

local function failure(code, message_key, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(code, message_key, false, details)
end

local function invalid(reason, details)
    return failure(
        'CHARACTER_RECEIPT_INVALID',
        'error.character.receipt_invalid',
        reason,
        details
    )
end

local function unsupported(reason, details)
    return failure(
        'CHARACTER_RECEIPT_VERSION_UNSUPPORTED',
        'error.character.receipt_version_unsupported',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        'CHARACTER_RECEIPT_LIMIT_EXCEEDED',
        'error.character.receipt_limit_exceeded',
        reason,
        details
    )
end

local function validate_exact_map(value, allowed_fields, required_fields, path)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return invalid('PLAIN_TABLE_REQUIRED', { path = path })
    end

    local key
    for key in raw_next, value do
        if type(key) ~= 'string' or not allowed_fields[key] then
            return invalid('UNKNOWN_FIELD', {
                path = path,
                field = type(key) == 'string' and key or nil,
                key_type = type(key),
            })
        end
    end

    local index
    local field
    for index = 1, #required_fields do
        field = required_fields[index]
        if rawget(value, field) == nil then
            return invalid('FIELD_REQUIRED', {
                path = path,
                field = field,
            })
        end
    end
    return result_ok(true)
end

local function is_lower_sha256(value)
    return type(value) == 'string'
        and #value == 64
        and string_match(value, '^[a-f0-9]+$') ~= nil
end

local function validate_receipt_id(receipt_id, field)
    local derived = validate_derived_id(receipt_id, field)
    if not derived.ok then
        return invalid('RECEIPT_ID_INVALID', {
            field = field,
            cause_code = derived.error.code,
        })
    end
    return result_ok(receipt_id)
end

local function derive_digest(receipt_id, namespace)
    local checked = validate_receipt_id(receipt_id, 'receipt_id')
    if not checked.ok then
        return checked
    end
    local derived = derive_receipt_hash(namespace, RECEIPT_ID_FIELDS, {
        receipt_id = receipt_id,
    })
    if not derived.ok then
        return invalid('RECEIPT_DERIVATION_FAILED', {
            cause_code = derived.error.code,
        })
    end
    return result_ok(derived.value.digest)
end

local function derive_transport_request_key(receipt_id)
    return derive_digest(receipt_id, TRANSPORT_NAMESPACE)
end

function CharacterReceiptCodec.derive_transport_request_key(receipt_id)
    return derive_transport_request_key(receipt_id)
end

local function validate_result_fields(row, status, path)
    local result_schema_version = rawget(row, 'result_schema_version')
    local result_digest = rawget(row, 'result_digest')
    local result_ref = rawget(row, 'result_ref')

    if TERMINAL_RESULT_STATUSES[status] then
        if result_schema_version == nil or result_digest == nil or result_ref == nil then
            return invalid('TERMINAL_RESULT_FIELDS_REQUIRED', { path = path })
        end
        if not is_integer(result_schema_version, 1, MAX_SAFE_INTEGER) then
            return invalid('RESULT_SCHEMA_VERSION_INVALID', {
                path = path,
                field = 'result_schema_version',
            })
        end
        if not is_lower_sha256(result_digest) then
            return invalid('RESULT_DIGEST_INVALID', {
                path = path,
                field = 'result_digest',
            })
        end
        if status == 'COMMITTED'
            and result_digest ~= rawget(row, 'expected_result_digest')
        then
            return invalid('EXPECTED_RESULT_DIGEST_MISMATCH', {
                path = path,
                field = 'result_digest',
            })
        end
        local reference = validate_source_reference(result_ref, 'result_ref')
        if not reference.ok then
            return invalid('RESULT_REF_INVALID', {
                path = path,
                field = 'result_ref',
                cause_code = reference.error.code,
            })
        end
        return result_ok(true)
    end

    if result_schema_version ~= nil or result_digest ~= nil or result_ref ~= nil then
        return invalid('NON_TERMINAL_RESULT_FIELDS_FORBIDDEN', { path = path })
    end
    return result_ok(true)
end

local function validate_identity_separation(
    receipt_id,
    transport_request_key,
    transaction_id,
    payload_hash,
    expected_result_digest,
    path
)
    local identities = {
        { name = 'receipt_id', value = receipt_id },
        { name = 'transport_request_key', value = transport_request_key },
        { name = 'transaction_id', value = transaction_id },
        { name = 'payload_hash', value = payload_hash },
        { name = 'expected_result_digest', value = expected_result_digest },
    }
    local left_index
    local right_index
    for left_index = 1, #identities - 1 do
        for right_index = left_index + 1, #identities do
            local left = identities[left_index]
            local right = identities[right_index]
            if left.value ~= nil
                and right.value ~= nil
                and left.value == right.value
            then
                return invalid('PERSISTENCE_IDENTITY_REUSE_FORBIDDEN', {
                    path = path,
                    left = left.name,
                    right = right.name,
                })
            end
        end
    end
    return result_ok(true)
end

local function validate_row(row, row_index, bundle_revision)
    local path = '$.character_operation_receipts[' .. tostring(row_index) .. ']'
    local exact = validate_exact_map(row, ROW_FIELDS, REQUIRED_ROW_FIELDS, path)
    if not exact.ok then
        return exact
    end

    local receipt_id = rawget(row, 'receipt_id')
    local receipt = validate_receipt_id(receipt_id, path .. '.receipt_id')
    if not receipt.ok then
        return receipt
    end

    local operation_type = rawget(row, 'operation_type')
    if type(operation_type) ~= 'string' or not OPERATION_TYPES[operation_type] then
        return invalid('OPERATION_TYPE_INVALID', {
            path = path,
            field = 'operation_type',
        })
    end

    local status = rawget(row, 'status')
    if type(status) ~= 'string' or not STATUSES[status] then
        return invalid('STATUS_INVALID', { path = path, field = 'status' })
    end

    if not is_lower_sha256(rawget(row, 'payload_hash')) then
        return invalid('PAYLOAD_HASH_INVALID', {
            path = path,
            field = 'payload_hash',
        })
    end
    if not is_lower_sha256(rawget(row, 'expected_result_digest')) then
        return invalid('EXPECTED_RESULT_DIGEST_INVALID', {
            path = path,
            field = 'expected_result_digest',
        })
    end

    local transport = derive_transport_request_key(receipt_id)
    if not transport.ok then
        return transport
    end
    local transport_request_key = rawget(row, 'transport_request_key')
    if not is_lower_sha256(transport_request_key)
        or transport_request_key ~= transport.value
    then
        return invalid('TRANSPORT_REQUEST_KEY_MISMATCH', {
            path = path,
            field = 'transport_request_key',
        })
    end

    local transaction = validate_component_id(
        rawget(row, 'transaction_id'),
        path .. '.transaction_id'
    )
    if not transaction.ok then
        return invalid('TRANSACTION_ID_INVALID', {
            path = path,
            field = 'transaction_id',
            cause_code = transaction.error.code,
        })
    end
    local transaction_id = rawget(row, 'transaction_id')
    if transaction_id == receipt_id
        or transaction_id == transport_request_key
        or transaction_id == rawget(row, 'payload_hash')
        or transaction_id == rawget(row, 'expected_result_digest')
    then
        return invalid('TRANSACTION_IDENTITY_REUSED', {
            path = path,
            field = 'transaction_id',
        })
    end

    local separated = validate_identity_separation(
        receipt_id,
        transport_request_key,
        transaction_id,
        rawget(row, 'payload_hash'),
        rawget(row, 'expected_result_digest'),
        path
    )
    if not separated.ok then
        return separated
    end

    local expected_revision = rawget(row, 'expected_character_save_revision')
    local target_revision = rawget(row, 'target_character_save_revision')
    local changed = rawget(row, 'character_state_changed')
    if not is_integer(expected_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('EXPECTED_CHARACTER_SAVE_REVISION_INVALID', {
            path = path,
            field = 'expected_character_save_revision',
        })
    end
    if not is_integer(target_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('TARGET_CHARACTER_SAVE_REVISION_INVALID', {
            path = path,
            field = 'target_character_save_revision',
        })
    end
    if type(changed) ~= 'boolean' then
        return invalid('CHARACTER_STATE_CHANGED_INVALID', {
            path = path,
            field = 'character_state_changed',
        })
    end
    if status == 'COMMITTED'
        and operation_type ~= 'CREATE_OWNED_CHARACTER'
        and not changed
    then
        return invalid('COMMITTED_OPERATION_REQUIRES_STATE_CHANGE', {
            path = path,
            field = 'character_state_changed',
            operation_type = operation_type,
        })
    end
    local expected_target = expected_revision + (changed and 1 or 0)
    if expected_target > MAX_SAFE_INTEGER or target_revision ~= expected_target then
        return invalid('CHARACTER_SAVE_REVISION_TRANSITION_INVALID', {
            path = path,
            expected_target_revision = expected_target <= MAX_SAFE_INTEGER
                and expected_target
                or nil,
        })
    end

    local receipt_revision = rawget(row, 'receipt_revision')
    if not is_integer(receipt_revision, 0, MAX_SAFE_INTEGER)
        or receipt_revision > bundle_revision
    then
        return invalid('RECEIPT_REVISION_INVALID', {
            path = path,
            field = 'receipt_revision',
            bundle_revision = bundle_revision,
        })
    end

    local result_fields = validate_result_fields(row, status, path)
    if not result_fields.ok then
        return result_fields
    end
    return result_ok(true)
end

local function copy_row(row)
    local copied = {
        receipt_id = rawget(row, 'receipt_id'),
        transaction_id = rawget(row, 'transaction_id'),
        operation_type = rawget(row, 'operation_type'),
        payload_hash = rawget(row, 'payload_hash'),
        expected_result_digest = rawget(row, 'expected_result_digest'),
        transport_request_key = rawget(row, 'transport_request_key'),
        status = rawget(row, 'status'),
        expected_character_save_revision = rawget(
            row,
            'expected_character_save_revision'
        ),
        target_character_save_revision = rawget(
            row,
            'target_character_save_revision'
        ),
        character_state_changed = rawget(row, 'character_state_changed'),
        receipt_revision = rawget(row, 'receipt_revision'),
    }
    if rawget(row, 'result_schema_version') ~= nil then
        copied.result_schema_version = rawget(row, 'result_schema_version')
        copied.result_digest = rawget(row, 'result_digest')
        copied.result_ref = rawget(row, 'result_ref')
    end
    return copied
end

local HISTORY_IDENTITY_FIELDS = {
    { field = 'receipt_id', role = 'receipt_id' },
    { field = 'transport_request_key', role = 'transport_request_key' },
    { field = 'transaction_id', role = 'transaction_id' },
    { field = 'payload_hash', role = 'payload_hash' },
    {
        field = 'expected_result_digest',
        role = 'expected_result_digest',
    },
    {
        field = 'result_digest',
        role = 'expected_result_digest',
    },
}

local function claim_history_identity(history, value, role, row_index, field)
    if value == nil then
        return result_ok(true)
    end
    local previous = history[value]
    if previous == nil then
        history[value] = {
            role = role,
            row_index = row_index,
        }
        return result_ok(true)
    end
    if previous.role ~= role then
        return invalid('PERSISTENCE_IDENTITY_REUSE_FORBIDDEN', {
            path = '$.character_operation_receipts['
                .. tostring(row_index)
                .. '].'
                .. field,
            left = previous.role,
            right = role,
            left_row_index = previous.row_index,
            right_row_index = row_index,
        })
    end
    return result_ok(true)
end

local function validate_rows(rows, bundle_revision, maximum_rows)
    if type(rows) ~= 'table' or getmetatable(rows) ~= nil then
        return invalid('RECEIPT_ROWS_PLAIN_ARRAY_REQUIRED', {
            path = '$.character_operation_receipts',
        })
    end

    local count = 0
    local maximum_index = 0
    local key
    for key in raw_next, rows do
        if type(key) ~= 'number'
            or key ~= key
            or key == math.huge
            or key == -math.huge
            or key < 1
            or key ~= math_floor(key)
        then
            return invalid('RECEIPT_ROWS_DENSE_ARRAY_REQUIRED', {
                path = '$.character_operation_receipts',
                key_type = type(key),
            })
        end
        if key > maximum_rows then
            return limit_exceeded('RECEIPT_ROW_LIMIT_EXCEEDED', {
                maximum_receipt_rows = maximum_rows,
            })
        end
        count = count + 1
        if count > maximum_rows then
            return limit_exceeded('RECEIPT_ROW_LIMIT_EXCEEDED', {
                maximum_receipt_rows = maximum_rows,
            })
        end
        if key > maximum_index then
            maximum_index = key
        end
    end

    if count ~= maximum_index then
        return invalid('RECEIPT_ROWS_DENSE_ARRAY_REQUIRED', {
            path = '$.character_operation_receipts',
        })
    end

    local copied = {}
    local identity_history = {}
    local previous_receipt_id
    local index
    for index = 1, count do
        local row = rawget(rows, index)
        local validated = validate_row(row, index, bundle_revision)
        if not validated.ok then
            return validated
        end
        local receipt_id = rawget(row, 'receipt_id')
        if previous_receipt_id ~= nil then
            if not bytewise_string_less(previous_receipt_id, receipt_id) then
                return invalid('RECEIPT_ORDER_INVALID', {
                    path = '$.character_operation_receipts',
                    row_index = index,
                })
            end
        end
        previous_receipt_id = receipt_id

        local history_field_index
        for history_field_index = 1, #HISTORY_IDENTITY_FIELDS do
            local identity_field = HISTORY_IDENTITY_FIELDS[history_field_index]
            local claimed = claim_history_identity(
                identity_history,
                rawget(row, identity_field.field),
                identity_field.role,
                index,
                identity_field.field
            )
            if not claimed.ok then
                return claimed
            end
        end
        copied[index] = copy_row(row)
    end
    return result_ok(copied)
end

local function validate_header(bundle)
    local exact = validate_exact_map(
        bundle,
        BUNDLE_FIELDS,
        { 'character_operation_metadata', 'character_operation_receipts' },
        '$'
    )
    if not exact.ok then
        return exact
    end

    local metadata = rawget(bundle, 'character_operation_metadata')
    exact = validate_exact_map(
        metadata,
        METADATA_FIELDS,
        { 'revision' },
        '$.character_operation_metadata'
    )
    if not exact.ok then
        return exact
    end

    local schema_version = rawget(metadata, 'schema_version')
    if schema_version ~= SCHEMA_VERSION then
        local details = {
            path = '$.character_operation_metadata.schema_version',
            actual_type = type(schema_version),
            supported_schema_version = SCHEMA_VERSION,
        }
        if is_integer(schema_version, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER) then
            details.actual = schema_version
        end
        return unsupported('SCHEMA_VERSION_UNSUPPORTED', {
            path = details.path,
            actual_type = details.actual_type,
            actual = details.actual,
            supported_schema_version = details.supported_schema_version,
        })
    end

    local revision = rawget(metadata, 'revision')
    if not is_integer(revision, 0, MAX_SAFE_INTEGER) then
        return invalid('BUNDLE_REVISION_INVALID', {
            path = '$.character_operation_metadata.revision',
        })
    end
    return result_ok({ revision = revision })
end

local function validate_current(self, bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('CODEC_AUTHORITY_REQUIRED')
    end
    local header = validate_header(bundle)
    if not header.ok then
        return header
    end
    local rows = validate_rows(
        rawget(bundle, 'character_operation_receipts'),
        header.value.revision,
        state.max_receipt_rows
    )
    if not rows.ok then
        return rows
    end
    return result_ok({
        character_operation_metadata = {
            schema_version = SCHEMA_VERSION,
            revision = header.value.revision,
        },
        character_operation_receipts = rows.value,
    })
end

function Codec:validate_current(bundle)
    return validate_current(self, bundle)
end

function Codec:validate(bundle)
    return validate_current(self, bundle)
end

function Codec:copy(bundle)
    return validate_current(self, bundle)
end

function Codec:migrate_to_current(bundle)
    local validated = validate_current(self, bundle)
    if not validated.ok then
        return validated
    end
    return result_ok({
        bundle = validated.value,
        report = {
            from_version = SCHEMA_VERSION,
            to_version = SCHEMA_VERSION,
            changed = false,
            applied_migration_ids = {},
            diagnostics = {},
        },
    })
end

function Codec:migrate(bundle)
    return self:migrate_to_current(bundle)
end

function CharacterReceiptCodec.bind(limits)
    local exact = validate_exact_map(
        limits,
        { max_receipt_rows = true },
        { 'max_receipt_rows' },
        '$.limits'
    )
    if not exact.ok then
        return exact
    end
    local maximum_rows = rawget(limits, 'max_receipt_rows')
    if not is_integer(maximum_rows, 1, MAX_SAFE_INTEGER) then
        return invalid('MAX_RECEIPT_ROWS_INVALID', {
            field = 'max_receipt_rows',
        })
    end

    local codec = setmetatable({}, Codec)
    STATES[codec] = {
        max_receipt_rows = maximum_rows,
    }
    return result_ok(codec)
end

CharacterReceiptCodec.SCHEMA_VERSION = SCHEMA_VERSION

return CharacterReceiptCodec
