-- System 03 party formation presets (structure-only; no ownership until apply).
-- Offline slice: save / apply / delete with per-context limit of 5.

local Ordered = require 'wzx.domain.common.ordered'
local PartyErrorCodes = require 'wzx.domain.party.error_codes'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Utf8Text = require 'wzx.domain.character.utf8_text'

local PartyPreset = {}
local bytewise_string_less = Ordered.bytewise_string_less
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_floor = math.floor
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local utf8_is_valid = Utf8Text.is_valid

local CONTEXTS = {
    PVE_MAIN = true,
    PVE_ALT = true,
    ARENA_DEFENSE = true,
}
local MAX_MEMBERS = 4
local MAX_PRESETS_PER_CONTEXT = 5
local MAX_DISPLAY_NAME_CODEPOINTS = 12
local MAX_SAFE_INTEGER = 9007199254740991
local PRESET_ID_PREFIX = 'preset_party_'

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
        normalized[index] = {
            character_id = character_id,
            position_index = position_index,
            entry_order = entry_order,
            role_tag_override = raw_get(row, 'role_tag_override'),
        }
    end
    return result_ok(sort_members(normalized))
end

local function validate_structure(leader, members)
    local character_ids = {}
    local positions = {}
    local leader_found = false
    local index
    for index = 1, #members do
        local member = members[index]
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
    end
    if not leader_found then
        return fail(
            PartyErrorCodes.PARTY_LEADER_INVALID,
            'LEADER_NOT_IN_PARTY',
            { leader_character_id = leader }
        )
    end
    return result_ok(true)
end

function PartyPreset.copy_preset(preset)
    if type_value(preset) ~= 'table' or get_metatable(preset) ~= nil then
        return invalid('PRESET_TABLE_REQUIRED', { field = 'preset' })
    end
    local members = raw_get(preset, 'member_rows')
    if type_value(members) ~= 'table' or not is_dense_array(members) then
        return invalid('MEMBER_ROWS_REQUIRED', { field = 'member_rows' })
    end
    return result_ok({
        preset_id = raw_get(preset, 'preset_id'),
        display_name = raw_get(preset, 'display_name') or '',
        party_context = raw_get(preset, 'party_context'),
        leader_character_id = raw_get(preset, 'leader_character_id'),
        member_rows = copy_members(members),
        formation_template_id = raw_get(preset, 'formation_template_id'),
        revision = raw_get(preset, 'revision') or 0,
        protected = raw_get(preset, 'protected') == true,
    })
end

function PartyPreset.validate_preset(preset)
    local copied = PartyPreset.copy_preset(preset)
    if not copied.ok then
        return copied
    end
    local value = copied.value

    local checked_id = validate_content(
        value.preset_id,
        PRESET_ID_PREFIX,
        'preset_id'
    )
    if not checked_id.ok then
        return invalid('PRESET_ID_INVALID', { field = 'preset_id' })
    end
    if CONTEXTS[value.party_context] ~= true then
        return fail(
            PartyErrorCodes.PARTY_CONTEXT_INVALID,
            'PARTY_CONTEXT_INVALID',
            { party_context = value.party_context }
        )
    end
    if type_value(value.display_name) ~= 'string' then
        return fail(
            PartyErrorCodes.PARTY_PRESET_NAME_INVALID,
            'DISPLAY_NAME_NOT_STRING',
            { field = 'display_name' }
        )
    end
    local name_ok, name_reason = utf8_is_valid(
        value.display_name,
        MAX_DISPLAY_NAME_CODEPOINTS
    )
    if not name_ok then
        return fail(
            PartyErrorCodes.PARTY_PRESET_NAME_INVALID,
            'DISPLAY_NAME_INVALID',
            {
                field = 'display_name',
                utf8_reason = name_reason,
                max_codepoints = MAX_DISPLAY_NAME_CODEPOINTS,
            }
        )
    end
    if not is_safe_integer(value.revision, 0, MAX_SAFE_INTEGER) then
        return invalid('REVISION_INVALID', { field = 'revision' })
    end

    local leader_checked = validate_content(
        value.leader_character_id,
        'char_',
        'leader_character_id'
    )
    if not leader_checked.ok then
        return fail(
            PartyErrorCodes.PARTY_LEADER_INVALID,
            'LEADER_ID_INVALID',
            { field = 'leader_character_id' }
        )
    end
    if value.formation_template_id ~= nil then
        local template_checked = validate_content(
            value.formation_template_id,
            'formation_',
            'formation_template_id'
        )
        if not template_checked.ok then
            return invalid('FORMATION_TEMPLATE_ID_INVALID', {
                field = 'formation_template_id',
            })
        end
    end

    local members = normalize_member_input(value.member_rows)
    if not members.ok then
        return members
    end
    local structure = validate_structure(value.leader_character_id, members.value)
    if not structure.ok then
        return structure
    end

    value.member_rows = members.value
    return result_ok(value)
