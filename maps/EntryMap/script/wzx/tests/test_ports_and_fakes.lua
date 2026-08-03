local Harness = require 'wzx.tests.harness'
local PortContract = require 'wzx.application.ports.port_contract'
local RequestContext = require 'wzx.application.ports.request_context'
local ScriptedPort = require 'wzx.adapters.fake.scripted_port'

local case = Harness.case
local assert = Harness.assert
local CHECKSUM = string.rep('a', 64)
local OWNER_HASH = string.rep('b', 64)

local function save_envelope(revision)
    return {
        schema_version = 1,
        revision = revision or 1,
        checkpoint_id = 'checkpoint:1',
        content_version = 'content-v1',
        owner_fingerprint = 'owner_v1_' .. OWNER_HASH,
        payload_checksum = CHECKSUM,
        written_at = 1,
        payload = { marker = 'fixture' },
    }
end

local PORTS = {
    {
        module = 'wzx.application.ports.clock_service',
        name = 'ClockService',
        operations = { 'now' },
        fake = 'wzx.adapters.fake.services.fake_clock_service',
        probe_operation = 'now',
        probe_fields = {},
    },
    {
        module = 'wzx.application.ports.gacha_service',
        name = 'GachaService',
        operations = { 'request_pool', 'query_pool_request', 'get_pool_capability' },
        fake = 'wzx.adapters.fake.services.fake_gacha_service',
        probe_operation = 'get_pool_capability',
        probe_fields = { pool_id = 'pool_standard' },
    },
    {
        module = 'wzx.application.ports.open_archive_service',
        name = 'OpenArchiveService',
        operations = { 'read_public_snapshot' },
        fake = 'wzx.adapters.fake.services.fake_open_archive_service',
        probe_operation = 'read_public_snapshot',
        probe_fields = { opponent_aid = 'aid001', slot_id = 100 },
    },
    {
        module = 'wzx.application.ports.platform_store',
        name = 'PlatformStore',
        operations = {
            'get_goods_info',
            'purchase',
            'get_owned_count',
            'consume_item',
            'reconcile',
        },
        fake = 'wzx.adapters.fake.services.fake_platform_store',
        probe_operation = 'get_goods_info',
        probe_fields = { goods_id = 'goods_starter' },
    },
    {
        module = 'wzx.application.ports.rank_service',
        name = 'RankService',
        operations = {
            'publish_score',
            'get_self_rank',
            'get_nearby_entries',
            'get_entry_identity',
        },
        fake = 'wzx.adapters.fake.services.fake_rank_service',
        probe_operation = 'get_self_rank',
        probe_fields = { slot_id = 101 },
    },
    {
        module = 'wzx.application.ports.save_store',
        name = 'SaveStore',
        operations = {
            'load_slot',
            'stage_slot',
            'commit',
            'upload',
            'read_integer',
            'compare_and_add_integer',
            'compare_and_set_integer',
            'query_integer_request',
        },
        fake = 'wzx.adapters.fake.services.fake_save_store',
        probe_operation = 'load_slot',
        probe_fields = { player_ref = 'player001', slot_id = 1 },
    },
}

