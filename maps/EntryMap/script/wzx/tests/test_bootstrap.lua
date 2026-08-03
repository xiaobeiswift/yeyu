local Harness = require 'wzx.tests.harness'
local AppFactory = require 'wzx.bootstrap.app_factory'
local ReloadGuard = require 'wzx.bootstrap.reload_guard'
local Result = require 'wzx.domain.common.result'
local PortContract = require 'wzx.application.ports.port_contract'
local UnavailableService = require 'wzx.adapters.unavailable.service'
local Y3Runtime = require 'wzx.bootstrap.y3_runtime'

local case = Harness.case
local assert = Harness.assert
local CHECKSUM = string.rep('a', 64)
local OWNER_HASH = string.rep('b', 64)

local function safe_dependencies()
    local dependencies = {}
    local definitions = AppFactory.port_definitions()
    local index
    for index = 1, #definitions do
        local created = UnavailableService.create(
            definitions[index].spec,
            'TEST_CAPABILITY_UNVERIFIED'
        )
        assert.equal(created.ok, true)
        dependencies[definitions[index].key] = created.value
    end
    return dependencies, definitions
end

local function assert_all_flags_disabled(flags)
    local expected = {
        arena = true,
        cloud_save = true,
        open_archive = true,
        paid_gacha = true,
        platform_store = true,
        server_refresh = true,
    }
    local count = 0
    local key
    for key in pairs(flags) do
        assert.equal(expected[key], true, 'unknown feature flag: ' .. tostring(key))
        assert.equal(flags[key], false, key .. ' must default to disabled')
        count = count + 1
    end
    assert.equal(count, 6)
end

local function valid_context(include_idempotency)
    local value = {
        request_id = 'bootstrap-request-1',
        correlation_id = 'bootstrap-correlation-1',
        attempt = 1,
    }
    if include_idempotency then
        value.idempotency_key = 'bootstrap-idempotency-1'
    end
    return value
end

local function valid_stage_request()
    return {
        context = valid_context(true),
        player_ref = 'player001',
        slot_id = 1,
        expected_revision = 0,
        checkpoint_id = 'checkpoint:1',
        payload_checksum = CHECKSUM,
        dto = {
            schema_version = 1,
            revision = 1,
            checkpoint_id = 'checkpoint:1',
            content_version = 'content-v1',
            owner_fingerprint = 'owner_v1_' .. OWNER_HASH,
            payload_checksum = CHECKSUM,
            written_at = 1,
            payload = { marker = 'bootstrap' },
        },
    }
end

local function with_clean_runtime(callback)
    Y3Runtime.stop()
    local ok, failure = xpcall(callback, debug.traceback)
    Y3Runtime.stop()
    if not ok then
        error(failure, 0)
    end
end

