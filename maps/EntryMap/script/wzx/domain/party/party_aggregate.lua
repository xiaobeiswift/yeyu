local Formation = require 'wzx.domain.contracts.formation'
local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local PartyErrorCodes = require 'wzx.domain.party.error_codes'

local PartyAggregate = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_floor = math.floor
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content

local CONTEXTS = {
    PVE_MAIN = true,
    PVE_ALT = true,
    ARENA_DEFENSE = true,
}
local MAX_MEMBERS = 4
local MAX_SAFE_INTEGER = 9007199254740991

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.party.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(PartyErrorCodes.PARTY_ARGUMENT_INVALID, reason, details)
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function copy_members(rows)
    local copied = {}
    local index
    for index = 1, #rows do
        local row = rows[index]
        copied[index] = {
            character_id = row.character_id,
            position_index = row.position_index,
            entry_order = row.entry_order,
            role_tag_override = row.role_tag_override,
        }
    end
    return copied
end

local function sort_members(rows)
    local sorted = copy_members(rows)
    table_sort(sorted, function(left, right)
        if left.position_index ~= right.position_index then
            return left.position_index < right.position_index
        end
        return bytewise_string_less(left.character_id, right.character_id)
    end)
    return sorted
end

function PartyAggregate.empty(party_context)
    if CONTEXTS[party_context] ~= true then
        return fail(
            PartyErrorCodes.PARTY_CONTEXT_INVALID,
            'PARTY_CONTEXT_INVALID',
            { party_context = party_context }
        )
    end
    return result_ok({
        party_context = party_context,
        leader_character_id = nil,
        member_rows = {},
        formation_template_id = nil,
        active_preset_id = nil,
        is_dirty_from_preset = false,
        revision = 0,
    })
end

