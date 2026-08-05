-- Pure domain membership and reputation rules for system 15 (faction).
-- No save, economy debit, or platform clock — only identity state machine.

local Ordered = require 'wzx.domain.common.ordered'
local Result = require 'wzx.domain.common.result'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local FactionErrorCodes = require 'wzx.domain.faction.error_codes'

local Membership = {}
local get_metatable = getmetatable
local is_dense_array = Ordered.is_dense_array
local math_floor = math.floor
local raw_get = rawget
local raw_next = next
local result_err = Result.err
local result_ok = Result.ok
local string_sub = string.sub
local type_value = type
local validate_content = RuntimeId.validate_content
local validate_derived = RuntimeId.validate_derived

local MAX_SAFE_INTEGER = 9007199254740991
local REPUTATION_MAX = 2147483647

local STATUS = {
    CANDIDATE = 'CANDIDATE',
    MEMBER = 'MEMBER',
    SUSPENDED = 'SUSPENDED',
    LEFT = 'LEFT',
}
Membership.STATUS = STATUS

local ACTIVE_STATUS = {
    CANDIDATE = true,
    MEMBER = true,
}

local SOURCE_TYPES = {
    QUEST = true,
    COMMISSION = true,
    STORY = true,
    ADMIN_RECOVERY = true,
}

local function fail(code, reason, details)
    details = details or {}
    details.reason = reason
    return result_err(
        code,
        'error.faction.' .. string.lower(code),
        false,
        details
    )
end

local function invalid(reason, details)
    return fail(FactionErrorCodes.FACTION_ARGUMENT_INVALID, reason, details)
end

local function is_safe_integer(value, minimum, maximum)
    if type_value(value) ~= 'number'
        or value ~= value
        or value == math.huge
        or value == -math.huge
        or value ~= math_floor(value)
    then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

local function ensure_session(session)
    if type_value(session) ~= 'table' or get_metatable(session) ~= nil then
        return invalid('SESSION_REQUIRED', { field = 'session' })
    end
    if type_value(raw_get(session, 'records')) ~= 'table'
        or get_metatable(session.records) ~= nil
    then
        return invalid('RECORDS_TABLE_REQUIRED', { field = 'session.records' })
    end
    if type_value(raw_get(session, 'receipt_index')) ~= 'table'
        or get_metatable(session.receipt_index) ~= nil
    then
        return invalid('RECEIPT_INDEX_REQUIRED', { field = 'session.receipt_index' })
    end
    if not is_safe_integer(raw_get(session, 'revision'), 0, MAX_SAFE_INTEGER) then
        return invalid('REVISION_INVALID', { field = 'session.revision' })
    end
    return result_ok(session)
end

local function check_faction_id(faction_id)
    local checked = validate_content(faction_id, 'faction_', 'faction_id')
    if not checked.ok then
        return invalid('FACTION_ID_INVALID', { field = 'faction_id' })
    end
    return result_ok(faction_id)
end

local function check_command_id(command_id, field_name)
    field_name = field_name or 'command_id'
    local checked = validate_derived(command_id, field_name)
    if not checked.ok then
        return invalid(string.upper(field_name) .. '_INVALID', { field = field_name })
    end
    return result_ok(command_id)
end

local function check_rank_id(rank_id, field_name)
    field_name = field_name or 'rank_id'
    local checked = validate_content(rank_id, nil, field_name)
    if not checked.ok then
        return invalid('RANK_ID_INVALID', { field = field_name })
    end
    return result_ok(rank_id)
end

--- Map faction_id → contribution currency id.
--- When faction_id is "faction_xxx", result is "currency_faction_xxx".
function Membership.contribution_currency_id_for(faction_id)
    if type_value(faction_id) ~= 'string' or faction_id == '' then
        return nil
    end
    if string_sub(faction_id, 1, 8) == 'faction_' then
        return 'currency_' .. faction_id
    end
    return 'currency_faction_' .. faction_id
end

function Membership.empty_session()
    return {
        active_faction_id = nil,
        records = {},
        receipt_index = {},
        revision = 0,
    }
end

