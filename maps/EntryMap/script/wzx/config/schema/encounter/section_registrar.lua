local Result = require 'wzx.domain.common.result'

local SYSTEM_ID = '07'

local DEFINITIONS = {
    {
        section_key = 'encounter_metadata',
        section_path = 'encounter_metadata',
        slot_id = 2,
        validator_id = 'validator_encounter_metadata_v1',
        codec_id = 'codec_encounter_save_bundle_v1',
    },
    {
        section_key = 'encounter_progress_rows',
        section_path = 'encounter_progress_rows',
        slot_id = 2,
        validator_id = 'validator_encounter_progress_rows_v1',
        codec_id = 'codec_encounter_save_bundle_v1',
    },
    {
        section_key = 'encounter_settlement_rows',
        section_path = 'encounter_settlement_rows',
        slot_id = 2,
        validator_id = 'validator_encounter_settlement_rows_v1',
        codec_id = 'codec_encounter_save_bundle_v1',
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
            'error.encounter.section_registrar_context_invalid',
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
        error('encounter section registrar is read-only', 2)
    end,
    __metatable = false,
})