local SUCCESS_FIXTURES = {
    ClockService = {
        now = function()
            return {
                unix_seconds = 1234,
                trust_level = 'TRUSTED',
                response_id = 'clock-response-001',
            }
        end,
    },
    GachaService = {
        request_pool = function()
            return {
                status = 'CONFIRMED',
                pool_id = 'pool_standard',
                request_key = 'idempotency-001',
                probability_version = 'prob_v1',
                result_id = 'gacha:result_1',
                trusted_unix_seconds = 1,
                platform_code = 'SUCCESS',
                rewards = {
                    {
                        reward_kind = 'CHARACTER',
                        content_id = 'char_hero001',
                        quantity = 1,
                    },
                },
            }
        end,
        query_pool_request = function()
            return {
                status = 'PENDING',
                request_key = 'draw_request_001',
            }
        end,
        get_pool_capability = function()
            return {
                status = 'VERIFIED',
                pool_id = 'pool_standard',
                authoritative = true,
                consumption_atomic = true,
                result_persistence_atomic = true,
                request_query_supported = true,
                audit_export_supported = true,
            }
        end,
    },
    OpenArchiveService = {
        read_public_snapshot = function()
            return {
                status = 'FOUND',
                opponent_aid = 'aid001',
                slot_id = 100,
                snapshot = {
                    marker = 'original-result',
                    nested = { revision_marker = 1 },
                },
                revision = 1,
                payload_checksum = CHECKSUM,
            }
        end,
    },
    PlatformStore = {
        get_goods_info = function()
            return {
                goods_id = 'goods_starter',
                status = 'AVAILABLE',
                currency_code = 'CNY',
                price_minor = 600,
                metadata = { category = 'starter' },
            }
        end,
        purchase = function()
            return {
                status = 'CONFIRMED',
                order_ref = 'order-001',
                goods_id = 'goods_starter',
                quantity = 1,
                request_key = 'idempotency-001',
            }
        end,
        get_owned_count = function()
            return {
                platform_item_id = 'item_draw_ticket',
                count = 3,
                revision = 1,
            }
        end,
        consume_item = function()
            return {
                status = 'CONFIRMED',
                platform_item_id = 'item_draw_ticket',
                consumed_quantity = 1,
                remaining_count = 2,
                revision = 2,
                request_key = 'idempotency-001',
            }
        end,
        reconcile = function()
            return {
                status = 'CONFIRMED',
                orders = {},
                request_id = 'request-001',
                cursor_request_hash = CHECKSUM,
            }
        end,
    },
    RankService = {
        publish_score = function()
            return {
                status = 'CONFIRMED',
                slot_id = 101,
                encoded_value = 100,
                request_key = 'idempotency-001',
            }
        end,
        get_self_rank = function()
            return { status = 'UNRANKED', slot_id = 101 }
        end,
        get_nearby_entries = function()
            return {
                status = 'AVAILABLE',
                slot_id = 101,
                entries = {},
            }
        end,
        get_entry_identity = function()
            return {
                status = 'UNAVAILABLE',
                entry_ref = 'rank:entry_1',
                rank = 1,
                encoded_value = 100,
            }
        end,
    },
    SaveStore = {
        load_slot = function()
            return {
                player_ref = 'player001',
                slot_id = 1,
                dto = save_envelope(1),
                revision = 1,
                checkpoint_id = 'checkpoint:1',
                payload_checksum = CHECKSUM,
            }
        end,
        stage_slot = function()
            return {
                player_ref = 'player001',
                slot_id = 1,
                revision = 1,
                checkpoint_id = 'checkpoint:1',
                payload_checksum = CHECKSUM,
                request_key = 'idempotency-001',
            }
        end,
        commit = function()
            return {
                status = 'CONFIRMED',
                player_ref = 'player001',
                request_key = 'idempotency-001',
                slot_results = {
                    {
                        slot_id = 1,
                        status = 'CONFIRMED',
                        target_revision = 1,
                        checkpoint_id = 'checkpoint:1',
                        payload_checksum = CHECKSUM,
                    },
                },
            }
        end,
        upload = function()
            return {
                player_ref = 'player001',
                status = 'CONFIRMED',
                request_key = 'idempotency-001',
            }
        end,
        read_integer = function()
            return {
                player_ref = 'player001',
                slot_id = 1,
                value = 10,
                revision = 1,
            }
        end,
        compare_and_add_integer = function()
            return {
                player_ref = 'player001',
                slot_id = 1,
                value = 11,
                revision = 2,
                request_key = 'idempotency-001',
            }
        end,
        compare_and_set_integer = function()
            return {
                player_ref = 'player001',
                slot_id = 1,
                value = 12,
                revision = 2,
                request_key = 'idempotency-001',
            }
        end,
        query_integer_request = function()
            return {
                status = 'NOT_FOUND',
                player_ref = 'player001',
                slot_id = 1,
                original_idempotency_key = 'idempotency-query-001',
            }
        end,
    },
}

local function success_fixture(port_name, operation_name)
    local by_operation = SUCCESS_FIXTURES[port_name]
    local factory = by_operation and by_operation[operation_name]
    if type(factory) ~= 'function' then
        error('missing success fixture for ' .. port_name .. '.' .. operation_name)
    end
    return factory()
end

local function context(include_idempotency, suffix, idempotency_key)
    suffix = suffix or '001'
    local value = {
        request_id = 'request-' .. suffix,
        correlation_id = 'correlation-' .. suffix,
        attempt = 1,
        started_at_local = 0,
        timeout_ms = 1000,
    }
    if include_idempotency then
        value.idempotency_key = idempotency_key or 'idempotency-001'
    end
    return value
end

local function probe_request(definition, suffix)
    local request = {
        context = context(false, suffix),
    }
    local key
    local value
    for key, value in pairs(definition.probe_fields) do
        request[key] = value
    end
    return request
end

local function stage_request(suffix, idempotency_key, balance)
    local dto = save_envelope(1)
    dto.payload = {
        balance = balance or 10,
        nested = { marker = 'stable' },
    }
    return {
        context = context(true, suffix, idempotency_key),
        player_ref = 'player001',
        slot_id = 1,
        expected_revision = 0,
        checkpoint_id = 'checkpoint:1',
        payload_checksum = CHECKSUM,
        dto = dto,
    }
end