local function copy_record(record)
    if record == nil then
        return nil
    end
    return {
        faction_id = record.faction_id,
        status = record.status,
        rank_id = record.rank_id,
        reputation = record.reputation,
        contribution_currency_id = record.contribution_currency_id,
        joined_at = record.joined_at,
        promoted = record.promoted == true,
        membership_revision = record.membership_revision or 0,
    }
end

local function find_active_record(session)
    local active_id = raw_get(session, 'active_faction_id')
    if type_value(active_id) == 'string' and active_id ~= '' then
        local record = session.records[active_id]
        if record ~= nil and ACTIVE_STATUS[record.status] == true then
            return record
        end
    end
    local faction_id
    local record
    for faction_id, record in raw_next, session.records do
        if ACTIVE_STATUS[record.status] == true then
            return record
        end
    end
    return nil
end

local function store_command_receipt(session, command_id, kind, payload)
    session.receipt_index[command_id] = {
        kind = kind,
        faction_id = payload.faction_id,
        rank_id = payload.rank_id,
        reputation = payload.reputation,
        joined_at = payload.joined_at,
        status = payload.status,
        resulting_revision = session.revision,
        receipt_id = payload.receipt_id,
        reputation_delta = payload.reputation_delta,
        source_type = payload.source_type,
        source_id = payload.source_id,
    }
end

local function replay_payload_from_receipt(prior)
    return {
        faction_id = prior.faction_id,
        status = prior.status,
        rank_id = prior.rank_id,
        reputation = prior.reputation,
        joined_at = prior.joined_at,
        resulting_revision = prior.resulting_revision,
        command_replay = true,
        receipt_replay = prior.receipt_id ~= nil,
        receipt_id = prior.receipt_id,
        reputation_delta = prior.reputation_delta,
        source_type = prior.source_type,
        source_id = prior.source_id,
        promoted = prior.status == STATUS.MEMBER and prior.rank_id ~= nil,
    }
end

local function ensure_command_fresh(session, command_id, expected_kind, faction_id)
    local prior = session.receipt_index[command_id]
    if prior == nil then
        return nil
    end
    if prior.kind ~= expected_kind or prior.faction_id ~= faction_id then
        return fail(
            FactionErrorCodes.FACTION_COMMAND_CONFLICT,
            'COMMAND_ID_REUSED',
            {
                command_id = command_id,
                expected_kind = expected_kind,
                prior_kind = prior.kind,
                faction_id = faction_id,
                prior_faction_id = prior.faction_id,
            }
        )
    end
    return result_ok(replay_payload_from_receipt(prior))
end

local function ensure_receipt_fresh(session, receipt_id, expected_kind, faction_id)
    local prior = session.receipt_index[receipt_id]
    if prior == nil then
        return nil
    end
    if prior.kind ~= expected_kind or prior.faction_id ~= faction_id then
        return fail(
            FactionErrorCodes.FACTION_RECEIPT_CONFLICT,
            'RECEIPT_ID_REUSED',
            {
                receipt_id = receipt_id,
                expected_kind = expected_kind,
                prior_kind = prior.kind,
                faction_id = faction_id,
                prior_faction_id = prior.faction_id,
            }
        )
    end
    local payload = replay_payload_from_receipt(prior)
    payload.receipt_replay = true
    payload.command_replay = false
    return result_ok(payload)
end

