local Result = require 'wzx.domain.common.result'

local SYSTEM_ID = '10'

local DEFINITIONS = {
    {
        section_key = 'economy_metadata',
        section_path = 'economy_metadata',
        slot_id = 4,
        validator_id = 'validator_economy_metadata_v1',
        codec_id = 'codec_economy_save_bundle_v1',
    },
    {
        section_key = 'currency_balance_rows',
        section_path = 'currency_balance_rows',
        slot_id = 4,
        validator_id = 'validator_currency_balance_rows_v1',
        codec_id = 'codec_economy_save_bundle_v1',
    },
    {
        section_key = 'economy_receipt_metadata',
        section_path = 'economy_receipt_metadata',
        slot_id = 5,
        validator_id = 'validator_economy_receipt_metadata_v1',
        codec_id = 'codec_economy_receipt_bundle_v1',
    },
    {
        section_key = 'economy_reward_receipts',
        section_path = 'economy_reward_receipts',
        slot_id = 5,
        validator_id = 'validator_economy_reward_receipts_v1',
        codec_id = 'codec_economy_receipt_bundle_v1',
    },
    {
        section_key = 'economy_source_occurrences',
        section_path = 'economy_source_occurrences',
        slot_id = 5,
        validator_id = 'validator_economy_source_occurrences_v1',
        codec_id = 'codec_economy_receipt_bundle_v1',
    },
}

local function definition_copy(source)
    return {
        section_key = source.section_key,
        section_path = source.section_path,
        owner_system = SYSTEM_ID,
        slot_id = source.slot_id,
        schema_version = 1,
        storage_kind = 'TABLE_SECTION',
        write_policy = 'CRITICAL',
        validator_id = source.validator_id,
        codec_id = source.codec_id,
        sensitive = true,
        public = false,
    }
end

local function register(context)
    if type(context) ~= 'table'
        or context.system_id ~= SYSTEM_ID
        or type(context.section_owners) ~= 'table'
        or type(context.section_owners.register) ~= 'function'
    then
        return Result.err(
            'SCHEMA_VALIDATION_FAILED',
            'error.economy.section_registrar_context_invalid',
            false
        )
    end

    local index
    for index = 1, #DEFINITIONS do
        local registered = context.section_owners:register(
            definition_copy(DEFINITIONS[index])
        )
        if not registered.ok then
            return registered
        end
    end
    return Result.ok(#DEFINITIONS)
end

local methods = {
    system_id = SYSTEM_ID,
    register = register,
}

return setmetatable({}, {
    __index = methods,
    __newindex = function()
        error('economy section registrar is read-only', 2)
    end,
    __metatable = false,
})
