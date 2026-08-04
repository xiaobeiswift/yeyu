local Harness = require 'wzx.tests.harness'
local CharacterSaveCodec = require 'wzx.domain.character.character_save_codec'
local SaveEnvelope = require 'wzx.domain.save.save_envelope'

local assert = Harness.assert
local case = Harness.case

local function deep_copy(value, copies)
    if type(value) ~= 'table' then
        return value
    end
    copies = copies or {}
    if copies[value] ~= nil then
        return copies[value]
    end
    local copy = {}
    copies[value] = copy
    local key
    local child
    for key, child in next, value do
        copy[deep_copy(key, copies)] = deep_copy(child, copies)
    end
    return copy
end

local function receipt(digit)
    return 'receipt_character_v1_' .. string.rep(digit, 64)
end

local function limits(character_rows, talent_rows)
    return {
        limits_version = 1,
        max_character_rows = character_rows or 8,
        max_talent_rows = talent_rows or 32,
    }
end

local function authority(custom_limits)
    local bound = CharacterSaveCodec.bind(custom_limits or limits())
    assert.equal(bound.ok, true)
    return bound.value
end

local function state(character_id, definition_version, revision, talents, custom_name)
    local value = {
        character_id = character_id,
        definition_version = definition_version,
        level = revision + 1,
        experience = revision * 100,
        awakening_rank = 0,
        unlocked_talent_ids = talents,
        created_receipt_id = character_id == 'char_alpha'
            and receipt('a')
            or receipt('b'),
        revision = revision,
    }
    if custom_name ~= nil then
        value.custom_name = custom_name
    end
    return value
end

local function snapshot()
    return {
        revision = 4,
        character_states = {
            state('char_beta', 2, 1, { 'talent_beta' }, ''),
            state('char_alpha', 1, 2, {
                'talent_alpha',
                'talent_shared',
            }),
        },
        talent_unlock_rows = {
            {
                character_id = 'char_beta',
                talent_id = 'talent_beta',
                unlocked_revision = 1,
            },
            {
                character_id = 'char_alpha',
                talent_id = 'talent_shared',
                unlocked_revision = 2,
            },
            {
                character_id = 'char_alpha',
                talent_id = 'talent_alpha',
                unlocked_revision = 0,
            },
        },
    }
end

local function references()
    return {
        character_definition_versions = {
            char_alpha = 1,
            char_beta = 2,
        },
        talent_ids = {
            'talent_alpha',
            'talent_beta',
            'talent_shared',
        },
    }
end

local function encoded_bundle(codec)
    local encoded = codec:encode_current(snapshot())
    assert.equal(encoded.ok, true)
    return encoded.value
end

local function envelope(payload)
    return {
        schema_version = 1,
        revision = 7,
        checkpoint_id = 'checkpoint:character:7',
        content_version = 'content_v1',
        owner_fingerprint = 'owner_v1_' .. string.rep('a', 64),
        payload_checksum = string.rep('b', 64),
        payload = payload,
    }
end

local function run_permutations(source, callback)
    local seed = 19
    local iteration
    for iteration = 1, 50 do
        local copy = deep_copy(source)
        local index
        for index = #copy, 2, -1 do
            seed = (seed * 48271) % 2147483647
            local target = (seed % index) + 1
            copy[index], copy[target] = copy[target], copy[index]
        end
        callback(copy, iteration)
    end
end