end

local function count_context_presets(presets_map, party_context, exclude_id)
    local count = 0
    local preset_id
    local preset
    for preset_id, preset in raw_next, presets_map do
        if exclude_id == nil or preset_id ~= exclude_id then
            if raw_get(preset, 'party_context') == party_context then
                count = count + 1
            end
        end
    end
    return count
end

local function copy_presets_map(presets_map)
    local copied = {}
    local preset_id
    local preset
    for preset_id, preset in raw_next, presets_map do
        local snap = PartyPreset.copy_preset(preset)
        if not snap.ok then
            return snap
        end
        copied[preset_id] = snap.value
    end
    return result_ok(copied)
end

-- presets_map: { [preset_id] = preset }
-- input: preset_id?, display_name, party_context, leader_character_id,
--        member_rows, formation_template_id?, expected_revision? (required on update),
--        protected?
function PartyPreset.save_preset(presets_map, input, options)
    if type_value(presets_map) ~= 'table' or get_metatable(presets_map) ~= nil then
        return invalid('PRESETS_MAP_REQUIRED', { field = 'presets_map' })
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    options = options or {}

    local party_context = raw_get(input, 'party_context')
    if CONTEXTS[party_context] ~= true then
        return fail(
            PartyErrorCodes.PARTY_CONTEXT_INVALID,
            'PARTY_CONTEXT_INVALID',
            { party_context = party_context }
        )
    end

    local preset_id = raw_get(input, 'preset_id')
    local existing = nil
    if preset_id ~= nil then
        local checked = validate_content(preset_id, PRESET_ID_PREFIX, 'preset_id')
        if not checked.ok then
            return invalid('PRESET_ID_INVALID', { field = 'preset_id' })
        end
        existing = presets_map[preset_id]
    else
        local next_id = raw_get(options, 'next_preset_id')
        if type_value(next_id) ~= 'function' then
            return invalid('NEXT_PRESET_ID_REQUIRED', { field = 'options.next_preset_id' })
        end
        local generated = next_id()
        if type_value(generated) ~= 'string' then
            return invalid('NEXT_PRESET_ID_INVALID', { field = 'options.next_preset_id' })
        end
        local checked = validate_content(generated, PRESET_ID_PREFIX, 'preset_id')
        if not checked.ok then
            return invalid('PRESET_ID_INVALID', { field = 'preset_id', generated = generated })
        end
        if presets_map[generated] ~= nil then
            return fail(
                PartyErrorCodes.PARTY_PRESET_CONFLICT,
                'GENERATED_PRESET_ID_EXISTS',
                { preset_id = generated }
            )
        end
        preset_id = generated
    end

    local is_update = existing ~= nil
    if is_update then
        local expected = raw_get(input, 'expected_revision')
        if expected == nil then
            expected = existing.revision
        end
        if expected ~= existing.revision then
            return fail(
                PartyErrorCodes.PARTY_PRESET_CONFLICT,
                'PRESET_REVISION_MISMATCH',
                {
                    preset_id = preset_id,
                    expected = expected,
                    actual = existing.revision,
                }
            )
        end
        if existing.protected == true then
            -- Protected presets may still be overwritten if structure save is allowed;
            -- protection is for delete. Keep content updatable.
        end
        if existing.party_context ~= party_context then
            return fail(
                PartyErrorCodes.PARTY_PRESET_CONFLICT,
                'PRESET_CONTEXT_IMMUTABLE',
                {
                    preset_id = preset_id,
                    existing_context = existing.party_context,
                    party_context = party_context,
                }
            )
        end
    else
        if preset_id ~= nil and presets_map[preset_id] == nil then
            -- explicit new id path
        end
        local count = count_context_presets(presets_map, party_context, nil)
        if count >= MAX_PRESETS_PER_CONTEXT then
            return fail(
                PartyErrorCodes.PARTY_PRESET_LIMIT_REACHED,
                'PRESET_LIMIT_REACHED',
                {
                    party_context = party_context,
                    limit = MAX_PRESETS_PER_CONTEXT,
                    count = count,
                }
            )
        end
    end

    local display_name = raw_get(input, 'display_name')
    if display_name == nil then
        display_name = ''
    end

    local next_revision = 1
    if is_update then
        next_revision = existing.revision + 1
    end

    local candidate = {
        preset_id = preset_id,
        display_name = display_name,
        party_context = party_context,
        leader_character_id = raw_get(input, 'leader_character_id'),
        member_rows = raw_get(input, 'member_rows'),
        formation_template_id = raw_get(input, 'formation_template_id'),
        revision = next_revision,
        protected = raw_get(input, 'protected') == true
            or (is_update and existing.protected == true),
    }
    if is_update and raw_get(input, 'protected') == nil then
        candidate.protected = existing.protected == true
    end

    local validated = PartyPreset.validate_preset(candidate)
    if not validated.ok then
        return validated
    end

    local next_map = copy_presets_map(presets_map)
    if not next_map.ok then
        return next_map
    end
    next_map.value[preset_id] = validated.value

    return result_ok({
        status = is_update and 'UPDATED' or 'CREATED',
        preset = validated.value,
        presets_map = next_map.value,
        created = not is_update,
    })
