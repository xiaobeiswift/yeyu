local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.domain.contracts.validation'

local ReachabilitySourceVector = {}

local CONTRACT = 'ReachabilitySourceVectorV1'
local FIELDS = {
    spatial_revision = true,
    world_revision = true,
    source_loadout_revision = true,
    source_progress_revision = true,
    profile_hash = true,
    rules_version = true,
}

function ReachabilitySourceVector.validate(value)
    local err = Validation.no_unknown_fields(CONTRACT, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.integer(CONTRACT, 'spatial_revision', value.spatial_revision, 0),
        Validation.integer(CONTRACT, 'world_revision', value.world_revision, 0),
        Validation.integer(CONTRACT, 'source_loadout_revision', value.source_loadout_revision, 0),
        Validation.integer(CONTRACT, 'source_progress_revision', value.source_progress_revision, 0),
        Validation.hash(CONTRACT, 'profile_hash', value.profile_hash),
        Validation.integer(CONTRACT, 'rules_version', value.rules_version, 1)
    )
    if err ~= nil then
        return err
    end
    return Result.ok(value)
end

function ReachabilitySourceVector.equals(left, right)
    local left_result = ReachabilitySourceVector.validate(left)
    if not left_result.ok then
        return left_result
    end
    local right_result = ReachabilitySourceVector.validate(right)
    if not right_result.ok then
        return right_result
    end
    return Result.ok(
        left.spatial_revision == right.spatial_revision
        and left.world_revision == right.world_revision
        and left.source_loadout_revision == right.source_loadout_revision
        and left.source_progress_revision == right.source_progress_revision
        and left.profile_hash == right.profile_hash
        and left.rules_version == right.rules_version
    )
end

return ReachabilitySourceVector
