local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TableShape = require 'wzx.domain.common.table_shape'
local DialogueErrorCodes = require 'wzx.domain.dialogue.error_codes'
local DialogueSession = require 'wzx.domain.dialogue.dialogue_session'

local DialogueSaveCodec = {}
local bytewise_string_less = Ordered.bytewise_string_less
local is_integer = TableShape.is_integer
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local table_sort = table.sort
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local CURRENT_SCHEMA_VERSION = 1
local MAX_MEMORIES = 512
local MAX_COMPLETED = 512
local MAX_EVENT_RECEIPTS = 2048
local MAX_SAFE_INTEGER = 9007199254740991

local BUNDLE_FIELDS = {
    dialogue_metadata = true,
    dialogue_memories = true,
    dialogue_completed = true,
    dialogue_event_receipts = true,
}
local METADATA_FIELDS = {
    schema_version = true,
    facts_revision = true,
}
local MEMORY_FIELDS = {
    memory_key = true,
    memory_value = true,
}
local COMPLETED_FIELDS = {
    completion_key = true,
    dialogue_id = true,
    count = true,
    graph_version = true,
}
local EVENT_FIELDS = {
    event_id = true,
    event_type = true,
    receipt_id = true,
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
        DialogueErrorCodes.DIALOGUE_SAVE_INVALID,
        'error.dialogue.save_invalid',
        reason,
        details
    )
end

