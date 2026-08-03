local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local DecimalInteger = require 'wzx.domain.common.decimal_integer'

local DeriveSeed = {}

local MODULUS = 2147483647
local MAX_SEED = MODULUS - 1
local MULTIPLIER = 48271
local NAMESPACES = {
    combat = true,
    reward = true,
}

function DeriveSeed.derive(root_seed, namespace, context_id)
    if not TableShape.is_integer(root_seed, 1, MAX_SEED) then
        return Result.err('INVALID_ARGUMENT', 'error.foundation.root_seed_invalid', false, {
            minimum = 1,
            maximum = MAX_SEED,
        })
    end
    if not NAMESPACES[namespace] then
        return Result.err('INVALID_ARGUMENT', 'error.foundation.seed_namespace_invalid', false)
    end
    local context_check = RuntimeId.validate_derived(context_id, 'context_id')
    if not context_check.ok then
        return context_check
    end

    local input = DecimalInteger.encode(root_seed)
        .. '\0'
        .. namespace
        .. '\0'
        .. context_id
    local state = root_seed
    local index
    for index = 1, #input do
        state = (state * MULTIPLIER + input:byte(index) + 1) % MODULUS
    end
    if state == 0 then
        state = 1
    end

    return Result.ok({
        seed = state,
        algorithm_version = 1,
    })
end

return DeriveSeed
