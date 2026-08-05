-- System 03 slot-3 party formation save codec.
-- Flat sections only: headers, members, empty preset placeholders.
-- Does not store combat stats, engine unit handles, or nested 3x3 grids.

local Ordered = require 'wzx.domain.common.ordered'
local PartyErrorCodes = require 'wzx.domain.party.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'

local PartySaveCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content

local CURRENT_SCHEMA_VERSION = 1
local MAX_CONTEXTS = 3
local MAX_MEMBERS = 4
local MAX_SAFE_INTEGER = 9007199254740991

local CONTEXTS = {
    PVE_MAIN = true,
    PVE_ALT = true,
    ARENA_DEFENSE = true,
}

local BUNDLE_FIELDS = {
    party_metadata = true,
    party_header_rows = true,
    party_member_rows = true,
    preset_header_rows = true,
    preset_member_rows = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    party_save_revision = true,
}
local HEADER_FIELDS = {
    party_context = true,
    leader_character_id = true,
    formation_template_id = true,
    active_preset_id = true,
    is_dirty_from_preset = true,
    revision = true,
}
local MEMBER_FIELDS = {
    party_context = true,
    character_id = true,
    position_index = true,
    entry_order = true,
    role_tag_override = true,
}
local SNAPSHOT_FIELDS = {
    party_save_revision = true,
    parties = true,
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
        PartyErrorCodes.PARTY_ARGUMENT_INVALID,
        'error.party.save_invalid',
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
                field = path == '$' and tostring(key)
                    or (path .. '.' .. tostring(key)),
            })
        end
    end
    return nil
end

local function context_less(left, right)
    return bytewise_string_less(left.party_context, right.party_context)
end

local function member_less(left, right)
    if left.party_context ~= right.party_context then
        return bytewise_string_less(left.party_context, right.party_context)
    end
    if left.position_index ~= right.position_index then
        return left.position_index < right.position_index
    end
    return bytewise_string_less(left.character_id, right.character_id)
end

local function copy_party(party)
    local members = {}
    local index
    for index = 1, #party.member_rows do
        local row = party.member_rows[index]
        members[index] = {
            character_id = row.character_id,
            position_index = row.position_index,
            entry_order = row.entry_order,
            role_tag_override = row.role_tag_override,
        }
    end
    return {
        party_context = party.party_context,
        leader_character_id = party.leader_character_id,
        member_rows = members,
        formation_template_id = party.formation_template_id,
        active_preset_id = party.active_preset_id,
        is_dirty_from_preset = party.is_dirty_from_preset == true,
        revision = party.revision,
    }
end

