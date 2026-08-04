-- Pure Lua 5.1/5.4 SHA-256. Uses arithmetic bit operations for portability.

local Sha256 = {}
local math_floor = math.floor

local MOD = 4294967296
local HEX = '0123456789abcdef'

local K = {
    1116352408, 1899447441, 3049323471, 3921009573,
    961987163, 1508970993, 2453635748, 2870763221,
    3624381080, 310598401, 607225278, 1426881987,
    1925078388, 2162078206, 2614888103, 3248222580,
    3835390401, 4022224774, 264347078, 604807628,
    770255983, 1249150122, 1555081692, 1996064986,
    2554220882, 2821834349, 2952996808, 3210313671,
    3336571891, 3584528711, 113926993, 338241895,
    666307205, 773529912, 1294757372, 1396182291,
    1695183700, 1986661051, 2177026350, 2456956037,
    2730485921, 2820302411, 3259730800, 3345764771,
    3516065817, 3600352804, 4094571909, 275423344,
    430227734, 506948616, 659060556, 883997877,
    958139571, 1322822218, 1537002063, 1747873779,
    1955562222, 2024104815, 2227730452, 2361852424,
    2428436474, 2756734187, 3204031479, 3329325298,
}

local function normalize(value)
    return value % MOD
end

local function band(left, right)
    left = normalize(left)
    right = normalize(right)
    local result = 0
    local bit = 1
    local i
    for i = 1, 32 do
        local left_bit = left % 2
        local right_bit = right % 2
        if left_bit == 1 and right_bit == 1 then
            result = result + bit
        end
        left = (left - left_bit) / 2
        right = (right - right_bit) / 2
        bit = bit * 2
    end
    return result
end

local function bxor2(left, right)
    left = normalize(left)
    right = normalize(right)
    local result = 0
    local bit = 1
    local i
    for i = 1, 32 do
        local left_bit = left % 2
        local right_bit = right % 2
        if left_bit ~= right_bit then
            result = result + bit
        end
        left = (left - left_bit) / 2
        right = (right - right_bit) / 2
        bit = bit * 2
    end
    return result
end

local function bxor3(a, b, c)
    return bxor2(bxor2(a, b), c)
end

local function bnot(value)
    return 4294967295 - normalize(value)
end

local function rshift(value, count)
    return math_floor(normalize(value) / (2 ^ count))
end

local function lshift(value, count)
    return normalize(normalize(value) * (2 ^ count))
end

local function ror(value, count)
    return normalize(rshift(value, count) + lshift(value, 32 - count))
end

local function append_u32(bytes, value)
    bytes[#bytes + 1] = math_floor(value / 16777216) % 256
    bytes[#bytes + 1] = math_floor(value / 65536) % 256
    bytes[#bytes + 1] = math_floor(value / 256) % 256
    bytes[#bytes + 1] = value % 256
end

local function hex_u32(value)
    local chars = {}
    local index
    for index = 7, 0, -1 do
        local nibble = math_floor(value / (16 ^ index)) % 16
        chars[#chars + 1] = HEX:sub(nibble + 1, nibble + 1)
    end
    return table.concat(chars)
end

function Sha256.hex(message)
    if type(message) ~= 'string' then
        return nil, 'message must be a string'
    end

    local bytes = { message:byte(1, #message) }
    local bit_length = #message * 8
    bytes[#bytes + 1] = 128
    while (#bytes % 64) ~= 56 do
        bytes[#bytes + 1] = 0
    end
    append_u32(bytes, math_floor(bit_length / MOD))
    append_u32(bytes, bit_length % MOD)

    local h0 = 1779033703
    local h1 = 3144134277
    local h2 = 1013904242
    local h3 = 2773480762
    local h4 = 1359893119
    local h5 = 2600822924
    local h6 = 528734635
    local h7 = 1541459225

    local offset
    for offset = 1, #bytes, 64 do
        local words = {}
        local i
        for i = 0, 15 do
            local cursor = offset + (i * 4)
            words[i + 1] = bytes[cursor] * 16777216
                + bytes[cursor + 1] * 65536
                + bytes[cursor + 2] * 256
                + bytes[cursor + 3]
        end
        for i = 17, 64 do
            local x = words[i - 15]
            local y = words[i - 2]
            local sigma0 = bxor3(ror(x, 7), ror(x, 18), rshift(x, 3))
            local sigma1 = bxor3(ror(y, 17), ror(y, 19), rshift(y, 10))
            words[i] = normalize(words[i - 16] + sigma0 + words[i - 7] + sigma1)
        end

        local a = h0
        local b = h1
        local c = h2
        local d = h3
        local e = h4
        local f = h5
        local g = h6
        local h = h7

        for i = 1, 64 do
            local big_sigma1 = bxor3(ror(e, 6), ror(e, 11), ror(e, 25))
            local choose = bxor2(band(e, f), band(bnot(e), g))
            local temp1 = normalize(h + big_sigma1 + choose + K[i] + words[i])
            local big_sigma0 = bxor3(ror(a, 2), ror(a, 13), ror(a, 22))
            local majority = bxor3(band(a, b), band(a, c), band(b, c))
            local temp2 = normalize(big_sigma0 + majority)

            h = g
            g = f
            f = e
            e = normalize(d + temp1)
            d = c
            c = b
            b = a
            a = normalize(temp1 + temp2)
        end

        h0 = normalize(h0 + a)
        h1 = normalize(h1 + b)
        h2 = normalize(h2 + c)
        h3 = normalize(h3 + d)
        h4 = normalize(h4 + e)
        h5 = normalize(h5 + f)
        h6 = normalize(h6 + g)
        h7 = normalize(h7 + h)
    end

    return hex_u32(h0)
        .. hex_u32(h1)
        .. hex_u32(h2)
        .. hex_u32(h3)
        .. hex_u32(h4)
        .. hex_u32(h5)
        .. hex_u32(h6)
        .. hex_u32(h7)
end

return Sha256