local REQUEST_FIXTURES = {
    ClockService = {
        now = function()
            return { context = context(false) }
        end,
    },
    GachaService = {
        request_pool = function()
            return {
                context = context(true),
                pool_id = 'pool_standard',
                expected_probability_version = 'prob_v1',
            }
        end,
        query_pool_request = function()
            return {
                context = context(false),
                original_request_key = 'draw_request_001',
                expected_pool_id = 'pool_standard',
                expected_probability_version = 'prob_v1',
            }
        end,
        get_pool_capability = function()
            return {
                context = context(false),
                pool_id = 'pool_standard',
            }
        end,
    },
    OpenArchiveService = {
        read_public_snapshot = function()
            return {
                context = context(false),
                opponent_aid = 'aid001',
                slot_id = 100,
            }
        end,
    },
    PlatformStore = {
        get_goods_info = function()
            return {
                context = context(false),
                goods_id = 'goods_starter',
            }
        end,
        purchase = function()
            return {
                context = context(true),
                goods_id = 'goods_starter',
                quantity = 1,
            }
        end,
        get_owned_count = function()
            return {
                context = context(false),
                platform_item_id = 'item_draw_ticket',
            }
        end,
        consume_item = function()
            return {
                context = context(true),
                platform_item_id = 'item_draw_ticket',
                quantity = 1,
            }
        end,
        reconcile = function()
            return {
                context = context(false),
                entitlement_cursor = { page = 1 },
                cursor_request_hash = CHECKSUM,
            }
        end,
    },
    RankService = {
        publish_score = function()
            return {
                context = context(true),
                slot_id = 101,
                encoded_value = 100,
            }
        end,
        get_self_rank = function()
            return {
                context = context(false),
                slot_id = 101,
            }
        end,
        get_nearby_entries = function()
            return {
                context = context(false),
                slot_id = 101,
                center_rank = 1,
                count = 10,
            }
        end,
        get_entry_identity = function()
            return {
                context = context(false),
                entry = {
                    entry_ref = 'rank:entry_1',
                    rank = 1,
                    encoded_value = 100,
                },
            }
        end,
    },
    SaveStore = {
        load_slot = function()
            return {
                context = context(false),
                player_ref = 'player001',
                slot_id = 1,
            }
        end,
        stage_slot = function()
            return stage_request('001', 'idempotency-001', 10)
        end,
        commit = function()
            return {
                context = context(true),
                player_ref = 'player001',
                commit_entries = {
                    {
                        slot_id = 1,
                        target_revision = 1,
                        checkpoint_id = 'checkpoint:1',
                        payload_checksum = CHECKSUM,
                    },
                },
            }
        end,
        upload = function()
            return {
                context = context(true),
                player_ref = 'player001',
            }
        end,
        read_integer = function()
            return {
                context = context(false),
                player_ref = 'player001',
                slot_id = 1,
            }
        end,
        compare_and_add_integer = function()
            return {
                context = context(true),
                player_ref = 'player001',
                slot_id = 1,
                expected_value = 10,
                expected_revision = 1,
                delta = 1,
            }
        end,
        compare_and_set_integer = function()
            return {
                context = context(true),
                player_ref = 'player001',
                slot_id = 1,
                expected_value = 10,
                expected_revision = 1,
                target_value = 12,
            }
        end,
        query_integer_request = function()
            return {
                context = context(false),
                player_ref = 'player001',
                slot_id = 1,
                original_idempotency_key = 'idempotency-query-001',
            }
        end,
    },
}

local function request_fixture(port_name, operation_name)
    local by_operation = REQUEST_FIXTURES[port_name]
    local factory = by_operation and by_operation[operation_name]
    if type(factory) ~= 'function' then
        error('missing request fixture for ' .. port_name .. '.' .. operation_name)
    end
    return factory()
end

