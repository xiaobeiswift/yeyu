local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local Codec = require 'wzx.domain.common.canonical_value_codec_v1'
local Sha256 = require 'wzx.domain.common.sha256'
local DeriveSeed = require 'wzx.domain.common.derive_seed_v1'
local CombatSnapshot = require 'wzx.domain.contracts.combat_snapshot'
local Rules = require 'wzx.domain.combat.rules'
local EnemyBuilder = require 'wzx.domain.encounter.enemy_builder'
local WaveController = require 'wzx.domain.encounter.wave_controller'
local BossPhase = require 'wzx.domain.encounter.boss_phase'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local EncounterRun = {}
local get_metatable = getmetatable
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type
local string_rep = string.rep
local table_concat = table.concat

local PHASE = {
    PREPARING = 'PREPARING',
    ENTRY_COMMITTED = 'ENTRY_COMMITTED',
    COMBAT_ACTIVE = 'COMBAT_ACTIVE',
    WAVE_CLEARED = 'WAVE_CLEARED',
    RESULT_PENDING = 'RESULT_PENDING',
    SETTLING = 'SETTLING',
    COMPLETED = 'COMPLETED',
    FAILED = 'FAILED',
    ABANDONED = 'ABANDONED',
    INVALID = 'INVALID',
}

local VICTORY_OUTCOMES = {
    ATTACKER_WIN = true,
}
local FAILURE_OUTCOMES = {
    DEFENDER_WIN = true,
    ATTACKER_FORFEIT = true,
    TIMEOUT = true,
}
local RULE_ERROR_OUTCOMES = {
    INVALID_RULE_EXECUTION = true,
}

local PARTY_HASH_SPECS = {
    { name = 'party_revision', type = Codec.TYPE_INTEGER },
    { name = 'member_digest', type = Codec.TYPE_STRING },
}
local RESULT_HASH_SPECS = {
    { name = 'combat_id', type = Codec.TYPE_STRING },
    { name = 'outcome', type = Codec.TYPE_STRING },
    { name = 'event_hash', type = Codec.TYPE_STRING },
    { name = 'snapshot_hash', type = Codec.TYPE_STRING },
    { name = 'rules_version', type = Codec.TYPE_INTEGER },
}
local SNAPSHOT_HASH_SPECS = {
    { name = 'encounter_id', type = Codec.TYPE_STRING },
    { name = 'run_id', type = Codec.TYPE_STRING },
    { name = 'wave_index', type = Codec.TYPE_INTEGER },
    { name = 'seed', type = Codec.TYPE_INTEGER },
    { name = 'attacker_hash', type = Codec.TYPE_STRING },
    { name = 'defender_hash', type = Codec.TYPE_STRING },
    { name = 'rules_version', type = Codec.TYPE_INTEGER },
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.encounter.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID, reason, details)
end

local function phase_fail(reason, details)
    return fail(EncounterErrorCodes.ENCOUNTER_PHASE_INVALID, reason, details)
end

local function sha_hex(namespace, specs, values)
    local encoded = Codec.encode(namespace, specs, values)
    if not encoded.ok then
        return encoded
    end
    local digest, hash_error = Sha256.hex(encoded.value)
    if digest == nil then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'HASH_FAILED',
            { reason = hash_error, namespace = namespace }
        )
    end
    return result_ok(digest)
end

local function copy_member(member)
    local tags = {}
    local statuses = {}
    local index
    for index = 1, #member.tags do
        tags[index] = member.tags[index]
    end
    for index = 1, #member.initial_status_ids do
        statuses[index] = member.initial_status_ids[index]
    end
    local stats = {}
    local key
    local value
    for key, value in pairs(member.stats) do
        stats[key] = value
    end
    return {
        actor_id = member.actor_id,
        definition_id = member.definition_id,
        side = member.side,
        position_index = member.position_index,
        level = member.level,
        tags = tags,
        stats = stats,
        martial_loadout = member.martial_loadout,
        initial_status_ids = statuses,
        ai_profile_id = member.ai_profile_id,
        source_revision = member.source_revision,
        source_hash = member.source_hash,
    }
end

local function copy_strings(values)
    local copied = {}
    local index
    for index = 1, #values do
        copied[index] = values[index]
    end
    return copied
end

local function copy_vitals_map(vitals)
    if vitals == nil then
        return nil
    end
    local copied = {}
    local actor_id
    local row
    for actor_id, row in pairs(vitals) do
        copied[actor_id] = {
            current_hp = row.current_hp,
            current_qi = row.current_qi,
        }
    end
    return copied
end

