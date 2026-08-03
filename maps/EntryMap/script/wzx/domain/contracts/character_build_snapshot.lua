local Result = require 'wzx.domain.common.result'
local Validation = require 'wzx.domain.contracts.validation'

local CharacterBuildSnapshot = {}

local CONTRACT = 'CharacterBuildSnapshotV1'
local ALLOWED_FIELDS = {
    schema_version = true,
    character_id = true,
    definition_version = true,
    level = true,
    awakening_rank = true,
    talent_entries = true,
    equipment_snapshot = true,
    martial_snapshot = true,
    progression_snapshot = true,
    character_revision = true,
    rules_version = true,
    source_hashes = true,
    build_hash = true,
}
local TALENT_ENTRY_FIELDS = {
    talent_id = true,
}

function CharacterBuildSnapshot.validate(value)
    local err = Validation.no_unknown_fields(CONTRACT, value, ALLOWED_FIELDS)
    if err ~= nil then
        return err
    end
    err = Validation.first(
        Validation.integer(CONTRACT, 'schema_version', value.schema_version, 1),
        Validation.identifier(CONTRACT, 'character_id', value.character_id, 'char_'),
        Validation.integer(CONTRACT, 'definition_version', value.definition_version, 1),
        Validation.integer(CONTRACT, 'level', value.level, 1, 100),
        Validation.integer(CONTRACT, 'awakening_rank', value.awakening_rank, 0, 100),
        Validation.dense_array(CONTRACT, 'talent_entries', value.talent_entries, 0),
        Validation.table_serializable(CONTRACT, 'equipment_snapshot', value.equipment_snapshot, 5),
        Validation.table_serializable(CONTRACT, 'martial_snapshot', value.martial_snapshot, 5),
        Validation.table_serializable(CONTRACT, 'progression_snapshot', value.progression_snapshot, 5),
        Validation.integer(CONTRACT, 'character_revision', value.character_revision, 0),
        Validation.integer(CONTRACT, 'rules_version', value.rules_version, 1),
        Validation.hash_map(CONTRACT, 'source_hashes', value.source_hashes),
        Validation.hash(CONTRACT, 'build_hash', value.build_hash)
    )
    if err ~= nil then
        return err
    end

    local index
    local previous_id
    for index = 1, #value.talent_entries do
        local entry = value.talent_entries[index]
        err = Validation.no_unknown_fields(CONTRACT .. '.TalentEntryV1', entry, TALENT_ENTRY_FIELDS)
        if err ~= nil then
            err.error.details.index = index
            return err
        end
        err = Validation.identifier(
            CONTRACT .. '.TalentEntryV1',
            'talent_id',
            entry.talent_id,
            'talent_'
        )
        if err ~= nil then
            return Validation.invalid(CONTRACT, 'talent_entries', 'TALENT_ENTRY_INVALID', {
                index = index,
                cause = err.error,
            })
        end
        if previous_id ~= nil and previous_id >= entry.talent_id then
            return Validation.invalid(CONTRACT, 'talent_entries', 'TALENT_ORDER_INVALID', {
                index = index,
            })
        end
        previous_id = entry.talent_id
    end
    return Result.ok(value)
end

return CharacterBuildSnapshot
