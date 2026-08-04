local Result = require 'wzx.domain.common.result'
local ErrorCodes = require 'wzx.domain.common.error_codes'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Ordered = require 'wzx.domain.common.ordered'
local TableShape = require 'wzx.domain.common.table_shape'

local SectionOwnerRegistry = {}
local Registry = {}
Registry.__index = Registry
Registry.__newindex = function()
    error('section owner registry is read-only', 2)
end
Registry.__metatable = false
local STATES = setmetatable({}, { __mode = 'k' })

local MAX_SECTION_PATH_BYTES = 192
local STORAGE_KINDS = {
    TABLE_SECTION = true,
    PUBLIC_SECTION = true,
    RANK_INTEGER = true,
    PLATFORM_INTEGER = true,
}
local WRITE_POLICIES = {
    CHECKPOINT = true,
    CRITICAL = true,
    DERIVED = true,
    PLATFORM_CAS = true,
}
local ENTRY_FIELDS = {
    section_key = true,
    storage_kind = true,
    slot_id = true,
    section_path = true,
    owner_system = true,
    schema_version = true,
    write_policy = true,
    validator_id = true,
    codec_id = true,
    sensitive = true,
    public = true,
}

local function is_positive_integer(value)
    return TableShape.is_integer(value, 1)
end

local function validate_section_path(value)
    if type(value) ~= 'string'
        or #value < 1
        or #value > MAX_SECTION_PATH_BYTES
        or value:match('^[a-z][a-z0-9_%.]*$') == nil
        or value:find('..', 1, true) ~= nil
        or value:sub(-1) == '.'
    then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.section_path_invalid',
            false,
            {
                section_path = value,
                max_bytes = MAX_SECTION_PATH_BYTES,
            }
        )
    end

    local component
    for component in value:gmatch('[^.]+') do
        if #component > 64 or component:match('^[a-z][a-z0-9_]*$') == nil then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.section_path_component_invalid',
                false,
                { section_path = value }
            )
        end
    end
    return Result.ok(value)
end

local function validate_entry(entry)
    local entry_keys = Ordered.sorted_string_keys(entry)
    if not entry_keys.ok then
        return entry_keys
    end
    local field
    local field_index
    for field_index = 1, #entry_keys.value do
        field = entry_keys.value[field_index]
        if not ENTRY_FIELDS[field] then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.section_unknown_field',
                false,
                { field = field }
            )
        end
    end
    local key_result = RuntimeId.validate_content(
        entry.section_key,
        nil,
        'section_key'
    )
    if not key_result.ok then
        return key_result
    end

    local path_result = validate_section_path(entry.section_path)
    if not path_result.ok then
        return path_result
    end

    if type(entry.owner_system) ~= 'string'
        or entry.owner_system:match('^[0-9][0-9]$') == nil
    then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.section_owner_system_invalid',
            false,
            { section_key = entry.section_key }
        )
    end

    if not is_positive_integer(entry.slot_id) or entry.slot_id > 319 then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.section_slot_invalid',
            false,
            { section_key = entry.section_key }
        )
    end

    if not is_positive_integer(entry.schema_version) then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.section_schema_version_invalid',
            false,
            { section_key = entry.section_key }
        )
    end

    if not STORAGE_KINDS[entry.storage_kind]
        or not WRITE_POLICIES[entry.write_policy]
        or type(entry.sensitive) ~= 'boolean'
        or type(entry.public) ~= 'boolean'
    then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.section_storage_contract_invalid',
            false,
            { section_key = entry.section_key }
        )
    end

    local validator_result = RuntimeId.validate_content(
        entry.validator_id,
        'validator_',
        'validator_id'
    )
    if not validator_result.ok then
        return validator_result
    end
    local codec_result = RuntimeId.validate_content(
        entry.codec_id,
        'codec_',
        'codec_id'
    )
    if not codec_result.ok then
        return codec_result
    end

    if entry.storage_kind == 'TABLE_SECTION' then
        if entry.slot_id > 5
            or entry.public
            or (entry.write_policy ~= 'CHECKPOINT' and entry.write_policy ~= 'CRITICAL')
        then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.table_section_policy_invalid',
                false,
                { section_key = entry.section_key }
            )
        end
    elseif entry.storage_kind == 'PUBLIC_SECTION' then
        if entry.slot_id < 100 or entry.slot_id > 199
            or not entry.public
            or entry.sensitive
            or entry.write_policy ~= 'DERIVED'
        then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.public_section_policy_invalid',
                false,
                { section_key = entry.section_key }
            )
        end
    elseif entry.storage_kind == 'RANK_INTEGER' then
        if entry.slot_id < 100 or entry.slot_id > 199
            or not entry.public
            or entry.sensitive
            or entry.write_policy ~= 'DERIVED'
        then
            return Result.err(
                ErrorCodes.SCHEMA_VALIDATION_FAILED,
                'error.foundation.rank_integer_policy_invalid',
                false,
                { section_key = entry.section_key }
            )
        end
    elseif entry.slot_id < 200
        or entry.slot_id > 319
        or entry.public
        or not entry.sensitive
        or entry.write_policy ~= 'PLATFORM_CAS'
    then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.platform_integer_policy_invalid',
            false,
            { section_key = entry.section_key }
        )
    end

    return Result.ok(true)
end

