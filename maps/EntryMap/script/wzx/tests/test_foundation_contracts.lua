local Harness = require 'wzx.tests.harness'
local ContentManifest = require 'wzx.domain.contracts.content_manifest'
local DecimalInteger = require 'wzx.domain.common.decimal_integer'
local PlayerProfile = require 'wzx.domain.save.player_profile'
local ReachabilitySourceVector = require 'wzx.domain.contracts.reachability_source_vector'
local SaveManifest = require 'wzx.domain.save.save_manifest'

local case = Harness.case
local assert = Harness.assert
local HASH_A = string.rep('a', 64)
local HASH_B = string.rep('b', 64)
local HASH_C = string.rep('c', 64)

local function content_manifest()
    return {
        content_version = 'content_v1',
        rules_version = 1,
        foundation_contract_version = 1,
        schema_versions = {
            combat_snapshot = 1,
            save_manifest = 1,
        },
        generator_version = 'excelgen_1',
        source_table_hashes = {
            characters = HASH_A,
            martial_arts = HASH_B,
        },
        record_counts = {
            characters = 5,
            martial_arts = 12,
        },
        generated_file_hashes = {
            characters_lua = HASH_B,
            martial_arts_lua = HASH_C,
        },
        stable_id_owner_index = {
            char_hero = 'system_03',
            martial_cloud_step = 'system_05',
        },
        y3_mapping_version = 'mapping_1',
        world_graph_hash = HASH_A,
        traversal_graph_hash = HASH_B,
        event_schema_registry_hash = HASH_C,
        section_owner_registry_hash = HASH_A,
        minimum_readable_content_version = 'content_v1',
    }
end

local function revision_entries()
    local entries = {}
    local slot_id
    for slot_id = 2, 5 do
        local prefix = 'slot_' .. tostring(slot_id) .. '_'
        entries[prefix .. 'schema_version'] = 1
        entries[prefix .. 'revision'] = slot_id * 10
        entries[prefix .. 'checkpoint_id'] = 'checkpoint:slot' .. tostring(slot_id) .. ':10'
        entries[prefix .. 'payload_checksum'] = HASH_A
    end
    return entries
end

local function save_manifest()
    return {
        save_format_version = 1,
        created_revision = 40,
        slot_revision_entries = revision_entries(),
        checkpoint_id = 'checkpoint:all:40',
        last_save_server_time = 1700000000,
        save_seed = 123456789,
        feature_flag_snapshot = { 'arena', 'cloud_save' },
        recovery_epoch = 0,
    }
end

local function player_profile()
    return {
        schema_version = 1,
        revision = 0,
        player_save_scope = 'profile001',
        created_at = 1700000000,
    }
end

local function source_vector()
    return {
        spatial_revision = 7,
        world_revision = 11,
        source_loadout_revision = 3,
        source_progress_revision = 5,
        profile_hash = HASH_A,
        rules_version = 1,
    }
end

