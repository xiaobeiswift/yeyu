-- Foundation V1 result type. Expected business failures are values, not exceptions.

local Result = {}
local get_metatable = getmetatable
local raw_get = rawget
local type_value = type

local function ok(value)
    return {
        ok = true,
        value = value,
    }
end
Result.ok = ok

local function err(code, message_key, retryable, details)
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
Result.err = err

local function validate(value)
    if type_value(value) ~= 'table'
        or get_metatable(value) ~= nil
        or type_value(raw_get(value, 'ok')) ~= 'boolean'
    then
        return err('RESULT_INVALID', 'error.foundation.result_invalid', false)
    end

    if raw_get(value, 'ok') then
        if raw_get(value, 'error') ~= nil then
            return err(
                'RESULT_INVALID',
                'error.foundation.result_has_error_on_success',
                false
            )
        end
        return ok(value)
    end

    local error_value = raw_get(value, 'error')
    if type_value(error_value) ~= 'table'
        or get_metatable(error_value) ~= nil
        or type_value(raw_get(error_value, 'code')) ~= 'string'
        or raw_get(error_value, 'code') == ''
        or type_value(raw_get(error_value, 'message_key')) ~= 'string'
        or raw_get(error_value, 'message_key') == ''
        or type_value(raw_get(error_value, 'retryable')) ~= 'boolean'
    then
        return err('RESULT_INVALID', 'error.foundation.result_error_invalid', false)
    end

    return ok(value)
end
Result.validate = validate

return Result
