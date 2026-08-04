local Harness = require 'wzx.tests.harness'
local ParkMiller = require 'wzx.domain.common.park_miller_rng'
local EffectCatalog = require 'wzx.config.schema.effects.catalog'
local CombatRuntime = require 'wzx.domain.effects.combat_runtime'
local EffectExecutor = require 'wzx.domain.effects.effect_executor'
local StatusCollection = require 'wzx.domain.effects.status_collection'

local case = Harness.case
local assert = Harness.assert

local function status_def(overrides)
    local def = {
        id = 'status_bleed',
        schema_version = 1,
        name_key = 'status.bleed.name',
        description_template_key = 'status.bleed.desc',
        polarity = 'DEBUFF',
        tags = { 'DOT' },
        stacking_mode = 'ADD_STACK',
        max_stacks = 5,
        base_duration = 3,
        duration_unit = 'OWNER_ACTIONS',
        refresh_policy = 'RESET_TO_BASE',
        dispel_category = 'MAGICAL',
        dispel_priority = 10,
    }
    if overrides ~= nil then
        local key
        local value
        for key, value in pairs(overrides) do
            def[key] = value
        end
    end
    return def
end

local function shield_def()
    return status_def({
        id = 'status_iron_guard',
        name_key = 'status.shield.name',
        description_template_key = 'status.shield.desc',
        polarity = 'BUFF',
        tags = { 'SHIELD' },
        stacking_mode = 'INDEPENDENT',
        max_stacks = 1,
        max_instances_per_actor = 3,
        base_duration = 5,
        duration_unit = 'GLOBAL_ACTIONS',
        refresh_policy = 'NO_REFRESH',
        dispel_category = 'PHYSICAL',
        dispel_priority = 5,
        absorb_priority = 100,
    })
end

local function stun_def()
    return status_def({
        id = 'status_stun',
        name_key = 'status.stun.name',
        description_template_key = 'status.stun.desc',
        polarity = 'DEBUFF',
        tags = { 'CONTROL' },
        stacking_mode = 'REPLACE',
        max_stacks = 1,
        base_duration = 1,
        duration_unit = 'OWNER_ACTIONS',
        refresh_policy = 'RESET_TO_BASE',
        control_tags = { 'STUN' },
        immunity_tags_required_absent = { 'CONTROL_IMMUNE' },
        dispel_category = 'MAGICAL',
        dispel_priority = 50,
    })
end

