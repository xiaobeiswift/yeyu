local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Validation = require 'wzx.domain.contracts.validation'

local PlayerProfile = {}

local CONTRACT = 'PlayerProfileV1'
local FIELDS = {
    schema_version = true,
    revision = true,
    player_save_scope = true,
    created_at = true,
}

function PlayerProfile.validate(value)
    local err = Validation.no_unknown_fields(CONTRACT, value, FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.integer(CONTRACT, 'schema_version', value.schema_version, 1),
        Validation.integer(CONTRACT, 'revision', value.revision, 0),
        Validation.integer(CONTRACT, 'created_at', value.created_at, 0, nil, true)
    )
    if err ~= nil then
        return err
    end
    local scope = RuntimeId.validate_component(value.player_save_scope, 'player_save_scope')
    if not scope.ok then
        return Validation.invalid(CONTRACT, 'player_save_scope', 'INTERNAL_SCOPE_ID_INVALID')
    end
    return Result.ok(value)
end

return PlayerProfile
