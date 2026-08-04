local DecimalInteger = {}
local math_floor = math.floor

local MAX_SAFE_INTEGER = 9007199254740991

function DecimalInteger.encode(value)
    if type(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
        or value < -MAX_SAFE_INTEGER
        or value > MAX_SAFE_INTEGER
    then
        return nil
    end
    if value == 0 then
        return '0'
    end

    if math.type ~= nil and math.type(value) == 'integer' then
        return tostring(value)
    end

    local negative = value < 0
    if negative then
        value = -value
    end
    local reversed = {}
    while value > 0 do
        local digit = value % 10
        reversed[#reversed + 1] = string.char(48 + digit)
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
    return table.concat(chars)
end

return DecimalInteger
