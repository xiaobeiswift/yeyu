local PortContract = require 'wzx.application.ports.port_contract'

local UnavailableService = {}

function UnavailableService.create(spec, reason)
    local operations = PortContract.list_operation_descriptors(spec)
    local port_name = PortContract.get_contract_name(spec)
    if operations == nil or port_name == nil then
        return PortContract.error('PORT_CONTRACT_INVALID', {
            reason = 'PORT_SPEC_REQUIRED',
        }, false)
    end

    local service = {}
    local index
    for index = 1, #operations do
        local operation = operations[index]
        local bound_operation_name = operation.name
        local is_mutating = operation.mutating == true
        service[bound_operation_name] = function(_, request, complete)
            local callback_result = PortContract.validate_callback(complete)
            if not callback_result.ok then
                return callback_result
            end
            local request_result = PortContract.validate_request(
                spec,
                bound_operation_name,
                request
            )
            if not request_result.ok then
                return request_result
            end
            return PortContract.error('PLATFORM_UNAVAILABLE', {
                port = port_name,
                operation = bound_operation_name,
                reason = reason or 'ADAPTER_NOT_VERIFIED',
                recovery = is_mutating
                    and 'QUERY_OR_RECONCILE'
                    or 'RETRY_WITH_BACKOFF',
            }, not is_mutating)
        end
    end
    return PortContract.ok(service)
end

return UnavailableService
