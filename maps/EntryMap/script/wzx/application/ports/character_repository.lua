local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CharacterReceiptCodec = require 'wzx.domain.character.character_receipt_codec'
local Ordered = require 'wzx.domain.common.ordered'
local PortContract = require 'wzx.application.ports.port_contract'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TalentListDigest = require 'wzx.domain.character.talent_list_digest'
local Utf8Text = require 'wzx.domain.character.utf8_text'

local bytewise_string_less = Ordered.bytewise_string_less
local canonical_derive = CanonicalReceiptHashV1.derive
local derive_transport_identity = CharacterReceiptCodec.derive_transport_request_key
local is_dense_array = Ordered.is_dense_array
local utf8_is_valid = Utf8Text.is_valid
local validate_content_id = RuntimeId.validate_content
local validate_derived_id = RuntimeId.validate_derived
local validate_runtime_component = RuntimeId.validate_component
local validate_source_reference = RuntimeId.validate_source_reference
local derive_talent_list_digest = TalentListDigest.derive
local port_check_result_request_echo = PortContract.check_result_request_echo
local port_check_result_string = PortContract.check_result_string
local port_define = PortContract.define
local port_invalid_request = PortContract.invalid_request
local port_invalid_result = PortContract.invalid_result
local port_ok = PortContract.ok
local port_max_safe_integer = PortContract.MAX_SAFE_INTEGER
local math_floor = math.floor
local raw_next = next
local string_match = string.match

local MAX_SAFE_INTEGER = port_max_safe_integer
local MAX_EXPERIENCE_GRANT = 1000000000
local MAX_CUSTOM_NAME_CODEPOINTS = 18
local MAX_REWARD_REF_COUNT = 64
local MAX_UNLOCKED_TALENT_COUNT = TalentListDigest.MAX_TALENT_IDS
local NO_REWARD_RECEIPT_ID = 'none'
local NO_REWARD_RESULT_DIGEST = string.rep('0', 64)

local READ_ONLY_ISSUE_CODES = {
    CHARACTER_CONFIG_MISSING = true,
    CHARACTER_DEFINITION_VERSION_MIGRATION_REQUIRED = true,
    CHARACTER_DEFINITION_VERSION_UNAVAILABLE = true,
    CHARACTER_TALENT_CONFIG_MISSING = true,
}

local ERROR_DETAIL_FIELDS = {
    reason = true,
    cause_code = true,
    request_key = true,
    recovery = true,
    player_save_scope = true,
    original_request_key = true,
    receipt_id = true,
    transaction_id = true,
    operation_type = true,
    command_digest = true,
    expected_result_digest = true,
    expected_character_save_revision = true,
    actual_character_save_revision = true,
    actual_receipt_save_revision = true,
}

local ERROR_REVISION_DETAIL_FIELDS = {
    expected_character_save_revision = true,
    actual_character_save_revision = true,
    actual_receipt_save_revision = true,
}

local DEFAULT_ERROR_DETAIL_FIELDS = {
    reason = true,
    request_key = true,
}

local ERROR_DETAIL_FIELDS_BY_CODE = {
    IDEMPOTENCY_KEY_REUSED = {
        reason = true,
        player_save_scope = true,
        original_request_key = true,
        receipt_id = true,
        transaction_id = true,
        operation_type = true,
        command_digest = true,
        expected_result_digest = true,
        expected_character_save_revision = true,
        request_key = true,
    },
    SAVE_READ_ONLY = {
        reason = true,
        request_key = true,
    },
    SAVE_REVISION_CONFLICT = {
        request_key = true,
        expected_character_save_revision = true,
        actual_character_save_revision = true,
        actual_receipt_save_revision = true,
    },
    TRANSACTION_RECOVERY_REQUIRED = {
        reason = true,
        request_key = true,
        recovery = true,
        receipt_id = true,
        transaction_id = true,
    },
    PLATFORM_RESULT_UNKNOWN = {
        reason = true,
        cause_code = true,
        request_key = true,
        recovery = true,
    },
}

local ERROR_REASON_CODES = {
    IDEMPOTENCY_KEY_REUSED = {
        BUSINESS_RECEIPT_IDENTITY_MISMATCH = true,
        CHARACTER_TRANSACTION_IDENTITY_MISMATCH = true,
    },
    SAVE_READ_ONLY = {
        CHARACTER_READ_ONLY_ISOLATED = true,
        PLAYER_CHARACTER_SECTION_READ_ONLY = true,
    },
    TRANSACTION_RECOVERY_REQUIRED = {
        EARLIER_CHARACTER_TRANSACTION_UNRESOLVED = true,
    },
    PLATFORM_RESULT_UNKNOWN = {
        ACCEPTED_MUTATION_HAS_AMBIGUOUS_PLATFORM_ERROR = true,
        CALLBACK_RESULT_CONTRACT_INVALID = true,
        COMPLETION_REQUEST_KEY_MISMATCH = true,
        COMPLETION_RESULT_UNKNOWN = true,
        EXISTING_TRANSACTION_NOT_TERMINAL = true,
        FAKE_COMMIT_COMPLETION_UNKNOWN = true,
        FAKE_TRANSACTION_RECOVERY_REQUIRED = true,
        INTERNAL_ERROR_IS_NOT_PLATFORM_CONCLUSION = true,
    },
    PLATFORM_UNAVAILABLE = {
        FAKE_INJECTED_UNAVAILABLE = true,
    },
}

local ERROR_REASON_REQUIRED = {
    IDEMPOTENCY_KEY_REUSED = true,
    SAVE_READ_ONLY = true,
    TRANSACTION_RECOVERY_REQUIRED = true,
    PLATFORM_RESULT_UNKNOWN = true,
    PLATFORM_UNAVAILABLE = true,
}

local UNKNOWN_CAUSE_CODES_BY_REASON = {
    ACCEPTED_MUTATION_HAS_AMBIGUOUS_PLATFORM_ERROR = {
        PLATFORM_RATE_LIMITED = true,
        PLATFORM_UNAVAILABLE = true,
    },
    CALLBACK_RESULT_CONTRACT_INVALID = {
        PORT_CONTRACT_INVALID = true,
        PORT_OPERATION_UNKNOWN = true,
        PORT_RESULT_INVALID = true,
    },
    COMPLETION_REQUEST_KEY_MISMATCH = {
        PORT_RESULT_INVALID = true,
    },
    COMPLETION_RESULT_UNKNOWN = {
        ADAPTER_COMPLETION_AMBIGUOUS = true,
    },
    EXISTING_TRANSACTION_NOT_TERMINAL = {
        APPLYING = true,
        PREPARED = true,
        PREPARING = true,
        RECOVERY_REQUIRED = true,
    },
    FAKE_COMMIT_COMPLETION_UNKNOWN = {
        FAKE_INJECTED_UNKNOWN = true,
    },
    FAKE_TRANSACTION_RECOVERY_REQUIRED = {
        RECOVERY_REQUIRED = true,
    },
    INTERNAL_ERROR_IS_NOT_PLATFORM_CONCLUSION = {
        FAKE_FINGERPRINT_FAILED = true,
        FAKE_RESULT_SNAPSHOT_FAILED = true,
        FAKE_SCRIPT_EXHAUSTED = true,
        FAKE_SCRIPT_HANDLER_FAILED = true,
        FAKE_SCRIPT_INVALID = true,
        FAKE_SNAPSHOT_INVALID = true,
        PORT_ADAPTER_CALLBACK_INLINE = true,
        PORT_ADAPTER_FAILED = true,
        PORT_ADAPTER_RETURN_INVALID = true,
        PORT_CONTRACT_INVALID = true,
        PORT_IDEMPOTENCY_REQUIRED = true,
        PORT_OPERATION_UNKNOWN = true,
        PORT_REQUEST_CONTEXT_INVALID = true,
        PORT_REQUEST_INVALID = true,
        PORT_RESULT_INVALID = true,
    },
}

local COMMIT_BUSINESS_ERROR_CODES = {
    SAVE_REVISION_CONFLICT = true,
    SAVE_READ_ONLY = true,
    TRANSACTION_RECOVERY_REQUIRED = true,
}

local CREATE_OWNED_CHARACTER = 'CREATE_OWNED_CHARACTER'
local GRANT_CHARACTER_EXPERIENCE = 'GRANT_CHARACTER_EXPERIENCE'
local RENAME_PROTAGONIST = 'RENAME_PROTAGONIST'

local OPERATION_TYPES = {
    CREATE_OWNED_CHARACTER,
    GRANT_CHARACTER_EXPERIENCE,
    RENAME_PROTAGONIST,
}

local LOAD_STATUSES = {
    'FOUND',
    'NOT_FOUND',
    'READ_ONLY_ISOLATED',
}

local QUERY_STATUSES = {
    'PREPARING',
    'PREPARED',
    'APPLYING',
    'UNKNOWN',
    'COMMITTED',
    'RECOVERY_REQUIRED',
    'COMPENSATED',
    'FAILED_BEFORE_APPLY',
    'NOT_FOUND',
}

local CHANGE_TYPES = {
    'INSERT',
    'UPDATE',
    'NO_CHANGE',
}

-- These ordered tuples are persistence identities. Changing a name, type,
-- order, or namespace requires a contract-version migration and new vectors.
local COMMAND_SPECS = {
    [CREATE_OWNED_CHARACTER] = {
        namespace = 'character_create_owned_command',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'source_type', type = 'STRING' },
            { name = 'source_reference', type = 'STRING' },
        },
    },
    [GRANT_CHARACTER_EXPERIENCE] = {
        namespace = 'character_grant_experience_command',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'created_receipt_id', type = 'STRING' },
            { name = 'amount', type = 'INTEGER' },
            { name = 'reason', type = 'STRING' },
            { name = 'expected_revision', type = 'INTEGER' },
            { name = 'reward_ref_count', type = 'INTEGER' },
            { name = 'reward_plan_digest', type = 'STRING' },
        },
    },
    [RENAME_PROTAGONIST] = {
        namespace = 'character_rename_protagonist_command',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'created_receipt_id', type = 'STRING' },
            { name = 'new_name', type = 'STRING' },
            { name = 'expected_revision', type = 'INTEGER' },
        },
    },
}

