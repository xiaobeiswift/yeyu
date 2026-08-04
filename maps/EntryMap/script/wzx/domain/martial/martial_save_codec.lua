local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local MartialErrorCodes = require 'wzx.domain.martial.error_codes'

local MartialSaveCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived
local validate_source_reference = RuntimeId.validate_source_reference

local CURRENT_SCHEMA_VERSION = 1
local MAX_OWNERSHIP_ROWS = 256
local MAX_PROGRESS_ROWS = 512
local MAX_LOADOUT_ROWS = 64
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_COPIES = 9999

local BUNDLE_FIELDS = {
    martial_metadata = true,
    martial_ownership_rows = true,
    martial_progress_rows = true,
    martial_loadout_rows = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    book_revision = true,
}
local OWNERSHIP_FIELDS = {
    martial_id = true,
    available_copy_count = true,
    bound_copy_count = true,
    account_unlocked = true,
    revision = true,
}
local PROGRESS_FIELDS = {
    character_id = true,
    martial_id = true,
    level = true,
    mastery_points = true,
    source_type = true,
    source_reference = true,
    acquisition_receipt_id = true,
    revision = true,
}
local LOADOUT_FIELDS = {
    character_id = true,
    routine_martial_id = true,
    internal_martial_id = true,
    lightness_martial_id = true,
    ai_profile_id = true,
    revision = true,
}
local SNAPSHOT_FIELDS = {
    book_revision = true,
    ownership_rows = true,
    progress_rows = true,
    loadout_rows = true,
}
local SOURCE_TYPES = {
    QUEST = true,
    FACTION = true,
    SHOP = true,
    DROP = true,
    EVENT = true,
    ENTITLEMENT = true,
    COMPENSATION = true,
}

local function failure(code, message_key, reason, details)
    local copied = {}
    local key
    local value
    if type_value(details) == 'table' then
        for key, value in raw_next, details do
            copied[key] = value
        end
    end
    copied.reason = reason
    return result_err(code, message_key, false, copied)
end

local function invalid(reason, details)
    return failure(
        MartialErrorCodes.MARTIAL_SAVE_INVALID,
        'error.martial.save_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        MartialErrorCodes.MARTIAL_SAVE_LIMIT_EXCEEDED,
        'error.martial.save_limit_exceeded',
        reason,
        details
    )
end

local function no_unknown_fields(value, allowed, path)
    if type_value(value) ~= 'table' then
        return invalid('TABLE_REQUIRED', { field = path })
    end
    local key
    for key in raw_next, value do
        if type_value(key) ~= 'string' or not allowed[key] then
            return invalid('UNKNOWN_FIELD', {
                field = path == '$' and tostring(key) or (path .. '.' .. tostring(key)),
            })
        end
    end
    return nil
end

local function optional_martial_id(value, field)
    if value == nil then
        return nil
    end
    local checked = validate_content(value, 'martial_', field)
    if not checked.ok then
        return invalid('MARTIAL_ID_INVALID', { field = field })
    end
    return nil
end

