-- Minimal, locale-independent UTF-8 validation for Lua 5.1/5.4.
-- A valid sequence must encode a Unicode scalar value: no overlong forms,
-- surrogate code points, or values above U+10FFFF are accepted.

local Utf8Text = {}
local math_floor = math.floor
local string_byte = string.byte

local function byte_in_range(value, minimum, maximum)
    return value ~= nil and value >= minimum and value <= maximum
end

local function continuation(value)
    return byte_in_range(value, 0x80, 0xBF)
end

local function invalid(reason, byte_index)
    return nil, reason, byte_index
end

local function codepoint_count(value)
    if type(value) ~= 'string' then
        return invalid('STRING_REQUIRED', 1)
    end

    local byte_length = #value
    local byte_index = 1
    local codepoint_count = 0
    while byte_index <= byte_length do
        local first = string_byte(value, byte_index)
        local sequence_length
        local second_minimum = 0x80
        local second_maximum = 0xBF

        if first <= 0x7F then
            sequence_length = 1
        elseif byte_in_range(first, 0xC2, 0xDF) then
            sequence_length = 2
        elseif first == 0xE0 then
            sequence_length = 3
            second_minimum = 0xA0
        elseif byte_in_range(first, 0xE1, 0xEC)
            or byte_in_range(first, 0xEE, 0xEF)
        then
            sequence_length = 3
        elseif first == 0xED then
            sequence_length = 3
            second_maximum = 0x9F
        elseif first == 0xF0 then
            sequence_length = 4
            second_minimum = 0x90
        elseif byte_in_range(first, 0xF1, 0xF3) then
            sequence_length = 4
        elseif first == 0xF4 then
            sequence_length = 4
            second_maximum = 0x8F
        else
            return invalid('INVALID_LEADING_BYTE', byte_index)
        end

        if byte_index + sequence_length - 1 > byte_length then
            return invalid('TRUNCATED_SEQUENCE', byte_index)
        end
        if sequence_length > 1 then
            local second = string_byte(value, byte_index + 1)
            if not byte_in_range(second, second_minimum, second_maximum) then
                return invalid('INVALID_SECOND_BYTE', byte_index + 1)
            end
        end

        local offset
        for offset = 2, sequence_length - 1 do
            if not continuation(string_byte(value, byte_index + offset)) then
                return invalid('INVALID_CONTINUATION_BYTE', byte_index + offset)
            end
        end

        codepoint_count = codepoint_count + 1
        byte_index = byte_index + sequence_length
    end

    return codepoint_count
end
Utf8Text.codepoint_count = codepoint_count

function Utf8Text.is_valid(value, maximum_codepoints)
    local count, reason, byte_index = codepoint_count(value)
    if count == nil then
        return false, reason, byte_index
    end
    if maximum_codepoints ~= nil then
        if type(maximum_codepoints) ~= 'number'
            or maximum_codepoints ~= math_floor(maximum_codepoints)
            or maximum_codepoints < 0
        then
            return false, 'MAXIMUM_CODEPOINTS_INVALID'
        end
        if count > maximum_codepoints then
            return false, 'CODEPOINT_LIMIT_EXCEEDED', count
        end
    end
    return true, count
end

return Utf8Text