local RESULT_SPECS = {
    [CREATE_OWNED_CHARACTER] = {
        namespace = 'character_create_owned_result',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'already_owned', type = 'BOOLEAN' },
            { name = 'definition_version', type = 'INTEGER' },
            { name = 'level', type = 'INTEGER' },
            { name = 'experience', type = 'INTEGER' },
            { name = 'unlocked_talent_count', type = 'INTEGER' },
            { name = 'unlocked_talent_digest', type = 'STRING' },
            { name = 'created_receipt_id', type = 'STRING' },
            { name = 'character_revision', type = 'INTEGER' },
        },
    },
    [GRANT_CHARACTER_EXPERIENCE] = {
        namespace = 'character_grant_experience_result',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'amount', type = 'INTEGER' },
            { name = 'reason', type = 'STRING' },
            { name = 'old_experience', type = 'INTEGER' },
            { name = 'new_experience', type = 'INTEGER' },
            { name = 'old_level', type = 'INTEGER' },
            { name = 'new_level', type = 'INTEGER' },
            { name = 'character_revision', type = 'INTEGER' },
            { name = 'reward_status', type = 'STRING' },
            { name = 'reward_receipt_id', type = 'STRING' },
            { name = 'reward_result_digest', type = 'STRING' },
        },
    },
    [RENAME_PROTAGONIST] = {
        namespace = 'character_rename_protagonist_result',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'new_name', type = 'STRING' },
            { name = 'character_revision', type = 'INTEGER' },
        },
    },
}

local STATE_REQUIRED_FIELDS = {
    'character_id',
    'definition_version',
    'level',
    'experience',
    'awakening_rank',
    'unlocked_talent_ids',
    'created_receipt_id',
    'revision',
}

local function failure(mode, field_name, reason, details)
    if mode == 'request' then
        return port_invalid_request(field_name, reason, details)
    end
    return port_invalid_result(field_name, reason, details)
end

local function exact_fields(
    value,
    required_fields,
    optional_fields,
    mode,
    path
)
    if type(value) ~= 'table' then
        return failure(mode, path, 'TABLE_REQUIRED')
    end

    local allowed = {}
    local index
    for index = 1, #required_fields do
        allowed[required_fields[index]] = true
    end
    optional_fields = optional_fields or {}
    for index = 1, #optional_fields do
        allowed[optional_fields[index]] = true
    end

    local field_name
    for field_name in raw_next, value do
        if type(field_name) ~= 'string' or not allowed[field_name] then
            return failure(
                mode,
                path .. '.' .. tostring(field_name),
                'UNKNOWN_FIELD'
            )
        end
    end
    for index = 1, #required_fields do
        field_name = required_fields[index]
        if value[field_name] == nil then
            return failure(
                mode,
                path .. '.' .. field_name,
                'FIELD_REQUIRED'
            )
        end
    end
    return nil
end

local function is_integer(value, minimum, maximum)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math_floor(value)
        and (minimum == nil or value >= minimum)
        and (maximum == nil or value <= maximum)
end

local function validate_integer(value, minimum, maximum, mode, path)
    if not is_integer(value, minimum, maximum) then
        return failure(mode, path, 'SAFE_INTEGER_OUT_OF_RANGE', {
            minimum = minimum,
            maximum = maximum,
        })
    end
    return nil
end

local function validate_error_details(error_value)
    local details = error_value.details
    if details == nil then
        if ERROR_REASON_REQUIRED[error_value.code] then
            return port_invalid_result(
                'error.details.reason',
                'ERROR_REASON_REQUIRED'
            )
        end
        return nil
    end
    if type(details) ~= 'table' then
        return port_invalid_result('error.details', 'TABLE_REQUIRED')
    end
    local key
    local value
    local code_fields = ERROR_DETAIL_FIELDS_BY_CODE[error_value.code]
        or DEFAULT_ERROR_DETAIL_FIELDS
    for key, value in raw_next, details do
        if type(key) ~= 'string'
            or not ERROR_DETAIL_FIELDS[key]
            or not code_fields[key]
        then
            return port_invalid_result(
                'error.details',
                'ERROR_DETAIL_FIELD_NOT_ALLOWED'
            )
        end
        if ERROR_REVISION_DETAIL_FIELDS[key] then
            local invalid = validate_integer(
                value,
                0,
                MAX_SAFE_INTEGER,
                'result',
                'error.details.' .. key
            )
            if invalid then
                return invalid
            end
        elseif type(value) ~= 'string'
            or #value < 1
            or #value > 1024
        then
            return port_invalid_result(
                'error.details.' .. key,
                'NON_EMPTY_BOUNDED_STRING_REQUIRED'
            )
        end
    end
    if details.cause_code ~= nil
        and (#details.cause_code > 64
            or string_match(
                details.cause_code,
                '^[A-Z][A-Z0-9_]*$'
            ) == nil)
    then
        return port_invalid_result(
            'error.details.cause_code',
            'STABLE_CAUSE_CODE_REQUIRED'
        )
    end
    local allowed_reasons = ERROR_REASON_CODES[error_value.code]
    if details.reason ~= nil
        and (allowed_reasons == nil
            or not allowed_reasons[details.reason])
    then
        return port_invalid_result(
            'error.details.reason',
            'ERROR_REASON_NOT_ALLOWED'
        )
    end
    if ERROR_REASON_REQUIRED[error_value.code]
        and details.reason == nil
    then
        return port_invalid_result(
            'error.details.reason',
            'ERROR_REASON_REQUIRED'
        )
    end
    return nil
end

local function validate_enum(value, allowed, mode, path)
    local index
    for index = 1, #allowed do
        if value == allowed[index] then
            return nil
        end
    end
    return failure(mode, path, 'ENUM_VALUE_INVALID', { actual = value })
end

local function validate_hash(value, mode, path)
    if type(value) ~= 'string'
        or #value ~= 64
        or string_match(value, '^[0-9a-f]+$') == nil
    then
        return failure(mode, path, 'LOWERCASE_SHA256_REQUIRED')
    end
    return nil
end

local function validate_character_id(value, mode, path)
    local validated = validate_content_id(value, 'char_', path)
    if not validated.ok then
        return failure(mode, path, 'CHARACTER_ID_REQUIRED', {
            cause_code = validated.error.code,
        })
    end
    return nil
end

local function validate_player_save_scope(value, mode, path)
    local validated = validate_runtime_component(value, path)
    if not validated.ok then
        return failure(mode, path, 'PLAYER_SAVE_SCOPE_REQUIRED', {
            cause_code = validated.error.code,
        })
    end
    return nil
end

local function validate_receipt_id(value, mode, path)
    if value == NO_REWARD_RECEIPT_ID then
        return failure(mode, path, 'REWARD_SENTINEL_NOT_BUSINESS_RECEIPT')
    end
    local validated = validate_derived_id(value, path)
    if not validated.ok then
        return failure(mode, path, 'STABLE_RECEIPT_ID_REQUIRED', {
            cause_code = validated.error.code,
        })
    end
    return nil
end

local function validate_upper_token(value, mode, path)
    if type(value) ~= 'string'
        or #value < 1
        or #value > 64
        or string_match(value, '^[A-Z][A-Z0-9_]*$') == nil
    then
        return failure(mode, path, 'STABLE_UPPER_TOKEN_REQUIRED')
    end
    return nil
end

local function validate_custom_name(value, require_non_empty, mode, path)
    if type(value) ~= 'string' then
        return failure(mode, path, 'UTF8_STRING_REQUIRED')
    end
    local valid, count_or_reason, context = utf8_is_valid(
        value,
        MAX_CUSTOM_NAME_CODEPOINTS
    )
    if not valid then
        return failure(mode, path, 'CUSTOM_NAME_INVALID', {
            utf8_reason = count_or_reason,
            utf8_context = context,
            maximum_codepoints = MAX_CUSTOM_NAME_CODEPOINTS,
        })
    end
    if require_non_empty and count_or_reason < 1 then
        return failure(mode, path, 'CUSTOM_NAME_EMPTY')
    end
    return nil
end

local function derive_digest(namespace, fields, values, mode, path)
    local derived = canonical_derive(namespace, fields, values)
    if not derived.ok then
        return nil, failure(mode, path, 'CANONICAL_DIGEST_INVALID', {
            cause_code = derived.error.code,
        })
    end
    return derived.value.digest, nil
end

local function expected_transport_key(receipt_id, mode, path)
    local derived = derive_transport_identity(receipt_id)
    if not derived.ok then
        return nil, failure(mode, path, 'TRANSPORT_KEY_DERIVATION_FAILED', {
            cause_code = derived.error.code,
        })
    end
    return derived.value, nil
end

local function validate_transport_key(
    actual_key,
    receipt_id,
    mode,
    path
)
    local expected, invalid = expected_transport_key(receipt_id, mode, path)
    if invalid then
        return invalid
    end
    if actual_key ~= expected then
        return failure(mode, path, 'RECEIPT_TRANSPORT_KEY_MISMATCH', {
            expected = expected,
            actual = actual_key,
        })
    end
    return nil
end

local function validate_transaction_id(
    actual_id,
    receipt_id,
    transport_key,
    command_digest,
    result_digest,
    mode,
    path
)
    local stable = validate_runtime_component(actual_id, path)
    if not stable.ok then
        return failure(mode, path, 'ATOMIC_TRANSACTION_ID_REQUIRED', {
            cause_code = stable.error.code,
        })
    end
    if actual_id == receipt_id
        or actual_id == transport_key
        or actual_id == command_digest
        or actual_id == result_digest
    then
        return failure(mode, path, 'TRANSACTION_IDENTITY_REUSE_FORBIDDEN')
    end
    return nil
end

local function validate_primary_identity_separation(
    receipt_id,
    transport_key,
    command_digest,
    result_digest,
    mode,
    path
)
    local identities = {
        { name = 'receipt_id', value = receipt_id },
        { name = 'transport_key', value = transport_key },
        { name = 'command_digest', value = command_digest },
        { name = 'result_digest', value = result_digest },
    }
    local left_index
    local right_index
    for left_index = 1, #identities - 1 do
        for right_index = left_index + 1, #identities do
            if identities[left_index].value == identities[right_index].value then
                return failure(
                    mode,
                    path,
                    'PERSISTENCE_IDENTITY_REUSE_FORBIDDEN',
                    {
                        left = identities[left_index].name,
                        right = identities[right_index].name,
                    }
                )
            end
        end
    end
    return nil
end

local function validate_created_receipt_identity(
    created_receipt_id,
    receipt_id,
    transport_key,
    transaction_id,
    command_digest,
    result_digest,
    mode,
    path
)
    if created_receipt_id == receipt_id
        or created_receipt_id == transport_key
        or created_receipt_id == transaction_id
        or created_receipt_id == command_digest
        or created_receipt_id == result_digest
    then
        return failure(
            mode,
            path,
            'CREATED_RECEIPT_IDENTITY_REUSE_FORBIDDEN'
        )
    end
    return nil
end

local function validate_reward_receipt_identity(
    result,
    receipt_id,
    created_receipt_id,
    transport_key,
    transaction_id,
    command_digest,
    result_digest,
    mode,
    path
)
    if result.reward_status ~= 'COMMITTED' then
        return nil
    end
    local reward_receipt_id = result.reward_receipt_id
    if reward_receipt_id == receipt_id
        or reward_receipt_id == created_receipt_id
        or reward_receipt_id == transport_key
        or reward_receipt_id == transaction_id
        or reward_receipt_id == command_digest
        or reward_receipt_id == result_digest
        or reward_receipt_id == result.reward_result_digest
    then
        return failure(
            mode,
            path,
            'REWARD_RECEIPT_IDENTITY_REUSE_FORBIDDEN'
        )
    end
    return nil
