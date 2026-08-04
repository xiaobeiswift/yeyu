local Harness = require 'wzx.tests.harness'
local CharacterSectionRegistrar = require 'wzx.config.schema.character.section_registrar'
local Foundation = require 'wzx.config.schema.foundation'

local case = Harness.case
local assert = Harness.assert

local EXPECTED = {
    {
        section_key = 'character_metadata',
        slot_id = 3,
        validator_id = 'validator_character_metadata_v1',
        codec_id = 'codec_character_save_bundle_v1',
    },
    {
        section_key = 'character_rows',
        slot_id = 3,
        validator_id = 'validator_character_rows_v1',
        codec_id = 'codec_character_save_bundle_v1',
    },
    {
        section_key = 'character_talent_rows',
        slot_id = 3,
        validator_id = 'validator_character_talent_rows_v1',
        codec_id = 'codec_character_save_bundle_v1',
    },
    {
        section_key = 'character_operation_metadata',
        slot_id = 5,
        validator_id = 'validator_character_operation_metadata_v1',
        codec_id = 'codec_character_receipt_bundle_v1',
    },
    {
        section_key = 'character_operation_receipts',
        slot_id = 5,
        validator_id = 'validator_character_operation_receipts_v1',
        codec_id = 'codec_character_receipt_bundle_v1',
    },
}

local function create_foundation()
    return Foundation.create({
        registrars = { CharacterSectionRegistrar },
    })
end

local function assert_definition(actual, expected)
    assert.equal(actual.section_key, expected.section_key)
    assert.equal(actual.section_path, expected.section_key)
    assert.equal(actual.owner_system, '01')
    assert.equal(actual.slot_id, expected.slot_id)
    assert.equal(actual.schema_version, 1)
    assert.equal(actual.storage_kind, 'TABLE_SECTION')
    assert.equal(actual.write_policy, 'CRITICAL')
    assert.equal(actual.validator_id, expected.validator_id)
    assert.equal(actual.codec_id, expected.codec_id)
    assert.equal(actual.sensitive, true)
    assert.equal(actual.public, false)
end

return {
    case('character registrar installs five non-overlapping owned sections', function()
        local created = create_foundation()
        assert.equal(created.ok, true)
        assert.equal(created.value.registrar_count, 1)

        local registry = created.value.section_owners
        local index
        for index = 1, #EXPECTED do
            local expected = EXPECTED[index]
            local fetched = registry:get(expected.section_key)
            assert.equal(fetched.ok, true)
            assert_definition(fetched.value, expected)

            local by_path = registry:find_by_path(
                expected.slot_id,
                expected.section_key
            )
            assert.equal(by_path.ok, true)
            assert.equal(by_path.value.section_key, expected.section_key)
        end
    end),

    case('only system 01 can write registered character paths', function()
        local created = create_foundation()
        assert.equal(created.ok, true)

        local registry = created.value.section_owners
        local index
        for index = 1, #EXPECTED do
            local expected = EXPECTED[index]
            local authorized = registry:authorize_write(
                '01',
                expected.slot_id,
                expected.section_key
            )
            assert.equal(authorized.ok, true)
            assert_definition(authorized.value, expected)

            assert.error_code(
                registry:authorize_write(
                    '02',
                    expected.slot_id,
                    expected.section_key
                ),
                'SECTION_WRITE_FORBIDDEN'
            )
        end
    end),

    case('character section definitions and registrar are defensive', function()
        local created = create_foundation()
        assert.equal(created.ok, true)
        local registry = created.value.section_owners

        local fetched = registry:get('character_rows').value
        fetched.owner_system = '99'
        fetched.section_path = 'forged_path'
        fetched.codec_id = 'codec_forged_v1'

        local refetched = registry:get('character_rows')
        assert.equal(refetched.ok, true)
        assert_definition(refetched.value, EXPECTED[2])

        local listed = registry:list().value
        local index
        for index = 1, #listed do
            if listed[index].section_key == 'character_rows' then
                listed[index].validator_id = 'validator_forged_v1'
            end
        end
        assert_definition(
            registry:get('character_rows').value,
            EXPECTED[2]
        )

        assert.throws(function()
            CharacterSectionRegistrar.system_id = '99'
        end, 'character section registrar is read-only')
        assert.equal(CharacterSectionRegistrar.system_id, '01')
    end),
}
