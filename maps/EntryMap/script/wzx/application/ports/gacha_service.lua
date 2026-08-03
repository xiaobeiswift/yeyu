local PortContract = require "wzx.application.ports.port_contract"
local RuntimeId = require "wzx.domain.common.runtime_id"

local function validate_pool(request)
    local invalid = PortContract.check_non_empty_string(request, "pool_id", false)
    local validated
    if invalid then
        return invalid
    end
    validated = RuntimeId.validate_component(request.pool_id, "pool_id")
    if not validated.ok then
        return PortContract.invalid_request(
            "pool_id",
            "STABLE_POOL_ID_REQUIRED",
            { cause_code = validated.error.code }
        )
    end
    return PortContract.ok(true)
end

local function validate_component_request(request, field_name, reason)
    local invalid = PortContract.check_non_empty_string(
        request,
        field_name,
        false
    )
    local validated
    if invalid then
        return invalid
    end
    validated = RuntimeId.validate_component(request[field_name], field_name)
    if not validated.ok then
        return PortContract.invalid_request(field_name, reason, {
            cause_code = validated.error.code,
        })
    end
    return nil
end

local function validate_request_pool(request)
    local checked = validate_pool(request)
    local invalid
    if not checked.ok then
        return checked
    end
    invalid = validate_component_request(
        request,
        "expected_probability_version",
        "STABLE_PROBABILITY_VERSION_REQUIRED"
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_query_pool_request(request)
    local invalid = validate_component_request(
        request,
        "original_request_key",
        "STABLE_REQUEST_KEY_REQUIRED"
    )
    if invalid then
        return invalid
    end
    invalid = validate_component_request(
        request,
        "expected_pool_id",
        "STABLE_POOL_ID_REQUIRED"
    )
    if invalid then
        return invalid
    end
    invalid = validate_component_request(
        request,
        "expected_probability_version",
        "STABLE_PROBABILITY_VERSION_REQUIRED"
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local REWARD_PREFIX_BY_KIND = {
    CHARACTER = "char_",
    MARTIAL = "martial_",
    VOUCHER = "item_",
}

local function validate_request_key_result(value)
    local invalid = PortContract.check_result_string(
        value,
        "request_key",
        false
    )
    local validated
    if invalid then
        return invalid
    end
    validated = RuntimeId.validate_component(
        value.request_key,
        "request_key"
    )
    if not validated.ok then
        return PortContract.invalid_result(
            "request_key",
            "STABLE_REQUEST_KEY_REQUIRED",
            { cause_code = validated.error.code }
        )
    end
    return nil
end

local function validate_component_result(value, field_name, reason)
    local invalid = PortContract.check_result_string(
        value,
        field_name,
        false
    )
    local validated
    if invalid then
        return invalid
    end
    validated = RuntimeId.validate_component(value[field_name], field_name)
    if not validated.ok then
        return PortContract.invalid_result(field_name, reason, {
            cause_code = validated.error.code,
        })
    end
    return nil
end

local function validate_result_id(value)
    local invalid = PortContract.check_result_string(
        value,
        "result_id",
        false
    )
    local validated
    if invalid then
        return invalid
    end
    validated = RuntimeId.validate_stable_order_key(
        value.result_id,
        "result_id"
    )
    if not validated.ok then
        return PortContract.invalid_result(
            "result_id",
            "STABLE_RESULT_ID_REQUIRED",
            { cause_code = validated.error.code }
        )
    end
    return nil
end

local function validate_reward_row(row, index)
    local invalid = PortContract.check_result_fields(
        row,
        { "reward_kind", "content_id", "quantity" }
    )
    local prefix
    local content_id_result

    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "rewards"
        return invalid
    end
    invalid = PortContract.check_result_enum(
        row,
        "reward_kind",
        { "CHARACTER", "MARTIAL", "VOUCHER" },
        false
    )
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "rewards"
        return invalid
    end
    prefix = REWARD_PREFIX_BY_KIND[row.reward_kind]
    content_id_result = RuntimeId.validate_content(
        row.content_id,
        prefix,
        "content_id"
    )
    if not content_id_result.ok then
        return PortContract.invalid_result(
            "rewards",
            "MAPPED_REWARD_CONTENT_ID_INVALID",
            {
                entry_index = index,
                reward_kind = row.reward_kind,
                expected_prefix = prefix,
                cause_code = content_id_result.error.code,
            }
        )
    end
    invalid = PortContract.check_result_integer(
        row,
        "quantity",
        1,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "rewards"
        return invalid
    end
    return nil
end

local function validate_rewards(value)
    local invalid = PortContract.check_result_list(
        value,
        "rewards",
        false,
        false
    )
    local seen_content_ids = {}
    local previous_content_id
    local index
    local row

    if invalid then
        return invalid
    end
    if #value.rewards > 100 then
        return PortContract.invalid_result("rewards", "LIST_TOO_LONG", {
            maximum = 100,
            actual = #value.rewards,
        })
    end
    for index = 1, #value.rewards do
        row = value.rewards[index]
        invalid = validate_reward_row(row, index)
        if invalid then
            return invalid
        end
        if seen_content_ids[row.content_id] then
            return PortContract.invalid_result(
                "rewards",
                "DUPLICATE_REWARD_CONTENT_ID",
                { entry_index = index, content_id = row.content_id }
            )
        end
        if previous_content_id ~= nil
            and row.content_id <= previous_content_id
        then
            return PortContract.invalid_result(
                "rewards",
                "REWARD_CONTENT_IDS_MUST_BE_ASCENDING",
                { entry_index = index, content_id = row.content_id }
            )
        end
        seen_content_ids[row.content_id] = true
        previous_content_id = row.content_id
    end
    return nil
end

local function validate_confirmed_draw(
    value,
    request,
    request_key_source
)
    local required_fields = {
        "status",
        "pool_id",
        "request_key",
        "probability_version",
        "result_id",
        "trusted_unix_seconds",
        "platform_code",
        "rewards",
    }
    local invalid

    invalid = PortContract.check_result_fields(value, required_fields)
    if invalid then
        return invalid
    end
    invalid = validate_component_result(
        value,
        "pool_id",
        "STABLE_POOL_ID_REQUIRED"
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
    invalid = validate_request_key_result(value)
    if invalid then
        return invalid
    end
    if request ~= nil then
        local expected_request_key
        if request_key_source == "IDEMPOTENCY" then
            if type(request.context) == "table" then
                expected_request_key = request.context.idempotency_key
            end
        else
            expected_request_key = request.original_request_key
        end
        if expected_request_key == nil
            or value.request_key ~= expected_request_key
        then
            return PortContract.invalid_result(
                "request_key",
                "REQUEST_ECHO_MISMATCH",
                {
                    expected = expected_request_key,
                    actual = value.request_key,
                }
            )
        end
    end
    invalid = validate_component_result(
        value,
        "probability_version",
        "STABLE_PROBABILITY_VERSION_REQUIRED"
    )
    if invalid then
        return invalid
    end
    invalid = validate_result_id(value)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "trusted_unix_seconds",
        0,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    if request ~= nil then
        local expected_pool_id
        if request_key_source == "IDEMPOTENCY" then
            expected_pool_id = request.pool_id
        else
            expected_pool_id = request.expected_pool_id
        end
        if value.pool_id ~= expected_pool_id then
            return PortContract.invalid_result(
                "pool_id",
                "REQUEST_ECHO_MISMATCH",
                { expected = expected_pool_id, actual = value.pool_id }
            )
        end
        if value.probability_version
            ~= request.expected_probability_version
        then
            return PortContract.invalid_result(
                "probability_version",
                "REQUEST_ECHO_MISMATCH",
                {
                    expected = request.expected_probability_version,
                    actual = value.probability_version,
                }
            )
        end
    end
    invalid = PortContract.check_result_enum(
        value,
        "platform_code",
        { "SUCCESS" },
        false
    )
    if invalid then
        return invalid
    end
    invalid = validate_rewards(value)
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_request_pool_success(value, request)
    return validate_confirmed_draw(
        value,
        request,
        "IDEMPOTENCY"
    )
end

local function validate_query_pool_success(value, request)
    local invalid

    if type(value) ~= "table" then
        return PortContract.invalid_result("value", "TABLE_REQUIRED")
    end
    if value.status == "CONFIRMED" then
        return validate_confirmed_draw(
            value,
            request,
            "QUERY"
        )
    end
    invalid = PortContract.check_result_fields(
        value,
        { "status", "request_key" }
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
    invalid = validate_request_key_result(value)
    if invalid then
        return invalid
    end
    if request ~= nil
        and value.request_key ~= request.original_request_key
    then
        return PortContract.invalid_result(
            "request_key",
            "REQUEST_ECHO_MISMATCH",
            {
                expected = request.original_request_key,
                actual = value.request_key,
            }
        )
    end
    return PortContract.ok(true)
end

local function validate_pool_capability_success(value, request)
    local invalid = PortContract.check_result_fields(value, {
        "status",
        "pool_id",
        "authoritative",
        "consumption_atomic",
        "result_persistence_atomic",
        "request_query_supported",
        "audit_export_supported",
    })
    local boolean_fields = {
        "authoritative",
        "consumption_atomic",
        "result_persistence_atomic",
        "request_query_supported",
        "audit_export_supported",
    }
    local index

    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_enum(
        value,
        "status",
        { "VERIFIED" },
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(value, "pool_id", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "pool_id",
        request
    )
    if invalid then
        return invalid
    end
    for index = 1, #boolean_fields do
        invalid = PortContract.check_result_boolean(
            value,
            boolean_fields[index],
            false
        )
        if invalid then
            return invalid
        end
    end
    return PortContract.ok(true)
end

return PortContract.define({
    name = "GachaService",
    contract_version = 1,
    operations = {
        {
            name = "request_pool",
            request_fields = {
                "pool_id",
                "expected_probability_version",
            },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_request_pool,
            validate_success = validate_request_pool_success,
            error_codes = {
                "GACHA_CREDENTIAL_INSUFFICIENT",
                "GACHA_UNKNOWN_REWARD",
            },
        },
        {
            name = "query_pool_request",
            request_fields = {
                "original_request_key",
                "expected_pool_id",
                "expected_probability_version",
            },
            validate_request = validate_query_pool_request,
            validate_success = validate_query_pool_success,
            error_codes = { "GACHA_UNKNOWN_REWARD" },
        },
        {
            name = "get_pool_capability",
            request_fields = { "pool_id" },
            validate_request = validate_pool,
            validate_success = validate_pool_capability_success,
        },
    },
})
