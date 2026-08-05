local Result = require 'wzx.domain.common.result'

local SYSTEM_ID = '08'

local DEFINITIONS = {
    {
        section_key = 'equipment_metadata',
        section_path = 'equipment_metadata',
        slot_id = 4,
        validator_id = 'validator_equipment_metadata_v1',
        codec_id = 'codec_equipment_save_bundle_v1',
    },
    {
        section_key = 'equipment_instance_rows',
        section_path = 'equipment_instance_rows',
        slot_id = 4,
        validator_id = 'validator_equipment_instance_rows_v1',
        codec_id = 'codec_equipment_save_bundle_v1',
    },
    {
        section_key = 'equipment_affix_rows',
        section_path = 'equipment_affix_rows',
        slot_id = 4,
        validator_id = 'validator_equipment_affix_rows_v1',
        codec_id = 'codec_equipment_save_bundle_v1',
    },
    {
        section_key = 'equipment_locked_affix_rows',
        section_path = 'equipment_locked_affix_rows',
        slot_id = 4,
        validator_id = 'validator_equipment_locked_affix_rows_v1',
        codec_id = 'codec_equipment_save_bundle_v1',
    },
    {
        section_key = 'character_loadout_rows',
        section_path = 'character_loadout_rows',
        slot_id = 4,
        validator_id = 'validator_character_loadout_rows_v1',
        codec_id = 'codec_equipment_save_bundle_v1',
    },
    {
        section_key = 'equipment_tombstone_rows',
        section_path = 'equipment_tombstone_rows',
        slot_id = 4,
        validator_id = 'validator_equipment_tombstone_rows_v1',
        codec_id = 'codec_equipment_save_bundle_v1',
    },
    {
        section_key = 'equipment_operation_metadata',
        section_path = 'equipment_operation_metadata',
        slot_id = 5,
        validator_id = 'validator_equipment_operation_metadata_v1',
        codec_id = 'codec_equipment_receipt_bundle_v1',
    },
    {
        section_key = 'equipment_operation_receipts',
        section_path = 'equipment_operation_receipts',
        slot_id = 5,
        validator_id = 'validator_equipment_operation_receipts_v1',
        codec_id = 'codec_equipment_receipt_bundle_v1',
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
            'error.equipment.section_registrar_context_invalid',
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
        error('equipment section registrar is read-only', 2)
    end,
    __metatable = false,
})