end

function PartyPreset.delete_preset(presets_map, preset_id, expected_revision)
    if type_value(presets_map) ~= 'table' or get_metatable(presets_map) ~= nil then
        return invalid('PRESETS_MAP_REQUIRED', { field = 'presets_map' })
    end
    local checked = validate_content(preset_id, PRESET_ID_PREFIX, 'preset_id')
    if not checked.ok then
        return invalid('PRESET_ID_INVALID', { field = 'preset_id' })
    end
    local existing = presets_map[preset_id]
    if existing == nil then
        return fail(
            PartyErrorCodes.PARTY_PRESET_NOT_FOUND,
            'PRESET_NOT_FOUND',
            { preset_id = preset_id }
        )
    end
    if existing.protected == true then
        return fail(
            PartyErrorCodes.PARTY_PRESET_PROTECTED,
            'PRESET_PROTECTED',
            { preset_id = preset_id }
        )
    end
    if expected_revision ~= nil and expected_revision ~= existing.revision then
        return fail(
            PartyErrorCodes.PARTY_PRESET_CONFLICT,
            'PRESET_REVISION_MISMATCH',
            {
                preset_id = preset_id,
                expected = expected_revision,
                actual = existing.revision,
            }
        )
    end

    local next_map = copy_presets_map(presets_map)
    if not next_map.ok then
        return next_map
    end
    next_map.value[preset_id] = nil
    local deleted = PartyPreset.copy_preset(existing)
    if not deleted.ok then
        return deleted
    end
    return result_ok({
        status = 'DELETED',
        preset = deleted.value,
        presets_map = next_map.value,
    })
end

