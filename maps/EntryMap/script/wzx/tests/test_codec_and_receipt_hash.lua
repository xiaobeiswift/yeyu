local Harness = require 'wzx.tests.harness'
local Codec = require 'wzx.domain.common.canonical_value_codec_v1'
local ReceiptHash = require 'wzx.domain.common.canonical_receipt_hash_v1'
local DecimalInteger = require 'wzx.domain.common.decimal_integer'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local Sha256 = require 'wzx.domain.common.sha256'

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

    case('canonical codec rejects a hostile field spec array without invoking metamethods', function()
        local calls = {
            index = 0,
            pairs = 0,
            len = 0,
        }
        local hostile_specs = setmetatable({
            SPECS[1],
            SPECS[2],
            SPECS[3],
        }, {
            __index = function()
                calls.index = calls.index + 1
                return SPECS[1]
            end,
            __pairs = function(value)
                calls.pairs = calls.pairs + 1
                return next, value, nil
            end,
            __len = function()
                calls.len = calls.len + 1
                return 3
            end,
        })

        assert.error_code(Codec.encode('arena', hostile_specs, VALUES), 'CANONICAL_SCHEMA_INVALID')
        assert.equal(calls.index, 0)
        assert.equal(calls.pairs, 0)
        assert.equal(calls.len, 0)
    end),

    case('canonical codec rejects a hostile individual field spec without invoking metamethods', function()
        local calls = {
            index = 0,
            pairs = 0,
            len = 0,
        }
        local hostile_spec = setmetatable({
            name = 'aid',
        }, {
            __index = function(_, key)
                calls.index = calls.index + 1
                if key == 'type' then
                    return Codec.TYPE_STRING
                end
                return nil
            end,
            __pairs = function(value)
                calls.pairs = calls.pairs + 1
                return next, value, nil
            end,
            __len = function()
                calls.len = calls.len + 1
                return 2
            end,
        })

        assert.error_code(Codec.encode('arena', {
            hostile_spec,
            SPECS[2],
            SPECS[3],
        }, VALUES), 'CANONICAL_SCHEMA_INVALID')
        assert.equal(calls.index, 0)
        assert.equal(calls.pairs, 0)
        assert.equal(calls.len, 0)
    end),

    case('canonical codec rejects hostile values that synthesize required fields', function()
        local calls = {
            index = 0,
            pairs = 0,
            len = 0,
        }
        local hostile_values = setmetatable({
            aid = 'A-01',
            season = 7,
        }, {
            __index = function(_, key)
                calls.index = calls.index + 1
                if key == 'won' then
                    return true
                end
                return nil
            end,
            __pairs = function(value)
                calls.pairs = calls.pairs + 1
                return next, value, nil
            end,
            __len = function()
                calls.len = calls.len + 1
                return 3
            end,
        })

        assert.error_code(Codec.encode('arena', SPECS, hostile_values), 'CANONICAL_SCHEMA_INVALID')
        assert.equal(calls.index, 0)
        assert.equal(calls.pairs, 0)
        assert.equal(calls.len, 0)
    end),

    case('canonical codec rejects hostile values that hide an extra field', function()
        local calls = {
            index = 0,
            pairs = 0,
            len = 0,
        }
        local hostile_values = setmetatable({
            aid = 'A-01',
            extra = 'not-allowed',
            season = 7,
            won = true,
        }, {
            __index = function()
                calls.index = calls.index + 1
                return nil
            end,
            __pairs = function()
                calls.pairs = calls.pairs + 1
                local entries = {
                    { 'aid', 'A-01' },
                    { 'season', 7 },
                    { 'won', true },
                    { 'extra', 'not-allowed' },
                }
                local index = 0
                return function()
                    index = index + 1
                    local entry = entries[index]
                    if entry ~= nil then
                        return entry[1], entry[2]
                    end
                end
            end,
            __len = function()
                calls.len = calls.len + 1
                return 4
            end,
        })

        assert.error_code(Codec.encode('arena', SPECS, hostile_values), 'CANONICAL_SCHEMA_INVALID')
        assert.equal(calls.index, 0)
        assert.equal(calls.pairs, 0)
        assert.equal(calls.len, 0)
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

    case('canonical hash authorities retain their captured dependency chain', function()
        local encode = Codec.encode
        local derive = ReceiptHash.derive
        local originals = {
            codec_encode = Codec.encode,
            decimal_encode = DecimalInteger.encode,
            dense = Ordered.is_dense_array,
            keys = Ordered.sorted_string_keys,
            result_err = Result.err,
            result_ok = Result.ok,
            sha = Sha256.hex,
        }
        local function hostile()
            error('monkeypatched canonical dependency must not run')
        end
        Codec.encode = hostile
        DecimalInteger.encode = hostile
        Ordered.is_dense_array = hostile
        Ordered.sorted_string_keys = hostile
        Result.err = hostile
        Result.ok = hostile
        Sha256.hex = hostile

        local ok, raised = pcall(function()
            local encoded = encode('arena', SPECS, VALUES)
            assert.equal(encoded.ok, true)
            local hashed = derive('arena', SPECS, VALUES)
            assert.equal(hashed.ok, true)
            assert.equal(hashed.value.digest, EXPECTED_DIGEST)
        end)

        Codec.encode = originals.codec_encode
        DecimalInteger.encode = originals.decimal_encode
        Ordered.is_dense_array = originals.dense
        Ordered.sorted_string_keys = originals.keys
        Result.err = originals.result_err
        Result.ok = originals.result_ok
        Sha256.hex = originals.sha
        if not ok then
            error(raised)
        end
    end),
}
