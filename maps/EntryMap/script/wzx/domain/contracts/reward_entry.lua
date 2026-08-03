local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Validation = require 'wzx.domain.contracts.validation'

local RewardEntry = {}

local CONTRACT = 'RewardEntryV1'
local FIELDS = {
    entry_type = true,
    target_id = true,
    quantity = true,
    target_character_id = true,
    metadata = true,
    entry_order = true,
}
local TYPES = {
    CURRENCY = true,
    ITEM = true,
    EQUIPMENT = true,
    CHARACTER_XP = true,
    MARTIAL_XP = true,
    AFFINITY = true,
    UNLOCK_FLAG = true,
}
local CHARACTER_TARGETED = {
    CHARACTER_XP = true,
    MARTIAL_XP = true,
    AFFINITY = true,
}
local TARGET_PREFIXES = {
    CURRENCY = 'currency_',
    ITEM = 'item_',
    EQUIPMENT = 'equip_',
    CHARACTER_XP = 'char_',
    MARTIAL_XP = 'martial_',
    AFFINITY = 'char_',
    UNLOCK_FLAG = 'flag_',
}

local function validate_target_id(entry_type, target_id)
    local prefix = TARGET_PREFIXES[entry_type]
    if prefix == nil then
        return Validation.invalid(CONTRACT, 'target_id', 'ENTRY_TYPE_REQUIRED_FOR_TARGET')
    end
    local validated = RuntimeId.validate_content(target_id, prefix, 'target_id')
    if not validated.ok then
        return Validation.invalid(CONTRACT, 'target_id', 'TARGET_ID_PREFIX_INVALID', {
            expected_prefix = prefix,
        })
    end
    return nil
end

function RewardEntry.validate(value)
    local err = Validation.no_unknown_fields(CONTRACT, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.enum(CONTRACT, 'entry_type', value.entry_type, TYPES),
        validate_target_id(value.entry_type, value.target_id),
        Validation.integer(CONTRACT, 'quantity', value.quantity, 1),
        Validation.identifier(CONTRACT, 'target_character_id', value.target_character_id, 'char_', true),
        Validation.flat_map(CONTRACT, 'metadata', value.metadata, 'scalar'),
        Validation.integer(CONTRACT, 'entry_order', value.entry_order, 1)
    )
    if err ~= nil then
        return err
    end
    if CHARACTER_TARGETED[value.entry_type] and value.target_character_id == nil then
        return Validation.invalid(CONTRACT, 'target_character_id', 'CHARACTER_TARGET_REQUIRED')
    end
    if value.entry_type == 'UNLOCK_FLAG'
        and (type(value.metadata.owner_type) ~= 'string' or value.metadata.owner_type == '')
    then
        return Validation.invalid(CONTRACT, 'metadata.owner_type', 'OWNER_TYPE_REQUIRED')
    end
    return Result.ok(value)
end

return RewardEntry
