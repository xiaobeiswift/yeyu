local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local ErrorCodes = require 'wzx.domain.character.error_codes'
local Progression = require 'wzx.domain.character.progression'
local Utf8Text = require 'wzx.domain.character.utf8_text'

local CharacterAggregate = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local is_integer = TableShape.is_integer
local progression_resolve_level = Progression.resolve_level
local progression_validate_curve = Progression.validate_curve
local result_err = Result.err
local result_ok = Result.ok
local sorted_string_keys = Ordered.sorted_string_keys
local tostring_value = tostring
local type_value = type
local utf8_is_valid = Utf8Text.is_valid
local validate_content_id = RuntimeId.validate_content
local validate_derived_id = RuntimeId.validate_derived

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_EXPERIENCE_GRANT = 1000000000
local MAX_CUSTOM_NAME_CODEPOINTS = 18

local AGGREGATE_FIELDS = {
    character_id = true,
    definition_version = true,
    level = true,
    experience = true,
    awakening_rank = true,
    unlocked_talent_ids = true,
    custom_name = true,
    created_receipt_id = true,
    revision = true,
}
local DEFINITION_FACT_FIELDS = {
    id = true,
    definition_version = true,
    role = true,
    level_curve_id = true,
    default_talent_ids = true,
    deprecated = true,
}
local CURVE_FIELDS = {
    id = true,
    level_cap = true,
    experience_cap = true,
    cumulative_exp_by_level = true,
    level_reward_refs = true,
}
local ROLES = {
    PROTAGONIST = true,
    COMPANION = true,
    ENEMY_TEMPLATE = true,
}

