local Result = require 'wzx.domain.common.result'

local FoundationSections = {}

local CRITICAL_SECTIONS = {
    manifest = true,
    player_profile = true,
    world_position = true,
    save_recovery_transactions = true,
    arena_private = true,
    paid_transactions = true,
    paid_entitlement_cursor = true,
}

local DEFINITIONS = {
    {
        section_key = 'manifest',
        section_path = 'manifest',
        owner_system = '18',
        slot_id = 1,
        schema_version = 1,
    },
    {
        section_key = 'player_profile',
        section_path = 'player_profile',
        owner_system = '18',
        slot_id = 1,
        schema_version = 1,
    },
    {
        section_key = 'settings_profile',
        section_path = 'settings_profile',
        owner_system = '24',
        slot_id = 1,
        schema_version = 1,
    },
    {
        section_key = 'world_position',
        section_path = 'world_position',
        owner_system = '12',
        slot_id = 2,
        schema_version = 1,
    },
    {
        section_key = 'save_recovery_transactions',
        section_path = 'save_recovery_transactions',
        owner_system = '18',
        slot_id = 5,
        schema_version = 1,
    },
    {
        section_key = 'tutorial_progress',
        section_path = 'tutorial_progress',
        owner_system = '24',
        slot_id = 5,
        schema_version = 1,
    },
    {
        section_key = 'refresh_section',
        section_path = 'refresh_section',
        owner_system = '17',
        slot_id = 5,
        schema_version = 1,
    },
    {
        section_key = 'arena_private',
        section_path = 'arena_private',
        owner_system = '20',
        slot_id = 5,
        schema_version = 1,
    },
    {
        section_key = 'paid_transactions',
        section_path = 'paid_transactions',
        owner_system = '21',
        slot_id = 5,
        schema_version = 1,
    },
    {
        section_key = 'paid_entitlement_cursor',
        section_path = 'paid_entitlement_cursor',
        owner_system = '21',
        slot_id = 5,
        schema_version = 1,
    },
    {
        section_key = 'arena_public_snapshot',
        section_path = 'arena_public_snapshot',
        owner_system = '20',
        slot_id = 100,
        schema_version = 1,
    },
    {
        section_key = 'arena_rank_value',
        section_path = 'arena_rank_value',
        owner_system = '20',
        slot_id = 101,
        schema_version = 1,
    },
}

function FoundationSections.register_into(registry)
    if type(registry) ~= 'table' or type(registry.register) ~= 'function' then
        return Result.err(
            'INVALID_ARGUMENT',
            'error.foundation.section_registry_invalid',
            false
        )
    end

    local index
    for index = 1, #DEFINITIONS do
        local source = DEFINITIONS[index]
        local definition = {
            section_key = source.section_key,
            section_path = source.section_path,
            owner_system = source.owner_system,
            slot_id = source.slot_id,
            schema_version = source.schema_version,
            validator_id = 'validator_' .. source.section_key .. '_v1',
            codec_id = 'codec_' .. source.section_key .. '_v1',
        }
        if source.slot_id <= 5 then
            definition.storage_kind = 'TABLE_SECTION'
            definition.write_policy = CRITICAL_SECTIONS[source.section_key]
                and 'CRITICAL'
                or 'CHECKPOINT'
            definition.sensitive = true
            definition.public = false
        elseif source.slot_id == 100 then
            definition.storage_kind = 'PUBLIC_SECTION'
            definition.write_policy = 'DERIVED'
            definition.sensitive = false
            definition.public = true
        else
            definition.storage_kind = 'RANK_INTEGER'
            definition.write_policy = 'DERIVED'
            definition.sensitive = false
            definition.public = true
        end
        local registered = registry:register(definition)
        if not registered.ok then
            return registered
        end
    end
    return Result.ok(#DEFINITIONS)
end

return FoundationSections
