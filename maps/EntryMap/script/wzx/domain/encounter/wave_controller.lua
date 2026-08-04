-- Wave clear / between-wave carry helpers for system 07 multi-wave runs.
-- Sequential sub-combats model: each wave is one CombatAggregate session.

local Result = require 'wzx.domain.common.result'
local EncounterErrorCodes = require 'wzx.domain.encounter.error_codes'

local WaveController = {}
local get_metatable = getmetatable
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local raw_get = rawget
local result_err = Result.err
local result_ok = Result.ok
local type_value = type

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

local function index_survivors(survivor_rows)
    local by_id = {}
    if type_value(survivor_rows) ~= 'table' or get_metatable(survivor_rows) ~= nil then
        return by_id
    end
    local index
    for index = 1, #survivor_rows do
        local row = survivor_rows[index]
        if type_value(row) == 'table' and type_value(row.actor_id) == 'string' then
            by_id[row.actor_id] = row
        end
    end
    return by_id
end

--- Apply between-wave policy to a carried vitals pair.
-- policy from the wave that was just cleared.
function WaveController.apply_between_wave_policy(vitals, max_hp, max_qi, initial_qi, policy, policy_value)
    local hp = vitals.current_hp
    local qi = vitals.current_qi
    if policy == 'RESET_QI' then
        qi = initial_qi
    elseif policy == 'HEAL_PERCENT' then
        local percent = policy_value or 0
        if type_value(percent) ~= 'number' then
            percent = 0
        end
        local heal = math_floor(max_hp * percent / 10000)
        hp = math_min(max_hp, hp + heal)
    elseif policy == 'CUSTOM_EFFECT' then
        -- V1: no custom effect executor; treat as CONTINUE_STATE.
    end
    -- CONTINUE_STATE and default: keep hp/qi.
    if hp < 0 then
        hp = 0
    end
    if hp > max_hp then
        hp = max_hp
    end
    if qi < 0 then
        qi = 0
    end
    if qi > max_qi then
        qi = max_qi
    end
    return {
        current_hp = hp,
        current_qi = qi,
    }
end

--- Build next-wave attacker formation + vitals from previous combat survivors.
-- Only ALIVE attackers carry forward; positions preserved.
-- @return Result { members, actor_vitals, cleared_wave_index }
function WaveController.carry_attackers(attacker_members, survivor_rows, cleared_wave)
    if type_value(attacker_members) ~= 'table' or get_metatable(attacker_members) ~= nil then
        return fail(
            EncounterErrorCodes.ENCOUNTER_ARGUMENT_INVALID,
            'ATTACKER_MEMBERS_REQUIRED'
        )
    end
    local survivors = index_survivors(survivor_rows)
    local policy = 'CONTINUE_STATE'
    local policy_value = nil
    if type_value(cleared_wave) == 'table' then
        policy = raw_get(cleared_wave, 'between_wave_policy') or 'CONTINUE_STATE'
        policy_value = raw_get(cleared_wave, 'between_wave_value')
    end

    local carried = {}
    local vitals = {}
    local index
    for index = 1, #attacker_members do
        local member = attacker_members[index]
        local row = survivors[member.actor_id]
        if row ~= nil and row.side == 'ATTACKER' and row.alive_state == 'ALIVE' then
            local hp = row.current_hp
            local qi = row.current_qi
            if type_value(hp) ~= 'number' then
                hp = member.stats.max_hp
            end
            if type_value(qi) ~= 'number' then
                qi = member.stats.initial_qi
            end
            if hp > 0 then
                local applied = WaveController.apply_between_wave_policy(
                    { current_hp = hp, current_qi = qi },
                    member.stats.max_hp,
                    member.stats.max_qi,
                    member.stats.initial_qi,
                    policy,
                    policy_value
                )
                if applied.current_hp > 0 then
                    carried[#carried + 1] = copy_member(member)
                    vitals[member.actor_id] = applied
                end
            end
        end
    end

    if #carried < 1 then
        return fail(
            EncounterErrorCodes.ENCOUNTER_NO_SURVIVING_ATTACKERS,
            'NO_SURVIVING_ATTACKERS'
        )
    end

    return result_ok({
        members = carried,
        actor_vitals = vitals,
        between_wave_policy = policy,
    })
end

--- Index victory-relevant spawn ids for a wave (counts_for_victory).
function WaveController.victory_spawn_ids(wave)
    local ids = {}
    if type_value(wave) ~= 'table' or type_value(wave.spawn_rows) ~= 'table' then
        return ids
    end
    local index
    for index = 1, #wave.spawn_rows do
        local row = wave.spawn_rows[index]
        if row.counts_for_victory ~= false then
            ids[row.spawn_id] = true
        end
    end
    return ids
end

return WaveController
