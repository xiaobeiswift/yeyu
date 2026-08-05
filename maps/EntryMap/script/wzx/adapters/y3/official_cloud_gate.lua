-- Gate for official cloud UI/backend. Does not claim platform availability.
-- When verification lands, flip options here / feature flags — BootFlow UI stays the same.

local FeatureFlags = require 'wzx.config.feature_flags'
local UnavailableService = require 'wzx.adapters.unavailable.service'
local SaveStore = require 'wzx.application.ports.save_store'
local Result = require 'wzx.domain.common.result'

local OfficialCloudGate = {}

---Snapshot used by BootFlow / UI.
function OfficialCloudGate.platform_options()
    return {
        feature_flags = FeatureFlags.safe_defaults(),
        -- Foundation runtime currently reports false; keep in sync intentionally.
        platform_adapters_verified = false,
        validation_status = 'UNVERIFIED',
    }
end

---SaveStore for official path: always unavailable until verification + adapter exist.
function OfficialCloudGate.create_save_store()
    local options = OfficialCloudGate.platform_options()
    if options.platform_adapters_verified
        and options.feature_flags.cloud_save == true
        and options.validation_status == 'AVAILABLE'
    then
        return Result.err(
            'BOOTSTRAP_INVALID',
            'error.boot.official_adapter_missing',
            false,
            {
                reason = 'VERIFIED_BUT_ENGINE_SAVE_ADAPTER_NOT_IMPLEMENTED',
                hint = 'Implement wzx.adapters.y3.save_store and wire here',
            }
        )
    end
    return UnavailableService.create(
        SaveStore,
        'CLOUD_SAVE_UNVERIFIED_UI_RESERVED'
    )
end

---Probe callable from UI "检测官方存档" button. Safe: never enables write path.
function OfficialCloudGate.probe_for_ui()
    local options = OfficialCloudGate.platform_options()
    local store = OfficialCloudGate.create_save_store()
    local probe = {
        options = options,
        save_store_ok = store.ok,
        can_enter_official = false,
        detail = nil,
    }
    if not store.ok then
        probe.detail = 'save_store_create_failed'
        return Result.ok(probe)
    end
    -- Admission-style call: unavailable port returns error without callback requirement issues
    local result = store.value:load_slot({
        player_ref = 'player_probe',
        slot_id = 1,
        context = {
            request_id = 'req_boot_probe_1',
            correlation_id = 'cor_boot_probe_1',
            attempt = 1,
        },
    }, function() end)
    probe.detail = result
    probe.can_enter_official = false
    if result and result.ok == false and result.error and result.error.code then
        probe.platform_code = result.error.code
    end
    return Result.ok(probe)
end

return OfficialCloudGate