function MartialSaveCodec.encode(snapshot)
    local err = no_unknown_fields(snapshot, SNAPSHOT_FIELDS, '$')
    if err ~= nil then
        return err
    end
    if not is_integer(snapshot.book_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('BOOK_REVISION_INVALID', { field = 'book_revision' })
    end
    if type_value(snapshot.ownership_rows) ~= 'table'
        or type_value(snapshot.progress_rows) ~= 'table'
        or type_value(snapshot.loadout_rows) ~= 'table'
    then
        return invalid('ROWS_TABLE_REQUIRED')
    end
    if #snapshot.ownership_rows > MAX_OWNERSHIP_ROWS then
        return limit_exceeded('OWNERSHIP_ROW_LIMIT', {
            count = #snapshot.ownership_rows,
            max = MAX_OWNERSHIP_ROWS,
        })
    end
    if #snapshot.progress_rows > MAX_PROGRESS_ROWS then
        return limit_exceeded('PROGRESS_ROW_LIMIT', {
            count = #snapshot.progress_rows,
            max = MAX_PROGRESS_ROWS,
        })
    end
    if #snapshot.loadout_rows > MAX_LOADOUT_ROWS then
        return limit_exceeded('LOADOUT_ROW_LIMIT', {
            count = #snapshot.loadout_rows,
            max = MAX_LOADOUT_ROWS,
        })
    end

    local ownership_rows = {}
    local index
    for index = 1, #snapshot.ownership_rows do
        local row = snapshot.ownership_rows[index]
        err = no_unknown_fields(row, OWNERSHIP_FIELDS, 'ownership_rows[' .. tostring(index) .. ']')
        if err ~= nil then
            return err
        end
        local checked = validate_content(row.martial_id, 'martial_', 'martial_id')
        if not checked.ok then
            return invalid('MARTIAL_ID_INVALID', { field = 'ownership_rows.martial_id' })
        end
        if not is_integer(row.available_copy_count, 0, MAX_COPIES)
            or not is_integer(row.bound_copy_count, 0, MAX_COPIES)
            or not is_integer(row.revision, 0, MAX_SAFE_INTEGER)
            or type_value(row.account_unlocked) ~= 'boolean'
        then
            return invalid('OWNERSHIP_ROW_INVALID', { index = index })
        end
        ownership_rows[index] = {
            martial_id = row.martial_id,
            available_copy_count = row.available_copy_count,
            bound_copy_count = row.bound_copy_count,
            account_unlocked = row.account_unlocked,
            revision = row.revision,
        }
    end
    table_sort(ownership_rows, function(left, right)
        return bytewise_string_less(left.martial_id, right.martial_id)
    end)

    local progress_rows = {}
    for index = 1, #snapshot.progress_rows do
        local row = snapshot.progress_rows[index]
        err = no_unknown_fields(row, PROGRESS_FIELDS, 'progress_rows[' .. tostring(index) .. ']')
        if err ~= nil then
            return err
        end
        local checked_character = validate_content(row.character_id, 'char_', 'character_id')
        local checked_martial = validate_content(row.martial_id, 'martial_', 'martial_id')
        if not checked_character.ok or not checked_martial.ok then
            return invalid('PROGRESS_IDS_INVALID', { index = index })
        end
        if not is_integer(row.level, 1, 10)
            or not is_integer(row.mastery_points, 0, MAX_SAFE_INTEGER)
            or SOURCE_TYPES[row.source_type] ~= true
            or not is_integer(row.revision, 1, MAX_SAFE_INTEGER)
        then
            return invalid('PROGRESS_ROW_INVALID', { index = index })
        end
        local checked_ref = validate_source_reference(row.source_reference, 'source_reference')
        if not checked_ref.ok then
            return invalid('SOURCE_REFERENCE_INVALID', { index = index })
        end
        local checked_receipt = validate_derived(
            row.acquisition_receipt_id,
            'acquisition_receipt_id'
        )
        if not checked_receipt.ok then
            checked_receipt = validate_content(
                row.acquisition_receipt_id,
                'receipt_',
                'acquisition_receipt_id'
            )
            if not checked_receipt.ok then
                return invalid('ACQUISITION_RECEIPT_INVALID', { index = index })
            end
        end
        progress_rows[index] = {
            character_id = row.character_id,
            martial_id = row.martial_id,
            level = row.level,
            mastery_points = row.mastery_points,
            source_type = row.source_type,
            source_reference = row.source_reference,
            acquisition_receipt_id = row.acquisition_receipt_id,
            revision = row.revision,
        }
    end
    table_sort(progress_rows, function(left, right)
        if left.character_id ~= right.character_id then
            return bytewise_string_less(left.character_id, right.character_id)
        end
        return bytewise_string_less(left.martial_id, right.martial_id)
    end)

    local loadout_rows = {}
    for index = 1, #snapshot.loadout_rows do
        local row = snapshot.loadout_rows[index]
        err = no_unknown_fields(row, LOADOUT_FIELDS, 'loadout_rows[' .. tostring(index) .. ']')
        if err ~= nil then
            return err
        end
        local checked_character = validate_content(row.character_id, 'char_', 'character_id')
        if not checked_character.ok then
            return invalid('CHARACTER_ID_INVALID', { index = index })
        end
        err = optional_martial_id(row.routine_martial_id, 'routine_martial_id')
        if err ~= nil then
            return err
        end
        err = optional_martial_id(row.internal_martial_id, 'internal_martial_id')
        if err ~= nil then
            return err
        end
        err = optional_martial_id(row.lightness_martial_id, 'lightness_martial_id')
        if err ~= nil then
            return err
        end
        local checked_ai = validate_content(row.ai_profile_id, 'ai_profile_', 'ai_profile_id')
        if not checked_ai.ok or not is_integer(row.revision, 0, MAX_SAFE_INTEGER) then
            return invalid('LOADOUT_ROW_INVALID', { index = index })
        end
        loadout_rows[index] = {
            character_id = row.character_id,
            routine_martial_id = row.routine_martial_id,
            internal_martial_id = row.internal_martial_id,
            lightness_martial_id = row.lightness_martial_id,
            ai_profile_id = row.ai_profile_id,
            revision = row.revision,
        }
    end
    table_sort(loadout_rows, function(left, right)
        return bytewise_string_less(left.character_id, right.character_id)
    end)

    return result_ok({
        martial_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            book_revision = snapshot.book_revision,
        },
        martial_ownership_rows = ownership_rows,
        martial_progress_rows = progress_rows,
        martial_loadout_rows = loadout_rows,
    })
