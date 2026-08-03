local Harness = require 'wzx.tests.harness'
local EventSchemaRegistry = require 'wzx.config.schema.event_schema_registry'
local FeatureFlags = require 'wzx.config.feature_flags'
local Foundation = require 'wzx.config.schema.foundation'
local Result = require 'wzx.domain.common.result'
local SchemaRegistry = require 'wzx.config.schema.schema_registry'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local Versions = require 'wzx.config.schema.versions'

local case = Harness.case
local assert = Harness.assert
local HASH_A = string.rep('a', 64)
local HASH_B = string.rep('b', 64)

local function event_schema(event_type, schema_version, producer_system)
    schema_version = schema_version or 1
    return {
        event_type = event_type or 'QuestStarted',
        producer_system = producer_system or '09',
        schema_version = schema_version,
        consumer_systems = {
            '10',
            { system_id = '17', minimum_schema_version = 1 },
        },
        required_payload_fields = {
            {
                name = 'quest_id',
                value_type = 'ID',
                sensitive = false,
                constraint_id = 'constraint_quest_id',
            },
        },
        optional_payload_fields = {
            {
                name = 'source_note',
                value_type = 'STRING',
                sensitive = false,
                default_semantics = 'ABSENT_MEANS_UNKNOWN',
            },
        },
        payload_schema_hash = schema_version == 1 and HASH_A or HASH_B,
        payload_validator = function(payload)
            if type(payload) ~= 'table' or type(payload.quest_id) ~= 'string' then
                return Result.err(
                    'SCHEMA_VALIDATION_FAILED',
                    'error.test.quest_payload_invalid',
                    false
                )
            end
            return Result.ok(payload)
        end,
        envelope_kind = 'DOMAIN_EVENT',
        persistence_policy = 'TRANSIENT',
    }
end

local function table_section(section_key, section_path, owner_system, slot_id)
    return {
        section_key = section_key,
        storage_kind = 'TABLE_SECTION',
        slot_id = slot_id or 2,
        section_path = section_path,
        owner_system = owner_system,
        schema_version = 1,
        write_policy = 'CHECKPOINT',
        validator_id = 'validator_' .. section_key .. '_v1',
        codec_id = 'codec_' .. section_key .. '_v1',
        sensitive = true,
        public = false,
    }
end

local function integer_section(section_key, slot_id)
    return {
        section_key = section_key,
        storage_kind = 'RANK_INTEGER',
        slot_id = slot_id,
        section_path = section_key,
        owner_system = '20',
        schema_version = 1,
        write_policy = 'DERIVED',
        validator_id = 'validator_' .. section_key .. '_v1',
        codec_id = 'codec_' .. section_key .. '_v1',
        sensitive = false,
        public = true,
    }
end

local function public_section(section_key, slot_id)
    local value = integer_section(section_key, slot_id)
    value.storage_kind = 'PUBLIC_SECTION'
    return value
end

local function all_release_flags()
    return {
        cloud_save = true,
        open_archive = true,
        server_refresh = true,
        arena = true,
        platform_store = true,
        paid_gacha = true,
    }
end

local function all_capabilities()
    return {
        cloud_save = 'available',
        open_archive = 'available',
        server_clock = 'available',
        checkpoint_readback = 'available',
        rank_identity = 'available',
        store_recovery = 'available',
        gacha_audit_export = 'available',
        integer_cas = 'available',
        integer_request_query = 'available',
        random_pool_atomicity = 'available',
        random_pool_request_query = 'available',
    }
end

