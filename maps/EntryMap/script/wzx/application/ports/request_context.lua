local RuntimeId = require "wzx.domain.common.runtime_id"

local RequestContext = {}
local validate_runtime_component = RuntimeId.validate_component
local math_floor = math.floor
local raw_next = next

local MAX_ID_BYTES = 64
local MAX_SAFE_INTEGER = 9007199254740991
local ALLOWED_FIELDS = {
    request_id = true,
    correlation_id = true,
    idempotency_key = true,
    attempt = true,
    started_at_local = true,
    timeout_ms = true,
}

local function result_ok(value)
    return {
        ok = true,
        value = value,
    }
end

local function result_error(code, details)
    return {
        ok = false,
        error = {
            code = code,
            message_key = "error." .. string.lower(code),
            retryable = false,
            details = details,
        },
    }
end

local function is_finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function is_integer(value)
    return is_finite_number(value) and value == math_floor(value)
end

local function validate_identifier(value, field_name, required)
    local validated

    if value == nil and not required then
        return nil
    end

    validated = validate_runtime_component(value, field_name)
    if not validated.ok then
        return result_error("PORT_REQUEST_CONTEXT_INVALID", {
            field = field_name,
            reason = "RUNTIME_ID_COMPONENT_REQUIRED",
            max_bytes = MAX_ID_BYTES,
            cause_code = validated.error.code,
        })
    end

    return nil
end

function RequestContext.validate(context, options)
    options = options or {}

    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return result_error("PORT_REQUEST_CONTEXT_INVALID", {
            field = "options",
            reason = "PLAIN_TABLE_REQUIRED",
        })
    end
    local option_field
    for option_field in raw_next, options do
        if option_field ~= "require_idempotency" then
            return result_error("PORT_REQUEST_CONTEXT_INVALID", {
                field = "options." .. tostring(option_field),
                reason = "UNKNOWN_FIELD",
            })
        end
    end
    local require_idempotency = rawget(options, "require_idempotency")
    if require_idempotency ~= nil and type(require_idempotency) ~= "boolean" then
        return result_error("PORT_REQUEST_CONTEXT_INVALID", {
            field = "options.require_idempotency",
            reason = "BOOLEAN_REQUIRED",
        })
    end

    if type(context) ~= "table" or getmetatable(context) ~= nil then
        return result_error("PORT_REQUEST_CONTEXT_INVALID", {
            field = "context",
            reason = "PLAIN_TABLE_REQUIRED",
        })
    end

    local field
    for field in raw_next, context do
        if type(field) ~= "string" or not ALLOWED_FIELDS[field] then
            return result_error("PORT_REQUEST_CONTEXT_INVALID", {
                field = tostring(field),
                reason = "UNKNOWN_FIELD",
            })
        end
    end

    local request_id_error = validate_identifier(context.request_id, "request_id", true)
    if request_id_error then
        return request_id_error
    end

    local correlation_id_error = validate_identifier(
        context.correlation_id,
        "correlation_id",
        true
    )
    if correlation_id_error then
        return correlation_id_error
    end

    local idempotency_error = validate_identifier(
        context.idempotency_key,
        "idempotency_key",
        require_idempotency == true
    )
    if idempotency_error then
        if require_idempotency == true and context.idempotency_key == nil then
            idempotency_error.error.code = "PORT_IDEMPOTENCY_REQUIRED"
            idempotency_error.error.message_key = "error.port_idempotency_required"
        end
        return idempotency_error
    end

    if not is_integer(context.attempt)
        or context.attempt < 1
        or context.attempt > MAX_SAFE_INTEGER
    then
        return result_error("PORT_REQUEST_CONTEXT_INVALID", {
            field = "attempt",
            reason = "SAFE_POSITIVE_INTEGER_REQUIRED",
            maximum = MAX_SAFE_INTEGER,
        })
    end

    if context.started_at_local ~= nil
        and (not is_finite_number(context.started_at_local)
            or context.started_at_local < 0
            or context.started_at_local > MAX_SAFE_INTEGER)
    then
        return result_error("PORT_REQUEST_CONTEXT_INVALID", {
            field = "started_at_local",
            reason = "NON_NEGATIVE_SAFE_NUMBER_REQUIRED",
            maximum = MAX_SAFE_INTEGER,
        })
    end

    if context.timeout_ms ~= nil
        and (not is_integer(context.timeout_ms)
            or context.timeout_ms < 1
            or context.timeout_ms > MAX_SAFE_INTEGER)
    then
        return result_error("PORT_REQUEST_CONTEXT_INVALID", {
            field = "timeout_ms",
            reason = "SAFE_POSITIVE_INTEGER_REQUIRED",
            maximum = MAX_SAFE_INTEGER,
        })
    end

    return result_ok({
        request_id = context.request_id,
        correlation_id = context.correlation_id,
        idempotency_key = context.idempotency_key,
        attempt = context.attempt,
        started_at_local = context.started_at_local,
        timeout_ms = context.timeout_ms,
    })
end

RequestContext.MAX_ID_BYTES = MAX_ID_BYTES
RequestContext.MAX_SAFE_INTEGER = MAX_SAFE_INTEGER
RequestContext.is_integer = is_integer
RequestContext.is_finite_number = is_finite_number

return RequestContext
