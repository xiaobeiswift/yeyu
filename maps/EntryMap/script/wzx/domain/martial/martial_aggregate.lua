local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local MartialErrorCodes = require 'wzx.domain.martial.error_codes'

local MartialAggregate = {}
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
local validate_source_reference = RuntimeId.validate_source_reference

local MAX_SAFE_INTEGER = 9007199254740991
local SOURCE_TYPES = {
    QUEST = true,
    FACTION = true,
    SHOP = true,
    DROP = true,
    EVENT = true,
    ENTITLEMENT = true,
    COMPENSATION = true,
}
local CATEGORY_SLOT = {
    ROUTINE = 'routine_martial_id',
    INTERNAL = 'internal_martial_id',
    LIGHTNESS = 'lightness_martial_id',
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.martial.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(MartialErrorCodes.MARTIAL_ARGUMENT_INVALID, reason, details)
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

local function progress_key(character_id, martial_id)
    return character_id .. '\0' .. martial_id
end

local function copy_ownership(row)
    return {
        martial_id = row.martial_id,
        available_copy_count = row.available_copy_count,
        bound_copy_count = row.bound_copy_count,
        account_unlocked = row.account_unlocked == true,
        revision = row.revision,
    }
end

local function copy_progress(row)
    return {
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

local function copy_loadout(row)
    return {
        character_id = row.character_id,
        routine_martial_id = row.routine_martial_id,
        internal_martial_id = row.internal_martial_id,
        lightness_martial_id = row.lightness_martial_id,
        ai_profile_id = row.ai_profile_id,
        revision = row.revision,
    }
end

local function ownership_list(map)
    local rows = {}
    local martial_id
    local row
    for martial_id, row in raw_next, map do
        rows[#rows + 1] = copy_ownership(row)
    end
    table_sort(rows, function(left, right)
        return bytewise_string_less(left.martial_id, right.martial_id)
    end)
    return rows
end

local function progress_list(map)
    local rows = {}
    local key
    local row
    for key, row in raw_next, map do
        rows[#rows + 1] = copy_progress(row)
    end
    table_sort(rows, function(left, right)
        if left.character_id ~= right.character_id then
            return bytewise_string_less(left.character_id, right.character_id)
        end
        return bytewise_string_less(left.martial_id, right.martial_id)
    end)
    return rows
end

local function loadout_list(map)
    local rows = {}
    local character_id
    local row
    for character_id, row in raw_next, map do
        rows[#rows + 1] = copy_loadout(row)
    end
    table_sort(rows, function(left, right)
        return bytewise_string_less(left.character_id, right.character_id)
    end)
    return rows
end

function MartialAggregate.empty()
    return result_ok({
        ownership_by_martial = {},
        progress_by_key = {},
        loadout_by_character = {},
        book_revision = 0,
    })
end

function MartialAggregate.snapshot(state)
    if type_value(state) ~= 'table' or get_metatable(state) ~= nil then
        return invalid('MARTIAL_STATE_REQUIRED', { field = 'state' })
    end
    if not is_safe_integer(raw_get(state, 'book_revision'), 0, MAX_SAFE_INTEGER) then
        return invalid('BOOK_REVISION_INVALID', { field = 'book_revision' })
    end
    local ownership = raw_get(state, 'ownership_by_martial')
    local progress = raw_get(state, 'progress_by_key')
    local loadout = raw_get(state, 'loadout_by_character')
    if type_value(ownership) ~= 'table' or get_metatable(ownership) ~= nil then
        return invalid('OWNERSHIP_MAP_REQUIRED', { field = 'ownership_by_martial' })
    end
    if type_value(progress) ~= 'table' or get_metatable(progress) ~= nil then
        return invalid('PROGRESS_MAP_REQUIRED', { field = 'progress_by_key' })
    end
    if type_value(loadout) ~= 'table' or get_metatable(loadout) ~= nil then
        return invalid('LOADOUT_MAP_REQUIRED', { field = 'loadout_by_character' })
    end
    return result_ok({
        ownership_rows = ownership_list(ownership),
        progress_rows = progress_list(progress),
        loadout_rows = loadout_list(loadout),
        book_revision = state.book_revision,
    })
end

local function clone_state(state)
    local ownership = {}
    local martial_id
    local row
    for martial_id, row in raw_next, state.ownership_by_martial do
        ownership[martial_id] = copy_ownership(row)
    end
    local progress = {}
    local key
    for key, row in raw_next, state.progress_by_key do
        progress[key] = copy_progress(row)
    end
    local loadout = {}
    local character_id
    for character_id, row in raw_next, state.loadout_by_character do
        loadout[character_id] = copy_loadout(row)
    end
    return {
        ownership_by_martial = ownership,
        progress_by_key = progress,
        loadout_by_character = loadout,
        book_revision = state.book_revision,
    }
end

function MartialAggregate.get_progress(state, character_id, martial_id)
    local snap = MartialAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    local checked_character = validate_content(character_id, 'char_', 'character_id')
    if not checked_character.ok then
        return invalid('CHARACTER_ID_INVALID', { field = 'character_id' })
    end
    local checked_martial = validate_content(martial_id, 'martial_', 'martial_id')
    if not checked_martial.ok then
        return invalid('MARTIAL_ID_INVALID', { field = 'martial_id' })
    end
    local row = state.progress_by_key[progress_key(character_id, martial_id)]
    if row == nil then
        return result_ok(nil)
    end
    return result_ok(copy_progress(row))
end

function MartialAggregate.get_loadout(state, character_id)
    local snap = MartialAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    local checked_character = validate_content(character_id, 'char_', 'character_id')
    if not checked_character.ok then
        return invalid('CHARACTER_ID_INVALID', { field = 'character_id' })
    end
    local row = state.loadout_by_character[character_id]
    if row == nil then
        return result_ok({
            character_id = character_id,
            routine_martial_id = nil,
            internal_martial_id = nil,
            lightness_martial_id = nil,
            ai_profile_id = 'ai_profile_default',
            revision = 0,
        })
    end
    return result_ok(copy_loadout(row))
end

function MartialAggregate.get_ownership(state, martial_id)
    local snap = MartialAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    local checked_martial = validate_content(martial_id, 'martial_', 'martial_id')
    if not checked_martial.ok then
        return invalid('MARTIAL_ID_INVALID', { field = 'martial_id' })
    end
    local row = state.ownership_by_martial[martial_id]
    if row == nil then
        return result_ok({
            martial_id = martial_id,
            available_copy_count = 0,
            bound_copy_count = 0,
            account_unlocked = false,
            revision = 0,
        })
    end
    return result_ok(copy_ownership(row))
end

-- martial_definition is a sealed catalog entry table.
function MartialAggregate.grant_ownership(state, input, martial_definition)
    local snap = MartialAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    if type_value(martial_definition) ~= 'table' then
        return invalid('MARTIAL_DEFINITION_REQUIRED', { field = 'martial_definition' })
    end
    local martial_id = raw_get(input, 'martial_id')
    if martial_id ~= martial_definition.id then
        return invalid('MARTIAL_ID_MISMATCH', { field = 'martial_id' })
    end
    if martial_definition.deprecated == true then
        return fail(MartialErrorCodes.MARTIAL_DEPRECATED, 'MARTIAL_DEPRECATED', {
            martial_id = martial_id,
        })
    end
    local amount = raw_get(input, 'amount')
    if amount == nil then
        amount = 1
    end
    if not is_safe_integer(amount, 1, 9999) then
        return invalid('AMOUNT_INVALID', { field = 'amount' })
    end
    local source_type = raw_get(input, 'source_type')
    if SOURCE_TYPES[source_type] ~= true then
        return invalid('SOURCE_TYPE_INVALID', { field = 'source_type' })
    end
    local source_reference = raw_get(input, 'source_reference')
    local checked_ref = validate_source_reference(source_reference, 'source_reference')
    if not checked_ref.ok then
        return invalid('SOURCE_REFERENCE_INVALID', { field = 'source_reference' })
    end
    local expected = raw_get(input, 'expected_ownership_revision')
    local next_state = clone_state(state)
    local current = next_state.ownership_by_martial[martial_id]
    if current == nil then
        current = {
            martial_id = martial_id,
            available_copy_count = 0,
            bound_copy_count = 0,
            account_unlocked = false,
            revision = 0,
        }
    end
    if expected ~= nil and expected ~= current.revision then
        return fail(MartialErrorCodes.MARTIAL_REVISION_CONFLICT, 'OWNERSHIP_REVISION_CONFLICT', {
            expected = expected,
            actual = current.revision,
        })
    end

    if martial_definition.learn_policy == 'ACCOUNT_UNLOCK' then
        current.account_unlocked = true
    else
        current.available_copy_count = current.available_copy_count + amount
    end
    current.revision = current.revision + 1
    next_state.ownership_by_martial[martial_id] = current
    next_state.book_revision = next_state.book_revision + 1
    return result_ok(next_state)
end

local function character_has_tag(tags, tag)
    local index
    for index = 1, #tags do
        if tags[index] == tag then
            return true
        end
    end
    return false
end

local function check_compatibility(rule, character_level, character_tags, weapon_path, martial_weapon_path)
    if character_level < rule.minimum_character_level then
        return fail(
            MartialErrorCodes.MARTIAL_CHARACTER_LEVEL_TOO_LOW,
            'CHARACTER_LEVEL_TOO_LOW',
            {
                required = rule.minimum_character_level,
                actual = character_level,
            }
        )
    end
    local index
    for index = 1, #rule.required_character_tags do
        if not character_has_tag(character_tags, rule.required_character_tags[index]) then
            return fail(MartialErrorCodes.MARTIAL_INCOMPATIBLE, 'REQUIRED_TAG_MISSING', {
                tag = rule.required_character_tags[index],
            })
        end
    end
    for index = 1, #rule.forbidden_character_tags do
        if character_has_tag(character_tags, rule.forbidden_character_tags[index]) then
            return fail(MartialErrorCodes.MARTIAL_INCOMPATIBLE, 'FORBIDDEN_TAG_PRESENT', {
                tag = rule.forbidden_character_tags[index],
            })
        end
    end
    if martial_weapon_path ~= 'NONE'
        and weapon_path ~= nil
        and weapon_path ~= martial_weapon_path
    then
        return fail(MartialErrorCodes.MARTIAL_WEAPON_MISMATCH, 'WEAPON_PATH_MISMATCH', {
            required = martial_weapon_path,
            actual = weapon_path,
        })
    end
    return result_ok(true)
end

function MartialAggregate.learn(state, input, martial_definition, compatibility_rule)
    local snap = MartialAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local character_id = raw_get(input, 'character_id')
    local martial_id = raw_get(input, 'martial_id')
    local checked_character = validate_content(character_id, 'char_', 'character_id')
    if not checked_character.ok then
        return invalid('CHARACTER_ID_INVALID', { field = 'character_id' })
    end
    if martial_id ~= martial_definition.id then
        return invalid('MARTIAL_ID_MISMATCH', { field = 'martial_id' })
    end
    if martial_definition.deprecated == true then
        return fail(MartialErrorCodes.MARTIAL_DEPRECATED, 'MARTIAL_DEPRECATED', {
            martial_id = martial_id,
        })
    end

    local key = progress_key(character_id, martial_id)
    if state.progress_by_key[key] ~= nil then
        return fail(MartialErrorCodes.MARTIAL_ALREADY_LEARNED, 'MARTIAL_ALREADY_LEARNED', {
            character_id = character_id,
            martial_id = martial_id,
        })
    end

    local character_level = raw_get(input, 'character_level')
    if not is_safe_integer(character_level, 1, 100) then
        return invalid('CHARACTER_LEVEL_INVALID', { field = 'character_level' })
    end
    local character_tags = raw_get(input, 'character_tags')
    if character_tags == nil then
        character_tags = {}
    end
    if type_value(character_tags) ~= 'table'
        or get_metatable(character_tags) ~= nil
        or not is_dense_array(character_tags)
    then
        return invalid('CHARACTER_TAGS_DENSE_ARRAY_REQUIRED', { field = 'character_tags' })
    end
    local weapon_path = raw_get(input, 'weapon_path')
    local compat = check_compatibility(
        compatibility_rule,
        character_level,
        character_tags,
        weapon_path,
        martial_definition.weapon_path
    )
    if not compat.ok then
        return compat
    end

    local level_one = martial_definition.level_rows[1]
    if character_level < level_one.required_character_level then
        return fail(
            MartialErrorCodes.MARTIAL_CHARACTER_LEVEL_TOO_LOW,
            'LEVEL_ONE_CHARACTER_LEVEL_TOO_LOW',
            {
                required = level_one.required_character_level,
                actual = character_level,
            }
        )
    end

    local source_type = raw_get(input, 'source_type')
    if SOURCE_TYPES[source_type] ~= true then
        return invalid('SOURCE_TYPE_INVALID', { field = 'source_type' })
    end
    local source_reference = raw_get(input, 'source_reference')
    local checked_ref = validate_source_reference(source_reference, 'source_reference')
    if not checked_ref.ok then
        return invalid('SOURCE_REFERENCE_INVALID', { field = 'source_reference' })
    end
    local acquisition_receipt_id = raw_get(input, 'acquisition_receipt_id')
    local checked_receipt = validate_content(
        acquisition_receipt_id,
        'receipt_',
        'acquisition_receipt_id'
    )
    -- receipt_ uses derived form; accept via validate_derived
    if not checked_receipt.ok then
        local derived = RuntimeId.validate_derived(acquisition_receipt_id, 'acquisition_receipt_id')
        if not derived.ok then
            return invalid('ACQUISITION_RECEIPT_INVALID', { field = 'acquisition_receipt_id' })
        end
    end

    local next_state = clone_state(state)
    local ownership = next_state.ownership_by_martial[martial_id]
    if ownership == nil then
        ownership = {
            martial_id = martial_id,
            available_copy_count = 0,
            bound_copy_count = 0,
            account_unlocked = false,
            revision = 0,
        }
    end

    if martial_definition.learn_policy == 'ACCOUNT_UNLOCK' then
        if ownership.account_unlocked ~= true then
            return fail(
                MartialErrorCodes.MARTIAL_COPY_INSUFFICIENT,
                'ACCOUNT_UNLOCK_REQUIRED',
                { martial_id = martial_id }
            )
        end
    else
        if ownership.available_copy_count < 1 then
            return fail(
                MartialErrorCodes.MARTIAL_COPY_INSUFFICIENT,
                'COPY_INSUFFICIENT',
                {
                    martial_id = martial_id,
                    available = ownership.available_copy_count,
                }
            )
        end
        ownership.available_copy_count = ownership.available_copy_count - 1
        ownership.bound_copy_count = ownership.bound_copy_count + 1
        ownership.revision = ownership.revision + 1
        next_state.ownership_by_martial[martial_id] = ownership
    end

    next_state.progress_by_key[key] = {
        character_id = character_id,
        martial_id = martial_id,
        level = 1,
        mastery_points = 0,
        source_type = source_type,
        source_reference = source_reference,
        acquisition_receipt_id = acquisition_receipt_id,
        revision = 1,
    }
    next_state.book_revision = next_state.book_revision + 1
    return result_ok(next_state)
end

function MartialAggregate.upgrade(state, input, martial_definition)
    local snap = MartialAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    local character_id = raw_get(input, 'character_id')
    local martial_id = raw_get(input, 'martial_id')
    local target_level = raw_get(input, 'target_level')
    local checked_character = validate_content(character_id, 'char_', 'character_id')
    if not checked_character.ok then
        return invalid('CHARACTER_ID_INVALID', { field = 'character_id' })
    end
    if martial_id ~= martial_definition.id then
        return invalid('MARTIAL_ID_MISMATCH', { field = 'martial_id' })
    end
    local key = progress_key(character_id, martial_id)
    local progress = state.progress_by_key[key]
    if progress == nil then
        return fail(MartialErrorCodes.MARTIAL_NOT_LEARNED, 'MARTIAL_NOT_LEARNED', {
            character_id = character_id,
            martial_id = martial_id,
        })
    end
    if progress.level >= 10 then
        return fail(MartialErrorCodes.MARTIAL_LEVEL_MAX, 'MARTIAL_LEVEL_MAX', {
            martial_id = martial_id,
            level = progress.level,
        })
    end
    if not is_safe_integer(target_level, progress.level + 1, 10) then
        return fail(
            MartialErrorCodes.MARTIAL_LEVEL_SEQUENCE_INVALID,
            'TARGET_LEVEL_INVALID',
            {
                current = progress.level,
                target = target_level,
            }
        )
    end
    -- First slice only allows single-step upgrades (+1). Batch can be layered later.
    if target_level ~= progress.level + 1 then
        return fail(
            MartialErrorCodes.MARTIAL_LEVEL_SEQUENCE_INVALID,
            'SINGLE_STEP_REQUIRED',
            {
                current = progress.level,
                target = target_level,
            }
        )
    end

    local character_level = raw_get(input, 'character_level')
    if not is_safe_integer(character_level, 1, 100) then
        return invalid('CHARACTER_LEVEL_INVALID', { field = 'character_level' })
    end
    local mastery_points = raw_get(input, 'mastery_points')
    if mastery_points == nil then
        mastery_points = progress.mastery_points
    end
    if not is_safe_integer(mastery_points, 0, MAX_SAFE_INTEGER) then
        return invalid('MASTERY_POINTS_INVALID', { field = 'mastery_points' })
    end

    local level_row = martial_definition.level_rows[target_level]
    if character_level < level_row.required_character_level then
        return fail(
            MartialErrorCodes.MARTIAL_CHARACTER_LEVEL_TOO_LOW,
            'CHARACTER_LEVEL_TOO_LOW',
            {
                required = level_row.required_character_level,
                actual = character_level,
            }
        )
    end
    if mastery_points < level_row.mastery_required then
        return fail(
            MartialErrorCodes.MARTIAL_MASTERY_INSUFFICIENT,
            'MASTERY_INSUFFICIENT',
            {
                required = level_row.mastery_required,
                actual = mastery_points,
            }
        )
    end

    local expected = raw_get(input, 'expected_progress_revision')
    if expected ~= nil and expected ~= progress.revision then
        return fail(MartialErrorCodes.MARTIAL_REVISION_CONFLICT, 'PROGRESS_REVISION_CONFLICT', {
            expected = expected,
            actual = progress.revision,
        })
    end

    local next_state = clone_state(state)
    local next_progress = copy_progress(progress)
    next_progress.level = target_level
    next_progress.mastery_points = mastery_points
    next_progress.revision = next_progress.revision + 1
    next_state.progress_by_key[key] = next_progress
    next_state.book_revision = next_state.book_revision + 1
    return result_ok(next_state)
end

local function resolve_equipped_definition(catalog_lookup, martial_id, expected_category)
    if martial_id == nil then
        return result_ok(nil)
    end
    local definition = catalog_lookup(martial_id)
    if definition == nil then
        return fail(MartialErrorCodes.MARTIAL_UNKNOWN, 'MARTIAL_UNKNOWN', {
            martial_id = martial_id,
        })
    end
    if definition.category ~= expected_category then
        return fail(MartialErrorCodes.MARTIAL_CATEGORY_MISMATCH, 'CATEGORY_MISMATCH', {
            martial_id = martial_id,
            expected = expected_category,
            actual = definition.category,
        })
    end
    return result_ok(definition)
end

-- catalog_lookup(martial_id) -> definition or nil
-- compatibility_lookup(rule_id) -> rule or nil
function MartialAggregate.commit_loadout(
    state,
    input,
    catalog_lookup,
    compatibility_lookup
)
    local snap = MartialAggregate.snapshot(state)
    if not snap.ok then
        return snap
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end
    if type_value(catalog_lookup) ~= 'function'
        or type_value(compatibility_lookup) ~= 'function'
    then
        return invalid('CATALOG_LOOKUP_REQUIRED')
    end

    local character_id = raw_get(input, 'character_id')
    local checked_character = validate_content(character_id, 'char_', 'character_id')
    if not checked_character.ok then
        return invalid('CHARACTER_ID_INVALID', { field = 'character_id' })
    end

    local routine_id = raw_get(input, 'routine_martial_id')
    local internal_id = raw_get(input, 'internal_martial_id')
    local lightness_id = raw_get(input, 'lightness_martial_id')
    local ai_profile_id = raw_get(input, 'ai_profile_id')
    if ai_profile_id == nil then
        ai_profile_id = 'ai_profile_default'
    end
    local checked_ai = validate_content(ai_profile_id, 'ai_profile_', 'ai_profile_id')
    if not checked_ai.ok then
        return invalid('AI_PROFILE_ID_INVALID', { field = 'ai_profile_id' })
    end

    local character_level = raw_get(input, 'character_level')
    if not is_safe_integer(character_level, 1, 100) then
        return invalid('CHARACTER_LEVEL_INVALID', { field = 'character_level' })
    end
    local character_tags = raw_get(input, 'character_tags')
    if character_tags == nil then
        character_tags = {}
    end
    if type_value(character_tags) ~= 'table'
        or get_metatable(character_tags) ~= nil
        or not is_dense_array(character_tags)
    then
        return invalid('CHARACTER_TAGS_DENSE_ARRAY_REQUIRED', { field = 'character_tags' })
    end
    local weapon_path = raw_get(input, 'weapon_path')

    local function ensure_learned(martial_id)
        if martial_id == nil then
            return result_ok(true)
        end
        local checked = validate_content(martial_id, 'martial_', 'martial_id')
        if not checked.ok then
            return invalid('MARTIAL_ID_INVALID', { field = 'martial_id' })
        end
        if state.progress_by_key[progress_key(character_id, martial_id)] == nil then
            return fail(MartialErrorCodes.MARTIAL_NOT_LEARNED, 'MARTIAL_NOT_LEARNED', {
                character_id = character_id,
                martial_id = martial_id,
            })
        end
        return result_ok(true)
    end

    local learned = ensure_learned(routine_id)
    if not learned.ok then
        return learned
    end
    learned = ensure_learned(internal_id)
    if not learned.ok then
        return learned
    end
    learned = ensure_learned(lightness_id)
    if not learned.ok then
        return learned
    end

    local routine = resolve_equipped_definition(catalog_lookup, routine_id, 'ROUTINE')
    if not routine.ok then
        return routine
    end
    local internal = resolve_equipped_definition(catalog_lookup, internal_id, 'INTERNAL')
    if not internal.ok then
        return internal
    end
    local lightness = resolve_equipped_definition(catalog_lookup, lightness_id, 'LIGHTNESS')
    if not lightness.ok then
        return lightness
    end

    local equipped = { routine.value, internal.value, lightness.value }
    local exclusive_groups = {}
    local exclusive_ids = {}
    local index
    for index = 1, #equipped do
        local definition = equipped[index]
        if definition ~= nil then
            local rule = compatibility_lookup(definition.compatibility_rule_id)
            if rule == nil then
                return fail(MartialErrorCodes.MARTIAL_INCOMPATIBLE, 'COMPATIBILITY_RULE_MISSING', {
                    martial_id = definition.id,
                    rule_id = definition.compatibility_rule_id,
                })
            end
            local compat = check_compatibility(
                rule,
                character_level,
                character_tags,
                weapon_path,
                definition.weapon_path
            )
            if not compat.ok then
                return compat
            end
            local group_index
            for group_index = 1, #rule.exclusive_groups do
                local group = rule.exclusive_groups[group_index]
                if exclusive_groups[group] ~= nil then
                    return fail(
                        MartialErrorCodes.MARTIAL_LOADOUT_CONFLICT,
                        'EXCLUSIVE_GROUP_CONFLICT',
                        {
                            exclusive_group = group,
                            martial_id = definition.id,
                            conflicting_martial_id = exclusive_groups[group],
                        }
                    )
                end
                exclusive_groups[group] = definition.id
            end
            for group_index = 1, #rule.exclusive_martial_ids do
                exclusive_ids[rule.exclusive_martial_ids[group_index]] = definition.id
            end
        end
    end
    for index = 1, #equipped do
        local definition = equipped[index]
        if definition ~= nil and exclusive_ids[definition.id] ~= nil then
            return fail(
                MartialErrorCodes.MARTIAL_LOADOUT_CONFLICT,
                'EXCLUSIVE_MARTIAL_CONFLICT',
                {
                    martial_id = definition.id,
                    blocked_by = exclusive_ids[definition.id],
                }
            )
        end
    end

    local current = state.loadout_by_character[character_id]
    local current_revision = 0
    if current ~= nil then
        current_revision = current.revision
    end
    local expected = raw_get(input, 'expected_loadout_revision')
    if expected ~= nil and expected ~= current_revision then
        return fail(MartialErrorCodes.MARTIAL_REVISION_CONFLICT, 'LOADOUT_REVISION_CONFLICT', {
            expected = expected,
            actual = current_revision,
        })
    end

    local next_state = clone_state(state)
    next_state.loadout_by_character[character_id] = {
        character_id = character_id,
        routine_martial_id = routine_id,
        internal_martial_id = internal_id,
        lightness_martial_id = lightness_id,
        ai_profile_id = ai_profile_id,
        revision = current_revision + 1,
    }
    next_state.book_revision = next_state.book_revision + 1
    return result_ok(next_state)
end

function MartialAggregate.equipped_contributions(state, character_id, catalog_lookup)
    local loadout = MartialAggregate.get_loadout(state, character_id)
    if not loadout.ok then
        return loadout
    end
    local ids = {
        loadout.value.routine_martial_id,
        loadout.value.internal_martial_id,
        loadout.value.lightness_martial_id,
    }
    local contributions = {}
    local index
    for index = 1, #ids do
        local martial_id = ids[index]
        if martial_id ~= nil then
            local progress = state.progress_by_key[progress_key(character_id, martial_id)]
            if progress == nil then
                return fail(MartialErrorCodes.MARTIAL_NOT_LEARNED, 'MARTIAL_NOT_LEARNED', {
                    character_id = character_id,
                    martial_id = martial_id,
                })
            end
            local definition = catalog_lookup(martial_id)
            if definition == nil then
                return fail(MartialErrorCodes.MARTIAL_UNKNOWN, 'MARTIAL_UNKNOWN', {
                    martial_id = martial_id,
                })
            end
            local level_row = definition.level_rows[progress.level]
            local contribution_index
            for contribution_index = 1, #level_row.contributions do
                contributions[#contributions + 1] = level_row.contributions[contribution_index]
            end
        end
    end
    return result_ok(contributions)
end

MartialAggregate.CATEGORY_SLOT = CATEGORY_SLOT
MartialAggregate.progress_key = progress_key

return MartialAggregate