end

local function validate_nested_digest_identity_separation(
    operation_type,
    command,
    result,
    receipt_id,
    transport_key,
    transaction_id,
    command_digest,
    result_digest,
    mode,
    path
)
    if operation_type ~= GRANT_CHARACTER_EXPERIENCE then
        return nil
    end
    local identities = {
        { name = 'receipt_id', value = receipt_id },
        { name = 'transport_key', value = transport_key },
        { name = 'transaction_id', value = transaction_id },
    }
    if command ~= nil then
        identities[#identities + 1] = {
            name = 'created_receipt_id',
            value = command.created_receipt_id,
        }
    end
    if result ~= nil and result.reward_status == 'COMMITTED' then
        identities[#identities + 1] = {
            name = 'reward_receipt_id',
            value = result.reward_receipt_id,
        }
    end
    local digests = {
        { name = 'command_digest', value = command_digest },
        { name = 'result_digest', value = result_digest },
    }
    if command ~= nil then
        digests[#digests + 1] = {
            name = 'reward_plan_digest',
            value = command.reward_plan_digest,
        }
    end
    if result ~= nil then
        digests[#digests + 1] = {
            name = 'reward_result_digest',
            value = result.reward_result_digest,
        }
    end
    local identity_index
    local digest_index
    for identity_index = 1, #identities do
        for digest_index = 1, #digests do
            if identities[identity_index].value == digests[digest_index].value then
                return failure(
                    mode,
                    path,
                    'NESTED_DIGEST_IDENTITY_REUSE_FORBIDDEN',
                    {
                        identity = identities[identity_index].name,
                        digest = digests[digest_index].name,
                    }
                )
            end
        end
    end
    local left_digest_index
    local right_digest_index
    for left_digest_index = 1, #digests - 1 do
        for right_digest_index = left_digest_index + 1, #digests do
            local left_digest = digests[left_digest_index]
            local right_digest = digests[right_digest_index]
            local shared_no_reward_sentinel =
                left_digest.name == 'reward_plan_digest'
                and right_digest.name == 'reward_result_digest'
                and left_digest.value == NO_REWARD_RESULT_DIGEST
                and right_digest.value == NO_REWARD_RESULT_DIGEST
            if left_digest.value == right_digest.value
                and not shared_no_reward_sentinel
            then
                return failure(
                    mode,
                    path,
                    'NESTED_DIGEST_IDENTITY_REUSE_FORBIDDEN',
                    {
                        identity = left_digest.name,
                        digest = right_digest.name,
                    }
                )
            end
        end
    end
    return nil
end

local function validate_talent_ids(value, mode, path)
    if type(value) ~= 'table' or not is_dense_array(value) then
        return failure(mode, path, 'DENSE_ARRAY_REQUIRED')
    end
    local previous
    local index
    for index = 1, #value do
        local talent_id = value[index]
        local validated = validate_content_id(
            talent_id,
            'talent_',
            path .. '[' .. tostring(index) .. ']'
        )
        if not validated.ok then
            return failure(mode, path, 'TALENT_ID_REQUIRED', {
                entry_index = index,
                cause_code = validated.error.code,
            })
        end
        if previous ~= nil
            and not bytewise_string_less(previous, talent_id)
        then
            return failure(mode, path, 'STRICT_ASCENDING_ORDER_REQUIRED', {
                entry_index = index,
            })
        end
        previous = talent_id
    end
    return nil
end

local function validate_state(value, mode, path)
    local invalid = exact_fields(
        value,
        STATE_REQUIRED_FIELDS,
        { 'custom_name' },
        mode,
        path
    )
    if invalid then
        return invalid
    end
    invalid = validate_character_id(value.character_id, mode, path .. '.character_id')
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.definition_version,
        1,
        MAX_SAFE_INTEGER,
        mode,
        path .. '.definition_version'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(value.level, 1, 100, mode, path .. '.level')
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.experience,
        0,
        MAX_SAFE_INTEGER,
        mode,
        path .. '.experience'
    )
    if invalid then
        return invalid
    end
    if value.awakening_rank ~= 0 then
        return failure(mode, path .. '.awakening_rank', 'AWAKENING_NOT_AVAILABLE')
    end
    invalid = validate_talent_ids(
        value.unlocked_talent_ids,
        mode,
        path .. '.unlocked_talent_ids'
    )
    if invalid then
        return invalid
    end
    if value.custom_name ~= nil then
        invalid = validate_custom_name(
            value.custom_name,
            false,
            mode,
            path .. '.custom_name'
        )
        if invalid then
            return invalid
        end
    end
    invalid = validate_receipt_id(
        value.created_receipt_id,
        mode,
        path .. '.created_receipt_id'
    )
    if invalid then
        return invalid
    end
    return validate_integer(
        value.revision,
        0,
        MAX_SAFE_INTEGER,
        mode,
        path .. '.revision'
    )
end

local function validate_command(value, operation_type, mode, path)
    local invalid
    local spec = COMMAND_SPECS[operation_type]
    if spec == nil then
        return nil, failure(mode, path, 'OPERATION_TYPE_INVALID')
    end

    if operation_type == CREATE_OWNED_CHARACTER then
        invalid = exact_fields(
            value,
            { 'character_id', 'source_type', 'source_reference' },
            nil,
            mode,
            path
        )
        if invalid then
            return nil, invalid
        end
        invalid = validate_character_id(value.character_id, mode, path .. '.character_id')
        if invalid then
            return nil, invalid
        end
        invalid = validate_upper_token(value.source_type, mode, path .. '.source_type')
        if invalid then
            return nil, invalid
        end
        local reference = validate_source_reference(
            value.source_reference,
            path .. '.source_reference'
        )
        if not reference.ok then
            return nil, failure(mode, path .. '.source_reference', 'SOURCE_REFERENCE_REQUIRED', {
                cause_code = reference.error.code,
            })
        end
    elseif operation_type == GRANT_CHARACTER_EXPERIENCE then
        invalid = exact_fields(
            value,
            {
                'character_id',
                'created_receipt_id',
                'amount',
                'reason',
                'expected_revision',
                'reward_ref_count',
                'reward_plan_digest',
            },
            nil,
            mode,
            path
        )
        if invalid then
            return nil, invalid
        end
        invalid = validate_integer(
            value.reward_ref_count,
            0,
            MAX_REWARD_REF_COUNT,
            mode,
            path .. '.reward_ref_count'
        )
        if invalid then
            return nil, invalid
        end
        invalid = validate_hash(
            value.reward_plan_digest,
            mode,
            path .. '.reward_plan_digest'
        )
        if invalid then
            return nil, invalid
        end
        if value.reward_ref_count == 0
            and value.reward_plan_digest ~= NO_REWARD_RESULT_DIGEST
        then
            return nil, failure(
                mode,
                path .. '.reward_plan_digest',
                'EMPTY_REWARD_PLAN_SENTINEL_REQUIRED'
            )
        end
        if value.reward_ref_count > 0
            and value.reward_plan_digest == NO_REWARD_RESULT_DIGEST
        then
            return nil, failure(
                mode,
                path .. '.reward_plan_digest',
                'NON_EMPTY_REWARD_PLAN_DIGEST_REQUIRED'
            )
        end
        invalid = validate_character_id(value.character_id, mode, path .. '.character_id')
        if invalid then
            return nil, invalid
        end
        invalid = validate_receipt_id(
            value.created_receipt_id,
            mode,
            path .. '.created_receipt_id'
        )
        if invalid then
            return nil, invalid
        end
        invalid = validate_integer(
            value.amount,
            1,
            MAX_EXPERIENCE_GRANT,
            mode,
            path .. '.amount'
        )
        if invalid then
            return nil, invalid
        end
        invalid = validate_upper_token(value.reason, mode, path .. '.reason')
        if invalid then
            return nil, invalid
        end
        invalid = validate_integer(
            value.expected_revision,
            0,
            MAX_SAFE_INTEGER - 1,
            mode,
            path .. '.expected_revision'
        )
        if invalid then
            return nil, invalid
        end
    else
        invalid = exact_fields(
            value,
            {
                'character_id',
                'created_receipt_id',
                'new_name',
                'expected_revision',
            },
            nil,
            mode,
            path
        )
        if invalid then
            return nil, invalid
        end
        invalid = validate_character_id(value.character_id, mode, path .. '.character_id')
        if invalid then
            return nil, invalid
        end
        invalid = validate_receipt_id(
            value.created_receipt_id,
            mode,
            path .. '.created_receipt_id'
        )
        if invalid then
            return nil, invalid
        end
        invalid = validate_custom_name(value.new_name, true, mode, path .. '.new_name')
        if invalid then
            return nil, invalid
        end
        invalid = validate_integer(
            value.expected_revision,
            0,
            MAX_SAFE_INTEGER - 1,
            mode,
            path .. '.expected_revision'
        )
        if invalid then
            return nil, invalid
        end
    end

    local digest
    digest, invalid = derive_digest(
        spec.namespace,
        spec.fields,
        value,
        mode,
        path
    )
    if invalid then
        return nil, invalid
    end
    return {
        digest = digest,
        character_id = value.character_id,
    }, nil
end

local function validate_create_result(value, mode, path)
    local invalid = exact_fields(value, {
        'operation_type',
        'character_id',
        'already_owned',
        'definition_version',
        'level',
        'experience',
        'unlocked_talent_count',
        'unlocked_talent_digest',
        'created_receipt_id',
        'character_revision',
    }, nil, mode, path)
    if invalid then
        return invalid
    end
    if type(value.already_owned) ~= 'boolean' then
        return failure(mode, path .. '.already_owned', 'BOOLEAN_REQUIRED')
    end
    invalid = validate_character_id(value.character_id, mode, path .. '.character_id')
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.definition_version,
        1,
        MAX_SAFE_INTEGER,
        mode,
        path .. '.definition_version'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(value.level, 1, 100, mode, path .. '.level')
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.experience,
        0,
        MAX_SAFE_INTEGER,
        mode,
        path .. '.experience'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.unlocked_talent_count,
        0,
        MAX_UNLOCKED_TALENT_COUNT,
        mode,
        path .. '.unlocked_talent_count'
    )
    if invalid then
        return invalid
    end
    invalid = validate_hash(
        value.unlocked_talent_digest,
        mode,
        path .. '.unlocked_talent_digest'
    )
    if invalid then
        return invalid
    end
    invalid = validate_receipt_id(
        value.created_receipt_id,
        mode,
        path .. '.created_receipt_id'
    )
    if invalid then
        return invalid
    end
    return validate_integer(
        value.character_revision,
        0,
        MAX_SAFE_INTEGER,
        mode,
        path .. '.character_revision'
    )
