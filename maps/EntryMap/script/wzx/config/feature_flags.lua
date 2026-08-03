local Result = require 'wzx.domain.common.result'
local ErrorCodes = require 'wzx.domain.common.error_codes'

local FeatureFlags = {}

local DEFINITIONS = {
    {
        key = 'cloud_save',
        capabilities = { 'cloud_save' },
    },
    {
        key = 'open_archive',
        capabilities = { 'open_archive' },
    },
    {
        key = 'server_refresh',
        capabilities = { 'server_clock' },
    },
    {
        key = 'arena',
        capabilities = {
            'checkpoint_readback',
            'open_archive',
            'rank_identity',
            'server_clock',
        },
    },
    {
        key = 'platform_store',
        capabilities = { 'store_recovery' },
    },
    {
        key = 'paid_gacha',
        capabilities = {
            'gacha_audit_export',
            'integer_cas',
            'integer_request_query',
            'random_pool_atomicity',
            'random_pool_request_query',
            'store_recovery',
        },
        compliance_gate = 'paid_gacha',
    },
}

local function definitions_by_key()
    local values = {}
    local index
    for index = 1, #DEFINITIONS do
        values[DEFINITIONS[index].key] = DEFINITIONS[index]
    end
    return values
end

local DEFINITION_BY_KEY = definitions_by_key()

function FeatureFlags.safe_defaults()
    local flags = {}
    local index
    for index = 1, #DEFINITIONS do
        flags[DEFINITIONS[index].key] = false
    end
    return flags
end

function FeatureFlags.validate(flags)
    if type(flags) ~= 'table' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.feature_flags_invalid',
            false
        )
    end

    local key
    local value
    for key, value in pairs(flags) do
        if DEFINITION_BY_KEY[key] == nil or type(value) ~= 'boolean' then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.feature_flag_invalid',
                false,
                { feature_key = key }
            )
        end
    end

    local index
    for index = 1, #DEFINITIONS do
        key = DEFINITIONS[index].key
        if type(flags[key]) ~= 'boolean' then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.feature_flag_missing',
                false,
                { feature_key = key }
            )
        end
    end
    return Result.ok(flags)
end

function FeatureFlags.resolve(release_flags, capabilities, compliance_gates)
    local release_result = FeatureFlags.validate(release_flags)
    if not release_result.ok then
        return release_result
    end
    if type(capabilities) ~= 'table' or type(compliance_gates) ~= 'table' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.feature_flag_inputs_invalid',
            false
        )
    end

    local resolved = FeatureFlags.safe_defaults()
    local index
    for index = 1, #DEFINITIONS do
        local definition = DEFINITIONS[index]
        local enabled = release_flags[definition.key]
        local capability_index
        for capability_index = 1, #definition.capabilities do
            local capability_key = definition.capabilities[capability_index]
            if capabilities[capability_key] ~= 'available' then
                enabled = false
            end
        end
        if definition.compliance_gate ~= nil
            and compliance_gates[definition.compliance_gate] ~= true
        then
            enabled = false
        end
        resolved[definition.key] = enabled
    end
    return Result.ok(resolved)
end

return FeatureFlags
