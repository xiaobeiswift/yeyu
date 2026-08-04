local Result = require 'wzx.domain.common.result'

local SYSTEM_ID = '01'

local DEFINITIONS = {
    {
        section_key = 'character_metadata',
        section_path = 'character_metadata',
        slot_id = 3,
        validator_id = 'validator_character_metadata_v1',
        codec_id = 'codec_character_save_bundle_v1',
    },
    {
        section_key = 'character_rows',
        section_path = 'character_rows',
        slot_id = 3,
        validator_id = 'validator_character_rows_v1',
        codec_id = 'codec_character_save_bundle_v1',
    },
    {
        section_key = 'character_talent_rows',
        section_path = 'character_talent_rows',
        slot_id = 3,
        validator_id = 'validator_character_talent_rows_v1',
        codec_id = 'codec_character_save_bundle_v1',
    },
    {
        section_key = 'character_operation_metadata',
        section_path = 'character_operation_metadata',
        slot_id = 5,
        validator_id = 'validator_character_operation_metadata_v1',
        codec_id = 'codec_character_receipt_bundle_v1',
    },
    {
        section_key = 'character_operation_receipts',
        section_path = 'character_operation_receipts',
        slot_id = 5,
        validator_id = 'validator_character_operation_receipts_v1',
        codec_id = 'codec_character_receipt_bundle_v1',
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
            'error.character.section_registrar_context_invalid',
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
        error('character section registrar is read-only', 2)
    end,
    __metatable = false,
})
