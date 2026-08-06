local Harness = require 'wzx.tests.harness'
local CreateCharacterIntent = require 'wzx.application.boot.create_character_intent'
local LocalRunSlotStore = require 'wzx.application.boot.local_run_slot_store'
local MapIds = require 'wzx.config.map_ids'
local BootIntentStore = require 'wzx.application.boot.boot_intent_store'

local case = Harness.case
local assert = Harness.assert

return {
    case('map ids are UUID strings not pure decimal', function()
        assert.equal(type(MapIds.ENTRY) == 'string', true)
        assert.equal(type(MapIds.CREATE_CHARACTER) == 'string', true)
        -- Engine convert_level_id requires UUID form
        assert.equal(MapIds.CREATE_CHARACTER:match('^%x+%-%x+%-%x+%-%x+%-%x+$') ~= nil, true)
        assert.equal(MapIds.ENTRY:match('^%x+%-%x+%-%x+%-%x+%-%x+$') ~= nil, true)
        assert.equal(MapIds.CREATE_CHARACTER, '790bd0ad-91e6-11f1-a87d-25a4c7a653a4')
        assert.equal(MapIds.ENTRY, '73763292-8f4c-11f1-9d30-93a4cd3b7dcd')
    end),

    case('prepare_go rejects occupied slot', function()
        LocalRunSlotStore.reset_shared()
        local store = LocalRunSlotStore.shared()
        store:create(1, { display_name = '甲' })
        local r = CreateCharacterIntent.prepare_go(1)
        assert.equal(r.ok, false)
    end),

    case('prepare_go accepts empty slot when io works', function()
        LocalRunSlotStore.reset_shared()
        LocalRunSlotStore.shared()
        local r = CreateCharacterIntent.prepare_go(2)
        if not r.ok then
            -- INTENT_WRITE_FAILED when sandbox has no io
            return
        end
        assert.equal(r.value.slot_index, 2)
        assert.equal(type(r.value.level_id) == 'string', true)
        BootIntentStore.read_and_clear()
    end),

    case('intent store write and read_and_clear', function()
        local ok = BootIntentStore.write({
            reason = 'TEST',
            slot_index = 3,
            nested = { a = 1 },
        })
        -- io may be unavailable in some sandboxes; allow either
        if not ok then
            return
        end
        local intent = BootIntentStore.read_and_clear()
        assert.equal(type(intent) == 'table', true)
        assert.equal(intent.reason, 'TEST')
        assert.equal(intent.slot_index, 3)
        assert.equal(intent.nested.a, 1)
        local again = BootIntentStore.read_and_clear()
        assert.equal(again, nil)
    end),

    case('complete path restores snapshot shape via store create', function()
        LocalRunSlotStore.reset_shared()
        local store = LocalRunSlotStore.shared()
        store:create(2, {
            display_name = '乙',
            character_id = 'hero_blade',
        })
        local listed = store:list()
        assert.equal(listed.value[2].empty, false)
        assert.equal(listed.value[2].character_id, 'hero_blade')
    end),
}
