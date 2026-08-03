local Codec = require 'wzx.domain.common.canonical_value_codec_v1'
local Result = require 'wzx.domain.common.result'
local Sha256 = require 'wzx.domain.common.sha256'

local ReceiptHash = {}

function ReceiptHash.derive(namespace, field_specs, values)
    local encoded = Codec.encode(namespace, field_specs, values)
    if not encoded.ok then
        return encoded
    end

    local digest, hash_error = Sha256.hex(encoded.value)
    if digest == nil then
        return Result.err('CANONICAL_VALUE_INVALID', 'error.foundation.sha256_failed', false, {
            reason = hash_error,
        })
    end

    return Result.ok({
        receipt_id = 'receipt_' .. namespace .. '_v1_' .. digest,
        digest = digest,
        canonical_bytes = encoded.value,
    })
end

function ReceiptHash.verify(receipt_id, namespace, field_specs, values)
    local derived = ReceiptHash.derive(namespace, field_specs, values)
    if not derived.ok then
        return derived
    end
    return Result.ok(derived.value.receipt_id == receipt_id)
end

return ReceiptHash