end

local function validate_experience_result(value, mode, path)
    local invalid = exact_fields(value, {
        'operation_type',
        'character_id',
        'amount',
        'reason',
        'old_experience',
        'new_experience',
        'old_level',
        'new_level',
        'character_revision',
        'reward_status',
        'reward_receipt_id',
        'reward_result_digest',
    }, nil, mode, path)
    if invalid then
        return invalid
    end
    invalid = validate_character_id(value.character_id, mode, path .. '.character_id')
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.amount,
        1,
        MAX_EXPERIENCE_GRANT,
        mode,
        path .. '.amount'
    )
    if invalid then
        return invalid
    end
    invalid = validate_upper_token(value.reason, mode, path .. '.reason')
    if invalid then
        return invalid
    end
    local integer_fields = {
        { 'old_experience', 0, MAX_SAFE_INTEGER },
        { 'new_experience', 0, MAX_SAFE_INTEGER },
        { 'old_level', 1, 100 },
        { 'new_level', 1, 100 },
        { 'character_revision', 0, MAX_SAFE_INTEGER },
    }
    local index
    for index = 1, #integer_fields do
        local field = integer_fields[index]
        invalid = validate_integer(
            value[field[1]],
            field[2],
            field[3],
            mode,
            path .. '.' .. field[1]
        )
        if invalid then
            return invalid
        end
    end
    invalid = validate_enum(
        value.reward_status,
        { 'NOT_REQUIRED', 'COMMITTED' },
        mode,
        path .. '.reward_status'
    )
    if invalid then
        return invalid
    end
    if value.reward_status == 'NOT_REQUIRED' then
        if value.reward_receipt_id ~= NO_REWARD_RECEIPT_ID
            or value.reward_result_digest ~= NO_REWARD_RESULT_DIGEST
        then
            return failure(mode, path .. '.reward_status', 'NO_REWARD_SENTINEL_REQUIRED')
        end
    else
        invalid = validate_receipt_id(
            value.reward_receipt_id,
            mode,
            path .. '.reward_receipt_id'
        )
        if invalid then
            return invalid
        end
        if value.reward_receipt_id == NO_REWARD_RECEIPT_ID then
            return failure(mode, path .. '.reward_receipt_id', 'REWARD_RECEIPT_REQUIRED')
        end
        invalid = validate_hash(
            value.reward_result_digest,
            mode,
            path .. '.reward_result_digest'
        )
        if invalid then
            return invalid
        end
        if value.reward_result_digest == NO_REWARD_RESULT_DIGEST then
            return failure(mode, path .. '.reward_result_digest', 'REWARD_RESULT_REQUIRED')
        end
    end
    return nil
end

local function validate_rename_result(value, mode, path)
    local invalid = exact_fields(value, {
        'operation_type',
        'character_id',
        'new_name',
        'character_revision',
    }, nil, mode, path)
    if invalid then
        return invalid
    end
    invalid = validate_character_id(value.character_id, mode, path .. '.character_id')
    if invalid then
        return invalid
    end
    invalid = validate_custom_name(value.new_name, true, mode, path .. '.new_name')
    if invalid then
        return invalid
    end
    return validate_integer(
        value.character_revision,
        0,
        MAX_SAFE_INTEGER,
        mode,
        path .. '.character_revision'
    )
end

local function result_digest_values(value, operation_type)
    if operation_type == CREATE_OWNED_CHARACTER then
        return {
            character_id = value.character_id,
            already_owned = value.already_owned,
            definition_version = value.definition_version,
            level = value.level,
            experience = value.experience,
            unlocked_talent_count = value.unlocked_talent_count,
            unlocked_talent_digest = value.unlocked_talent_digest,
            created_receipt_id = value.created_receipt_id,
            character_revision = value.character_revision,
        }
    end
    if operation_type == GRANT_CHARACTER_EXPERIENCE then
        return {
            character_id = value.character_id,
            amount = value.amount,
            reason = value.reason,
            old_experience = value.old_experience,
            new_experience = value.new_experience,
            old_level = value.old_level,
            new_level = value.new_level,
            character_revision = value.character_revision,
            reward_status = value.reward_status,
            reward_receipt_id = value.reward_receipt_id,
            reward_result_digest = value.reward_result_digest,
        }
    end
    return {
        character_id = value.character_id,
        new_name = value.new_name,
        character_revision = value.character_revision,
    }
end

local function validate_typed_result(value, operation_type, mode, path)
    local invalid
    if operation_type == CREATE_OWNED_CHARACTER then
        invalid = validate_create_result(value, mode, path)
    elseif operation_type == GRANT_CHARACTER_EXPERIENCE then
        invalid = validate_experience_result(value, mode, path)
    elseif operation_type == RENAME_PROTAGONIST then
        invalid = validate_rename_result(value, mode, path)
    else
        return nil, failure(mode, path, 'OPERATION_TYPE_INVALID')
    end
    if invalid then
        return nil, invalid
    end
    if value.operation_type ~= operation_type then
        return nil, failure(mode, path .. '.operation_type', 'OPERATION_TYPE_MISMATCH')
    end
    local spec = RESULT_SPECS[operation_type]
    local digest
    digest, invalid = derive_digest(
        spec.namespace,
        spec.fields,
        result_digest_values(value, operation_type),
        mode,
        path
    )
    if invalid then
        return nil, invalid
    end
    return { digest = digest }, nil
end

local function validate_result_against_command(
    result,
    command,
    operation_type,
    receipt_id,
    transport_key,
    transaction_id,
    command_digest,
    result_digest,
    mode,
    path
)
    if result.character_id ~= command.character_id then
        return failure(mode, path .. '.character_id', 'COMMAND_CHARACTER_MISMATCH')
    end
    if operation_type == CREATE_OWNED_CHARACTER then
        if result.already_owned then
            if result.created_receipt_id == receipt_id then
                return failure(
                    mode,
                    path .. '.created_receipt_id',
                    'ALREADY_OWNED_RECEIPT_MUST_PREDATE_ATTEMPT'
                )
            end
            return nil
        end
        if result.created_receipt_id ~= receipt_id
            or result.level ~= 1
            or result.experience ~= 0
            or result.character_revision ~= 0
        then
            return failure(
                mode,
                path,
                'CREATED_RESULT_MUST_USE_INITIAL_VALUES'
            )
        end
        return nil
    end
    if result.character_revision ~= command.expected_revision + 1 then
        return failure(
            mode,
            path .. '.character_revision',
            'COMMAND_REVISION_RESULT_MISMATCH'
        )
    end
    if operation_type == GRANT_CHARACTER_EXPERIENCE then
        if result.amount ~= command.amount
            or result.reason ~= command.reason
            or result.old_experience > MAX_SAFE_INTEGER - command.amount
            or result.new_experience ~= result.old_experience + command.amount
        then
            return failure(
                mode,
                path,
                'COMMAND_EXPERIENCE_RESULT_MISMATCH'
            )
        end
        if result.new_level < result.old_level then
            return failure(mode, path .. '.new_level', 'LEVEL_MUST_NOT_DECREASE')
        end
        if result.new_level == result.old_level
            and command.reward_ref_count ~= 0
        then
            return failure(
                mode,
                path .. '.reward_status',
                'UNCHANGED_LEVEL_REQUIRES_EMPTY_REWARD_PLAN'
            )
        end
        local reached_level_count = result.new_level - result.old_level
        if command.reward_ref_count > reached_level_count then
            return failure(
                mode,
                path .. '.new_level',
                'REWARD_REF_COUNT_EXCEEDS_REACHED_LEVELS',
                {
                    reward_ref_count = command.reward_ref_count,
                    reached_level_count = reached_level_count,
                }
            )
        end
        if command.reward_ref_count == 0
            and result.reward_status ~= 'NOT_REQUIRED'
        then
            return failure(
                mode,
                path .. '.reward_status',
                'EMPTY_REWARD_PLAN_REQUIRES_NO_REWARD'
            )
        end
        if command.reward_ref_count > 0
            and result.reward_status ~= 'COMMITTED'
        then
            return failure(
                mode,
                path .. '.reward_status',
                'NON_EMPTY_REWARD_PLAN_REQUIRES_COMMITTED_REWARD'
            )
        end
        local invalid = validate_reward_receipt_identity(
            result,
            receipt_id,
            command.created_receipt_id,
            transport_key,
            transaction_id,
            command_digest,
            result_digest,
            mode,
            path .. '.reward_receipt_id'
        )
        if invalid then
            return invalid
        end
        return nil
    end
    if result.new_name ~= command.new_name then
        return failure(mode, path .. '.new_name', 'COMMAND_NAME_RESULT_MISMATCH')
    end
    return nil
end

local function arrays_equal(left, right)
    if #left ~= #right then
        return false
    end
    local index
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function scalar_tables_equal(left, right)
    local key
    for key in raw_next, left do
        if right[key] ~= left[key] then
            return false
        end
    end
    for key in raw_next, right do
        if left[key] ~= right[key] then
            return false
        end
    end
    return true
end

local function same_state_fields(left, right, excluded)
    local scalar_fields = {
        'character_id',
        'definition_version',
        'level',
        'experience',
        'awakening_rank',
        'custom_name',
        'created_receipt_id',
        'revision',
    }
    local index
    for index = 1, #scalar_fields do
        local field = scalar_fields[index]
        if not excluded[field] and left[field] ~= right[field] then
            return false, field
        end
    end
    if not excluded.unlocked_talent_ids
        and not arrays_equal(left.unlocked_talent_ids, right.unlocked_talent_ids)
    then
        return false, 'unlocked_talent_ids'
    end
    return true, nil
end

local function create_result_matches_state(result, state, already_owned)
    local talent_proof = derive_talent_list_digest(
        state.unlocked_talent_ids
    )
    return talent_proof.ok
        and result.already_owned == already_owned
        and result.character_id == state.character_id
        and result.definition_version == state.definition_version
        and result.level == state.level
        and result.experience == state.experience
        and result.unlocked_talent_count == talent_proof.value.count
        and result.unlocked_talent_digest == talent_proof.value.digest
        and result.created_receipt_id == state.created_receipt_id
        and result.character_revision == state.revision
end

