local RequestContext = require "wzx.application.ports.request_context"
local Ordered = require "wzx.domain.common.ordered"
local TableShape = require "wzx.domain.common.table_shape"

local PortContract = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_dense_array = Ordered.is_dense_array
local request_context_is_finite_number = RequestContext.is_finite_number
local request_context_is_integer = RequestContext.is_integer
local request_context_validate = RequestContext.validate
local validate_serializable = TableShape.validate_serializable
local math_floor = math.floor
local raw_next = next
local string_match = string.match
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_RESULT_DEPTH = 8
local MAX_STRING_BYTES = 1024
local MAX_PAYLOAD_DEPTH = 8
local MAX_PAYLOAD_NODES = 4096
local MAX_TOTAL_STRING_BYTES = 262144
local MAX_KEY_BYTES = 256
local MAX_VALUE_STRING_BYTES = 65536
local RESULT_PHASE_ADMISSION = "ADMISSION"
local RESULT_PHASE_COMPLETION = "COMPLETION"
local SPEC_STATES = setmetatable({}, { __mode = "k" })
local COMMON_ERROR_CODES = {
    FAKE_FINGERPRINT_FAILED = true,
    FAKE_RESULT_SNAPSHOT_FAILED = true,
    FAKE_SCRIPT_EXHAUSTED = true,
    FAKE_SCRIPT_HANDLER_FAILED = true,
    FAKE_SCRIPT_INVALID = true,
    FAKE_SNAPSHOT_INVALID = true,
    IDEMPOTENCY_KEY_REUSED = true,
    PLATFORM_INVALID_ARGUMENT = true,
    PLATFORM_PERMISSION_DENIED = true,
    PLATFORM_QUOTA_EXCEEDED = true,
    PLATFORM_RATE_LIMITED = true,
    PLATFORM_RESULT_UNKNOWN = true,
    PLATFORM_UNAVAILABLE = true,
    PORT_ADAPTER_CALLBACK_INLINE = true,
    PORT_ADAPTER_FAILED = true,
    PORT_ADAPTER_RETURN_INVALID = true,
    PORT_CONTRACT_INVALID = true,
    PORT_IDEMPOTENCY_REQUIRED = true,
    PORT_OPERATION_UNKNOWN = true,
    PORT_REQUEST_CONTEXT_INVALID = true,
    PORT_REQUEST_INVALID = true,
    PORT_RESULT_INVALID = true,
}

local function copy_details(details)
    local copied = {}
    local key
    local value

    if type(details) == "table" then
        for key, value in raw_next, details do
            copied[key] = value
        end
    end

    return copied
end

local function payload_failure(code, path, reason, details)
    local error_details = copy_details(details)
    error_details.path = path
    error_details.reason = reason
    return {
        ok = false,
        error = {
            code = code,
            message_key = "error." .. string.lower(code),
            retryable = false,
            details = error_details,
        },
    }
end

local function is_finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function is_safe_positive_integer(value)
    return is_finite_number(value)
        and value == math_floor(value)
        and value >= 1
        and value <= MAX_SAFE_INTEGER
end

local function touch_node(state, path)
    state.nodes = state.nodes + 1
    if state.nodes > MAX_PAYLOAD_NODES then
        return payload_failure(
            "PAYLOAD_BUDGET_EXCEEDED",
            path,
            "MAXIMUM_NODE_COUNT_EXCEEDED",
            {
                maximum_nodes = MAX_PAYLOAD_NODES,
                actual_nodes = state.nodes,
            }
        )
    end
    return nil
end

local function touch_string(state, value, path, is_key)
    local length = #value
    local maximum = is_key and MAX_KEY_BYTES or MAX_VALUE_STRING_BYTES
    local reason = is_key
        and "MAXIMUM_KEY_BYTES_EXCEEDED"
        or "MAXIMUM_VALUE_STRING_BYTES_EXCEEDED"

    if length > maximum then
        return payload_failure("PAYLOAD_BUDGET_EXCEEDED", path, reason, {
            maximum_bytes = maximum,
            actual_bytes = length,
        })
    end
    state.total_string_bytes = state.total_string_bytes + length
    if state.total_string_bytes > MAX_TOTAL_STRING_BYTES then
        return payload_failure(
            "PAYLOAD_BUDGET_EXCEEDED",
            path,
            "MAXIMUM_TOTAL_STRING_BYTES_EXCEEDED",
            {
                maximum_bytes = MAX_TOTAL_STRING_BYTES,
                actual_bytes = state.total_string_bytes,
            }
        )
    end
    return nil
end

local function classify_payload_table(value, path, state)
    local key
    local key_type
    local budget_error
    local numeric_count = 0
    local maximum_index = 0
    local has_numeric_key = false
    local has_string_key = false

    for key in raw_next, value do
        budget_error = touch_node(state, path .. ".<key>")
        if budget_error then
            return nil, budget_error
        end
        key_type = type(key)
        if key_type == "string" then
            if key == "" then
                return nil, payload_failure(
                    "PAYLOAD_SNAPSHOT_INVALID",
                    path,
                    "NON_EMPTY_STRING_MAP_KEY_REQUIRED"
                )
            end
            budget_error = touch_string(
                state,
                key,
                path .. ".<key>",
                true
            )
            if budget_error then
                return nil, budget_error
            end
            has_string_key = true
        elseif key_type == "number" and is_safe_positive_integer(key) then
            has_numeric_key = true
            numeric_count = numeric_count + 1
            if key > maximum_index then
                maximum_index = key
            end
        else
            return nil, payload_failure(
                "PAYLOAD_SNAPSHOT_INVALID",
                path,
                "STRING_MAP_OR_ARRAY_KEY_REQUIRED",
                { actual_key_type = key_type }
            )
        end
        if has_numeric_key and has_string_key then
            return nil, payload_failure(
                "PAYLOAD_SNAPSHOT_INVALID",
                path,
                "MIXED_TABLE_KEYS_FORBIDDEN"
            )
        end
    end
    if has_numeric_key then
        if numeric_count ~= maximum_index then
            return nil, payload_failure(
                "PAYLOAD_SNAPSHOT_INVALID",
                path,
                "DENSE_ARRAY_REQUIRED",
                { count = numeric_count, maximum_index = maximum_index }
            )
        end
        return "ARRAY", maximum_index
    end
    return "MAP", 0
end