local function formation_source_hash(members)
    local chunks = {}
    local index
    for index = 1, #members do
        chunks[#chunks + 1] = members[index].actor_id
            .. ':'
            .. members[index].definition_id
            .. ':'
            .. tostring(members[index].level)
            .. ':'
            .. members[index].source_hash
    end
    local digest, hash_error = Sha256.hex(table_concat(chunks, '|'))
    if digest == nil then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'FORMATION_HASH_FAILED',
            { reason = hash_error }
        )
    end
    return result_ok(digest)
end

local function validate_attacker_formation(members)
    if type_value(members) ~= 'table' or get_metatable(members) ~= nil then
        return invalid('ATTACKER_MEMBERS_REQUIRED')
    end
    if #members < 1 or #members > 4 then
        return fail(
            EncounterErrorCodes.ENCOUNTER_PARTY_INVALID,
            'ATTACKER_COUNT_OUT_OF_RANGE',
            { count = #members }
        )
    end
    local previous_position = -1
    local actor_ids = {}
    local CombatantSnapshot = require 'wzx.domain.contracts.combatant_snapshot'
    local index
    for index = 1, #members do
        local member = members[index]
        local validated = CombatantSnapshot.validate(member, 'ATTACKER')
        if not validated.ok then
            return fail(
                EncounterErrorCodes.ENCOUNTER_PARTY_INVALID,
                'ATTACKER_MEMBER_INVALID',
                { index = index }
            )
        end
        if actor_ids[member.actor_id] or member.position_index <= previous_position then
            return fail(
                EncounterErrorCodes.ENCOUNTER_PARTY_INVALID,
                'ATTACKER_ORDER_INVALID',
                { index = index }
            )
        end
        actor_ids[member.actor_id] = true
        previous_position = member.position_index
    end
    return result_ok(true)
end

local function resolve_root_seed(encounter, start_receipt_id)
    if encounter.seed_policy == 'FIXED' then
        return result_ok(encounter.fixed_seed)
    end
    if encounter.seed_policy == 'DERIVE_FROM_RUN_RECEIPT' then
        local root = 1
        local derived = DeriveSeed.derive(root, 'combat', start_receipt_id)
        if not derived.ok then
            local digest, hash_error = Sha256.hex('seed|' .. start_receipt_id)
            if digest == nil then
                return fail(
                    EncounterErrorCodes.ENCOUNTER_SEED_INVALID,
                    'SEED_DERIVE_FAILED',
                    { reason = hash_error }
                )
            end
            local numeric = 0
            local index
            for index = 1, 8 do
                local byte = string.byte(digest, index)
                numeric = numeric * 16
                if byte >= 48 and byte <= 57 then
                    numeric = numeric + (byte - 48)
                elseif byte >= 97 and byte <= 102 then
                    numeric = numeric + (byte - 87)
                end
            end
            numeric = (numeric % 2147483646) + 1
            return result_ok(numeric)
        end
        return result_ok(derived.value.seed)
    end
    return fail(
        EncounterErrorCodes.ENCOUNTER_SEED_INVALID,
        'SEED_POLICY_UNSUPPORTED',
        { seed_policy = encounter.seed_policy }
    )
end

local function wave_seed(root_seed, wave_index)
    if wave_index == 1 then
        return result_ok(root_seed)
    end
    local derived = DeriveSeed.derive(root_seed, 'combat', 'wave_' .. tostring(wave_index))
    if not derived.ok then
        return fail(
            EncounterErrorCodes.ENCOUNTER_SEED_INVALID,
            'WAVE_SEED_DERIVE_FAILED',
            {
                wave_index = wave_index,
                cause_code = derived.error and derived.error.code or 'UNKNOWN',
            }
        )
    end
    return result_ok(derived.value.seed)
end

local function make_combat_id(run_id, wave_index)
    local combat_id = 'cbt_' .. run_id .. '_w' .. tostring(wave_index)
    local combat_check = RuntimeId.validate_component(combat_id, 'combat_id')
    if not combat_check.ok then
        return invalid('COMBAT_ID_INVALID', { combat_id = combat_id })
    end
    return result_ok(combat_id)
end

local function collect_move_library(catalog)
    local library = {}
    if type_value(catalog.list) ~= 'function' then
        return library
    end
    local listed = catalog:list('enemy_move_sets')
    if not listed.ok then
        return library
    end
    local index
    for index = 1, #listed.value do
        local move_set = listed.value[index]
        if move_set.basic_move ~= nil then
            library[move_set.basic_move.move_id] = move_set.basic_move
        end
        local move_index
        for move_index = 1, #(move_set.active_moves or {}) do
            local move = move_set.active_moves[move_index]
            library[move.move_id] = move
        end
    end
    return library
end

local function wave_has_spawn(wave, spawn_id)
    local index
    for index = 1, #wave.spawn_rows do
        if wave.spawn_rows[index].spawn_id == spawn_id then
            return true
        end
    end
    return false
end

local function build_boss_runtime_for_wave(catalog, encounter, run_id, wave)
    if encounter.boss_controller_id == nil then
        return result_ok(nil)
    end
    if type_value(catalog.require_boss_controller) ~= 'function' then
        return result_ok(nil)
    end
    local controller = catalog:require_boss_controller(encounter.boss_controller_id)
    if not controller.ok then
        return controller
    end
    controller = controller.value
    if not wave_has_spawn(wave, controller.boss_spawn_id) then
        return result_ok(nil)
    end
    local boss_actor_id = run_id .. ':' .. controller.boss_spawn_id
    local phases = {}
    local index
    for index = 1, #controller.phase_ids do
        local phase = catalog:require_boss_phase(controller.phase_ids[index])
        if not phase.ok then
            return phase
        end
        phases[index] = phase.value
    end
    return BossPhase.create_runtime({
        controller = controller,
        phases = phases,
        boss_actor_id = boss_actor_id,
        move_library = collect_move_library(catalog),
    })
end

local function build_wave_snapshot(run_ctx, wave, attackers, wave_index)
    local defenders = EnemyBuilder.build_wave_defenders(run_ctx.catalog, wave, {
        run_id = run_ctx.run_id,
        source_revision = 1,
    })
    if not defenders.ok then
        return defenders
    end

    local seed = wave_seed(run_ctx.root_seed, wave_index)
    if not seed.ok then
        return seed
    end

    local attacker_hash = formation_source_hash(attackers)
    if not attacker_hash.ok then
        return attacker_hash
    end
    local defender_hash = formation_source_hash(defenders.value.members)
    if not defender_hash.ok then
        return defender_hash
    end

    local snapshot_hash = sha_hex('combat_snapshot_v1', SNAPSHOT_HASH_SPECS, {
        encounter_id = run_ctx.encounter_id,
        run_id = run_ctx.run_id,
        wave_index = wave_index,
        seed = seed.value,
        attacker_hash = attacker_hash.value,
        defender_hash = defender_hash.value,
        rules_version = run_ctx.rules_version,
    })
    if not snapshot_hash.ok then
        return snapshot_hash
    end

    local combat_id = make_combat_id(run_ctx.run_id, wave_index)
    if not combat_id.ok then
        return combat_id
    end

    local snapshot = {
        snapshot_schema_version = 1,
        rules_version = run_ctx.rules_version,
        combat_kind = run_ctx.combat_kind,
        encounter_id = run_ctx.encounter_id,
        attacker_formation = { members = attackers },
        defender_formation = { members = defenders.value.members },
        environment_spec_id = run_ctx.environment_spec_id,
        control_policy = run_ctx.control_policy,
        seed = seed.value,
        action_limit = run_ctx.action_limit,
        event_budget = run_ctx.event_budget,
        source_hashes = {
            attacker = attacker_hash.value,
            defender = defender_hash.value,
        },
        snapshot_hash = snapshot_hash.value,
    }
    local snapshot_ok = CombatSnapshot.validate(snapshot)
    if not snapshot_ok.ok then
        return fail(
            EncounterErrorCodes.ENCOUNTER_BUILD_INVALID,
            'COMBAT_SNAPSHOT_INVALID',
            {
                wave_index = wave_index,
                cause_code = snapshot_ok.error and snapshot_ok.error.code or 'UNKNOWN',
            }
        )
    end

    return result_ok({
        combat_id = combat_id.value,
        snapshot = snapshot,
        wave_id = wave.id,
        wave_index = wave_index,
        wave_seed = seed.value,
    })
end

local function append_wave_event(run, event_type, payload)
    run.wave_events[#run.wave_events + 1] = {
        event_type = event_type,
        wave_id = payload.wave_id,
        wave_index = payload.wave_index,
        combat_id = payload.combat_id,
        result_hash = payload.result_hash,
        sequence = #run.wave_events + 1,
    }
end

local function compute_result_hash(combat_id, combat_result)
    return sha_hex('encounter_result_v1', RESULT_HASH_SPECS, {
        combat_id = combat_id,
        outcome = combat_result.outcome,
        event_hash = combat_result.event_hash,
        snapshot_hash = combat_result.snapshot_hash,
        rules_version = combat_result.rules_version,
    })
end

function EncounterRun.prepare(catalog, input)
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_encounter) ~= 'function'
    then
        return invalid('CATALOG_REQUIRED')
    end
    if type_value(input) ~= 'table' or get_metatable(input) ~= nil then
        return invalid('INPUT_REQUIRED')
    end

    local encounter_id = raw_get(input, 'encounter_id')
    local run_id = raw_get(input, 'run_id')
    local start_receipt_id = raw_get(input, 'start_receipt_id')
    local attacker_members = raw_get(input, 'attacker_members')
    local party_revision = raw_get(input, 'party_revision') or 1
    local control_policy = raw_get(input, 'control_policy') or 'AUTO_ALL'
    local first_clear_already = raw_get(input, 'first_clear_already') == true

    local run_check = RuntimeId.validate_derived(run_id, 'run_id')
    if not run_check.ok then
        return invalid('RUN_ID_INVALID')
    end
    local receipt_check = RuntimeId.validate_derived(start_receipt_id, 'start_receipt_id')
    if not receipt_check.ok then
        return invalid('START_RECEIPT_INVALID')
    end
    if control_policy ~= 'AUTO_ALL' and control_policy ~= 'MANUAL_ULTIMATE' then
        return invalid('CONTROL_POLICY_INVALID')
    end

    local encounter = catalog:require_encounter(encounter_id)
    if not encounter.ok then
        return encounter
    end
    encounter = encounter.value
    if encounter.rules_version ~= Rules.RULES_VERSION then
        return fail(
            EncounterErrorCodes.ENCOUNTER_RULES_MISMATCH,
            'RULES_VERSION_UNSUPPORTED',
            {
                expected = Rules.RULES_VERSION,
                actual = encounter.rules_version,
            }
        )
    end

    local attackers_ok = validate_attacker_formation(attacker_members)
    if not attackers_ok.ok then
        return attackers_ok
    end

    local root_seed = resolve_root_seed(encounter, start_receipt_id)
    if not root_seed.ok then
        return root_seed
    end

    local copied_attackers = {}
    local index
    for index = 1, #attacker_members do
        copied_attackers[index] = copy_member(attacker_members[index])
    end

    local member_digest_parts = {}
    for index = 1, #copied_attackers do
        member_digest_parts[index] = copied_attackers[index].actor_id
            .. ':'
            .. copied_attackers[index].definition_id
    end
    local party_hash = sha_hex('party_snapshot_v1', PARTY_HASH_SPECS, {
        party_revision = party_revision,
        member_digest = table_concat(member_digest_parts, '|'),
    })
    if not party_hash.ok then
        return party_hash
    end

    local first_wave = catalog:require_wave(encounter.wave_ids[1])
    if not first_wave.ok then
        return first_wave
    end

    local run_ctx = {
        catalog = catalog,
        run_id = run_id,
        encounter_id = encounter.id,
        rules_version = encounter.rules_version,
        combat_kind = encounter.combat_kind,
        environment_spec_id = encounter.environment_spec_id,
        control_policy = control_policy,
        action_limit = encounter.action_limit,
        event_budget = encounter.event_budget,
        root_seed = root_seed.value,
        boss_controller_id = encounter.boss_controller_id,
    }

    local wave_bundle = build_wave_snapshot(
        run_ctx,
        first_wave.value,
        copied_attackers,
        1
    )
    if not wave_bundle.ok then
        return wave_bundle
    end

    local boss_runtime = build_boss_runtime_for_wave(
        catalog,
        encounter,
        run_id,
        first_wave.value
    )
    if not boss_runtime.ok then
        return boss_runtime
    end

    local run = {
        run_id = run_id,
        encounter_id = encounter.id,
        rules_version = encounter.rules_version,
        state = PHASE.ENTRY_COMMITTED,
        start_receipt_id = start_receipt_id,
        party_snapshot_hash = party_hash.value,
        seed = root_seed.value,
        combat_id = wave_bundle.value.combat_id,
        combat_snapshot = wave_bundle.value.snapshot,
        actor_vitals = nil,
        boss_controller_id = encounter.boss_controller_id,
        boss_runtime = boss_runtime.value,
        wave_ids = copy_strings(encounter.wave_ids),
        wave_count = #encounter.wave_ids,
        wave_id = wave_bundle.value.wave_id,
        wave_index = 1,
        wave_seed = wave_bundle.value.wave_seed,
        cleared_wave_ids = {},
        wave_events = {},
        attacker_members = copied_attackers,
        control_policy = control_policy,
        combat_kind = encounter.combat_kind,
        environment_spec_id = encounter.environment_spec_id,
        action_limit = encounter.action_limit,
        event_budget = encounter.event_budget,
        first_clear_already = first_clear_already,
        completion_fact_id = encounter.completion_fact_id,
        first_clear_reward_bundle_id = encounter.first_clear_reward_bundle_id,
        repeat_reward_bundle_id = encounter.repeat_reward_bundle_id,
        first_clear_loot_table_id = encounter.first_clear_loot_table_id,
        repeat_loot_table_id = encounter.repeat_loot_table_id,
        result = nil,
        result_hash = nil,
        settlement_receipt_id = nil,
        settlement_plan = nil,
        pending_wave_clear = nil,
        retry_count = 0,
        revision = 1,
    }

    append_wave_event(run, 'WaveStarted', {
        wave_id = run.wave_id,
        wave_index = 1,
        combat_id = run.combat_id,
    })

    return result_ok(run)
