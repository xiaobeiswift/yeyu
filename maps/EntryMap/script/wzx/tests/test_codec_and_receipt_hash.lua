local Harness = require 'wzx.tests.harness'
local Codec = require 'wzx.domain.common.canonical_value_codec_v1'
local ReceiptHash = require 'wzx.domain.common.canonical_receipt_hash_v1'

local case = Harness.case
local assert = Harness.assert

local SPECS = {
    { name = 'aid', type = Codec.TYPE_STRING },
    { name = 'season', type = Codec.TYPE_INTEGER },
    { name = 'won', type = Codec.TYPE_BOOLEAN },
}

local VALUES = {
    aid = 'A-01',
    season = 7,
    won = true,
}

local EXPECTED_BYTES_HEX = '575a582d524543454950542d563100000000056172656e6100000003'
    .. '000000036169645300000004412d303100000006736561736f6e490000000137'
    .. '00000003776f6e420000000131'
local EXPECTED_DIGEST = 'e43dd73f306005fd3a933468d1d96816e377571eb3038ec9f2f4bd09006218f4'

return {
    case('canonical codec matches the Foundation V1 golden byte vector', function()
        local encoded = Codec.encode('arena', SPECS, VALUES)
        assert.equal(encoded.ok, true)
        assert.equal(assert.bytes_hex(encoded.value), EXPECTED_BYTES_HEX)
    end),

    case('receipt hash matches independent SHA-256 golden vector', function()
        local derived = ReceiptHash.derive('arena', SPECS, VALUES)
        assert.equal(derived.ok, true)
        assert.equal(derived.value.digest, EXPECTED_DIGEST)
        assert.equal(
            derived.value.receipt_id,
            'receipt_arena_v1_' .. EXPECTED_DIGEST
        )
        assert.equal(assert.bytes_hex(derived.value.canonical_bytes), EXPECTED_BYTES_HEX)

        local verified = ReceiptHash.verify(derived.value.receipt_id, 'arena', SPECS, VALUES)
        assert.equal(verified.ok, true)
        assert.equal(verified.value, true)
        verified = ReceiptHash.verify('receipt_arena_v1_deadbeef', 'arena', SPECS, VALUES)
        assert.equal(verified.ok, true)
        assert.equal(verified.value, false)
    end),

    case('canonical codec rejects invalid schemas and ambiguous value maps', function()
        assert.error_code(Codec.encode('Arena', SPECS, VALUES), 'CANONICAL_SCHEMA_INVALID')
        assert.error_code(Codec.encode('arena', {
            [1] = SPECS[1],
            [3] = SPECS[3],
        }, VALUES), 'CANONICAL_SCHEMA_INVALID')
        assert.error_code(Codec.encode('arena', {
            SPECS[1],
            SPECS[1],
        }, VALUES), 'CANONICAL_SCHEMA_INVALID')

        assert.error_code(Codec.encode('arena', SPECS, {
            aid = 'A-01',
            season = 7,
        }), 'CANONICAL_VALUE_INVALID')
        assert.error_code(Codec.encode('arena', SPECS, {
            aid = 'A-01',
            season = 7,
            won = true,
            extra = 'not-allowed',
        }), 'CANONICAL_VALUE_INVALID')
    end),

    case('canonical codec validates scalar type and UTF-8 constraints', function()
        assert.error_code(Codec.encode('arena', SPECS, {
            aid = string.char(0xC0, 0x80),
            season = 7,
            won = true,
        }), 'CANONICAL_VALUE_INVALID')
        assert.error_code(Codec.encode('arena', SPECS, {
            aid = 'A-01',
            season = 7.5,
            won = true,
        }), 'CANONICAL_VALUE_INVALID')
        assert.error_code(Codec.encode('arena', SPECS, {
            aid = 'A-01',
            season = 9007199254740992,
            won = true,
        }), 'CANONICAL_VALUE_INVALID')
        assert.error_code(Codec.encode('arena', SPECS, {
            aid = 'A-01',
            season = 7,
            won = 1,
        }), 'CANONICAL_VALUE_INVALID')

        local chinese = Codec.encode('arena', SPECS, {
            aid = '雾州',
            season = -7,
            won = false,
        })
        assert.equal(chinese.ok, true)
    end),

    case('field order and namespace are digest-significant', function()
        local reordered = ReceiptHash.derive('arena', {
            SPECS[3],
            SPECS[2],
            SPECS[1],
        }, VALUES)
        local other_namespace = ReceiptHash.derive('arena_practice', SPECS, VALUES)
        assert.equal(reordered.ok, true)
        assert.equal(other_namespace.ok, true)
        assert.truthy(reordered.value.digest ~= EXPECTED_DIGEST)
        assert.truthy(other_namespace.value.digest ~= EXPECTED_DIGEST)
    end),
}
