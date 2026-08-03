local PortContract = require "wzx.application.ports.port_contract"

local function validate_now(_request)
    return PortContract.ok(true)
end

local function validate_now_success(value)
    local invalid = PortContract.check_result_fields(value, {
        "unix_seconds",
        "trust_level",
        "response_id",
    })
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "unix_seconds",
        0,
        PortContract.MAX_SAFE_INTEGER,
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_enum(
        value,
        "trust_level",
        { "TRUSTED" },
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(value, "response_id", false)
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

return PortContract.define({
    name = "ClockService",
    contract_version = 1,
    operations = {
        {
            name = "now",
            request_fields = {},
            validate_request = validate_now,
            validate_success = validate_now_success,
        },
    },
})
