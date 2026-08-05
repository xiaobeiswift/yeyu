local Harness = require 'wzx.tests.harness'
local BootFlow = require 'wzx.application.boot.boot_flow'
local PlatformBackendStatus = require 'wzx.application.boot.platform_backend_status'
local OfficialCloudGate = require 'wzx.adapters.y3.official_cloud_gate'

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
    case('official cloud is blocked while unverified', function()
        local status = PlatformBackendStatus.official_cloud({
            feature_flags = { cloud_save = false },
            platform_adapters_verified = false,
            validation_status = 'UNVERIFIED',
        })
        assert.equal(status.available, false)
        assert.equal(status.status, 'UNVERIFIED')
        assert.equal(status.can_create, false)
        assert.equal(type(status.banner) == 'string', true)
    end),

    case('local backend is available for boot UI', function()
        local status = PlatformBackendStatus.local_dev()
        assert.equal(status.available, true)
        assert.equal(status.can_create, true)
    end),

    case('boot flow title to local slot enter', function()
        local bound = BootFlow.bind({})
        assert.equal(bound.ok, true, reason_of(bound))
        local flow = bound.value

        local view = flow:get_view()
        assert.equal(view.value.screen, 'TITLE')

        view = flow:start()
        assert.equal(view.value.screen, 'BACKEND')
        assert.equal(#view.value.backends, 2)

        view = flow:select_backend('local_dev')
        assert.equal(view.value.screen, 'SLOTS')
        assert.equal(#view.value.slots, 3)
        assert.equal(view.value.slots[1].empty, true)

        view = flow:create_slot(1)
        assert.equal(view.value.slots[1].empty, false)

        view = flow:confirm_enter()
        assert.equal(view.value.screen, 'ENTERED')
        assert.equal(view.value.entered, true)
        assert.equal(view.value.entered_payload.slot_index, 1)
    end),

    case('boot flow official path shows blocked screen', function()
        local bound = BootFlow.bind({
            platform_options = OfficialCloudGate.platform_options(),
        })
        local flow = bound.value
        flow:start()
        local view = flow:select_backend('official_cloud')
        assert.equal(view.ok, true, reason_of(view))
        assert.equal(view.value.screen, 'OFFICIAL_BLOCKED')
        assert.equal(type(view.value.message) == 'string', true)
    end),

    case('empty local slot cannot enter', function()
        local bound = BootFlow.bind({})
        local flow = bound.value
        flow:start()
        flow:select_backend('local_dev')
        local view = flow:confirm_enter()
        assert.equal(view.value.screen, 'SLOTS')
        assert.equal(view.value.entered, false)
    end),

    case('official gate creates unavailable save store', function()
        local store = OfficialCloudGate.create_save_store()
        assert.equal(store.ok, true, reason_of(store))
        local admitted = store.value:load_slot({
            player_ref = 'player_probe',
            slot_id = 1,
            context = {
                request_id = 'req_boot_probe_1',
                correlation_id = 'cor_boot_probe_1',
                attempt = 1,
            },
        }, function() end)
        assert.equal(admitted.ok, false)
        assert.equal(admitted.error.code, 'PLATFORM_UNAVAILABLE')
    end),
}
