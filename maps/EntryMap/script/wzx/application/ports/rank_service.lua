local PortContract = require "wzx.application.ports.port_contract"
local RuntimeId = require "wzx.domain.common.runtime_id"

local MAX_INTEGER = PortContract.MAX_SAFE_INTEGER

local function validate_slot(request)
    return PortContract.check_integer(request, "slot_id", 101, 101, false)
end

local function validate_publish_score(request)
    local invalid = validate_slot(request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "encoded_value",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_slot_only(request)
    local invalid = validate_slot(request)
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_nearby(request)
    local invalid = validate_slot(request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "center_rank",
        1,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(request, "count", 1, 1000, false)
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_entry_identity(request)
    local invalid = PortContract.check_table(request, "entry", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request.entry,
        "rank",
        1,
        MAX_INTEGER,
        false
    )
    if invalid then
        invalid.error.details.parent_field = "entry"
        return invalid
    end
    invalid = PortContract.check_non_empty_string(
        request.entry,
        "entry_ref",
        false
    )
    if invalid then
        invalid.error.details.parent_field = "entry"
        return invalid
    end
    local entry_ref = RuntimeId.validate_stable_order_key(
        request.entry.entry_ref,
        "entry_ref"
    )
    if not entry_ref.ok then
        return PortContract.invalid_request(
            "entry",
            "STABLE_ENTRY_REFERENCE_REQUIRED",
            { cause_code = entry_ref.error.code }
        )
    end
    invalid = PortContract.check_integer(
        request.entry,
        "encoded_value",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        invalid.error.details.parent_field = "entry"
        return invalid
    end
    local entry_field
    for entry_field in pairs(request.entry) do
        if entry_field ~= "rank"
            and entry_field ~= "encoded_value"
            and entry_field ~= "entry_ref"
            and entry_field ~= "display_name"
            and entry_field ~= "aid"
        then
            return PortContract.invalid_request(
                "entry",
                "RANK_ENTRY_UNKNOWN_FIELD",
                { field = tostring(entry_field) }
            )
        end
    end
    invalid = PortContract.check_non_empty_string(
        request.entry,
        "display_name",
        true
    )
    if invalid then
        invalid.error.details.parent_field = "entry"
        return invalid
    end
    invalid = PortContract.check_non_empty_string(request.entry, "aid", true)
    if invalid then
        invalid.error.details.parent_field = "entry"
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_rank_entry(entry, index, require_entry_ref)
    local required_fields = { "rank", "encoded_value" }
    if require_entry_ref then
        required_fields[#required_fields + 1] = "entry_ref"
    end
    local invalid = PortContract.check_result_fields(
        entry,
        required_fields,
        { "display_name", "aid" }
    )
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "entries"
        return invalid
    end
    if require_entry_ref then
        invalid = PortContract.check_result_string(
            entry,
            "entry_ref",
            false
        )
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "entries"
            return invalid
        end
        local entry_ref = RuntimeId.validate_stable_order_key(
            entry.entry_ref,
            "entry_ref"
        )
        if not entry_ref.ok then
            return PortContract.invalid_result(
                "entries",
                "STABLE_ENTRY_REFERENCE_REQUIRED",
                { entry_index = index, cause_code = entry_ref.error.code }
            )
        end
    end
    invalid = PortContract.check_result_integer(
        entry,
        "rank",
        1,
        MAX_INTEGER,
        false
    )
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "entries"
        return invalid
    end
    invalid = PortContract.check_result_integer(
        entry,
        "encoded_value",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "entries"
        return invalid
    end
    invalid = PortContract.check_result_string(entry, "display_name", true)
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "entries"
        return invalid
    end
    invalid = PortContract.check_result_string(entry, "aid", true)
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "entries"
        return invalid
    end
    return nil
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

local function validate_publish_success(value, request)
    local invalid = PortContract.check_result_fields(
        value,
        { "status", "slot_id", "encoded_value", "request_key" },
        { "rank" }
    )
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
        101,
        101,
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
    invalid = PortContract.check_result_enum(
        value,
        "status",
        { "CONFIRMED" },
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "encoded_value",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "encoded_value",
        0,
        MAX_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "rank",
        1,
        MAX_INTEGER,
        true
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_self_rank_success(value, request)
    local invalid

    if type(value) ~= "table" then
        return PortContract.invalid_result("value", "TABLE_REQUIRED")
    end
    if value.status == "UNRANKED" then
        invalid = PortContract.check_result_fields(
            value,
            { "status", "slot_id" }
        )
        if invalid then
            return invalid
        end
    else
        invalid = PortContract.check_result_fields(
            value,
            { "status", "slot_id", "rank", "encoded_value" }
        )
        if invalid then
            return invalid
        end
        invalid = PortContract.check_result_enum(
            value,
            "status",
            { "RANKED" },
            false
        )
        if invalid then
            return invalid
        end
        invalid = validate_rank_entry({
            rank = value.rank,
            encoded_value = value.encoded_value,
        }, 1)
        if invalid then
            return invalid
        end
    end
    invalid = PortContract.check_result_integer(
        value,
        "slot_id",
        101,
        101,
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
    return PortContract.ok(true)
end

local function validate_nearby_success(value, request)
    local invalid = PortContract.check_result_fields(
        value,
        { "status", "slot_id", "entries" }
    )
    local index
    local entry
    local previous_rank = 0
    local seen_entry_refs = {}

    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "slot_id",
        101,
        101,
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
    invalid = PortContract.check_result_enum(
        value,
        "status",
        { "AVAILABLE" },
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_list(value, "entries", true, false)
    if invalid then
        return invalid
    end
    if #value.entries > 1000 then
        return PortContract.invalid_result("entries", "LIST_TOO_LONG", {
            maximum = 1000,
            actual = #value.entries,
        })
    end
    if request ~= nil
        and type(request.count) == "number"
        and #value.entries > request.count
    then
        return PortContract.invalid_result(
            "entries",
            "REQUESTED_COUNT_EXCEEDED",
            { requested = request.count, actual = #value.entries }
        )
    end
    for index = 1, #value.entries do
        entry = value.entries[index]
        invalid = validate_rank_entry(entry, index, true)
        if invalid then
            return invalid
        end
        if seen_entry_refs[entry.entry_ref] then
            return PortContract.invalid_result(
                "entries",
                "DUPLICATE_ENTRY_REFERENCE",
                { entry_index = index, entry_ref = entry.entry_ref }
            )
        end
        if entry.rank <= previous_rank then
            return PortContract.invalid_result(
                "entries",
                "RANKS_MUST_BE_STRICTLY_ASCENDING",
                { entry_index = index, rank = entry.rank }
            )
        end
        seen_entry_refs[entry.entry_ref] = true
        previous_rank = entry.rank
    end
    return PortContract.ok(true)
end

local function validate_identity_success(value, request)
    local invalid
    local request_aid = type(request) == "table"
        and type(request.entry) == "table"
        and request.entry.aid
        or nil

    if type(value) ~= "table" then
        return PortContract.invalid_result("value", "TABLE_REQUIRED")
    end
    if value.status == "UNAVAILABLE" then
        invalid = PortContract.check_result_fields(
            value,
            { "status", "entry_ref", "rank", "encoded_value" },
            { "aid" }
        )
        if invalid then
            return invalid
        end
        if request_aid == nil and value.aid ~= nil then
            return PortContract.invalid_result(
                "aid",
                "UNREQUESTED_IDENTITY_FORBIDDEN"
            )
        end
    else
        invalid = PortContract.check_result_fields(
            value,
            { "status", "entry_ref", "rank", "encoded_value", "aid" }
        )
        if invalid then
            return invalid
        end
        invalid = PortContract.check_result_enum(
            value,
            "status",
            { "AVAILABLE" },
            false
        )
        if invalid then
            return invalid
        end
        invalid = PortContract.check_result_string(value, "aid", false)
        if invalid then
            return invalid
        end
    end
    invalid = validate_rank_entry({
        entry_ref = value.entry_ref,
        rank = value.rank,
        encoded_value = value.encoded_value,
        aid = value.aid,
    }, 1, true)
    if invalid then
        return invalid
    end
    if request_aid ~= nil then
        invalid = PortContract.check_result_string(value, "aid", false)
        if invalid then
            return invalid
        end
        if value.aid ~= request_aid then
            return PortContract.invalid_result(
                "aid",
                "REQUEST_ECHO_MISMATCH",
                { expected = request_aid, actual = value.aid }
            )
        end
    end
    if request ~= nil then
        if type(request.entry) ~= "table"
            or value.entry_ref ~= request.entry.entry_ref
            or value.rank ~= request.entry.rank
            or value.encoded_value ~= request.entry.encoded_value
        then
            return PortContract.invalid_result(
                "rank",
                "RANK_ENTRY_ECHO_MISMATCH",
                {
                    expected_rank = type(request.entry) == "table"
                        and request.entry.rank or nil,
                    actual_rank = value.rank,
                    expected_entry_ref = type(request.entry) == "table"
                        and request.entry.entry_ref or nil,
                    actual_entry_ref = value.entry_ref,
                    expected_encoded_value = type(request.entry) == "table"
                        and request.entry.encoded_value or nil,
                    actual_encoded_value = value.encoded_value,
                }
            )
        end
    end
    return PortContract.ok(true)
end

return PortContract.define({
    name = "RankService",
    contract_version = 1,
    operations = {
        {
            name = "publish_score",
            request_fields = { "slot_id", "encoded_value" },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_publish_score,
            validate_success = validate_publish_success,
        },
        {
            name = "get_self_rank",
            request_fields = { "slot_id" },
            validate_request = validate_slot_only,
            validate_success = validate_self_rank_success,
        },
        {
            name = "get_nearby_entries",
            request_fields = { "slot_id", "center_rank", "count" },
            validate_request = validate_nearby,
            validate_success = validate_nearby_success,
        },
        {
            name = "get_entry_identity",
            request_fields = { "entry" },
            validate_request = validate_entry_identity,
            validate_success = validate_identity_success,
        },
    },
})