--- Begin candidacy for a faction. V1: only one active identity at a time.
function Membership.begin_candidacy(session, faction_id, command_id)
    local session_ok = ensure_session(session)
    if not session_ok.ok then
        return session_ok
    end
    local faction_ok = check_faction_id(faction_id)
    if not faction_ok.ok then
        return faction_ok
    end
    local command_ok = check_command_id(command_id, 'command_id')
    if not command_ok.ok then
        return command_ok
    end

    local replay = ensure_command_fresh(session, command_id, 'BEGIN_CANDIDACY', faction_id)
    if replay ~= nil then
        return replay
    end

    local existing = session.records[faction_id]
    if existing ~= nil then
        if existing.status == STATUS.MEMBER then
            return fail(
                FactionErrorCodes.FACTION_ALREADY_JOINED,
                'ALREADY_MEMBER',
                { faction_id = faction_id, status = existing.status }
            )
        end
        if existing.status == STATUS.CANDIDATE then
            return fail(
                FactionErrorCodes.FACTION_ALREADY_JOINED,
                'ALREADY_CANDIDATE',
                { faction_id = faction_id, status = existing.status }
            )
        end
        if existing.status == STATUS.SUSPENDED then
            return fail(
                FactionErrorCodes.FACTION_STATUS_INVALID,
                'SUSPENDED_BLOCKS_CANDIDACY',
                { faction_id = faction_id, status = existing.status }
            )
        end
        -- LEFT history is retained but does not auto-restore; V1 blocks re-entry.
        if existing.status == STATUS.LEFT then
            return fail(
                FactionErrorCodes.FACTION_STATUS_INVALID,
                'LEFT_BLOCKS_CANDIDACY',
                { faction_id = faction_id, status = existing.status }
            )
        end
    end

    local active = find_active_record(session)
    if active ~= nil and active.faction_id ~= faction_id then
        return fail(
            FactionErrorCodes.FACTION_ALREADY_JOINED,
            'OTHER_ACTIVE_IDENTITY',
            {
                active_faction_id = active.faction_id,
                active_status = active.status,
                requested_faction_id = faction_id,
            }
        )
    end

    local record = {
        faction_id = faction_id,
        status = STATUS.CANDIDATE,
        rank_id = nil,
        reputation = 0,
        contribution_currency_id = nil,
        joined_at = nil,
        promoted = false,
        membership_revision = 1,
    }
    session.records[faction_id] = record
    session.active_faction_id = faction_id
    session.revision = session.revision + 1
    store_command_receipt(session, command_id, 'BEGIN_CANDIDACY', {
        faction_id = faction_id,
        status = STATUS.CANDIDATE,
        rank_id = nil,
        reputation = 0,
        joined_at = nil,
    })

    return result_ok({
        faction_id = faction_id,
        status = STATUS.CANDIDATE,
        record = copy_record(record),
        resulting_revision = session.revision,
        command_replay = false,
    })
end

--- CANDIDATE → MEMBER. Requires an existing candidacy for faction_id.
function Membership.join_faction(session, faction_id, command_id, joined_at, initial_rank_id)
    local session_ok = ensure_session(session)
    if not session_ok.ok then
        return session_ok
    end
    local faction_ok = check_faction_id(faction_id)
    if not faction_ok.ok then
        return faction_ok
    end
    local command_ok = check_command_id(command_id, 'command_id')
    if not command_ok.ok then
        return command_ok
    end
    if not is_safe_integer(joined_at, 0, MAX_SAFE_INTEGER) then
        return invalid('JOINED_AT_INVALID', { field = 'joined_at' })
    end
    local rank_ok = check_rank_id(initial_rank_id, 'initial_rank_id')
    if not rank_ok.ok then
        return rank_ok
    end

    local replay = ensure_command_fresh(session, command_id, 'JOIN_FACTION', faction_id)
    if replay ~= nil then
        if replay.ok then
            local prior = session.receipt_index[command_id]
            local record = session.records[faction_id]
            return result_ok({
                faction_id = faction_id,
                status = STATUS.MEMBER,
                rank_id = prior.rank_id,
                reputation = prior.reputation or 0,
                contribution_currency_id = Membership.contribution_currency_id_for(faction_id),
                joined_at = prior.joined_at,
                record = copy_record(record),
                resulting_revision = prior.resulting_revision,
                command_replay = true,
            })
        end
        return replay
    end

    local record = session.records[faction_id]
    if record == nil or record.status ~= STATUS.CANDIDATE then
        return fail(
            FactionErrorCodes.FACTION_NOT_CANDIDATE,
            'CANDIDACY_REQUIRED',
            {
                faction_id = faction_id,
                status = record and record.status or nil,
            }
        )
    end

    local active = find_active_record(session)
    if active ~= nil and active.faction_id ~= faction_id then
        return fail(
            FactionErrorCodes.FACTION_ALREADY_JOINED,
            'OTHER_ACTIVE_IDENTITY',
            {
                active_faction_id = active.faction_id,
                requested_faction_id = faction_id,
            }
        )
    end

    local currency_id = Membership.contribution_currency_id_for(faction_id)
    record.status = STATUS.MEMBER
    record.rank_id = initial_rank_id
    record.reputation = 0
    record.contribution_currency_id = currency_id
    record.joined_at = joined_at
    record.promoted = false
    record.membership_revision = (record.membership_revision or 0) + 1
    session.active_faction_id = faction_id
    session.revision = session.revision + 1
    store_command_receipt(session, command_id, 'JOIN_FACTION', {
        faction_id = faction_id,
        status = STATUS.MEMBER,
        rank_id = initial_rank_id,
        reputation = 0,
        joined_at = joined_at,
    })

    return result_ok({
        faction_id = faction_id,
        status = STATUS.MEMBER,
        rank_id = initial_rank_id,
        reputation = 0,
        contribution_currency_id = currency_id,
        joined_at = joined_at,
        record = copy_record(record),
        resulting_revision = session.revision,
        command_replay = false,
    })