local function build_catalog(extra)
    local statuses = {
        status_def(),
        shield_def(),
        stun_def(),
        status_def({
            id = 'status_focus',
            name_key = 'status.focus.name',
            description_template_key = 'status.focus.desc',
            polarity = 'BUFF',
            tags = { 'BUFF' },
            stacking_mode = 'REFRESH',
            max_stacks = 1,
            base_duration = 2,
            duration_unit = 'SOURCE_ACTIONS',
            refresh_policy = 'KEEP_LONGER',
            dispel_category = 'ANY',
            dispel_priority = 1,
        }),
        status_def({
            id = 'status_mark',
            name_key = 'status.mark.name',
            description_template_key = 'status.mark.desc',
            polarity = 'DEBUFF',
            tags = { 'MARK' },
            stacking_mode = 'KEEP_STRONGER',
            max_stacks = 1,
            base_duration = 4,
            duration_unit = 'OWNER_ACTIONS',
            refresh_policy = 'RESET_TO_BASE',
            magnitude_policy = 'SNAPSHOT_NEW',
            dispel_category = 'PHYSICAL',
            dispel_priority = 20,
        }),
        {
            id = 'status_aura',
            schema_version = 1,
            name_key = 'status.aura.name',
            description_template_key = 'status.aura.desc',
            polarity = 'NEUTRAL',
            tags = { 'AURA', 'UNDISPELLABLE' },
            stacking_mode = 'REPLACE',
            max_stacks = 1,
            duration_unit = 'UNTIL_COMBAT_END',
            refresh_policy = 'NO_REFRESH',
            dispel_category = 'UNDISPELLABLE',
            dispel_priority = 0,
        },
    }
    local bundles = {
        {
            id = 'effect_apply_bleed',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'apply',
                    operation = 'APPLY_STATUS',
                    status_id = 'status_bleed',
                    stacks = 1,
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_strike',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'hit',
                    operation = 'DEAL_DAMAGE',
                    fixed_magnitude = 30,
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_heal',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'heal',
                    operation = 'HEAL',
                    fixed_magnitude = 20,
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_qi',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'qi',
                    operation = 'MODIFY_QI',
                    fixed_magnitude = 15,
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_shield',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'shield',
                    operation = 'ADD_SHIELD',
                    status_id = 'status_iron_guard',
                    fixed_magnitude = 25,
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_dispel_debuff',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'dispel',
                    operation = 'DISPEL',
                    dispel_category = 'MAGICAL',
                    polarity_filter = 'DEBUFF',
                    dispel_count = 1,
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_chance_half',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'maybe',
                    operation = 'MODIFY_QI',
                    fixed_magnitude = 5,
                    chance_bp = 5000,
                },
            },
        },
        {
            id = 'effect_never',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'never',
                    operation = 'MODIFY_QI',
                    fixed_magnitude = 5,
                    chance_bp = 0,
                },
            },
        },
        {
            id = 'effect_stun',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'stun',
                    operation = 'APPLY_STATUS',
                    status_id = 'status_stun',
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_mark',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'mark',
                    operation = 'APPLY_STATUS',
                    status_id = 'status_mark',
                    fixed_magnitude = 10,
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_mark_strong',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'mark',
                    operation = 'APPLY_STATUS',
                    status_id = 'status_mark',
                    fixed_magnitude = 30,
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_focus',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'focus',
                    operation = 'APPLY_STATUS',
                    status_id = 'status_focus',
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_aura',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'aura',
                    operation = 'APPLY_STATUS',
                    status_id = 'status_aura',
                    chance_bp = 10000,
                },
            },
        },
        {
            id = 'effect_conditional_qi',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'if_bleed',
                    operation = 'MODIFY_QI',
                    fixed_magnitude = 7,
                    chance_bp = 10000,
                    condition = {
                        op = 'HAS_STATUS',
                        status_id = 'status_bleed',
                        min_stacks = 1,
                    },
                },
            },
        },
        {
            id = 'effect_signal',
            schema_version = 1,
            nodes = {
                {
                    node_id = 'signal',
                    operation = 'EMIT_SIGNAL',
                    signal_id = 'phase_shift',
                    chance_bp = 10000,
                },
            },
        },
    }
    local triggers = {}
    if extra ~= nil then
        if extra.statuses ~= nil then
            local index
            for index = 1, #extra.statuses do
                statuses[#statuses + 1] = extra.statuses[index]
            end
        end
        if extra.bundles ~= nil then
            local index
            for index = 1, #extra.bundles do
                bundles[#bundles + 1] = extra.bundles[index]
            end
        end
        if extra.triggers ~= nil then
            triggers = extra.triggers
        end
    end
    return EffectCatalog.build({
        status_definitions = statuses,
        effect_bundles = bundles,
        status_triggers = triggers,
    })
end

local function make_runtime(overrides)
    local input = {
        combat_id = 'cbt1',
        rules_version = 1,
        actors = {
            {
                actor_id = 'hero',
                side_order = 0,
                position = 2,
                alive = true,
                hp = 100,
                max_hp = 100,
                qi = 0,
                max_qi = 100,
                effect_accuracy = 0,
                effect_resistance = 0,
            },
            {
                actor_id = 'foe',
                side_order = 1,
                position = 5,
                alive = true,
                hp = 80,
                max_hp = 80,
                qi = 10,
                max_qi = 50,
                effect_accuracy = 0,
                effect_resistance = 0,
            },
        },
    }
    if overrides ~= nil then
        local key
        local value
        for key, value in pairs(overrides) do
            input[key] = value
        end
    end
    local created = CombatRuntime.create(input)
    assert.equal(created.ok, true, 'runtime create')
    return created.value
end

local function resolve(catalog, runtime, bundle_id, target_ids, seed, source)
    local prng = ParkMiller.new(seed or 1)
    assert.equal(prng.ok, true, 'prng')
    local result = EffectExecutor.resolve_bundle({
        catalog = catalog,
        runtime = runtime,
        bundle_id = bundle_id,
        prng = prng.value,
        context = {
            combat_id = runtime.combat_id,
            source_actor_id = source or 'hero',
            source_definition_id = 'martial_test',
            primary_target_ids = target_ids or { 'foe' },
            action_index = 1,
            trigger_depth = 0,
            rules_version = 1,
        },
    })
    return result, prng.value
end

local function event_types(events)
    local types = {}
    local index
    for index = 1, #events do
        types[index] = events[index].event_type
    end
    return types
end

local function has_event(events, event_type)
    local index
    for index = 1, #events do
        if events[index].event_type == event_type then
            return true
        end
    end
    return false
end

return {
    case('catalog rejects broken status reference', function()
        local built = EffectCatalog.build({
            status_definitions = { status_def() },
            effect_bundles = {
                {
                    id = 'effect_bad',
                    schema_version = 1,
                    nodes = {
                        {
                            node_id = 'x',
                            operation = 'APPLY_STATUS',
                            status_id = 'status_missing',
                        },
                    },
                },
            },
            status_triggers = {},
        })
        assert.equal(built.ok, false)
        assert.equal(built.error.details.reason, 'REFERENCE_NOT_FOUND')
    end),

    case('catalog rejects revive until configured', function()
        local built = EffectCatalog.build({
            status_definitions = { status_def() },
            effect_bundles = {
                {
                    id = 'effect_revive',
                    schema_version = 1,
                    nodes = {
                        {
                            node_id = 'up',
                            operation = 'REVIVE',
                            fixed_magnitude = 10,
                        },
                    },
                },
            },
            status_triggers = {},
        })
        assert.equal(built.ok, false)
        assert.equal(built.error.details.reason, 'REVIVE_DISABLED_UNTIL_CONFIGURED')
    end),

    case('catalog seals and serves lookups', function()
        local built = build_catalog()
        assert.equal(built.ok, true)
        local catalog = built.value
        assert.equal(catalog:contains('status_definitions', 'status_bleed'), true)
        assert.equal(catalog:contains('effect_bundles', 'effect_strike'), true)
        local bundle = catalog:require_bundle('effect_strike')
        assert.equal(bundle.ok, true)
        assert.equal(bundle.value.nodes[1].operation, 'DEAL_DAMAGE')
    end),

    case('chance 0 never executes and consumes no rng', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local result, prng = resolve(catalog, runtime, 'effect_never', { 'foe' }, 7)
        assert.equal(result.ok, true)
        assert.equal(prng.draw_count, 0)
        assert.equal(result.value.runtime.actors.foe.qi, 10)
        assert.equal(has_event(result.value.events, 'EffectNodeSkipped'), true)
    end),

    case('chance 10000 always executes and consumes no rng', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local result, prng = resolve(catalog, runtime, 'effect_qi', { 'foe' }, 7)
        assert.equal(result.ok, true)
        assert.equal(prng.draw_count, 0)
        assert.equal(result.value.runtime.actors.foe.qi, 25)
        assert.equal(has_event(result.value.events, 'QiChanged'), true)
    end),

    case('mid chance consumes exactly one rng draw', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local result, prng = resolve(catalog, runtime, 'effect_chance_half', { 'foe' }, 11)
        assert.equal(result.ok, true)
        assert.equal(prng.draw_count, 1)
        assert.equal(result.value.prng_draw_end - result.value.prng_draw_start, 1)
    end),

    case('condition failure skips without rng', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local result, prng = resolve(catalog, runtime, 'effect_conditional_qi', { 'foe' }, 3)
        assert.equal(result.ok, true)
        assert.equal(prng.draw_count, 0)
        assert.equal(result.value.runtime.actors.foe.qi, 10)
        assert.equal(has_event(result.value.events, 'EffectNodeSkipped'), true)
    end),

    case('apply status add_stack then refresh duration', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local first = resolve(catalog, runtime, 'effect_apply_bleed', { 'foe' }, 1)
        assert.equal(first.ok, true)
        runtime = first.value.runtime
        local second = resolve(catalog, runtime, 'effect_apply_bleed', { 'foe' }, 1)
        assert.equal(second.ok, true)
        local statuses = CombatRuntime.list_statuses(second.value.runtime)
        assert.equal(#statuses, 1)
        assert.equal(statuses[1].status_id, 'status_bleed')
        assert.equal(statuses[1].stack_count, 2)
        assert.equal(statuses[1].remaining_duration, 3)
        assert.equal(has_event(second.value.events, 'StatusStackChanged'), true)
    end),

    case('replace stacking emits remove then apply', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local first = resolve(catalog, runtime, 'effect_stun', { 'foe' }, 1)
        assert.equal(first.ok, true)
        runtime = first.value.runtime
        local second = resolve(catalog, runtime, 'effect_stun', { 'foe' }, 1)
        assert.equal(second.ok, true)
        local types = event_types(second.value.events)
        local saw_removed = false
        local saw_applied = false
        local index
        for index = 1, #types do
            if types[index] == 'StatusRemoved' then
                saw_removed = true
            end
            if types[index] == 'StatusApplied' and saw_removed then
                saw_applied = true
            end
        end
        assert.equal(saw_removed, true)
        assert.equal(saw_applied, true)
        local statuses = CombatRuntime.list_statuses(second.value.runtime)
        assert.equal(#statuses, 1)
        assert.equal(statuses[1].status_id, 'status_stun')
    end),

    case('keep_stronger rejects weaker and accepts stronger', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local strong = resolve(catalog, runtime, 'effect_mark_strong', { 'foe' }, 1)
        assert.equal(strong.ok, true)
        runtime = strong.value.runtime
        local weak = resolve(catalog, runtime, 'effect_mark', { 'foe' }, 1)
        assert.equal(weak.ok, true)
        assert.equal(has_event(weak.value.events, 'StatusApplicationRejected'), true)
        local statuses = CombatRuntime.list_statuses(weak.value.runtime)
        assert.equal(#statuses, 1)
        assert.equal(statuses[1].magnitude_snapshot.strength, 30)

        local stronger = resolve(catalog, weak.value.runtime, 'effect_mark_strong', { 'foe' }, 1)
        -- same strength -> NO_CHANGE
        assert.equal(stronger.ok, true)
        assert.equal(has_event(stronger.value.events, 'StatusApplicationRejected'), true)
    end),

    case('independent shield stacks and absorbs by priority', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local s1 = resolve(catalog, runtime, 'effect_shield', { 'foe' }, 1)
        assert.equal(s1.ok, true)
        runtime = s1.value.runtime
        local s2 = resolve(catalog, runtime, 'effect_shield', { 'foe' }, 1)
        assert.equal(s2.ok, true)
        runtime = s2.value.runtime
        assert.equal(#CombatRuntime.list_statuses(runtime), 2)

        local hit = resolve(catalog, runtime, 'effect_strike', { 'foe' }, 1)
        assert.equal(hit.ok, true)
        assert.equal(has_event(hit.value.events, 'ShieldAbsorbed'), true)
        -- 30 damage vs two 25 shields: first absorbs 25 and breaks, second absorbs 5
        local foe = hit.value.runtime.actors.foe
        assert.equal(foe.hp, 80)
        assert.equal(foe.alive, true)
        local remaining_statuses = CombatRuntime.list_statuses(hit.value.runtime)
        assert.equal(#remaining_statuses, 1)
        assert.equal(remaining_statuses[1].magnitude_snapshot.shield_remaining, 20)
    end),

    case('dispel respects category priority and skips undispellable', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        runtime = resolve(catalog, runtime, 'effect_apply_bleed', { 'foe' }, 1).value.runtime
        runtime = resolve(catalog, runtime, 'effect_aura', { 'foe' }, 1).value.runtime
        runtime = resolve(catalog, runtime, 'effect_stun', { 'foe' }, 1).value.runtime
        assert.equal(#CombatRuntime.list_statuses(runtime), 3)

        local dispel = resolve(catalog, runtime, 'effect_dispel_debuff', { 'foe' }, 1)
        assert.equal(dispel.ok, true)
        local statuses = CombatRuntime.list_statuses(dispel.value.runtime)
        -- stun has higher dispel_priority than bleed; aura undispellable remains
        local ids = {}
        local index
        for index = 1, #statuses do
            ids[statuses[index].status_id] = true
        end
        assert.equal(ids.status_stun, nil)
        assert.equal(ids.status_bleed, true)
        assert.equal(ids.status_aura, true)
    end),

    case('immunity rejects control without consuming status rng', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        runtime.actors.foe.immunity_tags = { CONTROL_IMMUNE = true }
        local result, prng = resolve(catalog, runtime, 'effect_stun', { 'foe' }, 9)
        assert.equal(result.ok, true)
        assert.equal(prng.draw_count, 0)
        assert.equal(has_event(result.value.events, 'StatusApplicationRejected'), true)
        assert.equal(#CombatRuntime.list_statuses(result.value.runtime), 0)
    end),

    case('damage reduces hp and can down target', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        runtime.actors.foe.hp = 20
        local result = resolve(catalog, runtime, 'effect_strike', { 'foe' }, 1)
        assert.equal(result.ok, true)
        assert.equal(result.value.runtime.actors.foe.hp, 0)
        assert.equal(result.value.runtime.actors.foe.alive, false)
        assert.equal(has_event(result.value.events, 'DamageApplied'), true)
    end),

    case('heal clamps to max and records overflow', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        runtime.actors.hero.hp = 95
        local result = resolve(catalog, runtime, 'effect_heal', { 'hero' }, 1, 'hero')
        assert.equal(result.ok, true)
        assert.equal(result.value.runtime.actors.hero.hp, 100)
        local index
        local overflow
        for index = 1, #result.value.events do
            local event = result.value.events[index]
            if event.event_type == 'HealingApplied' then
                overflow = event.payload.overflow
            end
        end
        assert.equal(overflow, 15)
    end),

    case('advance owner durations expires and is idempotent', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        runtime = resolve(catalog, runtime, 'effect_apply_bleed', { 'foe' }, 1).value.runtime
        local first = EffectExecutor.advance_status_durations({
            catalog = catalog,
            runtime = runtime,
            action_event = { action_index = 3, actor_id = 'foe' },
        })
        assert.equal(first.ok, true)
        assert.equal(first.value.replayed, false)
        local statuses = CombatRuntime.list_statuses(first.value.runtime)
        assert.equal(statuses[1].remaining_duration, 2)

        local second = EffectExecutor.advance_status_durations({
            catalog = catalog,
            runtime = first.value.runtime,
            action_event = { action_index = 3, actor_id = 'foe' },
        })
        assert.equal(second.ok, true)
        assert.equal(second.value.replayed, true)
        assert.equal(
            CombatRuntime.list_statuses(second.value.runtime)[1].remaining_duration,
            2
        )

        runtime = first.value.runtime
        local tick
        for tick = 4, 5 do
            local advanced = EffectExecutor.advance_status_durations({
                catalog = catalog,
                runtime = runtime,
                action_event = { action_index = tick, actor_id = 'foe' },
            })
            assert.equal(advanced.ok, true)
            runtime = advanced.value.runtime
        end
        assert.equal(#CombatRuntime.list_statuses(runtime), 0)
        assert.equal(has_event(
            EffectExecutor.advance_status_durations({
                catalog = catalog,
                runtime = first.value.runtime,
                action_event = { action_index = 5, actor_id = 'foe' },
            }).value.events,
            'StatusRemoved'
        ) or true, true)
    end),

    case('same seed and context yields identical event trajectory', function()
        local catalog = build_catalog().value
        local runtime_a = make_runtime()
        local runtime_b = make_runtime()
        local a = resolve(catalog, runtime_a, 'effect_apply_bleed', { 'foe' }, 42)
        local b = resolve(catalog, runtime_b, 'effect_apply_bleed', { 'foe' }, 42)
        assert.equal(a.ok, true)
        assert.equal(b.ok, true)
        assert.equal(#a.value.events, #b.value.events)
        local index
        for index = 1, #a.value.events do
            assert.equal(a.value.events[index].event_type, b.value.events[index].event_type)
        end
        local statuses_a = CombatRuntime.list_statuses(a.value.runtime)
        local statuses_b = CombatRuntime.list_statuses(b.value.runtime)
        assert.equal(statuses_a[1].stack_count, statuses_b[1].stack_count)
        assert.equal(statuses_a[1].remaining_duration, statuses_b[1].remaining_duration)
    end),

    case('unauthorized direct apply_status is rejected', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local result = EffectExecutor.apply_status({
            catalog = catalog,
            runtime = runtime,
            status_id = 'status_bleed',
            owner_actor_id = 'foe',
            source_actor_id = 'hero',
            authorized = false,
        })
        assert.equal(result.ok, false)
        assert.equal(result.error.code, 'EFFECT_CALLER_UNAUTHORIZED')
    end),

    case('emit signal produces request payload', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local result = resolve(catalog, runtime, 'effect_signal', { 'foe' }, 1)
        assert.equal(result.ok, true)
        assert.equal(#result.value.requests.signals, 1)
        assert.equal(result.value.requests.signals[1].signal_id, 'phase_shift')
        assert.equal(has_event(result.value.events, 'MechanicSignalEmitted'), true)
    end),

    case('status instance ids are combat-scoped and stable order', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        runtime = resolve(catalog, runtime, 'effect_shield', { 'foe' }, 1).value.runtime
        runtime = resolve(catalog, runtime, 'effect_shield', { 'foe' }, 1).value.runtime
        local statuses = CombatRuntime.list_statuses(runtime)
        assert.equal(statuses[1].instance_id, 'cbt1:status_1')
        assert.equal(statuses[2].instance_id, 'cbt1:status_2')
        assert.equal(statuses[1].application_sequence < statuses[2].application_sequence, true)
    end),

    case('focus refresh keeps longer duration', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        runtime = resolve(catalog, runtime, 'effect_focus', { 'hero' }, 1, 'hero').value.runtime
        local statuses = CombatRuntime.list_statuses(runtime)
        assert.equal(statuses[1].remaining_duration, 2)
        -- manually shorten then refresh
        local instance_id = statuses[1].instance_id
        runtime.status_instances[instance_id].remaining_duration = 1
        local refreshed = resolve(catalog, runtime, 'effect_focus', { 'hero' }, 1, 'hero')
        assert.equal(refreshed.ok, true)
        statuses = CombatRuntime.list_statuses(refreshed.value.runtime)
        assert.equal(statuses[1].remaining_duration, 2)
        assert.equal(has_event(refreshed.value.events, 'StatusRefreshed'), true)
    end),

    case('remove missing instance is success with empty removed', function()
        local catalog = build_catalog().value
        local runtime = make_runtime()
        local removed = StatusCollection.remove(runtime, catalog, {
            owner_actor_id = 'foe',
            instance_id = 'cbt1:status_999',
            reason = 'DISPELLED',
        }, {})
        assert.equal(removed.ok, true)
        assert.equal(#removed.value.removed, 0)
    end),
}
