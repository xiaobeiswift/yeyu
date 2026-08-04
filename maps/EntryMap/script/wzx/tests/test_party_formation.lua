local Harness = require 'wzx.tests.harness'
local Formation = require 'wzx.domain.contracts.formation'
local PartyAggregate = require 'wzx.domain.party.party_aggregate'
local PartyService = require 'wzx.application.use_cases.party.party_service'

local case = Harness.case
local assert = Harness.assert

local function members_two()
    return {
        {
            character_id = 'char_hero',
            position_index = 1,
            entry_order = 1,
        },
        {
            character_id = 'char_ally',
            position_index = 4,
            entry_order = 2,
            role_tag_override = 'SUPPORT',
        },
    }
end

return {
    case('party commit formation validates leader positions and ownership', function()
        local service = PartyService.bind({
            party_context = 'PVE_MAIN',
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
        })
        assert.equal(service.ok, true)

        local empty = service.value:get_formation()
        assert.equal(empty.ok, true)
        assert.equal(#empty.value.member_rows, 0)
        assert.equal(empty.value.revision, 0)

        local committed = service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
        })
        assert.equal(committed.ok, true, committed.error and committed.error.code)
        assert.equal(committed.value.revision, 1)
        assert.equal(#committed.value.formation.member_rows, 2)
        assert.equal(Formation.validate(committed.value.formation).ok, true)

        local unknown = service.value:commit_formation({
            member_rows = {
                {
                    character_id = 'char_stranger',
                    position_index = 0,
                    entry_order = 1,
                },
            },
            leader_character_id = 'char_stranger',
            expected_revision = 1,
        })
        assert.equal(unknown.ok, false)
        assert.equal(unknown.error.code, 'PARTY_MEMBER_UNKNOWN')

        local bad_leader = service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_missing',
            expected_revision = 1,
        })
        assert.equal(bad_leader.ok, false)
        assert.equal(bad_leader.error.code, 'PARTY_LEADER_INVALID')
    end),

    case('swap positions increments revision and keeps leader', function()
        local service = PartyService.bind({
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
        })
        assert.equal(service.ok, true)
        local committed = service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
        })
        assert.equal(committed.ok, true)

        local swapped = service.value:swap_positions({
            position_a = 1,
            position_b = 4,
            expected_revision = 1,
        })
        assert.equal(swapped.ok, true, swapped.error and swapped.error.code)
        assert.equal(swapped.value.revision, 2)
        assert.equal(swapped.value.formation.leader_character_id, 'char_hero')

        local by_pos = {}
        local index
        for index = 1, #swapped.value.formation.member_rows do
            local row = swapped.value.formation.member_rows[index]
            by_pos[row.position_index] = row.character_id
        end
        assert.equal(by_pos[1], 'char_ally')
        assert.equal(by_pos[4], 'char_hero')

        local ready = service.value:validate_ready()
        assert.equal(ready.ok, true)
        assert.equal(ready.value.ready, true)
    end),

    case('revision conflict and duplicate position fail closed', function()
        local empty = PartyAggregate.empty('PVE_MAIN')
        assert.equal(empty.ok, true)
        local first = PartyAggregate.commit_formation(empty.value, {
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
        }, { char_hero = true, char_ally = true })
        assert.equal(first.ok, true)

        local stale = PartyAggregate.commit_formation(first.value, {
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
        }, { char_hero = true, char_ally = true })
        assert.equal(stale.ok, false)
        assert.equal(stale.error.code, 'PARTY_REVISION_CONFLICT')

        local dup = PartyAggregate.commit_formation(empty.value, {
            member_rows = {
                {
                    character_id = 'char_hero',
                    position_index = 1,
                    entry_order = 1,
                },
                {
                    character_id = 'char_ally',
                    position_index = 1,
                    entry_order = 2,
                },
            },
            leader_character_id = 'char_hero',
        }, { char_hero = true, char_ally = true })
        assert.equal(dup.ok, false)
        assert.equal(dup.error.code, 'PARTY_POSITION_OCCUPIED')
    end),
}
