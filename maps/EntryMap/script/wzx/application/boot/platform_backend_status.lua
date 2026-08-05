-- UI-facing platform backend status. Does not enable unverified features.
-- Screens bind to this contract so official cloud can plug in without UI rewrite.

local FeatureFlags = require 'wzx.config.feature_flags'

local PlatformBackendStatus = {}

local OFFICIAL = {
    backend_id = 'official_cloud',
    display_name = '官方云档',
    feature_flag = 'cloud_save',
    validation_doc = 'docs/service-validation/01-云存档.md',
    port = 'SaveStore',
}

local LOCAL = {
    backend_id = 'local_dev',
    display_name = '本地开发档',
    feature_flag = nil,
    validation_doc = nil,
    port = nil,
}

function PlatformBackendStatus.local_dev()
    return {
        backend_id = LOCAL.backend_id,
        display_name = LOCAL.display_name,
        available = true,
        status = 'AVAILABLE',
        feature_flag = nil,
        flag_value = true,
        can_list_slots = true,
        can_create = true,
        can_load = true,
        can_write = true,
        banner = '本地内存/开发槽 · 不进官方云 · 可随时清档',
        blocked_reason = nil,
        next_step = nil,
    }
end

function PlatformBackendStatus.official_cloud(options)
    options = options or {}
    local flags = options.feature_flags or FeatureFlags.safe_defaults()
    local flag_on = flags.cloud_save == true
    local adapters_verified = options.platform_adapters_verified == true
    local validation_status = options.validation_status or 'UNVERIFIED'

    -- Official path only becomes UI-available when BOTH flag and verification hold.
    local available = flag_on and adapters_verified and validation_status == 'AVAILABLE'
    local status = validation_status
    if not adapters_verified and validation_status == 'UNVERIFIED' then
        status = 'UNVERIFIED'
    end
    if flag_on and not adapters_verified then
        status = 'UNVERIFIED'
    end

    local banner
    local blocked_reason
    local next_step
    if available then
        banner = '官方云档已启用'
        blocked_reason = nil
        next_step = nil
    else
        banner = '官方云档：未开放（UI 已按平台契约预留）'
        if not adapters_verified then
            blocked_reason = 'ENGINE_SAVE_ADAPTER_NOT_VERIFIED'
            next_step = '完成 SaveStore engine adapter 与 ' .. OFFICIAL.validation_doc
        elseif validation_status ~= 'AVAILABLE' then
            blocked_reason = 'VALIDATION_' .. tostring(validation_status)
            next_step = '按验证报告补齐证据后将状态改为 AVAILABLE'
        elseif not flag_on then
            blocked_reason = 'FEATURE_FLAG_CLOUD_SAVE_OFF'
            next_step = '验证通过后开启 feature flag cloud_save'
        else
            blocked_reason = 'OFFICIAL_CLOUD_BLOCKED'
            next_step = OFFICIAL.validation_doc
        end
    end

    return {
        backend_id = OFFICIAL.backend_id,
        display_name = OFFICIAL.display_name,
        available = available,
        status = status,
        feature_flag = OFFICIAL.feature_flag,
        flag_value = flag_on,
        can_list_slots = available,
        can_create = available,
        can_load = available,
        can_write = available,
        banner = banner,
        blocked_reason = blocked_reason,
        next_step = next_step,
        validation_doc = OFFICIAL.validation_doc,
        port = OFFICIAL.port,
        platform_adapters_verified = adapters_verified,
    }
end

function PlatformBackendStatus.list_backends(options)
    return {
        PlatformBackendStatus.local_dev(),
        PlatformBackendStatus.official_cloud(options),
    }
end

return PlatformBackendStatus