function PartySaveCodec.encode(snapshot)
    local err = no_unknown_fields(snapshot, SNAPSHOT_FIELDS, '$')
    if err ~= nil then
        return err
    end
    if not is_integer(snapshot.party_save_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('PARTY_SAVE_REVISION_INVALID', {
            field = 'party_save_revision',
        })
    end
    if type_value(snapshot.parties) ~= 'table'
        or not Ordered.is_dense_array(snapshot.parties)
    then
        return invalid('PARTIES_DENSE_ARRAY_REQUIRED', { field = 'parties' })
    end
    if #snapshot.parties > MAX_CONTEXTS then
        return invalid('PARTY_CONTEXT_LIMIT', {
            count = #snapshot.parties,
            max_contexts = MAX_CONTEXTS,
        })
    end

    local headers = {}
    local members = {}
    local seen = {}
    local index
    for index = 1, #snapshot.parties do
        local party = snapshot.parties[index]
        if type_value(party) ~= 'table' then
            return invalid('PARTY_ROW_TABLE_REQUIRED', {
                field = 'parties[' .. tostring(index) .. ']',
            })
        end
        local context = party.party_context
        if CONTEXTS[context] ~= true then
            return invalid('PARTY_CONTEXT_INVALID', {
                party_context = context,
            })
        end
        if seen[context] then
            return invalid('DUPLICATE_PARTY_CONTEXT', {
                party_context = context,
            })
        end
        seen[context] = true
        if not is_integer(party.revision, 0, MAX_SAFE_INTEGER) then
            return invalid('PARTY_REVISION_INVALID', {
                party_context = context,
            })
        end
        if party.leader_character_id ~= nil then
            local checked = validate_content(
                party.leader_character_id,
                'char_',
                'leader_character_id'
            )
            if not checked.ok then
                return invalid('LEADER_ID_INVALID', {
                    party_context = context,
                })
            end
        end
        if party.formation_template_id ~= nil then
            local checked = validate_content(
                party.formation_template_id,
                'formation_',
                'formation_template_id'
            )
            if not checked.ok then
                return invalid('FORMATION_TEMPLATE_ID_INVALID', {
                    party_context = context,
                })
            end
        end
        if party.active_preset_id ~= nil then
            local checked = validate_content(
                party.active_preset_id,
                'preset_party_',
                'active_preset_id'
            )
            if not checked.ok then
                return invalid('ACTIVE_PRESET_ID_INVALID', {
                    party_context = context,
                })
            end
        end
        if type_value(party.member_rows) ~= 'table'
            or not Ordered.is_dense_array(party.member_rows)
        then
            return invalid('MEMBER_ROWS_REQUIRED', {
                party_context = context,
            })
        end
        if #party.member_rows > MAX_MEMBERS then
            return invalid('PARTY_SIZE_OUT_OF_RANGE', {
                party_context = context,
                count = #party.member_rows,
            })
        end

        headers[#headers + 1] = {
            party_context = context,
            leader_character_id = party.leader_character_id,
            formation_template_id = party.formation_template_id,
            active_preset_id = party.active_preset_id,
            is_dirty_from_preset = party.is_dirty_from_preset == true,
            revision = party.revision,
        }

        local member_index
        for member_index = 1, #party.member_rows do
            local row = party.member_rows[member_index]
            local checked = validate_content(
                row.character_id,
                'char_',
                'character_id'
            )
            if not checked.ok then
                return invalid('CHARACTER_ID_INVALID', {
                    party_context = context,
                    index = member_index,
                })
            end
            if not is_integer(row.position_index, 0, 8) then
                return invalid('POSITION_INDEX_INVALID', {
                    party_context = context,
                    index = member_index,
                })
            end
            if not is_integer(row.entry_order, 1, MAX_MEMBERS) then
                return invalid('ENTRY_ORDER_INVALID', {
                    party_context = context,
                    index = member_index,
                })
            end
            members[#members + 1] = {
                party_context = context,
                character_id = row.character_id,
                position_index = row.position_index,
                entry_order = row.entry_order,
                role_tag_override = row.role_tag_override,
            }
        end
    end

    table_sort(headers, context_less)
    table_sort(members, member_less)

    return result_ok({
        party_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            party_save_revision = snapshot.party_save_revision,
        },
        party_header_rows = headers,
        party_member_rows = members,
        -- Presets are owned by system 03 but not implemented in this offline slice.
        preset_header_rows = {},
        preset_member_rows = {},
    })
end

