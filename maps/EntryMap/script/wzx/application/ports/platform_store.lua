local PortContract = require "wzx.application.ports.port_contract"

local function validate_goods(request)
    local invalid = PortContract.check_non_empty_string(request, "goods_id", false)
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_purchase(request)
    local invalid = PortContract.check_non_empty_string(request, "goods_id", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "quantity",
        1,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_platform_item(request)
    local invalid = PortContract.check_non_empty_string(
        request,
        "platform_item_id",
        false
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_consume_item(request)
    local invalid = PortContract.check_non_empty_string(
        request,
        "platform_item_id",
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "quantity",
        1,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_reconcile(request)
    local invalid
    local index
    local seen_order_refs = {}
    local previous_order_ref

    invalid = PortContract.check_list(
        request,
        "known_order_refs",
        true,
        true
    )
    if invalid then
        return invalid
    end
    if request.known_order_refs ~= nil then
        if #request.known_order_refs > 1000 then
            return PortContract.invalid_request(
                "known_order_refs",
                "LIST_TOO_LONG",
                { maximum = 1000, actual = #request.known_order_refs }
            )
        end
        for index = 1, #request.known_order_refs do
            if type(request.known_order_refs[index]) ~= "string"
                or request.known_order_refs[index] == ""
            then
                return PortContract.invalid_request(
                    "known_order_refs",
                    "NON_EMPTY_ORDER_REFERENCE_REQUIRED",
                    { entry_index = index }
                )
            end
            if #request.known_order_refs[index] > PortContract.MAX_STRING_BYTES then
                return PortContract.invalid_request(
                    "known_order_refs",
                    "ORDER_REFERENCE_TOO_LONG",
                    {
                        entry_index = index,
                        maximum_bytes = PortContract.MAX_STRING_BYTES,
                    }
                )
            end
            if seen_order_refs[request.known_order_refs[index]] then
                return PortContract.invalid_request(
                    "known_order_refs",
                    "DUPLICATE_ORDER_REFERENCE",
                    { entry_index = index }
                )
            end
            if previous_order_ref ~= nil
                and request.known_order_refs[index] <= previous_order_ref
            then
                return PortContract.invalid_request(
                    "known_order_refs",
                    "ORDER_REFERENCES_MUST_BE_ASCENDING",
                    { entry_index = index }
                )
            end
            seen_order_refs[request.known_order_refs[index]] = true
            previous_order_ref = request.known_order_refs[index]
        end
    end
    invalid = PortContract.check_table(request, "entitlement_cursor", true)
    if invalid then
        return invalid
    end
    if (request.known_order_refs == nil or #request.known_order_refs == 0)
        and request.entitlement_cursor == nil
    then
        return PortContract.invalid_request(
            "known_order_refs",
            "ORDER_REFS_OR_CURSOR_REQUIRED"
        )
    end
    if type(request.cursor_request_hash) ~= "string"
        or #request.cursor_request_hash ~= 64
        or not string.match(request.cursor_request_hash, "^[0-9a-f]+$")
    then
        return PortContract.invalid_request(
            "cursor_request_hash",
            "LOWERCASE_SHA256_REQUIRED"
        )
    end
    return PortContract.ok(true)
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

local function validate_goods_success(value, request)
    local invalid = PortContract.check_result_fields(
        value,
        {
            "goods_id",
            "status",
            "currency_code",
            "price_minor",
            "metadata",
        },
        { "valid_from_unix", "valid_until_unix" }
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "goods_id",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(value, "goods_id", false)
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
    if type(value.currency_code) ~= "string"
        or not string.match(value.currency_code, "^[A-Z][A-Z][A-Z]$")
    then
        return PortContract.invalid_result(
            "currency_code",
            "ISO_4217_ALPHA_CODE_REQUIRED"
        )
    end
    invalid = PortContract.check_result_integer(
        value,
        "price_minor",
        0,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_table(value, "metadata", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "valid_from_unix",
        0,
        PortContract.MAX_SAFE_INTEGER,
        true
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "valid_until_unix",
        0,
        PortContract.MAX_SAFE_INTEGER,
        true
    )
    if invalid then
        return invalid
    end
    if value.valid_from_unix ~= nil
        and value.valid_until_unix ~= nil
        and value.valid_until_unix <= value.valid_from_unix
    then
        return PortContract.invalid_result(
            "valid_until_unix",
            "VALIDITY_WINDOW_MUST_INCREASE"
        )
    end
    return PortContract.ok(true)
end

local function validate_purchase_success(value, request)
    local invalid = PortContract.check_result_fields(value, {
        "status",
        "order_ref",
        "goods_id",
        "quantity",
        "request_key",
    })
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
    invalid = PortContract.check_result_string(value, "order_ref", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(value, "goods_id", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "goods_id",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "quantity",
        1,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "quantity",
        request
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_owned_count_success(value, request)
    local invalid = PortContract.check_result_fields(
        value,
        { "platform_item_id", "count", "revision" }
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(
        value,
        "platform_item_id",
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "platform_item_id",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "count",
        0,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "revision",
        0,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_consume_success(value, request)
    local invalid = PortContract.check_result_fields(value, {
        "status",
        "platform_item_id",
        "consumed_quantity",
        "remaining_count",
        "revision",
        "request_key",
    })
    if invalid then
        return invalid
    end
    invalid = validate_result_request_key(value, request)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "platform_item_id",
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
        "consumed_quantity",
        request,
        "quantity"
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(
        value,
        "platform_item_id",
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "consumed_quantity",
        1,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "remaining_count",
        0,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "revision",
        0,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_reconcile_row(row, index)
    local invalid
    local required_fields

    if type(row) ~= "table" then
        return PortContract.invalid_result("orders", "ROW_TABLE_REQUIRED", {
            entry_index = index,
        })
    end
    if row.status == "CONFIRMED" or row.status == "REFUNDED" then
        required_fields = { "order_ref", "status", "goods_id", "quantity" }
    elseif row.status == "PENDING"
        or row.status == "NOT_FOUND"
        or row.status == "UNKNOWN"
    then
        required_fields = { "order_ref", "status" }
    else
        return PortContract.invalid_result("orders", "ROW_STATUS_INVALID", {
            entry_index = index,
            actual = row.status,
        })
    end
    invalid = PortContract.check_result_fields(row, required_fields)
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "orders"
        return invalid
    end
    invalid = PortContract.check_result_string(row, "order_ref", false)
    if invalid then
        invalid.error.details.entry_index = index
        invalid.error.details.parent_field = "orders"
        return invalid
    end
    if row.status == "CONFIRMED" or row.status == "REFUNDED" then
        invalid = PortContract.check_result_string(row, "goods_id", false)
        if invalid then
            invalid.error.details.entry_index = index
            invalid.error.details.parent_field = "orders"
            return invalid
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
            invalid.error.details.parent_field = "orders"
            return invalid
        end
    end
    return nil
end

local function validate_reconcile_success(value, request)
    local invalid = PortContract.check_result_fields(
        value,
        {
            "status",
            "orders",
            "request_id",
            "cursor_request_hash",
        },
        { "entitlement_cursor", "entitlement_cursor_hash" }
    )
    local seen_order_refs = {}
    local previous_order_ref
    local index
    local row

    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(value, "request_id", false)
    if invalid then
        return invalid
    end
    if request ~= nil then
        local expected_request_id = type(request.context) == "table"
            and request.context.request_id
            or nil
        if expected_request_id == nil
            or value.request_id ~= expected_request_id
        then
            return PortContract.invalid_result(
                "request_id",
                "REQUEST_ECHO_MISMATCH",
                {
                    expected = expected_request_id,
                    actual = value.request_id,
                }
            )
        end
        if value.cursor_request_hash ~= request.cursor_request_hash then
            return PortContract.invalid_result(
                "cursor_request_hash",
                "REQUEST_ECHO_MISMATCH",
                {
                    expected = request.cursor_request_hash,
                    actual = value.cursor_request_hash,
                }
            )
        end
    end
    if type(value.cursor_request_hash) ~= "string"
        or #value.cursor_request_hash ~= 64
        or not string.match(value.cursor_request_hash, "^[0-9a-f]+$")
    then
        return PortContract.invalid_result(
            "cursor_request_hash",
            "LOWERCASE_SHA256_REQUIRED"
        )
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
    if (value.entitlement_cursor == nil)
        ~= (value.entitlement_cursor_hash == nil)
    then
        return PortContract.invalid_result(
            "entitlement_cursor",
            "CURSOR_AND_HASH_MUST_APPEAR_TOGETHER"
        )
    end
    if value.entitlement_cursor_hash ~= nil
        and (type(value.entitlement_cursor_hash) ~= "string"
            or #value.entitlement_cursor_hash ~= 64
            or not string.match(
                value.entitlement_cursor_hash,
                "^[0-9a-f]+$"
            ))
    then
        return PortContract.invalid_result(
            "entitlement_cursor_hash",
            "LOWERCASE_SHA256_REQUIRED"
        )
    end
    invalid = PortContract.check_result_list(value, "orders", true, false)
    if invalid then
        return invalid
    end
    if #value.orders > 1000 then
        return PortContract.invalid_result("orders", "LIST_TOO_LONG", {
            maximum = 1000,
            actual = #value.orders,
        })
    end
    invalid = PortContract.check_result_table(
        value,
        "entitlement_cursor",
        true
    )
    if invalid then
        return invalid
    end
    for index = 1, #value.orders do
        row = value.orders[index]
        invalid = validate_reconcile_row(row, index)
        if invalid then
            return invalid
        end
        if seen_order_refs[row.order_ref] then
            return PortContract.invalid_result(
                "orders",
                "DUPLICATE_ORDER_REFERENCE",
                { entry_index = index, order_ref = row.order_ref }
            )
        end
        if previous_order_ref ~= nil and row.order_ref <= previous_order_ref then
            return PortContract.invalid_result(
                "orders",
                "ORDER_REFERENCES_MUST_BE_ASCENDING",
                { entry_index = index, order_ref = row.order_ref }
            )
        end
        seen_order_refs[row.order_ref] = true
        previous_order_ref = row.order_ref
    end
    if request ~= nil and request.known_order_refs ~= nil then
        for index = 1, #request.known_order_refs do
            if not seen_order_refs[request.known_order_refs[index]] then
                return PortContract.invalid_result(
                    "orders",
                    "REQUESTED_ORDER_RESULT_MISSING",
                    {
                        entry_index = index,
                        order_ref = request.known_order_refs[index],
                    }
                )
            end
        end
    end
    return PortContract.ok(true)
end

return PortContract.define({
    name = "PlatformStore",
    contract_version = 1,
    operations = {
        {
            name = "get_goods_info",
            request_fields = { "goods_id" },
            validate_request = validate_goods,
            validate_success = validate_goods_success,
            error_codes = { "STORE_GOODS_UNAVAILABLE" },
        },
        {
            name = "purchase",
            request_fields = { "goods_id", "quantity" },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_purchase,
            validate_success = validate_purchase_success,
            error_codes = { "STORE_GOODS_UNAVAILABLE" },
        },
        {
            name = "get_owned_count",
            request_fields = { "platform_item_id" },
            validate_request = validate_platform_item,
            validate_success = validate_owned_count_success,
        },
        {
            name = "consume_item",
            request_fields = { "platform_item_id", "quantity" },
            mutating = true,
            requires_idempotency = true,
            validate_request = validate_consume_item,
            validate_success = validate_consume_success,
        },
        {
            name = "reconcile",
            request_fields = {
                "known_order_refs",
                "entitlement_cursor",
                "cursor_request_hash",
            },
            validate_request = validate_reconcile,
            validate_success = validate_reconcile_success,
        },
    },
})
