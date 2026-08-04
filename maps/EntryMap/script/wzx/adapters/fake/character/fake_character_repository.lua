local CharacterRepository = require 'wzx.application.ports.character_repository'
local PortContract = require 'wzx.application.ports.port_contract'
local ScriptedPort = require 'wzx.adapters.fake.scripted_port'
local SerializableSnapshot = require 'wzx.adapters.fake.serializable_snapshot'

local FakeCharacterRepository = {}

local MAX_SAFE_INTEGER = PortContract.MAX_SAFE_INTEGER
local fingerprint_request = SerializableSnapshot.fingerprint_request
local raw_next = next

local FAULT_MODES = {
    COMMIT_THEN_UNKNOWN = true,
    COMMIT_THEN_UNKNOWN_LATE_SUCCESS = true,
    COMMIT_THEN_UNAVAILABLE = true,
    COMMIT_THEN_WRONG_REQUEST_KEY = true,
    COMMIT_THEN_MALFORMED = true,
    COMMIT_THEN_DUPLICATE_SUCCESS = true,
    RECOVERY_REQUIRED_THEN_UNKNOWN = true,
}

local COMPLETION_GATE_FAULT_MODES = {
    COMMIT_THEN_WRONG_REQUEST_KEY = true,
    COMMIT_THEN_MALFORMED = true,
}

local UNRESOLVED_STATES = {
    PREPARING = true,
    PREPARED = true,
    APPLYING = true,
    RECOVERY_REQUIRED = true,
}

local function assert_plain_tree(value, path, depth, active, seen)
    local value_type = type(value)
    if value_type == 'string'
        or value_type == 'boolean'
        or value_type == 'number'
    then
        return
    end
    if value_type ~= 'table' then
        error(path .. ' must contain only serializable values', 3)
    end
    if getmetatable(value) ~= nil then
        error(path .. ' must not have a metatable', 3)
    end
    depth = depth or 1
    if depth > SerializableSnapshot.MAX_TABLE_DEPTH then
        error(path .. ' exceeds the maximum table depth', 3)
    end
    active = active or {}
    seen = seen or {}
    if active[value] then
        error(path .. ' must not contain a table cycle', 3)
    end
    if seen[value] then
        error(path .. ' must not contain shared table references', 3)
    end
    seen[value] = true
    active[value] = true
    local key
    local child
    key = raw_next(value, nil)
    while key ~= nil do
        if type(key) ~= 'string'
            and (type(key) ~= 'number'
                or key ~= math.floor(key)
                or key < 1)
        then
            active[value] = nil
            error(path .. ' contains an invalid table key', 3)
        end
        child = rawget(value, key)
        assert_plain_tree(
            child,
            path .. '.' .. tostring(key),
            depth + 1,
            active,
            seen
        )
        key = raw_next(value, key)
    end
    active[value] = nil
end

local function assert_exact_keys(value, allowed, path)
    local key = raw_next(value, nil)
    while key ~= nil do
        if type(key) ~= 'string' or not allowed[key] then
            error(path .. ' contains unknown field ' .. tostring(key), 3)
        end
        key = raw_next(value, key)
    end
end

local function copy_or_error(value, path)
    assert_plain_tree(value, path)
    local copied = SerializableSnapshot.deep_copy(value, path)
    if not copied.ok then
        error(
            'FakeCharacterRepository snapshot failed: '
                .. tostring(copied.error.code),
            3
        )
    end
    return copied.value
end

