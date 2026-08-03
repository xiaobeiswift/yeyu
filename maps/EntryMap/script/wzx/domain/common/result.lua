-- Foundation V1 result type. Expected business failures are values, not exceptions.

local Result = {}

function Result.ok(value)
    return {
        ok = true,
        value = value,
    }
end

function Result.err(code, message_key, retryable, details)
    return {
        ok = false,
        error = {
            code = code,
            message_key = message_key,
            retryable = retryable == true,
            details = details,
        },
    }
end

function Result.validate(value)
    if type(value) ~= 'table' or type(value.ok) ~= 'boolean' then
        return Result.err('RESULT_INVALID', 'error.foundation.result_invalid', false)
    end

    if value.ok then
        if value.error ~= nil then
            return Result.err('RESULT_INVALID', 'error.foundation.result_has_error_on_success', false)
        end
        return Result.ok(value)
    end

    local err = value.error
    if type(err) ~= 'table'
        or type(err.code) ~= 'string'
        or err.code == ''
        or type(err.message_key) ~= 'string'
        or err.message_key == ''
        or type(err.retryable) ~= 'boolean'
    then
        return Result.err('RESULT_INVALID', 'error.foundation.result_error_invalid', false)
    end

    return Result.ok(value)
end

return Result