local function sorted_payload_keys(value)
    local keys = {}
    local key
    for key in raw_next, value do
        keys[#keys + 1] = key
    end
    table.sort(keys, bytewise_string_less)
    return keys
end

local function copy_payload_value(value, path, table_depth, state, active, copies)
    local node_error = touch_node(state, path)
    local value_type = type(value)
    local string_error
    local kind
    local length
    local kind_error
    local target
    local index
    local keys
    local key
    local child_copy
    local child_error

    if node_error then
        return nil, node_error
    end
    if value_type == "string" then
        string_error = touch_string(state, value, path, false)
        if string_error then
            return nil, string_error
        end
        return value, nil
    end
    if value_type == "boolean" then
        return value, nil
    end
    if value_type == "number" then
        if not is_finite_number(value) then
            return nil, payload_failure(
                "PAYLOAD_SNAPSHOT_INVALID",
                path,
                "FINITE_NUMBER_REQUIRED"
            )
        end
        return value, nil
    end
    if value_type ~= "table" then
        return nil, payload_failure(
            "PAYLOAD_SNAPSHOT_INVALID",
            path,
            "SERIALIZABLE_VALUE_REQUIRED",
            { actual_type = value_type }
        )
    end
    if table_depth > MAX_PAYLOAD_DEPTH then
        return nil, payload_failure(
            "PAYLOAD_BUDGET_EXCEEDED",
            path,
            "MAXIMUM_TABLE_DEPTH_EXCEEDED",
            { maximum_table_depth = MAX_PAYLOAD_DEPTH }
        )
    end
    if active[value] then
        return nil, payload_failure(
            "PAYLOAD_SNAPSHOT_INVALID",
            path,
            "TABLE_CYCLE_DETECTED"
        )
    end
    if copies[value] ~= nil then
        return nil, payload_failure(
            "PAYLOAD_SNAPSHOT_INVALID",
            path,
            "SHARED_TABLE_REFERENCE_FORBIDDEN"
        )
    end

    kind, length = classify_payload_table(value, path, state)
    if kind == nil then
        kind_error = length
        return nil, kind_error
    end
    target = {}
    copies[value] = target
    active[value] = true
    if kind == "ARRAY" then
        for index = 1, length do
            child_copy, child_error = copy_payload_value(
                rawget(value, index),
                path .. "[" .. tostring(index) .. "]",
                table_depth + 1,
                state,
                active,
                copies
            )
            if child_error then
                active[value] = nil
                copies[value] = nil
                return nil, child_error
            end
            target[index] = child_copy
        end
    else
        keys = sorted_payload_keys(value)
        for index = 1, #keys do
            key = keys[index]
            child_copy, child_error = copy_payload_value(
                rawget(value, key),
                path .. "." .. key,
                table_depth + 1,
                state,
                active,
                copies
            )
            if child_error then
                active[value] = nil
                copies[value] = nil
                return nil, child_error
            end
            target[key] = child_copy
        end
    end
    active[value] = nil
    return target, nil
end

local function snapshot_payload(value, root_path)
    local state = {
        nodes = 0,
        total_string_bytes = 0,
    }
    local copied
    local found

    copied, found = copy_payload_value(
        value,
        root_path or "$",
        1,
        state,
        {},
        {}
    )
    if found then
        return found
    end
    return {
        ok = true,
        value = copied,
        stats = state,
    }
end

function PortContract.ok(value)
    return {
        ok = true,
        value = value,
    }
end

function PortContract.error(code, details, retryable)
    return {
        ok = false,
        error = {
            code = code,
            message_key = "error." .. string.lower(code),
            retryable = retryable == true,
            details = details,
        },
    }
end

function PortContract.is_result(value)
    local ok_value
    local error_value
    if type(value) ~= "table"
        or getmetatable(value) ~= nil
        or type(rawget(value, "ok")) ~= "boolean"
    then
        return false
    end

    ok_value = rawget(value, "ok")
    error_value = rawget(value, "error")
    if ok_value then
        return error_value == nil
    end

    return type(error_value) == "table"
        and getmetatable(error_value) == nil
        and type(rawget(error_value, "code")) == "string"
        and rawget(error_value, "code") ~= ""
        and type(rawget(error_value, "message_key")) == "string"
        and rawget(error_value, "message_key") ~= ""
        and type(rawget(error_value, "retryable")) == "boolean"
end

function PortContract.invalid_request(field_name, reason, details)
    local error_details = copy_details(details)
    error_details.field = field_name
    error_details.reason = reason

    return PortContract.error("PORT_REQUEST_INVALID", error_details, false)
end

function PortContract.invalid_result(field_name, reason, details)
    local error_details = copy_details(details)
    if field_name ~= nil then
        error_details.field = field_name
    end
    error_details.reason = reason

    return PortContract.error("PORT_RESULT_INVALID", error_details, false)
end

local function build_field_set(fields)
    local allowed = {}
    local index
    local field_name

    if fields == nil then
        return allowed
    end
    for index = 1, #fields do
        field_name = fields[index]
        allowed[field_name] = true
    end
    return allowed
end

function PortContract.check_result_fields(value, required_fields, optional_fields)
    local allowed = build_field_set(required_fields)
    local optional = build_field_set(optional_fields)
    local field_name
    local index

    if type(value) ~= "table" then
        return PortContract.invalid_result("value", "TABLE_REQUIRED")
    end
    for field_name in raw_next, optional do
        allowed[field_name] = true
    end
    for field_name in raw_next, value do
        if type(field_name) ~= "string" or not allowed[field_name] then
            return PortContract.invalid_result(
                tostring(field_name),
                "UNKNOWN_FIELD"
            )
        end
    end
    required_fields = required_fields or {}
    for index = 1, #required_fields do
        field_name = required_fields[index]
        if value[field_name] == nil then
            return PortContract.invalid_result(field_name, "FIELD_REQUIRED")
        end
    end
    return nil
end

function PortContract.check_result_string(container, field_name, optional)
    local value = container[field_name]
    if value == nil and optional then
        return nil
    end
    if type(value) ~= "string" or value == "" then
        return PortContract.invalid_result(
            field_name,
            "NON_EMPTY_STRING_REQUIRED"
        )
    end
    if #value > MAX_STRING_BYTES then
        return PortContract.invalid_result(field_name, "STRING_TOO_LONG", {
            maximum_bytes = MAX_STRING_BYTES,
            actual_bytes = #value,
        })
    end
    return nil
end

function PortContract.check_result_integer(
    container,
    field_name,
    minimum,
    maximum,
    optional
)
    local value = container[field_name]
    if value == nil and optional then
        return nil
    end
    if not request_context_is_integer(value)
        or value < -MAX_SAFE_INTEGER
        or value > MAX_SAFE_INTEGER
    then
        return PortContract.invalid_result(field_name, "SAFE_INTEGER_REQUIRED")
    end
    if minimum ~= nil and value < minimum then
        return PortContract.invalid_result(field_name, "INTEGER_BELOW_MINIMUM", {
            minimum = minimum,
            actual = value,
        })
    end
    if maximum ~= nil and value > maximum then
        return PortContract.invalid_result(field_name, "INTEGER_ABOVE_MAXIMUM", {
            maximum = maximum,
            actual = value,
        })
    end
    return nil
end

function PortContract.check_result_boolean(container, field_name, optional)
    local value = container[field_name]
    if value == nil and optional then
        return nil
    end
    if type(value) ~= "boolean" then
        return PortContract.invalid_result(field_name, "BOOLEAN_REQUIRED")
    end
    return nil
end

function PortContract.check_result_request_echo(
    container,
    result_field,
    request,
    request_field
)
    local expected
    if request == nil then
        return nil
    end
    if type(request) ~= "table" then
        return PortContract.invalid_result(
            result_field,
            "REQUEST_BINDING_TABLE_REQUIRED"
        )
    end
    request_field = request_field or result_field
    expected = request[request_field]
    if expected == nil then
        return PortContract.invalid_result(
            result_field,
            "REQUEST_BINDING_FIELD_REQUIRED",
            { request_field = request_field }
        )
    end
    if container[result_field] ~= expected then
        return PortContract.invalid_result(
            result_field,
            "REQUEST_ECHO_MISMATCH",
            {
                request_field = request_field,
                expected = expected,
                actual = container[result_field],
            }
        )
    end
    return nil
end

function PortContract.check_result_enum(
    container,
    field_name,
    allowed_values,
    optional
)
    local value = container[field_name]
    local index
    if value == nil and optional then
        return nil
    end
    for index = 1, #allowed_values do
        if value == allowed_values[index] then
            return nil
        end
    end
    return PortContract.invalid_result(field_name, "ENUM_VALUE_INVALID", {
        actual = value,
    })
end

function PortContract.check_result_table(container, field_name, optional)
    local value = container[field_name]
    local serializable
    if value == nil and optional then
        return nil
    end
    if type(value) ~= "table" then
        return PortContract.invalid_result(field_name, "TABLE_REQUIRED")
    end
    serializable = validate_serializable(
        value,
        MAX_RESULT_DEPTH,
        "$.value." .. field_name
    )
    if not serializable.ok then
        return PortContract.invalid_result(
            field_name,
            "SERIALIZABLE_TABLE_REQUIRED",
            { cause = serializable.error }
        )
    end
    return nil
end

function PortContract.check_result_list(
    container,
    field_name,
    allow_empty,
    optional
)
    local value = container[field_name]
    local length
    if value == nil and optional then
        return nil
    end
    if type(value) ~= "table" then
        return PortContract.invalid_result(field_name, "LIST_REQUIRED")
    end
    if not is_dense_array(value) then
        return PortContract.invalid_result(field_name, "DENSE_LIST_REQUIRED")
    end
    length = #value
    if not allow_empty and length == 0 then
        return PortContract.invalid_result(
            field_name,
            "NON_EMPTY_LIST_REQUIRED"
        )
    end
    return nil
end

function PortContract.check_non_empty_string(container, field_name, optional)
    local value = container[field_name]

    if value == nil and optional then
        return nil
    end

    if type(value) ~= "string" or value == "" then
        return PortContract.invalid_request(
            field_name,
            "NON_EMPTY_STRING_REQUIRED"
        )
    end
    if #value > MAX_STRING_BYTES then
        return PortContract.invalid_request(field_name, "STRING_TOO_LONG", {
            maximum_bytes = MAX_STRING_BYTES,
            actual_bytes = #value,
        })
    end

    return nil
end

function PortContract.check_integer(container, field_name, minimum, maximum, optional)
    local value = container[field_name]

    if value == nil and optional then
        return nil
    end

    if not request_context_is_integer(value) then
        return PortContract.invalid_request(field_name, "INTEGER_REQUIRED")
    end

    if minimum ~= nil and value < minimum then
        return PortContract.invalid_request(field_name, "INTEGER_BELOW_MINIMUM", {
            minimum = minimum,
            actual = value,
        })
    end

    if maximum ~= nil and value > maximum then
        return PortContract.invalid_request(field_name, "INTEGER_ABOVE_MAXIMUM", {
            maximum = maximum,
            actual = value,
        })
    end

    return nil
end

function PortContract.check_number(container, field_name, minimum, maximum, optional)
    local value = container[field_name]

    if value == nil and optional then
        return nil
    end

    if not request_context_is_finite_number(value) then
        return PortContract.invalid_request(field_name, "FINITE_NUMBER_REQUIRED")
    end

    if minimum ~= nil and value < minimum then
        return PortContract.invalid_request(field_name, "NUMBER_BELOW_MINIMUM", {
            minimum = minimum,
            actual = value,
        })
    end

    if maximum ~= nil and value > maximum then
        return PortContract.invalid_request(field_name, "NUMBER_ABOVE_MAXIMUM", {
            maximum = maximum,
            actual = value,
        })
    end

    return nil
end

function PortContract.check_table(container, field_name, optional)
    local value = container[field_name]

    if value == nil and optional then
        return nil
    end

    if type(value) ~= "table" then
        return PortContract.invalid_request(field_name, "TABLE_REQUIRED")
    end

    local serializable = validate_serializable(
        value,
        8,
        "$." .. field_name
    )
    if not serializable.ok then
        return PortContract.invalid_request(field_name, "SERIALIZABLE_TABLE_REQUIRED", {
            cause = serializable.error,
        })
    end

    return nil
end

function PortContract.check_list(container, field_name, allow_empty, optional)
    local value = container[field_name]
    local length

    if value == nil and optional then
        return nil
    end

    if type(value) ~= "table" then
        return PortContract.invalid_request(field_name, "LIST_REQUIRED")
    end

    if not is_dense_array(value) then
        return PortContract.invalid_request(field_name, "DENSE_LIST_REQUIRED")
    end
    length = #value

    if not allow_empty and length == 0 then
        return PortContract.invalid_request(field_name, "NON_EMPTY_LIST_REQUIRED")
    end

    return nil
end

function PortContract.check_boolean(container, field_name, optional)
    local value = container[field_name]

    if value == nil and optional then
        return nil
    end

    if type(value) ~= "boolean" then
        return PortContract.invalid_request(field_name, "BOOLEAN_REQUIRED")
    end

    return nil
end

function PortContract.check_enum(container, field_name, allowed_values, optional)
    local value = container[field_name]
    local index

    if value == nil and optional then
        return nil
    end

    for index = 1, #allowed_values do
        if value == allowed_values[index] then
            return nil
        end
    end

    return PortContract.invalid_request(field_name, "ENUM_VALUE_INVALID", {
        actual = value,
    })
end

local function find_operation(spec, operation_name)
    local state = type(spec) == "table" and SPEC_STATES[spec] or nil
    if state == nil then
        return nil
    end
    return state.operation_by_name[operation_name]
end

local function spec_name(spec)
    local state = type(spec) == "table" and SPEC_STATES[spec] or nil
    return state and state.name or nil
end

local function validate_request_snapshot(spec, operation_name, request)
    local operation = find_operation(spec, operation_name)
    local context_result
    local request_result
    local validator_ok

    if not operation then
        return PortContract.error("PORT_OPERATION_UNKNOWN", {
            port = spec_name(spec),
            operation = operation_name,
        }, false)
    end

    if type(request) ~= "table" then
        return PortContract.invalid_request("request", "TABLE_REQUIRED")
    end

    local field
    for field in raw_next, request do
        if type(field) ~= "string" or not operation.allowed_request_fields[field] then
            return PortContract.invalid_request(tostring(field), "UNKNOWN_FIELD")
        end
    end

    context_result = request_context_validate(request.context, {
        require_idempotency = operation.requires_idempotency == true,
    })
    if not context_result.ok then
        return context_result
    end

    if operation.validate_request then
        validator_ok, request_result = pcall(operation.validate_request, request)
        if not validator_ok then
            return PortContract.error("PORT_CONTRACT_INVALID", {
                port = spec_name(spec),
                operation = operation_name,
                reason = "VALIDATOR_RAISED",
                message = tostring(request_result),
            }, false)
        end
        if not PortContract.is_result(request_result) then
            return PortContract.error("PORT_CONTRACT_INVALID", {
                port = spec_name(spec),
                operation = operation_name,
                reason = "VALIDATOR_MUST_RETURN_RESULT",
            }, false)
        end
        if not request_result.ok then
            return request_result
        end
    end

    return PortContract.ok({
        request = request,
        context = context_result.value,
        operation = {
            name = operation.name,
            mutating = operation.mutating,
            requires_idempotency = operation.requires_idempotency,
        },
    })
end

function PortContract.sanitize_request(spec, operation_name, request)
    local snapshot = snapshot_payload(request, "$.request")
    local checked
    local details

    if not snapshot.ok then
        details = copy_details(snapshot.error.details)
        details.cause_code = snapshot.error.code
        return PortContract.invalid_request(
            "request",
            snapshot.error.code,
            details
        )
    end
    checked = validate_request_snapshot(spec, operation_name, snapshot.value)
    if not checked.ok then
        return checked
    end
    return PortContract.ok(snapshot.value)
end

function PortContract.validate_request(spec, operation_name, request)
    local sanitized = PortContract.sanitize_request(spec, operation_name, request)
    if not sanitized.ok then
        return sanitized
    end
    return validate_request_snapshot(spec, operation_name, sanitized.value)
end

local function invalid_result_with_context(spec, operation, invalid)
    local details = {}
    local key
    local value

    if type(invalid) == "table"
        and type(invalid.error) == "table"
        and type(invalid.error.details) == "table"
    then
        for key, value in raw_next, invalid.error.details do
            details[key] = value
        end
    end
    details.port = spec_name(spec)
    details.operation = operation.name
    return PortContract.error("PORT_RESULT_INVALID", details, false)
end

local function validate_error_result(operation, result)
    local error_value = result.error
    local key
    local allowed

    for key in raw_next, result do
        if key ~= "ok" and key ~= "error" then
            return PortContract.invalid_result(
                tostring(key),
                "RESULT_ENVELOPE_UNKNOWN_FIELD"
            )
        end
    end
    if type(error_value) ~= "table" then
        return PortContract.invalid_result("error", "ERROR_TABLE_REQUIRED")
    end
    for key in raw_next, error_value do
        if key ~= "code"
            and key ~= "message_key"
            and key ~= "retryable"
            and key ~= "details"
        then
            return PortContract.invalid_result(
                "error." .. tostring(key),
                "ERROR_UNKNOWN_FIELD"
            )
        end
    end
    if type(error_value.code) ~= "string"
        or #error_value.code < 1
        or #error_value.code > 64
        or not string_match(error_value.code, "^[A-Z][A-Z0-9_]*$")
    then
        return PortContract.invalid_result(
            "error.code",
            "STABLE_ERROR_CODE_REQUIRED"
        )
    end
    allowed = COMMON_ERROR_CODES[error_value.code]
        or operation.allowed_error_codes[error_value.code]
    if not allowed then
        return PortContract.invalid_result("error.code", "ERROR_CODE_NOT_ALLOWED", {
            actual = error_value.code,
        })
    end
    if type(error_value.message_key) ~= "string"
        or #error_value.message_key < 7
        or #error_value.message_key > MAX_STRING_BYTES
        or not string_match(error_value.message_key, "^error%.[a-z0-9_.]+$")
    then
        return PortContract.invalid_result(
            "error.message_key",
            "STABLE_MESSAGE_KEY_REQUIRED"
        )
    end
    if error_value.message_key ~= "error." .. string.lower(error_value.code) then
        return PortContract.invalid_result(
            "error.message_key",
            "MESSAGE_KEY_CODE_MISMATCH"
        )
    end
    if type(error_value.retryable) ~= "boolean" then
        return PortContract.invalid_result(
            "error.retryable",
            "BOOLEAN_REQUIRED"
        )
    end
    if error_value.code == "PLATFORM_RESULT_UNKNOWN"
        and error_value.retryable
    then
        return PortContract.invalid_result(
            "error.retryable",
            "UNKNOWN_RESULT_MUST_NOT_BE_BLINDLY_RETRYABLE"
        )
    end
    if operation.mutating
        and (error_value.code == "PLATFORM_UNAVAILABLE"
            or error_value.code == "PLATFORM_RATE_LIMITED")
        and error_value.retryable
    then
        return PortContract.invalid_result(
            "error.retryable",
            "MUTATION_ERROR_MUST_REQUIRE_QUERY_OR_RECONCILE"
        )
    end
    if error_value.details ~= nil and type(error_value.details) ~= "table" then
        return PortContract.invalid_result(
            "error.details",
            "TABLE_REQUIRED"
        )
    end
    return nil
end

local function validate_result_snapshot(
    spec,
    operation_name,
    result,
    request,
    phase
)
    local operation = find_operation(spec, operation_name)
    local serializable
    local invalid
    local validator_ok
    local success_validation
    local key

    if not operation then
        return false, PortContract.error("PORT_OPERATION_UNKNOWN", {
            port = spec_name(spec),
            operation = operation_name,
        }, false)
    end
    if type(result) ~= "table" or type(result.ok) ~= "boolean" then
        return false, invalid_result_with_context(
            spec,
            operation,
            PortContract.invalid_result(nil, "RESULT_ENVELOPE_INVALID")
        )
    end
    serializable = validate_serializable(
        result,
        MAX_RESULT_DEPTH,
        "$.result"
    )
    if not serializable.ok then
        return false, invalid_result_with_context(
            spec,
            operation,
            PortContract.invalid_result(nil, "RESULT_NOT_SERIALIZABLE", {
                cause = serializable.error,
            })
        )
    end

    if not result.ok then
        invalid = validate_error_result(operation, result)
        if invalid then
            return false, invalid_result_with_context(spec, operation, invalid)
        end
        if operation.validate_error ~= nil then
            validator_ok, success_validation = pcall(
                operation.validate_error,
                result.error,
                request,
                phase
            )
            if not validator_ok then
                return false, invalid_result_with_context(
                    spec,
                    operation,
                    PortContract.invalid_result(nil, "ERROR_VALIDATOR_RAISED")
                )
            end
            if not PortContract.is_result(success_validation) then
                return false, invalid_result_with_context(
                    spec,
                    operation,
                    PortContract.invalid_result(
                        nil,
                        "ERROR_VALIDATOR_MUST_RETURN_RESULT"
                    )
                )
            end
            if not success_validation.ok then
                return false, invalid_result_with_context(
                    spec,
                    operation,
                    success_validation
                )
            end
        end
        return true, result
    end

    for key in raw_next, result do
        if key ~= "ok" and key ~= "value" then
            return false, invalid_result_with_context(
                spec,
                operation,
                PortContract.invalid_result(
                    tostring(key),
                    "RESULT_ENVELOPE_UNKNOWN_FIELD"
                )
            )
        end
    end
    if result.value == nil then
        return false, invalid_result_with_context(
            spec,
            operation,
            PortContract.invalid_result("value", "SUCCESS_VALUE_REQUIRED")
        )
    end

    validator_ok, success_validation = pcall(
        operation.validate_success,
        result.value,
        request
    )
    if not validator_ok then
        return false, invalid_result_with_context(
            spec,
            operation,
            PortContract.invalid_result(nil, "SUCCESS_VALIDATOR_RAISED")
        )
    end
    if not PortContract.is_result(success_validation) then
        return false, invalid_result_with_context(
            spec,
            operation,
            PortContract.invalid_result(
                nil,
                "SUCCESS_VALIDATOR_MUST_RETURN_RESULT"
            )
        )
    end
    if not success_validation.ok then
        return false, invalid_result_with_context(
            spec,
            operation,
            success_validation
        )
    end
    return true, result
end

function PortContract.sanitize_completion_result(
    spec,
    operation_name,
    result,
    request,
    phase
)
    local operation = find_operation(spec, operation_name)
    local snapshot
    local request_binding = nil
    local sanitized_request
    local valid
    local normalized
    local details

    phase = phase or RESULT_PHASE_COMPLETION
    if phase ~= RESULT_PHASE_ADMISSION and phase ~= RESULT_PHASE_COMPLETION then
        return PortContract.error("PORT_CONTRACT_INVALID", {
            port = spec_name(spec),
            operation = operation_name,
            reason = "RESULT_PHASE_INVALID",
        }, false)
    end
    if not operation then
        return PortContract.error("PORT_OPERATION_UNKNOWN", {
            port = spec_name(spec),
            operation = operation_name,
        }, false)
    end
    if request ~= nil then
        sanitized_request = PortContract.sanitize_request(
            spec,
            operation_name,
            request
        )
        if not sanitized_request.ok then
            return sanitized_request
        end
        request_binding = sanitized_request.value
    end
    snapshot = snapshot_payload(result, "$.result")
    if not snapshot.ok then
        details = copy_details(snapshot.error.details)
        details.cause_code = snapshot.error.code
        return invalid_result_with_context(
            spec,
            operation,
            PortContract.invalid_result(
                nil,
                snapshot.error.code,
                details
            )
        )
    end
    valid, normalized = validate_result_snapshot(
        spec,
        operation_name,
        snapshot.value,
        request_binding,
        phase
    )
    if not valid then
        return normalized
    end
    return PortContract.ok(snapshot.value)
end

function PortContract.validate_result(spec, operation_name, result, request, phase)
    local sanitized = PortContract.sanitize_completion_result(
        spec,
        operation_name,
        result,
        request,
        phase
    )
    if not sanitized.ok then
        return sanitized
    end
    return sanitized.value
end

function PortContract.validate_implementation(spec, implementation)
    local missing_operations = {}
    local state = type(spec) == "table" and SPEC_STATES[spec] or nil
    local index
    local operation

    if state == nil then
        return PortContract.error("PORT_CONTRACT_INVALID", {
            reason = "KNOWN_PORT_CONTRACT_REQUIRED",
        }, false)
    end
    if type(implementation) ~= "table" then
        return PortContract.error("PORT_IMPLEMENTATION_INVALID", {
            port = state.name,
            reason = "TABLE_REQUIRED",
        }, false)
    end

    for index = 1, #state.operations do
        operation = state.operations[index]
        if type(implementation[operation.name]) ~= "function" then
            missing_operations[#missing_operations + 1] = operation.name
        end
    end

    if #missing_operations > 0 then
        return PortContract.error("PORT_IMPLEMENTATION_INVALID", {
            port = state.name,
            reason = "OPERATIONS_MISSING",
            missing_operations = missing_operations,
        }, false)
    end

    return PortContract.ok(implementation)
end

function PortContract.guard_implementation(spec, implementation)
    local checked = PortContract.validate_implementation(spec, implementation)
    local spec_state = type(spec) == "table" and SPEC_STATES[spec] or nil
    local proxy
    local operation_methods = {}
    local index
    local operation

    if not checked.ok then
        return checked
    end
    proxy = {}
    for index = 1, #spec_state.operations do
        operation = spec_state.operations[index]
        local bound_operation = operation
        local raw_method = implementation[bound_operation.name]
        operation_methods[bound_operation.name] = function(_, request, complete)
            local callback_result = PortContract.validate_callback(complete)
            local sanitized_request
            local adapter_request_snapshot
            local binding_request
            local gate
            local gate_error
            local admission_finished = false
            local callback_enabled = false
            local inline_callback_count = 0
            local invoked
            local admission
            local admission_snapshot
            local sanitized_error
            local key

            local function adapter_failure(code, reason, details)
                if bound_operation.mutating then
                    local safe_details = {
                        reason = "INTERNAL_ERROR_IS_NOT_PLATFORM_CONCLUSION",
                        cause_code = code,
                        recovery = "QUERY_OR_RECONCILE",
                    }
                    if type(binding_request) == "table"
                        and type(binding_request.context) == "table"
                    then
                        safe_details.request_key =
                            binding_request.context.idempotency_key
                    end
                    return PortContract.error(
                        "PLATFORM_RESULT_UNKNOWN",
                        safe_details,
                        false
                    )
                end
                return PortContract.error(code, nil, false)
            end

            if not callback_result.ok then
                return callback_result
            end
            sanitized_request = PortContract.sanitize_request(
                spec,
                bound_operation.name,
                request
            )
            if not sanitized_request.ok then
                return sanitized_request
            end
            binding_request = sanitized_request.value
            adapter_request_snapshot = snapshot_payload(
                binding_request,
                "$.adapter_request"
            )
            if not adapter_request_snapshot.ok then
                return adapter_failure(
                    "PORT_ADAPTER_RETURN_INVALID",
                    "REQUEST_COPY_FAILED",
                    { cause = adapter_request_snapshot.error }
                )
            end
            gate, _, gate_error = PortContract.completion_gate(
                spec,
                bound_operation.name,
                complete,
                nil,
                binding_request
            )
            if gate_error ~= nil then
                return gate_error
            end

            local function guarded_complete(result)
                if not admission_finished then
                    inline_callback_count = inline_callback_count + 1
                    return false
                end
                if not callback_enabled then
                    return false
                end
                return gate(result)
            end

            invoked, admission = pcall(
                raw_method,
                implementation,
                adapter_request_snapshot.value,
                guarded_complete
            )
            admission_finished = true
            if not invoked then
                return adapter_failure(
                    "PORT_ADAPTER_FAILED",
                    "ADAPTER_RAISED"
                )
            end
            admission_snapshot = snapshot_payload(admission, "$.admission")
            if not admission_snapshot.ok then
                return adapter_failure(
                    "PORT_ADAPTER_RETURN_INVALID",
                    "ADMISSION_SNAPSHOT_INVALID",
                    { cause = admission_snapshot.error }
                )
            end
            admission = admission_snapshot.value
            if not PortContract.is_result(admission) then
                return adapter_failure(
                    "PORT_ADAPTER_RETURN_INVALID",
                    "ADMISSION_RESULT_REQUIRED"
                )
            end
            if inline_callback_count > 0 then
                return adapter_failure(
                    "PORT_ADAPTER_CALLBACK_INLINE",
                    "CALLBACK_MUST_NOT_RUN_INLINE",
                    { callback_count = inline_callback_count }
                )
            end
            if not admission.ok then
                sanitized_error = PortContract.sanitize_completion_result(
                    spec,
                    bound_operation.name,
                    admission,
                    binding_request,
                    RESULT_PHASE_ADMISSION
                )
                if not sanitized_error.ok then
                    return adapter_failure(
                        "PORT_ADAPTER_RETURN_INVALID",
                        "ADMISSION_ERROR_INVALID",
                        { cause = sanitized_error.error }
                    )
                end
                return sanitized_error.value
            end
            for key in raw_next, admission do
                if key ~= "ok" and key ~= "value" then
                    return adapter_failure(
                        "PORT_ADAPTER_RETURN_INVALID",
                        "ADMISSION_ENVELOPE_UNKNOWN_FIELD",
                        { field = tostring(key) }
                    )
                end
            end
            if type(admission.value) ~= "table"
                or admission.value.accepted ~= true
            then
                return adapter_failure(
                    "PORT_ADAPTER_RETURN_INVALID",
                    "ACCEPTED_TRUE_REQUIRED"
                )
            end
            for key in raw_next, admission.value do
                if key ~= "accepted" then
                    return adapter_failure(
                        "PORT_ADAPTER_RETURN_INVALID",
                        "ADMISSION_VALUE_UNKNOWN_FIELD",
                        { field = tostring(key) }
                    )
                end
            end
            callback_enabled = true
            return PortContract.ok({ accepted = true })
        end
    end
    proxy = setmetatable({}, {
        __index = operation_methods,
        __newindex = function()
            error("guarded port service is read-only", 2)
        end,
        __metatable = false,
    })
    return PortContract.ok(proxy)
end


function PortContract.validate_callback(complete)
    if type(complete) ~= "function" then
        return PortContract.error("PORT_CALLBACK_INVALID", {
            reason = "FUNCTION_REQUIRED",
        }, false)
    end
    return PortContract.ok(complete)
end

function PortContract.once(complete, on_suppressed, normalize_result)
    local completed = false
    local suppressed_count = 0

    local function wrapped(result)
        if completed then
            suppressed_count = suppressed_count + 1
            if on_suppressed then
                on_suppressed(PortContract.error(
                    "PORT_DUPLICATE_COMPLETION_SUPPRESSED",
                    {
                        reason = "COMPLETION_ALREADY_DELIVERED",
                        suppressed_count = suppressed_count,
                    },
                    false
                ), suppressed_count)
            end
            return false
        end

        if normalize_result then
            result = normalize_result(result)
        elseif not PortContract.is_result(result) then
            result = PortContract.error("PORT_RESULT_INVALID", {
                reason = "RESULT_ENVELOPE_INVALID",
            }, false)
        end

        completed = true
        complete(result)
        return true
    end

    local function state()
        return {
            completed = completed,
            suppressed_count = suppressed_count,
        }
    end

    return wrapped, state
end


function PortContract.completion_gate(
    spec,
    operation_name,
    complete,
    on_suppressed,
    request
)
    local callback_result = PortContract.validate_callback(complete)
    local operation = find_operation(spec, operation_name)
    local request_binding = nil
    local sanitized_request
    if not callback_result.ok then
        return nil, nil, callback_result
    end
    if operation == nil then
        return nil, nil, PortContract.error("PORT_OPERATION_UNKNOWN", {
            port = spec_name(spec),
            operation = operation_name,
        }, false)
    end
    if request ~= nil then
        sanitized_request = PortContract.sanitize_request(
            spec,
            operation_name,
            request
        )
        if not sanitized_request.ok then
            return nil, nil, sanitized_request
        end
        request_binding = sanitized_request.value
    end
    if operation.requires_idempotency and request_binding == nil then
        return nil, nil, PortContract.error("PORT_IDEMPOTENCY_REQUIRED", {
            port = spec_name(spec),
            operation = operation_name,
            reason = "COMPLETION_GATE_REQUIRES_REQUEST_BINDING",
        }, false)
    end
    local gate
    local state
    gate, state = PortContract.once(complete, on_suppressed, function(result)
        local normalized_ok
        local sanitized
        normalized_ok, sanitized = pcall(
            PortContract.sanitize_completion_result,
            spec,
            operation_name,
            result,
            request_binding,
            RESULT_PHASE_COMPLETION
        )
        if not normalized_ok then
            sanitized = PortContract.error("PORT_RESULT_INVALID", {
                port = spec_name(spec),
                operation = operation_name,
                reason = "COMPLETION_NORMALIZER_RAISED",
            }, false)
        end
        if sanitized.ok then
            if operation.requires_idempotency then
                local expected_request_key = request_binding.context
                    .idempotency_key
                local actual_request_key
                if sanitized.value.ok then
                    actual_request_key = type(sanitized.value.value) == "table"
                        and sanitized.value.value.request_key
                        or nil
                else
                    actual_request_key = type(sanitized.value.error.details)
                            == "table"
                        and sanitized.value.error.details.request_key
                        or nil
                end
                if actual_request_key ~= expected_request_key then
                    return PortContract.error("PLATFORM_RESULT_UNKNOWN", {
                        reason = "COMPLETION_REQUEST_KEY_MISMATCH",
                        recovery = "QUERY_OR_RECONCILE",
                        cause_code = "PORT_RESULT_INVALID",
                        request_key = expected_request_key,
                    }, false)
                end
            end
            if operation.mutating
                and sanitized.value.ok == false
                and (sanitized.value.error.code == "PLATFORM_UNAVAILABLE"
                    or sanitized.value.error.code == "PLATFORM_RATE_LIMITED")
            then
                return PortContract.error("PLATFORM_RESULT_UNKNOWN", {
                    reason = "ACCEPTED_MUTATION_HAS_AMBIGUOUS_PLATFORM_ERROR",
                    recovery = "QUERY_OR_RECONCILE",
                    cause_code = sanitized.value.error.code,
                    request_key = request_binding.context.idempotency_key,
                }, false)
            end
            if operation.mutating
                and sanitized.value.ok == false
                and (string_match(
                    sanitized.value.error.code,
                    "^PORT_"
                ) ~= nil
                    or string_match(
                        sanitized.value.error.code,
                        "^FAKE_"
                    ) ~= nil)
            then
                return PortContract.error("PLATFORM_RESULT_UNKNOWN", {
                    reason = "INTERNAL_ERROR_IS_NOT_PLATFORM_CONCLUSION",
                    recovery = "QUERY_OR_RECONCILE",
                    cause_code = sanitized.value.error.code,
                    request_key = request_binding.context.idempotency_key,
                }, false)
            end
            return sanitized.value
        end
        if operation.mutating then
            return PortContract.error("PLATFORM_RESULT_UNKNOWN", {
                reason = "CALLBACK_RESULT_CONTRACT_INVALID",
                recovery = "QUERY_OR_RECONCILE",
                cause_code = sanitized.error
                    and sanitized.error.code
                    or "PORT_RESULT_INVALID",
                request_key = request_binding.context.idempotency_key,
            }, false)
        end
        return PortContract.error("PORT_RESULT_INVALID", nil, false)
    end)
    return gate, state, nil
end

local function copy_array(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

local function copy_string_set(values)
    local copied = {}
    local key
    local value
    for key, value in raw_next, values do
        copied[key] = value
    end
    return copied
end

local function public_operation(operation)
    return {
        name = operation.name,
        mutating = operation.mutating,
        requires_idempotency = operation.requires_idempotency,
        request_fields = copy_array(operation.request_fields),
        allowed_request_fields = copy_string_set(
            operation.allowed_request_fields
        ),
        error_codes = copy_array(operation.error_codes),
        allowed_error_codes = copy_string_set(operation.allowed_error_codes),
    }
end

local function public_operations(state)
    local copied = {}
    local index
    for index = 1, #state.operations do
        copied[index] = public_operation(state.operations[index])
    end
    return copied
end

local function public_operation_map(state)
    local copied = {}
    local name
    local operation
    for name, operation in raw_next, state.operation_by_name do
        copied[name] = public_operation(operation)
    end
    return copied
end

function PortContract.get_operation_descriptor(spec, operation_name)
    local operation = find_operation(spec, operation_name)
    if operation == nil then
        return nil
    end
    return public_operation(operation)
end

function PortContract.list_operation_descriptors(spec)
    local state = type(spec) == "table" and SPEC_STATES[spec] or nil
    if state == nil then
        return nil
    end
    return public_operations(state)
end

function PortContract.get_contract_name(spec)
    return spec_name(spec)
end

local SPEC_METHODS = {}

function SPEC_METHODS:get_operation(operation_name)
    local operation = find_operation(self, operation_name)
    if operation == nil then
        return nil
    end
    return public_operation(operation)
end

function SPEC_METHODS:validate_request(operation_name, request)
    return PortContract.validate_request(self, operation_name, request)
end

function SPEC_METHODS:sanitize_request(operation_name, request)
    return PortContract.sanitize_request(self, operation_name, request)
end

function SPEC_METHODS:validate_implementation(implementation)
    return PortContract.validate_implementation(self, implementation)
end

function SPEC_METHODS:guard_implementation(implementation)
    return PortContract.guard_implementation(self, implementation)
end

function SPEC_METHODS:validate_result(operation_name, result, request, phase)
    return PortContract.validate_result(
        self,
        operation_name,
        result,
        request,
        phase
    )
end

function SPEC_METHODS:sanitize_completion_result(
    operation_name,
    result,
    request,
    phase
)
    return PortContract.sanitize_completion_result(
        self,
        operation_name,
        result,
        request,
        phase
    )
end

function SPEC_METHODS:completion_gate(
    operation_name,
    complete,
    on_suppressed,
    request
)
    return PortContract.completion_gate(
        self,
        operation_name,
        complete,
        on_suppressed,
        request
    )
end

function PortContract.define(definition)
    local spec
    local state
    local contract_version
    local operations = {}
    local operation_by_name = {}
    local index
    local source_operation
    local operation

    if type(definition) == "table" then
        contract_version = definition.contract_version
    end
    if contract_version == nil then
        contract_version = 1
    end
    if type(definition) ~= "table"
        or type(definition.name) ~= "string"
        or #definition.name < 1
        or #definition.name > 64
        or not string_match(definition.name, "^[A-Za-z][A-Za-z0-9_]*$")
        or type(definition.operations) ~= "table"
        or not is_dense_array(definition.operations)
        or not request_context_is_integer(contract_version)
        or contract_version < 1
        or contract_version > MAX_SAFE_INTEGER
    then
        error("invalid port contract definition")
    end

    for index = 1, #definition.operations do
        source_operation = definition.operations[index]
        if type(source_operation) ~= "table"
            or type(source_operation.name) ~= "string"
            or #source_operation.name < 1
            or #source_operation.name > 64
            or not string_match(
                source_operation.name,
                "^[a-z][a-z0-9_]*$"
            )
        then
            error("invalid operation in port contract " .. definition.name)
        end
        if operation_by_name[source_operation.name] then
            error(
                "duplicate operation "
                    .. source_operation.name
                    .. " in port contract "
                    .. definition.name
            )
        end

        operation = {
            name = source_operation.name,
            mutating = source_operation.mutating == true,
            requires_idempotency = source_operation.requires_idempotency == true,
            validate_request = source_operation.validate_request,
            validate_success = source_operation.validate_success,
            validate_error = source_operation.validate_error,
            request_fields = {},
            allowed_request_fields = { context = true },
            error_codes = {},
            allowed_error_codes = {},
        }
        if operation.mutating ~= operation.requires_idempotency then
            error(
                "mutating and requires_idempotency must match for operation "
                    .. source_operation.name
                    .. " in port contract "
                    .. definition.name
            )
        end
        if type(operation.validate_success) ~= "function" then
            error(
                "validate_success is required for operation "
                    .. source_operation.name
                    .. " in port contract "
                    .. definition.name
            )
        end
        if operation.validate_error ~= nil
            and type(operation.validate_error) ~= "function"
        then
            error(
                "validate_error must be a function for operation "
                    .. source_operation.name
                    .. " in port contract "
                    .. definition.name
            )
        end
        if type(source_operation.request_fields) ~= "table"
            or not is_dense_array(source_operation.request_fields)
        then
            error(
                "request_fields are required for operation "
                    .. source_operation.name
                    .. " in port contract "
                    .. definition.name
            )
        end
        local field_index
        for field_index = 1, #source_operation.request_fields do
            local field_name = source_operation.request_fields[field_index]
            if type(field_name) ~= "string"
                or #field_name < 1
                or #field_name > 64
                or not string_match(field_name, "^[a-z][a-z0-9_]*$")
                or field_name == "context"
                or operation.allowed_request_fields[field_name]
            then
                error(
                    "invalid request field in operation "
                        .. source_operation.name
                        .. " in port contract "
                        .. definition.name
                )
            end
            operation.request_fields[field_index] = field_name
            operation.allowed_request_fields[field_name] = true
        end
        if source_operation.error_codes ~= nil
            and (type(source_operation.error_codes) ~= "table"
                or not is_dense_array(source_operation.error_codes))
        then
            error(
                "error_codes must be a table for operation "
                    .. source_operation.name
                    .. " in port contract "
                    .. definition.name
            )
        end
        local error_index
        local error_code
        local source_error_codes = source_operation.error_codes or {}
        for error_index = 1, #source_error_codes do
            error_code = source_error_codes[error_index]
            if type(error_code) ~= "string"
                or #error_code < 1
                or #error_code > 64
                or not string_match(error_code, "^[A-Z][A-Z0-9_]*$")
                or operation.allowed_error_codes[error_code]
            then
                error(
                    "invalid error code in operation "
                        .. source_operation.name
                        .. " in port contract "
                        .. definition.name
                )
            end
            operation.error_codes[error_index] = error_code
            operation.allowed_error_codes[error_code] = true
        end
        operations[#operations + 1] = operation
        operation_by_name[operation.name] = operation
    end

    state = {
        name = definition.name,
        contract_version = contract_version,
        operations = operations,
        operation_by_name = operation_by_name,
    }
    spec = setmetatable({}, {
        __index = function(_, key)
            if key == "name" then
                return state.name
            end
            if key == "contract_version" then
                return state.contract_version
            end
            if key == "operations" then
                return public_operations(state)
            end
            if key == "operation_by_name" then
                return public_operation_map(state)
            end
            return SPEC_METHODS[key]
        end,
        __newindex = function()
            error("port contract is read-only", 2)
        end,
        __metatable = false,
    })
    SPEC_STATES[spec] = state
    return spec
end

PortContract.MAX_SAFE_INTEGER = MAX_SAFE_INTEGER
PortContract.MAX_RESULT_DEPTH = MAX_RESULT_DEPTH
PortContract.MAX_STRING_BYTES = MAX_STRING_BYTES
PortContract.MAX_PAYLOAD_DEPTH = MAX_PAYLOAD_DEPTH
PortContract.MAX_PAYLOAD_NODES = MAX_PAYLOAD_NODES
PortContract.MAX_TOTAL_STRING_BYTES = MAX_TOTAL_STRING_BYTES
PortContract.MAX_KEY_BYTES = MAX_KEY_BYTES
PortContract.MAX_VALUE_STRING_BYTES = MAX_VALUE_STRING_BYTES

function PortContract.inspect_payload_budget(value, root_path)
    local inspected = snapshot_payload(value, root_path or "$.payload")
    if not inspected.ok then
        return inspected
    end
    return PortContract.ok({
        nodes = inspected.stats.nodes,
        total_string_bytes = inspected.stats.total_string_bytes,
    })
end

return setmetatable({}, {
    __index = PortContract,
    __newindex = function()
        error("port contract module is read-only", 2)
    end,
    __metatable = false,
})