local function paths_overlap(left, right)
    if left == right then
        return true
    end
    return left:sub(1, #right + 1) == right .. '.'
        or right:sub(1, #left + 1) == left .. '.'
end

local function is_integer_storage(storage_kind)
    return storage_kind == 'RANK_INTEGER'
        or storage_kind == 'PLATFORM_INTEGER'
end

function SectionOwnerRegistry.new()
    local registry = setmetatable({}, Registry)
    STATES[registry] = {
        entries_by_key = {},
        entries_by_slot = {},
        sealed = false,
    }
    return Result.ok(registry)
end

function Registry:register(entry)
    local state = STATES[self]
    if state.sealed then
        return Result.err(
            ErrorCodes.REGISTRY_SEALED,
            'error.foundation.section_registry_sealed',
            false
        )
    end

    if type(entry) ~= 'table' then
        return Result.err(
            ErrorCodes.SCHEMA_VALIDATION_FAILED,
            'error.foundation.section_entry_invalid',
            false
        )
    end

    local entry_result = validate_entry(entry)
    if not entry_result.ok then
        return entry_result
    end

    if state.entries_by_key[entry.section_key] ~= nil then
        return Result.err(
            ErrorCodes.REGISTRY_DUPLICATE,
            'error.foundation.section_key_duplicate',
            false,
            { section_key = entry.section_key }
        )
    end

    local slot_entries = state.entries_by_slot[entry.slot_id] or {}
    local index
    for index = 1, #slot_entries do
        local existing = slot_entries[index]
        if is_integer_storage(existing.storage_kind)
            or is_integer_storage(entry.storage_kind)
        then
            return Result.err(
                ErrorCodes.SECTION_OWNER_CONFLICT,
                'error.foundation.integer_slot_conflict',
                false,
                {
                    slot_id = entry.slot_id,
                    section_key = entry.section_key,
                    existing_section_key = existing.section_key,
                }
            )
        end
        if paths_overlap(existing.section_path, entry.section_path) then
            return Result.err(
                ErrorCodes.SECTION_OWNER_CONFLICT,
                'error.foundation.section_path_overlap',
                false,
                {
                    slot_id = entry.slot_id,
                    section_path = entry.section_path,
                    existing_section_key = existing.section_key,
                    existing_section_path = existing.section_path,
                }
            )
        end
    end

    local stored = {
        section_key = entry.section_key,
        section_path = entry.section_path,
        slot_id = entry.slot_id,
        owner_system = entry.owner_system,
        schema_version = entry.schema_version,
        storage_kind = entry.storage_kind,
        write_policy = entry.write_policy,
        validator_id = entry.validator_id,
        codec_id = entry.codec_id,
        sensitive = entry.sensitive,
        public = entry.public,
    }
    state.entries_by_key[stored.section_key] = stored
    slot_entries[#slot_entries + 1] = stored
    table.sort(slot_entries, function(left, right)
        return left.section_path < right.section_path
    end)
    state.entries_by_slot[stored.slot_id] = slot_entries
    return Result.ok(stored.section_key)
end

local function copy_entry(entry)
    return {
        section_key = entry.section_key,
        section_path = entry.section_path,
        slot_id = entry.slot_id,
        owner_system = entry.owner_system,
        schema_version = entry.schema_version,
        storage_kind = entry.storage_kind,
        write_policy = entry.write_policy,
        validator_id = entry.validator_id,
        codec_id = entry.codec_id,
        sensitive = entry.sensitive,
        public = entry.public,
    }
end

function Registry:get(section_key)
    local entry = STATES[self].entries_by_key[section_key]
    if entry == nil then
        return Result.err(
            ErrorCodes.REGISTRY_ENTRY_NOT_FOUND,
            'error.foundation.section_entry_not_found',
            false,
            { section_key = section_key }
        )
    end
    return Result.ok(copy_entry(entry))
end

function Registry:find_by_path(slot_id, section_path)
    local path_result = validate_section_path(section_path)
    if not path_result.ok then
        return path_result
    end

    local slot_entries = STATES[self].entries_by_slot[slot_id] or {}
    local index
    for index = 1, #slot_entries do
        if slot_entries[index].section_path == section_path then
            return Result.ok(copy_entry(slot_entries[index]))
        end
    end
    return Result.err(
        ErrorCodes.REGISTRY_ENTRY_NOT_FOUND,
        'error.foundation.section_path_not_found',
        false,
        {
            slot_id = slot_id,
            section_path = section_path,
        }
    )
end

function Registry:authorize_write(owner_system, slot_id, section_path)
    local owner_result = RuntimeId.validate_component(owner_system, 'owner_system')
    if not owner_result.ok then
        return owner_result
    end

    local entry_result = self:find_by_path(slot_id, section_path)
    if not entry_result.ok then
        return entry_result
    end

    local entry = entry_result.value
    if entry.owner_system ~= owner_system then
        return Result.err(
            ErrorCodes.SECTION_WRITE_FORBIDDEN,
            'error.foundation.section_write_forbidden',
            false,
            {
                slot_id = slot_id,
                section_path = section_path,
                owner_system = entry.owner_system,
                requester_system = owner_system,
            }
        )
    end
    return Result.ok(entry)
end

function Registry:list()
    local state = STATES[self]
    local keys = {}
    local section_key
    for section_key in pairs(state.entries_by_key) do
        keys[#keys + 1] = section_key
    end
    table.sort(keys, Ordered.bytewise_string_less)

    local entries = {}
    local index
    for index = 1, #keys do
        entries[index] = copy_entry(state.entries_by_key[keys[index]])
    end
    return Result.ok(entries)
end

function Registry:seal()
    STATES[self].sealed = true
    return Result.ok(true)
end

function Registry:is_sealed()
    return STATES[self].sealed
end

return SectionOwnerRegistry
