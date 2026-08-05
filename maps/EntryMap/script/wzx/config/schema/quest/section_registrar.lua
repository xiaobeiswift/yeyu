local Result = require 'wzx.domain.common.result'

local SYSTEM_ID = '14'

local DEFINITIONS = {
    {
        section_key = 'quest_metadata',
        section_path = 'quest_metadata',
        slot_id = 2,
        validator_id = 'validator_quest_metadata_v1',
        codec_id = 'codec_quest_save_bundle_v1',
    },
    {
        section_key = 'quest_runs',
        section_path = 'quest_runs',
        slot_id = 2,
        validator_id = 'validator_quest_runs_v1',
        codec_id = 'codec_quest_save_bundle_v1',
    },
    {
        section_key = 'quest_objectives',
        section_path = 'quest_objectives',
        slot_id = 2,
        validator_id = 'validator_quest_objectives_v1',
        codec_id = 'codec_quest_save_bundle_v1',
    },
    {
        section_key = 'quest_event_receipts',
        section_path = 'quest_event_receipts',
        slot_id = 2,
        validator_id = 'validator_quest_event_receipts_v1',
        codec_id = 'codec_quest_save_bundle_v1',
    },
    {
        section_key = 'revealed_hidden_quests',
        section_path = 'revealed_hidden_quests',
        slot_id = 2,
        validator_id = 'validator_revealed_hidden_quests_v1',
        codec_id = 'codec_quest_save_bundle_v1',
    },
    {
        section_key = 'tracked_quest_runs',
        section_path = 'tracked_quest_runs',
        slot_id = 2,
        validator_id = 'validator_tracked_quest_runs_v1',
        codec_id = 'codec_quest_save_bundle_v1',
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
            'error.quest.section_registrar_context_invalid',
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
        error('quest section registrar is read-only', 2)
    end,
    __metatable = false,
})
