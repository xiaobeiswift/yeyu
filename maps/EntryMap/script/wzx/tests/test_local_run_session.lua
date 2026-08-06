local Harness = require 'wzx.tests.harness'
local LocalRunSession = require 'wzx.application.boot.local_run_session'
local BootFlow = require 'wzx.application.boot.boot_flow'

local case = Harness.case
local assert = Harness.assert

local function reason_of(result)
    if result.ok then
        return 'ok'
    end
    local details = result.error and result.error.details
    if details and details.reason then
        return tostring(details.reason)
    end
    if result.error and result.error.code then
        return tostring(result.error.code)
    end
    return 'unknown'
end

return {
    case('start rejects bad payload', function()
        LocalRunSession.stop()
        local r = LocalRunSession.start(nil)
        assert.equal(r.ok, false)
        r = LocalRunSession.start({ slot_index = 0 })
        assert.equal(r.ok, false)
        r = LocalRunSession.start({ backend_id = 'official_cloud', slot_index = 1 })
        assert.equal(r.ok, false)
    end),

    case('start from boot enter payload', function()
        LocalRunSession.stop()
        local bound = BootFlow.bind({})
        local flow = bound.value
        flow:open_local_slots()
        flow:create_slot(2)
        local entered = flow:confirm_enter()
        assert.equal(entered.value.entered, true, reason_of(entered))

        local started = LocalRunSession.start(entered.value.entered_payload)
        assert.equal(started.ok, true, reason_of(started))
        assert.equal(started.value.slot_index, 2)
        assert.equal(started.value.started, true)
        assert.equal(LocalRunSession.is_active(), true)

        local view = LocalRunSession.get_view()
        assert.equal(view.ok, true)
        assert.equal(view.value.active, true)
        assert.equal(view.value.slot_index, 2)
        assert.equal(type(view.value.title) == 'string', true)
        assert.equal(type(view.value.tip) == 'string', true)

        LocalRunSession.stop()
        assert.equal(LocalRunSession.is_active(), false)
        view = LocalRunSession.get_view()
        assert.equal(view.value.active, false)
    end),
}
