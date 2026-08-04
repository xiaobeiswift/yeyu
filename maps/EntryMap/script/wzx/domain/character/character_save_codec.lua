local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local Utf8Text = require 'wzx.domain.character.utf8_text'

local CharacterSaveCodec = {}

-- Capture the trusted primitives once. Replacing an exported module method
-- after this codec is loaded must not alter an already-bound authority.
local bytewise_string_less = Ordered.bytewise_string_less
local result_ok = Result.ok
local result_err = Result.err
local raw_next = next
local table_sort = table.sort
local validate_content_id_primitive = RuntimeId.validate_content
local validate_derived_id = RuntimeId.validate_derived
local is_integer = TableShape.is_integer
local validate_utf8 = Utf8Text.is_valid

local CURRENT_SCHEMA_VERSION = 1
local LIMITS_VERSION = 1
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_LEVEL = 100
local MAX_CUSTOM_NAME_CODEPOINTS = 18

local BUNDLE_FIELDS = {
    character_metadata = true,
    character_rows = true,
    character_talent_rows = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    revision = true,
}
local CHARACTER_ROW_FIELDS = {
    character_id = true,
    definition_version = true,
    level = true,
    experience = true,
    awakening_rank = true,
    custom_name = true,
    created_receipt_id = true,
    revision = true,
}
local TALENT_ROW_FIELDS = {
    character_id = true,
    talent_id = true,
    unlocked_revision = true,
}
local SNAPSHOT_FIELDS = {
    revision = true,
    character_states = true,
    talent_unlock_rows = true,
}
local STATE_FIELDS = {
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
local LIMIT_FIELDS = {
    limits_version = true,
    max_character_rows = true,
    max_talent_rows = true,
}
local REFERENCE_FIELDS = {
    character_definition_versions = true,
    talent_ids = true,
}

local Authority = {}
Authority.__index = Authority
Authority.__newindex = function()
    error('character save codec is read-only', 2)
end
Authority.__metatable = false

local STATES = setmetatable({}, { __mode = 'k' })

local function failure(code, message_key, reason, details)
    local copied = {}
    local key
    local value
    if type(details) == 'table' then
        for key, value in raw_next, details do
            copied[key] = value
        end
    end
    copied.reason = reason
    return result_err(code, message_key, false, copied)
end

local function invalid(reason, details)
    return failure(
        'CHARACTER_SAVE_INVALID',
        'error.character.save_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        'CHARACTER_SAVE_LIMIT_EXCEEDED',
        'error.character.save_limit_exceeded',
        reason,
        details
    )
end

local function unsupported_version(actual)
    local details = {
        current = CURRENT_SCHEMA_VERSION,
        minimum_supported = CURRENT_SCHEMA_VERSION,
    }
    if is_integer(actual, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER) then
        details.actual = actual
    else
        details.actual_type = type(actual)
    end
    return failure(
        'CHARACTER_SAVE_VERSION_UNSUPPORTED',
        'error.character.save_version_unsupported',
        'SCHEMA_VERSION_UNSUPPORTED',
        details
    )
end

local function invalid_authority()
    return invalid('CODEC_AUTHORITY_REQUIRED')
end

local function validate_exact_fields(value, allowed, path)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return invalid('PLAIN_TABLE_REQUIRED', { path = path })
    end

    local key
    for key in raw_next, value do
        if type(key) ~= 'string' then
            return invalid('STRING_FIELD_KEY_REQUIRED', { path = path })
        end
        if not allowed[key] then
            return invalid('UNKNOWN_FIELD', {
                path = path,
                field_bytes = #key,
            })
        end
    end
    return result_ok(true)
end

-- The count guard deliberately runs before any sort, copy, or unbounded dense
-- array helper. Save data is untrusted and may be a hostile sparse/huge table.
local function bounded_array_length(value, maximum, path)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return invalid('PLAIN_DENSE_ARRAY_REQUIRED', { path = path })
    end

    local count = 0
    local maximum_index = 0
    local key
    for key in raw_next, value do
        count = count + 1
        if count > maximum then
            return limit_exceeded('ROW_LIMIT_EXCEEDED', {
                path = path,
                maximum = maximum,
                observed_at_least = count,
            })
        end
        if not is_integer(key, 1, MAX_SAFE_INTEGER) then
            return invalid('DENSE_ARRAY_KEY_REQUIRED', { path = path })
        end
        if key > maximum_index then
            maximum_index = key
        end
    end
    if count ~= maximum_index then
        return invalid('DENSE_ARRAY_REQUIRED', {
            path = path,
            count = count,
            maximum_index = maximum_index,
        })
    end
    local index
    for index = 1, maximum_index do
        if rawget(value, index) == nil then
            return invalid('DENSE_ARRAY_REQUIRED', {
                path = path,
                missing_index = index,
            })
        end
    end
    return result_ok(count)
end

local function validate_content_id(value, prefix, path, reason)
    local checked = validate_content_id_primitive(value, prefix, path)
    if not checked.ok then
        return invalid(reason, { path = path })
    end
    return result_ok(value)
end

local function validate_custom_name(value, path)
    if value == nil then
        return result_ok(true)
    end
    local valid, reason, context = validate_utf8(
        value,
        MAX_CUSTOM_NAME_CODEPOINTS
    )
    if not valid then
        local details = {
            path = path,
            utf8_reason = reason,
            maximum_codepoints = MAX_CUSTOM_NAME_CODEPOINTS,
        }
        if reason == 'CODEPOINT_LIMIT_EXCEEDED' then
            details.actual_codepoints = context
        elseif context ~= nil then
            details.byte_index = context
        end
        return invalid('CUSTOM_NAME_INVALID', details)
    end
    return result_ok(true)
end

local function validate_character_values(value, path, bundle_revision)
    local character_id = validate_content_id(
        rawget(value, 'character_id'),
        'char_',
        path .. '.character_id',
        'CHARACTER_ID_INVALID'
    )
    if not character_id.ok then
        return character_id
    end
    if not is_integer(
        rawget(value, 'definition_version'),
        1,
        MAX_SAFE_INTEGER
    ) then
        return invalid('DEFINITION_VERSION_INVALID', {
            path = path .. '.definition_version',
        })
    end
    if not is_integer(rawget(value, 'level'), 1, MAX_LEVEL) then
        return invalid('LEVEL_INVALID', { path = path .. '.level' })
    end
    if not is_integer(
        rawget(value, 'experience'),
        0,
        MAX_SAFE_INTEGER
    ) then
        return invalid('EXPERIENCE_INVALID', {
            path = path .. '.experience',
        })
    end
    if rawget(value, 'awakening_rank') ~= 0 then
        return invalid('AWAKENING_NOT_AVAILABLE', {
            path = path .. '.awakening_rank',
        })
    end
    local custom_name = validate_custom_name(
        rawget(value, 'custom_name'),
        path .. '.custom_name'
    )
    if not custom_name.ok then
        return custom_name
    end
    local receipt = validate_derived_id(
        rawget(value, 'created_receipt_id'),
        path .. '.created_receipt_id'
    )
    if not receipt.ok then
        return invalid('CREATED_RECEIPT_ID_INVALID', {
            path = path .. '.created_receipt_id',
        })
    end
    local revision = rawget(value, 'revision')
    if not is_integer(revision, 0, MAX_SAFE_INTEGER) then
        return invalid('REVISION_INVALID', { path = path .. '.revision' })
    end
    if revision > bundle_revision then
        return invalid('CHARACTER_REVISION_ABOVE_BUNDLE', {
            path = path .. '.revision',
            character_revision = revision,
            bundle_revision = bundle_revision,
        })
    end
    return result_ok(true)
end

local function copy_character_row(value)
    local copy = {
        character_id = rawget(value, 'character_id'),
        definition_version = rawget(value, 'definition_version'),
        level = rawget(value, 'level'),
        experience = rawget(value, 'experience'),
        awakening_rank = rawget(value, 'awakening_rank'),
        created_receipt_id = rawget(value, 'created_receipt_id'),
        revision = rawget(value, 'revision'),
    }
    if rawget(value, 'custom_name') ~= nil then
        copy.custom_name = rawget(value, 'custom_name')
    end
    return copy
end

local function validate_character_row(value, index, bundle_revision)
    local path = '$.character_rows[' .. tostring(index) .. ']'
    local fields = validate_exact_fields(value, CHARACTER_ROW_FIELDS, path)
    if not fields.ok then
        return fields
    end
    local values = validate_character_values(value, path, bundle_revision)
    if not values.ok then
        return values
    end
    return result_ok(copy_character_row(value))
end

local function copy_talent_row(value)
    return {
        character_id = rawget(value, 'character_id'),
        talent_id = rawget(value, 'talent_id'),
        unlocked_revision = rawget(value, 'unlocked_revision'),
    }
end

local function validate_talent_row(value, index)
    local path = '$.character_talent_rows[' .. tostring(index) .. ']'
    local fields = validate_exact_fields(value, TALENT_ROW_FIELDS, path)
    if not fields.ok then
        return fields
    end
    local character_id = validate_content_id(
        rawget(value, 'character_id'),
        'char_',
        path .. '.character_id',
        'CHARACTER_ID_INVALID'
    )
    if not character_id.ok then
        return character_id
    end
    local talent_id = validate_content_id(
        rawget(value, 'talent_id'),
        'talent_',
        path .. '.talent_id',
        'TALENT_ID_INVALID'
    )
    if not talent_id.ok then
        return talent_id
    end
    if not is_integer(
        rawget(value, 'unlocked_revision'),
        0,
        MAX_SAFE_INTEGER
    ) then
        return invalid('UNLOCKED_REVISION_INVALID', {
            path = path .. '.unlocked_revision',
        })
    end
    return result_ok(copy_talent_row(value))
end

local function character_less(left, right)
    return bytewise_string_less(left.character_id, right.character_id)
end

local function talent_less(left, right)
    if left.character_id ~= right.character_id then
        return bytewise_string_less(left.character_id, right.character_id)
    end
    return bytewise_string_less(left.talent_id, right.talent_id)
end

local function talent_pair_equal(left, right)
    return left.character_id == right.character_id
        and left.talent_id == right.talent_id
end

local function validate_bundle(bundle, limits)
    local root = validate_exact_fields(bundle, BUNDLE_FIELDS, '$')
    if not root.ok then
        return root
    end
    if rawget(bundle, 'character_metadata') == nil
        or rawget(bundle, 'character_rows') == nil
        or rawget(bundle, 'character_talent_rows') == nil
    then
        return invalid('BUNDLE_SECTION_REQUIRED', { path = '$' })
    end

    local metadata = rawget(bundle, 'character_metadata')
    local metadata_fields = validate_exact_fields(
        metadata,
        METADATA_FIELDS,
        '$.character_metadata'
    )
    if not metadata_fields.ok then
        return metadata_fields
    end
    local schema_version = rawget(metadata, 'schema_version')
    if schema_version ~= CURRENT_SCHEMA_VERSION then
        return unsupported_version(schema_version)
    end
    local bundle_revision = rawget(metadata, 'revision')
    if not is_integer(bundle_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('REVISION_INVALID', {
            path = '$.character_metadata.revision',
        })
    end

    local source_characters = rawget(bundle, 'character_rows')
    local character_length = bounded_array_length(
        source_characters,
        limits.max_character_rows,
        '$.character_rows'
    )
    if not character_length.ok then
        return character_length
    end
    local source_talents = rawget(bundle, 'character_talent_rows')
    local talent_length = bounded_array_length(
        source_talents,
        limits.max_talent_rows,
        '$.character_talent_rows'
    )
    if not talent_length.ok then
        return talent_length
    end

    local characters = {}
    local characters_by_id = {}
    local receipts = {}
    local previous_character_id
    local index
    for index = 1, character_length.value do
        local validated = validate_character_row(
            rawget(source_characters, index),
            index,
            bundle_revision
        )
        if not validated.ok then
            return validated
        end
        local row = validated.value
        if previous_character_id ~= nil
            and not bytewise_string_less(
                previous_character_id,
                row.character_id
            )
        then
            return invalid('CHARACTER_ROWS_NOT_STRICTLY_ORDERED', {
                path = '$.character_rows',
                index = index,
            })
        end
        if characters_by_id[row.character_id] ~= nil then
            return invalid('CHARACTER_ID_DUPLICATE', {
                character_id = row.character_id,
            })
        end
        if receipts[row.created_receipt_id] ~= nil then
            return invalid('CREATED_RECEIPT_ID_DUPLICATE', {
                character_id = row.character_id,
            })
        end
        previous_character_id = row.character_id
        characters_by_id[row.character_id] = row
        receipts[row.created_receipt_id] = true
        characters[index] = row
    end

    local talents = {}
    local previous_talent
    for index = 1, talent_length.value do
        local validated = validate_talent_row(rawget(source_talents, index), index)
        if not validated.ok then
            return validated
        end
        local row = validated.value
        if previous_talent ~= nil and not talent_less(previous_talent, row) then
            return invalid('TALENT_ROWS_NOT_STRICTLY_ORDERED', {
                path = '$.character_talent_rows',
                index = index,
            })
        end
        local parent = characters_by_id[row.character_id]
        if parent == nil then
            return invalid('TALENT_PARENT_NOT_FOUND', {
                character_id = row.character_id,
                talent_id = row.talent_id,
            })
        end
        if row.unlocked_revision > parent.revision then
            return invalid('UNLOCKED_REVISION_ABOVE_CHARACTER', {
                character_id = row.character_id,
                talent_id = row.talent_id,
                unlocked_revision = row.unlocked_revision,
                character_revision = parent.revision,
            })
        end
        previous_talent = row
        talents[index] = row
    end

    return result_ok({
        character_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            revision = bundle_revision,
        },
        character_rows = characters,
        character_talent_rows = talents,
    })
end

local function validate_limits(limits)
    local fields = validate_exact_fields(limits, LIMIT_FIELDS, '$.limits')
    if not fields.ok then
        return fields
    end
    if rawget(limits, 'limits_version') ~= LIMITS_VERSION then
        return invalid('LIMITS_VERSION_INVALID', { path = '$.limits.limits_version' })
    end
    if not is_integer(
        rawget(limits, 'max_character_rows'),
        0,
        MAX_SAFE_INTEGER
    ) then
        return invalid('CHARACTER_ROW_LIMIT_INVALID', {
            path = '$.limits.max_character_rows',
        })
    end
    if not is_integer(
        rawget(limits, 'max_talent_rows'),
        0,
        MAX_SAFE_INTEGER
    ) then
        return invalid('TALENT_ROW_LIMIT_INVALID', {
            path = '$.limits.max_talent_rows',
        })
    end
    return result_ok({
        max_character_rows = rawget(limits, 'max_character_rows'),
        max_talent_rows = rawget(limits, 'max_talent_rows'),
    })
end

local function validate_reference_map(value, maximum)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return invalid('PLAIN_TABLE_REQUIRED', {
            path = '$.references.character_definition_versions',
        })
    end
    local copy = {}
    local count = 0
    local character_id
    local version
    for character_id, version in raw_next, value do
        count = count + 1
        if count > maximum then
            return limit_exceeded('REFERENCE_LIMIT_EXCEEDED', {
                path = '$.references.character_definition_versions',
                maximum = maximum,
                observed_at_least = count,
            })
        end
        local checked = validate_content_id(
            character_id,
            'char_',
            '$.references.character_definition_versions.<key>',
            'CHARACTER_ID_INVALID'
        )
        if not checked.ok then
            return checked
        end
        if not is_integer(version, 1, MAX_SAFE_INTEGER) then
            return invalid('DEFINITION_VERSION_INVALID', {
                path = '$.references.character_definition_versions.' .. character_id,
            })
        end
        copy[character_id] = version
    end
    return result_ok(copy)
end

local function validate_references(references, limits)
    local fields = validate_exact_fields(references, REFERENCE_FIELDS, '$.references')
    if not fields.ok then
        return fields
    end
    if rawget(references, 'character_definition_versions') == nil
        or rawget(references, 'talent_ids') == nil
    then
        return invalid('REFERENCE_FIELD_REQUIRED', { path = '$.references' })
    end
    local versions = validate_reference_map(
        rawget(references, 'character_definition_versions'),
        limits.max_character_rows
    )
    if not versions.ok then
        return versions
    end

    local source_talents = rawget(references, 'talent_ids')
    local length = bounded_array_length(
        source_talents,
        limits.max_talent_rows,
        '$.references.talent_ids'
    )
    if not length.ok then
        return length
    end
    local talent_ids = {}
    local talent_set = {}
    local previous
    local index
    for index = 1, length.value do
        local talent_id = rawget(source_talents, index)
        local checked = validate_content_id(
            talent_id,
            'talent_',
            '$.references.talent_ids[' .. tostring(index) .. ']',
            'TALENT_ID_INVALID'
        )
        if not checked.ok then
            return checked
        end
        if previous ~= nil
            and not bytewise_string_less(previous, talent_id)
        then
            return invalid('REFERENCE_TALENTS_NOT_STRICTLY_ORDERED', {
                path = '$.references.talent_ids',
                index = index,
            })
        end
        previous = talent_id
        talent_ids[index] = talent_id
        talent_set[talent_id] = true
    end
    return result_ok({
        character_definition_versions = versions.value,
        talent_ids = talent_ids,
        talent_set = talent_set,
    })
end

local function issue_less(left, right)
    local left_character = left.character_id or ''
    local right_character = right.character_id or ''
    if left_character ~= right_character then
        return bytewise_string_less(left_character, right_character)
    end
    local left_talent = left.talent_id or ''
    local right_talent = right.talent_id or ''
    if left_talent ~= right_talent then
        return bytewise_string_less(left_talent, right_talent)
    end
    return bytewise_string_less(left.code, right.code)
end

local function copy_talent_ids(value)
    local copy = {}
    local index
    for index = 1, #value do
        copy[index] = value[index]
    end
    return copy
end

local function decode_validated(bundle, references)
    local talents_by_character = {}
    local index
    for index = 1, #bundle.character_rows do
        talents_by_character[bundle.character_rows[index].character_id] = {}
    end
    for index = 1, #bundle.character_talent_rows do
        local row = bundle.character_talent_rows[index]
        local target = talents_by_character[row.character_id]
        target[#target + 1] = row.talent_id
    end

    local issues = {}
    local states = {}
    for index = 1, #bundle.character_rows do
        local row = bundle.character_rows[index]
        local available_version = references.character_definition_versions[
            row.character_id
        ]
        if available_version == nil then
            issues[#issues + 1] = {
                code = 'CHARACTER_CONFIG_MISSING',
                character_id = row.character_id,
            }
        elseif row.definition_version ~= available_version then
            local issue_code = 'CHARACTER_DEFINITION_VERSION_UNAVAILABLE'
            if row.definition_version < available_version then
                issue_code = 'CHARACTER_DEFINITION_VERSION_MIGRATION_REQUIRED'
            end
            issues[#issues + 1] = {
                code = issue_code,
                character_id = row.character_id,
                saved_definition_version = row.definition_version,
                available_definition_version = available_version,
            }
        end

        local state = copy_character_row(row)
        state.unlocked_talent_ids = copy_talent_ids(
            talents_by_character[row.character_id]
        )
        states[index] = state
    end
    for index = 1, #bundle.character_talent_rows do
        local row = bundle.character_talent_rows[index]
        if not references.talent_set[row.talent_id] then
            issues[#issues + 1] = {
                code = 'CHARACTER_TALENT_CONFIG_MISSING',
                character_id = row.character_id,
                talent_id = row.talent_id,
            }
        end
    end

    if #issues > 0 then
        table_sort(issues, issue_less)
        return result_ok({
            status = 'READ_ONLY_ISOLATED',
            writable = false,
            schema_version = CURRENT_SCHEMA_VERSION,
            revision = bundle.character_metadata.revision,
            preserve_original = true,
            issues = issues,
        })
    end

    local talent_rows = {}
    for index = 1, #bundle.character_talent_rows do
        talent_rows[index] = copy_talent_row(bundle.character_talent_rows[index])
    end
    return result_ok({
        status = 'READY',
        writable = true,
        schema_version = CURRENT_SCHEMA_VERSION,
        revision = bundle.character_metadata.revision,
        character_states = states,
        talent_unlock_rows = talent_rows,
        issues = {},
    })
end

local function validate_state(value, index, bundle_revision, talent_limit)
    local path = '$.snapshot.character_states[' .. tostring(index) .. ']'
    local fields = validate_exact_fields(value, STATE_FIELDS, path)
    if not fields.ok then
        return fields
    end
    local values = validate_character_values(value, path, bundle_revision)
    if not values.ok then
        return values
    end
    local source_talents = rawget(value, 'unlocked_talent_ids')
    local length = bounded_array_length(
        source_talents,
        talent_limit,
        path .. '.unlocked_talent_ids'
    )
    if not length.ok then
        return length
    end
    local talents = {}
    local previous
    local talent_index
    for talent_index = 1, length.value do
        local talent_id = rawget(source_talents, talent_index)
        local checked = validate_content_id(
            talent_id,
            'talent_',
            path .. '.unlocked_talent_ids[' .. tostring(talent_index) .. ']',
            'TALENT_ID_INVALID'
        )
        if not checked.ok then
            return checked
        end
        if previous ~= nil
            and not bytewise_string_less(previous, talent_id)
        then
            return invalid('UNLOCKED_TALENTS_NOT_STRICTLY_ORDERED', {
                path = path .. '.unlocked_talent_ids',
                index = talent_index,
            })
        end
        previous = talent_id
        talents[talent_index] = talent_id
    end
    local state = copy_character_row(value)
    state.unlocked_talent_ids = talents
    return result_ok(state)
end

local function encode_snapshot(snapshot, limits)
    local fields = validate_exact_fields(snapshot, SNAPSHOT_FIELDS, '$.snapshot')
    if not fields.ok then
        return fields
    end
    local revision = rawget(snapshot, 'revision')
    if not is_integer(revision, 0, MAX_SAFE_INTEGER) then
        return invalid('REVISION_INVALID', { path = '$.snapshot.revision' })
    end

    local source_states = rawget(snapshot, 'character_states')
    local state_length = bounded_array_length(
        source_states,
        limits.max_character_rows,
        '$.snapshot.character_states'
    )
    if not state_length.ok then
        return state_length
    end
    local source_talents = rawget(snapshot, 'talent_unlock_rows')
    local talent_length = bounded_array_length(
        source_talents,
        limits.max_talent_rows,
        '$.snapshot.talent_unlock_rows'
    )
    if not talent_length.ok then
        return talent_length
    end

    local states = {}
    local state_by_id = {}
    local receipts = {}
    local expected_talents = {}
    local expected_count = 0
    local index
    for index = 1, state_length.value do
        local validated = validate_state(
            rawget(source_states, index),
            index,
            revision,
            limits.max_talent_rows
        )
        if not validated.ok then
            return validated
        end
        local state = validated.value
        if state_by_id[state.character_id] ~= nil then
            return invalid('CHARACTER_ID_DUPLICATE', {
                character_id = state.character_id,
            })
        end
        if receipts[state.created_receipt_id] ~= nil then
            return invalid('CREATED_RECEIPT_ID_DUPLICATE', {
                character_id = state.character_id,
            })
        end
        state_by_id[state.character_id] = state
        receipts[state.created_receipt_id] = true
        states[index] = state

        local talent_index
        for talent_index = 1, #state.unlocked_talent_ids do
            expected_count = expected_count + 1
            if expected_count > limits.max_talent_rows then
                return limit_exceeded('ROW_LIMIT_EXCEEDED', {
                    path = '$.snapshot.character_states[].unlocked_talent_ids',
                    maximum = limits.max_talent_rows,
                    observed_at_least = expected_count,
                })
            end
            expected_talents[expected_count] = {
                character_id = state.character_id,
                talent_id = state.unlocked_talent_ids[talent_index],
            }
        end
    end
    table_sort(states, character_less)
    table_sort(expected_talents, talent_less)

    local talents = {}
    for index = 1, talent_length.value do
        local validated = validate_talent_row(rawget(source_talents, index), index)
        if not validated.ok then
            return validated
        end
        local row = validated.value
        local parent = state_by_id[row.character_id]
        if parent == nil then
            return invalid('TALENT_PARENT_NOT_FOUND', {
                character_id = row.character_id,
                talent_id = row.talent_id,
            })
        end
        if row.unlocked_revision > parent.revision then
            return invalid('UNLOCKED_REVISION_ABOVE_CHARACTER', {
                character_id = row.character_id,
                talent_id = row.talent_id,
                unlocked_revision = row.unlocked_revision,
                character_revision = parent.revision,
            })
        end
        talents[index] = row
    end
    table_sort(talents, talent_less)
    for index = 2, #talents do
        if talent_pair_equal(talents[index - 1], talents[index]) then
            return invalid('TALENT_ID_DUPLICATE', {
                character_id = talents[index].character_id,
                talent_id = talents[index].talent_id,
            })
        end
    end

    if #expected_talents ~= #talents then
        return invalid('TALENT_SET_MISMATCH', {
            expected_count = #expected_talents,
            actual_count = #talents,
        })
    end
    for index = 1, #expected_talents do
        if not talent_pair_equal(expected_talents[index], talents[index]) then
            return invalid('TALENT_SET_MISMATCH', {
                index = index,
                expected_character_id = expected_talents[index].character_id,
                expected_talent_id = expected_talents[index].talent_id,
                actual_character_id = talents[index].character_id,
                actual_talent_id = talents[index].talent_id,
            })
        end
    end

    local character_rows = {}
    for index = 1, #states do
        character_rows[index] = copy_character_row(states[index])
    end
    return validate_bundle({
        character_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            revision = revision,
        },
        character_rows = character_rows,
        character_talent_rows = talents,
    }, limits)
end

function Authority:validate_current(bundle)
    local limits = STATES[self]
    if limits == nil then
        return invalid_authority()
    end
    return validate_bundle(bundle, limits)
end

function Authority:encode_current(snapshot)
    local limits = STATES[self]
    if limits == nil then
        return invalid_authority()
    end
    return encode_snapshot(snapshot, limits)
end

function Authority:decode_current(bundle, references)
    local limits = STATES[self]
    if limits == nil then
        return invalid_authority()
    end
    local validated_bundle = validate_bundle(bundle, limits)
    if not validated_bundle.ok then
        return validated_bundle
    end
    local validated_references = validate_references(references, limits)
    if not validated_references.ok then
        return validated_references
    end
    return decode_validated(validated_bundle.value, validated_references.value)
end

function Authority:migrate_to_current(bundle)
    local limits = STATES[self]
    if limits == nil then
        return invalid_authority()
    end
    local validated = validate_bundle(bundle, limits)
    if not validated.ok then
        return validated
    end
    return result_ok({
        bundle = validated.value,
        report = {
            from_version = CURRENT_SCHEMA_VERSION,
            to_version = CURRENT_SCHEMA_VERSION,
            changed = false,
            applied_migration_ids = {},
            diagnostics = {},
        },
    })
end

function CharacterSaveCodec.bind(limits)
    local validated = validate_limits(limits)
    if not validated.ok then
        return validated
    end
    local authority = setmetatable({}, Authority)
    STATES[authority] = validated.value
    return result_ok(authority)
end

function CharacterSaveCodec.is_authority(value)
    return STATES[value] ~= nil
end

CharacterSaveCodec.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION
CharacterSaveCodec.LIMITS_VERSION = LIMITS_VERSION

return CharacterSaveCodec
