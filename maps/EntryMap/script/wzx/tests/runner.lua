local function normalize_initial(path)
    if type(path) ~= 'string' then
        return nil
    end
    local value = path:gsub('\\', '/'):gsub('/+', '/')
    if value:match('^%a:/$') == nil and value ~= '/' then
        value = value:gsub('/$', '')
    end
    return value
end

local function initial_root_check(path)
    local normalized = normalize_initial(path)
    if normalized == nil or normalized == '' then
        return nil, 'missing --project-root'
    end
    if normalized:match('^%a:/') == nil and normalized:sub(1, 1) ~= '/' then
        return nil, '--project-root must be absolute'
    end
    if normalized == '..'
        or normalized:match('^%.%./')
        or normalized:match('/%.%./')
        or normalized:match('/%.%.$')
    then
        return nil, '--project-root must not contain parent traversal'
    end
    local marker = io.open(normalized .. '/maps/EntryMap/script/wzx/tests/path_guard.lua', 'rb')
    if marker == nil then
        return nil, '--project-root does not contain the WZX test boundary'
    end
    marker:close()
    return normalized
end

local function parse_arguments(arguments)
    local options = {
        repeat_count = 1,
        fail_fast = false,
        list = false,
    }
    local project_root
    local index = 1
    while index <= #arguments do
        local value = arguments[index]
        if value == '--project-root' then
            index = index + 1
            project_root = arguments[index]
        elseif value:match('^%-%-project%-root=') then
            project_root = value:sub(16)
        elseif value == '--match' then
            index = index + 1
            options.match = arguments[index]
        elseif value:match('^%-%-match=') then
            options.match = value:sub(9)
        elseif value == '--repeat' then
            index = index + 1
            options.repeat_count = tonumber(arguments[index])
        elseif value:match('^%-%-repeat=') then
            options.repeat_count = tonumber(value:sub(10))
        elseif value == '--fail-fast' then
            options.fail_fast = true
        elseif value == '--list' then
            options.list = true
        else
            return nil, nil, 'unknown or incomplete argument: ' .. tostring(value)
        end
        index = index + 1
    end

    if type(options.repeat_count) ~= 'number'
        or options.repeat_count ~= math.floor(options.repeat_count)
        or options.repeat_count < 1
        or options.repeat_count > 100
    then
        return nil, nil, '--repeat must be an integer between 1 and 100'
    end
    if options.match ~= nil and (type(options.match) ~= 'string' or options.match == '') then
        return nil, nil, '--match must be a non-empty string'
    end
    return project_root, options
end

local project_root_argument, options, argument_error = parse_arguments(arg)
if argument_error ~= nil then
    io.stderr:write('WZX test runner: ' .. argument_error .. '\n')
    os.exit(2)
end

local project_root, root_error = initial_root_check(project_root_argument)
if project_root == nil then
    io.stderr:write('WZX test runner: ' .. root_error .. '\n')
    os.exit(2)
end

local script_root = project_root .. '/maps/EntryMap/script'
package.path = script_root .. '/?.lua;' .. script_root .. '/?/init.lua'
package.cpath = ''

local PathGuard = require 'wzx.tests.path_guard'
local validated_root, validation_error = PathGuard.validate_project_root(project_root)
if validated_root == nil then
    io.stderr:write('WZX test runner: ' .. validation_error .. '\n')
    os.exit(2)
end

local Harness = require 'wzx.tests.harness'
local manifest = require 'wzx.tests.manifest'
local summary, run_error = Harness.run(manifest, options, PathGuard)
if summary == nil then
    io.stderr:write('WZX test runner: ' .. run_error .. '\n')
    os.exit(2)
end

if summary.listed then
    print(string.format('Listed %d test(s).', summary.selected))
    os.exit(0)
end

print(string.format(
    'WZX offline tests: %d passed, %d failed, %d selected, %d iteration(s).',
    summary.passed,
    summary.failed,
    summary.selected,
    summary.iterations
))

if summary.failed > 0 then
    os.exit(1)
end
os.exit(0)