end

function MartialSaveCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    err = no_unknown_fields(bundle.martial_metadata, METADATA_FIELDS, 'martial_metadata')
    if err ~= nil then
        return err
    end
    local metadata = bundle.martial_metadata
    if metadata.schema_version ~= CURRENT_SCHEMA_VERSION then
        return invalid('SCHEMA_VERSION_UNSUPPORTED', {
            schema_version = metadata.schema_version,
        })
    end
    if not is_integer(metadata.book_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('BOOK_REVISION_INVALID', { field = 'book_revision' })
    end
    if type_value(bundle.martial_ownership_rows) ~= 'table'
        or type_value(bundle.martial_progress_rows) ~= 'table'
        or type_value(bundle.martial_loadout_rows) ~= 'table'
    then
        return invalid('ROWS_TABLE_REQUIRED')
    end

    return MartialSaveCodec.encode({
        book_revision = metadata.book_revision,
        ownership_rows = bundle.martial_ownership_rows,
        progress_rows = bundle.martial_progress_rows,
        loadout_rows = bundle.martial_loadout_rows,
    })
end

function MartialSaveCodec.to_aggregate_state(bundle)
    local decoded = MartialSaveCodec.decode(bundle)
    if not decoded.ok then
        return decoded
    end
    -- decode returns re-encoded bundle; rebuild aggregate maps.
    local encoded = decoded.value
    local ownership_by_martial = {}
    local index
    for index = 1, #encoded.martial_ownership_rows do
        local row = encoded.martial_ownership_rows[index]
        ownership_by_martial[row.martial_id] = {
            martial_id = row.martial_id,
            available_copy_count = row.available_copy_count,
            bound_copy_count = row.bound_copy_count,
            account_unlocked = row.account_unlocked,
            revision = row.revision,
        }
    end
    local progress_by_key = {}
    for index = 1, #encoded.martial_progress_rows do
        local row = encoded.martial_progress_rows[index]
        local key = row.character_id .. '\0' .. row.martial_id
        progress_by_key[key] = {
            character_id = row.character_id,
            martial_id = row.martial_id,
            level = row.level,
            mastery_points = row.mastery_points,
            source_type = row.source_type,
            source_reference = row.source_reference,
            acquisition_receipt_id = row.acquisition_receipt_id,
            revision = row.revision,
        }
    end
    local loadout_by_character = {}
    for index = 1, #encoded.martial_loadout_rows do
        local row = encoded.martial_loadout_rows[index]
        loadout_by_character[row.character_id] = {
            character_id = row.character_id,
            routine_martial_id = row.routine_martial_id,
            internal_martial_id = row.internal_martial_id,
            lightness_martial_id = row.lightness_martial_id,
            ai_profile_id = row.ai_profile_id,
            revision = row.revision,
        }
    end
    return result_ok({
        ownership_by_martial = ownership_by_martial,
        progress_by_key = progress_by_key,
        loadout_by_character = loadout_by_character,
        book_revision = encoded.martial_metadata.book_revision,
    })
end

return MartialSaveCodec