local function validate_transition(request)
    local operation_type = request.operation_type
    local command = request.command
    local before_state = request.before_state
    local after_state = request.after_state
    local result = request.result
    local invalid

    if operation_type == CREATE_OWNED_CHARACTER then
        if request.change_type == 'INSERT' then
            if before_state ~= nil or after_state == nil then
                return port_invalid_request(
                    'change_type',
                    'INSERT_REQUIRES_ONLY_AFTER_STATE'
                )
            end
            if after_state.character_id ~= command.character_id
                or after_state.level ~= 1
                or after_state.experience ~= 0
                or after_state.awakening_rank ~= 0
                or after_state.revision ~= 0
                or after_state.custom_name ~= nil
                or after_state.created_receipt_id ~= request.receipt_id
            then
                return port_invalid_request(
                    'after_state',
                    'CREATED_STATE_MUST_USE_INITIAL_VALUES'
                )
            end
            if not create_result_matches_state(result, after_state, false) then
                return port_invalid_request(
                    'result',
                    'CREATE_RESULT_STATE_MISMATCH'
                )
            end
            return nil
        end
        if request.change_type == 'NO_CHANGE' then
            if before_state == nil or after_state ~= nil then
                return port_invalid_request(
                    'change_type',
                    'NO_CHANGE_REQUIRES_ONLY_BEFORE_STATE'
                )
            end
            if before_state.character_id ~= command.character_id then
                return port_invalid_request(
                    'before_state.character_id',
                    'COMMAND_CHARACTER_MISMATCH'
                )
            end
            if before_state.created_receipt_id == request.receipt_id then
                return port_invalid_request(
                    'before_state.created_receipt_id',
                    'ALREADY_OWNED_RECEIPT_MUST_PREDATE_ATTEMPT'
                )
            end
            invalid = validate_created_receipt_identity(
                before_state.created_receipt_id,
                request.receipt_id,
                request.context.idempotency_key,
                request.transaction_id,
                request.command_digest,
                request.result_digest,
                'request',
                'before_state.created_receipt_id'
            )
            if invalid then
                return invalid
            end
            if not create_result_matches_state(result, before_state, true) then
                return port_invalid_request(
                    'result',
                    'ALREADY_OWNED_RESULT_STATE_MISMATCH'
                )
            end
            return nil
        end
        return port_invalid_request(
            'change_type',
            'CREATE_CHANGE_TYPE_INVALID'
        )
    end

    if request.change_type ~= 'UPDATE'
        or before_state == nil
        or after_state == nil
    then
        return port_invalid_request(
            'change_type',
            'UPDATE_REQUIRES_BEFORE_AND_AFTER_STATE'
        )
    end
    if before_state.character_id ~= command.character_id
        or after_state.character_id ~= command.character_id
        or result.character_id ~= command.character_id
    then
        return port_invalid_request(
            'command.character_id',
            'TRANSACTION_CHARACTER_MISMATCH'
        )
    end
    if before_state.revision ~= command.expected_revision then
        return port_invalid_request(
            'command.expected_revision',
            'EXPECTED_CHARACTER_REVISION_MISMATCH'
        )
    end
    if request.receipt_id == before_state.created_receipt_id then
        return port_invalid_request(
            'receipt_id',
            'COMMAND_RECEIPT_MUST_DIFFER_FROM_CREATED_RECEIPT'
        )
    end
    if command.created_receipt_id ~= before_state.created_receipt_id then
        return port_invalid_request(
            'command.created_receipt_id',
            'FROZEN_CREATED_RECEIPT_MISMATCH'
        )
    end
    invalid = validate_created_receipt_identity(
        command.created_receipt_id,
        request.receipt_id,
        request.context.idempotency_key,
        request.transaction_id,
        request.command_digest,
        request.result_digest,
        'request',
        'command.created_receipt_id'
    )
    if invalid then
        return invalid
    end
    if before_state.revision == MAX_SAFE_INTEGER
        or after_state.revision ~= before_state.revision + 1
    then
        return port_invalid_request(
            'after_state.revision',
            'CHARACTER_REVISION_MUST_ADVANCE_ONCE'
        )
    end

    if operation_type == GRANT_CHARACTER_EXPERIENCE then
        local same, changed_field = same_state_fields(before_state, after_state, {
            experience = true,
            level = true,
            revision = true,
        })
        if not same then
            return port_invalid_request(
                'after_state.' .. changed_field,
                'EXPERIENCE_CHANGE_MODIFIED_FORBIDDEN_FIELD'
            )
        end
        if before_state.experience > MAX_SAFE_INTEGER - command.amount
            or after_state.experience ~= before_state.experience + command.amount
        then
            return port_invalid_request(
                'after_state.experience',
                'EXPERIENCE_DELTA_MISMATCH'
            )
        end
        if after_state.level < before_state.level then
            return port_invalid_request(
                'after_state.level',
                'LEVEL_MUST_NOT_DECREASE'
            )
        end
        if after_state.level == before_state.level
            and command.reward_ref_count ~= 0
        then
            return port_invalid_request(
                'command.reward_ref_count',
                'UNCHANGED_LEVEL_REQUIRES_EMPTY_REWARD_PLAN'
            )
        end
        local reached_level_count = after_state.level - before_state.level
        if command.reward_ref_count > reached_level_count then
            return port_invalid_request(
                'command.reward_ref_count',
                'REWARD_REF_COUNT_EXCEEDS_REACHED_LEVELS',
                {
                    reward_ref_count = command.reward_ref_count,
                    reached_level_count = reached_level_count,
                }
            )
        end
        if result.amount ~= command.amount
            or result.reason ~= command.reason
            or result.old_experience ~= before_state.experience
            or result.new_experience ~= after_state.experience
            or result.old_level ~= before_state.level
            or result.new_level ~= after_state.level
            or result.character_revision ~= after_state.revision
        then
            return port_invalid_request(
                'result',
                'EXPERIENCE_RESULT_STATE_MISMATCH'
            )
        end
        if command.reward_ref_count == 0
            and result.reward_status ~= 'NOT_REQUIRED'
        then
            return port_invalid_request(
                'result.reward_status',
                'EMPTY_REWARD_PLAN_REQUIRES_NO_REWARD'
            )
        end
        if command.reward_ref_count > 0
            and result.reward_status ~= 'COMMITTED'
        then
            return port_invalid_request(
                'result.reward_status',
                'NON_EMPTY_REWARD_PLAN_REQUIRES_COMMITTED_REWARD'
            )
        end
        invalid = validate_reward_receipt_identity(
            result,
            request.receipt_id,
            before_state.created_receipt_id,
            request.context.idempotency_key,
            request.transaction_id,
            request.command_digest,
            request.result_digest,
            'request',
            'result.reward_receipt_id'
        )
        if invalid then
            return invalid
        end
        return nil
    end

    local same, changed_field = same_state_fields(before_state, after_state, {
        custom_name = true,
        revision = true,
    })
    if not same then
        return port_invalid_request(
            'after_state.' .. changed_field,
            'RENAME_MODIFIED_FORBIDDEN_FIELD'
        )
    end
    if after_state.custom_name ~= command.new_name
        or before_state.custom_name == command.new_name
    then
        return port_invalid_request(
            'after_state.custom_name',
            'RENAME_TARGET_MISMATCH_OR_UNCHANGED'
        )
    end
    if result.new_name ~= command.new_name
        or result.character_revision ~= after_state.revision
    then
        return port_invalid_request(
            'result',
            'RENAME_RESULT_STATE_MISMATCH'
        )
    end
    return nil
end

local function validate_load_request(request)
    local invalid = validate_player_save_scope(
        request.player_save_scope,
        'request',
        'player_save_scope'
    )
    if invalid then
        return invalid
    end
    invalid = validate_character_id(
        request.character_id,
        'request',
        'character_id'
    )
    if invalid then
        return invalid
    end
    return port_ok(true)
end

local function validate_commit_request(request)
    local required = {
        'player_save_scope',
        'operation_type',
        'receipt_id',
        'transaction_id',
        'command_digest',
        'expected_character_save_revision',
        'change_type',
        'command',
        'result_digest',
        'result',
    }
    local index
    for index = 1, #required do
        if request[required[index]] == nil then
            return port_invalid_request(required[index], 'FIELD_REQUIRED')
        end
    end

    local invalid = validate_player_save_scope(
        request.player_save_scope,
        'request',
        'player_save_scope'
    )
    if invalid then
        return invalid
    end
    invalid = validate_enum(
        request.operation_type,
        OPERATION_TYPES,
        'request',
        'operation_type'
    )
    if invalid then
        return invalid
    end
    invalid = validate_receipt_id(request.receipt_id, 'request', 'receipt_id')
    if invalid then
        return invalid
    end
    invalid = validate_transport_key(
        request.context.idempotency_key,
        request.receipt_id,
        'request',
        'context.idempotency_key'
    )
    if invalid then
        return invalid
    end
    invalid = validate_hash(request.command_digest, 'request', 'command_digest')
    if invalid then
        return invalid
    end
    invalid = validate_transaction_id(
        request.transaction_id,
        request.receipt_id,
        request.context.idempotency_key,
        request.command_digest,
        request.result_digest,
        'request',
        'transaction_id'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        request.expected_character_save_revision,
        0,
        MAX_SAFE_INTEGER,
        'request',
        'expected_character_save_revision'
    )
    if invalid then
        return invalid
    end
    invalid = validate_enum(
        request.change_type,
        CHANGE_TYPES,
        'request',
        'change_type'
    )
    if invalid then
        return invalid
    end
    if request.change_type ~= 'NO_CHANGE'
        and request.expected_character_save_revision == MAX_SAFE_INTEGER
    then
        return port_invalid_request(
            'expected_character_save_revision',
            'CHARACTER_SAVE_REVISION_INCREMENT_OVERFLOW'
        )
    end

    local command_info
    command_info, invalid = validate_command(
        request.command,
        request.operation_type,
        'request',
        'command'
    )
    if invalid then
        return invalid
    end
    if command_info.digest ~= request.command_digest then
        return port_invalid_request(
            'command_digest',
            'COMMAND_DIGEST_MISMATCH'
        )
    end

    if request.before_state ~= nil then
        invalid = validate_state(request.before_state, 'request', 'before_state')
        if invalid then
            return invalid
        end
        if request.before_state.revision > request.expected_character_save_revision then
            return port_invalid_request(
                'before_state.revision',
                'CHARACTER_REVISION_ABOVE_CHARACTER_SAVE_REVISION'
            )
        end
    end
    if request.after_state ~= nil then
        invalid = validate_state(request.after_state, 'request', 'after_state')
        if invalid then
            return invalid
        end
    end

    local result_info
    result_info, invalid = validate_typed_result(
        request.result,
        request.operation_type,
        'request',
        'result'
    )
    if invalid then
        return invalid
    end
    invalid = validate_hash(request.result_digest, 'request', 'result_digest')
    if invalid then
        return invalid
    end
    if result_info.digest ~= request.result_digest then
        return port_invalid_request(
            'result_digest',
            'RESULT_DIGEST_MISMATCH'
        )
    end
    invalid = validate_primary_identity_separation(
        request.receipt_id,
        request.context.idempotency_key,
        request.command_digest,
        request.result_digest,
        'request',
        'identity'
    )
    if invalid then
        return invalid
    end

    invalid = validate_transition(request)
    if invalid then
        return invalid
    end
    invalid = validate_nested_digest_identity_separation(
        request.operation_type,
        request.command,
        request.result,
        request.receipt_id,
        request.context.idempotency_key,
        request.transaction_id,
        request.command_digest,
        request.result_digest,
        'request',
        'identity'
    )
    if invalid then
        return invalid
    end
    local target_character_save_revision = request.expected_character_save_revision
    if request.change_type ~= 'NO_CHANGE' then
        target_character_save_revision = target_character_save_revision + 1
    end
    local target_character_revision = request.result.character_revision
    if target_character_revision > target_character_save_revision then
        return port_invalid_request(
            'result.character_revision',
            'CHARACTER_REVISION_ABOVE_CHARACTER_SAVE_REVISION'
        )
    end
    return port_ok(true)
