local PortContract = require "wzx.application.ports.port_contract"

local function validate_read_public_snapshot(request)
    local invalid = PortContract.check_non_empty_string(request, "opponent_aid", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_integer(
        request,
        "slot_id",
        100,
        100,
        false
    )
    if invalid then
        return invalid
    end
    return PortContract.ok(true)
end

local function validate_read_success(value, request)
    local invalid = PortContract.check_result_fields(value, {
        "status",
        "opponent_aid",
        "slot_id",
        "snapshot",
        "revision",
        "payload_checksum",
    })
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_string(value, "opponent_aid", false)
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_request_echo(
        value,
        "opponent_aid",
        request
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_integer(
        value,
        "slot_id",
        100,
        100,
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
        { "FOUND" },
        false
    )
    if invalid then
        return invalid
    end
    invalid = PortContract.check_result_table(value, "snapshot", false)
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
    if type(value.payload_checksum) ~= "string"
        or #value.payload_checksum ~= 64
        or not string.match(value.payload_checksum, "^[0-9a-f]+$")
    then
        return PortContract.invalid_result(
            "payload_checksum",
            "LOWERCASE_SHA256_REQUIRED"
        )
    end
    return PortContract.ok(true)
end

return PortContract.define({
    name = "OpenArchiveService",
    contract_version = 1,
    operations = {
        {
            name = "read_public_snapshot",
            request_fields = { "opponent_aid", "slot_id" },
            validate_request = validate_read_public_snapshot,
            validate_success = validate_read_success,
            error_codes = { "OPEN_ARCHIVE_NOT_FOUND" },
        },
    },
})