return {
    case('all six port contracts load all 22 exact request field specifications', function()
        local total_operations = 0
        local port_index
        for port_index = 1, #PORTS do
            local expected = PORTS[port_index]
            local spec = require(expected.module)
            assert.equal(spec.name, expected.name)
            assert.equal(spec.contract_version, 1)
            assert.equal(#spec.operations, #expected.operations)

            local operation_index
            for operation_index = 1, #expected.operations do
                local operation_name = expected.operations[operation_index]
                local operation = spec:get_operation(operation_name)
                assert.not_nil(operation, expected.name .. ' missing ' .. operation_name)
                assert.equal(operation.name, operation_name)
                assert.equal(type(operation.mutating), 'boolean')
                assert.equal(type(operation.requires_idempotency), 'boolean')
                assert.equal(type(operation.request_fields), 'table')
                assert.equal(operation.allowed_request_fields.context, true)
                local seen_fields = {}
                local field_index
                for field_index = 1, #operation.request_fields do
                    local field_name = operation.request_fields[field_index]
                    assert.equal(type(field_name), 'string')
                    assert.truthy(field_name ~= '' and field_name ~= 'context')
                    assert.falsy(seen_fields[field_name])
                    assert.equal(operation.allowed_request_fields[field_name], true)
                    seen_fields[field_name] = true
                end
                local allowed_count = 0
                local allowed_name
                for allowed_name in pairs(operation.allowed_request_fields) do
                    assert.truthy(
                        allowed_name == 'context' or seen_fields[allowed_name],
                        expected.name .. '.' .. operation_name .. ' leaked request field'
                    )
                    allowed_count = allowed_count + 1
                end
                assert.equal(allowed_count, #operation.request_fields + 1)
                total_operations = total_operations + 1
            end
        end
        assert.equal(total_operations, 22)
    end),

    case('all 22 operations validate exact success DTOs and allowlisted errors', function()
        local total_operations = 0
        local port_index
        for port_index = 1, #PORTS do
            local expected = PORTS[port_index]
            local spec = require(expected.module)
            local operation_index
            for operation_index = 1, #expected.operations do
                local operation_name = expected.operations[operation_index]
                local operation = spec:get_operation(operation_name)
                local request = request_fixture(expected.name, operation_name)
                local request_validation = spec:validate_request(
                    operation_name,
                    request
                )
                assert.equal(
                    request_validation.ok,
                    true,
                    expected.name .. '.' .. operation_name .. ' request fixture'
                )
                local valid_result = PortContract.ok(
                    success_fixture(expected.name, operation_name)
                )
                local validated = spec:validate_result(
                    operation_name,
                    valid_result,
                    request
                )
                local validation_label = expected.name .. '.' .. operation_name
                if not validated.ok and type(validated.error) == 'table' then
                    validation_label = validation_label .. ' -> '
                        .. tostring(validated.error.code) .. '/'
                        .. tostring(type(validated.error.details) == 'table'
                            and validated.error.details.reason or nil)
                end
                assert.equal(validated.ok, true, validation_label)
                assert.deep_equal(validated, valid_result)
                assert.truthy(validated ~= valid_result)
                assert.truthy(validated.value ~= valid_result.value)

                local malformed = spec:validate_result(
                    operation_name,
                    PortContract.ok({ unexpected = true }),
                    request
                )
                assert.error_code(malformed, 'PORT_RESULT_INVALID')
                assert.equal(malformed.error.details.port, expected.name)
                assert.equal(malformed.error.details.operation, operation_name)

                local extra_envelope_field = PortContract.ok(
                    success_fixture(expected.name, operation_name)
                )
                extra_envelope_field.unexpected = true
                assert.error_code(
                    spec:validate_result(
                        operation_name,
                        extra_envelope_field,
                        request
                    ),
                    'PORT_RESULT_INVALID'
                )

                local common_error = PortContract.error(
                    'PLATFORM_UNAVAILABLE',
                    { source = 'fixture' },
                    false
                )
                local validated_common = spec:validate_result(
                    operation_name,
                    common_error
                )
                assert.deep_equal(validated_common, common_error)
                assert.truthy(validated_common ~= common_error)

                local error_index
                for error_index = 1, #operation.error_codes do
                    local declared_error = PortContract.error(
                        operation.error_codes[error_index],
                        { source = 'fixture' },
                        false
                    )
                    local validated_error = spec:validate_result(
                        operation_name,
                        declared_error
                    )
                    assert.deep_equal(validated_error, declared_error)
                    assert.truthy(validated_error ~= declared_error)
                end

                assert.error_code(spec:validate_result(
                    operation_name,
                    PortContract.error('UNDECLARED_OPERATION_ERROR', {}, false)
                ), 'PORT_RESULT_INVALID')
                total_operations = total_operations + 1
            end
        end
        assert.equal(total_operations, 22)
    end),

    case('result validation contains a throwing success validator', function()
        local ExplodingPort = PortContract.define({
            name = 'ExplodingPort',
            operations = {
                {
                    name = 'explode',
                    request_fields = {},
                    validate_success = function()
                        error('validator exploded')
                    end,
                },
            },
        })
        local validation = ExplodingPort:validate_result(
            'explode',
            PortContract.ok({ marker = true })
        )
        assert.error_code(validation, 'PORT_RESULT_INVALID')
        assert.equal(
            validation.error.details.reason,
            'SUCCESS_VALIDATOR_RAISED'
        )
        assert.equal(validation.error.details.port, 'ExplodingPort')
        assert.equal(validation.error.details.operation, 'explode')
    end),

    case('result string fields enforce the documented byte ceiling', function()
        local ClockService = require 'wzx.application.ports.clock_service'
        local at_limit = success_fixture('ClockService', 'now')
        at_limit.response_id = string.rep('r', PortContract.MAX_STRING_BYTES)
        assert.equal(ClockService:validate_result(
            'now',
            PortContract.ok(at_limit)
        ).ok, true)

        local above_limit = success_fixture('ClockService', 'now')
        above_limit.response_id = string.rep(
            'r',
            PortContract.MAX_STRING_BYTES + 1
        )
        local invalid = ClockService:validate_result(
            'now',
            PortContract.ok(above_limit)
        )
        assert.error_code(invalid, 'PORT_RESULT_INVALID')
        assert.equal(invalid.error.details.reason, 'STRING_TOO_LONG')
        assert.equal(
            invalid.error.details.maximum_bytes,
            PortContract.MAX_STRING_BYTES
        )
    end),

    case('request-bound results reject an echo mismatch', function()
        local OpenArchiveService =
            require 'wzx.application.ports.open_archive_service'
        local request = request_fixture(
            'OpenArchiveService',
            'read_public_snapshot'
        )
        local value = success_fixture(
            'OpenArchiveService',
            'read_public_snapshot'
        )
        value.opponent_aid = 'aid999'
        local invalid = OpenArchiveService:validate_result(
            'read_public_snapshot',
            PortContract.ok(value),
            request
        )
        assert.error_code(invalid, 'PORT_RESULT_INVALID')
        assert.equal(invalid.error.details.reason, 'REQUEST_ECHO_MISMATCH')
        assert.equal(invalid.error.details.expected, 'aid001')
        assert.equal(invalid.error.details.actual, 'aid999')
    end),

    case('gacha reward results enforce the 100-row list ceiling', function()
        local GachaService = require 'wzx.application.ports.gacha_service'
        local request = request_fixture('GachaService', 'request_pool')
        local function draw_with_rewards(count)
            local value = success_fixture('GachaService', 'request_pool')
            value.rewards = {}
            local index
            for index = 1, count do
                value.rewards[index] = {
                    reward_kind = 'VOUCHER',
                    content_id = string.format('item_%03d', index),
                    quantity = 1,
                }
            end
            return value
        end

        assert.equal(GachaService:validate_result(
            'request_pool',
            PortContract.ok(draw_with_rewards(100)),
            request
        ).ok, true)
        local invalid = GachaService:validate_result(
            'request_pool',
            PortContract.ok(draw_with_rewards(101)),
            request
        )
        assert.error_code(invalid, 'PORT_RESULT_INVALID')
        assert.equal(invalid.error.details.reason, 'LIST_TOO_LONG')
        assert.equal(invalid.error.details.maximum, 100)
    end),

    case('port descriptors are defensive copies and contracts are read-only', function()
        local SaveStore = require 'wzx.application.ports.save_store'
        assert.throws(function()
            SaveStore.name = 'ForgedStore'
        end, 'port contract is read-only')
        assert.throws(function()
            SaveStore.validate_result = function()
                return PortContract.ok(true)
            end
        end, 'port contract is read-only')

        local listed = SaveStore.operations
        listed[1].name = 'forged_operation'
        listed[1].request_fields[1] = 'forged_field'
        listed[1].allowed_request_fields.context = false
        local fetched = SaveStore:get_operation('load_slot')
        assert.equal(fetched.name, 'load_slot')
        assert.equal(fetched.request_fields[1], 'player_ref')
        assert.equal(fetched.allowed_request_fields.context, true)

        fetched.name = 'forged_again'
        assert.equal(SaveStore:get_operation('load_slot').name, 'load_slot')
    end),

    case('payload snapshots enforce value key and node budgets', function()
        local at_value_limit = PortContract.inspect_payload_budget({
            value = string.rep('v', PortContract.MAX_VALUE_STRING_BYTES),
        })
        assert.equal(at_value_limit.ok, true)

        local over_value_limit = PortContract.inspect_payload_budget({
            value = string.rep('v', PortContract.MAX_VALUE_STRING_BYTES + 1),
        })
        assert.error_code(over_value_limit, 'PAYLOAD_BUDGET_EXCEEDED')
        assert.equal(
            over_value_limit.error.details.reason,
            'MAXIMUM_VALUE_STRING_BYTES_EXCEEDED'
        )

        local long_key = {}
        long_key[string.rep('k', PortContract.MAX_KEY_BYTES + 1)] = true
        local over_key_limit = PortContract.inspect_payload_budget(long_key)
        assert.error_code(over_key_limit, 'PAYLOAD_BUDGET_EXCEEDED')
        assert.equal(
            over_key_limit.error.details.reason,
            'MAXIMUM_KEY_BYTES_EXCEEDED'
        )

        local too_many_nodes = {}
        local index
        for index = 1, PortContract.MAX_PAYLOAD_NODES + 1 do
            too_many_nodes[index] = true
        end
        local over_node_limit = PortContract.inspect_payload_budget(too_many_nodes)
        assert.error_code(over_node_limit, 'PAYLOAD_BUDGET_EXCEEDED')
        assert.equal(
            over_node_limit.error.details.reason,
            'MAXIMUM_NODE_COUNT_EXCEEDED'
        )
    end),

    case('request context and mutating operation validation are fail-closed', function()
        local valid = RequestContext.validate(context(false), {})
        assert.equal(valid.ok, true)
        assert.equal(valid.value.request_id, 'request-001')

        assert.error_code(RequestContext.validate(nil, {}), 'PORT_REQUEST_CONTEXT_INVALID')
        assert.error_code(RequestContext.validate({
            request_id = '',
            correlation_id = 'correlation',
            attempt = 1,
        }, {}), 'PORT_REQUEST_CONTEXT_INVALID')
        assert.error_code(RequestContext.validate({
            request_id = 'request:derived',
            correlation_id = 'correlation',
            attempt = 1,
        }, {}), 'PORT_REQUEST_CONTEXT_INVALID')
        assert.error_code(RequestContext.validate({
            request_id = string.rep('r', 65),
            correlation_id = 'correlation',
            attempt = 1,
        }, {}), 'PORT_REQUEST_CONTEXT_INVALID')
        assert.error_code(RequestContext.validate({
            request_id = 'request',
            correlation_id = 'correlation',
            attempt = 0,
        }, {}), 'PORT_REQUEST_CONTEXT_INVALID')

        local SaveStore = require 'wzx.application.ports.save_store'
        local stage = stage_request('context-check', 'idempotency-context-check', 10)
        stage.context = context(false)
        local validation = SaveStore:validate_request('stage_slot', stage)
        assert.error_code(validation, 'PORT_IDEMPOTENCY_REQUIRED')
        stage.context = context(true, 'context-check', 'idempotency-context-check')
        validation = SaveStore:validate_request('stage_slot', stage)
        assert.equal(validation.ok, true)

        validation = SaveStore:validate_request('unknown_operation', stage)
        assert.error_code(validation, 'PORT_OPERATION_UNKNOWN')

        local cycle = {}
        cycle.self = cycle
        stage = stage_request('cycle-check', 'idempotency-cycle-check', 10)
        stage.dto = cycle
        validation = SaveStore:validate_request('stage_slot', stage)
        assert.error_code(validation, 'PORT_REQUEST_INVALID')
        assert.equal(validation.error.details.reason, 'PAYLOAD_SNAPSHOT_INVALID')
        assert.equal(validation.error.details.cause_code, 'PAYLOAD_SNAPSHOT_INVALID')

        stage.dto = { callback = function() end }
        validation = SaveStore:validate_request('stage_slot', stage)
        assert.error_code(validation, 'PORT_REQUEST_INVALID')
        assert.equal(validation.error.details.reason, 'PAYLOAD_SNAPSHOT_INVALID')
        assert.equal(validation.error.details.cause_code, 'PAYLOAD_SNAPSHOT_INVALID')

        validation = SaveStore:validate_request('commit', {
            context = context(true),
            player_ref = 'player-1',
            commit_entries = {
                { slot_id = 1, unexpected = true },
            },
        })
        assert.error_code(validation, 'PORT_REQUEST_INVALID')
        assert.equal(validation.error.details.reason, 'COMMIT_ENTRY_UNKNOWN_FIELD')
    end),

    case('port and context top-level field whitelists reject unknown keys', function()
        local ClockService = require 'wzx.application.ports.clock_service'
        local request = {
            context = context(false),
            unexpected_business_field = true,
        }
        local validation = ClockService:validate_request('now', request)
        assert.error_code(validation, 'PORT_REQUEST_INVALID')
        assert.equal(validation.error.details.reason, 'UNKNOWN_FIELD')
        assert.equal(validation.error.details.field, 'unexpected_business_field')

        request = { context = context(false) }
        request.context.unexpected_context_field = true
        validation = ClockService:validate_request('now', request)
        assert.error_code(validation, 'PORT_REQUEST_CONTEXT_INVALID')
        assert.equal(validation.error.details.reason, 'UNKNOWN_FIELD')
        assert.equal(validation.error.details.field, 'unexpected_context_field')

        request = { context = context(false) }
        request[1] = 'numeric-business-key'
        validation = ClockService:validate_request('now', request)
        assert.error_code(validation, 'PORT_REQUEST_INVALID')
        assert.equal(validation.error.details.reason, 'PAYLOAD_SNAPSHOT_INVALID')

        request = { context = context(false) }
        request.context[1] = 'numeric-context-key'
        validation = ClockService:validate_request('now', request)
        assert.error_code(validation, 'PORT_REQUEST_INVALID')
        assert.equal(validation.error.details.reason, 'PAYLOAD_SNAPSHOT_INVALID')
    end),

    case('port completion gate accepts only the first callback result', function()
        local received = {}
        local suppressed = {}
        local gate, state = PortContract.once(function(result)
            received[#received + 1] = result
        end, function(result, count)
            suppressed[#suppressed + 1] = {
                result = result,
                count = count,
            }
        end)

        assert.equal(gate(PortContract.ok('first')), true)
        assert.equal(gate(PortContract.ok('second')), false)
        assert.equal(#received, 1)
        assert.equal(received[1].value, 'first')
        assert.equal(#suppressed, 1)
        assert.equal(suppressed[1].count, 1)
        assert.deep_equal(state(), {
            completed = true,
            suppressed_count = 1,
        })

        local invalid_received
        gate = PortContract.once(function(result)
            invalid_received = result
        end)
        gate('not-a-result')
        assert.error_code(invalid_received, 'PORT_RESULT_INVALID')
    end),

    case('all Fake factories are discoverable and satisfy their contracts', function()
        local port_index
        for port_index = 1, #PORTS do
            local expected = PORTS[port_index]
            local spec = require(expected.module)
            local factory = require(expected.fake)
            assert.equal(type(factory), 'table')
            assert.equal(type(factory.new), 'function')

            local fake = factory.new()
            assert.equal(fake:get_contract(), spec)
            local implementation = spec:validate_implementation(fake)
            assert.equal(implementation.ok, true)
            local operation_index
            for operation_index = 1, #expected.operations do
                assert.equal(type(fake[expected.operations[operation_index]]), 'function')
            end
        end
    end),

    case('all six Fake ports deliver zero-delay callbacks non-inline by default', function()
        local port_index
        for port_index = 1, #PORTS do
            local expected = PORTS[port_index]
            local factory = require(expected.fake)
            local expected_value = success_fixture(
                expected.name,
                expected.probe_operation
            )
            local fake = factory.new({
                default_step = ScriptedPort.success(expected_value),
            })
            local completion
            local invocation = fake[expected.probe_operation](
                fake,
                probe_request(expected, string.format('%03d', port_index)),
                function(result)
                    completion = result
                end
            )
            assert.equal(invocation.ok, true)
            assert.deep_equal(invocation.value, { accepted = true })
            assert.is_nil(completion, expected.name .. ' callback ran inline')
            assert.equal(fake:tick(0).value.processed_deliveries, 1)
            assert.equal(completion.ok, true)
            assert.deep_equal(completion.value, expected_value)
            assert.equal(fake:assert_exhausted(), true)
        end
    end),

    case('ScriptedPort freezes scripted results, requests, callbacks, and diagnostics', function()
        local FakeOpenArchiveService = require 'wzx.adapters.fake.services.fake_open_archive_service'
        local scripted_value = success_fixture(
            'OpenArchiveService',
            'read_public_snapshot'
        )
        scripted_value.opponent_aid = 'aid_original'
        local fake = FakeOpenArchiveService.new()
        assert.equal(
            fake:expect('read_public_snapshot', ScriptedPort.success(scripted_value)).ok,
            true
        )
        scripted_value.revision = 9999
        scripted_value.snapshot.marker = 'mutated-result'

        local request = {
            context = context(false),
            opponent_aid = 'aid_original',
            slot_id = 100,
        }
        local completion
        assert.equal(fake:read_public_snapshot(request, function(result)
            completion = result
        end).ok, true)
        request.opponent_aid = 'aid_mutated'
        assert.is_nil(completion)
        fake:tick(0)

        assert.equal(completion.value.revision, 1)
        assert.equal(completion.value.snapshot.marker, 'original-result')
        completion.value.snapshot.marker = 'mutated-callback-copy'

        local calls = fake:get_calls('read_public_snapshot')
        assert.equal(calls[1].request.opponent_aid, 'aid_original')
        assert.equal(
            calls[1].completion_result.value.snapshot.marker,
            'original-result'
        )
        calls[1].request.opponent_aid = 'aid_diagnostic_mutation'
        assert.equal(
            fake:get_calls('read_public_snapshot')[1].request.opponent_aid,
            'aid_original'
        )
        assert.equal(fake:assert_exhausted(), true)
    end),

    case('ScriptedPort schedules deterministically and suppresses duplicates', function()
        local FakeClockService = require 'wzx.adapters.fake.services.fake_clock_service'
        local fake = FakeClockService.new({ auto_run_immediate = false })
        local result = PortContract.ok(success_fixture('ClockService', 'now'))
        assert.equal(fake:enqueue('now', ScriptedPort.duplicate(result, 2, 2)).ok, true)

        local completions = {}
        local invocation = fake:now({ context = context(false) }, function(value)
            completions[#completions + 1] = value
        end)
        assert.equal(invocation.ok, true)
        assert.deep_equal(invocation.value, { accepted = true })
        assert.equal(#completions, 0)

        assert.equal(fake:tick(1).value.processed_deliveries, 0)
        assert.equal(#completions, 0)
        assert.equal(fake:tick(1).value.processed_deliveries, 2)
        assert.equal(#completions, 1)
        assert.equal(completions[1].value.unix_seconds, 1234)

        local diagnostics = fake:get_diagnostics()
        assert.equal(diagnostics.call_count, 1)
        assert.equal(diagnostics.pending_delivery_count, 0)
        assert.equal(diagnostics.suppressed_delivery_count, 1)
        assert.equal(fake:get_calls('now')[1].suppressed_delivery_count, 1)
    end),

    case('ScriptedPort timeout wins and a later success is diagnostic-only', function()
        local FakeClockService = require 'wzx.adapters.fake.services.fake_clock_service'
        local fake = FakeClockService.new({ auto_run_immediate = false })
        local late_value = success_fixture('ClockService', 'now')
        late_value.unix_seconds = 9999
        late_value.response_id = 'clock-response-late'
        local late = PortContract.ok(late_value)
        fake:enqueue('now', ScriptedPort.timeout(late, 1, 3))

        local received = {}
        fake:now({ context = context(false) }, function(result)
            received[#received + 1] = result
        end)
        fake:tick(1)
        assert.equal(#received, 1)
        assert.error_code(received[1], 'PLATFORM_RESULT_UNKNOWN')
        fake:tick(2)
        assert.equal(#received, 1)
        assert.equal(#fake:get_suppressed_deliveries(), 1)
        assert.equal(fake:assert_exhausted(), true)
    end),

    case('mutating Fake calls wait, replay, and reject idempotency conflicts', function()
        local FakeSaveStore = require 'wzx.adapters.fake.services.fake_save_store'
        local fake = FakeSaveStore.new()
        local key = 'idempotency-stage-001'
        local scripted_result = success_fixture('SaveStore', 'stage_slot')
        scripted_result.request_key = key
        assert.equal(fake:expect(
            'stage_slot',
            ScriptedPort.success(scripted_result, 2)
        ).ok, true)
        scripted_result.checkpoint_id = 'checkpoint:mutated-after-enqueue'

        local primary_request = stage_request('101', key, 10)
        local waiting_request = stage_request('102', key, 10)
        waiting_request.context.attempt = 2
        local primary_result
        local waiting_result
        local primary = fake:stage_slot(primary_request, function(result)
            primary_result = result
        end)
        local waiting = fake:stage_slot(waiting_request, function(result)
            waiting_result = result
        end)
        assert.deep_equal(primary.value, { accepted = true })
        assert.deep_equal(waiting.value, { accepted = true })
        assert.is_nil(primary_result)
        assert.is_nil(waiting_result)

        primary_request.dto.payload.balance = 999
        assert.equal(fake:tick(2).value.processed_deliveries, 2)
        assert.equal(primary_result.ok, true)
        assert.equal(waiting_result.ok, true)
        assert.equal(primary_result.value.checkpoint_id, 'checkpoint:1')
        assert.equal(waiting_result.value.checkpoint_id, 'checkpoint:1')
        assert.truthy(primary_result ~= waiting_result)
        assert.truthy(primary_result.value ~= waiting_result.value)

        primary_result.value.checkpoint_id = 'checkpoint:callback-mutated'
        assert.equal(waiting_result.value.checkpoint_id, 'checkpoint:1')

        local replay_result
        local replay = fake:stage_slot(stage_request('103', key, 10), function(result)
            replay_result = result
        end)
        assert.deep_equal(replay.value, { accepted = true })
        assert.is_nil(replay_result)
        fake:tick(0)
        assert.equal(replay_result.ok, true)
        assert.equal(replay_result.value.checkpoint_id, 'checkpoint:1')

        local conflict_result
        local conflict = fake:stage_slot(stage_request('104', key, 11), function(result)
            conflict_result = result
        end)
        assert.error_code(conflict, 'IDEMPOTENCY_KEY_REUSED')
        assert.is_nil(conflict_result)
        fake:tick(0)
        assert.is_nil(conflict_result)

        local calls = fake:get_calls('stage_slot')
        assert.equal(#calls, 4)
        assert.equal(calls[1].request.dto.payload.balance, 10)
        assert.equal(calls[1].request_fingerprint, calls[2].request_fingerprint)
        assert.equal(calls[1].request_fingerprint, calls[3].request_fingerprint)
        assert.truthy(calls[1].request_fingerprint ~= calls[4].request_fingerprint)
        assert.equal(calls[2].idempotency_replay, true)
        assert.equal(calls[3].idempotency_replay, true)
        assert.equal(calls[4].idempotency_replay, true)
        assert.equal(fake:assert_exhausted(), true)
    end),

    case('accepted mutations bind request keys and normalize ambiguous completions', function()
        local SaveStore = require 'wzx.application.ports.save_store'
        local key = 'idempotency-completion-gate'
        local request = stage_request('completion-gate', key, 10)

        local function deliver(raw_result)
            local received
            local gate, _, gate_error = SaveStore:completion_gate(
                'stage_slot',
                function(result)
                    received = result
                end,
                nil,
                request
            )
            assert.is_nil(gate_error)
            assert.equal(gate(raw_result), true)
            return received
        end

        local confirmed = success_fixture('SaveStore', 'stage_slot')
        confirmed.request_key = key
        local received = deliver(PortContract.ok(confirmed))
        assert.equal(received.ok, true)
        assert.equal(received.value.request_key, key)

        received = deliver(PortContract.error('SAVE_REVISION_CONFLICT', {
            request_key = key,
        }, false))
        assert.error_code(received, 'SAVE_REVISION_CONFLICT')
        assert.equal(received.error.details.request_key, key)

        local missing_key = success_fixture('SaveStore', 'stage_slot')
        missing_key.request_key = nil
        local wrong_key = success_fixture('SaveStore', 'stage_slot')
        wrong_key.request_key = 'idempotency-wrong-key'
        local ambiguous = {
            PortContract.ok(missing_key),
            PortContract.ok(wrong_key),
            PortContract.error('PLATFORM_UNAVAILABLE', {
                request_key = key,
            }, false),
            PortContract.error('PLATFORM_RATE_LIMITED', {
                request_key = key,
            }, false),
            PortContract.error('PORT_ADAPTER_FAILED', {
                request_key = key,
            }, false),
            'malformed-completion',
        }
        local index
        for index = 1, #ambiguous do
            received = deliver(ambiguous[index])
            assert.error_code(received, 'PLATFORM_RESULT_UNKNOWN')
            assert.equal(received.error.retryable, false)
            assert.equal(received.error.details.request_key, key)
            assert.equal(received.error.details.recovery, 'QUERY_OR_RECONCILE')
        end
    end),

    case('assert_exhausted fails on queued or pending work and passes after delivery', function()
        local FakeClockService = require 'wzx.adapters.fake.services.fake_clock_service'
        local fake = FakeClockService.new()
        local value = success_fixture('ClockService', 'now')
        value.unix_seconds = 1
        fake:expect('now', ScriptedPort.success(value, 1))
        assert.throws(function()
            fake:assert_exhausted()
        end, 'ScriptedPort not exhausted')

        local completion
        fake:now({ context = context(false) }, function(result)
            completion = result
        end)
        assert.throws(function()
            fake:assert_exhausted()
        end, 'ScriptedPort not exhausted')
        fake:tick(1)
        assert.equal(completion.ok, true)
        assert.equal(fake:verify_exhausted().ok, true)
        assert.equal(fake:assert_exhausted(), true)
    end),

    case('ScriptedPort rejects malformed requests synchronously without a callback', function()
        local FakeClockService = require 'wzx.adapters.fake.services.fake_clock_service'
        local fake = FakeClockService.new({
            default_step = ScriptedPort.success(
                success_fixture('ClockService', 'now')
            ),
        })
        local received
        local invocation = fake:now({}, function(result)
            received = result
        end)
        assert.error_code(invocation, 'PORT_REQUEST_CONTEXT_INVALID')
        assert.is_nil(received)
        assert.equal(fake:tick(0).value.processed_deliveries, 0)
        assert.is_nil(received)
        assert.equal(fake:get_calls('now')[1].state, 'ADMISSION_REJECTED')
        assert.equal(fake:assert_exhausted(), true)
    end),

    case('ScriptedPort applies business and context whitelists before scripting', function()
        local FakeClockService = require 'wzx.adapters.fake.services.fake_clock_service'
        local fake = FakeClockService.new({
            default_step = ScriptedPort.success(
                success_fixture('ClockService', 'now')
            ),
        })

        local business_result
        local business_admission = fake:now({
            context = context(false),
            unexpected_business_field = true,
        }, function(result)
            business_result = result
        end)
        assert.is_nil(business_result)
        assert.error_code(business_admission, 'PORT_REQUEST_INVALID')
        assert.equal(business_admission.error.details.reason, 'UNKNOWN_FIELD')
        assert.equal(fake:tick(0).value.processed_deliveries, 0)
        assert.is_nil(business_result)

        local invalid_context = context(false)
        invalid_context.unexpected_context_field = true
        local context_result
        local context_admission = fake:now({ context = invalid_context }, function(result)
            context_result = result
        end)
        assert.is_nil(context_result)
        assert.error_code(context_admission, 'PORT_REQUEST_CONTEXT_INVALID')
        assert.equal(context_admission.error.details.reason, 'UNKNOWN_FIELD')
        assert.equal(fake:tick(0).value.processed_deliveries, 0)
        assert.is_nil(context_result)

        assert.equal(fake:get_diagnostics().script_issue_count, 0)
        assert.equal(fake:assert_exhausted(), true)
    end),
}