end

--- Reputation is permanent progress: only increases, member-only, receipt-idempotent.
function Membership.grant_reputation(
    session,
    faction_id,
    receipt_id,
    source_type,
    source_id,
    reputation_delta
)
    local session_ok = ensure_session(session)
    if not session_ok.ok then
        return session_ok
    end
    local faction_ok = check_faction_id(faction_id)
    if not faction_ok.ok then
        return faction_ok
    end
    local receipt_ok = check_command_id(receipt_id, 'receipt_id')
    if not receipt_ok.ok then
        return receipt_ok
    end
    if SOURCE_TYPES[source_type] ~= true then
        return invalid('SOURCE_TYPE_INVALID', { field = 'source_type', source_type = source_type })
    end
    local source_checked = validate_derived(source_id, 'source_id')
    if not source_checked.ok then
        -- allow content-style source ids as well
        source_checked = validate_content(source_id, nil, 'source_id')
        if not source_checked.ok then
            return invalid('SOURCE_ID_INVALID', { field = 'source_id' })
        end
    end
    if not is_safe_integer(reputation_delta, 1, REPUTATION_MAX) then
        return invalid('REPUTATION_DELTA_INVALID', {
            field = 'reputation_delta',
            reputation_delta = reputation_delta,
        })
    end

    local replay = ensure_receipt_fresh(session, receipt_id, 'GRANT_REPUTATION', faction_id)
    if replay ~= nil then
        if replay.ok then
            local prior = session.receipt_index[receipt_id]
            local record = session.records[faction_id]
            return result_ok({
                faction_id = faction_id,
                receipt_id = receipt_id,
                source_type = prior.source_type,
                source_id = prior.source_id,
                reputation_delta = prior.reputation_delta,
                reputation = prior.reputation,
                resulting_revision = prior.resulting_revision,
                record = copy_record(record),
                receipt_replay = true,
            })
        end
        return replay
    end

    local record = session.records[faction_id]
    if record == nil then
        return fail(
            FactionErrorCodes.FACTION_NOT_FOUND,
            'FACTION_RECORD_MISSING',
            { faction_id = faction_id }
        )
    end
    if record.status ~= STATUS.MEMBER then
        return fail(
            FactionErrorCodes.FACTION_NOT_MEMBER,
            'MEMBER_REQUIRED',
            { faction_id = faction_id, status = record.status }
        )
    end

    local current = record.reputation or 0
    if current > REPUTATION_MAX - reputation_delta then
        return fail(
            FactionErrorCodes.FACTION_VALUE_OVERFLOW,
            'REPUTATION_OVERFLOW',
            {
                faction_id = faction_id,
                reputation = current,
                reputation_delta = reputation_delta,
                max = REPUTATION_MAX,
            }
        )
    end

    local next_reputation = current + reputation_delta
    record.reputation = next_reputation
    record.membership_revision = (record.membership_revision or 0) + 1
    session.revision = session.revision + 1
    store_command_receipt(session, receipt_id, 'GRANT_REPUTATION', {
        faction_id = faction_id,
        status = STATUS.MEMBER,
        rank_id = record.rank_id,
        reputation = next_reputation,
        joined_at = record.joined_at,
        receipt_id = receipt_id,
        reputation_delta = reputation_delta,
        source_type = source_type,
        source_id = source_id,
    })

    return result_ok({
        faction_id = faction_id,
        receipt_id = receipt_id,
        source_type = source_type,
        source_id = source_id,
        reputation_delta = reputation_delta,
        reputation = next_reputation,
        resulting_revision = session.revision,
        record = copy_record(record),
        receipt_replay = false,
    })
