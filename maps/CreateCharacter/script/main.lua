-- CreateCharacter map entry.
-- Share EntryMap/script (y3 + wzx). Resolve absolute path via this file location
-- (process CWD is often Engine/Binaries/Win64 — relative package.path fails).

local function dirname(path)
    if type(path) ~= 'string' then
        return nil
    end
    return path:match('^(.*)[/\\][^/\\]+$')
end

local function join_path(a, b)
    if not a or a == '' then
        return b
    end
    local sep = package.config:sub(1, 1)
    if a:sub(-1) == '/' or a:sub(-1) == '\\' then
        return a .. b
    end
    return a .. sep .. b
end

local function add_path_root(root)
    if type(root) ~= 'string' or root == '' then
        return
    end
    local sep = package.config:sub(1, 1)
    local pattern1 = join_path(root, '?.lua')
    local pattern2 = join_path(root, '?' .. sep .. 'init.lua')
    package.path = pattern1 .. ';' .. pattern2 .. ';' .. package.path
end

do
    local src = debug.getinfo(1, 'S').source
    if type(src) == 'string' and src:sub(1, 1) == '@' then
        src = src:sub(2)
    end
    local here = dirname(src) -- .../CreateCharacter/script
    if here then
        -- .../maps/CreateCharacter/script → .../maps/EntryMap/script
        local entry = here:gsub('CreateCharacter([/\\])script', 'EntryMap%1script')
        if entry == here then
            -- fallback: sibling of CreateCharacter
            local maps_dir = dirname(dirname(here))
            entry = join_path(join_path(maps_dir, 'EntryMap'), 'script')
        end
        add_path_root(entry)
        print('[WZX] CreateCharacter package root candidate: ' .. tostring(entry))
    end
    -- CWD fallbacks (editor / rare layouts)
    add_path_root(join_path(join_path(join_path('..', '..'), 'LocalData'), join_path(join_path('yeyu', 'maps'), join_path('EntryMap', 'script'))))
end

local y3_ok, y3_err = pcall(function()
    require 'y3'
end)
if not y3_ok or type(y3) ~= 'table' then
    error('[WZX] CreateCharacter: require y3 failed: ' .. tostring(y3_err))
end

local is_debug = y3.game.is_debug_mode()
y3.config.log.toGame = false
y3.config.log.toDialog = false
if is_debug then
    y3.config.log.level = 'debug'
else
    y3.config.log.level = 'info'
end

do
    local consoleprint = rawget(_G, 'consoleprint')
    ---@diagnostic disable-next-line: lowercase-global
    function print(...)
        local n = select('#', ...)
        local parts = {}
        local i
        for i = 1, n do
            parts[i] = tostring(select(i, ...))
        end
        local message = table.concat(parts, '\t')
        if type(consoleprint) == 'function' then
            pcall(consoleprint, message)
        end
        pcall(function()
            if log and log.info then
                log.info(message)
            end
        end)
    end
end

print('[WZX] CreateCharacter map main ok')

local ok_entry, err_entry = pcall(function()
    local CreateCharacterEntry = require 'wzx.bootstrap.create_character_entry'
    local ok, detail = CreateCharacterEntry.start({})
    if not ok then
        print('[WZX] create character entry failed: ' .. tostring(detail))
    end
end)
if not ok_entry then
    print('[WZX] create character entry error: ' .. tostring(err_entry))
end