local function failure(code, message_key, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(code, message_key, false, details)
end

local function argument_failure(reason, details)
    return failure(
        ErrorCodes.CHARACTER_ARGUMENT_INVALID,
        'error.character.argument_invalid',
        reason,
        details
    )
end

local function build_failure(reason, details)
    return failure(
        ErrorCodes.CHARACTER_BUILD_INVALID,
        'error.character.build_invalid',
        reason,
        details
    )
end

local function curve_failure(reason, details)
    return failure(
        ErrorCodes.CHARACTER_LEVEL_CURVE_INVALID,
        'error.character.level_curve_invalid',
        reason,
        details
    )
end

local function experience_failure(reason, details)
    return failure(
        ErrorCodes.CHARACTER_XP_OUT_OF_RANGE,
        'error.character.xp_out_of_range',
        reason,
        details
    )
end

local function validate_known_fields(value, allowed_fields, failure_callback, field)
    if type_value(value) ~= 'table' or get_metatable(value) ~= nil then
        return failure_callback('TABLE_REQUIRED', { field = field })
    end

    local keys = sorted_string_keys(value)
    if not keys.ok then
        return failure_callback('STRING_FIELDS_REQUIRED', { field = field })
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        if not allowed_fields[key] then
            return failure_callback('UNKNOWN_FIELD', {
                field = field .. '.' .. key,
            })
        end
    end
    return result_ok(true)
end

local function validate_talent_ids(value, failure_callback, field, optional)
    if value == nil and optional then
        return result_ok(true)
    end
    if get_metatable(value) ~= nil or not is_dense_array(value) then
        return failure_callback('DENSE_ARRAY_REQUIRED', { field = field })
    end

    local previous
    local index
    for index = 1, #value do
        local talent_id = value[index]
        local checked = validate_content_id(
            talent_id,
            'talent_',
            field .. '[' .. tostring_value(index) .. ']'
        )
        if not checked.ok then
            return failure_callback('TALENT_ID_INVALID', {
                field = field .. '[' .. tostring_value(index) .. ']',
            })
        end
        if previous ~= nil and not bytewise_string_less(previous, talent_id) then
            return failure_callback('STRICT_ASCENDING_ORDER_REQUIRED', {
                field = field,
                index = index,
            })
        end
        previous = talent_id
    end
    return result_ok(true)
end

local function validate_definition_facts(definition)
    local fields = validate_known_fields(
        definition,
        DEFINITION_FACT_FIELDS,
        argument_failure,
        'definition_facts'
    )
    if not fields.ok then
        return fields
    end

    local id = validate_content_id(definition.id, 'char_', 'definition.id')
    if not id.ok then
        return argument_failure('DEFINITION_ID_INVALID', { field = 'definition.id' })
    end
    if not is_integer(definition.definition_version, 1, MAX_SAFE_INTEGER) then
        return argument_failure('DEFINITION_VERSION_INVALID', {
            field = 'definition.definition_version',
            minimum = 1,
            maximum = MAX_SAFE_INTEGER,
        })
    end
    if not ROLES[definition.role] then
        return argument_failure('DEFINITION_ROLE_INVALID', { field = 'definition.role' })
    end
    local curve_id = validate_content_id(
        definition.level_curve_id,
        'curve_level_',
        'definition.level_curve_id'
    )
    if not curve_id.ok then
        return argument_failure('DEFINITION_CURVE_ID_INVALID', {
            field = 'definition.level_curve_id',
        })
    end
    if type_value(definition.deprecated) ~= 'boolean' then
        return argument_failure('DEFINITION_DEPRECATED_INVALID', {
            field = 'definition.deprecated',
        })
    end

    return validate_talent_ids(
        definition.default_talent_ids,
        argument_failure,
        'definition.default_talent_ids',
        false
    )
end

local function validate_curve_shape(curve)
    local fields = validate_known_fields(curve, CURVE_FIELDS, curve_failure, 'curve')
    if not fields.ok then
        return fields
    end
    local id = validate_content_id(curve.id, 'curve_level_', 'curve.id')
    if not id.ok then
        return curve_failure('CURVE_ID_INVALID', { field = 'curve.id' })
    end
    return progression_validate_curve(curve)
end

local function copy_talent_ids(value)
    local copy = {}
    local index
    for index = 1, #value do
        copy[index] = value[index]
    end
    return copy
end

local function copy_state(state)
    local copy = {
        character_id = state.character_id,
        definition_version = state.definition_version,
        level = state.level,
        experience = state.experience,
        awakening_rank = state.awakening_rank,
        unlocked_talent_ids = copy_talent_ids(state.unlocked_talent_ids),
        created_receipt_id = state.created_receipt_id,
        revision = state.revision,
    }
    if state.custom_name ~= nil then
        copy.custom_name = state.custom_name
    end
    return copy
end

local function validate_state_shape(state)
    local fields = validate_known_fields(
        state,
        AGGREGATE_FIELDS,
        build_failure,
        'state'
    )
    if not fields.ok then
        return fields
    end

    local character_id = validate_content_id(
        state.character_id,
        'char_',
        'state.character_id'
    )
    if not character_id.ok then
        return build_failure('CHARACTER_ID_INVALID', { field = 'state.character_id' })
    end
    if not is_integer(state.definition_version, 1, MAX_SAFE_INTEGER) then
        return build_failure('DEFINITION_VERSION_INVALID', {
            field = 'state.definition_version',
            minimum = 1,
            maximum = MAX_SAFE_INTEGER,
        })
    end
    if not is_integer(state.level, 1, 100) then
        return build_failure('LEVEL_INVALID', {
            field = 'state.level',
            minimum = 1,
            maximum = 100,
        })
    end
    if not is_integer(state.experience, 0, MAX_SAFE_INTEGER) then
        return build_failure('EXPERIENCE_INVALID', {
            field = 'state.experience',
            minimum = 0,
            maximum = MAX_SAFE_INTEGER,
        })
    end
    if state.awakening_rank ~= 0 then
        return build_failure('AWAKENING_NOT_AVAILABLE', {
            field = 'state.awakening_rank',
            expected = 0,
        })
    end

    local talents = validate_talent_ids(
        state.unlocked_talent_ids,
        build_failure,
        'state.unlocked_talent_ids',
        false
    )
    if not talents.ok then
        return talents
    end

    if state.custom_name ~= nil then
        local valid, reason, context = utf8_is_valid(
            state.custom_name,
            MAX_CUSTOM_NAME_CODEPOINTS
        )
        if not valid then
            local details = {
                field = 'state.custom_name',
                maximum_codepoints = MAX_CUSTOM_NAME_CODEPOINTS,
                utf8_reason = reason,
            }
            if reason == 'CODEPOINT_LIMIT_EXCEEDED' then
                details.actual_codepoints = context
            elseif context ~= nil then
                details.byte_index = context
            end
            return build_failure('CUSTOM_NAME_INVALID', details)
        end
    end

    local receipt = validate_derived_id(
        state.created_receipt_id,
        'state.created_receipt_id'
    )
    if not receipt.ok then
        return build_failure('CREATED_RECEIPT_ID_INVALID', {
            field = 'state.created_receipt_id',
        })
    end
    if not is_integer(state.revision, 0, MAX_SAFE_INTEGER) then
        return build_failure('REVISION_INVALID', {
            field = 'state.revision',
            minimum = 0,
            maximum = MAX_SAFE_INTEGER,
        })
    end
    return result_ok(true)
end

local function validate_state_against_valid_curve(state, curve)
    if state.level > curve.level_cap then
        return build_failure('LEVEL_ABOVE_CURVE_CAP', {
            field = 'state.level',
            level_cap = curve.level_cap,
        })
    end
    local level = progression_resolve_level(curve, state.experience)
    if not level.ok then
        return level
    end
    if state.level ~= level.value then
        return build_failure('LEVEL_EXPERIENCE_MISMATCH', {
            field = 'state.level',
            actual = state.level,
            expected = level.value,
        })
    end
    return result_ok(true)
end

-- definition_facts is the exact projection returned by the sealed character
-- catalog. Resolving registration and cross-references belongs to the trusted
-- config/application composition boundary, not to this domain module.
function CharacterAggregate.validate(state, definition_facts, curve)
    local state_result = validate_state_shape(state)
    if not state_result.ok then
        return state_result
    end
    local definition_result = validate_definition_facts(definition_facts)
    if not definition_result.ok then
        return definition_result
    end
    if definition_facts.role == 'ENEMY_TEMPLATE' then
        return build_failure('DEFINITION_NOT_OWNABLE', {
            character_id = definition_facts.id,
            role = definition_facts.role,
        })
    end
    local curve_result = validate_curve_shape(curve)
    if not curve_result.ok then
        return curve_result
    end
    if state.character_id ~= definition_facts.id then
        return build_failure('DEFINITION_CHARACTER_MISMATCH', {
            character_id = state.character_id,
            definition_id = definition_facts.id,
        })
    end
    if state.definition_version > definition_facts.definition_version then
        return build_failure('DEFINITION_VERSION_UNAVAILABLE', {
            state_definition_version = state.definition_version,
            available_definition_version = definition_facts.definition_version,
        })
    end
    if state.custom_name ~= nil and definition_facts.role ~= 'PROTAGONIST' then
        return build_failure('CUSTOM_NAME_NOT_ALLOWED', {
            field = 'state.custom_name',
            role = definition_facts.role,
        })
    end
    if definition_facts.level_curve_id ~= curve.id then
        return build_failure('DEFINITION_CURVE_MISMATCH', {
            definition_curve_id = definition_facts.level_curve_id,
            curve_id = curve.id,
        })
    end
    local state_curve_result = validate_state_against_valid_curve(state, curve)
    if not state_curve_result.ok then
        return state_curve_result
    end
    return result_ok(copy_state(state))
end

local validate_aggregate = CharacterAggregate.validate

function CharacterAggregate.create_owned(definition_facts, created_receipt_id)
    local definition_result = validate_definition_facts(definition_facts)
    if not definition_result.ok then
        return definition_result
    end
    if definition_facts.role == 'ENEMY_TEMPLATE' then
        return argument_failure('DEFINITION_NOT_OWNABLE', {
            field = 'definition.role',
            character_id = definition_facts.id,
            role = definition_facts.role,
        })
    end
    if definition_facts.deprecated then
        return argument_failure('DEFINITION_DEPRECATED', {
            field = 'definition.deprecated',
            character_id = definition_facts.id,
        })
    end
    local receipt = validate_derived_id(
        created_receipt_id,
        'created_receipt_id'
    )
    if not receipt.ok then
        return argument_failure('CREATED_RECEIPT_ID_INVALID', {
            field = 'created_receipt_id',
        })
    end

    return result_ok({
        character_id = definition_facts.id,
        definition_version = definition_facts.definition_version,
        level = 1,
        experience = 0,
        awakening_rank = 0,
        unlocked_talent_ids = copy_talent_ids(definition_facts.default_talent_ids),
        created_receipt_id = created_receipt_id,
        revision = 0,
    })
end

function CharacterAggregate.grant_experience(state, definition_facts, curve, amount)
    local validated = validate_aggregate(state, definition_facts, curve)
    if not validated.ok then
        return validated
    end
    if not is_integer(amount, 1, MAX_EXPERIENCE_GRANT) then
        return experience_failure('AMOUNT_OUT_OF_RANGE', {
            field = 'amount',
            minimum = 1,
            maximum = MAX_EXPERIENCE_GRANT,
        })
    end
    local current = validated.value
    if current.definition_version ~= definition_facts.definition_version then
        return build_failure('DEFINITION_VERSION_MIGRATION_REQUIRED', {
            field = 'state.definition_version',
            state_definition_version = current.definition_version,
            available_definition_version = definition_facts.definition_version,
        })
    end
    if current.experience > MAX_SAFE_INTEGER - amount then
        return experience_failure('SAFE_INTEGER_OVERFLOW', {
            field = 'experience',
            maximum = MAX_SAFE_INTEGER,
        })
    end
    if amount > curve.experience_cap - current.experience then
        return experience_failure('EXPERIENCE_CAP_EXCEEDED', {
            field = 'experience',
            current_experience = current.experience,
            amount = amount,
            experience_cap = curve.experience_cap,
        })
    end
    if current.revision == MAX_SAFE_INTEGER then
        return build_failure('REVISION_INCREMENT_OVERFLOW', {
            field = 'state.revision',
            maximum = MAX_SAFE_INTEGER,
        })
    end

    local updated = copy_state(current)
    updated.experience = current.experience + amount
    local resolved_level = progression_resolve_level(curve, updated.experience)
    if not resolved_level.ok then
        return resolved_level
    end
    updated.level = resolved_level.value
    updated.revision = current.revision + 1
    return result_ok(updated)
end

function CharacterAggregate.rename_protagonist(
    state,
    definition_facts,
    curve,
    new_name
)
    local validated = validate_aggregate(state, definition_facts, curve)
    if not validated.ok then
        return validated
    end
    if definition_facts.role ~= 'PROTAGONIST' then
        return result_err(
            ErrorCodes.CHARACTER_RENAME_NOT_ALLOWED,
            'error.character.rename_not_allowed',
            false,
            {
                reason = 'ROLE_NOT_PROTAGONIST',
                role = definition_facts.role,
                character_id = definition_facts.id,
            }
        )
    end
    if type_value(new_name) ~= 'string' then
        return result_err(
            ErrorCodes.CHARACTER_NAME_INVALID,
            'error.character.name_invalid',
            false,
            {
                reason = 'STRING_REQUIRED',
                field = 'new_name',
            }
        )
    end
    local valid, reason, context = utf8_is_valid(
        new_name,
        MAX_CUSTOM_NAME_CODEPOINTS
    )
    if not valid then
        local details = {
            reason = 'CUSTOM_NAME_INVALID',
            field = 'new_name',
            maximum_codepoints = MAX_CUSTOM_NAME_CODEPOINTS,
            utf8_reason = reason,
        }
        if reason == 'CODEPOINT_LIMIT_EXCEEDED' then
            details.actual_codepoints = context
        elseif context ~= nil then
            details.byte_index = context
        end
        return result_err(
            ErrorCodes.CHARACTER_NAME_INVALID,
            'error.character.name_invalid',
            false,
            details
        )
    end
    if reason < 1 then
        return result_err(
            ErrorCodes.CHARACTER_NAME_INVALID,
            'error.character.name_invalid',
            false,
            {
                reason = 'CUSTOM_NAME_EMPTY',
                field = 'new_name',
            }
        )
    end

    local current = validated.value
    if current.custom_name == new_name then
        return result_err(
            ErrorCodes.CHARACTER_NAME_INVALID,
            'error.character.name_invalid',
            false,
            {
                reason = 'NAME_UNCHANGED',
                field = 'new_name',
            }
        )
    end
    if current.revision == MAX_SAFE_INTEGER then
        return build_failure('REVISION_INCREMENT_OVERFLOW', {
            field = 'state.revision',
            maximum = MAX_SAFE_INTEGER,
        })
    end

    local updated = copy_state(current)
    updated.custom_name = new_name
    updated.revision = current.revision + 1
    return result_ok(updated)
end

CharacterAggregate.MAX_CUSTOM_NAME_CODEPOINTS = MAX_CUSTOM_NAME_CODEPOINTS
CharacterAggregate.MAX_EXPERIENCE_GRANT = MAX_EXPERIENCE_GRANT

return CharacterAggregate