end

local function index_ranks(ranks_config)
    if type_value(ranks_config) ~= 'table'
        or get_metatable(ranks_config) ~= nil
        or not is_dense_array(ranks_config)
        or #ranks_config < 1
    then
        return invalid('RANKS_CONFIG_REQUIRED', { field = 'ranks_config' })
    end

    local by_id = {}
    local by_order = {}
    local index
    for index = 1, #ranks_config do
        local row = ranks_config[index]
        if type_value(row) ~= 'table' or get_metatable(row) ~= nil then
            return invalid('RANK_ROW_REQUIRED', {
                field = 'ranks_config[' .. tostring(index) .. ']',
            })
        end
        local rank_id = raw_get(row, 'rank_id')
        local order = raw_get(row, 'order')
        local min_reputation = raw_get(row, 'min_reputation')
        local rank_ok = check_rank_id(rank_id, 'ranks_config[' .. tostring(index) .. '].rank_id')
        if not rank_ok.ok then
            return rank_ok
        end
        if not is_safe_integer(order, 1, MAX_SAFE_INTEGER) then
            return invalid('RANK_ORDER_INVALID', {
                field = 'ranks_config[' .. tostring(index) .. '].order',
            })
        end
        if not is_safe_integer(min_reputation, 0, REPUTATION_MAX) then
            return invalid('RANK_MIN_REPUTATION_INVALID', {
                field = 'ranks_config[' .. tostring(index) .. '].min_reputation',
            })
        end
        if by_id[rank_id] ~= nil then
            return invalid('RANK_ID_DUPLICATE', { rank_id = rank_id })
        end
        if by_order[order] ~= nil then
            return invalid('RANK_ORDER_DUPLICATE', { order = order })
        end
        local entry = {
            rank_id = rank_id,
            order = order,
            min_reputation = min_reputation,
        }
        by_id[rank_id] = entry
        by_order[order] = entry
    end
    return result_ok({ by_id = by_id, by_order = by_order })
end

--- Read-only promotion eligibility: MEMBER, target is current order+1, reputation met.
function Membership.can_promote(session, faction_id, ranks_config, target_rank_id)
    local session_ok = ensure_session(session)
    if not session_ok.ok then
        return session_ok
    end
    local faction_ok = check_faction_id(faction_id)
    if not faction_ok.ok then
        return faction_ok
    end
    local target_ok = check_rank_id(target_rank_id, 'target_rank_id')
    if not target_ok.ok then
        return target_ok
    end
    local ranks = index_ranks(ranks_config)
    if not ranks.ok then
        return ranks
    end

    local record = session.records[faction_id]
    if record == nil then
        return fail(
            FactionErrorCodes.FACTION_NOT_FOUND,
            'FACTION_RECORD_MISSING',
            { faction_id = faction_id }
        )
    end
    if record.status ~= STATUS.MEMBER then
        return fail(
            FactionErrorCodes.FACTION_NOT_MEMBER,
            'MEMBER_REQUIRED',
            { faction_id = faction_id, status = record.status }
        )
    end
    if type_value(record.rank_id) ~= 'string' or record.rank_id == '' then
        return fail(
            FactionErrorCodes.FACTION_PROMOTION_NOT_READY,
            'CURRENT_RANK_MISSING',
            { faction_id = faction_id }
        )
    end

    local current = ranks.value.by_id[record.rank_id]
    if current == nil then
        return fail(
            FactionErrorCodes.FACTION_PROMOTION_NOT_READY,
            'CURRENT_RANK_UNKNOWN',
            { faction_id = faction_id, rank_id = record.rank_id }
        )
    end
    local target = ranks.value.by_id[target_rank_id]
    if target == nil then
        return fail(
            FactionErrorCodes.FACTION_PROMOTION_NOT_READY,
            'TARGET_RANK_UNKNOWN',
            { faction_id = faction_id, target_rank_id = target_rank_id }
        )
    end
    if target.order ~= current.order + 1 then
        return fail(
            FactionErrorCodes.FACTION_PROMOTION_NOT_READY,
            'TARGET_NOT_NEXT_ORDER',
            {
                faction_id = faction_id,
                current_order = current.order,
                target_order = target.order,
                expected_order = current.order + 1,
            }
        )
    end
    local reputation = record.reputation or 0
    if reputation < target.min_reputation then
        return fail(
            FactionErrorCodes.FACTION_PROMOTION_NOT_READY,
            'REPUTATION_BELOW_THRESHOLD',
            {
                faction_id = faction_id,
                reputation = reputation,
                min_reputation = target.min_reputation,
                target_rank_id = target_rank_id,
            }
        )
    end

    return result_ok({
        faction_id = faction_id,
        current_rank_id = current.rank_id,
        current_order = current.order,
        target_rank_id = target.rank_id,
        target_order = target.order,
        reputation = reputation,
        min_reputation = target.min_reputation,
        ready = true,
    })
