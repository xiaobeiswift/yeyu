-- Persist small boot intents across switch_level (Lua state is wiped).
-- File is under the game custom sandbox (relative path, no ..).

local BootIntentStore = {}

-- Written relative to process CWD (often Engine/Binaries/Win64). Also try project custom.
local FILE_NAME = 'wzx_boot_intent.lua'
local FILE_CANDIDATES = {
    'wzx_boot_intent.lua',
    '../../LocalData/yeyu/custom/wzx_boot_intent.lua',
    'custom/wzx_boot_intent.lua',
}

local function serialize_value(value, depth)
    depth = depth or 0
    if depth > 6 then
        return 'nil'
    end
    local t = type(value)
    if t == 'nil' then
        return 'nil'
    end
    if t == 'boolean' then
        return value and 'true' or 'false'
    end
    if t == 'number' then
        return tostring(value)
    end
    if t == 'string' then
        return string.format('%q', value)
    end
    if t ~= 'table' then
        return 'nil'
    end
    local parts = { '{' }
    local i
    local n = #value
    for i = 1, n do
        parts[#parts + 1] = serialize_value(value[i], depth + 1)
        parts[#parts + 1] = ','
    end
    for k, v in pairs(value) do
        if type(k) ~= 'number' or k < 1 or k > n or k ~= math.floor(k) then
            if type(k) == 'string' then
                parts[#parts + 1] = '['
                parts[#parts + 1] = string.format('%q', k)
                parts[#parts + 1] = ']='
            elseif type(k) == 'number' then
                parts[#parts + 1] = '['
                parts[#parts + 1] = tostring(k)
                parts[#parts + 1] = ']='
            else
                -- skip non-serializable keys
            end
            if type(k) == 'string' or type(k) == 'number' then
                parts[#parts + 1] = serialize_value(v, depth + 1)
                parts[#parts + 1] = ','
            end
        end
    end
    parts[#parts + 1] = '}'
    return table.concat(parts)
end

---Write intent table. Returns true on success.
---@param intent table
---@return boolean
function BootIntentStore.write(intent)
    if type(intent) ~= 'table' or type(io) ~= 'table' or type(io.open) ~= 'function' then
        return false
    end
    local body = 'return ' .. serialize_value(intent)
    local i
    for i = 1, #FILE_CANDIDATES do
        local path = FILE_CANDIDATES[i]
        local ok = pcall(function()
            local f = io.open(path, 'w')
            if not f then
                error('open_failed')
            end
            f:write(body)
            f:close()
        end)
        if ok then
            return true
        end
    end
    return false
end

---Read and clear intent. Returns table or nil.
---@return table|nil
function BootIntentStore.read_and_clear()
    if type(io) ~= 'table' or type(io.open) ~= 'function' then
        return nil
    end
    local intent = nil
    local used_path = nil
    local i
    for i = 1, #FILE_CANDIDATES do
        local path = FILE_CANDIDATES[i]
        pcall(function()
            local f = io.open(path, 'r')
            if not f then
                return
            end
            local src = f:read('*a')
            f:close()
            if type(src) ~= 'string' or src == '' then
                return
            end
            local chunk = loadstring or load
            if type(chunk) ~= 'function' then
                return
            end
            local loader = chunk(src)
            if type(loader) == 'function' then
                local ok, value = pcall(loader)
                if ok and type(value) == 'table' then
                    intent = value
                    used_path = path
                end
            end
        end)
        if intent then
            break
        end
    end
    if used_path then
        pcall(function()
            os.remove(used_path)
        end)
    end
    -- Best-effort clear all candidates
    for i = 1, #FILE_CANDIDATES do
        pcall(function()
            os.remove(FILE_CANDIDATES[i])
        end)
    end
    return intent
end

function BootIntentStore.file_name()
    return FILE_NAME
end

return BootIntentStore