local function limit_exceeded(reason, details)
    return failure(
        DialogueErrorCodes.DIALOGUE_SAVE_LIMIT_EXCEEDED,
        'error.dialogue.save_limit_exceeded',
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
        if type_value(key) ~= 'string' or allowed[key] ~= true then
            return invalid('UNKNOWN_FIELD', { field = path .. '.' .. tostring(key) })
        end
    end
    return nil
end

local function sorted_keys(map)
    local keys = {}
    local key
    for key in raw_next, map do
        keys[#keys + 1] = key
    end
    table_sort(keys, bytewise_string_less)
    return keys
end

function DialogueSaveCodec.encode(facts)
    if type_value(facts) ~= 'table' then
        return invalid('FACTS_REQUIRED')
    end
    if not is_integer(facts.facts_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('FACTS_REVISION_INVALID')
    end

    local memory_keys = sorted_keys(facts.memories or {})
    if #memory_keys > MAX_MEMORIES then
        return limit_exceeded('MEMORY_LIMIT', { count = #memory_keys })
    end
    local memory_rows = {}
    local index
    for index = 1, #memory_keys do
        local key = memory_keys[index]
        local checked = validate_content(key, 'dmem_', 'memory_key')
        if not checked.ok then
            return invalid('MEMORY_KEY_INVALID', { memory_key = key })
        end
        memory_rows[index] = {
            memory_key = key,
            memory_value = facts.memories[key],
        }
    end

    local completed_keys = sorted_keys(facts.completed or {})
    if #completed_keys > MAX_COMPLETED then
        return limit_exceeded('COMPLETED_LIMIT', { count = #completed_keys })
    end
    local completed_rows = {}
    for index = 1, #completed_keys do
        local key = completed_keys[index]
        local row = facts.completed[key]
        if type_value(row) ~= 'table' then
            return invalid('COMPLETED_ROW_INVALID', { completion_key = key })
        end
        completed_rows[index] = {
            completion_key = row.completion_key or key,
            dialogue_id = row.dialogue_id,
            count = row.count,
            graph_version = row.graph_version,
        }
    end

    local event_keys = sorted_keys(facts.event_receipts or {})
    if #event_keys > MAX_EVENT_RECEIPTS then
        return limit_exceeded('EVENT_RECEIPT_LIMIT', { count = #event_keys })
    end
    local event_rows = {}
    for index = 1, #event_keys do
        local key = event_keys[index]
        local row = facts.event_receipts[key]
        event_rows[index] = {
            event_id = row.event_id or key,
            event_type = row.event_type,
            receipt_id = row.receipt_id,
        }
    end

    return result_ok({
        dialogue_metadata = {
            schema_version = CURRENT_SCHEMA_VERSION,
            facts_revision = facts.facts_revision,
        },
        dialogue_memories = memory_rows,
        dialogue_completed = completed_rows,
        dialogue_event_receipts = event_rows,
    })
end

function DialogueSaveCodec.decode(bundle)
    if type_value(bundle) ~= 'table' then
        return invalid('BUNDLE_REQUIRED')
    end
    local unknown = no_unknown_fields(bundle, BUNDLE_FIELDS, '$')
    if unknown ~= nil then
        return unknown
    end

    local metadata = bundle.dialogue_metadata
    if type_value(metadata) ~= 'table' then
        return invalid('METADATA_REQUIRED')
    end
    unknown = no_unknown_fields(metadata, METADATA_FIELDS, 'dialogue_metadata')
    if unknown ~= nil then
        return unknown
    end
    if metadata.schema_version ~= CURRENT_SCHEMA_VERSION then
        return failure(
            DialogueErrorCodes.DIALOGUE_SAVE_VERSION_UNSUPPORTED,
            'error.dialogue.save_version_unsupported',
            'SCHEMA_VERSION_UNSUPPORTED',
            { schema_version = metadata.schema_version }
        )
    end
    if not is_integer(metadata.facts_revision, 0, MAX_SAFE_INTEGER) then
        return invalid('FACTS_REVISION_INVALID')
    end

    local facts = DialogueSession.empty()
    facts.facts_revision = metadata.facts_revision

    local memories = bundle.dialogue_memories or {}
    local index
    for index = 1, #memories do
        local row = memories[index]
        unknown = no_unknown_fields(row, MEMORY_FIELDS, 'dialogue_memories[' .. index .. ']')
        if unknown ~= nil then
            return unknown
        end
        local checked = validate_content(row.memory_key, 'dmem_', 'memory_key')
        if not checked.ok then
            return invalid('MEMORY_KEY_INVALID', { memory_key = row.memory_key })
        end
        facts.memories[row.memory_key] = row.memory_value
    end

    local completed = bundle.dialogue_completed or {}
    for index = 1, #completed do
        local row = completed[index]
        unknown = no_unknown_fields(row, COMPLETED_FIELDS, 'dialogue_completed[' .. index .. ']')
        if unknown ~= nil then
            return unknown
        end
        local key_check = validate_content(row.completion_key, 'dcomp_', 'completion_key')
        if not key_check.ok then
            return invalid('COMPLETION_KEY_INVALID', { completion_key = row.completion_key })
        end
        local dialogue_check = validate_content(row.dialogue_id, 'dialogue_', 'dialogue_id')
        if not dialogue_check.ok then
            return invalid('DIALOGUE_ID_INVALID', { dialogue_id = row.dialogue_id })
        end
        if not is_integer(row.count, 1, MAX_SAFE_INTEGER) then
            return invalid('COMPLETED_COUNT_INVALID')
        end
        if not is_integer(row.graph_version, 1, MAX_SAFE_INTEGER) then
            return invalid('GRAPH_VERSION_INVALID')
        end
        facts.completed[row.completion_key] = {
            completion_key = row.completion_key,
            dialogue_id = row.dialogue_id,
            count = row.count,
            graph_version = row.graph_version,
        }
    end

    local events = bundle.dialogue_event_receipts or {}
    for index = 1, #events do
        local row = events[index]
        unknown = no_unknown_fields(row, EVENT_FIELDS, 'dialogue_event_receipts[' .. index .. ']')
        if unknown ~= nil then
            return unknown
        end
        local event_check = validate_derived(row.event_id, 'event_id')
        if not event_check.ok then
            return invalid('EVENT_ID_INVALID', { event_id = row.event_id })
        end
        facts.event_receipts[row.event_id] = {
            event_id = row.event_id,
            event_type = row.event_type,
            receipt_id = row.receipt_id,
        }
    end

    return result_ok(facts)
end

return DialogueSaveCodec