end

function Membership.promote(session, faction_id, command_id, target_rank_id, ranks_config)
    local session_ok = ensure_session(session)
    if not session_ok.ok then
        return session_ok
    end
    local faction_ok = check_faction_id(faction_id)
    if not faction_ok.ok then
        return faction_ok
    end
    local command_ok = check_command_id(command_id, 'command_id')
    if not command_ok.ok then
        return command_ok
    end
    local target_ok = check_rank_id(target_rank_id, 'target_rank_id')
    if not target_ok.ok then
        return target_ok
    end

    local replay = ensure_command_fresh(session, command_id, 'PROMOTE', faction_id)
    if replay ~= nil then
        if replay.ok then
            local prior = session.receipt_index[command_id]
            if prior.rank_id ~= target_rank_id then
                return fail(
                    FactionErrorCodes.FACTION_COMMAND_CONFLICT,
                    'PROMOTE_TARGET_MISMATCH',
                    {
                        command_id = command_id,
                        target_rank_id = target_rank_id,
                        prior_rank_id = prior.rank_id,
                    }
                )
            end
            local record = session.records[faction_id]
            return result_ok({
                faction_id = faction_id,
                from_rank_id = prior.from_rank_id,
                to_rank_id = prior.rank_id,
                rank_id = prior.rank_id,
                reputation = prior.reputation,
                promoted = true,
                record = copy_record(record),
                resulting_revision = prior.resulting_revision,
                command_replay = true,
            })
        end
        return replay
    end

    local eligibility = Membership.can_promote(session, faction_id, ranks_config, target_rank_id)
    if not eligibility.ok then
        return eligibility
    end

    local record = session.records[faction_id]
    local from_rank_id = record.rank_id
    record.rank_id = target_rank_id
    record.promoted = true
    record.membership_revision = (record.membership_revision or 0) + 1
    session.revision = session.revision + 1

    local receipt = {
        kind = 'PROMOTE',
        faction_id = faction_id,
        rank_id = target_rank_id,
        from_rank_id = from_rank_id,
        reputation = record.reputation,
        joined_at = record.joined_at,
        status = STATUS.MEMBER,
        resulting_revision = session.revision,
    }
    session.receipt_index[command_id] = receipt

    return result_ok({
        faction_id = faction_id,
        from_rank_id = from_rank_id,
        to_rank_id = target_rank_id,
        rank_id = target_rank_id,
        reputation = record.reputation,
        promoted = true,
        record = copy_record(record),
        resulting_revision = session.revision,
        command_replay = false,
    })
end

--- Read-only membership summary. Optional faction_id filters to one record.
function Membership.query(session, faction_id)
    local session_ok = ensure_session(session)
    if not session_ok.ok then
        return session_ok
    end

    if faction_id ~= nil then
        local faction_ok = check_faction_id(faction_id)
        if not faction_ok.ok then
            return faction_ok
        end
        local record = session.records[faction_id]
        if record == nil then
            return fail(
                FactionErrorCodes.FACTION_NOT_FOUND,
                'FACTION_RECORD_MISSING',
                { faction_id = faction_id }
            )
        end
        return result_ok({
            revision = session.revision,
            active_faction_id = session.active_faction_id,
            faction_id = faction_id,
            membership = copy_record(record),
        })
    end

    local active = find_active_record(session)
    return result_ok({
        revision = session.revision,
        active_faction_id = session.active_faction_id,
        membership = copy_record(active),
        faction_id = active and active.faction_id or nil,
    })
end

return Membership