return {
    case('bind requires finite explicit limits and returns a sealed authority', function()
        assert.error_reason(
            CharacterSaveCodec.bind(nil),
            'PLAIN_TABLE_REQUIRED'
        )
        assert.error_reason(CharacterSaveCodec.bind({
            limits_version = 1,
            max_character_rows = -1,
            max_talent_rows = 2,
        }), 'CHARACTER_ROW_LIMIT_INVALID')
        assert.error_reason(CharacterSaveCodec.bind({
            limits_version = 2,
            max_character_rows = 1,
            max_talent_rows = 2,
        }), 'LIMITS_VERSION_INVALID')
        assert.error_reason(CharacterSaveCodec.bind({
            limits_version = 1,
            max_character_rows = 1,
            max_talent_rows = 2,
            hidden = true,
        }), 'UNKNOWN_FIELD')

        local source_limits = limits(2, 3)
        local codec = authority(source_limits)
        assert.equal(CharacterSaveCodec.is_authority(codec), true)
        source_limits.max_character_rows = 0
        assert.equal(codec:encode_current(snapshot()).ok, true)
        assert.throws(function()
            codec.decode_current = function()
                return true
            end
        end, 'read-only')

        local hostile_limits = setmetatable(limits(), {})
        assert.error_reason(
            CharacterSaveCodec.bind(hostile_limits),
            'PLAIN_TABLE_REQUIRED'
        )
    end),

    case('encode emits the three direct canonical sections and sorts all rows', function()
        local codec = authority()
        local source = snapshot()
        local before = deep_copy(source)
        local encoded = codec:encode_current(source)
        assert.equal(encoded.ok, true)
        assert.deep_equal(source, before)
        assert.deep_equal(encoded.value, {
            character_metadata = {
                schema_version = 1,
                revision = 4,
            },
            character_rows = {
                {
                    character_id = 'char_alpha',
                    definition_version = 1,
                    level = 3,
                    experience = 200,
                    awakening_rank = 0,
                    created_receipt_id = receipt('a'),
                    revision = 2,
                },
                {
                    character_id = 'char_beta',
                    definition_version = 2,
                    level = 2,
                    experience = 100,
                    awakening_rank = 0,
                    custom_name = '',
                    created_receipt_id = receipt('b'),
                    revision = 1,
                },
            },
            character_talent_rows = {
                {
                    character_id = 'char_alpha',
                    talent_id = 'talent_alpha',
                    unlocked_revision = 0,
                },
                {
                    character_id = 'char_alpha',
                    talent_id = 'talent_shared',
                    unlocked_revision = 2,
                },
                {
                    character_id = 'char_beta',
                    talent_id = 'talent_beta',
                    unlocked_revision = 1,
                },
            },
        })
        assert.is_nil(encoded.value.characters)
    end),

    case('canonical bundle passes SaveEnvelope depth while an extra wrapper fails', function()
        local codec = authority()
        local bundle = encoded_bundle(codec)
        local direct = envelope(bundle)
        assert.equal(SaveEnvelope.validate(direct).ok, true)
        local copied = SaveEnvelope.copy(direct)
        assert.equal(copied.ok, true)
        direct.payload.character_rows[1].level = 99
        assert.equal(copied.value.payload.character_rows[1].level, 3)

        local wrapped = envelope({ characters = encoded_bundle(codec) })
        local rejected = SaveEnvelope.validate(wrapped)
        assert.error_reason(rejected, 'PAYLOAD_INVALID')
        assert.equal(
            rejected.error.details.cause.details.reason,
            'MAXIMUM_TABLE_DEPTH_EXCEEDED'
        )
    end),

    case('ready decode reconstructs aggregates and is fully alias isolated', function()
        local codec = authority()
        local bundle = encoded_bundle(codec)
        local refs = references()
        local decoded = codec:decode_current(bundle, refs)
        assert.equal(decoded.ok, true)
        assert.equal(decoded.value.status, 'READY')
        assert.equal(decoded.value.writable, true)
        assert.equal(decoded.value.revision, 4)
        assert.deep_equal(decoded.value.character_states[1].unlocked_talent_ids, {
            'talent_alpha',
            'talent_shared',
        })
        assert.deep_equal(decoded.value.character_states[2].unlocked_talent_ids, {
            'talent_beta',
        })
        assert.is_nil(decoded.value.character_states[1].custom_name)
        assert.equal(decoded.value.character_states[2].custom_name, '')

        bundle.character_rows[1].level = 99
        refs.character_definition_versions.char_alpha = 99
        assert.equal(decoded.value.character_states[1].level, 3)
        decoded.value.character_states[1].level = 88
        local decoded_again = codec:decode_current(encoded_bundle(codec), references())
        assert.equal(decoded_again.value.character_states[1].level, 3)

        local reencoded = codec:encode_current({
            revision = decoded_again.value.revision,
            character_states = decoded_again.value.character_states,
            talent_unlock_rows = decoded_again.value.talent_unlock_rows,
        })
        assert.deep_equal(reencoded.value, encoded_bundle(codec))
    end),

    case('unknown content isolates the whole bundle without a writable subset', function()
        local codec = authority()
        local bundle = encoded_bundle(codec)
        local refs = references()
        refs.character_definition_versions.char_alpha = nil
        refs.character_definition_versions.char_beta = 1
        refs.talent_ids = { 'talent_alpha' }
        local decoded = codec:decode_current(bundle, refs)
        assert.equal(decoded.ok, true)
        assert.equal(decoded.value.status, 'READ_ONLY_ISOLATED')
        assert.equal(decoded.value.writable, false)
        assert.equal(decoded.value.preserve_original, true)
        assert.is_nil(decoded.value.character_states)
        assert.is_nil(decoded.value.talent_unlock_rows)
        assert.deep_equal(decoded.value.issues, {
            {
                code = 'CHARACTER_CONFIG_MISSING',
                character_id = 'char_alpha',
            },
            {
                code = 'CHARACTER_TALENT_CONFIG_MISSING',
                character_id = 'char_alpha',
                talent_id = 'talent_shared',
            },
            {
                code = 'CHARACTER_DEFINITION_VERSION_UNAVAILABLE',
                character_id = 'char_beta',
                saved_definition_version = 2,
                available_definition_version = 1,
            },
            {
                code = 'CHARACTER_TALENT_CONFIG_MISSING',
                character_id = 'char_beta',
                talent_id = 'talent_beta',
            },
        })
    end),

    case('older saved definitions require explicit migration instead of current rules', function()
        local codec = authority()
        local refs = references()
        refs.character_definition_versions.char_alpha = 2
        local decoded = codec:decode_current(encoded_bundle(codec), refs)
        assert.equal(decoded.ok, true)
        assert.equal(decoded.value.status, 'READ_ONLY_ISOLATED')
        assert.is_nil(decoded.value.character_states)
        assert.is_nil(decoded.value.talent_unlock_rows)
        assert.deep_equal(decoded.value.issues, {
            {
                code = 'CHARACTER_DEFINITION_VERSION_MIGRATION_REQUIRED',
                character_id = 'char_alpha',
                saved_definition_version = 1,
                available_definition_version = 2,
            },
        })
    end),

    case('current DTO validation rejects torn, reordered, duplicate, and stale rows', function()
        local codec = authority()
        local bundle = encoded_bundle(codec)

        local invalid = deep_copy(bundle)
        invalid.character_metadata = nil
        assert.error_reason(codec:validate_current(invalid), 'BUNDLE_SECTION_REQUIRED')

        invalid = deep_copy(bundle)
        invalid.unowned_section = {}
        assert.error_reason(codec:validate_current(invalid), 'UNKNOWN_FIELD')

        invalid = deep_copy(bundle)
        invalid.character_rows[1], invalid.character_rows[2] =
            invalid.character_rows[2], invalid.character_rows[1]
        assert.error_reason(
            codec:validate_current(invalid),
            'CHARACTER_ROWS_NOT_STRICTLY_ORDERED'
        )

        invalid = deep_copy(bundle)
        invalid.character_talent_rows[1], invalid.character_talent_rows[2] =
            invalid.character_talent_rows[2], invalid.character_talent_rows[1]
        assert.error_reason(
            codec:validate_current(invalid),
            'TALENT_ROWS_NOT_STRICTLY_ORDERED'
        )

        invalid = deep_copy(bundle)
        invalid.character_rows[2].created_receipt_id =
            invalid.character_rows[1].created_receipt_id
        assert.error_reason(
            codec:validate_current(invalid),
            'CREATED_RECEIPT_ID_DUPLICATE'
        )

        invalid = deep_copy(bundle)
        invalid.character_talent_rows[1].character_id = 'char_missing'
        assert.error_reason(
            codec:validate_current(invalid),
            'TALENT_PARENT_NOT_FOUND'
        )

        invalid = deep_copy(bundle)
        invalid.character_talent_rows[1].unlocked_revision = 3
        assert.error_reason(
            codec:validate_current(invalid),
            'UNLOCKED_REVISION_ABOVE_CHARACTER'
        )

        invalid = deep_copy(bundle)
        invalid.character_rows[1].revision = 5
        assert.error_reason(
            codec:validate_current(invalid),
            'CHARACTER_REVISION_ABOVE_BUNDLE'
        )
    end),

    case('encode requires exact one-to-one talent metadata and valid parents', function()
        local codec = authority()
        local source = snapshot()
        source.talent_unlock_rows[1] = nil
        assert.error_reason(
            codec:encode_current(source),
            'DENSE_ARRAY_REQUIRED'
        )

        source = snapshot()
        source.talent_unlock_rows[1].talent_id = 'talent_other'
        assert.error_reason(codec:encode_current(source), 'TALENT_SET_MISMATCH')

        source = snapshot()
        source.talent_unlock_rows[2] = deep_copy(source.talent_unlock_rows[1])
        assert.error_reason(codec:encode_current(source), 'TALENT_ID_DUPLICATE')

        source = snapshot()
        source.talent_unlock_rows[1].character_id = 'char_missing'
        assert.error_reason(codec:encode_current(source), 'TALENT_PARENT_NOT_FOUND')

        source = snapshot()
        source.character_states[2].created_receipt_id =
            source.character_states[1].created_receipt_id
        assert.error_reason(
            codec:encode_current(source),
            'CREATED_RECEIPT_ID_DUPLICATE'
        )

        source = snapshot()
        source.character_states[1].unlocked_talent_ids = {
            'talent_beta',
            'talent_beta',
        }
        assert.error_reason(
            codec:encode_current(source),
            'UNLOCKED_TALENTS_NOT_STRICTLY_ORDERED'
        )
    end),

    case('UTF-8 scalar boundaries and all exact row fields are enforced', function()
        local codec = authority()
        local source = snapshot()
        source.character_states[1].custom_name = string.rep('\240\159\140\171', 18)
        assert.equal(codec:encode_current(source).ok, true)

        source.character_states[1].custom_name = string.rep('\240\159\140\171', 19)
        assert.error_reason(codec:encode_current(source), 'CUSTOM_NAME_INVALID')

        source = snapshot()
        source.character_states[1].custom_name = '\237\160\128'
        assert.error_reason(codec:encode_current(source), 'CUSTOM_NAME_INVALID')

        source = snapshot()
        source.character_states[1].awakening_rank = 1
        assert.error_reason(codec:encode_current(source), 'AWAKENING_NOT_AVAILABLE')

        source = snapshot()
        source.character_states[1].created_receipt_id = 'bad::receipt'
        assert.error_reason(codec:encode_current(source), 'CREATED_RECEIPT_ID_INVALID')

        source = snapshot()
        source.character_states[1].shadow_field = true
        assert.error_reason(codec:encode_current(source), 'UNKNOWN_FIELD')
    end),

    case('hostile metatables, sparse arrays, and row budgets fail before copying', function()
        local codec = authority(limits(2, 3))
        local bundle = encoded_bundle(codec)

        local hostile = deep_copy(bundle)
        setmetatable(hostile.character_rows[1], {
            __index = function()
                error('must not run')
            end,
        })
        assert.error_reason(codec:validate_current(hostile), 'PLAIN_TABLE_REQUIRED')

        hostile = deep_copy(bundle)
        setmetatable(hostile.character_talent_rows, {})
        assert.error_reason(
            codec:validate_current(hostile),
            'PLAIN_DENSE_ARRAY_REQUIRED'
        )

        hostile = deep_copy(bundle)
        hostile.character_rows[4] = deep_copy(hostile.character_rows[1])
        assert.error_code(
            codec:validate_current(hostile),
            'CHARACTER_SAVE_LIMIT_EXCEEDED'
        )

        local too_many = snapshot()
        too_many.talent_unlock_rows[4] = deep_copy(too_many.talent_unlock_rows[1])
        assert.error_code(
            codec:encode_current(too_many),
            'CHARACTER_SAVE_LIMIT_EXCEEDED'
        )

        local hostile_snapshot = snapshot()
        setmetatable(hostile_snapshot.character_states[1].unlocked_talent_ids, {})
        assert.error_reason(
            codec:encode_current(hostile_snapshot),
            'PLAIN_DENSE_ARRAY_REQUIRED'
        )
    end),

    case('reference facts are exact, bounded, sorted, plain, and defensively read', function()
        local codec = authority(limits(2, 3))
        local bundle = encoded_bundle(codec)

        local refs = references()
        refs.hidden = true
        assert.error_reason(codec:decode_current(bundle, refs), 'UNKNOWN_FIELD')

        refs = references()
        refs.talent_ids[1], refs.talent_ids[2] = refs.talent_ids[2], refs.talent_ids[1]
        assert.error_reason(
            codec:decode_current(bundle, refs),
            'REFERENCE_TALENTS_NOT_STRICTLY_ORDERED'
        )

        refs = references()
        setmetatable(refs.character_definition_versions, {})
        assert.error_reason(
            codec:decode_current(bundle, refs),
            'PLAIN_TABLE_REQUIRED'
        )

        refs = references()
        refs.character_definition_versions.char_gamma = 1
        assert.error_code(
            codec:decode_current(bundle, refs),
            'CHARACTER_SAVE_LIMIT_EXCEEDED'
        )

        refs = references()
        refs.talent_ids[4] = 'talent_zeta'
        assert.error_code(
            codec:decode_current(bundle, refs),
            'CHARACTER_SAVE_LIMIT_EXCEEDED'
        )
    end),

    case('V1 migration is an isolated idempotent identity and future versions fail', function()
        local codec = authority()
        local bundle = encoded_bundle(codec)
        local before = deep_copy(bundle)
        local migrated = codec:migrate_to_current(bundle)
        assert.equal(migrated.ok, true)
        assert.deep_equal(migrated.value.bundle, before)
        assert.deep_equal(migrated.value.report, {
            from_version = 1,
            to_version = 1,
            changed = false,
            applied_migration_ids = {},
            diagnostics = {},
        })
        bundle.character_rows[1].level = 99
        assert.equal(migrated.value.bundle.character_rows[1].level, 3)

        local repeated = codec:migrate_to_current(migrated.value.bundle)
        assert.deep_equal(repeated.value, migrated.value)

        local future = deep_copy(before)
        future.character_metadata.schema_version = 2
        assert.error_code(
            codec:migrate_to_current(future),
            'CHARACTER_SAVE_VERSION_UNSUPPORTED'
        )

        local missing = deep_copy(before)
        missing.character_metadata.schema_version = nil
        assert.error_code(
            codec:validate_current(missing),
            'CHARACTER_SAVE_VERSION_UNSUPPORTED'
        )

        local zero = deep_copy(before)
        zero.character_metadata.schema_version = 0
        assert.error_code(
            codec:migrate_to_current(zero),
            'CHARACTER_SAVE_VERSION_UNSUPPORTED'
        )

        local hostile_version = setmetatable({ secret = true }, {
            __tostring = function()
                error('must not stringify hostile schema version')
            end,
        })
        local hostile = deep_copy(before)
        hostile.character_metadata.schema_version = hostile_version
        local rejected = codec:validate_current(hostile)
        assert.error_code(rejected, 'CHARACTER_SAVE_VERSION_UNSUPPORTED')
        assert.equal(rejected.error.details.actual_type, 'table')
        assert.is_nil(rejected.error.details.actual)
        hostile_version.secret = false
        assert.is_nil(rejected.error.details.secret)
    end),

    case('shared input arrays are normalized into independent decoded copies', function()
        local codec = authority()
        local source = snapshot()
        local shared = { 'talent_shared' }
        source.character_states[1].unlocked_talent_ids = shared
        source.character_states[2].unlocked_talent_ids = shared
        source.talent_unlock_rows = {
            {
                character_id = 'char_alpha',
                talent_id = 'talent_shared',
                unlocked_revision = 0,
            },
            {
                character_id = 'char_beta',
                talent_id = 'talent_shared',
                unlocked_revision = 0,
            },
        }
        local encoded = codec:encode_current(source)
        assert.equal(encoded.ok, true)
        local decoded = codec:decode_current(encoded.value, references())
        assert.equal(decoded.ok, true)
        decoded.value.character_states[1].unlocked_talent_ids[1] = 'talent_changed'
        assert.equal(
            decoded.value.character_states[2].unlocked_talent_ids[1],
            'talent_shared'
        )
        assert.equal(shared[1], 'talent_shared')
    end),

    case('canonical encode is invariant under bounded input row permutations', function()
        local codec = authority()
        local expected = encoded_bundle(codec)
        local base = snapshot()
        run_permutations(base.character_states, function(permutation)
            local candidate = deep_copy(base)
            candidate.character_states = permutation
            local encoded = codec:encode_current(candidate)
            assert.equal(encoded.ok, true)
            assert.deep_equal(encoded.value, expected)
        end)
        run_permutations(base.talent_unlock_rows, function(permutation)
            local candidate = deep_copy(base)
            candidate.talent_unlock_rows = permutation
            local encoded = codec:encode_current(candidate)
            assert.equal(encoded.ok, true)
            assert.deep_equal(encoded.value, expected)
        end)
    end),

    case('bound save codec retains trusted traversal sort and utf8 primitives', function()
        local Utf8Text = require 'wzx.domain.character.utf8_text'
        local codec = authority()
        local source = snapshot()
        local unknown = snapshot()
        unknown.hidden = true
        local overlong = snapshot()
        overlong.character_states[1].custom_name = string.rep('a', 19)
        local originals = {
            next = _G.next,
            sort = table.sort,
            byte = string.byte,
            codepoint_count = Utf8Text.codepoint_count,
        }

        local ok, failure = xpcall(function()
            _G.next = function()
                return nil
            end
            table.sort = function(target)
                local key
                for key in originals.next, target do
                    target[key] = nil
                end
            end
            string.byte = function()
                error('dynamic string.byte must not be invoked')
            end
            Utf8Text.codepoint_count = function()
                return 0
            end

            local encoded = codec:encode_current(source)
            assert.equal(encoded.ok, true)
            assert.equal(#encoded.value.character_rows, 2)
            assert.equal(
                encoded.value.character_rows[1].character_id,
                'char_alpha'
            )
            assert.equal(
                encoded.value.character_rows[2].character_id,
                'char_beta'
            )
            assert.error_reason(codec:encode_current(unknown), 'UNKNOWN_FIELD')
            assert.error_reason(
                codec:encode_current(overlong),
                'CUSTOM_NAME_INVALID'
            )
        end, debug.traceback)

        _G.next = originals.next
        table.sort = originals.sort
        string.byte = originals.byte
        Utf8Text.codepoint_count = originals.codepoint_count
        if not ok then
            error(failure)
        end
    end),
}
