-- System 18 application orchestration: after LoadGameSave returns READY,
-- import owned sections from loaded envelopes into offline system stores.
-- This does not call SaveStore and does not re-write cloud state.
-- Missing optional targets or absent slots are reported as SKIPPED, not failures.

local CharacterSaveCodec = require 'wzx.domain.character.character_save_codec'
local CharacterReceiptCodec = require 'wzx.domain.character.character_receipt_codec'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local SaveErrorCodes = require 'wzx.domain.save.error_codes'
local TableShape = require 'wzx.domain.common.table_shape'

local HydrateGameRuntime = {}
local error_value = error
local get_metatable = getmetatable
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local set_metatable = setmetatable
local type_value = type
local validate_component = RuntimeId.validate_component

local Service = {}
Service.__index = Service
Service.__newindex = function()
    error_value('hydrate game runtime service is read-only', 2)
end
Service.__metatable = false

local function fail(code, reason, details, retryable)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.save.' .. string.lower(code),
        retryable == true,
        details
    )
end

local function invalid(reason, details)
    return fail(SaveErrorCodes.SAVE_ARGUMENT_INVALID, reason, details, false)
end

local function copy_section(value, path)
    if value == nil then
        return result_ok(nil)
    end
    local copied = TableShape.deep_copy_serializable(value, 3, path)
    if not copied.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'SECTION_COPY_FAILED',
            { path = path, cause = copied.error },
            false
        )
    end
    return result_ok(copied.value)
end

local function envelope_payload(envelopes, slot_id)
    local envelope = envelopes and envelopes[slot_id]
    if type_value(envelope) ~= 'table' then
        return nil
    end
    local payload = raw_get(envelope, 'payload')
    if type_value(payload) ~= 'table' then
        return nil
    end
    return payload
end

local function pick_sections(payload, keys)
    if type_value(payload) ~= 'table' then
        return nil, false
    end
    local bundle = {}
    local present = 0
    local index
    for index = 1, #keys do
        local key = keys[index]
        local value = raw_get(payload, key)
        if value ~= nil then
            present = present + 1
            local copied = copy_section(value, '$.' .. key)
            if not copied.ok then
                return copied, true
            end
            bundle[key] = copied.value
        end
    end
    if present == 0 then
        return nil, false
    end
    if present ~= #keys then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'SECTION_SET_INCOMPLETE',
            {
                expected_keys = keys,
                present_count = present,
            },
            false
        ), true
    end
    return result_ok(bundle), true
end

local function report_entry(system_id, status, extra)
    local entry = {
        system_id = system_id,
        status = status,
    }
    if type_value(extra) == 'table' then
        local key
        local value
        for key, value in raw_next, extra do
            entry[key] = value
        end
    end
    return entry
end

local QUEST_KEYS = {
    'quest_metadata',
    'quest_runs',
    'quest_objectives',
    'quest_event_receipts',
    'revealed_hidden_quests',
    'tracked_quest_runs',
}

local WORLD_KEYS = {
    'world_metadata',
    'world_position',
    'world_discovered_locations',
    'world_flags',
    'world_event_receipts',
    'world_interactable_states',
}

local INVENTORY_KEYS = {
    'inventory_metadata',
    'inventory_stack_rows',
}

local ECONOMY_SLOT4_KEYS = {
    'economy_metadata',
    'currency_balance_rows',
}

local ECONOMY_SLOT5_KEYS = {
    'economy_receipt_metadata',
    'economy_reward_receipts',
    'economy_source_occurrences',
}

local CHARACTER_SLOT3_KEYS = {
    'character_metadata',
    'character_rows',
    'character_talent_rows',
}

local PARTY_KEYS = {
    'party_metadata',
    'party_header_rows',
    'party_member_rows',
    'preset_header_rows',
    'preset_member_rows',
}

local CHARACTER_SLOT5_KEYS = {
    'character_operation_metadata',
    'character_operation_receipts',
}

