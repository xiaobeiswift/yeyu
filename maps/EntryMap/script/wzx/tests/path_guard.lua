local PathGuard = {}

local function normalize(path)
    if type(path) ~= 'string' then
        return nil
    end

    local value = path:gsub('\\', '/')
    value = value:gsub('/+', '/')

    if value:match('^%a:/$') == nil and value ~= '/' then
        value = value:gsub('/$', '')
    end
    return value
end

local function has_parent_segment(path)
    return path == '..'
        or path:match('^%.%./') ~= nil
        or path:match('/%.%./') ~= nil
        or path:match('/%.%.$') ~= nil
end

local function is_absolute(path)
    return path:match('^%a:/') ~= nil or path:sub(1, 1) == '/'
end

local function file_exists(path)
    local handle = io.open(path, 'rb')
    if handle == nil then
        return false
    end
    handle:close()
    return true
end

function PathGuard.normalize(path)
    return normalize(path)
end

function PathGuard.validate_project_root(path)
    local normalized = normalize(path)
    if normalized == nil or normalized == '' then
        return nil, 'project root must be a non-empty string'
    end
    if not is_absolute(normalized) then
        return nil, 'project root must be absolute'
    end
    if has_parent_segment(normalized) then
        return nil, 'project root must not contain parent traversal'
    end

    local required = {
        '/AGENTS.md',
        '/toolchain.lock',
        '/maps/EntryMap/script/wzx/tests/manifest.lua',
    }
    local index
    for index = 1, #required do
        if not file_exists(normalized .. required[index]) then
            return nil, 'project root marker is missing: ' .. required[index]
        end
    end
    return normalized
end

function PathGuard.validate_test_module(module_name)
    if type(module_name) ~= 'string'
        or module_name:match('^wzx%.tests%.test_[a-z0-9_]+$') == nil
    then
        return nil, 'test module is outside the explicit wzx.tests boundary'
    end
    return module_name
end

return PathGuard
