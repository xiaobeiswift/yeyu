local PortContract = require "wzx.application.ports.port_contract"
local SerializableSnapshot = require "wzx.adapters.fake.serializable_snapshot"

local ScriptedPort = {}
local ScriptedPortMethods = {}

local function is_non_negative_integer(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math.floor(value)
        and value >= 0
end

local function dense_array_length(value)
    local count = 0
    local maximum = 0
    local key

    if type(value) ~= "table" then
        return nil
    end
    for key in pairs(value) do
        if not is_non_negative_integer(key) or key < 1 then
            return nil
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
    end
    if count ~= maximum then
        return nil
    end
    return maximum
end

local function script_error(reason, details)
    details = details or {}
    details.reason = reason
    return PortContract.error("FAKE_SCRIPT_INVALID", details, false)
end

local function freeze_result(result, path)
    local copied

    if not PortContract.is_result(result) then
        return script_error("RESULT_ENVELOPE_INVALID", {
            path = path,
        })
    end
    copied = SerializableSnapshot.deep_copy(result, path)
    if not copied.ok then
        return script_error("RESULT_NOT_SERIALIZABLE", {
            path = path,
            cause_code = copied.error.code,
            cause_details = copied.error.details,
        })
    end
    return PortContract.ok(copied.value)
end

local function freeze_operation_result(
    result,
    path,
    spec,
    operation_name
)
    local validated

    if spec ~= nil and operation_name ~= nil then
        validated = PortContract.sanitize_completion_result(
            spec,
            operation_name,
            result
        )
        if not validated.ok then
            return script_error("OPERATION_RESULT_INVALID", {
                path = path,
                port = PortContract.get_contract_name(spec),
                operation = operation_name,
                cause_code = validated.error and validated.error.code or nil,
                cause_details = validated.error and validated.error.details or nil,
            })
        end
        result = validated.value
    end
    return freeze_result(result, path)
end

local function prepare_step(step, path, spec, operation_name)
    local prepared_deliveries = {}
    local deliveries_length
    local index
    local delivery
    local delay_ticks
    local duplicate_count
    local duplicate_index
    local frozen

    if type(step) == "function" then
        return PortContract.ok({
            kind = "HANDLER",
            handler = step,
        })
    end

    if PortContract.is_result(step) then
        frozen = freeze_operation_result(
            step,
            path .. ".result",
            spec,
            operation_name
        )
        if not frozen.ok then
            return frozen
        end
        return PortContract.ok({
            kind = "DELIVERIES",
            deliveries = {
                {
                    after_ticks = 0,
                    result = frozen.value,
                },
            },
        })
    end

    if type(step) ~= "table" then
        return script_error("STEP_TABLE_RESULT_OR_HANDLER_REQUIRED", {
            path = path,
        })
    end
    if step.drop == true then
        return PortContract.ok({
            kind = "DROP",
        })
    end

    if step.deliveries ~= nil then
        deliveries_length = dense_array_length(step.deliveries)
        if deliveries_length == nil or deliveries_length < 1 then
            return script_error("DENSE_NON_EMPTY_DELIVERIES_REQUIRED", {
                path = path .. ".deliveries",
            })
        end
        for index = 1, deliveries_length do
            delivery = step.deliveries[index]
            if type(delivery) ~= "table"
                or not is_non_negative_integer(delivery.after_ticks or 0)
                or delivery.result == nil
            then
                return script_error("DELIVERY_INVALID", {
                    path = path .. ".deliveries[" .. tostring(index) .. "]",
                })
            end
            frozen = freeze_operation_result(
                delivery.result,
                path .. ".deliveries[" .. tostring(index) .. "].result",
                spec,
                operation_name
            )
            if not frozen.ok then
                return frozen
            end
            prepared_deliveries[#prepared_deliveries + 1] = {
                after_ticks = delivery.after_ticks or 0,
                result = frozen.value,
            }
        end
        return PortContract.ok({
            kind = "DELIVERIES",
            deliveries = prepared_deliveries,
        })
    end

    if step.result == nil then
        return script_error("RESULT_REQUIRED", {
            path = path,
        })
    end
    delay_ticks = step.delay_ticks or 0
    duplicate_count = step.duplicate_count or 1
    if not is_non_negative_integer(delay_ticks)
        or not is_non_negative_integer(duplicate_count)
        or duplicate_count < 1
    then
        return script_error("DELAY_OR_DUPLICATE_COUNT_INVALID", {
            path = path,
        })
    end

    frozen = freeze_operation_result(
        step.result,
        path .. ".result",
        spec,
        operation_name
    )
    if not frozen.ok then
        return frozen
    end
    for duplicate_index = 1, duplicate_count do
        prepared_deliveries[#prepared_deliveries + 1] = {
            after_ticks = delay_ticks,
            result = frozen.value,
        }
    end
    return PortContract.ok({
        kind = "DELIVERIES",
        deliveries = prepared_deliveries,
    })
end

local function validate_prepared_step(
    spec,
    operation_name,
    prepared,
    path,
    request
)
    local index
    local checked

    if prepared.kind ~= "DELIVERIES" then
        return PortContract.ok(prepared)
    end
    for index = 1, #prepared.deliveries do
        checked = PortContract.sanitize_completion_result(
            spec,
            operation_name,
            prepared.deliveries[index].result,
            request
        )
        if not checked.ok then
            return script_error("OPERATION_RESULT_INVALID", {
                path = path .. ".deliveries[" .. tostring(index) .. "].result",
                port = PortContract.get_contract_name(spec),
                operation = operation_name,
                cause_code = checked.error and checked.error.code or nil,
                cause_details = checked.error and checked.error.details or nil,
            })
        end
        prepared.deliveries[index].result = checked.value
    end
    return PortContract.ok(prepared)
end

local function get_script_queue(self, operation_name)
    local queue = self._scripts[operation_name]
    if not queue then
        queue = {
            items = {},
            head = 1,
            tail = 0,
        }
        self._scripts[operation_name] = queue
    end
    return queue
end

local function pop_script(self, operation_name)
    local queue = get_script_queue(self, operation_name)
    local step = queue.items[queue.head]

    if step ~= nil then
        queue.items[queue.head] = nil
        queue.head = queue.head + 1
        if queue.head > queue.tail then
            queue.items = {}
            queue.head = 1
            queue.tail = 0
        end
    end
    return step
end

local function pending_script_count(queue)
    return queue.tail - queue.head + 1
end

local function sort_scheduled(self)
    table.sort(self._scheduled, function(left, right)
        if left.due_tick ~= right.due_tick then
            return left.due_tick < right.due_tick
        end
        return left.order < right.order
    end)
end

local function schedule_delivery(self, call_record, delivery, gate)
    self._next_schedule_order = self._next_schedule_order + 1
    self._scheduled[#self._scheduled + 1] = {
        due_tick = self._tick + delivery.after_ticks,
        order = self._next_schedule_order,
        call_record = call_record,
        result = delivery.result,
        gate = gate,
    }
    call_record.scheduled_delivery_count = call_record.scheduled_delivery_count + 1
    if call_record.state ~= "WAITING_IDEMPOTENCY" then
        call_record.state = "SCHEDULED"
    end
end

local function copy_or_fallback(value, path)
    local copied = SerializableSnapshot.deep_copy(value, path)
    if copied.ok then
        return copied.value
    end
    return PortContract.error("FAKE_RESULT_SNAPSHOT_FAILED", {
        cause_code = copied.error.code,
        cause_details = copied.error.details,
    }, false)
end

local function complete_idempotency_entry(self, entry, terminal_result)
    local waiter_index
    local waiter

    if entry == nil or entry.state == "TERMINAL" then
        return
    end
    entry.state = "TERMINAL"
    entry.terminal_result = copy_or_fallback(
        terminal_result,
        "$idempotency.terminal_result"
    )

    for waiter_index = 1, #entry.waiters do
        waiter = entry.waiters[waiter_index]
        schedule_delivery(self, waiter.call_record, {
            after_ticks = 0,
            result = entry.terminal_result,
        }, waiter.gate)
    end
    entry.waiters = {}
end

local function create_gate(
    self,
    call_record,
    complete,
    idempotency_entry,
    binding_request
)
    local gate
    local state_reader
    local gate_error

    gate, state_reader, gate_error = PortContract.completion_gate(
        self._spec,
        call_record.operation,
        function(result)
        local stored_result = copy_or_fallback(
            result,
            "$calls[" .. tostring(call_record.call_index) .. "].completion_result"
        )
        local outward_result

        call_record.state = "COMPLETED"
        call_record.completed_tick = self._tick
        call_record.completion_result = stored_result
        complete_idempotency_entry(self, idempotency_entry, stored_result)

        outward_result = copy_or_fallback(stored_result, "$callback.result")
        complete(outward_result)
    end,
    function(result, suppressed_count)
        local copied_result = copy_or_fallback(result, "$suppressed.result")
        call_record.suppressed_delivery_count = suppressed_count
        self._suppressed_deliveries[#self._suppressed_deliveries + 1] = {
            call_index = call_record.call_index,
            operation = call_record.operation,
            tick = self._tick,
            result = copied_result,
            suppressed_count = suppressed_count,
        }
    end,
    binding_request or call_record.request
    )
    if gate_error ~= nil then
        error("failed to create operation-aware Fake completion gate")
    end

    self._gate_state_by_call[call_record.call_index] = state_reader
    return gate
end

local function run_due(self, maximum_count)
    local processed = 0
    local delivery
    local copied_result

    while #self._scheduled > 0
        and (maximum_count == nil or processed < maximum_count)
    do
        sort_scheduled(self)
        if self._scheduled[1].due_tick > self._tick then
            break
        end
        delivery = table.remove(self._scheduled, 1)
        copied_result = copy_or_fallback(delivery.result, "$scheduled.result")
        delivery.gate(copied_result)
        processed = processed + 1
    end
    return processed
end

local function maybe_run_immediate(self)
    if self._auto_run_immediate then
        run_due(self)
    end
end

local function schedule_terminal(self, call_record, gate, result)
    local frozen = freeze_result(result, "$terminal.result")
    local delivery_result

    if frozen.ok then
        delivery_result = frozen.value
    else
        delivery_result = frozen
    end
    schedule_delivery(self, call_record, {
        after_ticks = 0,
        result = delivery_result,
    }, gate)
    maybe_run_immediate(self)
end

local function make_call_record(self, operation_name)
    self._next_call_index = self._next_call_index + 1
    local record = {
        call_index = self._next_call_index,
        operation = operation_name,
        request = nil,
        request_fingerprint = nil,
        idempotency_key = nil,
        idempotency_replay = false,
        started_tick = self._tick,
        completed_tick = nil,
        state = "VALIDATING",
        completion_result = nil,
        scheduled_delivery_count = 0,
        suppressed_delivery_count = 0,
    }
    self._calls[#self._calls + 1] = record
    return record
end

local function reject_admission(self, call_record, result)
    call_record.state = "ADMISSION_REJECTED"
    call_record.completed_tick = self._tick
    call_record.completion_result = copy_or_fallback(
        result,
        "$calls[" .. tostring(call_record.call_index) .. "].admission_result"
    )
    return result
end

local function get_idempotency_bucket(self, operation_name)
    local bucket = self._idempotency[operation_name]
    if not bucket then
        bucket = {}
        self._idempotency[operation_name] = bucket
    end
    return bucket
end

local function bind_idempotency(
    self,
    operation,
    request,
    fingerprint,
    call_record
)
    local idempotency_key
    local bucket
    local entry

    if operation.requires_idempotency ~= true then
        return PortContract.ok({
            mode = "NONE",
        })
    end

    idempotency_key = request.context.idempotency_key
    bucket = get_idempotency_bucket(self, operation.name)
    entry = bucket[idempotency_key]
    call_record.idempotency_key = idempotency_key

    if entry ~= nil then
        call_record.idempotency_replay = true
        if entry.fingerprint ~= fingerprint then
            return PortContract.ok({
                mode = "MISMATCH",
                result = PortContract.error("IDEMPOTENCY_KEY_REUSED", {
                    operation = operation.name,
                    expected_fingerprint = entry.fingerprint,
                    actual_fingerprint = fingerprint,
                }, false),
            })
        end
        if entry.state == "TERMINAL" then
            return PortContract.ok({
                mode = "REPLAY",
                result = entry.terminal_result,
                entry = entry,
            })
        end

        call_record.state = "WAITING_IDEMPOTENCY"
        return PortContract.ok({
            mode = "WAITING",
            entry = entry,
        })
    end

    entry = {
        operation = operation.name,
        idempotency_key = idempotency_key,
        fingerprint = fingerprint,
        state = "PENDING",
        primary_call_index = call_record.call_index,
        primary_request = request,
        terminal_result = nil,
        waiters = {},
    }
    bucket[idempotency_key] = entry
    return PortContract.ok({
        mode = "PRIMARY",
        entry = entry,
    })
end

local function resolve_step(self, operation_name, request, call_record)
    local prepared = pop_script(self, operation_name)
    local handled
    local ok
    local resolved
    local handler_request
    local handler_record

    if prepared == nil then
        prepared = self._default_steps[operation_name]
            or self._default_step
    end
    if prepared == nil then
        self._script_issue_count = self._script_issue_count + 1
        return PortContract.error("FAKE_SCRIPT_EXHAUSTED", {
            port = PortContract.get_contract_name(self._spec),
            operation = operation_name,
        }, false)
    end

    if prepared.kind == "HANDLER" then
        handler_request = copy_or_fallback(request, "$handler.request")
        handler_record = copy_or_fallback(call_record, "$handler.call_record")
        ok, resolved = pcall(prepared.handler, handler_request, handler_record)
        if not ok then
            self._script_issue_count = self._script_issue_count + 1
            return PortContract.error("FAKE_SCRIPT_HANDLER_FAILED", {
                operation = operation_name,
                message = tostring(resolved),
            }, false)
        end
        handled = prepare_step(
            resolved,
            "$handler_result",
            self._spec,
            operation_name
        )
        if not handled.ok then
            self._script_issue_count = self._script_issue_count + 1
            return handled
        end
        handled = validate_prepared_step(
            self._spec,
            operation_name,
            handled.value,
            "$handler_result",
            request
        )
        if not handled.ok then
            self._script_issue_count = self._script_issue_count + 1
            return handled
        end
        return handled
    end

    handled = validate_prepared_step(
        self._spec,
        operation_name,
        prepared,
        "$resolved_step",
        request
    )
    if not handled.ok then
        self._script_issue_count = self._script_issue_count + 1
        return handled
    end
    return handled
end

local function invoke(self, operation_name, request, complete)
    local callback_result = PortContract.validate_callback(complete)
    local operation = PortContract.get_operation_descriptor(
        self._spec,
        operation_name
    )
    local call_record
    local frozen_request
    local call_request
    local gate
    local fingerprint_result
    local idempotency_result
    local idempotency_entry
    local step_result
    local index

    if not callback_result.ok then
        return callback_result
    end
    if operation == nil then
        return PortContract.error("PORT_OPERATION_UNKNOWN", {
            port = PortContract.get_contract_name(self._spec),
            operation = operation_name,
        }, false)
    end

    call_record = make_call_record(self, operation_name)

    frozen_request = PortContract.sanitize_request(
        self._spec,
        operation_name,
        request
    )
    if not frozen_request.ok then
        call_record.request_snapshot_error = {
            code = frozen_request.error.code,
            details = frozen_request.error.details,
        }
        return reject_admission(self, call_record, frozen_request)
    end
    call_request = SerializableSnapshot.deep_copy(
        frozen_request.value,
        "$call_record.request"
    )
    if not call_request.ok then
        return reject_admission(self, call_record, call_request)
    end
    call_record.request = call_request.value

    fingerprint_result = SerializableSnapshot.fingerprint_request(
        operation_name,
        frozen_request.value
    )
    if not fingerprint_result.ok then
        return reject_admission(self, call_record, fingerprint_result)
    end
    call_record.request_fingerprint = fingerprint_result.value

    idempotency_result = bind_idempotency(
        self,
        operation,
        frozen_request.value,
        fingerprint_result.value,
        call_record
    )
    if not idempotency_result.ok then
        return reject_admission(self, call_record, idempotency_result)
    end
    if idempotency_result.value.mode == "MISMATCH" then
        return reject_admission(
            self,
            call_record,
            idempotency_result.value.result
        )
    end
    if idempotency_result.value.mode == "REPLAY" then
        idempotency_entry = idempotency_result.value.entry
        gate = create_gate(
            self,
            call_record,
            complete,
            nil,
            idempotency_entry.primary_request
        )
        schedule_terminal(
            self,
            call_record,
            gate,
            idempotency_result.value.result
        )
        return PortContract.ok({ accepted = true })
    end
    if idempotency_result.value.mode == "WAITING" then
        idempotency_entry = idempotency_result.value.entry
        gate = create_gate(
            self,
            call_record,
            complete,
            nil,
            idempotency_entry.primary_request
        )
        idempotency_entry.waiters[#idempotency_entry.waiters + 1] = {
            call_record = call_record,
            gate = gate,
        }
        return PortContract.ok({ accepted = true })
    end
    idempotency_entry = idempotency_result.value.entry
    gate = create_gate(self, call_record, complete, idempotency_entry)

    call_record.state = "SCRIPTING"
    step_result = resolve_step(
        self,
        operation_name,
        frozen_request.value,
        call_record
    )
    if not step_result.ok then
        call_record.state = "SCRIPT_REJECTED"
        schedule_terminal(self, call_record, gate, step_result)
        return PortContract.ok({ accepted = true })
    end

    if step_result.value.kind == "DROP" then
        call_record.state = "DROPPED_UNRESOLVED"
        return PortContract.ok({ accepted = true })
    end

    for index = 1, #step_result.value.deliveries do
        schedule_delivery(
            self,
            call_record,
            step_result.value.deliveries[index],
            gate
        )
    end
    maybe_run_immediate(self)

    return PortContract.ok({ accepted = true })
end

function ScriptedPortMethods:enqueue(operation_name, step)
    local queue
    local prepared

    if not PortContract.get_operation_descriptor(self._spec, operation_name) then
        return PortContract.error("PORT_OPERATION_UNKNOWN", {
            port = PortContract.get_contract_name(self._spec),
            operation = operation_name,
        }, false)
    end
    if step == nil then
        return script_error("STEP_REQUIRED", {
            operation = operation_name,
        })
    end

    prepared = prepare_step(
        step,
        "$enqueue." .. operation_name,
        self._spec,
        operation_name
    )
    if not prepared.ok then
        return prepared
    end
    queue = get_script_queue(self, operation_name)
    queue.tail = queue.tail + 1
    queue.items[queue.tail] = prepared.value
    return PortContract.ok({
        operation = operation_name,
        queued = pending_script_count(queue),
    })
end

function ScriptedPortMethods:expect(operation_name, step)
    return self:enqueue(operation_name, step)
end

function ScriptedPortMethods:tick(ticks)
    local processed

    ticks = ticks or 1
    if not is_non_negative_integer(ticks) then
        return PortContract.error("FAKE_TICK_INVALID", {
            reason = "NON_NEGATIVE_INTEGER_REQUIRED",
        }, false)
    end
    self._tick = self._tick + ticks
    processed = run_due(self)
    return PortContract.ok({
        tick = self._tick,
        processed_deliveries = processed,
        pending_deliveries = #self._scheduled,
    })
end

function ScriptedPortMethods:drain(max_deliveries)
    local processed = 0
    local next_tick

    max_deliveries = max_deliveries or 10000
    if not is_non_negative_integer(max_deliveries) or max_deliveries < 1 then
        return PortContract.error("FAKE_DRAIN_INVALID", {
            reason = "POSITIVE_INTEGER_REQUIRED",
        }, false)
    end

    while #self._scheduled > 0 do
        if processed >= max_deliveries then
            return PortContract.error("FAKE_DRAIN_LIMIT_EXCEEDED", {
                max_deliveries = max_deliveries,
                pending_deliveries = #self._scheduled,
            }, false)
        end
        sort_scheduled(self)
        next_tick = self._scheduled[1].due_tick
        if next_tick > self._tick then
            self._tick = next_tick
        end
        processed = processed + run_due(self, max_deliveries - processed)
    end

    return PortContract.ok({
        tick = self._tick,
        processed_deliveries = processed,
    })
end

function ScriptedPortMethods:get_calls(operation_name)
    local calls = {}
    local index
    local call_record
    local copied

    for index = 1, #self._calls do
        call_record = self._calls[index]
        if operation_name == nil or call_record.operation == operation_name then
            calls[#calls + 1] = call_record
        end
    end
    copied = SerializableSnapshot.deep_copy(calls, "$calls")
    if not copied.ok then
        error("ScriptedPort internal call snapshot became unserializable")
    end
    return copied.value
end

function ScriptedPortMethods:get_suppressed_deliveries()
    local copied = SerializableSnapshot.deep_copy(
        self._suppressed_deliveries,
        "$suppressed_deliveries"
    )
    if not copied.ok then
        error("ScriptedPort internal suppression log became unserializable")
    end
    return copied.value
end

function ScriptedPortMethods:get_diagnostics()
    local scripts_pending = {}
    local operation_name
    local queue
    local unresolved_call_count = 0
    local waiting_idempotency_count = 0
    local pending_idempotency_count = 0
    local index
    local call_record
    local bucket
    local entry

    for operation_name, queue in pairs(self._scripts) do
        scripts_pending[operation_name] = pending_script_count(queue)
    end
    for index = 1, #self._calls do
        call_record = self._calls[index]
        if call_record.state == "DROPPED_UNRESOLVED" then
            unresolved_call_count = unresolved_call_count + 1
        elseif call_record.state == "WAITING_IDEMPOTENCY" then
            waiting_idempotency_count = waiting_idempotency_count + 1
        end
    end
    for operation_name, bucket in pairs(self._idempotency) do
        for _, entry in pairs(bucket) do
            if entry.state ~= "TERMINAL" then
                pending_idempotency_count = pending_idempotency_count + 1
            end
        end
    end

    return {
        port = PortContract.get_contract_name(self._spec),
        tick = self._tick,
        call_count = #self._calls,
        pending_delivery_count = #self._scheduled,
        suppressed_delivery_count = #self._suppressed_deliveries,
        unresolved_call_count = unresolved_call_count,
        waiting_idempotency_count = waiting_idempotency_count,
        pending_idempotency_count = pending_idempotency_count,
        script_issue_count = self._script_issue_count,
        scripts_pending = scripts_pending,
    }
end

function ScriptedPortMethods:verify_exhausted()
    local diagnostics = self:get_diagnostics()
    local unconsumed_script_count = 0
    local operation_name
    local count

    for operation_name, count in pairs(diagnostics.scripts_pending) do
        unconsumed_script_count = unconsumed_script_count + count
    end
    if unconsumed_script_count > 0
        or diagnostics.pending_delivery_count > 0
        or diagnostics.unresolved_call_count > 0
        or diagnostics.waiting_idempotency_count > 0
        or diagnostics.pending_idempotency_count > 0
        or diagnostics.script_issue_count > 0
    then
        diagnostics.unconsumed_script_count = unconsumed_script_count
        return PortContract.error("FAKE_NOT_EXHAUSTED", diagnostics, false)
    end
    diagnostics.unconsumed_script_count = 0
    return PortContract.ok(diagnostics)
end

function ScriptedPortMethods:assert_exhausted()
    local checked = self:verify_exhausted()
    local details

    if not checked.ok then
        details = checked.error.details
        error(
            "ScriptedPort not exhausted: port="
                .. tostring(details.port)
                .. " scripts="
                .. tostring(details.unconsumed_script_count)
                .. " deliveries="
                .. tostring(details.pending_delivery_count)
                .. " unresolved="
                .. tostring(details.unresolved_call_count)
                .. " waiting="
                .. tostring(details.waiting_idempotency_count)
                .. " issues="
                .. tostring(details.script_issue_count),
            2
        )
    end
    return true
end

function ScriptedPortMethods:get_contract()
    return self._spec
end

function ScriptedPort.success(value, delay_ticks)
    return {
        result = PortContract.ok(value),
        delay_ticks = delay_ticks or 0,
    }
end

function ScriptedPort.failure(code, details, retryable, delay_ticks)
    return {
        result = PortContract.error(code, details, retryable),
        delay_ticks = delay_ticks or 0,
    }
end

function ScriptedPort.timeout(late_result, timeout_ticks, late_after_ticks)
    local deliveries = {
        {
            after_ticks = timeout_ticks or 1,
            result = PortContract.error("PLATFORM_RESULT_UNKNOWN", {
                recovery_action = "QUERY_OR_RECONCILE",
            }, false),
        },
    }

    if late_result ~= nil then
        deliveries[#deliveries + 1] = {
            after_ticks = late_after_ticks or (timeout_ticks or 1) + 1,
            result = late_result,
        }
    end
    return {
        deliveries = deliveries,
    }
end

function ScriptedPort.duplicate(result, duplicate_count, delay_ticks)
    return {
        result = result,
        duplicate_count = duplicate_count or 2,
        delay_ticks = delay_ticks or 0,
    }
end

function ScriptedPort.drop()
    return {
        drop = true,
    }
end

local function prepare_defaults(spec, options)
    local prepared_default = nil
    local prepared_by_operation = {}
    local prepared
    local operation_name
    local step

    if options.default_step ~= nil then
        prepared = prepare_step(options.default_step, "$options.default_step")
        if not prepared.ok then
            return prepared
        end
        prepared_default = prepared.value
    end

    if options.default_steps ~= nil then
        if type(options.default_steps) ~= "table" then
            return script_error("DEFAULT_STEPS_MAP_REQUIRED")
        end
        for operation_name, step in pairs(options.default_steps) do
            if type(operation_name) ~= "string" or operation_name == "" then
                return script_error("DEFAULT_STEP_OPERATION_INVALID")
            end
            if PortContract.get_operation_descriptor(spec, operation_name) == nil then
                return script_error("DEFAULT_STEP_OPERATION_UNKNOWN", {
                    operation = operation_name,
                })
            end
            prepared = prepare_step(
                step,
                "$options.default_steps." .. operation_name,
                spec,
                operation_name
            )
            if not prepared.ok then
                return prepared
            end
            prepared_by_operation[operation_name] = prepared.value
        end
    end

    return PortContract.ok({
        default_step = prepared_default,
        default_steps = prepared_by_operation,
    })
end

function ScriptedPort.new(spec, options)
    local self
    local implementation_result
    local defaults
    local index
    local operation_name

    if options == nil then
        options = {}
    elseif type(options) ~= "table" then
        error("ScriptedPort options must be a table")
    end
    if options.auto_run_immediate == true then
        error("ScriptedPort callbacks must not run inline")
    end
    local operations = PortContract.list_operation_descriptors(spec)
    if operations == nil then
        error("ScriptedPort requires a port contract")
    end

    defaults = prepare_defaults(spec, options)
    if not defaults.ok then
        error("ScriptedPort defaults are invalid: " .. defaults.error.code)
    end

    self = setmetatable({
        _spec = spec,
        _scripts = {},
        _default_step = defaults.value.default_step,
        _default_steps = defaults.value.default_steps,
        _validate_requests = true,
        _auto_run_immediate = false,
        _tick = 0,
        _next_call_index = 0,
        _next_schedule_order = 0,
        _scheduled = {},
        _calls = {},
        _suppressed_deliveries = {},
        _gate_state_by_call = {},
        _idempotency = {},
        _script_issue_count = 0,
    }, {
        __index = ScriptedPortMethods,
    })

    for index = 1, #operations do
        operation_name = operations[index].name
        local bound_operation_name = operation_name
        self[bound_operation_name] = function(port, request, complete)
            return invoke(port, bound_operation_name, request, complete)
        end
    end

    implementation_result = PortContract.validate_implementation(spec, self)
    if not implementation_result.ok then
        error(
            "failed to build scripted port for "
                .. tostring(PortContract.get_contract_name(spec))
        )
    end
    return self
end

return ScriptedPort