local function finish_import(system_id, imported, reports, extra)
    if type_value(imported) ~= 'table' or imported.ok ~= true then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'SYSTEM_IMPORT_FAILED',
            {
                system_id = system_id,
                cause_code = imported and imported.error and imported.error.code,
                cause = imported and imported.error and imported.error.details,
            },
            false
        )
    end
    reports[#reports + 1] = report_entry(system_id, 'HYDRATED', extra)
    return result_ok(true)
end

local function hydrate_quest(targets, payload2, reports)
    local bundle, saw = pick_sections(payload2, QUEST_KEYS)
    if saw and not bundle.ok then
        return bundle
    end
    if not saw then
        reports[#reports + 1] = report_entry('quest', 'SKIPPED', {
            reason = 'SECTION_ABSENT',
        })
        return result_ok(true)
    end
    local store = raw_get(targets, 'quest_store')
    if store == nil then
        reports[#reports + 1] = report_entry('quest', 'SKIPPED', {
            reason = 'TARGET_ABSENT',
        })
        return result_ok(true)
    end
    if type_value(store.import_save_bundle) ~= 'function' then
        return invalid('TARGET_IMPORT_UNSUPPORTED', {
            system_id = 'quest',
            method = 'import_save_bundle',
        })
    end
    return finish_import(
        'quest',
        store:import_save_bundle(bundle.value),
        reports
    )
end

local function hydrate_world(targets, payload2, reports)
    local bundle, saw = pick_sections(payload2, WORLD_KEYS)
    if saw and not bundle.ok then
        return bundle
    end
    if not saw then
        reports[#reports + 1] = report_entry('world', 'SKIPPED', {
            reason = 'SECTION_ABSENT',
        })
        return result_ok(true)
    end
    local store = raw_get(targets, 'world_store')
    if store == nil then
        reports[#reports + 1] = report_entry('world', 'SKIPPED', {
            reason = 'TARGET_ABSENT',
        })
        return result_ok(true)
    end
    if type_value(store.import_save_bundle) ~= 'function' then
        return invalid('TARGET_IMPORT_UNSUPPORTED', {
            system_id = 'world',
            method = 'import_save_bundle',
        })
    end
    return finish_import(
        'world',
        store:import_save_bundle(bundle.value),
        reports
    )
end

local function hydrate_party(targets, payload3, reports)
    local bundle, saw = pick_sections(payload3, PARTY_KEYS)
    if saw and not bundle.ok then
        return bundle
    end
    if not saw then
        reports[#reports + 1] = report_entry('party', 'SKIPPED', {
            reason = 'SECTION_ABSENT',
        })
        return result_ok(true)
    end
    local store = raw_get(targets, 'party_store')
    if store == nil then
        reports[#reports + 1] = report_entry('party', 'SKIPPED', {
            reason = 'TARGET_ABSENT',
        })
        return result_ok(true)
    end
    if type_value(store.import_save_bundle) ~= 'function' then
        return invalid('TARGET_IMPORT_UNSUPPORTED', {
            system_id = 'party',
            method = 'import_save_bundle',
        })
    end
    return finish_import(
        'party',
        store:import_save_bundle(bundle.value),
        reports
    )
end

local function hydrate_inventory(targets, payload4, reports)
    local bundle, saw = pick_sections(payload4, INVENTORY_KEYS)
    if saw and not bundle.ok then
        return bundle
    end
    if not saw then
        reports[#reports + 1] = report_entry('inventory', 'SKIPPED', {
            reason = 'SECTION_ABSENT',
        })
        return result_ok(true)
    end
    local store = raw_get(targets, 'inventory_store')
    if store == nil then
        reports[#reports + 1] = report_entry('inventory', 'SKIPPED', {
            reason = 'TARGET_ABSENT',
        })
        return result_ok(true)
    end
    if type_value(store.import_save_bundle) ~= 'function' then
        return invalid('TARGET_IMPORT_UNSUPPORTED', {
            system_id = 'inventory',
            method = 'import_save_bundle',
        })
    end
    return finish_import(
        'inventory',
        store:import_save_bundle(bundle.value),
        reports
    )
end