return {
    case('generic schema registry is ordered, defensive, and sealable', function()
        local created = SchemaRegistry.new({
            registry_name = 'TestRegistry',
            id_field = 'id',
        })
        assert.equal(created.ok, true)
        local registry = created.value

        local source = { id = 'zeta', nested = { value = 7 } }
        assert.equal(registry:register(source).ok, true)
        source.nested.value = 99
        assert.equal(registry:get('zeta').value.nested.value, 7)

        local fetched = registry:get('zeta').value
        fetched.nested.value = 42
        assert.equal(registry:get('zeta').value.nested.value, 7)

        assert.equal(registry:register({ id = 'alpha' }).ok, true)
        local listed = registry:list()
        assert.equal(listed.ok, true)
        assert.equal(listed.value[1].id, 'alpha')
        assert.equal(listed.value[2].id, 'zeta')
        assert.error_code(registry:register({ id = 'zeta' }), 'REGISTRY_DUPLICATE')

        assert.equal(registry:seal().ok, true)
        assert.equal(registry:is_sealed(), true)
        assert.error_code(registry:register({ id = 'later' }), 'REGISTRY_SEALED')
    end),

    case('all registry instances reject method shadowing without breaking use', function()
        local generic = SchemaRegistry.new({
            registry_name = 'ReadOnlyRegistry',
            id_field = 'id',
        }).value
        assert.throws(function()
            generic.register = function()
                return Result.ok(true)
            end
        end, 'schema registry is read-only')
        assert.throws(function()
            generic.get = false
        end, 'schema registry is read-only')
        assert.equal(generic:register({ id = 'alpha' }).ok, true)
        assert.equal(generic:get('alpha').value.id, 'alpha')
        assert.equal(generic:seal().ok, true)
        assert.equal(generic:is_sealed(), true)

        local events = EventSchemaRegistry.new().value
        assert.throws(function()
            events.register = function()
                return Result.ok(true)
            end
        end, 'event schema registry is read-only')
        assert.throws(function()
            events.get = false
        end, 'event schema registry is read-only')
        assert.throws(function()
            events.validate_payload = function()
                return Result.ok(true)
            end
        end, 'event schema registry is read-only')
        assert.equal(events:register(event_schema('ReadOnlyEvent')).ok, true)
        assert.equal(events:get('ReadOnlyEvent', 1).ok, true)
        assert.equal(events:validate_payload('ReadOnlyEvent', 1, {
            quest_id = 'quest_read_only',
        }).ok, true)
        assert.equal(events:seal().ok, true)
        assert.equal(events:is_sealed(), true)

        local sections = SectionOwnerRegistry.new().value
        assert.throws(function()
            sections.register = function()
                return Result.ok(true)
            end
        end, 'section owner registry is read-only')
        assert.throws(function()
            sections.get = false
        end, 'section owner registry is read-only')
        assert.throws(function()
            sections.authorize_write = function()
                return Result.ok(true)
            end
        end, 'section owner registry is read-only')
        assert.equal(sections:register(table_section(
            'read_only_section',
            'read_only_section',
            '18',
            2
        )).ok, true)
        assert.equal(sections:get('read_only_section').ok, true)
        assert.equal(sections:authorize_write(
            '18',
            2,
            'read_only_section'
        ).ok, true)
        assert.equal(sections:seal().ok, true)
        assert.equal(sections:is_sealed(), true)
    end),

    case('generic schema registry rejects cycles instead of storing aliases', function()
        local registry = SchemaRegistry.new({
            registry_name = 'CycleRegistry',
            id_field = 'id',
        }).value
        local cyclic = { id = 'cyclic' }
        cyclic.self = cyclic
        assert.error_code(registry:register(cyclic), 'SCHEMA_VALIDATION_FAILED')
        assert.equal(registry:contains('cyclic'), false)
    end),

    case('generic schema registry contains thrown extension callbacks fail-closed', function()
        local callback_names = {
            'normalize_entry',
            'validate_id',
            'validate_entry',
        }
        local index
        for index = 1, #callback_names do
            local callback_name = callback_names[index]
            local options = {
                registry_name = 'ThrowingRegistry' .. tostring(index),
                id_field = 'id',
            }
            options[callback_name] = function()
                error(callback_name .. ' boom')
            end
            local registry = SchemaRegistry.new(options).value
            local succeeded, registered = pcall(function()
                return registry:register({ id = 'alpha' })
            end)
            assert.equal(succeeded, true, callback_name .. ' escaped the registry')
            assert.error_code(registered, 'SCHEMA_VALIDATION_FAILED')
            assert.equal(registry:contains('alpha'), false)
        end
    end),

    case('event schema registry validates versions, consumers, and payloads', function()
        local registry = EventSchemaRegistry.new().value
        assert.equal(registry:register(event_schema()).ok, true)
        assert.equal(registry:contains('QuestStarted', 1), true)
        assert.equal(registry:contains('QuestStarted', 2), false)

        local stored = registry:get('QuestStarted', 1)
        assert.equal(stored.ok, true)
        assert.deep_equal(stored.value.consumer_systems, {
            { system_id = '10', minimum_schema_version = 1 },
            { system_id = '17', minimum_schema_version = 1 },
        })
        assert.deep_equal(stored.value.required_payload_fields, {
            {
                name = 'quest_id',
                value_type = 'ID',
                sensitive = false,
                constraint_id = 'constraint_quest_id',
            },
        })
        assert.equal(stored.value.payload_schema_hash, HASH_A)

        local payload = registry:validate_payload('QuestStarted', 1, {
            quest_id = 'quest_main',
        })
        assert.equal(payload.ok, true)
        assert.error_code(
            registry:validate_payload('QuestStarted', 2, { quest_id = 'quest_main' }),
            'REGISTRY_ENTRY_NOT_FOUND'
        )
        assert.error_code(
            registry:validate_payload('QuestStarted', 1, {}),
            'SCHEMA_VALIDATION_FAILED'
        )

        local unsorted = event_schema('QuestCompleted')
        unsorted.consumer_systems = { '17', '10' }
        assert.error_code(registry:register(unsorted), 'SCHEMA_VALIDATION_FAILED')
        assert.error_code(registry:register(event_schema()), 'REGISTRY_DUPLICATE')
    end),

    case('event schema families retain every version and expose the latest', function()
        local registry = EventSchemaRegistry.new().value
        assert.equal(registry:register(event_schema('QuestAdvanced', 2)).ok, true)
        assert.equal(registry:register(event_schema('QuestAdvanced', 1)).ok, true)

        assert.equal(registry:get('QuestAdvanced', 1).value.payload_schema_hash, HASH_A)
        assert.equal(registry:get('QuestAdvanced', 2).value.payload_schema_hash, HASH_B)
        assert.equal(registry:get_latest('QuestAdvanced').value.schema_version, 2)
        local listed = registry:list().value
        assert.equal(#listed, 2)
        assert.equal(listed[1].schema_version, 1)
        assert.equal(listed[2].schema_version, 2)

        local drift = event_schema('QuestAdvanced', 3, '08')
        assert.error_code(registry:register(drift), 'SCHEMA_VALIDATION_FAILED')
    end),

    case('event schema payload descriptors and hashes are fail-closed', function()
        local registry = EventSchemaRegistry.new().value
        local invalid = event_schema('QuestMalformed')
        invalid.payload_schema_hash = 'ABC'
        assert.error_code(registry:register(invalid), 'SCHEMA_VALIDATION_FAILED')

        invalid = event_schema('QuestMalformed')
        invalid.required_payload_fields[1].default_semantics = 'NOT_ALLOWED'
        assert.error_code(registry:register(invalid), 'SCHEMA_VALIDATION_FAILED')

        invalid = event_schema('QuestMalformed')
        invalid.optional_payload_fields[1].default_semantics = nil
        assert.error_code(registry:register(invalid), 'SCHEMA_VALIDATION_FAILED')

        invalid = event_schema('QuestMalformed')
        invalid.optional_payload_fields[1].name = 'quest_id'
        assert.error_code(registry:register(invalid), 'SCHEMA_VALIDATION_FAILED')

        invalid = event_schema('QuestMalformed')
        invalid.required_payload_fields = {
            {
                name = 'z_field',
                value_type = 'STRING',
                sensitive = false,
            },
            {
                name = 'a_field',
                value_type = 'STRING',
                sensitive = false,
            },
        }
        assert.error_code(registry:register(invalid), 'SCHEMA_VALIDATION_FAILED')
    end),

    case('schema registries reject infinite and unsafe numeric versions', function()
        local events = EventSchemaRegistry.new().value
        local invalid_event = event_schema('InfiniteVersion')
        invalid_event.schema_version = math.huge
        assert.equal(events:register(invalid_event).ok, false)
        assert.error_code(
            events:get('InfiniteVersion', math.huge),
            'SCHEMA_VALIDATION_FAILED'
        )

        invalid_event = event_schema('UnsafeVersion')
        invalid_event.schema_version = 9007199254740992
        assert.equal(events:register(invalid_event).ok, false)
        assert.error_code(
            events:get('UnsafeVersion', 9007199254740992),
            'SCHEMA_VALIDATION_FAILED'
        )

        local sections = SectionOwnerRegistry.new().value
        local invalid_section = table_section('infinite_section', 'infinite_section', '18', 2)
        invalid_section.schema_version = math.huge
        assert.error_code(sections:register(invalid_section), 'SCHEMA_VALIDATION_FAILED')

        invalid_section = table_section('unsafe_section', 'unsafe_section', '18', 2)
        invalid_section.schema_version = 9007199254740992
        assert.error_code(sections:register(invalid_section), 'SCHEMA_VALIDATION_FAILED')
    end),

    case('section owner registry rejects path overlap and unauthorized writes', function()
        local registry = SectionOwnerRegistry.new().value
        local root = table_section('world_root', 'world', '12', 2)
        assert.equal(registry:register(root).ok, true)
        assert.deep_equal(registry:get('world_root').value, root)

        assert.error_code(
            registry:register(table_section('world_quest', 'world.quest', '09', 2)),
            'SECTION_OWNER_CONFLICT'
        )

        assert.equal(registry:authorize_write('12', 2, 'world').ok, true)
        assert.error_code(
            registry:authorize_write('09', 2, 'world'),
            'SECTION_WRITE_FORBIDDEN'
        )
        assert.error_code(
            registry:find_by_path(2, 'world.missing'),
            'REGISTRY_ENTRY_NOT_FOUND'
        )

        local invalid = table_section('private_table', 'private_table', '18', 2)
        invalid.public = true
        assert.error_code(registry:register(invalid), 'SCHEMA_VALIDATION_FAILED')

        invalid = table_section('missing_codec', 'missing_codec', '18', 2)
        invalid.codec_id = nil
        assert.error_code(registry:register(invalid), 'ID_INVALID')

        invalid = table_section('unknown_field', 'unknown_field', '18', 2)
        invalid.extra = true
        assert.error_code(registry:register(invalid), 'SCHEMA_VALIDATION_FAILED')
    end),

    case('integer-backed slots are globally single-owner', function()
        local registry = SectionOwnerRegistry.new().value
        assert.equal(registry:register(integer_section('rank_primary', 150)).ok, true)
        assert.error_code(
            registry:register(integer_section('rank_secondary', 150)),
            'SECTION_OWNER_CONFLICT'
        )
        assert.error_code(
            registry:register(public_section('public_same_slot', 150)),
            'SECTION_OWNER_CONFLICT'
        )

        local reverse = SectionOwnerRegistry.new().value
        assert.equal(reverse:register(public_section('public_primary', 151)).ok, true)
        assert.error_code(
            reverse:register(integer_section('rank_same_slot', 151)),
            'SECTION_OWNER_CONFLICT'
        )
    end),

    case('foundation registry starts sealed with the reserved section ownership', function()
        local created = Foundation.create()
        assert.equal(created.ok, true)
        local foundation = created.value
        assert.equal(foundation.event_schemas:is_sealed(), true)
        assert.equal(foundation.section_owners:is_sealed(), true)
        assert.equal(#foundation.event_schemas:list().value, 0)

        local sections = foundation.section_owners:list()
        assert.equal(sections.ok, true)
        assert.equal(#sections.value, 12)
        assert.equal(
            foundation.section_owners:authorize_write('18', 1, 'manifest').ok,
            true
        )
        local public_snapshot = foundation.section_owners:get('arena_public_snapshot').value
        assert.equal(public_snapshot.storage_kind, 'PUBLIC_SECTION')
        assert.equal(public_snapshot.write_policy, 'DERIVED')
        assert.equal(public_snapshot.public, true)
        assert.equal(public_snapshot.sensitive, false)
        local rank_value = foundation.section_owners:get('arena_rank_value').value
        assert.equal(rank_value.storage_kind, 'RANK_INTEGER')
        assert.equal(rank_value.slot_id, 101)
        local player_profile = foundation.section_owners:get('player_profile').value
        assert.equal(player_profile.owner_system, '18')
        assert.equal(player_profile.storage_kind, 'TABLE_SECTION')
        assert.error_code(
            foundation.section_owners:authorize_write('24', 1, 'manifest'),
            'SECTION_WRITE_FORBIDDEN'
        )
        assert.error_code(
            foundation.section_owners:register({
                section_key = 'late_section',
                section_path = 'late_section',
                owner_system = '01',
                slot_id = 1,
                schema_version = 1,
            }),
            'REGISTRY_SEALED'
        )

        assert.equal(Versions.FOUNDATION_CONTRACT_VERSION, 1)
        assert.equal(Versions.EVENT_SCHEMA_REGISTRY_VERSION, 1)
        assert.equal(Versions.SECTION_OWNER_REGISTRY_VERSION, 1)
        assert.equal(Versions.FEATURE_FLAG_SCHEMA_VERSION, 1)
    end),

    case('system registrars run sorted while registries are mutable, then seal', function()
        local execution_order = {}
        local registrars = {
            {
                system_id = '01',
                register = function(context)
                    execution_order[#execution_order + 1] = '01'
                    assert.equal(context.event_schemas:is_sealed(), false)
                    assert.equal(context.section_owners:is_sealed(), false)
                    local event = event_schema('SystemOneReady', 1, '01')
                    assert.equal(context.event_schemas:register(event).ok, true)
                    assert.equal(context.section_owners:register(
                        table_section('system_one_state', 'system_one_state', '01', 3)
                    ).ok, true)
                    return Result.ok(true)
                end,
            },
            {
                system_id = '02',
                register = function(context)
                    execution_order[#execution_order + 1] = '02'
                    assert.equal(context.event_schemas:is_sealed(), false)
                    local event = event_schema('SystemTwoReady', 1, '02')
                    assert.equal(context.event_schemas:register(event).ok, true)
                    return Result.ok(true)
                end,
            },
        }
        local created = Foundation.create({ registrars = registrars })
        assert.equal(created.ok, true)
        assert.deep_equal(execution_order, { '01', '02' })
        assert.equal(created.value.registrar_count, 2)
        assert.equal(created.value.event_schemas:is_sealed(), true)
        assert.equal(created.value.section_owners:is_sealed(), true)
        assert.equal(created.value.event_schemas:contains('SystemOneReady', 1), true)
        assert.equal(created.value.event_schemas:contains('SystemTwoReady', 1), true)
        assert.equal(created.value.section_owners:get('system_one_state').ok, true)
    end),

    case('scoped registrars cannot impersonate declaration ownership', function()
        local event_impersonation = Foundation.create({
            registrars = {
                {
                    system_id = '01',
                    register = function(context)
                        return context.event_schemas:register(
                            event_schema('ImpersonatedEvent', 1, '02')
                        )
                    end,
                },
            },
        })
        assert.error_code(event_impersonation, 'SCHEMA_VALIDATION_FAILED')

        local section_impersonation = Foundation.create({
            registrars = {
                {
                    system_id = '01',
                    register = function(context)
                        return context.section_owners:register(
                            table_section('impersonated_state', 'impersonated_state', '02', 3)
                        )
                    end,
                },
            },
        })
        assert.error_code(section_impersonation, 'SCHEMA_VALIDATION_FAILED')
    end),

    case('registrar version views are read-only and cannot mutate constants', function()
        local original = Versions.FOUNDATION_CONTRACT_VERSION
        local mutation_blocked = false
        local created = Foundation.create({
            registrars = {
                {
                    system_id = '01',
                    register = function(context)
                        assert.equal(context.system_id, '01')
                        local succeeded = pcall(function()
                            context.versions.FOUNDATION_CONTRACT_VERSION = 999
                        end)
                        mutation_blocked = not succeeded
                        assert.equal(Versions.FOUNDATION_CONTRACT_VERSION, original)
                        return Result.ok(true)
                    end,
                },
            },
        })
        assert.equal(created.ok, true)
        assert.equal(mutation_blocked, true)
        assert.equal(created.value.versions.FOUNDATION_CONTRACT_VERSION, original)
        assert.throws(function()
            created.value.versions.FOUNDATION_CONTRACT_VERSION = 999
        end, 'foundation versions are read-only')
        assert.equal(Versions.FOUNDATION_CONTRACT_VERSION, original)
    end),

    case('registrar ordering and registrar failures abort foundation creation', function()
        local execution_order = {}
        local unsorted = Foundation.create({
            registrars = {
                {
                    system_id = '02',
                    register = function()
                        execution_order[#execution_order + 1] = '02'
                        return Result.ok(true)
                    end,
                },
                {
                    system_id = '01',
                    register = function()
                        execution_order[#execution_order + 1] = '01'
                        return Result.ok(true)
                    end,
                },
            },
        })
        assert.error_code(unsorted, 'SCHEMA_VALIDATION_FAILED')
        assert.deep_equal(execution_order, { '02' })

        local failed = Foundation.create({
            registrars = {
                {
                    system_id = '01',
                    register = function()
                        return Result.err(
                            'TEST_REGISTRAR_FAILURE',
                            'error.test.registrar_failure',
                            false
                        )
                    end,
                },
            },
        })
        assert.error_code(failed, 'TEST_REGISTRAR_FAILURE')

        local raised = Foundation.create({
            registrars = {
                {
                    system_id = '01',
                    register = function()
                        error('registrar boom')
                    end,
                },
            },
        })
        assert.error_code(raised, 'SCHEMA_VALIDATION_FAILED')
    end),

    case('foundation rejects scalar options and adversarial sparse registrars', function()
        assert.error_code(Foundation.create(false), 'SCHEMA_VALIDATION_FAILED')

        local registrar = {
            system_id = '01',
            register = function()
                return Result.ok(true)
            end,
        }
        local sparse = {
            [1] = registrar,
            [2] = registrar,
            [4] = registrar,
            [6] = registrar,
        }
        assert.error_code(
            Foundation.create({ registrars = sparse }),
            'SCHEMA_VALIDATION_FAILED'
        )
    end),

    case('feature flags default closed and require every declared capability', function()
        local defaults = FeatureFlags.safe_defaults()
        local key
        local count = 0
        for key in pairs(defaults) do
            assert.equal(defaults[key], false)
            count = count + 1
        end
        assert.equal(count, 6)
        assert.equal(FeatureFlags.validate(defaults).ok, true)

        local resolved = FeatureFlags.resolve(
            all_release_flags(),
            all_capabilities(),
            { paid_gacha = true }
        )
        assert.equal(resolved.ok, true)
        for key in pairs(resolved.value) do
            assert.equal(resolved.value[key], true, key .. ' should be enabled')
        end

        local capabilities = all_capabilities()
        capabilities.open_archive = 'unverified'
        resolved = FeatureFlags.resolve(
            all_release_flags(),
            capabilities,
            { paid_gacha = true }
        )
        assert.equal(resolved.value.open_archive, false)
        assert.equal(resolved.value.arena, false)
        assert.equal(resolved.value.cloud_save, true)

        resolved = FeatureFlags.resolve(
            all_release_flags(),
            all_capabilities(),
            { paid_gacha = false }
        )
        assert.equal(resolved.value.paid_gacha, false)
        assert.equal(resolved.value.platform_store, true)
    end),

    case('feature flag schema rejects missing, unknown, and non-boolean values', function()
        local flags = all_release_flags()
        flags.arena = nil
        assert.error_code(FeatureFlags.validate(flags), 'SCHEMA_VALIDATION_FAILED')

        flags = all_release_flags()
        flags.unknown = false
        assert.error_code(FeatureFlags.validate(flags), 'SCHEMA_VALIDATION_FAILED')

        flags = all_release_flags()
        flags.cloud_save = 'true'
        assert.error_code(FeatureFlags.validate(flags), 'SCHEMA_VALIDATION_FAILED')
    end),
}
