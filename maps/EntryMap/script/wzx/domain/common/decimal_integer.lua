local DecimalInteger = {}
local math_floor = math.floor
local math_huge = math.huge
local math_type = math.type
local string_char = string.char
local table_concat = table.concat
local tostring_value = tostring
local type_value = type

local MAX_SAFE_INTEGER = 9007199254740991

function DecimalInteger.encode(value)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math_huge
        or value == -math_huge
        or value ~= math_floor(value)
        or value < -MAX_SAFE_INTEGER
        or value > MAX_SAFE_INTEGER
    then
        return nil
    end
    if value == 0 then
        return '0'
    end

    if math_type ~= nil and math_type(value) == 'integer' then
        return tostring_value(value)
    end

    local negative = value < 0
    if negative then
        value = -value
    end
    local reversed = {}
    while value > 0 do
        local digit = value % 10
        reversed[#reversed + 1] = string_char(48 + digit)
        value = (value - digit) / 10
    end
    local chars = {}
    if negative then
        chars[1] = '-'
    end
    local index
    for index = #reversed, 1, -1 do
        chars[#chars + 1] = reversed[index]
    end
    return table_concat(chars)
end

return DecimalInteger