local function hydrate_economy(targets, payload4, payload5, reports)
    local slot4, saw4 = pick_sections(payload4, ECONOMY_SLOT4_KEYS)
    if saw4 and not slot4.ok then
        return slot4
    end
    local slot5, saw5 = pick_sections(payload5, ECONOMY_SLOT5_KEYS)
    if saw5 and not slot5.ok then
        return slot5
    end
    if not saw4 and not saw5 then
        reports[#reports + 1] = report_entry('economy', 'SKIPPED', {
            reason = 'SECTION_ABSENT',
        })
        return result_ok(true)
    end
    if not saw4 or not saw5 then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'ECONOMY_SLOT_PAIR_INCOMPLETE',
            {
                slot4_present = saw4 == true,
                slot5_present = saw5 == true,
            },
            false
        )
    end
    local store = raw_get(targets, 'economy_store')
    if store == nil then
        reports[#reports + 1] = report_entry('economy', 'SKIPPED', {
            reason = 'TARGET_ABSENT',
        })
        return result_ok(true)
    end
    if type_value(store.import_save_bundles) ~= 'function' then
        return invalid('TARGET_IMPORT_UNSUPPORTED', {
            system_id = 'economy',
            method = 'import_save_bundles',
        })
    end
    return finish_import(
        'economy',
        store:import_save_bundles(slot4.value, slot5.value),
        reports
    )
end

local function default_character_codec(targets)
    local codec = raw_get(targets, 'character_codec')
    if codec ~= nil then
        return result_ok(codec)
    end
    local bound = CharacterSaveCodec.bind({
        limits_version = 1,
        max_character_rows = 64,
        max_talent_rows = 256,
    })
    return bound
end

local function default_character_receipt_codec(targets)
    local codec = raw_get(targets, 'character_receipt_codec')
    if codec ~= nil then
        return result_ok(codec)
    end
    return CharacterReceiptCodec.bind({
        max_receipt_rows = 256,
    })
end

local function hydrate_character(targets, player_save_scope, payload3, payload5, reports)
    local slot3, saw3 = pick_sections(payload3, CHARACTER_SLOT3_KEYS)
    if saw3 and not slot3.ok then
        return slot3
    end
    if not saw3 then
        reports[#reports + 1] = report_entry('character', 'SKIPPED', {
            reason = 'SECTION_ABSENT',
        })
        return result_ok(true)
    end

    local repository = raw_get(targets, 'character_repository')
    if repository == nil then
        reports[#reports + 1] = report_entry('character', 'SKIPPED', {
            reason = 'TARGET_ABSENT',
        })
        return result_ok(true)
    end
    if type_value(repository.import_player_from_save) ~= 'function' then
        return invalid('CHARACTER_IMPORT_UNSUPPORTED', {
            field = 'character_repository.import_player_from_save',
        })
    end

    local codec = default_character_codec(targets)
    if not codec.ok then
        return codec
    end
    local references = raw_get(targets, 'character_references')
    if type_value(references) ~= 'table' then
        return invalid('CHARACTER_REFERENCES_REQUIRED', {
            field = 'character_references',
        })
    end

    local decoded = codec.value:decode_current(slot3.value, references)
    if not decoded.ok then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'CHARACTER_DECODE_FAILED',
            {
                cause_code = decoded.error and decoded.error.code,
                cause = decoded.error and decoded.error.details,
            },
            false
        )
    end
    if decoded.value.status ~= 'READY' then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'CHARACTER_NOT_WRITABLE',
            {
                decode_status = decoded.value.status,
                issues = decoded.value.issues,
            },
            false
        )
    end

    local receipt_rows = {}
    local receipt_revision = 0
    local slot5, saw5 = pick_sections(payload5, CHARACTER_SLOT5_KEYS)
    if saw5 and not slot5.ok then
        return slot5
    end
    if saw5 then
        local receipt_codec = default_character_receipt_codec(targets)
        if not receipt_codec.ok then
            return receipt_codec
        end
        local validated = receipt_codec.value:validate_current(slot5.value)
        if not validated.ok then
            return fail(
                SaveErrorCodes.SAVE_CORRUPT,
                'CHARACTER_RECEIPT_INVALID',
                {
                    cause_code = validated.error and validated.error.code,
                    cause = validated.error and validated.error.details,
                },
                false
            )
        end
        receipt_revision = validated.value.character_operation_metadata.revision
        receipt_rows = validated.value.character_operation_receipts
    end

    local imported = repository:import_player_from_save({
        player_save_scope = player_save_scope,
        revision = decoded.value.revision,
        character_states = decoded.value.character_states,
        receipt_save_revision = receipt_revision,
        receipt_rows = receipt_rows,
    })
    if type_value(imported) ~= 'table' or imported.ok ~= true then
        return fail(
            SaveErrorCodes.SAVE_CORRUPT,
            'CHARACTER_IMPORT_FAILED',
            {
                cause_code = imported and imported.error and imported.error.code,
                cause = imported and imported.error and imported.error.details,
            },
            false
        )
    end
    reports[#reports + 1] = report_entry('character', 'HYDRATED', {
        character_count = #decoded.value.character_states,
        receipt_count = #receipt_rows,
    })
    return result_ok(true)