end

function EncounterRun.activate_combat(run)
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end
    if run.state ~= PHASE.ENTRY_COMMITTED then
        return phase_fail('ENTRY_COMMITTED_REQUIRED', { state = run.state })
    end
    run.state = PHASE.COMBAT_ACTIVE
    run.revision = run.revision + 1
    return result_ok({
        combat_id = run.combat_id,
        snapshot = run.combat_snapshot,
        actor_vitals = copy_vitals_map(run.actor_vitals),
        boss_runtime = run.boss_runtime,
        wave_index = run.wave_index,
        wave_id = run.wave_id,
        revision = run.revision,
    })
end

function EncounterRun.record_combat_result(run, combat_result)
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end
    if run.state ~= PHASE.COMBAT_ACTIVE
        and run.state ~= PHASE.RESULT_PENDING
        and run.state ~= PHASE.WAVE_CLEARED
    then
        return phase_fail(
            'COMBAT_ACTIVE_OR_RESULT_OR_WAVE_CLEARED_REQUIRED',
            { state = run.state }
        )
    end
    if type_value(combat_result) ~= 'table' or get_metatable(combat_result) ~= nil then
        return invalid('COMBAT_RESULT_REQUIRED')
    end

    local outcome = raw_get(combat_result, 'outcome')
    local event_hash = raw_get(combat_result, 'event_hash')
    local snapshot_hash = raw_get(combat_result, 'snapshot_hash')
    local rules_version = raw_get(combat_result, 'rules_version')
    local combat_id = raw_get(combat_result, 'combat_id') or run.combat_id

    if type_value(outcome) ~= 'string'
        or (
            not VICTORY_OUTCOMES[outcome]
            and not FAILURE_OUTCOMES[outcome]
            and not RULE_ERROR_OUTCOMES[outcome]
        )
    then
        return fail(
            EncounterErrorCodes.ENCOUNTER_RESULT_UNVERIFIED,
            'OUTCOME_INVALID',
            { outcome = outcome }
        )
    end
    if type_value(event_hash) ~= 'string'
        or #event_hash ~= 64
        or type_value(snapshot_hash) ~= 'string'
        or #snapshot_hash ~= 64
    then
        return fail(
            EncounterErrorCodes.ENCOUNTER_RESULT_UNVERIFIED,
            'HASH_INVALID'
        )
    end
    if rules_version ~= run.rules_version then
        return fail(
            EncounterErrorCodes.ENCOUNTER_RULES_MISMATCH,
            'RESULT_RULES_MISMATCH',
            {
                expected = run.rules_version,
                actual = rules_version,
            }
        )
    end
    if snapshot_hash ~= run.combat_snapshot.snapshot_hash then
        return fail(
            EncounterErrorCodes.ENCOUNTER_RESULT_MISMATCH,
            'SNAPSHOT_HASH_MISMATCH'
        )
    end
    if combat_id ~= run.combat_id then
        return fail(
            EncounterErrorCodes.ENCOUNTER_RESULT_MISMATCH,
            'COMBAT_ID_MISMATCH',
            {
                expected = run.combat_id,
                actual = combat_id,
            }
        )
    end

    local result_hash = compute_result_hash(run.combat_id, {
        outcome = outcome,
        event_hash = event_hash,
        snapshot_hash = snapshot_hash,
        rules_version = rules_version,
    })
    if not result_hash.ok then
        return result_hash
    end

    -- Idempotent replay for terminal or wave-cleared states.
    if run.state == PHASE.RESULT_PENDING or run.state == PHASE.WAVE_CLEARED then
        local expected_hash = run.result_hash
        if run.state == PHASE.WAVE_CLEARED and run.pending_wave_clear ~= nil then
            expected_hash = run.pending_wave_clear.result_hash
        end
        if expected_hash ~= result_hash.value then
            return fail(
                EncounterErrorCodes.ENCOUNTER_RESULT_MISMATCH,
                'RESULT_HASH_CONFLICT',
                {
                    existing = expected_hash,
                    incoming = result_hash.value,
                }
            )
        end
        return result_ok({
            state = run.state,
            result_hash = expected_hash,
            idempotent = true,
            terminal = run.state == PHASE.RESULT_PENDING,
            wave_cleared = run.state == PHASE.WAVE_CLEARED,
            wave_index = run.wave_index,
            has_more_waves = run.wave_index < run.wave_count,
        })
    end

    local recorded = {
        outcome = outcome,
        winner_side = combat_result.winner_side,
        finish_reason = combat_result.finish_reason,
        action_count = combat_result.action_count,
        event_hash = event_hash,
        snapshot_hash = snapshot_hash,
        command_hash = combat_result.command_hash,
        rules_version = rules_version,
        survivor_rows = combat_result.survivor_rows,
    }

    if RULE_ERROR_OUTCOMES[outcome] then
        run.result = recorded
        run.result_hash = result_hash.value
        run.state = PHASE.INVALID
        run.revision = run.revision + 1
        return result_ok({
            state = run.state,
            result_hash = run.result_hash,
            idempotent = false,
            terminal = true,
            wave_cleared = false,
            revision = run.revision,
        })
    end

    local is_victory = VICTORY_OUTCOMES[outcome] == true
    local has_more_waves = run.wave_index < run.wave_count

    if is_victory and has_more_waves then
        -- Intermediate wave clear: do not settle yet.
        run.pending_wave_clear = {
            wave_id = run.wave_id,
            wave_index = run.wave_index,
            combat_id = run.combat_id,
            result_hash = result_hash.value,
            result = recorded,
        }
        run.result_hash = result_hash.value
        run.state = PHASE.WAVE_CLEARED
        run.revision = run.revision + 1
        append_wave_event(run, 'WaveCleared', {
            wave_id = run.wave_id,
            wave_index = run.wave_index,
            combat_id = run.combat_id,
            result_hash = result_hash.value,
        })
        return result_ok({
            state = run.state,
            result_hash = result_hash.value,
            idempotent = false,
            terminal = false,
            wave_cleared = true,
            wave_index = run.wave_index,
            next_wave_index = run.wave_index + 1,
            has_more_waves = true,
            revision = run.revision,
        })
    end

    -- Final wave victory or any failure: terminal encounter result.
    run.result = recorded
    run.result_hash = result_hash.value
    run.state = PHASE.RESULT_PENDING
    run.revision = run.revision + 1
    if is_victory then
        append_wave_event(run, 'WaveCleared', {
            wave_id = run.wave_id,
            wave_index = run.wave_index,
            combat_id = run.combat_id,
            result_hash = result_hash.value,
        })
        run.cleared_wave_ids[#run.cleared_wave_ids + 1] = run.wave_id
    end

    return result_ok({
        state = run.state,
        result_hash = run.result_hash,
        idempotent = false,
        terminal = true,
        wave_cleared = is_victory,
        wave_index = run.wave_index,
        has_more_waves = false,
        revision = run.revision,
    })
end

--- Advance from WAVE_CLEARED to the next wave's ENTRY_COMMITTED snapshot.
function EncounterRun.advance_wave(run, catalog)
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end
    if type_value(catalog) ~= 'table'
        or type_value(catalog.require_wave) ~= 'function'
    then
        return invalid('CATALOG_REQUIRED')
    end
    if run.state ~= PHASE.WAVE_CLEARED then
        return phase_fail('WAVE_CLEARED_REQUIRED', { state = run.state })
    end
    if run.pending_wave_clear == nil then
        return fail(
            EncounterErrorCodes.ENCOUNTER_WAVE_ADVANCE_INVALID,
            'PENDING_WAVE_CLEAR_REQUIRED'
        )
    end

    local cleared = run.pending_wave_clear
    local cleared_wave = catalog:require_wave(cleared.wave_id)
    if not cleared_wave.ok then
        return cleared_wave
    end

    local carried = WaveController.carry_attackers(
        run.attacker_members,
        cleared.result.survivor_rows,
        cleared_wave.value
    )
    if not carried.ok then
        return carried
    end

    local next_index = cleared.wave_index + 1
    if next_index > run.wave_count then
        return fail(
            EncounterErrorCodes.ENCOUNTER_WAVE_ADVANCE_INVALID,
            'NO_NEXT_WAVE',
            { wave_index = cleared.wave_index, wave_count = run.wave_count }
        )
    end

    local next_wave_id = run.wave_ids[next_index]
    local next_wave = catalog:require_wave(next_wave_id)
    if not next_wave.ok then
        return next_wave
    end

    local run_ctx = {
        catalog = catalog,
        run_id = run.run_id,
        encounter_id = run.encounter_id,
        rules_version = run.rules_version,
        combat_kind = run.combat_kind,
        environment_spec_id = run.environment_spec_id,
        control_policy = run.control_policy,
        action_limit = run.action_limit,
        event_budget = run.event_budget,
        root_seed = run.seed,
    }

    local wave_bundle = build_wave_snapshot(
        run_ctx,
        next_wave.value,
        carried.value.members,
        next_index
    )
    if not wave_bundle.ok then
        return wave_bundle
    end

    local boss_runtime = result_ok(nil)
    if run.boss_controller_id ~= nil then
        boss_runtime = build_boss_runtime_for_wave(
            catalog,
            {
                boss_controller_id = run.boss_controller_id,
            },
            run.run_id,
            next_wave.value
        )
        if not boss_runtime.ok then
            return boss_runtime
        end
    end

    run.cleared_wave_ids[#run.cleared_wave_ids + 1] = cleared.wave_id
    run.attacker_members = carried.value.members
    run.actor_vitals = carried.value.actor_vitals
    run.combat_id = wave_bundle.value.combat_id
    run.combat_snapshot = wave_bundle.value.snapshot
    run.boss_runtime = boss_runtime.value
    run.wave_id = wave_bundle.value.wave_id
    run.wave_index = next_index
    run.wave_seed = wave_bundle.value.wave_seed
    run.pending_wave_clear = nil
    run.result = nil
    run.result_hash = nil
    run.state = PHASE.ENTRY_COMMITTED
    run.revision = run.revision + 1

    append_wave_event(run, 'WaveStarted', {
        wave_id = run.wave_id,
        wave_index = run.wave_index,
        combat_id = run.combat_id,
    })

    return result_ok({
        state = run.state,
        combat_id = run.combat_id,
        snapshot = run.combat_snapshot,
        actor_vitals = copy_vitals_map(run.actor_vitals),
        wave_id = run.wave_id,
        wave_index = run.wave_index,
        between_wave_policy = carried.value.between_wave_policy,
        revision = run.revision,
    })
end

function EncounterRun.plan_settlement(run, settlement_receipt_id)
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end
    if run.state == PHASE.INVALID then
        return fail(
            EncounterErrorCodes.ENCOUNTER_NOT_SETTLEABLE,
            'RULE_ERROR_NO_NORMAL_REWARD'
        )
    end
    if run.state == PHASE.WAVE_CLEARED then
        return fail(
            EncounterErrorCodes.ENCOUNTER_NOT_SETTLEABLE,
            'WAVE_ADVANCE_REQUIRED'
        )
    end
    if run.state ~= PHASE.RESULT_PENDING and run.state ~= PHASE.SETTLING then
        return phase_fail('RESULT_PENDING_REQUIRED', { state = run.state })
    end
    local receipt_check = RuntimeId.validate_derived(
        settlement_receipt_id,
        'settlement_receipt_id'
    )
    if not receipt_check.ok then
        return invalid('SETTLEMENT_RECEIPT_INVALID')
    end

    if run.settlement_receipt_id ~= nil
        and run.settlement_receipt_id ~= settlement_receipt_id
    then
        return fail(
            EncounterErrorCodes.ENCOUNTER_RECEIPT_CONFLICT,
            'SETTLEMENT_RECEIPT_CONFLICT',
            {
                existing = run.settlement_receipt_id,
                incoming = settlement_receipt_id,
            }
        )
    end

    local outcome = run.result.outcome
    local is_victory = VICTORY_OUTCOMES[outcome] == true
    local is_first_clear = is_victory and not run.first_clear_already
    -- Settlement reward priority (documented for consumers):
    -- 1. loot_table_id (first_clear / repeat) if non-nil → prepare_loot path
    -- 2. else reward_bundle_id if non-nil → prepare_reward path
    -- 3. both nil → no grant (grants_normal_reward = false)
    -- Loot must not silently fall back to bundle when economy lacks prepare_loot.
    local reward_bundle_id = nil
    local loot_table_id = nil
    if is_victory then
        if is_first_clear then
            loot_table_id = run.first_clear_loot_table_id
            reward_bundle_id = run.first_clear_reward_bundle_id
        else
            loot_table_id = run.repeat_loot_table_id
            reward_bundle_id = run.repeat_reward_bundle_id
        end
    end
    local has_loot = loot_table_id ~= nil
    local has_bundle = reward_bundle_id ~= nil

    local plan = {
        run_id = run.run_id,
        encounter_id = run.encounter_id,
        settlement_receipt_id = settlement_receipt_id,
        outcome = outcome,
        is_victory = is_victory,
        is_first_clear = is_first_clear,
        loot_table_id = loot_table_id,
        reward_bundle_id = reward_bundle_id,
        -- Root seed for deterministic loot; always present on a prepared run.
        root_seed = run.seed,
        completion_fact_id = is_victory and run.completion_fact_id or nil,
        result_hash = run.result_hash,
        rules_version = run.rules_version,
        grants_normal_reward = is_victory and (has_loot or has_bundle),
        waves_cleared = #run.cleared_wave_ids,
        wave_count = run.wave_count,
    }

    run.settlement_receipt_id = settlement_receipt_id
    run.settlement_plan = plan
    run.state = PHASE.SETTLING
    run.revision = run.revision + 1

    return result_ok({
        plan = plan,
        revision = run.revision,
    })
end

function EncounterRun.complete_settlement(run, settlement_receipt_id)
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end
    if run.state == PHASE.COMPLETED then
        if run.settlement_receipt_id == settlement_receipt_id then
            return result_ok({
                state = run.state,
                plan = run.settlement_plan,
                idempotent = true,
            })
        end
        return fail(
            EncounterErrorCodes.ENCOUNTER_ALREADY_COMPLETED,
            'ALREADY_COMPLETED'
        )
    end
    if run.state ~= PHASE.SETTLING then
        return phase_fail('SETTLING_REQUIRED', { state = run.state })
    end
    if run.settlement_receipt_id ~= settlement_receipt_id then
        return fail(
            EncounterErrorCodes.ENCOUNTER_RECEIPT_CONFLICT,
            'SETTLEMENT_RECEIPT_MISMATCH'
        )
    end

    if run.settlement_plan.is_victory then
        run.state = PHASE.COMPLETED
    elseif run.result.outcome == 'ATTACKER_FORFEIT' then
        run.state = PHASE.ABANDONED
    else
        run.state = PHASE.FAILED
    end
    run.revision = run.revision + 1

    return result_ok({
        state = run.state,
        plan = run.settlement_plan,
        idempotent = false,
        revision = run.revision,
    })
end

function EncounterRun.abandon(run, reason)
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end
    if run.state ~= PHASE.ENTRY_COMMITTED
        and run.state ~= PHASE.COMBAT_ACTIVE
        and run.state ~= PHASE.WAVE_CLEARED
    then
        return phase_fail('ABANDON_PHASE_INVALID', { state = run.state })
    end
    run.result = {
        outcome = 'ATTACKER_FORFEIT',
        winner_side = 'DEFENDER',
        finish_reason = reason or 'ABANDONED',
        action_count = 0,
        event_hash = string_rep('0', 64),
        snapshot_hash = run.combat_snapshot.snapshot_hash,
        command_hash = string_rep('0', 64),
        rules_version = run.rules_version,
    }
    local result_hash = compute_result_hash(run.combat_id, run.result)
    if not result_hash.ok then
        return result_hash
    end
    run.result_hash = result_hash.value
    run.pending_wave_clear = nil
    run.state = PHASE.RESULT_PENDING
    run.revision = run.revision + 1
    return result_ok({
        state = run.state,
        result_hash = run.result_hash,
        revision = run.revision,
    })
end

function EncounterRun.get_public_view(run)
    if type_value(run) ~= 'table' or get_metatable(run) ~= nil then
        return invalid('RUN_REQUIRED')
    end
    return result_ok({
        run_id = run.run_id,
        encounter_id = run.encounter_id,
        state = run.state,
        rules_version = run.rules_version,
        start_receipt_id = run.start_receipt_id,
        party_snapshot_hash = run.party_snapshot_hash,
        seed = run.seed,
        combat_id = run.combat_id,
        wave_id = run.wave_id,
        wave_index = run.wave_index,
        wave_count = run.wave_count,
        wave_seed = run.wave_seed,
        cleared_wave_ids = copy_strings(run.cleared_wave_ids),
        wave_events = run.wave_events,
        actor_vitals = copy_vitals_map(run.actor_vitals),
        result_hash = run.result_hash,
        settlement_receipt_id = run.settlement_receipt_id,
        settlement_plan = run.settlement_plan,
        retry_count = run.retry_count,
        revision = run.revision,
        result = run.result,
    })
end

EncounterRun.PHASE = PHASE

return EncounterRun