end

local function validate_query_request(request)
    local required = {
        'player_save_scope',
        'original_request_key',
        'receipt_id',
        'transaction_id',
        'operation_type',
        'command_digest',
        'expected_result_digest',
        'expected_character_save_revision',
        'command',
    }
    local index
    for index = 1, #required do
        if request[required[index]] == nil then
            return port_invalid_request(required[index], 'FIELD_REQUIRED')
        end
    end
    local invalid = validate_player_save_scope(
        request.player_save_scope,
        'request',
        'player_save_scope'
    )
    if invalid then
        return invalid
    end
    invalid = validate_receipt_id(request.receipt_id, 'request', 'receipt_id')
    if invalid then
        return invalid
    end
    invalid = validate_transport_key(
        request.original_request_key,
        request.receipt_id,
        'request',
        'original_request_key'
    )
    if invalid then
        return invalid
    end
    invalid = validate_enum(
        request.operation_type,
        OPERATION_TYPES,
        'request',
        'operation_type'
    )
    if invalid then
        return invalid
    end
    invalid = validate_hash(request.command_digest, 'request', 'command_digest')
    if invalid then
        return invalid
    end
    invalid = validate_hash(
        request.expected_result_digest,
        'request',
        'expected_result_digest'
    )
    if invalid then
        return invalid
    end
    invalid = validate_primary_identity_separation(
        request.receipt_id,
        request.original_request_key,
        request.command_digest,
        request.expected_result_digest,
        'request',
        'identity'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        request.expected_character_save_revision,
        0,
        MAX_SAFE_INTEGER,
        'request',
        'expected_character_save_revision'
    )
    if invalid then
        return invalid
    end
    invalid = validate_transaction_id(
        request.transaction_id,
        request.receipt_id,
        request.original_request_key,
        request.command_digest,
        request.expected_result_digest,
        'request',
        'transaction_id'
    )
    if invalid then
        return invalid
    end
    local command_info
    command_info, invalid = validate_command(
        request.command,
        request.operation_type,
        'request',
        'command'
    )
    if invalid then
        return invalid
    end
    if command_info.digest ~= request.command_digest then
        return port_invalid_request(
            'command_digest',
            'COMMAND_DIGEST_MISMATCH'
        )
    end
    if request.operation_type ~= CREATE_OWNED_CHARACTER
        and request.command.expected_revision
            > request.expected_character_save_revision
    then
        return port_invalid_request(
            'command.expected_revision',
            'CHARACTER_REVISION_ABOVE_CHARACTER_SAVE_REVISION'
        )
    end
    if request.operation_type ~= CREATE_OWNED_CHARACTER
        and request.expected_character_save_revision == MAX_SAFE_INTEGER
    then
        return port_invalid_request(
            'expected_character_save_revision',
            'CHARACTER_SAVE_REVISION_INCREMENT_OVERFLOW'
        )
    end
    if request.operation_type ~= CREATE_OWNED_CHARACTER then
        invalid = validate_created_receipt_identity(
            request.command.created_receipt_id,
            request.receipt_id,
            request.original_request_key,
            request.transaction_id,
            request.command_digest,
            request.expected_result_digest,
            'request',
            'command.created_receipt_id'
        )
        if invalid then
            return invalid
        end
    end
    invalid = validate_nested_digest_identity_separation(
        request.operation_type,
        request.command,
        nil,
        request.receipt_id,
        request.original_request_key,
        request.transaction_id,
        request.command_digest,
        request.expected_result_digest,
        'request',
        'identity'
    )
    if invalid then
        return invalid
    end
    return port_ok(true)
end

local function validate_result_identity(value, request, include_request_key)
    local invalid
    if request ~= nil then
        invalid = port_check_result_request_echo(
            value,
            'player_save_scope',
            request
        )
        if invalid then
            return invalid
        end
        invalid = port_check_result_request_echo(
            value,
            'receipt_id',
            request
        )
        if invalid then
            return invalid
        end
        invalid = port_check_result_request_echo(
            value,
            'transaction_id',
            request
        )
        if invalid then
            return invalid
        end
        invalid = port_check_result_request_echo(
            value,
            'operation_type',
            request
        )
        if invalid then
            return invalid
        end
        invalid = port_check_result_request_echo(
            value,
            'command_digest',
            request
        )
        if invalid then
            return invalid
        end
    end
    if include_request_key then
        invalid = port_check_result_string(value, 'request_key', false)
        if invalid then
            return invalid
        end
        if request ~= nil
            and value.request_key ~= request.context.idempotency_key
        then
            return port_invalid_result(
                'request_key',
                'REQUEST_ECHO_MISMATCH'
            )
        end
    end
    return nil
end

local function validate_load_success(value, request)
    if type(value) ~= 'table' then
        return port_invalid_result('value', 'TABLE_REQUIRED')
    end
    local invalid = validate_enum(
        value.status,
        LOAD_STATUSES,
        'result',
        'status'
    )
    if invalid then
        return invalid
    end
    if value.status == 'FOUND' then
        invalid = exact_fields(value, {
            'status',
            'player_save_scope',
            'character_id',
            'character_save_revision',
            'state',
        }, nil, 'result', 'value')
    elseif value.status == 'READ_ONLY_ISOLATED' then
        invalid = exact_fields(value, {
            'status',
            'player_save_scope',
            'character_id',
            'character_save_revision',
            'issue_codes',
        }, nil, 'result', 'value')
    else
        invalid = exact_fields(value, {
            'status',
            'player_save_scope',
            'character_id',
            'character_save_revision',
        }, nil, 'result', 'value')
    end
    if invalid then
        return invalid
    end
    if request ~= nil then
        invalid = port_check_result_request_echo(
            value,
            'player_save_scope',
            request
        )
        if invalid then
            return invalid
        end
        invalid = port_check_result_request_echo(
            value,
            'character_id',
            request
        )
        if invalid then
            return invalid
        end
    end
    invalid = validate_player_save_scope(
        value.player_save_scope,
        'result',
        'player_save_scope'
    )
    if invalid then
        return invalid
    end
    invalid = validate_character_id(value.character_id, 'result', 'character_id')
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.character_save_revision,
        0,
        MAX_SAFE_INTEGER,
        'result',
        'character_save_revision'
    )
    if invalid then
        return invalid
    end
    if value.status == 'FOUND' then
        invalid = validate_state(value.state, 'result', 'state')
        if invalid then
            return invalid
        end
        if value.state.character_id ~= value.character_id then
            return port_invalid_result(
                'state.character_id',
                'CHARACTER_ECHO_MISMATCH'
            )
        end
        if value.state.revision > value.character_save_revision then
            return port_invalid_result(
                'state.revision',
                'CHARACTER_REVISION_ABOVE_CHARACTER_SAVE_REVISION'
            )
        end
    elseif value.status == 'READ_ONLY_ISOLATED' then
        if type(value.issue_codes) ~= 'table'
            or not is_dense_array(value.issue_codes)
            or #value.issue_codes < 1
            or #value.issue_codes > 64
        then
            return port_invalid_result(
                'issue_codes',
                'BOUNDED_NON_EMPTY_LIST_REQUIRED'
            )
        end
        local previous
        local index
        for index = 1, #value.issue_codes do
            local code = value.issue_codes[index]
            if not READ_ONLY_ISSUE_CODES[code] then
                return port_invalid_result(
                    'issue_codes',
                    'ISSUE_CODE_NOT_ALLOWED',
                    { entry_index = index }
                )
            end
            if previous ~= nil
                and not bytewise_string_less(previous, code)
            then
                return port_invalid_result(
                    'issue_codes',
                    'STRICT_ASCENDING_ORDER_REQUIRED',
                    { entry_index = index }
                )
            end
            previous = code
        end
    end
    return port_ok(true)
end

local function validate_commit_success(value, request)
    local invalid = exact_fields(value, {
        'status',
        'player_save_scope',
        'request_key',
        'receipt_id',
        'transaction_id',
        'operation_type',
        'command_digest',
        'character_save_revision',
        'receipt_save_revision',
        'character_revision',
        'result_digest',
        'result',
    }, nil, 'result', 'value')
    if invalid then
        return invalid
    end
    if value.status ~= 'COMMITTED' then
        return port_invalid_result('status', 'COMMITTED_REQUIRED')
    end
    invalid = validate_result_identity(value, request, true)
    if invalid then
        return invalid
    end
    invalid = validate_player_save_scope(
        value.player_save_scope,
        'result',
        'player_save_scope'
    )
    if invalid then
        return invalid
    end
    invalid = validate_receipt_id(value.receipt_id, 'result', 'receipt_id')
    if invalid then
        return invalid
    end
    invalid = validate_enum(
        value.operation_type,
        OPERATION_TYPES,
        'result',
        'operation_type'
    )
    if invalid then
        return invalid
    end
    invalid = validate_hash(value.command_digest, 'result', 'command_digest')
    if invalid then
        return invalid
    end
    invalid = validate_transaction_id(
        value.transaction_id,
        value.receipt_id,
        value.request_key,
        value.command_digest,
        value.result_digest,
        'result',
        'transaction_id'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.character_save_revision,
        0,
        MAX_SAFE_INTEGER,
        'result',
        'character_save_revision'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.receipt_save_revision,
        1,
        MAX_SAFE_INTEGER,
        'result',
        'receipt_save_revision'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.character_revision,
        0,
        MAX_SAFE_INTEGER,
        'result',
        'character_revision'
    )
    if invalid then
        return invalid
    end
    if value.character_revision > value.character_save_revision then
        return port_invalid_result(
            'character_revision',
            'CHARACTER_REVISION_ABOVE_CHARACTER_SAVE_REVISION'
        )
    end
    local result_info
    result_info, invalid = validate_typed_result(
        value.result,
        value.operation_type,
        'result',
        'result'
    )
    if invalid then
        return invalid
    end
    local commit_created_receipt_id
    if value.operation_type == CREATE_OWNED_CHARACTER then
        if value.result.already_owned then
            commit_created_receipt_id = value.result.created_receipt_id
        end
    elseif request ~= nil then
        commit_created_receipt_id = request.command.created_receipt_id
    end
    if commit_created_receipt_id ~= nil then
        invalid = validate_created_receipt_identity(
            commit_created_receipt_id,
            value.receipt_id,
            value.request_key,
            value.transaction_id,
            value.command_digest,
            value.result_digest,
            'result',
            'result.created_receipt_id'
        )
        if invalid then
            return invalid
        end
    end
    if value.operation_type == GRANT_CHARACTER_EXPERIENCE then
        invalid = validate_reward_receipt_identity(
            value.result,
            value.receipt_id,
            commit_created_receipt_id,
            value.request_key,
            value.transaction_id,
            value.command_digest,
            value.result_digest,
            'result',
            'result.reward_receipt_id'
        )
        if invalid then
            return invalid
        end
    end
    invalid = validate_hash(value.result_digest, 'result', 'result_digest')
    if invalid then
        return invalid
    end
    invalid = validate_primary_identity_separation(
        value.receipt_id,
        value.request_key,
        value.command_digest,
        value.result_digest,
        'result',
        'identity'
    )
    if invalid then
        return invalid
    end
    local commit_command = request ~= nil and request.command or nil
    invalid = validate_nested_digest_identity_separation(
        value.operation_type,
        commit_command,
        value.result,
        value.receipt_id,
        value.request_key,
        value.transaction_id,
        value.command_digest,
        value.result_digest,
        'result',
        'identity'
    )
    if invalid then
        return invalid
    end
    if value.result_digest ~= result_info.digest
        or value.character_revision ~= value.result.character_revision
    then
        return port_invalid_result(
            'result_digest',
            'RESULT_BINDING_MISMATCH'
        )
    end
    if request ~= nil then
        local expected_character_save_revision = request.expected_character_save_revision
        if request.change_type ~= 'NO_CHANGE' then
            expected_character_save_revision = expected_character_save_revision + 1
        end
        if value.character_save_revision ~= expected_character_save_revision then
            return port_invalid_result(
                'character_save_revision',
                'CHARACTER_SAVE_REVISION_RESULT_MISMATCH'
            )
        end
        if value.result_digest ~= request.result_digest
            or not scalar_tables_equal(value.result, request.result)
        then
            return port_invalid_result(
                'result',
                'FIRST_RESULT_REPLAY_MISMATCH'
            )
        end
    end
    return port_ok(true)