end

function HydrateGameRuntime.bind(options)
    if options ~= nil then
        if type_value(options) ~= 'table' or get_metatable(options) ~= nil then
            return invalid('OPTIONS_TABLE_REQUIRED', { field = 'options' })
        end
        local key = raw_next(options, nil)
        if key ~= nil then
            return invalid('OPTIONS_MUST_BE_EMPTY', { field = 'options' })
        end
    end
    return result_ok(set_metatable({}, Service))
end

function Service:hydrate(input)
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_TABLE_REQUIRED', { field = 'input' })
    end

    local load_result = raw_get(input, 'load_result')
    if type_value(load_result) ~= 'table' or get_metatable(load_result) ~= nil then
        return invalid('LOAD_RESULT_REQUIRED', { field = 'load_result' })
    end
    if raw_get(load_result, 'mode') ~= 'READY' then
        return fail(
            SaveErrorCodes.SAVE_SESSION_INVALID,
            'LOAD_NOT_READY',
            {
                mode = raw_get(load_result, 'mode'),
            },
            false
        )
    end
    if raw_get(load_result, 'writable') ~= true then
        return fail(
            SaveErrorCodes.SAVE_SESSION_INVALID,
            'LOAD_NOT_WRITABLE',
            {
                writable = raw_get(load_result, 'writable'),
            },
            false
        )
    end

    local player_save_scope = validate_component(
        raw_get(input, 'player_save_scope')
            or raw_get(load_result, 'player_save_scope'),
        'player_save_scope'
    )
    if not player_save_scope.ok then
        return invalid('PLAYER_SAVE_SCOPE_INVALID', {
            field = 'player_save_scope',
        })
    end

    local targets = raw_get(input, 'targets')
    if type_value(targets) ~= 'table' or get_metatable(targets) ~= nil then
        return invalid('TARGETS_TABLE_REQUIRED', { field = 'targets' })
    end

    local envelopes = raw_get(load_result, 'loaded_envelopes')
    if type_value(envelopes) ~= 'table' then
        return invalid('LOADED_ENVELOPES_REQUIRED', {
            field = 'load_result.loaded_envelopes',
        })
    end

    local payload2 = envelope_payload(envelopes, 2)
    local payload3 = envelope_payload(envelopes, 3)
    local payload4 = envelope_payload(envelopes, 4)
    local payload5 = envelope_payload(envelopes, 5)
    local reports = {}

    local step = hydrate_quest(targets, payload2, reports)
    if not step.ok then
        return step
    end
    step = hydrate_world(targets, payload2, reports)
    if not step.ok then
        return step
    end
    step = hydrate_party(targets, payload3, reports)
    if not step.ok then
        return step
    end
    step = hydrate_inventory(targets, payload4, reports)
    if not step.ok then
        return step
    end
    step = hydrate_economy(targets, payload4, payload5, reports)
    if not step.ok then
        return step
    end
    step = hydrate_character(
        targets,
        player_save_scope.value,
        payload3,
        payload5,
        reports
    )
    if not step.ok then
        return step
    end

    return result_ok({
        player_save_scope = player_save_scope.value,
        mode = 'READY',
        systems = reports,
    })
end

return HydrateGameRuntime
