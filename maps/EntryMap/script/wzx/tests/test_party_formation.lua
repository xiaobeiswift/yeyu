local Harness = require 'wzx.tests.harness'
local FakePartyStore = require 'wzx.adapters.fake.party.fake_party_store'
local Formation = require 'wzx.domain.contracts.formation'
local HydrateGameRuntime = require 'wzx.application.use_cases.save.hydrate_game_runtime'
local LoadGameSave = require 'wzx.application.use_cases.save.load_game_save'
local MemorySaveStore = require 'wzx.adapters.fake.services.memory_save_store'
local PartyAggregate = require 'wzx.domain.party.party_aggregate'
local PartySaveBridge = require 'wzx.application.use_cases.party.party_save_bridge'
local PartySaveCodec = require 'wzx.domain.party.party_save_codec'
local PartySectionRegistrar = require 'wzx.config.schema.party.section_registrar'
local PartyService = require 'wzx.application.use_cases.party.party_service'
local SaveCoordinator = require 'wzx.application.save.save_coordinator'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'

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

    case('party save codec round-trips multi-context formations', function()
        local encoded = PartySaveCodec.encode({
            party_save_revision = 2,
            parties = {
                {
                    party_context = 'PVE_MAIN',
                    leader_character_id = 'char_hero',
                    formation_template_id = nil,
                    active_preset_id = nil,
                    is_dirty_from_preset = false,
                    revision = 1,
                    member_rows = members_two(),
                },
                {
                    party_context = 'PVE_ALT',
                    leader_character_id = 'char_ally',
                    formation_template_id = 'formation_default',
                    active_preset_id = nil,
                    is_dirty_from_preset = true,
                    revision = 3,
                    member_rows = {
                        {
                            character_id = 'char_ally',
                            position_index = 0,
                            entry_order = 1,
                        },
                    },
                },
            },
        })
        assert.equal(encoded.ok, true, encoded.error and encoded.error.details and encoded.error.details.reason)
        assert.equal(#encoded.value.party_header_rows, 2)
        assert.equal(#encoded.value.party_member_rows, 3)
        assert.equal(#encoded.value.preset_header_rows, 0)

        local decoded = PartySaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true, decoded.error and decoded.error.details and decoded.error.details.reason)
        assert.equal(decoded.value.party_save_revision, 2)
        assert.equal(#decoded.value.parties, 2)
        assert.equal(decoded.value.parties[1].party_context, 'PVE_ALT')
        assert.equal(decoded.value.parties[2].party_context, 'PVE_MAIN')
        assert.equal(#decoded.value.parties[2].member_rows, 2)
        assert.equal(decoded.value.parties[1].formation_template_id, 'formation_default')
    end),

    case('section registrar installs slot-3 party sections', function()
        local owners = SectionOwnerRegistry.new()
        assert.equal(owners.ok, true)
        local registered = PartySectionRegistrar.register({
            system_id = '03',
            section_owners = owners.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 5)
        local meta = owners.value:get('party_metadata')
        assert.equal(meta.ok, true)
        assert.equal(meta.value.slot_id, 3)
        assert.equal(meta.value.owner_system, '03')
    end),

    case('party store and save bridge checkpoint then hydrate resumes formation', function()
        local memory = MemorySaveStore.new()
        local coordinator = SaveCoordinator.bind({ save_store = memory })
        assert.equal(coordinator.ok, true)
        local invoke = SaveCoordinator.fake_invoke(memory)
        local load = LoadGameSave.bind({ coordinator = coordinator.value })
        assert.equal(load.ok, true)

        local store = FakePartyStore.new({ party_context = 'PVE_MAIN' })
        assert.equal(store.ok, true)
        local bridge = PartySaveBridge.bind({
            store = store.value,
            coordinator = coordinator.value,
            save_invoke = invoke,
            default_save_seed = 303001,
        })
        assert.equal(bridge.ok, true)
        local service = PartyService.bind({
            party_context = 'PVE_MAIN',
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
            party_store = store.value,
            save_bridge = bridge.value,
        })
        assert.equal(service.ok, true)

        local committed = service.value:commit_formation({
            member_rows = members_two(),
            leader_character_id = 'char_hero',
            expected_revision = 0,
            player_save_scope = 'player_party_001',
            request_id = 'request_party_commit',
            command_id = 'cmd_party_commit',
        })
        assert.equal(committed.ok, true, committed.error and committed.error.code)
        assert.equal(committed.value.revision, 1)
        assert.equal(committed.value.save.status, 'COMMITTED')
        assert.equal(committed.value.save.created_save, true)
        assert.equal(committed.value.save.slot3_revision, 1)

        local loaded = load.value:load({
            player_ref = 'player_party_001',
            session_instance_id = 'session_party_1',
            request_id = 'request_load_party_1',
        }, invoke)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        assert.equal(loaded.value.mode, 'READY')
        assert.equal(
            loaded.value.loaded_envelopes[3].payload.party_header_rows[1].leader_character_id,
            'char_hero'
        )
        assert.equal(
            #loaded.value.loaded_envelopes[3].payload.party_member_rows,
            2
        )

        local fresh_store = FakePartyStore.new()
        assert.equal(fresh_store.ok, true)
        local hydrate = HydrateGameRuntime.bind({})
        assert.equal(hydrate.ok, true)
        local hydrated = hydrate.value:hydrate({
            load_result = loaded.value,
            player_save_scope = 'player_party_001',
            targets = {
                party_store = fresh_store.value,
            },
        })
        assert.equal(hydrated.ok, true, hydrated.error and hydrated.error.code)
        local party_status
        local index
        for index = 1, #hydrated.value.systems do
            if hydrated.value.systems[index].system_id == 'party' then
                party_status = hydrated.value.systems[index].status
            end
        end
        assert.equal(party_status, 'HYDRATED')

        local resumed = PartyService.bind({
            party_context = 'PVE_MAIN',
            owned_character_ids = {
                char_hero = true,
                char_ally = true,
            },
            party_store = fresh_store.value,
        })
        assert.equal(resumed.ok, true)
        local formation = resumed.value:get_formation()
        assert.equal(formation.ok, true)
        assert.equal(formation.value.revision, 1)
        assert.equal(formation.value.leader_character_id, 'char_hero')
        assert.equal(#formation.value.member_rows, 2)
        assert.equal(Formation.validate(formation.value).ok, true)

        local swapped = resumed.value:swap_positions({
            position_a = 1,
            position_b = 4,
            expected_revision = 1,
        })
        assert.equal(swapped.ok, true)
        assert.equal(swapped.value.revision, 2)
        assert.equal(swapped.value.save.status, 'SKIPPED')
    end),
}