-- Apply: full ownership check. All members owned → new party state.
-- Any invalid member → REPAIR_REQUIRED with repair_draft, party unchanged.
function PartyPreset.apply_preset_to_party(party, preset, owned_character_ids, options)
    options = options or {}
    if type_value(party) ~= 'table' or get_metatable(party) ~= nil then
        return invalid('PARTY_TABLE_REQUIRED', { field = 'party' })
    end
    local validated = PartyPreset.validate_preset(preset)
    if not validated.ok then
        return validated
    end
    local ready = validated.value
    if ready.party_context ~= raw_get(party, 'party_context') then
        return fail(
            PartyErrorCodes.PARTY_CONTEXT_INVALID,
            'PRESET_CONTEXT_MISMATCH',
            {
                party_context = raw_get(party, 'party_context'),
                preset_context = ready.party_context,
            }
        )
    end

    local expected = raw_get(options, 'expected_formation_revision')
    local party_revision = raw_get(party, 'revision')
    if expected ~= nil and expected ~= party_revision then
        return fail(
            PartyErrorCodes.PARTY_REVISION_CONFLICT,
            'PARTY_REVISION_MISMATCH',
            {
                expected = expected,
                actual = party_revision,
            }
        )
    end

    local invalid_members = {}
    local valid_members = {}
    local index
    for index = 1, #ready.member_rows do
        local member = ready.member_rows[index]
        if owned_character_ids ~= nil
            and owned_character_ids[member.character_id] ~= true
        then
            invalid_members[#invalid_members + 1] = {
                character_id = member.character_id,
                position_index = member.position_index,
                reason = 'CHARACTER_NOT_OWNED',
            }
        else
            valid_members[#valid_members + 1] = {
                character_id = member.character_id,
                position_index = member.position_index,
                entry_order = member.entry_order,
                role_tag_override = member.role_tag_override,
            }
        end
    end

    if #invalid_members > 0 then
        local repair_leader = ready.leader_character_id
        local leader_still_valid = false
        for index = 1, #valid_members do
            if valid_members[index].character_id == repair_leader then
                leader_still_valid = true
                break
            end
        end
        if not leader_still_valid then
            if #valid_members > 0 then
                repair_leader = valid_members[1].character_id
            else
                repair_leader = nil
            end
        end
        return fail(
            PartyErrorCodes.PARTY_PRESET_REPAIR_REQUIRED,
            'PRESET_HAS_INVALID_MEMBERS',
            {
                preset_id = ready.preset_id,
                invalid_members = invalid_members,
                repair_draft = {
                    party_context = ready.party_context,
                    leader_character_id = repair_leader,
                    member_rows = sort_members(valid_members),
                    formation_template_id = ready.formation_template_id,
                    source_preset_id = ready.preset_id,
                    source_preset_revision = ready.revision,
                },
            }
        )
    end

    local next_party = {
        party_context = ready.party_context,
        leader_character_id = ready.leader_character_id,
        member_rows = copy_members(ready.member_rows),
        formation_template_id = ready.formation_template_id,
        active_preset_id = ready.preset_id,
        is_dirty_from_preset = false,
        revision = (party_revision or 0) + 1,
    }
    return result_ok({
        status = 'APPLIED',
        party = next_party,
        preset = ready,
    })
end

function PartyPreset.presets_map_to_list(presets_map)
    if type_value(presets_map) ~= 'table' then
        return invalid('PRESETS_MAP_REQUIRED', { field = 'presets_map' })
    end
    local list = {}
    local preset_id
    local preset
    for preset_id, preset in raw_next, presets_map do
        local snap = PartyPreset.copy_preset(preset)
        if not snap.ok then
            return snap
        end
        list[#list + 1] = snap.value
    end
    table_sort(list, function(left, right)
        if left.party_context ~= right.party_context then
            return bytewise_string_less(left.party_context, right.party_context)
        end
        return bytewise_string_less(left.preset_id, right.preset_id)
    end)
    return result_ok(list)
end

function PartyPreset.presets_list_to_map(presets_list)
    if type_value(presets_list) ~= 'table' or not is_dense_array(presets_list) then
        return invalid('PRESETS_LIST_REQUIRED', { field = 'presets' })
    end
    local map = {}
    local index
    for index = 1, #presets_list do
        local validated = PartyPreset.validate_preset(presets_list[index])
        if not validated.ok then
            return validated
        end
        if map[validated.value.preset_id] ~= nil then
            return invalid('DUPLICATE_PRESET_ID', {
                preset_id = validated.value.preset_id,
            })
        end
        map[validated.value.preset_id] = validated.value
    end
    return result_ok(map)
end

PartyPreset.MAX_PRESETS_PER_CONTEXT = MAX_PRESETS_PER_CONTEXT
PartyPreset.MAX_DISPLAY_NAME_CODEPOINTS = MAX_DISPLAY_NAME_CODEPOINTS
PartyPreset.PRESET_ID_PREFIX = PRESET_ID_PREFIX

return PartyPreset
