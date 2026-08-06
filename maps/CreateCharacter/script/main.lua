-- CreateCharacter map entry.
-- Shared game code lives in EntryMap/script (wzx + y3). Prepend that path.

do
    local entry_roots = {
        -- common when CWD is project / map script root
        'maps/EntryMap/script/?.lua',
        'maps/EntryMap/script/?/init.lua',
        '../EntryMap/script/?.lua',
        '../EntryMap/script/?/init.lua',
        '../../EntryMap/script/?.lua',
        '../../EntryMap/script/?/init.lua',
    }
    local i
    for i = 1, #entry_roots do
        package.path = entry_roots[i] .. ';' .. package.path
    end
end

-- Prefer y3 from EntryMap if local y3 is missing.
pcall(function()
    require 'y3'
end)
if type(y3) ~= 'table' then
    error('[WZX] CreateCharacter: cannot require y3 (check package.path → EntryMap/script)')
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

print('[WZX] CreateCharacter map main')

local CreateCharacterEntry = require 'wzx.bootstrap.create_character_entry'
local ok, detail = CreateCharacterEntry.start({})
if not ok then
    print('[WZX] create character entry failed: ' .. tostring(detail))
end
