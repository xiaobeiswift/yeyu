local Harness = {}

local function render(value, depth, seen)
    local value_type = type(value)
    if value_type == 'string' then
        return string.format('%q', value)
    end
    if value_type ~= 'table' then
        return tostring(value)
    end
    if depth > 4 then
        return '<max-depth>'
    end
    if seen[value] then
        return '<cycle>'
    end
    seen[value] = true

    local entries = {}
    local key
    for key in pairs(value) do
        entries[#entries + 1] = key
    end
    table.sort(entries, function(left, right)
        local left_type = type(left)
        local right_type = type(right)
        if left_type == right_type then
            return tostring(left) < tostring(right)
        end
        return left_type < right_type
    end)

    local chunks = {}
    local index
    for index = 1, #entries do
        key = entries[index]
        chunks[#chunks + 1] = '[' .. render(key, depth + 1, seen) .. ']='
            .. render(value[key], depth + 1, seen)
    end
    seen[value] = nil
    return '{' .. table.concat(chunks, ',') .. '}'
end

local function values_equal(actual, expected, visited)
    if actual == expected then
        return true
    end
    if type(actual) ~= type(expected) or type(actual) ~= 'table' then
        return false
    end

    visited[actual] = visited[actual] or {}
    if visited[actual][expected] then
        return true
    end
    visited[actual][expected] = true

    local key
    for key in pairs(actual) do
        if not values_equal(actual[key], expected[key], visited) then
            return false
        end
    end
    for key in pairs(expected) do
        if actual[key] == nil and expected[key] ~= nil then
            return false
        end
    end
    return true
end

local Assert = {}

function Assert.equal(actual, expected, message)
    if actual ~= expected then
        error((message or 'values are not equal')
            .. '\nexpected: ' .. render(expected, 1, {})
            .. '\nactual:   ' .. render(actual, 1, {}), 2)
    end
end

function Assert.deep_equal(actual, expected, message)
    if not values_equal(actual, expected, {}) then
        error((message or 'tables are not deeply equal')
            .. '\nexpected: ' .. render(expected, 1, {})
            .. '\nactual:   ' .. render(actual, 1, {}), 2)
    end
end

function Assert.truthy(value, message)
    if not value then
        error(message or 'expected a truthy value', 2)
    end
end

function Assert.falsy(value, message)
    if value then
        error(message or 'expected a falsy value', 2)
    end
end

function Assert.is_nil(value, message)
    if value ~= nil then
        error((message or 'expected nil') .. ', got ' .. render(value, 1, {}), 2)
    end
end

function Assert.not_nil(value, message)
    if value == nil then
        error(message or 'expected a non-nil value', 2)
    end
end

function Assert.error_code(result, expected_code)
    Assert.equal(type(result), 'table', 'result must be a table')
    Assert.equal(result.ok, false, 'result must be an error')
    Assert.equal(type(result.error), 'table', 'error payload must be a table')
    Assert.equal(result.error.code, expected_code, 'unexpected error code')
end

function Assert.error_reason(result, expected_reason)
    Assert.equal(type(result), 'table', 'result must be a table')
    Assert.equal(result.ok, false, 'result must be an error')
    Assert.equal(type(result.error), 'table', 'error payload must be a table')
    Assert.equal(type(result.error.details), 'table', 'error details must be a table')
    Assert.equal(result.error.details.reason, expected_reason, 'unexpected error reason')
end

function Assert.throws(callback, expected_fragment)
    local ok, failure = pcall(callback)
    if ok then
        error('expected callback to raise an error', 2)
    end
    if expected_fragment ~= nil
        and tostring(failure):find(expected_fragment, 1, true) == nil
    then
        error('error did not contain expected text: ' .. expected_fragment
            .. '\nactual: ' .. tostring(failure), 2)
    end
end

function Assert.bytes_hex(value)
    Assert.equal(type(value), 'string', 'byte value must be a string')
    local chunks = {}
    local index
    for index = 1, #value do
        chunks[index] = string.format('%02x', value:byte(index))
    end
    return table.concat(chunks)
end

function Harness.case(name, callback)
    if type(name) ~= 'string' or name == '' or type(callback) ~= 'function' then
        error('invalid test case declaration', 2)
    end
    return {
        name = name,
        callback = callback,
    }
end

local function matches_filter(value, filter)
    if filter == nil or filter == '' then
        return true
    end
    return value:lower():find(filter:lower(), 1, true) ~= nil
end

local function assert_dense_array(value, label)
    if type(value) ~= 'table' then
        error(label .. ' must be an array')
    end
    local count = 0
    local key
    for key in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then
            error(label .. ' contains a non-array key: ' .. tostring(key))
        end
        count = count + 1
    end
    if count ~= #value then
        error(label .. ' must be dense')
    end
end

local function load_cases(manifest, path_guard)
    assert_dense_array(manifest, 'test manifest')
    local loaded = {}
    local seen_names = {}
    local module_index
    for module_index = 1, #manifest do
        local module_name = manifest[module_index]
        local valid_module, module_error = path_guard.validate_test_module(module_name)
        if valid_module == nil then
            error('invalid manifest entry #' .. tostring(module_index) .. ': ' .. module_error)
        end

        local cases = require(module_name)
        assert_dense_array(cases, 'test module ' .. module_name)
        local case_index
        for case_index = 1, #cases do
            local case = cases[case_index]
            if type(case) ~= 'table'
                or type(case.name) ~= 'string'
                or case.name == ''
                or type(case.callback) ~= 'function'
            then
                error('invalid test case #' .. tostring(case_index) .. ' in ' .. module_name)
            end
            local full_name = module_name .. ' :: ' .. case.name
            if seen_names[full_name] then
                error('duplicate test case: ' .. full_name)
            end
            seen_names[full_name] = true
            loaded[#loaded + 1] = {
                name = full_name,
                callback = case.callback,
            }
        end
    end
    return loaded
end

function Harness.run(manifest, options, path_guard)
    options = options or {}
    local cases = load_cases(manifest, path_guard)
    local selected = {}
    local index
    for index = 1, #cases do
        if matches_filter(cases[index].name, options.match) then
            selected[#selected + 1] = cases[index]
        end
    end

    if options.list then
        for index = 1, #selected do
            print(selected[index].name)
        end
        return {
            selected = #selected,
            passed = 0,
            failed = 0,
            listed = true,
        }
    end

    if #selected == 0 then
        return nil, 'no tests matched the requested filter'
    end

    local repeat_count = options.repeat_count or 1
    local passed = 0
    local failed = 0
    local iteration
    for iteration = 1, repeat_count do
        for index = 1, #selected do
            local case = selected[index]
            local ok, failure = xpcall(case.callback, debug.traceback)
            local label = case.name
            if repeat_count > 1 then
                label = '[' .. tostring(iteration) .. '/' .. tostring(repeat_count) .. '] ' .. label
            end
            if ok then
                passed = passed + 1
                print('[PASS] ' .. label)
            else
                failed = failed + 1
                print('[FAIL] ' .. label)
                print(tostring(failure))
                if options.fail_fast then
                    return {
                        selected = #selected,
                        passed = passed,
                        failed = failed,
                        iterations = iteration,
                    }
                end
            end
        end
    end

    return {
        selected = #selected,
        passed = passed,
        failed = failed,
        iterations = repeat_count,
    }
end

Harness.assert = Assert

return Harness
