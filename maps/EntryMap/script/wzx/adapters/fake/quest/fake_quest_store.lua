local QuestSession = require 'wzx.domain.quest.quest_session'
local QuestSaveCodec = require 'wzx.domain.quest.quest_save_codec'
local Result = require 'wzx.domain.common.result'

local FakeQuestStore = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type

local Store = {}
Store.__index = Store
Store.__newindex = function()
    error_value('fake quest store is read-only', 2)
end
Store.__metatable = false

local STATES = set_metatable({}, { __mode = 'k' })

local function invalid(reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        'INVALID_ARGUMENT',
        'error.quest.fake_store_invalid',
        false,
        details
    )
end

local function copy_session(session)
    local encoded = QuestSaveCodec.encode(session)
    if not encoded.ok then
        return encoded
    end
    return QuestSaveCodec.decode(encoded.value)
end

function FakeQuestStore.new(options)
    options = options or {}
    if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
        return invalid('OPTIONS_TABLE_REQUIRED')
    end
    local seed = raw_get(options, 'session')
    local session
    if seed == nil then
        session = QuestSession.empty()
    else
        local copied = copy_session(seed)
        if not copied.ok then
            return copied
        end
        session = copied.value
    end
    local view = set_metatable({}, Store)
    STATES[view] = {
        session = session,
    }
    return result_ok(view)
end

function Store:get_session()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return copy_session(state.session)
end

function Store:replace_session(session)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local copied = copy_session(session)
    if not copied.ok then
        return copied
    end
    state.session = copied.value
    return result_ok(true)
end

function Store:encode_bundle()
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    return QuestSaveCodec.encode(state.session)
end

function Store:export_save_bundle()
    return self:encode_bundle()
end

function Store:import_save_bundle(bundle)
    local state = STATES[self]
    if state == nil then
        return invalid('STORE_AUTHORITY_REQUIRED')
    end
    local decoded = QuestSaveCodec.decode(bundle)
    if not decoded.ok then
        return decoded
    end
    state.session = decoded.value
    return result_ok(true)
end

return FakeQuestStore
