local Harness = require 'wzx.tests.harness'
local ErrorCodes = require 'wzx.domain.common.error_codes'
local Result = require 'wzx.domain.common.result'

local case = Harness.case
local assert = Harness.assert

return {
    case('success and error envelopes preserve contract fields', function()
        local success = Result.ok({ value = 7 })
        assert.equal(success.ok, true)
        assert.equal(success.value.value, 7)
        assert.is_nil(success.error)

        local failure = Result.err('INVALID_ARGUMENT', 'error.test.invalid', true, {
            field = 'sample',
        })
        assert.error_code(failure, 'INVALID_ARGUMENT')
        assert.equal(failure.error.message_key, 'error.test.invalid')
        assert.equal(failure.error.retryable, true)
        assert.equal(failure.error.details.field, 'sample')
    end),

    case('result validator accepts valid envelopes and rejects malformed ones', function()
        local valid_success = Result.ok(false)
        local validation = Result.validate(valid_success)
        assert.equal(validation.ok, true)
        assert.equal(validation.value, valid_success)

        local valid_error = Result.err('EXPECTED', 'error.expected', false)
        validation = Result.validate(valid_error)
        assert.equal(validation.ok, true)
        assert.equal(validation.value, valid_error)

        validation = Result.validate({ ok = true, error = {} })
        assert.error_code(validation, 'RESULT_INVALID')
        validation = Result.validate({ ok = false, error = { code = '' } })
        assert.error_code(validation, 'RESULT_INVALID')
        validation = Result.validate('not-a-result')
        assert.error_code(validation, 'RESULT_INVALID')
    end),

    case('foundation error codes are non-empty and unique', function()
        local seen = {}
        local count = 0
        local name
        local value
        for name, value in pairs(ErrorCodes) do
            assert.equal(type(name), 'string')
            assert.equal(type(value), 'string')
            assert.truthy(value ~= '')
            assert.falsy(seen[value], 'duplicate error code: ' .. value)
            seen[value] = true
            count = count + 1
        end
        assert.truthy(count >= 10, 'foundation error code registry is unexpectedly small')
        assert.equal(ErrorCodes.INVALID_ARGUMENT, 'INVALID_ARGUMENT')
        assert.equal(ErrorCodes.PLATFORM_UNAVAILABLE, 'PLATFORM_UNAVAILABLE')
    end),
}
