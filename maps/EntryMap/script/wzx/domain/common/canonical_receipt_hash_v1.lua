local Codec = require 'wzx.domain.common.canonical_value_codec_v1'
local Result = require 'wzx.domain.common.result'
local Sha256 = require 'wzx.domain.common.sha256'

local ReceiptHash = {}
local codec_encode = Codec.encode
local result_err = Result.err
local result_ok = Result.ok
local sha256_hex = Sha256.hex

local function derive(namespace, field_specs, values)
    local encoded = codec_encode(namespace, field_specs, values)
    if not encoded.ok then
        return encoded
    end

    local digest, hash_error = sha256_hex(encoded.value)
    if digest == nil then
        return result_err('CANONICAL_VALUE_INVALID', 'error.foundation.sha256_failed', false, {
            reason = hash_error,
        })
    end

    return result_ok({
        receipt_id = 'receipt_' .. namespace .. '_v1_' .. digest,
        digest = digest,
        canonical_bytes = encoded.value,
    })
end
ReceiptHash.derive = derive

function ReceiptHash.verify(receipt_id, namespace, field_specs, values)
    local derived = derive(namespace, field_specs, values)
    if not derived.ok then
        return derived
    end
    return result_ok(derived.value.receipt_id == receipt_id)
end

return ReceiptHash
