local Result = require 'wzx.domain.common.result'

local SYSTEM_ID = '12'

local DEFINITIONS = {
    {
        section_key = 'world_metadata',
        section_path = 'world_metadata',
        slot_id = 2,
        validator_id = 'validator_world_metadata_v1',
        codec_id = 'codec_world_save_bundle_v1',
    },
    {
        section_key = 'world_position',
        section_path = 'world_position',
        slot_id = 2,
        validator_id = 'validator_world_position_v1',
        codec_id = 'codec_world_save_bundle_v1',
    },
    {
        section_key = 'world_discovered_locations',
        section_path = 'world_discovered_locations',
        slot_id = 2,
        validator_id = 'validator_world_discovered_locations_v1',
        codec_id = 'codec_world_save_bundle_v1',
    },
    {
        section_key = 'world_flags',
        section_path = 'world_flags',
        slot_id = 2,
        validator_id = 'validator_world_flags_v1',
        codec_id = 'codec_world_save_bundle_v1',
    },
    {
        section_key = 'world_event_receipts',
        section_path = 'world_event_receipts',
        slot_id = 2,
        validator_id = 'validator_world_event_receipts_v1',
        codec_id = 'codec_world_save_bundle_v1',
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
            'error.world.section_registrar_context_invalid',
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
        error('world section registrar is read-only', 2)
    end,
    __metatable = false,
})