end

local function validate_query_success(value, request)
    if type(value) ~= 'table' then
        return port_invalid_result('value', 'TABLE_REQUIRED')
    end
    local invalid = validate_enum(
        value.status,
        QUERY_STATUSES,
        'result',
        'status'
    )
    if invalid then
        return invalid
    end
    local base_fields = {
        'status',
        'player_save_scope',
        'original_request_key',
        'receipt_id',
        'transaction_id',
        'operation_type',
        'command_digest',
        'expected_result_digest',
        'expected_character_save_revision',
    }
    if value.status == 'COMMITTED' then
        local committed_fields = {}
        local index
        for index = 1, #base_fields do
            committed_fields[index] = base_fields[index]
        end
        committed_fields[#committed_fields + 1] = 'character_save_revision'
        committed_fields[#committed_fields + 1] = 'receipt_save_revision'
        committed_fields[#committed_fields + 1] = 'character_revision'
        committed_fields[#committed_fields + 1] = 'result_digest'
        committed_fields[#committed_fields + 1] = 'result'
        invalid = exact_fields(value, committed_fields, nil, 'result', 'value')
    else
        invalid = exact_fields(value, base_fields, nil, 'result', 'value')
    end
    if invalid then
        return invalid
    end
    invalid = validate_player_save_scope(
        value.player_save_scope,
        'result',
        'player_save_scope'
    )
    if invalid then
        return invalid
    end
    invalid = validate_receipt_id(value.receipt_id, 'result', 'receipt_id')
    if invalid then
        return invalid
    end
    invalid = validate_enum(
        value.operation_type,
        OPERATION_TYPES,
        'result',
        'operation_type'
    )
    if invalid then
        return invalid
    end
    invalid = validate_hash(value.command_digest, 'result', 'command_digest')
    if invalid then
        return invalid
    end
    invalid = validate_hash(
        value.expected_result_digest,
        'result',
        'expected_result_digest'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.expected_character_save_revision,
        0,
        MAX_SAFE_INTEGER,
        'result',
        'expected_character_save_revision'
    )
    if invalid then
        return invalid
    end
    invalid = validate_transaction_id(
        value.transaction_id,
        value.receipt_id,
        value.original_request_key,
        value.command_digest,
        value.expected_result_digest,
        'result',
        'transaction_id'
    )
    if invalid then
        return invalid
    end
    if request ~= nil then
        local echo_fields = {
            'player_save_scope',
            'original_request_key',
            'receipt_id',
            'transaction_id',
            'operation_type',
            'command_digest',
            'expected_result_digest',
            'expected_character_save_revision',
        }
        local index
        for index = 1, #echo_fields do
            invalid = port_check_result_request_echo(
                value,
                echo_fields[index],
                request
            )
            if invalid then
                return invalid
            end
        end
    end
    invalid = validate_transport_key(
        value.original_request_key,
        value.receipt_id,
        'result',
        'original_request_key'
    )
    if invalid then
        return invalid
    end
    invalid = validate_primary_identity_separation(
        value.receipt_id,
        value.original_request_key,
        value.command_digest,
        value.expected_result_digest,
        'result',
        'identity'
    )
    if invalid then
        return invalid
    end
    if value.status ~= 'COMMITTED' then
        return port_ok(true)
    end
    invalid = validate_integer(
        value.character_save_revision,
        0,
        MAX_SAFE_INTEGER,
        'result',
        'character_save_revision'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.character_revision,
        0,
        MAX_SAFE_INTEGER,
        'result',
        'character_revision'
    )
    if invalid then
        return invalid
    end
    invalid = validate_integer(
        value.receipt_save_revision,
        1,
        MAX_SAFE_INTEGER,
        'result',
        'receipt_save_revision'
    )
    if invalid then
        return invalid
    end
    if value.character_revision > value.character_save_revision then
        return port_invalid_result(
            'character_revision',
            'CHARACTER_REVISION_ABOVE_CHARACTER_SAVE_REVISION'
        )
    end
    local result_info
    result_info, invalid = validate_typed_result(
        value.result,
        value.operation_type,
        'result',
        'result'
    )
    if invalid then
        return invalid
    end
    local target_character_save_revision =
        value.expected_character_save_revision
    if value.operation_type ~= CREATE_OWNED_CHARACTER
        or not value.result.already_owned
    then
        if target_character_save_revision == MAX_SAFE_INTEGER then
            return port_invalid_result(
                'expected_character_save_revision',
                'CHARACTER_SAVE_REVISION_INCREMENT_OVERFLOW'
            )
        end
        target_character_save_revision = target_character_save_revision + 1
    end
    if value.character_save_revision ~= target_character_save_revision then
        return port_invalid_result(
            'character_save_revision',
            'CHARACTER_SAVE_REVISION_RESULT_MISMATCH'
        )
    end
    local created_receipt_id
    if value.operation_type == CREATE_OWNED_CHARACTER then
        if value.result.already_owned then
            created_receipt_id = value.result.created_receipt_id
        end
    elseif request ~= nil then
        created_receipt_id = request.command.created_receipt_id
    end
    if created_receipt_id ~= nil then
        invalid = validate_created_receipt_identity(
            created_receipt_id,
            value.receipt_id,
            value.original_request_key,
            value.transaction_id,
            value.command_digest,
            value.result_digest,
            'result',
            'result.created_receipt_id'
        )
        if invalid then
            return invalid
        end
    end
    if value.operation_type == GRANT_CHARACTER_EXPERIENCE then
        invalid = validate_reward_receipt_identity(
            value.result,
            value.receipt_id,
            created_receipt_id,
            value.original_request_key,
            value.transaction_id,
            value.command_digest,
            value.result_digest,
            'result',
            'result.reward_receipt_id'
        )
        if invalid then
            return invalid
        end
    end
    invalid = validate_hash(value.result_digest, 'result', 'result_digest')
    if invalid then
        return invalid
    end
    invalid = validate_primary_identity_separation(
        value.receipt_id,
        value.original_request_key,
        value.command_digest,
        value.result_digest,
        'result',
        'identity'
    )
    if invalid then
        return invalid
    end
    local query_command = request ~= nil and request.command or nil
    invalid = validate_nested_digest_identity_separation(
        value.operation_type,
        query_command,
        value.result,
        value.receipt_id,
        value.original_request_key,
        value.transaction_id,
        value.command_digest,
        value.result_digest,
        'result',
        'identity'
    )
    if invalid then
        return invalid
    end
    if value.result_digest ~= value.expected_result_digest then
        return port_invalid_result(
            'result_digest',
            'EXPECTED_RESULT_DIGEST_MISMATCH'
        )
    end
    if request ~= nil
        and value.result_digest ~= request.expected_result_digest
    then
        return port_invalid_result(
            'result_digest',
            'EXPECTED_RESULT_DIGEST_MISMATCH'
        )
    end
    if value.result_digest ~= result_info.digest
        or value.character_revision ~= value.result.character_revision
    then
        return port_invalid_result(
            'result_digest',
            'RESULT_BINDING_MISMATCH'
        )
    end
    if request ~= nil then
        invalid = validate_result_against_command(
            value.result,
            request.command,
            value.operation_type,
            request.receipt_id,
            request.original_request_key,
            request.transaction_id,
            request.command_digest,
            value.result_digest,
            'result',
            'result'
        )
        if invalid then
            return invalid
        end
    end
    return port_ok(true)
end

local function validate_repository_error(error_value, request, phase)
    local details = error_value.details
    local is_query_request = request ~= nil
        and request.original_request_key ~= nil
    local query_request_key
    if is_query_request
        and type(request.context) == 'table'
    then
        query_request_key = request.context.idempotency_key
    end
    local invalid = validate_error_details(error_value)
    if invalid then
        return invalid
    end
    if details ~= nil and details.request_key ~= nil then
        if query_request_key ~= nil then
            local stable_request_key = validate_runtime_component(
                details.request_key,
                'error.details.request_key'
            )
            if not stable_request_key.ok then
                return port_invalid_result(
                    'error.details.request_key',
                    'RUNTIME_REQUEST_KEY_REQUIRED'
                )
            end
        else
            invalid = validate_hash(
                details.request_key,
                'result',
                'error.details.request_key'
            )
            if invalid then
                return invalid
            end
        end
    end
    if details ~= nil and details.receipt_id ~= nil then
        invalid = validate_receipt_id(
            details.receipt_id,
            'result',
            'error.details.receipt_id'
        )
        if invalid then
            return invalid
        end
        if request ~= nil
            and details.receipt_id ~= request.receipt_id
        then
            return port_invalid_result(
                'error.details.receipt_id',
                'ERROR_RECEIPT_ID_MISMATCH'
            )
        end
    end
    if details ~= nil and details.transaction_id ~= nil then
        local checked_transaction = validate_runtime_component(
            details.transaction_id,
            'error.details.transaction_id'
        )
        if not checked_transaction.ok then
            return port_invalid_result(
                'error.details.transaction_id',
                'ATOMIC_TRANSACTION_ID_REQUIRED'
            )
        end
        if request ~= nil
            and details.transaction_id ~= request.transaction_id
        then
            return port_invalid_result(
                'error.details.transaction_id',
                'ERROR_TRANSACTION_ID_MISMATCH'
            )
        end
    end
    if details ~= nil and details.player_save_scope ~= nil then
        local checked_scope = validate_runtime_component(
            details.player_save_scope,
            'error.details.player_save_scope'
        )
        if not checked_scope.ok then
            return port_invalid_result(
                'error.details.player_save_scope',
                'PLAYER_SAVE_SCOPE_REQUIRED'
            )
        end
    end
    if details ~= nil and details.original_request_key ~= nil then
        invalid = validate_hash(
            details.original_request_key,
            'result',
            'error.details.original_request_key'
        )
        if invalid then
            return invalid
        end
    end
    if details ~= nil and details.command_digest ~= nil then
        invalid = validate_hash(
            details.command_digest,
            'result',
            'error.details.command_digest'
        )
        if invalid then
            return invalid
        end
    end
    if details ~= nil and details.expected_result_digest ~= nil then
        invalid = validate_hash(
            details.expected_result_digest,
            'result',
            'error.details.expected_result_digest'
        )
        if invalid then
            return invalid
        end
    end
    if details ~= nil and details.operation_type ~= nil then
        invalid = validate_enum(
            details.operation_type,
            OPERATION_TYPES,
            'result',
            'error.details.operation_type'
        )
        if invalid then
            return invalid
        end
    end

    if error_value.retryable then
        return port_invalid_result(
            'error.retryable',
            'REPOSITORY_ERROR_MUST_NOT_BE_RETRYABLE'
        )
    end

    local commit_request_key
    local expected_request_key
    if request ~= nil
        and type(request.context) == 'table'
        and not is_query_request
    then
        commit_request_key = request.context.idempotency_key
    end
    if phase == 'COMPLETION' then
        if is_query_request then
            expected_request_key = query_request_key
        else
            expected_request_key = commit_request_key
        end
        if expected_request_key == nil
            and is_query_request
        then
            expected_request_key = request.original_request_key
        end
    elseif commit_request_key ~= nil then
        expected_request_key = commit_request_key
    end

    local request_binding_key = commit_request_key
    if is_query_request then
        request_binding_key = query_request_key
            or request.original_request_key
    end
    if details ~= nil
        and details.request_key ~= nil
        and request_binding_key ~= nil
        and details.request_key ~= request_binding_key
    then
        return port_invalid_result(
            'error.details.request_key',
            'COMPLETION_REQUEST_KEY_MISMATCH'
        )
    end
    if error_value.code == 'SAVE_REVISION_CONFLICT'
        and details ~= nil
        and details.expected_character_save_revision ~= nil
        and request ~= nil
        and details.expected_character_save_revision
            ~= request.expected_character_save_revision
    then
        return port_invalid_result(
            'error.details.expected_character_save_revision',
            'EXPECTED_CHARACTER_SAVE_REVISION_MISMATCH'
        )
    end
    if error_value.code == 'TRANSACTION_RECOVERY_REQUIRED'
        and details ~= nil
        and details.recovery ~= nil
        and details.recovery ~= 'QUERY_OR_RECONCILE'
    then
        return port_invalid_result(
            'error.details.recovery',
            'QUERY_OR_RECONCILE_REQUIRED'
        )
    end

    if phase == 'COMPLETION'
        and COMMIT_BUSINESS_ERROR_CODES[error_value.code]
        and not is_query_request
    then
        if type(details) ~= 'table'
            or details.request_key == nil
        then
            return port_invalid_result(
                'error.details.request_key',
                'COMPLETION_REQUEST_KEY_REQUIRED'
            )
        end
        if commit_request_key ~= nil
            and details.request_key ~= commit_request_key
        then
            return port_invalid_result(
                'error.details.request_key',
                'COMPLETION_REQUEST_KEY_MISMATCH'
            )
        end
    end
    if phase == 'COMPLETION'
        and error_value.code == 'IDEMPOTENCY_KEY_REUSED'
        and commit_request_key ~= nil
        and not is_query_request
    then
        if type(details) ~= 'table'
            or details.request_key ~= commit_request_key
        then
            return port_invalid_result(
                'error.details.request_key',
                'COMPLETION_REQUEST_KEY_MISMATCH'
            )
        end
        if details.receipt_id ~= request.receipt_id then
            return port_invalid_result(
                'error.details.receipt_id',
                'ERROR_RECEIPT_ID_MISMATCH'
            )
        end
        if details.transaction_id ~= request.transaction_id then
            return port_invalid_result(
                'error.details.transaction_id',
                'ERROR_TRANSACTION_ID_MISMATCH'
            )
        end
    end

    if phase == 'COMPLETION'
        and error_value.code == 'IDEMPOTENCY_KEY_REUSED'
        and request ~= nil
        and is_query_request
    then
        if type(details) ~= 'table'
            or details.player_save_scope == nil
            or details.original_request_key == nil
            or details.receipt_id == nil
            or details.transaction_id == nil
            or details.operation_type == nil
            or details.command_digest == nil
            or details.expected_result_digest == nil
            or details.expected_character_save_revision == nil
        then
            return port_invalid_result(
                'error.details',
                'QUERY_IDENTITY_DETAILS_REQUIRED'
            )
        end
        if details.request_key ~= nil then
            return port_invalid_result(
                'error.details.request_key',
                'QUERY_REQUEST_KEY_FIELD_FORBIDDEN'
            )
        end
        local query_identity_fields = {
            'player_save_scope',
            'original_request_key',
            'receipt_id',
            'transaction_id',
            'operation_type',
            'command_digest',
            'expected_result_digest',
            'expected_character_save_revision',
        }
        local identity_index
        for identity_index = 1, #query_identity_fields do
            local field_name = query_identity_fields[identity_index]
            if details[field_name] ~= request[field_name] then
                return port_invalid_result(
                    'error.details.' .. field_name,
                    'QUERY_ERROR_IDENTITY_MISMATCH'
                )
            end
        end
    end

    if phase == 'COMPLETION'
        and error_value.code == 'SAVE_REVISION_CONFLICT'
    then
        if type(details) ~= 'table'
            or details.expected_character_save_revision == nil
            or details.actual_character_save_revision == nil
            or details.actual_receipt_save_revision == nil
        then
            return port_invalid_result(
                'error.details',
                'SAVE_REVISION_CONFLICT_DETAILS_REQUIRED'
            )
        end
        if request ~= nil
            and details.expected_character_save_revision
                ~= request.expected_character_save_revision
        then
            return port_invalid_result(
                'error.details.expected_character_save_revision',
                'EXPECTED_CHARACTER_SAVE_REVISION_MISMATCH'
            )
        end
    end

    if phase == 'COMPLETION'
        and request ~= nil
        and error_value.code == 'TRANSACTION_RECOVERY_REQUIRED'
    then
        if type(details) ~= 'table'
            or details.recovery ~= 'QUERY_OR_RECONCILE'
        then
            return port_invalid_result(
                'error.details.recovery',
                'QUERY_OR_RECONCILE_REQUIRED'
            )
        end
        if details.receipt_id ~= request.receipt_id then
            return port_invalid_result(
                'error.details.receipt_id',
                'RECOVERY_RECEIPT_ID_MISMATCH'
            )
        end
        if details.transaction_id ~= request.transaction_id then
            return port_invalid_result(
                'error.details.transaction_id',
                'RECOVERY_TRANSACTION_ID_MISMATCH'
            )
        end
    end

    if (phase == 'COMPLETION' or commit_request_key ~= nil)
        and error_value.code == 'PLATFORM_RESULT_UNKNOWN'
    then
        if type(details) ~= 'table'
            or details.request_key == nil
        then
            return port_invalid_result(
                'error.details.request_key',
                'RECOVERY_REQUEST_KEY_REQUIRED'
            )
        end
        if request ~= nil and expected_request_key == nil then
            return port_invalid_result(
                'error.details.request_key',
                'RECOVERY_REQUEST_BINDING_UNAVAILABLE'
            )
        end
        if expected_request_key ~= nil
            and details.request_key ~= expected_request_key
        then
            return port_invalid_result(
                'error.details.request_key',
                'COMPLETION_REQUEST_KEY_MISMATCH'
            )
        end
        if details.recovery ~= 'QUERY_OR_RECONCILE' then
            return port_invalid_result(
                'error.details.recovery',
                'QUERY_OR_RECONCILE_REQUIRED'
            )
        end
        if details.cause_code == nil then
            return port_invalid_result(
                'error.details.cause_code',
                'STABLE_CAUSE_CODE_REQUIRED'
            )
        end
    end
    if error_value.code == 'PLATFORM_RESULT_UNKNOWN' then
        local allowed_causes = type(details) == 'table'
            and UNKNOWN_CAUSE_CODES_BY_REASON[details.reason]
            or nil
        if allowed_causes == nil
            or not allowed_causes[details.cause_code]
        then
            return port_invalid_result(
                'error.details.cause_code',
                'CAUSE_CODE_NOT_ALLOWED_FOR_REASON'
            )
        end
    end
    return port_ok(true)
end

return port_define({
    name = 'CharacterRepository',
    contract_version = 1,
    operations = {
        {
            name = 'load_character',
            request_fields = {
                'player_save_scope',
                'character_id',
            },
            validate_request = validate_load_request,
            validate_success = validate_load_success,
            validate_error = validate_repository_error,
        },
        {
            name = 'commit_character_transaction',
            request_fields = {
                'player_save_scope',
                'operation_type',
                'receipt_id',
                'transaction_id',
                'command_digest',
                'expected_character_save_revision',
                'change_type',
                'command',
                'before_state',
                'after_state',
                'result_digest',
                'result',
            },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_commit_request,
            validate_success = validate_commit_success,
            validate_error = validate_repository_error,
            error_codes = {
                'SAVE_REVISION_CONFLICT',
                'SAVE_READ_ONLY',
                'TRANSACTION_RECOVERY_REQUIRED',
            },
        },
        {
            name = 'query_character_transaction',
            request_fields = {
                'player_save_scope',
                'original_request_key',
                'receipt_id',
                'transaction_id',
                'operation_type',
                'command_digest',
                'expected_result_digest',
                'expected_character_save_revision',
                'command',
            },
            validate_request = validate_query_request,
            validate_success = validate_query_success,
            validate_error = validate_repository_error,
        },
    },
})
