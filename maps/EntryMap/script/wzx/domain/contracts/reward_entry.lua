local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Validation = require 'wzx.domain.contracts.validation'

local RewardEntry = {}
local raw_get = rawget
local type_value = type
local result_ok = Result.ok
local validate_content = RuntimeId.validate_content
local validation_enum = Validation.enum
local validation_first = Validation.first
local validation_flat_map = Validation.flat_map
local validation_identifier = Validation.identifier
local validation_integer = Validation.integer
local validation_invalid = Validation.invalid
local validation_no_unknown_fields = Validation.no_unknown_fields

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
local SAME_CHARACTER_TARGET = {
    CHARACTER_XP = true,
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
    local prefix = raw_get(TARGET_PREFIXES, entry_type)
    if prefix == nil then
        return validation_invalid(CONTRACT, 'target_id', 'ENTRY_TYPE_REQUIRED_FOR_TARGET')
    end
    local validated = validate_content(target_id, prefix, 'target_id')
    if not validated.ok then
        return validation_invalid(CONTRACT, 'target_id', 'TARGET_ID_PREFIX_INVALID', {
            expected_prefix = prefix,
        })
    end
    return nil
end

function RewardEntry.validate(value)
    local err = validation_no_unknown_fields(CONTRACT, value, FIELDS)
    if err ~= nil then
        return err
    end
    local entry_type = raw_get(value, 'entry_type')
    local target_id = raw_get(value, 'target_id')
    local target_character_id = raw_get(value, 'target_character_id')
    local metadata = raw_get(value, 'metadata')
    err = validation_first(
        validation_enum(CONTRACT, 'entry_type', entry_type, TYPES),
        validate_target_id(entry_type, target_id),
        validation_integer(CONTRACT, 'quantity', raw_get(value, 'quantity'), 1),
        validation_identifier(CONTRACT, 'target_character_id', target_character_id, 'char_', true),
        validation_flat_map(CONTRACT, 'metadata', metadata, 'scalar'),
        validation_integer(CONTRACT, 'entry_order', raw_get(value, 'entry_order'), 1)
    )
    if err ~= nil then
        return err
    end
    if raw_get(CHARACTER_TARGETED, entry_type) and target_character_id == nil then
        return validation_invalid(CONTRACT, 'target_character_id', 'CHARACTER_TARGET_REQUIRED')
    end
    if raw_get(SAME_CHARACTER_TARGET, entry_type)
        and target_character_id ~= target_id
    then
        return validation_invalid(
            CONTRACT,
            'target_character_id',
            'CHARACTER_TARGET_MISMATCH',
            { expected = target_id }
        )
    end
    local owner_type = metadata ~= nil and raw_get(metadata, 'owner_type') or nil
    if entry_type == 'UNLOCK_FLAG'
        and (type_value(owner_type) ~= 'string' or owner_type == '')
    then
        return validation_invalid(CONTRACT, 'metadata.owner_type', 'OWNER_TYPE_REQUIRED')
    end
    return result_ok(value)
end

return RewardEntry