return {
    case('app factory accepts all six unavailable service implementations', function()
        local dependencies, definitions = safe_dependencies()
        assert.equal(#definitions, 6)

        local created = AppFactory.create(dependencies)
        assert.equal(created.ok, true)
        local app = created.value
        local status = app:get_status()
        assert.equal(status.state, 'CREATED')
        assert.equal(status.generation, 0)
        assert.is_nil(app.state)
        assert.is_nil(app.generation)
        assert.is_nil(app.feature_flags)
        assert.equal(app.schemas.versions.FOUNDATION_CONTRACT_VERSION, 1)

        local index
        for index = 1, #definitions do
            local definition = definitions[index]
            assert.truthy(
                app.services[definition.key] ~= dependencies[definition.key],
                definition.key .. ' must be exposed through a guard proxy'
            )
            assert.equal(
                definition.spec:validate_implementation(app.services[definition.key]).ok,
                true
            )
        end
        assert_all_flags_disabled(status.feature_flags)
        status.feature_flags.cloud_save = true
        assert.equal(app:get_status().feature_flags.cloud_save, false)

        local completion
        local accepted = app.services.clock_service:now({
            context = valid_context(),
        }, function(result)
            completion = result
        end)
        assert.error_code(accepted, 'PLATFORM_UNAVAILABLE')
        assert.equal(accepted.error.retryable, true)
        assert.equal(accepted.error.details.recovery, 'RETRY_WITH_BACKOFF')
        assert.is_nil(accepted.error.details.request_key)
        assert.is_nil(completion)

        local mutating_completion
        accepted = app.services.save_store:stage_slot(valid_stage_request(), function(result)
            mutating_completion = result
        end)
        assert.error_code(accepted, 'PLATFORM_UNAVAILABLE')
        assert.equal(accepted.error.retryable, false)
        assert.equal(
            accepted.error.details.recovery,
            'QUERY_OR_RECONCILE'
        )
        assert.is_nil(accepted.error.details.request_key)
        assert.is_nil(mutating_completion)

        assert.throws(function()
            app.services.clock_service = {}
        end, 'application services is read-only')
        assert.throws(function()
            app.services.clock_service.now = function() end
        end, 'application services.clock_service is read-only')

        assert.error_reason(
            AppFactory.create(dependencies, 'scalar-options'),
            'OPTIONS_TABLE_REQUIRED'
        )
    end),

    case('app guard snapshots accepted adapter requests and completions', function()
        local dependencies = safe_dependencies()
        local adapter_request
        local adapter_complete
        dependencies.clock_service = {
            now = function(_, request, complete)
                adapter_request = request
                adapter_complete = complete
                return PortContract.ok({ accepted = true })
            end,
        }

        local app = AppFactory.create(dependencies).value
        local request = { context = valid_context(false) }
        local completion
        local admission = app.services.clock_service:now(request, function(result)
            completion = result
        end)
        assert.deep_equal(admission, PortContract.ok({ accepted = true }))
        assert.is_nil(completion)
        assert.equal(adapter_request.context.request_id, 'bootstrap-request-1')

        request.context.request_id = 'caller-mutated'
        assert.equal(adapter_request.context.request_id, 'bootstrap-request-1')
        adapter_request.context.request_id = 'adapter-mutated'
        assert.equal(request.context.request_id, 'caller-mutated')

        local adapter_result = PortContract.ok({
            unix_seconds = 1234,
            trust_level = 'TRUSTED',
            response_id = 'clock-response-proxy',
        })
        assert.equal(adapter_complete(adapter_result), true)
        assert.equal(completion.ok, true)
        assert.equal(completion.value.unix_seconds, 1234)
        adapter_result.value.unix_seconds = 9999
        assert.equal(completion.value.unix_seconds, 1234)
    end),

    case('app guard rejects hostile adapter admissions without leaking callbacks', function()
        local valid_clock_result = function()
            return PortContract.ok({
                unix_seconds = 1234,
                trust_level = 'TRUSTED',
                response_id = 'clock-response-hostile',
            })
        end
        local scenarios = {
            {
                expected_code = 'PORT_ADAPTER_CALLBACK_INLINE',
                method = function(_, _, complete)
                    complete(valid_clock_result())
                    return PortContract.ok({ accepted = true })
                end,
            },
            {
                expected_code = 'PORT_ADAPTER_FAILED',
                method = function()
                    error('hostile adapter raised')
                end,
            },
            {
                expected_code = 'PORT_ADAPTER_RETURN_INVALID',
                method = function()
                    return 'not-a-port-result'
                end,
            },
        }

        local index
        for index = 1, #scenarios do
            local dependencies = safe_dependencies()
            dependencies.clock_service = { now = scenarios[index].method }
            local app = AppFactory.create(dependencies).value
            local completion
            local admission = app.services.clock_service:now({
                context = valid_context(false),
            }, function(result)
                completion = result
            end)
            assert.error_code(admission, scenarios[index].expected_code)
            assert.is_nil(completion)
        end
    end),

    case('mutating adapter admission failures preserve the reconciliation key', function()
        local scenarios = {
            function(_, _, complete)
                complete(PortContract.ok({}))
                return PortContract.ok({ accepted = true })
            end,
            function()
                error('mutating adapter raised')
            end,
            function()
                return 'not-a-port-result'
            end,
        }
        local index
        for index = 1, #scenarios do
            local dependencies = safe_dependencies()
            dependencies.save_store.stage_slot = scenarios[index]
            local app = AppFactory.create(dependencies).value
            local completion
            local admission = app.services.save_store:stage_slot(
                valid_stage_request(),
                function(result)
                    completion = result
                end
            )
            assert.error_code(admission, 'PLATFORM_RESULT_UNKNOWN')
            assert.equal(admission.error.retryable, false)
            assert.equal(
                admission.error.details.recovery,
                'QUERY_OR_RECONCILE'
            )
            assert.equal(
                admission.error.details.request_key,
                'bootstrap-idempotency-1'
            )
            assert.is_nil(completion)
        end
    end),

    case('application start and stop are idempotent but stopped apps cannot restart', function()
        local dependencies = safe_dependencies()
        local app = AppFactory.create(dependencies).value
        assert.throws(function()
            app.state = 'STOPPED'
        end, 'application instance is read-only')
        assert.throws(function()
            app.generation = 999
        end, 'application instance is read-only')
        assert.throws(function()
            app.feature_flags = { arena = true }
        end, 'application instance is read-only')
        local pristine = app:get_status()
        assert.equal(pristine.state, 'CREATED')
        assert.equal(pristine.generation, 0)
        assert.equal(pristine.feature_flags.arena, false)
        local started = app:start()
        assert.equal(started.ok, true)
        assert.equal(started.value.state, 'RUNNING')
        assert.equal(started.value.generation, 1)
        assert.equal(started.value.gameplay_systems_registered, 0)
        assert.equal(started.value.feature_flags.arena, false)
        started.value.feature_flags.arena = true
        assert.equal(app:get_status().feature_flags.arena, false)

        local started_again = app:start()
        assert.equal(started_again.ok, true)
        assert.equal(started_again.value.state, 'RUNNING')
        assert.equal(started_again.value.generation, 1)

        local stopped = app:stop()
        assert.equal(stopped.ok, true)
        assert.equal(stopped.value.state, 'STOPPED')
        assert.equal(stopped.value.generation, 1)

        local stopped_again = app:stop()
        assert.equal(stopped_again.ok, true)
        assert.equal(stopped_again.value.state, 'STOPPED')
        assert.equal(stopped_again.value.generation, 1)

        local restarted = app:start()
        assert.error_code(restarted, 'BOOTSTRAP_INVALID')
        assert.error_reason(restarted, 'STOPPED_APP_CANNOT_RESTART')
    end),

    case('app factory passes sorted system registrars into the pre-seal window', function()
        local dependencies = safe_dependencies()
        local observed_mutable = false
        local created = AppFactory.create(dependencies, {
            system_registrars = {
                {
                    system_id = '06',
                    register = function(context)
                        observed_mutable = not context.event_schemas:is_sealed()
                            and not context.section_owners:is_sealed()
                        return Result.ok(true)
                    end,
                },
            },
        })
        assert.equal(created.ok, true)
        assert.equal(observed_mutable, true)
        assert.equal(created.value.schemas.registrar_count, 1)
        assert.equal(created.value:get_status().gameplay_systems_registered, 1)
        assert.equal(created.value.schemas.event_schemas:is_sealed(), true)
        assert.equal(created.value.schemas.section_owners:is_sealed(), true)
    end),

    case('runtime safe default starts foundation-only and stops cleanly', function()
        with_clean_runtime(function()
            assert.is_nil(Y3Runtime.get_active_host())
            local started = Y3Runtime.start({ generation = 41 })
            assert.equal(started.ok, true)
            local host = started.value
            assert.equal(Y3Runtime.get_active_host(), host)
            assert.is_nil(host.mode)

            local status = host:get_status()
            assert.equal(status.state, 'RUNNING')
            assert.equal(status.generation, 1)
            assert.equal(status.runtime_mode, 'FOUNDATION_ONLY')
            assert.equal(status.runtime_generation, 41)
            assert.equal(status.platform_adapters_verified, false)
            assert.equal(status.gameplay_systems_registered, 0)
            assert_all_flags_disabled(status.feature_flags)

            local duplicate_start = Y3Runtime.start({ generation = 999 })
            assert.equal(duplicate_start.ok, true)
            assert.equal(duplicate_start.value, host)
            assert.equal(duplicate_start.value:get_status().runtime_generation, 41)

            local stopped = Y3Runtime.stop()
            assert.equal(stopped.ok, true)
            assert.equal(stopped.value.state, 'STOPPED')
            assert.is_nil(Y3Runtime.get_active_host())

            local stopped_again = Y3Runtime.stop()
            assert.equal(stopped_again.ok, true)
            assert.equal(stopped_again.value.state, 'STOPPED')
            assert.equal(host:stop().ok, true)
        end)
    end),

    case('runtime rejects feature capability and compliance overrides', function()
        local override_fields = {
            'release_flags',
            'capabilities',
            'compliance_gates',
        }
        local index
        for index = 1, #override_fields do
            with_clean_runtime(function()
                local options = {}
                options[override_fields[index]] = { paid_gacha = true }
                local started = Y3Runtime.start(options)
                assert.error_code(started, 'BOOTSTRAP_INVALID')
                assert.is_nil(Y3Runtime.get_active_host())
            end)
        end

        with_clean_runtime(function()
            assert.error_code(Y3Runtime.start('scalar-options'), 'BOOTSTRAP_INVALID')
            local started = Y3Runtime.start({ generation = 1 })
            assert.equal(started.ok, true)
            assert.equal(started.value:get_status().feature_flags.paid_gacha, false)
        end)
    end),

    case('runtime hosts are read-only and forged replacements are rejected', function()
        with_clean_runtime(function()
            local started = Y3Runtime.start({ generation = 41 })
            assert.equal(started.ok, true)
            local host = started.value

            local protected_fields = {
                stop = false,
                app = {},
                generation = 999,
                mode = 'FORGED',
            }
            local field_name
            local forged_value
            for field_name, forged_value in pairs(protected_fields) do
                assert.throws(function()
                    host[field_name] = forged_value
                end, 'runtime host is read-only')
            end
            assert.equal(type(host.stop), 'function')
            assert.is_nil(host.app)
            assert.is_nil(host.generation)
            assert.is_nil(host.mode)
            assert.equal(host:get_status().runtime_generation, 41)
            assert.equal(host:get_status().runtime_mode, 'FOUNDATION_ONLY')

            assert.error_code(ReloadGuard.stop_previous({
                stop = function()
                    return Result.ok(true)
                end,
            }), 'RELOAD_BLOCKED')
            assert.error_code(ReloadGuard.stop_previous(nil), 'RELOAD_BLOCKED')
            assert.equal(Y3Runtime.get_active_host(), host)

            local register_again, unregister_again =
                ReloadGuard.claim_host_registrar()
            assert.is_nil(register_again)
            assert.is_nil(unregister_again)
        end)
    end),

    case('reload authority survives stop failure and is revoked after success', function()
        with_clean_runtime(function()
            local host = Y3Runtime.start({ generation = 51 }).value
            local host_metatable = debug.getmetatable(host)
            local host_methods = host_metatable.__index
            local original_stop = host_methods.stop
            local stop_attempts = 0
            local succeeded, failure = xpcall(function()
                host_methods.stop = function(self)
                    stop_attempts = stop_attempts + 1
                    if stop_attempts == 1 then
                        return Result.err(
                            'STOP_REJECTED',
                            'error.test.stop_rejected',
                            false
                        )
                    end
                    return original_stop(self)
                end

                local rejected = ReloadGuard.stop_previous(host)
                assert.error_code(rejected, 'RELOAD_BLOCKED')
                assert.equal(stop_attempts, 1)
                assert.equal(Y3Runtime.get_active_host(), host)

                local stopped = ReloadGuard.stop_previous(host)
                assert.equal(stopped.ok, true)
                assert.equal(stopped.value, true)
                assert.equal(stop_attempts, 2)
                assert.is_nil(Y3Runtime.get_active_host())

                assert.error_code(
                    ReloadGuard.stop_previous(host),
                    'RELOAD_BLOCKED'
                )
            end, debug.traceback)
            host_methods.stop = original_stop
            if not succeeded then
                error(failure, 0)
            end
        end)
    end),

    case('blocked development reload preserves an unregistered global replacement', function()
        local previous_host = rawget(_G, 'WZX_RUNTIME_HOST')
        local previous_generation = rawget(_G, 'WZX_RUNTIME_GENERATION')
        local previous_module = package.loaded['wzx.bootstrap.dev_runtime']
        local authority = {
            stop = function()
                return Result.err('STOP_REJECTED', 'error.test.stop_rejected', false)
            end,
        }

        local succeeded, failure = xpcall(function()
            rawset(_G, 'WZX_RUNTIME_HOST', authority)
            rawset(_G, 'WZX_RUNTIME_GENERATION', 77)
            package.loaded['wzx.bootstrap.dev_runtime'] = nil
            require 'wzx.bootstrap.dev_runtime'
            assert.equal(rawget(_G, 'WZX_RUNTIME_HOST'), authority)
            assert.equal(rawget(_G, 'WZX_RUNTIME_GENERATION'), 77)
        end, debug.traceback)

        rawset(_G, 'WZX_RUNTIME_HOST', previous_host)
        rawset(_G, 'WZX_RUNTIME_GENERATION', previous_generation)
        package.loaded['wzx.bootstrap.dev_runtime'] = previous_module
        if not succeeded then
            error(failure, 0)
        end
    end),

    case('direct host stop clears its global anchor and permits development restart', function()
        local previous_host = rawget(_G, 'WZX_RUNTIME_HOST')
        local previous_generation = rawget(_G, 'WZX_RUNTIME_GENERATION')
        local previous_dev_runtime = package.loaded['wzx.bootstrap.dev_runtime']
        local previous_reload_manifest =
            package.loaded['wzx.bootstrap.reload_manifest']
        local reload_modules = require 'wzx.bootstrap.reload_manifest'
        local saved_modules = {}
        local index
        for index = 1, #reload_modules do
            saved_modules[reload_modules[index]] =
                package.loaded[reload_modules[index]]
        end

        Y3Runtime.stop()
        local succeeded, failure = xpcall(function()
            local host = Y3Runtime.start({ generation = 61 }).value
            rawset(_G, 'WZX_RUNTIME_HOST', host)
            rawset(_G, 'WZX_RUNTIME_GENERATION', 61)

            local stopped = host:stop()
            assert.equal(stopped.ok, true)
            assert.is_nil(rawget(_G, 'WZX_RUNTIME_HOST'))
            assert.is_nil(Y3Runtime.get_active_host())

            package.loaded['wzx.bootstrap.dev_runtime'] = nil
            require 'wzx.bootstrap.dev_runtime'
            local replacement = rawget(_G, 'WZX_RUNTIME_HOST')
            local replacement_runtime =
                package.loaded['wzx.bootstrap.y3_runtime']
            assert.not_nil(replacement)
            assert.truthy(replacement ~= host)
            assert.equal(
                replacement_runtime.get_active_host(),
                replacement
            )
            assert.equal(replacement:get_status().state, 'RUNNING')
            assert.equal(replacement:get_status().runtime_generation, 62)
            assert.equal(replacement:stop().ok, true)
            assert.is_nil(rawget(_G, 'WZX_RUNTIME_HOST'))
        end, debug.traceback)

        local replacement_runtime = package.loaded['wzx.bootstrap.y3_runtime']
        if type(replacement_runtime) == 'table'
            and type(replacement_runtime.stop) == 'function'
        then
            replacement_runtime.stop()
        end
        for index = 1, #reload_modules do
            package.loaded[reload_modules[index]] =
                saved_modules[reload_modules[index]]
        end
        package.loaded['wzx.bootstrap.reload_manifest'] =
            previous_reload_manifest
        package.loaded['wzx.bootstrap.dev_runtime'] = previous_dev_runtime
        rawset(_G, 'WZX_RUNTIME_HOST', previous_host)
        rawset(_G, 'WZX_RUNTIME_GENERATION', previous_generation)
        Y3Runtime.stop()
        if not succeeded then
            error(failure, 0)
        end
    end),
}