function PartySaveCodec.decode(bundle)
    local err = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if err ~= nil then
        return err
    end
    err = no_unknown_fields(bundle.party_metadata, METADATA_FIELDS, 'party_metadata')
    if err ~= nil then
        return err
    end
    local meta = bundle.party_metadata
    if meta.schema_version ~= CURRENT_SCHEMA_VERSION then
        return invalid('SCHEMA_VERSION_UNSUPPORTED', {
            schema_version = meta.schema_version,
        })
    end
    if not is_integer(meta.party_save_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('PARTY_SAVE_REVISION_INVALID', {
            field = 'party_save_revision',
        })
    end
    if type_value(bundle.party_header_rows) ~= 'table'
        or not Ordered.is_dense_array(bundle.party_header_rows)
    then
        return invalid('HEADER_ROWS_DENSE_ARRAY_REQUIRED', {
            field = 'party_header_rows',
        })
    end
    if type_value(bundle.party_member_rows) ~= 'table'
        or not Ordered.is_dense_array(bundle.party_member_rows)
    then
        return invalid('MEMBER_ROWS_DENSE_ARRAY_REQUIRED', {
            field = 'party_member_rows',
        })
    end
    if type_value(bundle.preset_header_rows) ~= 'table'
        or not Ordered.is_dense_array(bundle.preset_header_rows)
    then
        return invalid('PRESET_HEADER_ROWS_REQUIRED', {
            field = 'preset_header_rows',
        })
    end
    if type_value(bundle.preset_member_rows) ~= 'table'
        or not Ordered.is_dense_array(bundle.preset_member_rows)
    then
        return invalid('PRESET_MEMBER_ROWS_REQUIRED', {
            field = 'preset_member_rows',
        })
    end
    -- Offline V1: reject non-empty presets until preset aggregate lands.
    if #bundle.preset_header_rows > 0 or #bundle.preset_member_rows > 0 then
        return invalid('PRESETS_UNSUPPORTED', {
            preset_header_count = #bundle.preset_header_rows,
            preset_member_count = #bundle.preset_member_rows,
        })
    end
    if #bundle.party_header_rows > MAX_CONTEXTS then
        return invalid('PARTY_CONTEXT_LIMIT', {
            count = #bundle.party_header_rows,
        })
    end

    local members_by_context = {}
    local index
    for index = 1, #bundle.party_member_rows do
        local row = bundle.party_member_rows[index]
        err = no_unknown_fields(
            row,
            MEMBER_FIELDS,
            'party_member_rows[' .. tostring(index) .. ']'
        )
        if err ~= nil then
            return err
        end
        if CONTEXTS[row.party_context] ~= true then
            return invalid('PARTY_CONTEXT_INVALID', {
                party_context = row.party_context,
            })
        end
        local checked = validate_content(row.character_id, 'char_', 'character_id')
        if not checked.ok then
            return invalid('CHARACTER_ID_INVALID', {
                field = 'party_member_rows[' .. tostring(index) .. '].character_id',
            })
        end
        if not is_integer(row.position_index, 0, 8) then
            return invalid('POSITION_INDEX_INVALID', {
                field = 'party_member_rows[' .. tostring(index) .. '].position_index',
            })
        end
        if not is_integer(row.entry_order, 1, MAX_MEMBERS) then
            return invalid('ENTRY_ORDER_INVALID', {
                field = 'party_member_rows[' .. tostring(index) .. '].entry_order',
            })
        end
        local list = members_by_context[row.party_context]
        if list == nil then
            list = {}
            members_by_context[row.party_context] = list
        end
        list[#list + 1] = {
            character_id = row.character_id,
            position_index = row.position_index,
            entry_order = row.entry_order,
            role_tag_override = row.role_tag_override,
        }
    end

    local parties = {}
    local seen = {}
    for index = 1, #bundle.party_header_rows do
        local row = bundle.party_header_rows[index]
        err = no_unknown_fields(
            row,
            HEADER_FIELDS,
            'party_header_rows[' .. tostring(index) .. ']'
        )
        if err ~= nil then
            return err
        end
        if CONTEXTS[row.party_context] ~= true then
            return invalid('PARTY_CONTEXT_INVALID', {
                party_context = row.party_context,
            })
        end
        if seen[row.party_context] then
            return invalid('DUPLICATE_PARTY_CONTEXT', {
                party_context = row.party_context,
            })
        end
        seen[row.party_context] = true
        if not is_integer(row.revision, 0, MAX_SAFE_INTEGER) then
            return invalid('PARTY_REVISION_INVALID', {
                party_context = row.party_context,
            })
        end
        if type_value(row.is_dirty_from_preset) ~= 'boolean' then
            return invalid('IS_DIRTY_BOOLEAN_REQUIRED', {
                party_context = row.party_context,
            })
        end
        if row.leader_character_id ~= nil then
            local checked = validate_content(
                row.leader_character_id,
                'char_',
                'leader_character_id'
            )
            if not checked.ok then
                return invalid('LEADER_ID_INVALID', {
                    party_context = row.party_context,
                })
            end
        end
        if row.formation_template_id ~= nil then
            local checked = validate_content(
                row.formation_template_id,
                'formation_',
                'formation_template_id'
            )
            if not checked.ok then
                return invalid('FORMATION_TEMPLATE_ID_INVALID', {
                    party_context = row.party_context,
                })
            end
        end
        if row.active_preset_id ~= nil then
            local checked = validate_content(
                row.active_preset_id,
                'preset_party_',
                'active_preset_id'
            )
            if not checked.ok then
                return invalid('ACTIVE_PRESET_ID_INVALID', {
                    party_context = row.party_context,
                })
            end
        end
        local member_rows = members_by_context[row.party_context] or {}
        if #member_rows > MAX_MEMBERS then
            return invalid('PARTY_SIZE_OUT_OF_RANGE', {
                party_context = row.party_context,
                count = #member_rows,
            })
        end
        table_sort(member_rows, function(left, right)
            if left.position_index ~= right.position_index then
                return left.position_index < right.position_index
            end
            return bytewise_string_less(left.character_id, right.character_id)
        end)
        parties[#parties + 1] = {
            party_context = row.party_context,
            leader_character_id = row.leader_character_id,
            formation_template_id = row.formation_template_id,
            active_preset_id = row.active_preset_id,
            is_dirty_from_preset = row.is_dirty_from_preset,
            revision = row.revision,
            member_rows = member_rows,
        }
    end

    -- Orphan member rows without a header fail closed.
    local context
    for context in raw_next, members_by_context do
        if not seen[context] then
            return invalid('MEMBER_CONTEXT_MISSING_HEADER', {
                party_context = context,
            })
        end
    end

    table_sort(parties, context_less)
    local copied = {}
    for index = 1, #parties do
        copied[index] = copy_party(parties[index])
    end
    return result_ok({
        party_save_revision = meta.party_save_revision,
        parties = copied,
    })
end

PartySaveCodec.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION

return PartySaveCodec
