local Harness = require 'wzx.tests.harness'
local MartialCatalog = require 'wzx.config.schema.martial.catalog'
local MartialSectionRegistrar = require 'wzx.config.schema.martial.section_registrar'
local SectionOwnerRegistry = require 'wzx.config.schema.section_owner_registry'
local MartialAggregate = require 'wzx.domain.martial.martial_aggregate'
local MartialSaveCodec = require 'wzx.domain.martial.martial_save_codec'
local LightnessTraversalProfile = require 'wzx.domain.contracts.lightness_traversal_profile'
local MartialService = require 'wzx.application.use_cases.martial.martial_service'

local case = Harness.case
local assert = Harness.assert

local function level_rows_with_moves(move_ids, contribution)
    local rows = {}
    local index
    for index = 1, 10 do
        local unlocked = {}
        if index >= 1 then
            unlocked[1] = move_ids[1]
        end
        if index >= 3 and move_ids[2] ~= nil then
            unlocked[2] = move_ids[2]
        end
        local contributions = {}
        if contribution ~= nil then
            contributions[1] = {
                source_type = 'MARTIAL',
                source_id = contribution.source_id_prefix .. ':' .. tostring(index) .. ':atk',
                target_stat = 'attack',
                operation = 'ADD_FLAT',
                value = contribution.base + index,
                priority = 100,
                condition_tags = {},
                stable_order_key = 'MARTIAL:'
                    .. contribution.source_id_prefix
                    .. ':'
                    .. tostring(index)
                    .. ':atk:ADD_FLAT',
            }
        end
        rows[index] = {
            level = index,
            required_character_level = index,
            mastery_required = 0,
            unlocked_move_ids = unlocked,
            contributions = contributions,
        }
    end
    return rows
end

local function jump_cap(range)
    return {
        capability_id = 'JUMP_BASIC',
        rank = 1,
        jump_range_cells = range,
        water_range_cells = 0,
        max_rise_levels = 1,
        max_drop_levels = 1,
        max_route_cost = range,
        movement_speed_bp = 10000,
    }
end

local function water_cap(range)
    return {
        capability_id = 'WATER_WALK',
        rank = 1,
        jump_range_cells = 0,
        water_range_cells = range,
        max_rise_levels = 0,
        max_drop_levels = 0,
        max_route_cost = 0,
        movement_speed_bp = 10000,
    }
end

local function lightness_level_rows()
    local rows = {}
    local index
    for index = 1, 10 do
        local specs = { jump_cap(index) }
        if index >= 5 then
            specs[2] = water_cap(index)
        end
        rows[index] = {
            level = index,
            capability_specs = specs,
            range_query_radius_cells = index,
        }
    end
    return rows
end

local function move_def(id, martial_id, unlock_level, move_type)
    move_type = move_type or 'ACTIVE'
    local def = {
        id = id,
        schema_version = 1,
        source_martial_id = martial_id,
        move_type = move_type,
        name_key = id .. '.name',
        description_template_key = id .. '.desc',
        unlock_level = unlock_level or 1,
        qi_cost = 10,
        action_cooldown = 1,
        target_rule_id = 'target_single_enemy',
        effect_bundle_id = 'effect_basic_strike',
        ai_tags = { 'DAMAGE' },
    }
    if move_type == 'PASSIVE' or move_type == 'REACTION' then
        def.trigger_type = 'COMBAT_STARTED'
        def.qi_cost = 0
        def.action_cooldown = 0
    end
    return def
end

