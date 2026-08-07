local Harness = require 'wzx.tests.harness'
local Roster = require 'wzx.config.content.create_character_roster'

local case = Harness.case
local assert = Harness.assert

return {
    case('roster is non-empty ordered list', function()
        assert.equal(type(Roster) == 'table', true)
        assert.equal(#Roster >= 4, true)
    end),

    case('each entry has stable id and model_id', function()
        local seen = {}
        local i
        for i = 1, #Roster do
            local e = Roster[i]
            assert.equal(type(e.id) == 'string', true)
            assert.equal(e.id ~= '', true)
            assert.equal(seen[e.id] == nil, true)
            seen[e.id] = true
            assert.equal(type(e.catalog_name) == 'string', true)
            assert.equal(type(e.intro) == 'string', true)
            assert.equal(type(e.model_id) == 'number', true)
            assert.equal(type(e.stats) == 'table', true)
            assert.equal(type(e.stats.strength) == 'number', true)
            assert.equal(type(e.stats.constitution) == 'number', true)
            assert.equal(type(e.stats.agility) == 'number', true)
            assert.equal(type(e.stats.inner_power) == 'number', true)
        end
    end),

    case('known openers present', function()
        local by_id = {}
        local i
        for i = 1, #Roster do
            by_id[Roster[i].id] = Roster[i]
        end
        assert.equal(by_id.hero_mist ~= nil, true)
        assert.equal(by_id.hero_blade ~= nil, true)
        assert.equal(by_id.hero_mist.catalog_name, '雾中客')
    end),
}
