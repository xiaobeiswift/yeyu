local Harness = require 'wzx.tests.harness'
local Sha256 = require 'wzx.domain.common.sha256'

local case = Harness.case
local assert = Harness.assert

return {
    case('SHA-256 matches published short-message vectors', function()
        assert.equal(
            Sha256.hex(''),
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        )
        assert.equal(
            Sha256.hex('abc'),
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        )
        assert.equal(
            Sha256.hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
            '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1'
        )
    end),

    case('SHA-256 handles embedded zero bytes and multiple blocks', function()
        assert.equal(
            Sha256.hex('WZX\0foundation\0' .. string.rep('x', 80)),
            'a63a2da399df8e0133008745721b9d176e73dc79be114e5f51642dd2814ed6dc'
        )
    end),

    case('SHA-256 rejects non-string input without throwing', function()
        local digest, failure = Sha256.hex({})
        assert.is_nil(digest)
        assert.equal(failure, 'message must be a string')
    end),
}