return {
    case('content manifest validates all version, hash, count, and owner maps', function()
        local manifest = content_manifest()
        assert.equal(ContentManifest.validate(manifest).ok, true)

        local invalid = content_manifest()
        invalid.record_counts.characters = -1
        assert.error_reason(
            ContentManifest.validate(invalid),
            'NON_NEGATIVE_INTEGER_REQUIRED'
        )

        invalid = content_manifest()
        invalid.schema_versions.save_manifest = 0
        assert.error_reason(
            ContentManifest.validate(invalid),
            'POSITIVE_INTEGER_REQUIRED'
        )

        invalid = content_manifest()
        invalid.generated_file_hashes.characters_lua = 'ABC'
        assert.error_reason(ContentManifest.validate(invalid), 'SHA256_HEX_REQUIRED')

        invalid = content_manifest()
        invalid.unknown_manifest_field = true
        assert.error_reason(ContentManifest.validate(invalid), 'UNKNOWN_FIELD')
    end),

    case('save manifest uses one flat sixteen-field slot revision vector', function()
        local manifest = save_manifest()
        assert.equal(SaveManifest.validate(manifest).ok, true)

        local count = 0
        local key
        for key in pairs(manifest.slot_revision_entries) do
            assert.truthy(key:match('^slot_[2-5]_[a-z_]+$') ~= nil)
            count = count + 1
        end
        assert.equal(count, 16)

        local invalid = save_manifest()
        invalid.slot_revision_entries = {
            slot_2 = {
                schema_version = 1,
                revision = 20,
                checkpoint_id = 'checkpoint:slot2:20',
                payload_checksum = HASH_A,
            },
        }
        assert.error_reason(
            SaveManifest.validate(invalid),
            'UNKNOWN_SLOT_VECTOR_FIELD'
        )

        invalid = save_manifest()
        invalid.slot_revision_entries.slot_3_revision = nil
        assert.error_reason(SaveManifest.validate(invalid), 'INTEGER_OUT_OF_RANGE')

        invalid = save_manifest()
        invalid.save_seed = '123456789'
        assert.error_reason(SaveManifest.validate(invalid), 'INTEGER_OUT_OF_RANGE')

        invalid = save_manifest()
        invalid.feature_flag_snapshot = { 'cloud_save', 'arena' }
        assert.error_reason(
            SaveManifest.validate(invalid),
            'STRICT_ASCENDING_ORDER_REQUIRED'
        )
    end),

    case('player profile validates the private atomic save scope', function()
        assert.equal(PlayerProfile.validate(player_profile()).ok, true)

        local invalid = player_profile()
        invalid.player_save_scope = 'profile:derived'
        assert.error_reason(PlayerProfile.validate(invalid), 'INTERNAL_SCOPE_ID_INVALID')

        invalid = player_profile()
        invalid.player_save_scope = string.rep('p', 65)
        assert.error_reason(PlayerProfile.validate(invalid), 'INTERNAL_SCOPE_ID_INVALID')

        invalid = player_profile()
        invalid.created_at = -1
        assert.error_reason(PlayerProfile.validate(invalid), 'INTEGER_OUT_OF_RANGE')
    end),

    case('reachability source vectors validate and compare every cache dependency', function()
        local left = source_vector()
        local right = source_vector()
        assert.equal(ReachabilitySourceVector.validate(left).ok, true)
        assert.equal(ReachabilitySourceVector.equals(left, right).value, true)

        right.world_revision = 12
        assert.equal(ReachabilitySourceVector.equals(left, right).value, false)
        right = source_vector()
        right.profile_hash = HASH_B
        assert.equal(ReachabilitySourceVector.equals(left, right).value, false)

        local invalid = source_vector()
        invalid.spatial_revision = -1
        assert.error_reason(
            ReachabilitySourceVector.validate(invalid),
            'INTEGER_OUT_OF_RANGE'
        )
    end),

    case('decimal integer encoding is canonical across Lua numeric runtimes', function()
        assert.equal(DecimalInteger.encode(0), '0')
        assert.equal(DecimalInteger.encode(42), '42')
        assert.equal(DecimalInteger.encode(-42), '-42')
        assert.equal(DecimalInteger.encode(9007199254740991), '9007199254740991')
        assert.equal(DecimalInteger.encode(-9007199254740991), '-9007199254740991')
        assert.is_nil(DecimalInteger.encode(1.5))
        assert.is_nil(DecimalInteger.encode(math.huge))
        assert.is_nil(DecimalInteger.encode(-math.huge))
        assert.is_nil(DecimalInteger.encode(0 / 0))
        assert.is_nil(DecimalInteger.encode(9007199254740992))
    end),

    case('foundation contract roots reject scalar payloads fail-closed', function()
        assert.error_reason(ContentManifest.validate('content'), 'TABLE_REQUIRED')
        assert.error_reason(SaveManifest.validate(1), 'TABLE_REQUIRED')
        assert.error_reason(PlayerProfile.validate(false), 'TABLE_REQUIRED')
        assert.error_reason(ReachabilitySourceVector.validate('vector'), 'TABLE_REQUIRED')
    end),
}
