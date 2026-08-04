local DomainEvent = require 'wzx.domain.common.domain_event'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Sha256 = require 'wzx.domain.common.sha256'
local TableShape = require 'wzx.domain.common.table_shape'

local CharacterEventBus = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local sha256_hex = Sha256.hex
local type_value = type
local validate_component = RuntimeId.validate_component
local validate_derived = RuntimeId.validate_derived
local validate_content = RuntimeId.validate_content

local Bus = {}
Bus.__index = Bus
Bus.__newindex = function()
    error_value('character event bus is read-only', 2)
end
Bus.__metatable = false

local STATES = setmetatable({}, { __mode = 'k' })
local SOURCE_SYSTEM = '01'

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.character.event_' .. string.lower(code),
        false,
        details
    )
end

local function invalid_argument(reason, details)
    return fail('INVALID_ARGUMENT', reason, details)
end

local function publish(self, event)
    local validated = DomainEvent.validate(event)
    if not validated.ok then
        return validated
    end
    local state = STATES[self]
    if state == nil then
        return invalid_argument('BUS_AUTHORITY_REQUIRED')
    end
    local copied = DomainEvent.copy(event)
    if not copied.ok then
        return copied
    end
    if state.seen[copied.value.event_id] then
        return result_ok({
            accepted = false,
            duplicate = true,
            event_id = copied.value.event_id,
        })
    end
    state.seen[copied.value.event_id] = true
    state.events[#state.events + 1] = copied.value
    local index
    for index = 1, #state.subscribers do
        state.subscribers[index](copied.value)
    end
    return result_ok({
        accepted = true,
        duplicate = false,
        event_id = copied.value.event_id,
        event = copied.value,
    })
end

local function base_event(event_type, aggregate_id, revision, payload, meta)
    meta = meta or {}
    local event_id = meta.event_id
    if event_id == nil then
        event_id = 'character:event:'
            .. event_type
            .. ':'
            .. tostring(revision)
            .. ':'
            .. aggregate_id
    end
    return {
        event_id = event_id,
        event_type = event_type,
        schema_version = 1,
        aggregate_id = aggregate_id,
        revision = revision,
        payload = payload,
        source_system = SOURCE_SYSTEM,
        correlation_id = meta.correlation_id,
        causation_id = meta.causation_id,
        source_occurrence_id = meta.source_occurrence_id,
        occurred_at = meta.occurred_at,
    }
end

function Bus:publish_character_owned(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED')
    end
    local character_id = validate_content(
        raw_get(input, 'character_id'),
        'char_',
        'character_id'
    )
    if not character_id.ok then
        return invalid_argument('CHARACTER_ID_INVALID')
    end
    local receipt_id = validate_derived(
        raw_get(input, 'receipt_id'),
        'receipt_id'
    )
    if not receipt_id.ok then
        return invalid_argument('RECEIPT_ID_INVALID')
    end
    return publish(self, base_event(
        'CharacterOwned',
        character_id.value,
        raw_get(input, 'revision') or 0,
        {
            character_id = character_id.value,
            source_type = raw_get(input, 'source_type'),
            source_reference = raw_get(input, 'source_reference'),
            receipt_id = receipt_id.value,
            already_owned = raw_get(input, 'already_owned') == true,
        },
        {
            event_id = 'character:event:owned:' .. receipt_id.value,
            correlation_id = raw_get(input, 'correlation_id'),
            causation_id = receipt_id.value,
            source_occurrence_id = raw_get(input, 'source_occurrence_id')
                or 'owned1',
            occurred_at = raw_get(input, 'occurred_at'),
        }
    ))
end

function Bus:publish_experience_granted(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED')
    end
    local character_id = validate_content(
        raw_get(input, 'character_id'),
        'char_',
        'character_id'
    )
    if not character_id.ok then
        return invalid_argument('CHARACTER_ID_INVALID')
    end
    local receipt_id = validate_derived(
        raw_get(input, 'receipt_id'),
        'receipt_id'
    )
    if not receipt_id.ok then
        return invalid_argument('RECEIPT_ID_INVALID')
    end
    return publish(self, base_event(
        'CharacterExperienceGranted',
        character_id.value,
        raw_get(input, 'revision') or 0,
        {
            character_id = character_id.value,
            amount = raw_get(input, 'amount'),
            old_experience = raw_get(input, 'old_experience'),
            new_experience = raw_get(input, 'new_experience'),
            reason = raw_get(input, 'reason'),
            receipt_id = receipt_id.value,
        },
        {
            event_id = 'character:event:xp:' .. receipt_id.value,
            correlation_id = raw_get(input, 'correlation_id'),
            causation_id = receipt_id.value,
            source_occurrence_id = raw_get(input, 'source_occurrence_id')
                or 'xp1',
            occurred_at = raw_get(input, 'occurred_at'),
        }
    ))
end

function Bus:publish_level_changed(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED')
    end
    local character_id = validate_content(
        raw_get(input, 'character_id'),
        'char_',
        'character_id'
    )
    if not character_id.ok then
        return invalid_argument('CHARACTER_ID_INVALID')
    end
    local receipt_id = validate_derived(
        raw_get(input, 'receipt_id'),
        'receipt_id'
    )
    if not receipt_id.ok then
        return invalid_argument('RECEIPT_ID_INVALID')
    end
    local unlocked_refs = raw_get(input, 'unlocked_refs') or {}
    return publish(self, base_event(
        'CharacterLevelChanged',
        character_id.value,
        raw_get(input, 'revision') or 0,
        {
            character_id = character_id.value,
            old_level = raw_get(input, 'old_level'),
            new_level = raw_get(input, 'new_level'),
            unlocked_refs = unlocked_refs,
            receipt_id = receipt_id.value,
        },
        {
            event_id = 'character:event:level:' .. receipt_id.value,
            correlation_id = raw_get(input, 'correlation_id'),
            causation_id = receipt_id.value,
            source_occurrence_id = raw_get(input, 'source_occurrence_id')
                or 'level1',
            occurred_at = raw_get(input, 'occurred_at'),
        }
    ))
end

function Bus:publish_renamed(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED')
    end
    local character_id = validate_content(
        raw_get(input, 'character_id'),
        'char_',
        'character_id'
    )
    if not character_id.ok then
        return invalid_argument('CHARACTER_ID_INVALID')
    end
    local receipt_id = validate_derived(
        raw_get(input, 'receipt_id'),
        'receipt_id'
    )
    if not receipt_id.ok then
        return invalid_argument('RECEIPT_ID_INVALID')
    end
    local new_name = raw_get(input, 'new_name')
    if type_value(new_name) ~= 'string' then
        return invalid_argument('NEW_NAME_INVALID')
    end
    local digest, hash_error = sha256_hex(new_name)
    if digest == nil then
        return fail('NAME_DIGEST_FAILED', 'SHA256_FAILED', {
            cause = hash_error,
        })
    end
    return publish(self, base_event(
        'CharacterRenamed',
        character_id.value,
        raw_get(input, 'revision') or 0,
        {
            character_id = character_id.value,
            name_digest = digest,
            name_length = #new_name,
            receipt_id = receipt_id.value,
        },
        {
            event_id = 'character:event:renamed:' .. receipt_id.value,
            correlation_id = raw_get(input, 'correlation_id'),
            causation_id = receipt_id.value,
            source_occurrence_id = raw_get(input, 'source_occurrence_id')
                or 'rename1',
            occurred_at = raw_get(input, 'occurred_at'),
        }
    ))
end

function Bus:publish_talent_unlocked(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid_argument('PLAIN_TABLE_REQUIRED')
    end
    local character_id = validate_content(
        raw_get(input, 'character_id'),
        'char_',
        'character_id'
    )
    if not character_id.ok then
        return invalid_argument('CHARACTER_ID_INVALID')
    end
    local talent_id = validate_content(
        raw_get(input, 'talent_id'),
        'talent_',
        'talent_id'
    )
    if not talent_id.ok then
        return invalid_argument('TALENT_ID_INVALID')
    end
    local receipt_id = validate_derived(
        raw_get(input, 'receipt_id'),
        'receipt_id'
    )
    if not receipt_id.ok then
        return invalid_argument('RECEIPT_ID_INVALID')
    end
    return publish(self, base_event(
        'CharacterTalentUnlocked',
        character_id.value,
        raw_get(input, 'revision') or 0,
        {
            character_id = character_id.value,
            talent_id = talent_id.value,
            source_reference = raw_get(input, 'source_reference'),
            receipt_id = receipt_id.value,
        },
        {
            event_id = 'character:event:talent:'
                .. talent_id.value
                .. ':'
                .. receipt_id.value,
            correlation_id = raw_get(input, 'correlation_id'),
            causation_id = receipt_id.value,
            source_occurrence_id = raw_get(input, 'source_occurrence_id')
                or 'talent1',
            occurred_at = raw_get(input, 'occurred_at'),
        }
    ))
end

function Bus:list()
    local state = STATES[self]
    if state == nil then
        return invalid_argument('BUS_AUTHORITY_REQUIRED')
    end
    local copied = {}
    local index
    for index = 1, #state.events do
        local event_copy = DomainEvent.copy(state.events[index])
        if not event_copy.ok then
            return event_copy
        end
        copied[index] = event_copy.value
    end
    return result_ok(copied)
end

function Bus:subscribe(handler)
    local state = STATES[self]
    if state == nil then
        return invalid_argument('BUS_AUTHORITY_REQUIRED')
    end
    if type_value(handler) ~= 'function' then
        return invalid_argument('HANDLER_REQUIRED')
    end
    state.subscribers[#state.subscribers + 1] = handler
    return result_ok(true)
end

function Bus:clear()
    local state = STATES[self]
    if state == nil then
        return invalid_argument('BUS_AUTHORITY_REQUIRED')
    end
    state.events = {}
    state.seen = {}
    return result_ok(true)
end

function CharacterEventBus.new()
    local bus = set_metatable({}, Bus)
    STATES[bus] = {
        events = {},
        seen = {},
        subscribers = {},
    }
    return result_ok(bus)
end

function CharacterEventBus.is_authority(value)
    return STATES[value] ~= nil
end

return CharacterEventBus
