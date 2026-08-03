local Harness = require 'wzx.tests.harness'
local PathGuard = require 'wzx.tests.path_guard'
local Manifest = require 'wzx.tests.manifest'

local case = Harness.case
local assert = Harness.assert

return {
    case('manifest is dense, explicit, unique, and boundary-safe', function()
        local seen = {}
        local count = 0
        local key
        for key in pairs(Manifest) do
            assert.equal(type(key), 'number')
            assert.truthy(key >= 1 and key == math.floor(key))
            count = count + 1
        end
        assert.equal(count, #Manifest)

        local index
        for index = 1, #Manifest do
            local module_name = Manifest[index]
            local validated, failure = PathGuard.validate_test_module(module_name)
            assert.equal(validated, module_name, failure)
            assert.falsy(seen[module_name], 'duplicate manifest entry: ' .. module_name)
            seen[module_name] = true
        end
    end),

    case('path guard rejects traversal and modules outside test boundary', function()
        local validated
        validated = PathGuard.validate_project_root('../outside')
        assert.is_nil(validated)
        validated = PathGuard.validate_project_root('C:/project/../outside')
        assert.is_nil(validated)
        validated = PathGuard.validate_test_module('wzx.domain.common.result')
        assert.is_nil(validated)
        validated = PathGuard.validate_test_module('wzx.tests.helper')
        assert.is_nil(validated)
        validated = PathGuard.validate_test_module('wzx.tests.test_safe_name')
        assert.equal(validated, 'wzx.tests.test_safe_name')
    end),

    case('path normalization is platform-neutral', function()
        assert.equal(PathGuard.normalize('C:\\repo\\maps\\'), 'C:/repo/maps')
        assert.equal(PathGuard.normalize('/repo//maps/'), '/repo/maps')
        assert.is_nil(PathGuard.normalize(false))
    end),
}
