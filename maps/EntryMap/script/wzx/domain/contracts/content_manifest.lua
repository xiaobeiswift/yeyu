local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.domain.contracts.validation'
local Ordered = require 'wzx.domain.common.ordered'

local ContentManifest = {}

local CONTRACT = 'ContentManifestV1'
local FIELDS = {
    content_version = true,
    rules_version = true,
    foundation_contract_version = true,
    schema_versions = true,
    generator_version = true,
    source_table_hashes = true,
    record_counts = true,
    generated_file_hashes = true,
    stable_id_owner_index = true,
    y3_mapping_version = true,
    world_graph_hash = true,
    traversal_graph_hash = true,
    event_schema_registry_hash = true,
    section_owner_registry_hash = true,
    minimum_readable_content_version = true,
}

local function version_string(field, value)
    if type(value) ~= 'string'
        or #value < 1
        or #value > 64
        or value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') == nil
    then
        return Validation.invalid(CONTRACT, field, 'VERSION_STRING_INVALID')
    end
    return nil
end

local function hash_map(field, value)
    if type(value) ~= 'table' then
        return Validation.invalid(CONTRACT, field, 'MAP_REQUIRED')
    end
    local keys = Ordered.sorted_string_keys(value)
    if not keys.ok then
        return Validation.invalid(CONTRACT, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
    end
    local index
    for index = 1, #keys.value do
        local key = keys.value[index]
        local hash = value[key]
        if key == '' then
            return Validation.invalid(CONTRACT, field, 'NON_EMPTY_STRING_KEY_REQUIRED')
        end
        local err = Validation.hash(CONTRACT, field .. '.' .. key, hash)
        if err ~= nil then
            return err
        end
    end
    return nil
end

function ContentManifest.validate(value)
    local err = Validation.no_unknown_fields(CONTRACT, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        version_string('content_version', value.content_version),
        Validation.integer(CONTRACT, 'rules_version', value.rules_version, 1),
        Validation.integer(CONTRACT, 'foundation_contract_version', value.foundation_contract_version, 1, 1),
        Validation.flat_map(CONTRACT, 'schema_versions', value.schema_versions, 'integer'),
        version_string('generator_version', value.generator_version),
        hash_map('source_table_hashes', value.source_table_hashes),
        Validation.flat_map(CONTRACT, 'record_counts', value.record_counts, 'integer'),
        hash_map('generated_file_hashes', value.generated_file_hashes),
        Validation.flat_map(CONTRACT, 'stable_id_owner_index', value.stable_id_owner_index, 'string'),
        version_string('y3_mapping_version', value.y3_mapping_version),
        Validation.hash(CONTRACT, 'world_graph_hash', value.world_graph_hash),
        Validation.hash(CONTRACT, 'traversal_graph_hash', value.traversal_graph_hash),
        Validation.hash(CONTRACT, 'event_schema_registry_hash', value.event_schema_registry_hash),
        Validation.hash(CONTRACT, 'section_owner_registry_hash', value.section_owner_registry_hash),
        version_string('minimum_readable_content_version', value.minimum_readable_content_version)
    )
    if err ~= nil then
        return err
    end

    local record_keys = Ordered.sorted_string_keys(value.record_counts).value
    local index
    for index = 1, #record_keys do
        local key = record_keys[index]
        local numeric_value = value.record_counts[key]
        if numeric_value < 0 then
            return Validation.invalid(CONTRACT, 'record_counts.' .. key, 'NON_NEGATIVE_INTEGER_REQUIRED')
        end
    end
    local schema_keys = Ordered.sorted_string_keys(value.schema_versions).value
    for index = 1, #schema_keys do
        local key = schema_keys[index]
        local numeric_value = value.schema_versions[key]
        if numeric_value < 1 then
            return Validation.invalid(CONTRACT, 'schema_versions.' .. key, 'POSITIVE_INTEGER_REQUIRED')
        end
    end
    return Result.ok(value)
end

return ContentManifest