local function build_catalog()
    local built = MartialCatalog.build({
        compatibility_rules = {
            {
                id = 'martial_compat_basic',
                schema_version = 1,
                minimum_character_level = 1,
            },
            {
                id = 'martial_compat_high',
                schema_version = 1,
                minimum_character_level = 5,
            },
        },
        move_definitions = {
            move_def('move_sword_slash', 'martial_routine_sword', 1, 'BASIC'),
            move_def('move_sword_thrust', 'martial_routine_sword', 3, 'ACTIVE'),
            move_def('move_internal_breath', 'martial_internal_calm', 1, 'PASSIVE'),
            move_def('move_lightness_step', 'martial_lightness_cloud', 1, 'PASSIVE'),
        },
        lightness_traversal_profiles = {
            {
                id = 'traversal_profile_cloud',
                schema_version = 1,
                source_martial_id = 'martial_lightness_cloud',
                rules_version = 1,
                default_presentation_profile_id = 'traversal_presentation_cloud',
                level_rows = lightness_level_rows(),
            },
        },
        martial_definitions = {
            {
                id = 'martial_routine_sword',
                schema_version = 1,
                rules_version = 1,
                name_key = 'martial.sword.name',
                description_key = 'martial.sword.desc',
                category = 'ROUTINE',
                weapon_path = 'SWORD',
                rarity = 'BASIC',
                learn_policy = 'SINGLE_COPY_PER_CHARACTER',
                move_ids = { 'move_sword_slash', 'move_sword_thrust' },
                compatibility_rule_id = 'martial_compat_basic',
                y3_visual_set_id = 'visual_sword_basic',
                level_rows = level_rows_with_moves(
                    { 'move_sword_slash', 'move_sword_thrust' },
                    { source_id_prefix = 'martial_routine_sword', base = 10 }
                ),
            },
            {
                id = 'martial_internal_calm',
                schema_version = 1,
                rules_version = 1,
                name_key = 'martial.internal.name',
                description_key = 'martial.internal.desc',
                category = 'INTERNAL',
                weapon_path = 'NONE',
                rarity = 'BASIC',
                learn_policy = 'SINGLE_COPY_PER_CHARACTER',
                move_ids = { 'move_internal_breath' },
                compatibility_rule_id = 'martial_compat_basic',
                y3_visual_set_id = 'visual_internal_basic',
                level_rows = level_rows_with_moves(
                    { 'move_internal_breath' },
                    { source_id_prefix = 'martial_internal_calm', base = 5 }
                ),
            },
            {
                id = 'martial_lightness_cloud',
                schema_version = 1,
                rules_version = 1,
                name_key = 'martial.lightness.name',
                description_key = 'martial.lightness.desc',
                category = 'LIGHTNESS',
                weapon_path = 'NONE',
                rarity = 'BASIC',
                learn_policy = 'SINGLE_COPY_PER_CHARACTER',
                move_ids = { 'move_lightness_step' },
                compatibility_rule_id = 'martial_compat_basic',
                lightness_traversal_profile_id = 'traversal_profile_cloud',
                y3_visual_set_id = 'visual_lightness_basic',
                level_rows = level_rows_with_moves(
                    { 'move_lightness_step' },
                    { source_id_prefix = 'martial_lightness_cloud', base = 2 }
                ),
            },
        },
    })
    assert.equal(built.ok, true, built.error and built.error.details and built.error.details.reason)
    return built.value
end

local function bind_service(options)
    options = options or {}
    options.martial_catalog = options.martial_catalog or build_catalog()
    options.world_protagonist_id = options.world_protagonist_id or 'char_hero'
    local service = MartialService.bind(options)
    assert.equal(service.ok, true, service.error and service.error.code)
    return service.value
end

local function grant_and_learn(service, character_id, martial_id, receipt_suffix)
    local grant = service:grant_ownership({
        martial_id = martial_id,
        amount = 1,
        source_type = 'QUEST',
        source_reference = 'quest.intro.reward',
        receipt_id = 'receipt_grant_' .. receipt_suffix,
    })
    assert.equal(grant.ok, true, grant.error and grant.error.code)
    local learned = service:learn({
        character_id = character_id,
        martial_id = martial_id,
        character_level = 10,
        character_tags = {},
        weapon_path = 'SWORD',
        source_type = 'QUEST',
        source_reference = 'quest.intro.reward',
        acquisition_receipt_id = 'receipt_learn_' .. receipt_suffix,
    })
    assert.equal(learned.ok, true, learned.error and learned.error.code)
    return learned
end