local function is_non_negative_integer(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math.floor(value)
        and value >= 0
        and value <= MAX_SAFE_INTEGER
end

local function dense_array(value)
    if type(value) ~= 'table' then
        return false
    end
    local count = 0
    local maximum = 0
    local key = raw_next(value, nil)
    while key ~= nil do
        if type(key) ~= 'number'
            or key ~= math.floor(key)
            or key < 1
        then
            return false
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
        key = raw_next(value, key)
    end
    return count == maximum
end

local function values_equal(left, right, visited)
    if left == right then
        return true
    end
    if type(left) ~= type(right) or type(left) ~= 'table' then
        return false
    end
    visited = visited or {}
    visited[left] = visited[left] or {}
    if visited[left][right] then
        return true
    end
    visited[left][right] = true

    local key = raw_next(left, nil)
    while key ~= nil do
        if not values_equal(left[key], right[key], visited) then
            return false
        end
        key = raw_next(left, key)
    end
    key = raw_next(right, nil)
    while key ~= nil do
        if left[key] == nil and right[key] ~= nil then
            return false
        end
        key = raw_next(right, key)
    end
    return true
end

local function request_digest(request)
    return request.command_digest
end

local function request_transaction_id(request)
    return request.transaction_id
end

local function expected_character_save_revision(request)
    return request.expected_character_save_revision
end

local function character_id_from_request(request)
    if type(request.command) == 'table' then
        return request.command.character_id
    end
    if type(request.after_state) == 'table' then
        return request.after_state.character_id
    end
    if type(request.before_state) == 'table' then
        return request.before_state.character_id
    end
    return nil
end

local function typed_identity_candidates(request)
    local candidates = {
        {
            category = 'RECEIPT',
            value = request.receipt_id,
        },
        {
            category = 'TRANSACTION',
            value = request.transaction_id,
        },
        {
            category = 'TRANSPORT',
            value = request.context.idempotency_key,
        },
        {
            category = 'DIGEST',
            value = request.command_digest,
        },
        {
            category = 'DIGEST',
            value = request.result_digest,
        },
    }
    if request.operation_type == 'GRANT_CHARACTER_EXPERIENCE' then
        candidates[#candidates + 1] = {
            category = 'DIGEST',
            value = request.command.reward_plan_digest,
        }
        candidates[#candidates + 1] = {
            category = 'DIGEST',
            value = request.result.reward_result_digest,
        }
    end
    if request.operation_type == 'GRANT_CHARACTER_EXPERIENCE'
        and request.result.reward_status == 'COMMITTED'
    then
        candidates[#candidates + 1] = {
            category = 'RECEIPT',
            value = request.result.reward_receipt_id,
        }
    end
    if request.operation_type ~= 'CREATE_OWNED_CHARACTER' then
        candidates[#candidates + 1] = {
            category = 'RECEIPT',
            value = request.command.created_receipt_id,
        }
    end
    return candidates
end

local function query_identity_candidates(request)
    local candidates = {
        {
            category = 'RECEIPT',
            value = request.receipt_id,
        },
        {
            category = 'TRANSACTION',
            value = request.transaction_id,
        },
        {
            category = 'TRANSPORT',
            value = request.original_request_key,
        },
        {
            category = 'DIGEST',
            value = request.command_digest,
        },
        {
            category = 'DIGEST',
            value = request.expected_result_digest,
        },
    }
    if request.operation_type == 'GRANT_CHARACTER_EXPERIENCE' then
        candidates[#candidates + 1] = {
            category = 'DIGEST',
            value = request.command.reward_plan_digest,
        }
    end
    if request.operation_type ~= 'CREATE_OWNED_CHARACTER' then
        candidates[#candidates + 1] = {
            category = 'RECEIPT',
            value = request.command.created_receipt_id,
        }
    end
    return candidates
end

local function typed_identity_history(history, category)
    if category == 'RECEIPT' then
        return history.receipts
    end
    if category == 'TRANSACTION' then
        return history.transactions
    end
    if category == 'TRANSPORT' then
        return history.transports
    end
    if category == 'DIGEST' then
        return history.digests
    end
    error('unsupported FakeCharacterRepository identity category')
end

local function new_typed_identity_history()
    return {
        receipts = {},
        transactions = {},
        transports = {},
        digests = {},
    }
end

local function scoped_typed_identity_history(histories, player_save_scope)
    local history = histories[player_save_scope]
    if history == nil then
        history = new_typed_identity_history()
        histories[player_save_scope] = history
    end
    return history
end

local function has_cross_typed_identity_collision(history, candidates)
    local index
    local other_index
    local candidate
    for index = 1, #candidates do
        candidate = candidates[index]
        if candidate.category ~= 'RECEIPT'
            and history.receipts[candidate.value]
        then
            return true
        end
        if candidate.category ~= 'TRANSACTION'
            and history.transactions[candidate.value]
        then
            return true
        end
        if candidate.category ~= 'TRANSPORT'
            and history.transports[candidate.value]
        then
            return true
        end
        if candidate.category ~= 'DIGEST'
            and history.digests[candidate.value]
        then
            return true
        end
        for other_index = index + 1, #candidates do
            if candidate.category ~= candidates[other_index].category
                and candidate.value == candidates[other_index].value
            then
                return true
            end
        end
    end
    return false
end

local function register_typed_identities(history, candidates)
    local added = {}
    local index
    for index = 1, #candidates do
        local candidate = candidates[index]
        local category_history = typed_identity_history(
            history,
            candidate.category
        )
        if not category_history[candidate.value] then
            category_history[candidate.value] = true
            added[#added + 1] = candidate
        end
    end
    return added
end

local function rollback_typed_identities(history, added)
    local index
    for index = #added, 1, -1 do
        local candidate = added[index]
        typed_identity_history(history, candidate.category)[
            candidate.value
        ] = nil
    end
end

local function has_receipt_owner_collision(history, request, is_replay)
    if is_replay then
        return false
    end
    if history[request.receipt_id] ~= nil then
        return true
    end
    if request.operation_type == 'GRANT_CHARACTER_EXPERIENCE'
        and request.result.reward_status == 'COMMITTED'
        and history[request.result.reward_receipt_id] ~= nil
    then
        return true
    end
    return false
end

local function has_query_receipt_owner_collision(history, request)
    local main_owner = history[request.receipt_id]
    if main_owner ~= nil
        and main_owner.player_save_scope == request.player_save_scope
        and not main_owner.main
    then
        return true
    end
    if request.operation_type ~= 'CREATE_OWNED_CHARACTER' then
        local created_owner = history[request.command.created_receipt_id]
        if created_owner ~= nil
            and created_owner.player_save_scope
                == request.player_save_scope
            and not created_owner.created
        then
            return true
        end
    end
    return false
end

local function register_receipt_owner(
    history,
    receipt_id,
    owner_kind,
    player_save_scope
)
    local owner = history[receipt_id]
    if owner == nil then
        owner = {
            player_save_scope = player_save_scope,
            created = false,
            main = false,
            reward = false,
        }
        history[receipt_id] = owner
    end
    owner[owner_kind] = true
end

local function reserve_receipt_owner(
    history,
    added,
    receipt_id,
    owner_kind,
    player_save_scope
)
    local owner = history[receipt_id]
    if owner == nil then
        owner = {
            player_save_scope = player_save_scope,
            created = false,
            main = false,
            reward = false,
        }
        history[receipt_id] = owner
    end
    if not owner[owner_kind] then
        owner[owner_kind] = true
        added[#added + 1] = {
            receipt_id = receipt_id,
            owner_kind = owner_kind,
        }
    end
end

local function reserve_receipt_owners(history, request)
    local added = {}
    reserve_receipt_owner(
        history,
        added,
        request.receipt_id,
        'main',
        request.player_save_scope
    )
    if request.operation_type == 'CREATE_OWNED_CHARACTER'
        and request.change_type == 'INSERT'
    then
        reserve_receipt_owner(
            history,
            added,
            request.result.created_receipt_id,
            'created',
            request.player_save_scope
        )
    end
    if request.operation_type == 'GRANT_CHARACTER_EXPERIENCE'
        and request.result.reward_status == 'COMMITTED'
    then
        reserve_receipt_owner(
            history,
            added,
            request.result.reward_receipt_id,
            'reward',
            request.player_save_scope
        )
    end
    return added
end

local function rollback_receipt_owners(history, added)
    local index
    for index = #added, 1, -1 do
        local change = added[index]
        local owner = history[change.receipt_id]
        owner[change.owner_kind] = false
        if not owner.created and not owner.main and not owner.reward then
            history[change.receipt_id] = nil
        end
    end
end

local function empty_player(scope)
    return {
        player_save_scope = scope,
        character_save_revision = 0,
        receipt_save_revision = 0,
        read_only = false,
        characters = {},
        isolated = {},
    }
end

local function make_error(code, request, details)
    local copied = copy_or_error(details or {}, '$error.details')
    copied.request_key = request.context.idempotency_key
    return PortContract.error(code, copied, false)
end

local function identity_matches(transaction, request)
    return transaction.player_save_scope == request.player_save_scope
        and transaction.receipt_id == request.receipt_id
        and transaction.operation_type == request.operation_type
        and transaction.command_digest == request_digest(request)
        and transaction.transaction_id == request_transaction_id(request)
end

local function query_identity_matches(transaction, request)
    return transaction.player_save_scope == request.player_save_scope
        and transaction.receipt_id == request.receipt_id
        and transaction.operation_type == request.operation_type
        and transaction.command_digest == request_digest(request)
        and transaction.result_digest == request.expected_result_digest
        and transaction.expected_character_save_revision
            == request.expected_character_save_revision
        and transaction.transaction_id == request.transaction_id
        and values_equal(transaction.command, request.command)
end

local function query_proof_from_commit(request)
    return {
        player_save_scope = request.player_save_scope,
        receipt_id = request.receipt_id,
        transaction_id = request.transaction_id,
        operation_type = request.operation_type,
        command_digest = request.command_digest,
        result_digest = request.result_digest,
        expected_character_save_revision =
            request.expected_character_save_revision,
        command = copy_or_error(request.command, '$accepted.command'),
    }
end

local function query_identity_error_details(request)
    return {
        reason = 'CHARACTER_TRANSACTION_IDENTITY_MISMATCH',
        player_save_scope = request.player_save_scope,
        original_request_key = request.original_request_key,
        receipt_id = request.receipt_id,
        transaction_id = request.transaction_id,
        operation_type = request.operation_type,
        command_digest = request.command_digest,
        expected_result_digest = request.expected_result_digest,
        expected_character_save_revision =
            request.expected_character_save_revision,
    }
end

local function current_commit_value(request, transaction)
    local value = {
        status = 'COMMITTED',
        player_save_scope = request.player_save_scope,
        request_key = request.context.idempotency_key,
        receipt_id = request.receipt_id,
        transaction_id = request.transaction_id,
        operation_type = request.operation_type,
        command_digest = request.command_digest,
        character_save_revision = transaction.character_save_revision,
        receipt_save_revision = transaction.receipt_save_revision,
        character_revision = transaction.character_revision,
        result_digest = transaction.result_digest,
        result = copy_or_error(transaction.result, '$commit.result'),
    }
    return value
end

local function current_query_value(request, transaction, status)
    local value = {
        status = status,
        player_save_scope = request.player_save_scope,
        original_request_key = request.original_request_key,
        receipt_id = request.receipt_id,
        transaction_id = request.transaction_id,
        operation_type = request.operation_type,
        command_digest = request.command_digest,
        expected_result_digest = request.expected_result_digest,
        expected_character_save_revision =
            request.expected_character_save_revision,
    }
    if status == 'COMMITTED' then
        value.character_save_revision = transaction.character_save_revision
        value.receipt_save_revision = transaction.receipt_save_revision
        value.character_revision = transaction.character_revision
        value.result_digest = transaction.result_digest
        value.result = copy_or_error(transaction.result, '$query.result')
    end
    return value
end

local function result_is_valid(operation_name, value, request)
    local checked = CharacterRepository:validate_result(
        operation_name,
        PortContract.ok(value),
        request
    )
    return checked.ok == true
end

local function assert_valid_result(operation_name, value, request)
    if not result_is_valid(operation_name, value, request) then
        error(
            'FakeCharacterRepository built an invalid '
                .. operation_name
                .. ' result',
            3
        )
    end
end

local function query_status_result(request, transaction, status)
    local value = current_query_value(request, transaction, status)
    assert_valid_result('query_character_transaction', value, request)
    return ScriptedPort.success(value)
end

local function find_unresolved(authority, player_save_scope, receipt_id)
    local existing_receipt_id
    local transaction
    existing_receipt_id, transaction = raw_next(authority.receipts, nil)
    while existing_receipt_id ~= nil do
        if existing_receipt_id ~= receipt_id
            and transaction.player_save_scope == player_save_scope
            and UNRESOLVED_STATES[transaction.status]
        then
            return transaction
        end
        existing_receipt_id, transaction = raw_next(
            authority.receipts,
            existing_receipt_id
        )
    end
    return nil
end

local function validate_before_state(player, request)
    local character_id = character_id_from_request(request)
    local current = character_id and player.characters[character_id] or nil

    if request.change_type == 'INSERT' then
        return current == nil
    end
    if current == nil or request.before_state == nil then
        return false
    end
    return values_equal(current, request.before_state)
end

local function build_transaction(request, player, status, apply_count)
    local target_character_save_revision = player.character_save_revision
    if request.change_type ~= 'NO_CHANGE' then
        target_character_save_revision = target_character_save_revision + 1
    end
    return {
        status = status,
        transaction_id = request_transaction_id(request),
        player_save_scope = request.player_save_scope,
        request_key = request.context.idempotency_key,
        receipt_id = request.receipt_id,
        operation_type = request.operation_type,
        command_digest = request_digest(request),
        command = copy_or_error(request.command, '$transaction.command'),
        expected_character_save_revision = expected_character_save_revision(
            request
        ),
        character_save_revision = target_character_save_revision,
        receipt_save_revision = player.receipt_save_revision + 1,
        character_revision = request.result.character_revision,
        result_digest = request.result_digest,
        result = copy_or_error(request.result, '$transaction.result'),
        apply_count = apply_count,
    }
end

local function make_unknown(request, reason, cause_code)
    return PortContract.error('PLATFORM_RESULT_UNKNOWN', {
        request_key = request.context.idempotency_key,
        recovery = 'QUERY_OR_RECONCILE',
        reason = reason,
        cause_code = cause_code,
    }, false)
end

local function fault_completion(mode, request, success)
    if mode == nil then
        return ScriptedPort.success(success)
    end
    if mode == 'COMMIT_THEN_UNKNOWN' then
        return {
            result = make_unknown(
                request,
                'FAKE_COMMIT_COMPLETION_UNKNOWN',
                'FAKE_INJECTED_UNKNOWN'
            ),
            delay_ticks = 0,
        }
    end
    if mode == 'COMMIT_THEN_UNKNOWN_LATE_SUCCESS' then
        return {
            deliveries = {
                {
                    after_ticks = 0,
                    result = make_unknown(
                        request,
                        'FAKE_COMMIT_COMPLETION_UNKNOWN',
                        'FAKE_INJECTED_UNKNOWN'
                    ),
                },
                {
                    after_ticks = 1,
                    result = PortContract.ok(success),
                },
            },
        }
    end
    if mode == 'COMMIT_THEN_UNAVAILABLE' then
        return {
            result = make_error('PLATFORM_UNAVAILABLE', request, {
                reason = 'FAKE_INJECTED_UNAVAILABLE',
            }),
            delay_ticks = 0,
        }
    end
    if mode == 'COMMIT_THEN_WRONG_REQUEST_KEY' then
        return ScriptedPort.success(success)
    end
    if mode == 'COMMIT_THEN_MALFORMED' then
        return ScriptedPort.success(success)
    end
    if mode == 'COMMIT_THEN_DUPLICATE_SUCCESS' then
        return ScriptedPort.duplicate(PortContract.ok(success), 2, 0)
    end
    error('unsupported FakeCharacterRepository fault mode: ' .. tostring(mode))
end

local function initialize_authority(options)
    local authority = {
        players = {},
        receipts = {},
    }
    local seeded_receipt_owners = {}
    assert_exact_keys(options, {
        players = true,
        commit_faults = true,
    }, '$options')
    local rows = rawget(options, 'players')
    if rows == nil then
        rows = {}
    end
    if not dense_array(rows) then
        error('FakeCharacterRepository players must be a dense array')
    end

    local index
    for index = 1, #rows do
        local row = copy_or_error(rows[index], '$options.players[' .. index .. ']')
        assert_exact_keys(row, {
            player_save_scope = true,
            character_save_revision = true,
            receipt_save_revision = true,
            read_only = true,
            characters = true,
            isolated = true,
        }, '$options.players[' .. index .. ']')
        local scope = row.player_save_scope
        if type(scope) ~= 'string' or scope == '' or authority.players[scope] then
            error('FakeCharacterRepository player seed is invalid')
        end
        local player = empty_player(scope)
        player.character_save_revision = rawget(
            row,
            'character_save_revision'
        )
        if player.character_save_revision == nil then
            player.character_save_revision = 0
        end
        player.receipt_save_revision = rawget(
            row,
            'receipt_save_revision'
        )
        if player.receipt_save_revision == nil then
            player.receipt_save_revision = 0
        end
        if row.read_only ~= nil and type(row.read_only) ~= 'boolean' then
            error('FakeCharacterRepository read_only must be boolean')
        end
        player.read_only = row.read_only == true
        if not is_non_negative_integer(player.character_save_revision)
            or not is_non_negative_integer(player.receipt_save_revision)
        then
            error('FakeCharacterRepository seed revision is invalid')
        end

        local characters = rawget(row, 'characters')
        if characters == nil then
            characters = {}
        end
        if not dense_array(characters) then
            error('FakeCharacterRepository characters must be a dense array')
        end
        local character_index
        for character_index = 1, #characters do
            local state = characters[character_index]
            local character_id = type(state) == 'table' and state.character_id or nil
            if type(character_id) ~= 'string'
                or player.characters[character_id] ~= nil
            then
                error('FakeCharacterRepository character seed is invalid')
            end
            local load_value = {
                status = 'FOUND',
                player_save_scope = scope,
                character_id = character_id,
                character_save_revision = player.character_save_revision,
                state = state,
            }
            if not result_is_valid('load_character', load_value, nil) then
                error('FakeCharacterRepository character seed violates the port')
            end
            local created_receipt_id = state.created_receipt_id
            if seeded_receipt_owners[created_receipt_id] ~= nil then
                error(
                    'FakeCharacterRepository created receipt seed '
                        .. 'must be globally unique'
                )
            end
            seeded_receipt_owners[created_receipt_id] = {
                player_save_scope = scope,
                character_id = character_id,
            }
            player.characters[character_id] = copy_or_error(
                state,
                '$seed.character'
            )
        end

        local isolated = rawget(row, 'isolated')
        if isolated == nil then
            isolated = {}
        end
        if not dense_array(isolated) then
            error('FakeCharacterRepository isolated rows must be a dense array')
        end
        local isolated_index
        for isolated_index = 1, #isolated do
            local isolated_row = isolated[isolated_index]
            if type(isolated_row) == 'table' then
                assert_exact_keys(isolated_row, {
                    character_id = true,
                    issue_codes = true,
                }, '$options.players[' .. index .. '].isolated['
                    .. isolated_index .. ']')
            end
            if type(isolated_row) ~= 'table'
                or type(isolated_row.character_id) ~= 'string'
                or player.isolated[isolated_row.character_id] ~= nil
            then
                error('FakeCharacterRepository isolated seed is invalid')
            end
            local isolated_value = {
                status = 'READ_ONLY_ISOLATED',
                player_save_scope = scope,
                character_id = isolated_row.character_id,
                character_save_revision = player.character_save_revision,
                issue_codes = isolated_row.issue_codes,
            }
            if not result_is_valid('load_character', isolated_value, nil) then
                error('FakeCharacterRepository isolated seed violates the port')
            end
            player.isolated[isolated_row.character_id] = copy_or_error(
                isolated_row.issue_codes,
                '$seed.issue_codes'
            )
        end
        authority.players[scope] = player
    end
    return authority, seeded_receipt_owners
end

function FakeCharacterRepository.new(options)
    if options == nil then
        options = {}
    end
    if type(options) ~= 'table' then
        error('FakeCharacterRepository options must be a table')
    end
    assert_plain_tree(options, '$options')

    local authority
    local seeded_receipt_owners
    authority, seeded_receipt_owners = initialize_authority(options)
    local commit_fingerprint_by_receipt = {}
    local commit_query_proof_by_receipt = {}
    local completion_fault_mode_by_receipt = {}
    local typed_identity_history = new_typed_identity_history()
    local typed_identity_history_by_scope = {}
    local receipt_owner_history = {}
    local seeded_receipt_id
    seeded_receipt_id = raw_next(seeded_receipt_owners, nil)
    while seeded_receipt_id ~= nil do
        typed_identity_history.receipts[seeded_receipt_id] = true
        scoped_typed_identity_history(
            typed_identity_history_by_scope,
            seeded_receipt_owners[seeded_receipt_id].player_save_scope
        ).receipts[seeded_receipt_id] = true
        register_receipt_owner(
            receipt_owner_history,
            seeded_receipt_id,
            'created',
            seeded_receipt_owners[seeded_receipt_id].player_save_scope
        )
        seeded_receipt_id = raw_next(
            seeded_receipt_owners,
            seeded_receipt_id
        )
    end
    local fault_by_receipt = {}
    local initial_faults = rawget(options, 'commit_faults')
    if initial_faults == nil then
        initial_faults = {}
    end
    if not dense_array(initial_faults) then
        error('FakeCharacterRepository commit_faults must be a dense array')
    end
    local index
    for index = 1, #initial_faults do
        local fault = initial_faults[index]
        if type(fault) == 'table' then
            assert_exact_keys(fault, {
                receipt_id = true,
                mode = true,
            }, '$options.commit_faults[' .. index .. ']')
        end
        if type(fault) ~= 'table'
            or type(fault.receipt_id) ~= 'string'
            or not FAULT_MODES[fault.mode]
            or fault_by_receipt[fault.receipt_id] ~= nil
        then
            error('FakeCharacterRepository commit fault is invalid')
        end
        fault_by_receipt[fault.receipt_id] = fault.mode
    end

    local function pending_fault_count()
        local count = 0
        local receipt_id = raw_next(fault_by_receipt, nil)
        while receipt_id ~= nil do
            count = count + 1
            receipt_id = raw_next(fault_by_receipt, receipt_id)
        end
        return count
    end

    local function load_handler(request)
        local player = authority.players[request.player_save_scope]
        local value
        if player == nil then
            value = {
                status = 'NOT_FOUND',
                player_save_scope = request.player_save_scope,
                character_id = request.character_id,
                character_save_revision = 0,
            }
        elseif player.isolated[request.character_id] ~= nil then
            value = {
                status = 'READ_ONLY_ISOLATED',
                player_save_scope = request.player_save_scope,
                character_id = request.character_id,
                character_save_revision = player.character_save_revision,
                issue_codes = copy_or_error(
                    player.isolated[request.character_id],
                    '$load.issue_codes'
                ),
            }
        elseif player.characters[request.character_id] ~= nil then
            value = {
                status = 'FOUND',
                player_save_scope = request.player_save_scope,
                character_id = request.character_id,
                character_save_revision = player.character_save_revision,
                state = copy_or_error(
                    player.characters[request.character_id],
                    '$load.state'
                ),
            }
        else
            value = {
                status = 'NOT_FOUND',
                player_save_scope = request.player_save_scope,
                character_id = request.character_id,
                character_save_revision = player.character_save_revision,
            }
        end
        assert_valid_result('load_character', value, request)
        return ScriptedPort.success(value)
    end

    local function commit_handler(request)
        local existing = authority.receipts[request.receipt_id]
        if existing ~= nil then
            if not identity_matches(existing, request) then
                return {
                    result = make_error('IDEMPOTENCY_KEY_REUSED', request, {
                        receipt_id = request.receipt_id,
                        reason = 'BUSINESS_RECEIPT_IDENTITY_MISMATCH',
                    }),
                    delay_ticks = 0,
                }
            end
            if existing.status == 'COMMITTED' then
                local replay = current_commit_value(request, existing)
                assert_valid_result(
                    'commit_character_transaction',
                    replay,
                    request
                )
                return ScriptedPort.success(replay)
            end
            return {
                result = make_unknown(
                    request,
                    'EXISTING_TRANSACTION_NOT_TERMINAL',
                    existing.status
                ),
                delay_ticks = 0,
            }
        end

        local player = authority.players[request.player_save_scope]
            or empty_player(request.player_save_scope)
        if player.read_only then
            return {
                result = make_error('SAVE_READ_ONLY', request, {
                    reason = 'PLAYER_CHARACTER_SECTION_READ_ONLY',
                }),
                delay_ticks = 0,
            }
        end
        local unresolved = find_unresolved(
            authority,
            request.player_save_scope,
            request.receipt_id
        )
        if unresolved ~= nil then
            return {
                result = make_error(
                    'TRANSACTION_RECOVERY_REQUIRED',
                    request,
                    {
                        reason =
                            'EARLIER_CHARACTER_TRANSACTION_UNRESOLVED',
                        recovery = 'QUERY_OR_RECONCILE',
                        receipt_id = request.receipt_id,
                        transaction_id = request.transaction_id,
                    }
                ),
                delay_ticks = 0,
            }
        end

        local expected_character = expected_character_save_revision(request)
        if player.character_save_revision ~= expected_character
            or player.receipt_save_revision == MAX_SAFE_INTEGER
            or not validate_before_state(player, request)
        then
            return {
                result = make_error('SAVE_REVISION_CONFLICT', request, {
                    expected_character_save_revision = expected_character,
                    actual_character_save_revision = player.character_save_revision,
                    actual_receipt_save_revision = player.receipt_save_revision,
                }),
                delay_ticks = 0,
            }
        end

        local fault_mode = fault_by_receipt[request.receipt_id]
        fault_by_receipt[request.receipt_id] = nil
        local next_authority = copy_or_error(authority, '$authority.next')
        local next_player = next_authority.players[request.player_save_scope]
            or empty_player(request.player_save_scope)

        if fault_mode == 'RECOVERY_REQUIRED_THEN_UNKNOWN' then
            local recovery = build_transaction(
                request,
                next_player,
                'RECOVERY_REQUIRED',
                0
            )
            next_player.receipt_save_revision = recovery.receipt_save_revision
            next_authority.players[request.player_save_scope] = next_player
            next_authority.receipts[request.receipt_id] = recovery
            authority = next_authority
            return {
                result = make_unknown(
                    request,
                    'FAKE_TRANSACTION_RECOVERY_REQUIRED',
                    'RECOVERY_REQUIRED'
                ),
                delay_ticks = 0,
            }
        end

        local transaction = build_transaction(
            request,
            next_player,
            'COMMITTED',
            1
        )
        if request.change_type ~= 'NO_CHANGE' then
            next_player.character_save_revision =
                transaction.character_save_revision
            next_player.characters[request.after_state.character_id] =
                copy_or_error(request.after_state, '$authority.after_state')
        end
        next_player.receipt_save_revision = transaction.receipt_save_revision
        next_authority.players[request.player_save_scope] = next_player
        next_authority.receipts[request.receipt_id] = transaction

        local success = current_commit_value(request, transaction)
        assert_valid_result(
            'commit_character_transaction',
            success,
            request
        )
        authority = next_authority
        if COMPLETION_GATE_FAULT_MODES[fault_mode] then
            completion_fault_mode_by_receipt[request.receipt_id] =
                fault_mode
        end
        return fault_completion(fault_mode, request, success)
    end

    local function query_handler(request)
        if has_cross_typed_identity_collision(
            scoped_typed_identity_history(
                typed_identity_history_by_scope,
                request.player_save_scope
            ),
            query_identity_candidates(request)
        ) then
            return ScriptedPort.failure(
                'IDEMPOTENCY_KEY_REUSED',
                query_identity_error_details(request),
                false
            )
        end
        if has_query_receipt_owner_collision(
            receipt_owner_history,
            request
        ) then
            return ScriptedPort.failure(
                'IDEMPOTENCY_KEY_REUSED',
                query_identity_error_details(request),
                false
            )
        end
        local transaction = authority.receipts[request.receipt_id]
        if transaction ~= nil
            and transaction.player_save_scope == request.player_save_scope
            and not query_identity_matches(transaction, request)
        then
            return ScriptedPort.failure(
                'IDEMPOTENCY_KEY_REUSED',
                query_identity_error_details(request),
                false
            )
        end
        local accepted_proof = commit_query_proof_by_receipt[
            request.receipt_id
        ]
        if transaction == nil
            and accepted_proof ~= nil
            and accepted_proof.player_save_scope
                == request.player_save_scope
            and not query_identity_matches(accepted_proof, request)
        then
            return ScriptedPort.failure(
                'IDEMPOTENCY_KEY_REUSED',
                query_identity_error_details(request),
                false
            )
        end
        if transaction == nil
            or transaction.player_save_scope ~= request.player_save_scope
        then
            local absent = {
                status = 'NOT_FOUND',
                player_save_scope = request.player_save_scope,
                original_request_key = request.original_request_key,
                receipt_id = request.receipt_id,
                transaction_id = request.transaction_id,
                operation_type = request.operation_type,
                command_digest = request.command_digest,
                expected_result_digest = request.expected_result_digest,
                expected_character_save_revision =
                    request.expected_character_save_revision,
            }
            assert_valid_result(
                'query_character_transaction',
                absent,
                request
            )
            return ScriptedPort.success(absent)
        end
        return query_status_result(request, transaction, transaction.status)
    end

    local scripted = ScriptedPort.new(CharacterRepository, {
        default_steps = {
            load_character = load_handler,
            commit_character_transaction = commit_handler,
            query_character_transaction = query_handler,
        },
    })
    local port = {}

    port.load_character = function(_, request, complete)
        return scripted:load_character(request, complete)
    end

    port.commit_character_transaction = function(_, request, complete)
        local callback = PortContract.validate_callback(complete)
        if not callback.ok then
            return callback
        end
        local sanitized = CharacterRepository:sanitize_request(
            'commit_character_transaction',
            request
        )
        if not sanitized.ok then
            return sanitized
        end
        local fingerprint = fingerprint_request(
            'commit_character_transaction',
            sanitized.value
        )
        if not fingerprint.ok then
            return PortContract.error('PORT_CONTRACT_INVALID', nil, false)
        end
        local identity_candidates = typed_identity_candidates(
            sanitized.value
        )
        if has_cross_typed_identity_collision(
            typed_identity_history,
            identity_candidates
        ) then
            return make_error(
                'IDEMPOTENCY_KEY_REUSED',
                sanitized.value,
                {
                    reason = 'BUSINESS_RECEIPT_IDENTITY_MISMATCH',
                    receipt_id = sanitized.value.receipt_id,
                }
            )
        end
        local existing_fingerprint = commit_fingerprint_by_receipt[
            sanitized.value.receipt_id
        ]
        if existing_fingerprint ~= nil
            and existing_fingerprint ~= fingerprint.value
        then
            return make_error(
                'IDEMPOTENCY_KEY_REUSED',
                sanitized.value,
                {
                    reason = 'BUSINESS_RECEIPT_IDENTITY_MISMATCH',
                    receipt_id = sanitized.value.receipt_id,
                }
            )
        end
        if has_receipt_owner_collision(
            receipt_owner_history,
            sanitized.value,
            existing_fingerprint ~= nil
        ) then
            return make_error(
                'IDEMPOTENCY_KEY_REUSED',
                sanitized.value,
                {
                    reason = 'BUSINESS_RECEIPT_IDENTITY_MISMATCH',
                    receipt_id = sanitized.value.receipt_id,
                }
            )
        end
        local player = authority.players[
            sanitized.value.player_save_scope
        ]
        if player ~= nil and player.read_only then
            return PortContract.error('SAVE_READ_ONLY', {
                reason = 'PLAYER_CHARACTER_SECTION_READ_ONLY',
                request_key = sanitized.value.context.idempotency_key,
            }, false)
        end
        local character_id = character_id_from_request(sanitized.value)
        if player ~= nil
            and character_id ~= nil
            and player.isolated[character_id] ~= nil
        then
            return PortContract.error('SAVE_READ_ONLY', {
                reason = 'PLAYER_CHARACTER_SECTION_READ_ONLY',
                request_key = sanitized.value.context.idempotency_key,
            }, false)
        end
        local fingerprint_was_new = existing_fingerprint == nil
        if fingerprint_was_new then
            commit_fingerprint_by_receipt[sanitized.value.receipt_id] =
                fingerprint.value
            commit_query_proof_by_receipt[sanitized.value.receipt_id] =
                query_proof_from_commit(sanitized.value)
        end
        local added_typed_identities = register_typed_identities(
            typed_identity_history,
            identity_candidates
        )
        local scoped_identity_history = scoped_typed_identity_history(
            typed_identity_history_by_scope,
            sanitized.value.player_save_scope
        )
        local added_scoped_typed_identities = register_typed_identities(
            scoped_identity_history,
            identity_candidates
        )
        local added_receipt_owners = reserve_receipt_owners(
            receipt_owner_history,
            sanitized.value
        )
        local scripted_complete = complete
        local completion_fault_mode = completion_fault_mode_by_receipt[
            sanitized.value.receipt_id
        ] or fault_by_receipt[sanitized.value.receipt_id]
        if COMPLETION_GATE_FAULT_MODES[completion_fault_mode] then
            local delivery_gate
            local outward_gate
            local gate_error
            delivery_gate, _, gate_error = PortContract.completion_gate(
                CharacterRepository,
                'commit_character_transaction',
                complete,
                nil,
                sanitized.value
            )
            if gate_error ~= nil then
                if fingerprint_was_new then
                    commit_fingerprint_by_receipt[
                        sanitized.value.receipt_id
                    ] = nil
                    commit_query_proof_by_receipt[
                        sanitized.value.receipt_id
                    ] = nil
                end
                rollback_typed_identities(
                    typed_identity_history,
                    added_typed_identities
                )
                rollback_typed_identities(
                    scoped_identity_history,
                    added_scoped_typed_identities
                )
                rollback_receipt_owners(
                    receipt_owner_history,
                    added_receipt_owners
                )
                return gate_error
            end
            local function deliver_normalized(normalized)
                local consumed_mode = completion_fault_mode_by_receipt[
                    sanitized.value.receipt_id
                ]
                if consumed_mode == completion_fault_mode
                    and normalized.ok == false
                    and normalized.error.code
                        == 'PLATFORM_RESULT_UNKNOWN'
                then
                    normalized = make_unknown(
                        sanitized.value,
                        'COMPLETION_RESULT_UNKNOWN',
                        'ADAPTER_COMPLETION_AMBIGUOUS'
                    )
                end
                return delivery_gate(normalized)
            end
            outward_gate, _, gate_error = PortContract.completion_gate(
                CharacterRepository,
                'commit_character_transaction',
                deliver_normalized,
                nil,
                sanitized.value
            )
            if gate_error ~= nil then
                if fingerprint_was_new then
                    commit_fingerprint_by_receipt[
                        sanitized.value.receipt_id
                    ] = nil
                    commit_query_proof_by_receipt[
                        sanitized.value.receipt_id
                    ] = nil
                end
                rollback_typed_identities(
                    typed_identity_history,
                    added_typed_identities
                )
                rollback_typed_identities(
                    scoped_identity_history,
                    added_scoped_typed_identities
                )
                rollback_receipt_owners(
                    receipt_owner_history,
                    added_receipt_owners
                )
                return gate_error
            end
            scripted_complete = function(result)
                local consumed_mode = completion_fault_mode_by_receipt[
                    sanitized.value.receipt_id
                ]
                if consumed_mode ~= completion_fault_mode then
                    return outward_gate(result)
                end
                if consumed_mode == 'COMMIT_THEN_WRONG_REQUEST_KEY' then
                    local wrong = copy_or_error(
                        result.value,
                        '$fault.wrong_request_key'
                    )
                    wrong.request_key = 'wrong_request_key'
                    return outward_gate(PortContract.ok(wrong))
                end
                return outward_gate(
                    'malformed-character-repository-completion'
                )
            end
        end
        local admission = scripted:commit_character_transaction(
            sanitized.value,
            scripted_complete
        )
        if not admission.ok and fingerprint_was_new then
            commit_fingerprint_by_receipt[sanitized.value.receipt_id] = nil
            commit_query_proof_by_receipt[sanitized.value.receipt_id] = nil
        end
        if not admission.ok then
            rollback_typed_identities(
                typed_identity_history,
                added_typed_identities
            )
            rollback_typed_identities(
                scoped_identity_history,
                added_scoped_typed_identities
            )
            rollback_receipt_owners(
                receipt_owner_history,
                added_receipt_owners
            )
        end
        return admission
    end

    port.query_character_transaction = function(_, request, complete)
        return scripted:query_character_transaction(request, complete)
    end

    port.tick = function(_, ticks)
        return scripted:tick(ticks)
    end

    port.drain = function(_, maximum_deliveries)
        return scripted:drain(maximum_deliveries)
    end

    port.get_calls = function(_, operation_name)
        return scripted:get_calls(operation_name)
    end

    port.get_suppressed_deliveries = function()
        return scripted:get_suppressed_deliveries()
    end

    port.get_diagnostics = function()
        local diagnostics = scripted:get_diagnostics()
        diagnostics.pending_commit_fault_count = pending_fault_count()
        return diagnostics
    end

    port.verify_exhausted = function()
        local verified = scripted:verify_exhausted()
        if not verified.ok then
            return verified
        end
        local pending = pending_fault_count()
        if pending > 0 then
            return PortContract.error('FAKE_NOT_EXHAUSTED', {
                pending_commit_fault_count = pending,
            }, false)
        end
        verified.value.pending_commit_fault_count = 0
        return verified
    end

    port.assert_exhausted = function()
        local verified = port.verify_exhausted(port)
        if not verified.ok then
            error(
                'FakeCharacterRepository is not exhausted: '
                    .. tostring(verified.error.code),
                2
            )
        end
        return true
    end

    port.get_contract = function()
        return CharacterRepository
    end

    port.inject_commit_fault = function(_, receipt_id, mode)
        if type(receipt_id) ~= 'string'
            or receipt_id == ''
            or not FAULT_MODES[mode]
        then
            return PortContract.error('FAKE_FAULT_INVALID', {
                reason = 'RECEIPT_AND_SUPPORTED_MODE_REQUIRED',
            }, false)
        end
        if fault_by_receipt[receipt_id] ~= nil then
            return PortContract.error('FAKE_FAULT_INVALID', {
                reason = 'FAULT_ALREADY_REGISTERED',
                receipt_id = receipt_id,
            }, false)
        end
        fault_by_receipt[receipt_id] = mode
        return PortContract.ok({
            receipt_id = receipt_id,
            mode = mode,
        })
    end

    port.get_authority_snapshot = function()
        return copy_or_error(authority, '$authority.snapshot')
    end

    port.get_apply_count = function(_, receipt_id)
        local transaction = authority.receipts[receipt_id]
        if transaction == nil then
            return 0
        end
        return transaction.apply_count
    end

    port.get_pending_faults = function()
        return copy_or_error(fault_by_receipt, '$faults.snapshot')
    end

    local implementation = CharacterRepository:validate_implementation(port)
    if not implementation.ok then
        error('FakeCharacterRepository does not implement its contract')
    end

    return port
end

return FakeCharacterRepository
