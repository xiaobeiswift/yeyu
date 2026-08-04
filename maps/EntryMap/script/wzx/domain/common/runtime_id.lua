local Result = require 'wzx.domain.common.result'
local DecimalInteger = require 'wzx.domain.common.decimal_integer'
local Ordered = require 'wzx.domain.common.ordered'

local RuntimeId = {}
local decimal_encode = DecimalInteger.encode
local is_dense_array = Ordered.is_dense_array
local result_err = Result.err
local result_ok = Result.ok
local string_match = string.match

local COMPONENT_MAX_BYTES = 64
local DERIVED_MAX_BYTES = 192
local CONTENT_MAX_BYTES = 96
local SOURCE_REFERENCE_MAX_BYTES = 320
local STABLE_ORDER_KEY_MAX_BYTES = 512

local function is_component(value)
    return type(value) == 'string'
        and #value >= 1
        and #value <= COMPONENT_MAX_BYTES
        and string_match(value, '^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

local function validate_component(value, field_name)
    if not is_component(value) then
        return result_err('ID_INVALID', 'error.foundation.runtime_id_invalid', false, {
            field = field_name,
            max_bytes = COMPONENT_MAX_BYTES,
        })
    end
    return result_ok(value)
end
RuntimeId.validate_component = validate_component

function RuntimeId.validate_derived(value, field_name)
    if type(value) ~= 'string'
        or #value < 1
        or #value > DERIVED_MAX_BYTES
        or string_match(value, '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
        or value:find('::', 1, true) ~= nil
        or value:sub(-1) == ':'
    then
        return result_err('ID_INVALID', 'error.foundation.derived_id_invalid', false, {
            field = field_name,
            max_bytes = DERIVED_MAX_BYTES,
        })
    end

    local receipt_namespace, receipt_digest = string_match(
        value,
        '^receipt_([a-z][a-z0-9_]*)_v1_([a-f0-9]+)$'
    )
    if receipt_namespace ~= nil
        and #receipt_namespace <= 48
        and receipt_digest ~= nil
        and #receipt_digest == 64
    then
        return result_ok(value)
    end

    local component
    for component in value:gmatch('[^:]+') do
        if not is_component(component) then
            return result_err('ID_INVALID', 'error.foundation.derived_id_component_invalid', false, {
                field = field_name,
                component = component,
                component_max_bytes = COMPONENT_MAX_BYTES,
            })
        end
    end
    return result_ok(value)
end

function RuntimeId.validate_content(value, prefix, field_name)
    if type(value) ~= 'string'
        or #value < 1
        or #value > CONTENT_MAX_BYTES
        or string_match(value, '^[a-z][a-z0-9_]*$') == nil
        or (prefix ~= nil and value:sub(1, #prefix) ~= prefix)
    then
        return result_err('ID_INVALID', 'error.foundation.content_id_invalid', false, {
            field = field_name,
            prefix = prefix,
            max_bytes = CONTENT_MAX_BYTES,
        })
    end
    return result_ok(value)
end

local function validate_reference(value, maximum_bytes, field_name)
    if type(value) ~= 'string'
        or #value < 1
        or #value > maximum_bytes
        or string_match(value, '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
        or value:find('::', 1, true) ~= nil
        or value:sub(-1) == ':'
    then
        return result_err('ID_INVALID', 'error.foundation.reference_key_invalid', false, {
            field = field_name,
            max_bytes = maximum_bytes,
        })
    end

    local component
    for component in value:gmatch('[^:]+') do
        if #component > CONTENT_MAX_BYTES
            or string_match(component, '^[A-Za-z0-9][A-Za-z0-9_.%-]*$') == nil
        then
            return result_err(
                'ID_INVALID',
                'error.foundation.reference_key_component_invalid',
                false,
                {
                    field = field_name,
                    component_max_bytes = CONTENT_MAX_BYTES,
                }
            )
        end
    end
    return result_ok(value)
end

function RuntimeId.validate_source_reference(value, field_name)
    return validate_reference(value, SOURCE_REFERENCE_MAX_BYTES, field_name)
end

function RuntimeId.validate_stable_order_key(value, field_name)
    return validate_reference(value, STABLE_ORDER_KEY_MAX_BYTES, field_name)
end

function RuntimeId.compose(parts)
    if not is_dense_array(parts) or #parts < 2 then
        return result_err('ID_INVALID', 'error.foundation.derived_id_parts_invalid', false)
    end

    local normalized = {}
    local i
    for i = 1, #parts do
        local part = rawget(parts, i)
        if type(part) == 'number' then
            local encoded = decimal_encode(part)
            if part < 1 or encoded == nil then
                return result_err('ID_INVALID', 'error.foundation.derived_id_number_invalid', false, {
                    part_index = i,
                })
            end
            part = encoded
        end

        local checked = validate_component(part, 'part_' .. tostring(i))
        if not checked.ok then
            return checked
        end
        normalized[i] = part
    end

    local value = table.concat(normalized, ':')
    if #value > DERIVED_MAX_BYTES then
        return result_err('ID_TOO_LONG', 'error.foundation.derived_id_too_long', false, {
            max_bytes = DERIVED_MAX_BYTES,
        })
    end
    return result_ok(value)
end

RuntimeId.COMPONENT_MAX_BYTES = COMPONENT_MAX_BYTES
RuntimeId.DERIVED_MAX_BYTES = DERIVED_MAX_BYTES
RuntimeId.CONTENT_MAX_BYTES = CONTENT_MAX_BYTES
RuntimeId.SOURCE_REFERENCE_MAX_BYTES = SOURCE_REFERENCE_MAX_BYTES
RuntimeId.STABLE_ORDER_KEY_MAX_BYTES = STABLE_ORDER_KEY_MAX_BYTES

return RuntimeId