function PartyAggregate.snapshot(state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('PARTY_STATE_REQUIRED', { field = 'state' })
    end
    if CONTEXTS[raw_get(state, 'party_context')] ~= true then
        return fail(
            PartyErrorCodes.PARTY_CONTEXT_INVALID,
            'PARTY_CONTEXT_INVALID',
            { party_context = raw_get(state, 'party_context') }
        )
    end
    if not is_safe_integer(raw_get(state, 'revision'), 0, MAX_SAFE_INTEGER) then
        return invalid('REVISION_INVALID', { field = 'revision' })
    end
    local members = raw_get(state, 'member_rows')
    if type_value(members) ~= 'table'
        or get_metatable(members) ~= nil
        or not is_dense_array(members)
    then
        return invalid('MEMBER_ROWS_REQUIRED', { field = 'member_rows' })
    end
    return result_ok({
        party_context = state.party_context,
        leader_character_id = state.leader_character_id,
        member_rows = copy_members(members),
        formation_template_id = state.formation_template_id,
        active_preset_id = state.active_preset_id,
        is_dirty_from_preset = state.is_dirty_from_preset == true,
        revision = state.revision,
    })
end

local function normalize_member_input(rows)
    if type_value(rows) ~= 'table'
        or get_metatable(rows) ~= nil
        or not is_dense_array(rows)
    then
        return invalid('MEMBER_ROWS_DENSE_ARRAY_REQUIRED', { field = 'member_rows' })
    end
    if #rows < 1 or #rows > MAX_MEMBERS then
        return fail(
            PartyErrorCodes.PARTY_SIZE_INVALID,
            'PARTY_SIZE_OUT_OF_RANGE',
            { count = #rows, min = 1, max = MAX_MEMBERS }
        )
    end

    local normalized = {}
    local index
    for index = 1, #rows do
        local row = rows[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return invalid('MEMBER_ROW_TABLE_REQUIRED', {
                field = 'member_rows[' .. tostring(index) .. ']',
            })
        end
        local character_id = raw_get(row, 'character_id')
        local checked = validate_content(character_id, 'char_', 'character_id')
        if not checked.ok then
            return invalid('CHARACTER_ID_INVALID', {
                field = 'member_rows[' .. tostring(index) .. '].character_id',
            })
        end
        local position_index = raw_get(row, 'position_index')
        if not is_safe_integer(position_index, 0, 8) then
            return invalid('POSITION_INDEX_INVALID', {
                field = 'member_rows[' .. tostring(index) .. '].position_index',
            })
        end
        local entry_order = raw_get(row, 'entry_order')
        if entry_order == nil then
            entry_order = index
        end
        if not is_safe_integer(entry_order, 1, MAX_MEMBERS) then
            return invalid('ENTRY_ORDER_INVALID', {
                field = 'member_rows[' .. tostring(index) .. '].entry_order',
            })
        end
        local role_tag = raw_get(row, 'role_tag_override')
        normalized[index] = {
            character_id = character_id,
            position_index = position_index,
            entry_order = entry_order,
            role_tag_override = role_tag,
        }
    end
    return result_ok(sort_members(normalized))
end

-- owned_character_ids is an optional set map { [char_id] = true }.
function PartyAggregate.commit_formation(state, input, owned_character_ids)
    local snap = PartyAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local expected_revision = raw_get(input, 'expected_revision')
    if expected_revision == nil then
        expected_revision = snap.value.revision
    end
    if expected_revision ~= snap.value.revision then
        return fail(
            PartyErrorCodes.PARTY_REVISION_CONFLICT,
            'PARTY_REVISION_MISMATCH',
            {
                expected = expected_revision,
                actual = snap.value.revision,
            }
        )
    end

    local members = normalize_member_input(raw_get(input, 'member_rows'))
    if not members.ok then
        return members
    end

    local leader = raw_get(input, 'leader_character_id')
    local checked_leader = validate_content(leader, 'char_', 'leader_character_id')
    if not checked_leader.ok then
        return fail(
            PartyErrorCodes.PARTY_LEADER_INVALID,
            'LEADER_ID_INVALID',
            { field = 'leader_character_id' }
        )
    end

    local character_ids = {}
    local positions = {}
    local leader_found = false
    local index
    for index = 1, #members.value do
        local member = members.value[index]
        if character_ids[member.character_id] then
            return fail(
                PartyErrorCodes.PARTY_DUPLICATE_MEMBER,
                'DUPLICATE_CHARACTER',
                { character_id = member.character_id }
            )
        end
        if positions[member.position_index] then
            return fail(
                PartyErrorCodes.PARTY_POSITION_OCCUPIED,
                'DUPLICATE_POSITION',
                { position_index = member.position_index }
            )
        end
        character_ids[member.character_id] = true
        positions[member.position_index] = true
        if member.character_id == leader then
            leader_found = true
        end
        if owned_character_ids ~= nil
            and owned_character_ids[member.character_id] ~= true
        then
            return fail(
                PartyErrorCodes.PARTY_MEMBER_UNKNOWN,
                'CHARACTER_NOT_OWNED',
                { character_id = member.character_id }
            )
        end
    end
    if not leader_found then
        return fail(
            PartyErrorCodes.PARTY_LEADER_INVALID,
            'LEADER_NOT_IN_PARTY',
            { leader_character_id = leader }
        )
    end

    local next_state = {
        party_context = snap.value.party_context,
        leader_character_id = leader,
        member_rows = members.value,
        formation_template_id = raw_get(input, 'formation_template_id'),
        active_preset_id = raw_get(input, 'active_preset_id'),
        is_dirty_from_preset = raw_get(input, 'is_dirty_from_preset') == true,
        revision = snap.value.revision + 1,
    }

    local validated = Formation.validate(next_state)
    if not validated.ok then
        return validated
    end
    return result_ok(next_state)
end

function PartyAggregate.swap_positions(state, position_a, position_b, expected_revision)
    local snap = PartyAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    if not is_safe_integer(position_a, 0, 8) or not is_safe_integer(position_b, 0, 8) then
        return invalid('POSITION_INDEX_INVALID', {
            position_a = position_a,
            position_b = position_b,
        })
    end
    if position_a == position_b then
        return result_ok(snap.value)
    end
    if expected_revision ~= nil and expected_revision ~= snap.value.revision then
        return fail(
            PartyErrorCodes.PARTY_REVISION_CONFLICT,
            'PARTY_REVISION_MISMATCH',
            {
                expected = expected_revision,
                actual = snap.value.revision,
            }
        )
    end

    local members = copy_members(snap.value.member_rows)
    local index
    local found_a = false
    local found_b = false
    for index = 1, #members do
        if members[index].position_index == position_a then
            members[index].position_index = position_b
            found_a = true
        elseif members[index].position_index == position_b then
            members[index].position_index = position_a
            found_b = true
        end
    end
    if not found_a and not found_b then
        return invalid('SWAP_POSITIONS_EMPTY', {
            position_a = position_a,
            position_b = position_b,
        })
    end

    return PartyAggregate.commit_formation(snap.value, {
        member_rows = members,
        leader_character_id = snap.value.leader_character_id,
        formation_template_id = snap.value.formation_template_id,
        active_preset_id = snap.value.active_preset_id,
        is_dirty_from_preset = true,
        expected_revision = snap.value.revision,
    })
end

return PartyAggregate
