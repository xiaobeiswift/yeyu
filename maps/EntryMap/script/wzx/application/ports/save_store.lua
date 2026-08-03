local PortContract = require "wzx.application.ports.port_contract"
local RuntimeId = require "wzx.domain.common.runtime_id"
local SaveEnvelope = require "wzx.domain.save.save_envelope"

local MAX_INTEGER = PortContract.MAX_SAFE_INTEGER
local MAX_SLOT_ID = 319

local function validate_player(request)
    local invalid = PortContract.check_non_empty_string(
        request,
        "player_ref",
        false
    )
    local validated
    if invalid then
        return invalid
    end
    validated = RuntimeId.validate_component(request.player_ref, "player_ref")
    if not validated.ok then
        return PortContract.invalid_request(
            "player_ref",
            "STABLE_PLAYER_REFERENCE_REQUIRED",
            { cause_code = validated.error.code }
        )
    end
    return nil
end

local function validate_slot(request)
    return PortContract.check_integer(request, "slot_id", 1, MAX_SLOT_ID, false)
end

local function validate_player_and_slot(request)
    local invalid = validate_player(request)
    if invalid then
        return invalid
    end
    invalid = validate_slot(request)
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_stage_slot(request)
    local invalid = validate_player(request)
    local envelope
    if invalid then
        return invalid
    end
    invalid = validate_slot(request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "expected_revision",
        0,
        MAX_INTEGER - 1,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_table(request, "dto", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_non_empty_string(
        request,
        "checkpoint_id",
        false
    )
    if invalid then
        return invalid
    end
    if type(request.payload_checksum) ~= "string"
        or #request.payload_checksum ~= 64
        or not string.match(request.payload_checksum, "^[0-9a-f]+$")
    then
        return PortContract.invalid_request(
            "payload_checksum",
            "LOWERCASE_SHA256_REQUIRED"
        )
    end
    envelope = SaveEnvelope.validate(request.dto)
    if not envelope.ok then
        return PortContract.invalid_request(
            "dto",
            "SAVE_ENVELOPE_REQUIRED",
            { cause = envelope.error }
        )
    end
    if request.dto.revision ~= request.expected_revision + 1 then
        return PortContract.invalid_request(
            "dto",
            "ENVELOPE_REVISION_MUST_ADVANCE_ONCE",
            {
                expected = request.expected_revision + 1,
                actual = request.dto.revision,
            }
        )
    end
    if request.checkpoint_id ~= request.dto.checkpoint_id then
        return PortContract.invalid_request(
            "checkpoint_id",
            "ENVELOPE_CHECKPOINT_MISMATCH"
        )
    end
    if request.payload_checksum ~= request.dto.payload_checksum then
        return PortContract.invalid_request(
            "payload_checksum",
            "ENVELOPE_CHECKSUM_MISMATCH"
        )
    end
    return PortContract.ok(true)
end

local function validate_commit(request)
    local invalid = validate_player(request)
    local seen_slots = {}
    local previous_slot_id = 0
    local index
    local entry
    if invalid then
        return invalid
    end
    invalid = PortContract.check_list(request, "commit_entries", false, false)
    if invalid then
        return invalid
    end
    if #request.commit_entries > 319 then
        return PortContract.invalid_request(
            "commit_entries",
            "LIST_TOO_LONG",
            { maximum = 319, actual = #request.commit_entries }
        )
    end
    for index = 1, #request.commit_entries do
        entry = request.commit_entries[index]
        if type(entry) ~= "table" then
            return PortContract.invalid_request(
                "commit_entries",
                "COMMIT_ENTRY_TABLE_REQUIRED",
                { entry_index = index }
            )
        end
        invalid = PortContract.check_table(
            { commit_entry = entry },
            "commit_entry",
            false
        )
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "commit_entries"
            return invalid
        end
        local entry_field
        for entry_field in pairs(entry) do
            if entry_field ~= "slot_id"
                and entry_field ~= "target_revision"
                and entry_field ~= "checkpoint_id"
                and entry_field ~= "payload_checksum"
            then
                return PortContract.invalid_request(
                    "commit_entries",
                    "COMMIT_ENTRY_UNKNOWN_FIELD",
                    { entry_index = index, field = tostring(entry_field) }
                )
            end
        end
        invalid = PortContract.check_integer(
            entry,
            "slot_id",
            1,
            MAX_SLOT_ID,
            false
        )
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "commit_entries"
            return invalid
        end
        invalid = PortContract.check_integer(
            entry,
            "target_revision",
            1,
            MAX_INTEGER,
            false
        )
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "commit_entries"
            return invalid
        end
        invalid = PortContract.check_non_empty_string(
            entry,
            "checkpoint_id",
            false
        )
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "commit_entries"
            return invalid
        end
        local checkpoint = RuntimeId.validate_derived(
            entry.checkpoint_id,
            "checkpoint_id"
        )
        if not checkpoint.ok then
            return PortContract.invalid_request(
                "commit_entries",
                "CHECKPOINT_ID_INVALID",
                { entry_index = index, cause_code = checkpoint.error.code }
            )
        end
        if type(entry.payload_checksum) ~= "string"
            or #entry.payload_checksum ~= 64
            or not string.match(entry.payload_checksum, "^[0-9a-f]+$")
        then
            return PortContract.invalid_request(
                "commit_entries",
                "PAYLOAD_CHECKSUM_INVALID",
                { entry_index = index }
            )
        end
        if seen_slots[entry.slot_id] then
            return PortContract.invalid_request(
                "commit_entries",
                "DUPLICATE_SLOT_FORBIDDEN",
                { entry_index = index, slot_id = entry.slot_id }
            )
        end
        if entry.slot_id <= previous_slot_id then
            return PortContract.invalid_request(
                "commit_entries",
                "SLOTS_MUST_BE_STRICTLY_ASCENDING",
                { entry_index = index, slot_id = entry.slot_id }
            )
        end
        seen_slots[entry.slot_id] = true
        previous_slot_id = entry.slot_id
    end
    return PortContract.ok(true)
end

local function validate_upload(request)
    local invalid = validate_player(request)
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_compare_and_add(request)
    local invalid = validate_player(request)
    if invalid then
        return invalid
    end
    invalid = validate_slot(request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "expected_value",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "expected_revision",
        0,
        MAX_INTEGER - 1,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(request, "delta", 0, MAX_INTEGER, false)
    if invalid then
        return invalid
    end
    if request.expected_value + request.delta > MAX_INTEGER then
        return PortContract.invalid_request("delta", "SAFE_INTEGER_OVERFLOW")
    end
    return PortContract.ok(true)
end

local function validate_compare_and_set(request)
    local invalid = validate_player(request)
    if invalid then
        return invalid
    end
    invalid = validate_slot(request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "expected_value",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "expected_revision",
        0,
        MAX_INTEGER - 1,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "target_value",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    if request.target_value < request.expected_value then
        return PortContract.invalid_request(
            "target_value",
            "MONOTONIC_TARGET_REQUIRED",
            {
                expected_value = request.expected_value,
                target_value = request.target_value,
            }
        )
    end
    return PortContract.ok(true)
end

local function validate_query_integer_request(request)
    local invalid = validate_player(request)
    local original_key
    if invalid then
        return invalid
    end
    invalid = validate_slot(request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_non_empty_string(
        request,
        "original_idempotency_key",
        false
    )
    if invalid then
        return invalid
    end
    original_key = RuntimeId.validate_component(
        request.original_idempotency_key,
        "original_idempotency_key"
    )
    if not original_key.ok then
        return PortContract.invalid_request(
            "original_idempotency_key",
            "STABLE_REQUEST_KEY_REQUIRED",
            { cause_code = original_key.error.code }
        )
    end
    return PortContract.ok(true)
end

local function validate_checksum(value, field_name)
    if type(value) ~= "string"
        or #value ~= 64
        or not string.match(value, "^[0-9a-f]+$")
    then
        return PortContract.invalid_result(
            field_name,
            "LOWERCASE_SHA256_REQUIRED"
        )
    end
    return nil
end

local function validate_result_player(value, request)
    local invalid = PortContract.check_result_string(
        value,
        "player_ref",
        false
    )
    local validated
    if invalid then
        return invalid
    end
    validated = RuntimeId.validate_component(value.player_ref, "player_ref")
    if not validated.ok then
        return PortContract.invalid_result(
            "player_ref",
            "STABLE_PLAYER_REFERENCE_REQUIRED",
            { cause_code = validated.error.code }
        )
    end
    return PortContract.check_result_request_echo(
        value,
        "player_ref",
        request
    )
end

local function validate_result_request_key(value, request)
    local invalid = PortContract.check_result_string(
        value,
        "request_key",
        false
    )
    local expected
    if invalid then
        return invalid
    end
    if request ~= nil then
        expected = type(request.context) == "table"
            and request.context.idempotency_key
            or nil
        if expected == nil or value.request_key ~= expected then
            return PortContract.invalid_result(
                "request_key",
                "REQUEST_ECHO_MISMATCH",
                { expected = expected, actual = value.request_key }
            )
        end
    end
    return nil
end

local function validate_slot_read_success(value, request)
    local invalid = PortContract.check_result_fields(value, {
        "player_ref",
        "slot_id",
        "dto",
        "revision",
        "checkpoint_id",
        "payload_checksum",
    })
    if invalid then
        return invalid
    end
    invalid = validate_result_player(value, request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "slot_id",
        1,
        MAX_SLOT_ID,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "slot_id",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_table(value, "dto", false)
    if invalid then
        return invalid
    end
    local envelope = SaveEnvelope.validate(value.dto)
    if not envelope.ok then
        return PortContract.invalid_result(
            "dto",
            "SAVE_ENVELOPE_REQUIRED",
            { cause = envelope.error }
        )
    end
    invalid = PortContract.check_result_integer(
        value,
        "revision",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(value, "checkpoint_id", false)
    if invalid then
        return invalid
    end
    invalid = validate_checksum(value.payload_checksum, "payload_checksum")
    if invalid then
        return invalid
    end
    if value.dto.revision ~= value.revision
        or value.dto.checkpoint_id ~= value.checkpoint_id
        or value.dto.payload_checksum ~= value.payload_checksum
    then
        return PortContract.invalid_result(
            "dto",
            "ENVELOPE_METADATA_MISMATCH"
        )
    end
    return PortContract.ok(true)
end

local function validate_stage_success(value, request)
    local invalid = PortContract.check_result_fields(value, {
        "player_ref",
        "slot_id",
        "revision",
        "checkpoint_id",
        "payload_checksum",
        "request_key",
    })
    if invalid then
        return invalid
    end
    invalid = validate_result_player(value, request)
    if invalid then
        return invalid
    end
    invalid = validate_result_request_key(value, request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "slot_id",
        1,
        MAX_SLOT_ID,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "slot_id",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "revision",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    if request ~= nil
        and value.revision ~= request.expected_revision + 1
    then
        return PortContract.invalid_result(
            "revision",
            "STAGE_REVISION_MUST_ADVANCE_ONCE",
            {
                expected = request.expected_revision + 1,
                actual = value.revision,
            }
        )
    end
    invalid = PortContract.check_result_string(value, "checkpoint_id", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "checkpoint_id",
        request
    )
    if invalid then
        return invalid
    end
    invalid = validate_checksum(value.payload_checksum, "payload_checksum")
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "payload_checksum",
        request
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local COMMIT_FAILURE_CODES = {
    PLATFORM_INVALID_ARGUMENT = true,
    PLATFORM_PERMISSION_DENIED = true,
    PLATFORM_QUOTA_EXCEEDED = true,
    PLATFORM_RESULT_UNKNOWN = true,
    SAVE_REVISION_CONFLICT = true,
}

local function validate_commit_row(row, index)
    local invalid
    local required_fields

    if type(row) ~= "table" then
        return PortContract.invalid_result("slot_results", "ROW_TABLE_REQUIRED", {
            entry_index = index,
        })
    end
    if row.status == "CONFIRMED" then
        required_fields = {
            "slot_id",
            "status",
            "target_revision",
            "checkpoint_id",
            "payload_checksum",
        }
    elseif row.status == "FAILED" or row.status == "UNKNOWN" then
        required_fields = { "slot_id", "status", "error_code" }
    else
        return PortContract.invalid_result("slot_results", "ROW_STATUS_INVALID", {
            entry_index = index,
            actual = row.status,
        })
    end
    invalid = PortContract.check_result_fields(row, required_fields)
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "slot_results"
        return invalid
    end
    invalid = PortContract.check_result_integer(
        row,
        "slot_id",
        1,
        MAX_SLOT_ID,
        false
    )
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "slot_results"
        return invalid
    end
    if row.status == "CONFIRMED" then
        invalid = PortContract.check_result_integer(
            row,
            "target_revision",
            1,
            MAX_INTEGER,
            false
        )
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "slot_results"
            return invalid
        end
        invalid = PortContract.check_result_string(
            row,
            "checkpoint_id",
            false
        )
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "slot_results"
            return invalid
        end
        local checkpoint = RuntimeId.validate_derived(
            row.checkpoint_id,
            "checkpoint_id"
        )
        if not checkpoint.ok then
            return PortContract.invalid_result(
                "slot_results",
                "CHECKPOINT_ID_INVALID",
                { entry_index = index, cause_code = checkpoint.error.code }
            )
        end
        invalid = validate_checksum(
            row.payload_checksum,
            "payload_checksum"
        )
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "slot_results"
            return invalid
        end
    else
        if type(row.error_code) ~= "string"
            or not COMMIT_FAILURE_CODES[row.error_code]
        then
            return PortContract.invalid_result(
                "slot_results",
                "ROW_ERROR_CODE_INVALID",
                { entry_index = index, actual = row.error_code }
            )
        end
        if row.status == "UNKNOWN"
            and row.error_code ~= "PLATFORM_RESULT_UNKNOWN"
        then
            return PortContract.invalid_result(
                "slot_results",
                "UNKNOWN_ROW_REQUIRES_UNKNOWN_RESULT_CODE",
                { entry_index = index, actual = row.error_code }
            )
        end
        if row.status == "FAILED"
            and row.error_code == "PLATFORM_RESULT_UNKNOWN"
        then
            return PortContract.invalid_result(
                "slot_results",
                "UNKNOWN_RESULT_REQUIRES_UNKNOWN_ROW_STATUS",
                { entry_index = index }
            )
        end
    end
    return nil
end

local function validate_commit_success(value, request)
    local invalid = PortContract.check_result_fields(
        value,
        { "player_ref", "status", "slot_results", "request_key" }
    )
    local seen_slots = {}
    local has_non_confirmed = false
    local index
    local row

    if invalid then
        return invalid
    end
    invalid = validate_result_player(value, request)
    if invalid then
        return invalid
    end
    invalid = validate_result_request_key(value, request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_enum(
        value,
        "status",
        { "CONFIRMED", "PARTIAL" },
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_list(
        value,
        "slot_results",
        false,
        false
    )
    if invalid then
        return invalid
    end
    if #value.slot_results > 319 then
        return PortContract.invalid_result("slot_results", "LIST_TOO_LONG", {
            maximum = 319,
            actual = #value.slot_results,
        })
    end
    for index = 1, #value.slot_results do
        row = value.slot_results[index]
        invalid = validate_commit_row(row, index)
        if invalid then
            return invalid
        end
        if seen_slots[row.slot_id] then
            return PortContract.invalid_result(
                "slot_results",
                "DUPLICATE_SLOT_FORBIDDEN",
                { entry_index = index, slot_id = row.slot_id }
            )
        end
        seen_slots[row.slot_id] = true
        if row.status ~= "CONFIRMED" then
            has_non_confirmed = true
        end
    end
    if request ~= nil then
        if type(request.commit_entries) ~= "table"
            or #request.commit_entries ~= #value.slot_results
        then
            return PortContract.invalid_result(
                "slot_results",
                "COMMIT_RESULT_COUNT_MISMATCH"
            )
        end
        for index = 1, #value.slot_results do
            if value.slot_results[index].slot_id
                ~= request.commit_entries[index].slot_id
            then
                return PortContract.invalid_result(
                    "slot_results",
                    "COMMIT_SLOT_ORDER_MISMATCH",
                    {
                        entry_index = index,
                        expected_slot_id = request.commit_entries[index].slot_id,
                        actual_slot_id = value.slot_results[index].slot_id,
                    }
                )
            end
            if value.slot_results[index].status == "CONFIRMED" then
                local result_row = value.slot_results[index]
                local request_row = request.commit_entries[index]
                if result_row.target_revision ~= request_row.target_revision
                    or result_row.checkpoint_id ~= request_row.checkpoint_id
                    or result_row.payload_checksum
                        ~= request_row.payload_checksum
                then
                    return PortContract.invalid_result(
                        "slot_results",
                        "COMMIT_TARGET_ECHO_MISMATCH",
                        { entry_index = index }
                    )
                end
            end
        end
    end
    if value.status == "CONFIRMED" and has_non_confirmed then
        return PortContract.invalid_result(
            "status",
            "CONFIRMED_REQUIRES_ALL_ROWS_CONFIRMED"
        )
    end
    if value.status == "PARTIAL" and not has_non_confirmed then
        return PortContract.invalid_result(
            "status",
            "PARTIAL_REQUIRES_NON_CONFIRMED_ROW"
        )
    end
    return PortContract.ok(true)
end

local function validate_upload_success(value, request)
    local invalid = PortContract.check_result_fields(
        value,
        { "player_ref", "status", "request_key" },
        { "upload_ref" }
    )
    if invalid then
        return invalid
    end
    invalid = validate_result_player(value, request)
    if invalid then
        return invalid
    end
    invalid = validate_result_request_key(value, request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_enum(
        value,
        "status",
        { "CONFIRMED" },
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(value, "upload_ref", true)
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_integer_success(value, request, require_request_key)
    local required_fields = { "player_ref", "slot_id", "value", "revision" }
    if require_request_key then
        required_fields[#required_fields + 1] = "request_key"
    end
    local invalid = PortContract.check_result_fields(
        value,
        required_fields
    )
    if invalid then
        return invalid
    end
    invalid = validate_result_player(value, request)
    if invalid then
        return invalid
    end
    if require_request_key then
        invalid = validate_result_request_key(value, request)
        if invalid then
            return invalid
        end
    end
    invalid = PortContract.check_result_integer(
        value,
        "slot_id",
        1,
        MAX_SLOT_ID,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "slot_id",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "value",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "revision",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_add_integer_success(value, request)
    local invalid = validate_integer_success(value, request, true)
    if not invalid.ok then
        return invalid
    end
    if request ~= nil then
        local expected_value = request.expected_value + request.delta
        if value.value ~= expected_value then
            return PortContract.invalid_result(
                "value",
                "ADD_RESULT_VALUE_MISMATCH",
                { expected = expected_value, actual = value.value }
            )
        end
        if value.revision ~= request.expected_revision + 1 then
            return PortContract.invalid_result(
                "revision",
                "INTEGER_REVISION_MUST_ADVANCE_ONCE",
                {
                    expected = request.expected_revision + 1,
                    actual = value.revision,
                }
            )
        end
    end
    return PortContract.ok(true)
end

local function validate_set_integer_success(value, request)
    local invalid = validate_integer_success(value, request, true)
    if not invalid.ok then
        return invalid
    end
    if request ~= nil then
        if value.value ~= request.target_value then
            return PortContract.invalid_result(
                "value",
                "SET_RESULT_VALUE_MISMATCH",
                { expected = request.target_value, actual = value.value }
            )
        end
        if value.revision ~= request.expected_revision + 1 then
            return PortContract.invalid_result(
                "revision",
                "INTEGER_REVISION_MUST_ADVANCE_ONCE",
                {
                    expected = request.expected_revision + 1,
                    actual = value.revision,
                }
            )
        end
    end
    return PortContract.ok(true)
end

local function validate_query_integer_success(value, request)
    local invalid

    if type(value) ~= "table" then
        return PortContract.invalid_result("value", "TABLE_REQUIRED")
    end
    if value.status == "CONFIRMED" then
        invalid = PortContract.check_result_fields(
            value,
            {
                "status",
                "player_ref",
                "slot_id",
                "original_idempotency_key",
                "value",
                "revision",
            }
        )
        if invalid then
            return invalid
        end
        invalid = PortContract.check_result_integer(
            value,
            "value",
            0,
            MAX_INTEGER,
            false
        )
        if invalid then
            return invalid
        end
        invalid = PortContract.check_result_integer(
            value,
            "revision",
            0,
            MAX_INTEGER,
            false
        )
        if invalid then
            return invalid
        end
    else
        invalid = PortContract.check_result_fields(
            value,
            {
                "status",
                "player_ref",
                "slot_id",
                "original_idempotency_key",
            }
        )
        if invalid then
            return invalid
        end
        invalid = PortContract.check_result_enum(
            value,
            "status",
            { "NOT_FOUND", "PENDING", "UNKNOWN" },
            false
        )
        if invalid then
            return invalid
        end
    end
    invalid = validate_result_player(value, request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "slot_id",
        1,
        MAX_SLOT_ID,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "slot_id",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(
        value,
        "original_idempotency_key",
        false
    )
    if invalid then
        return invalid
    end
    local original_key = RuntimeId.validate_component(
        value.original_idempotency_key,
        "original_idempotency_key"
    )
    if not original_key.ok then
        return PortContract.invalid_result(
            "original_idempotency_key",
            "STABLE_REQUEST_KEY_REQUIRED",
            { cause_code = original_key.error.code }
        )
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "original_idempotency_key",
        request
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

return PortContract.define({
    name = "SaveStore",
    contract_version = 1,
    operations = {
        {
            name = "load_slot",
            request_fields = { "player_ref", "slot_id" },
            validate_request = validate_player_and_slot,
            validate_success = validate_slot_read_success,
            error_codes = { "SAVE_NOT_FOUND" },
        },
        {
            name = "stage_slot",
            request_fields = {
                "player_ref",
                "slot_id",
                "expected_revision",
                "checkpoint_id",
                "payload_checksum",
                "dto",
            },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_stage_slot,
            validate_success = validate_stage_success,
            error_codes = { "SAVE_REVISION_CONFLICT" },
        },
        {
            name = "commit",
            request_fields = { "player_ref", "commit_entries" },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_commit,
            validate_success = validate_commit_success,
            error_codes = { "SAVE_REVISION_CONFLICT" },
        },
        {
            name = "upload",
            request_fields = { "player_ref" },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_upload,
            validate_success = validate_upload_success,
        },
        {
            name = "read_integer",
            request_fields = { "player_ref", "slot_id" },
            validate_request = validate_player_and_slot,
            validate_success = validate_integer_success,
            error_codes = { "SAVE_NOT_FOUND" },
        },
        {
            name = "compare_and_add_integer",
            request_fields = {
                "player_ref",
                "slot_id",
                "expected_value",
                "expected_revision",
                "delta",
            },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_compare_and_add,
            validate_success = validate_add_integer_success,
            error_codes = { "PLATFORM_INTEGER_CONFLICT" },
        },
        {
            name = "compare_and_set_integer",
            request_fields = {
                "player_ref",
                "slot_id",
                "expected_value",
                "expected_revision",
                "target_value",
            },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_compare_and_set,
            validate_success = validate_set_integer_success,
            error_codes = { "PLATFORM_INTEGER_CONFLICT" },
        },
        {
            name = "query_integer_request",
            request_fields = {
                "player_ref",
                "slot_id",
                "original_idempotency_key",
            },
            validate_request = validate_query_integer_request,
            validate_success = validate_query_integer_success,
        },
    },
})