return {
    case('catalog seals martial definitions and section registrar owns slot 3', function()
        local catalog = build_catalog()
        assert.equal(MartialCatalog.is_authority(catalog), true)
        assert.equal(catalog:contains('martial_definitions', 'martial_routine_sword'), true)
        local missing = catalog:require_martial('martial_missing')
        assert.equal(missing.ok, false)
        assert.equal(missing.error.code, 'MARTIAL_UNKNOWN')

        local registry = SectionOwnerRegistry.new()
        assert.equal(registry.ok, true)
        local registered = MartialSectionRegistrar.register({
            system_id = '04',
            section_owners = registry.value,
        })
        assert.equal(registered.ok, true)
        assert.equal(registered.value, 4)
    end),

    case('grant learn upgrade equip and profile hash are deterministic', function()
        local service = bind_service()
        grant_and_learn(service, 'char_hero', 'martial_routine_sword', 'sword')
        grant_and_learn(service, 'char_hero', 'martial_internal_calm', 'internal')
        grant_and_learn(service, 'char_hero', 'martial_lightness_cloud', 'light')

        local equipped = service:commit_loadout({
            character_id = 'char_hero',
            routine_martial_id = 'martial_routine_sword',
            internal_martial_id = 'martial_internal_calm',
            lightness_martial_id = 'martial_lightness_cloud',
            character_level = 10,
            character_tags = {},
            weapon_path = 'SWORD',
            receipt_id = 'receipt_loadout_1',
        })
        assert.equal(equipped.ok, true, equipped.error and equipped.error.code)
        assert.equal(equipped.value.loadout.lightness_martial_id, 'martial_lightness_cloud')
        assert.equal(#equipped.value.contributions >= 3, true)
        assert.equal(equipped.value.lightness_profile ~= nil, true)
        assert.equal(
            LightnessTraversalProfile.validate(equipped.value.lightness_profile).ok,
            true
        )
        assert.equal(#equipped.value.lightness_profile.capability_specs, 1)
        assert.equal(
            equipped.value.lightness_profile.capability_specs[1].capability_id,
            'JUMP_BASIC'
        )

        local first_hash = equipped.value.lightness_profile.profile_hash
        local profile = service:get_lightness_traversal_profile({
            character_id = 'char_hero',
        })
        assert.equal(profile.ok, true)
        assert.equal(profile.value.profile_hash, first_hash)

        local upgraded = service:upgrade({
            character_id = 'char_hero',
            martial_id = 'martial_lightness_cloud',
            target_level = 2,
            character_level = 10,
            receipt_id = 'receipt_upgrade_light_2',
        })
        assert.equal(upgraded.ok, true, upgraded.error and upgraded.error.code)
        assert.equal(upgraded.value.progress.level, 2)
        assert.equal(upgraded.value.lightness_profile ~= nil, true)
        assert.equal(upgraded.value.lightness_profile.source_martial_level, 2)
        assert.truthy(
            upgraded.value.lightness_profile.profile_hash ~= first_hash,
            'profile hash must change after equipped lightness upgrade'
        )

        -- Upgrade to rank 5 unlocks WATER_WALK.
        local level
        for level = 3, 5 do
            local step = service:upgrade({
                character_id = 'char_hero',
                martial_id = 'martial_lightness_cloud',
                target_level = level,
                character_level = 10,
                receipt_id = 'receipt_upgrade_light_' .. tostring(level),
            })
            assert.equal(step.ok, true, step.error and step.error.code)
        end
        local water = service:get_lightness_traversal_profile()
        assert.equal(water.ok, true)
        assert.equal(#water.value.capability_specs, 2)
        assert.equal(water.value.capability_specs[2].capability_id, 'WATER_WALK')
    end),

    case('partner lightness does not change protagonist profile', function()
        local service = bind_service({ world_protagonist_id = 'char_hero' })
        grant_and_learn(service, 'char_hero', 'martial_lightness_cloud', 'hero_light')
        grant_and_learn(service, 'char_ally', 'martial_lightness_cloud', 'ally_light')

        local ally_equip = service:commit_loadout({
            character_id = 'char_ally',
            lightness_martial_id = 'martial_lightness_cloud',
            character_level = 10,
            character_tags = {},
            receipt_id = 'receipt_ally_loadout',
        })
        assert.equal(ally_equip.ok, true, ally_equip.error and ally_equip.error.code)

        local profile = service:get_lightness_traversal_profile({
            character_id = 'char_hero',
        })
        assert.equal(profile.ok, true)
        assert.equal(profile.value.source_martial_id, nil)
        assert.equal(#profile.value.capability_specs, 0)

        local partner_query = service:get_lightness_traversal_profile({
            character_id = 'char_ally',
        })
        assert.equal(partner_query.ok, false)
        assert.equal(partner_query.error.code, 'MARTIAL_TRAVERSAL_PROTAGONIST_REQUIRED')
    end),

    case('learned but unequipped lightness does not grant capabilities', function()
        local service = bind_service()
        grant_and_learn(service, 'char_hero', 'martial_lightness_cloud', 'unequipped')
        local profile = service:get_lightness_traversal_profile()
        assert.equal(profile.ok, true)
        assert.equal(profile.value.source_martial_id, nil)
        assert.equal(#profile.value.capability_specs, 0)
    end),

    case('copy insufficient already learned and weapon mismatch fail closed', function()
        local service = bind_service()
        local grant = service:grant_ownership({
            martial_id = 'martial_routine_sword',
            amount = 1,
            source_type = 'QUEST',
            source_reference = 'quest.a',
            receipt_id = 'receipt_grant_once',
        })
        assert.equal(grant.ok, true)

        local first = service:learn({
            character_id = 'char_hero',
            martial_id = 'martial_routine_sword',
            character_level = 10,
            weapon_path = 'SWORD',
            source_type = 'QUEST',
            source_reference = 'quest.a',
            acquisition_receipt_id = 'receipt_learn_first',
        })
        assert.equal(first.ok, true)

        local second_copy = service:learn({
            character_id = 'char_ally',
            martial_id = 'martial_routine_sword',
            character_level = 10,
            weapon_path = 'SWORD',
            source_type = 'QUEST',
            source_reference = 'quest.a',
            acquisition_receipt_id = 'receipt_learn_second',
        })
        assert.equal(second_copy.ok, false)
        assert.equal(second_copy.error.code, 'MARTIAL_COPY_INSUFFICIENT')

        local already = service:learn({
            character_id = 'char_hero',
            martial_id = 'martial_routine_sword',
            character_level = 10,
            weapon_path = 'SWORD',
            source_type = 'QUEST',
            source_reference = 'quest.a',
            acquisition_receipt_id = 'receipt_learn_again',
        })
        assert.equal(already.ok, false)
        assert.equal(already.error.code, 'MARTIAL_ALREADY_LEARNED')

        grant_and_learn(service, 'char_hero', 'martial_internal_calm', 'int2')
        local bad_weapon = service:commit_loadout({
            character_id = 'char_hero',
            routine_martial_id = 'martial_routine_sword',
            character_level = 10,
            weapon_path = 'BLADE',
            receipt_id = 'receipt_bad_weapon',
        })
        assert.equal(bad_weapon.ok, false)
        assert.equal(bad_weapon.error.code, 'MARTIAL_WEAPON_MISMATCH')
    end),

    case('traversal guard blocks equipped lightness upgrade and swap', function()
        local service = bind_service({ traversal_active = true })
        grant_and_learn(service, 'char_hero', 'martial_lightness_cloud', 'guard1')
        local equip = service:commit_loadout({
            character_id = 'char_hero',
            lightness_martial_id = 'martial_lightness_cloud',
            character_level = 10,
            receipt_id = 'receipt_guard_equip',
        })
        assert.equal(equip.ok, false)
        assert.equal(equip.error.code, 'MARTIAL_TRAVERSAL_ACTIVE')

        service:set_traversal_active(false)
        equip = service:commit_loadout({
            character_id = 'char_hero',
            lightness_martial_id = 'martial_lightness_cloud',
            character_level = 10,
            receipt_id = 'receipt_guard_equip_ok',
        })
        assert.equal(equip.ok, true)

        service:set_traversal_active(true)
        local upgrade = service:upgrade({
            character_id = 'char_hero',
            martial_id = 'martial_lightness_cloud',
            target_level = 2,
            character_level = 10,
            receipt_id = 'receipt_guard_upgrade',
        })
        assert.equal(upgrade.ok, false)
        assert.equal(upgrade.error.code, 'MARTIAL_TRAVERSAL_ACTIVE')

        -- Unequipped martial upgrade does not need guard.
        grant_and_learn(service, 'char_hero', 'martial_routine_sword', 'guard_sword')
        local sword_up = service:upgrade({
            character_id = 'char_hero',
            martial_id = 'martial_routine_sword',
            target_level = 2,
            character_level = 10,
            receipt_id = 'receipt_guard_sword_up',
        })
        assert.equal(sword_up.ok, true, sword_up.error and sword_up.error.code)
    end),

    case('save codec round trip preserves book state', function()
        local service = bind_service()
        grant_and_learn(service, 'char_hero', 'martial_routine_sword', 'save_sword')
        grant_and_learn(service, 'char_hero', 'martial_lightness_cloud', 'save_light')
        local equip = service:commit_loadout({
            character_id = 'char_hero',
            routine_martial_id = 'martial_routine_sword',
            lightness_martial_id = 'martial_lightness_cloud',
            character_level = 10,
            weapon_path = 'SWORD',
            receipt_id = 'receipt_save_loadout',
        })
        assert.equal(equip.ok, true)

        local encoded = service:encode_save_bundle()
        assert.equal(encoded.ok, true, encoded.error and encoded.error.code)
        assert.equal(encoded.value.martial_metadata.schema_version, 1)
        assert.equal(#encoded.value.martial_progress_rows, 2)
        assert.equal(#encoded.value.martial_loadout_rows, 1)

        local reloaded = bind_service()
        local loaded = reloaded:load_save_bundle(encoded.value)
        assert.equal(loaded.ok, true, loaded.error and loaded.error.code)
        local profile = reloaded:get_lightness_traversal_profile()
        assert.equal(profile.ok, true)
        assert.equal(profile.value.source_martial_id, 'martial_lightness_cloud')
        assert.equal(profile.value.profile_hash, equip.value.lightness_profile.profile_hash)

        local decoded = MartialSaveCodec.decode(encoded.value)
        assert.equal(decoded.ok, true)
    end),

    case('receipt replay is idempotent and conflicting payload fails', function()
        local service = bind_service()
        local first = service:grant_ownership({
            martial_id = 'martial_routine_sword',
            amount = 1,
            source_type = 'QUEST',
            source_reference = 'quest.a',
            receipt_id = 'receipt_same',
        })
        assert.equal(first.ok, true)
        local replay = service:grant_ownership({
            martial_id = 'martial_routine_sword',
            amount = 1,
            source_type = 'QUEST',
            source_reference = 'quest.a',
            receipt_id = 'receipt_same',
        })
        assert.equal(replay.ok, true)
        assert.equal(replay.value.ownership.available_copy_count, 1)

        local conflict = service:grant_ownership({
            martial_id = 'martial_routine_sword',
            amount = 2,
            source_type = 'QUEST',
            source_reference = 'quest.a',
            receipt_id = 'receipt_same',
        })
        assert.equal(conflict.ok, false)
        assert.equal(conflict.error.code, 'MARTIAL_RECEIPT_REUSED')
    end),

    case('aggregate rejects skip level and max level', function()
        local catalog = build_catalog()
        local empty = MartialAggregate.empty()
        assert.equal(empty.ok, true)
        local sword = catalog:require_martial('martial_routine_sword').value
        local rule = catalog:require_compatibility_rule(sword.compatibility_rule_id).value
        local granted = MartialAggregate.grant_ownership(empty.value, {
            martial_id = 'martial_routine_sword',
            amount = 1,
            source_type = 'QUEST',
            source_reference = 'quest.a',
        }, sword)
        assert.equal(granted.ok, true)
        local learned = MartialAggregate.learn(granted.value, {
            character_id = 'char_hero',
            martial_id = 'martial_routine_sword',
            character_level = 10,
            weapon_path = 'SWORD',
            source_type = 'QUEST',
            source_reference = 'quest.a',
            acquisition_receipt_id = 'receipt_agg_learn',
        }, sword, rule)
        assert.equal(learned.ok, true)

        local skip = MartialAggregate.upgrade(learned.value, {
            character_id = 'char_hero',
            martial_id = 'martial_routine_sword',
            target_level = 3,
            character_level = 10,
        }, sword)
        assert.equal(skip.ok, false)
        assert.equal(skip.error.code, 'MARTIAL_LEVEL_SEQUENCE_INVALID')
    end),
}
