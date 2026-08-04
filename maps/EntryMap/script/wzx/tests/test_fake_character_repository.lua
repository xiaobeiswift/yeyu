local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CharacterReceiptCodec = require 'wzx.domain.character.character_receipt_codec'
local CharacterRepository = require 'wzx.application.ports.character_repository'
local FakeCharacterRepository = require 'wzx.adapters.fake.character.fake_character_repository'
local Harness = require 'wzx.tests.harness'
local TalentListDigest = require 'wzx.domain.character.talent_list_digest'

local case = Harness.case
local assert = Harness.assert

local CREATE = 'CREATE_OWNED_CHARACTER'
local EXPERIENCE = 'GRANT_CHARACTER_EXPERIENCE'
local RENAME = 'RENAME_PROTAGONIST'
local ZERO_DIGEST = string.rep('0', 64)

local COMMAND_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'source_type', type = 'STRING' },
    { name = 'source_reference', type = 'STRING' },
}

local RESULT_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'already_owned', type = 'BOOLEAN' },
    { name = 'definition_version', type = 'INTEGER' },
    { name = 'level', type = 'INTEGER' },
    { name = 'experience', type = 'INTEGER' },
    { name = 'unlocked_talent_count', type = 'INTEGER' },
    { name = 'unlocked_talent_digest', type = 'STRING' },
    { name = 'created_receipt_id', type = 'STRING' },
    { name = 'character_revision', type = 'INTEGER' },
}

local EXPERIENCE_COMMAND_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'created_receipt_id', type = 'STRING' },
    { name = 'amount', type = 'INTEGER' },
    { name = 'reason', type = 'STRING' },
    { name = 'expected_revision', type = 'INTEGER' },
    { name = 'reward_ref_count', type = 'INTEGER' },
    { name = 'reward_plan_digest', type = 'STRING' },
}

local EXPERIENCE_RESULT_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'amount', type = 'INTEGER' },
    { name = 'reason', type = 'STRING' },
    { name = 'old_experience', type = 'INTEGER' },
    { name = 'new_experience', type = 'INTEGER' },
    { name = 'old_level', type = 'INTEGER' },
    { name = 'new_level', type = 'INTEGER' },
    { name = 'character_revision', type = 'INTEGER' },
    { name = 'reward_status', type = 'STRING' },
    { name = 'reward_receipt_id', type = 'STRING' },
    { name = 'reward_result_digest', type = 'STRING' },
}

local RENAME_COMMAND_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'created_receipt_id', type = 'STRING' },
    { name = 'new_name', type = 'STRING' },
    { name = 'expected_revision', type = 'INTEGER' },
}

local RENAME_RESULT_FIELDS = {
    { name = 'character_id', type = 'STRING' },
    { name = 'new_name', type = 'STRING' },
    { name = 'character_revision', type = 'INTEGER' },
}

local function deep_copy(value)
    if type(value) ~= 'table' then
        return value
    end
    local copied = {}
    local key = next(value, nil)
    while key ~= nil do
        copied[key] = deep_copy(rawget(value, key))
        key = next(value, key)
    end
    return copied
end

local function digest(namespace, fields, values)
    local derived = CanonicalReceiptHashV1.derive(namespace, fields, values)
    assert.equal(derived.ok, true)
    return derived.value.digest
end

local function transport_key(receipt_id)
    local derived = CharacterReceiptCodec.derive_transport_request_key(
        receipt_id
    )
    assert.equal(derived.ok, true)
    return derived.value
end

local function external_transaction_id(fixture_name)
    return 'character_fake_' .. fixture_name .. '_tx_001'
end

local function context(suffix, receipt_id)
    local value = {
        request_id = 'request_' .. suffix,
        correlation_id = 'correlation_' .. suffix,
        attempt = 1,
    }
    if receipt_id ~= nil then
        value.idempotency_key = transport_key(receipt_id)
    end
    return value
end

local function create_request(overrides)
    overrides = overrides or {}
    local receipt_id = overrides.receipt_id
        or 'character:create:fake_receipt_001'
    local character_id = overrides.character_id or 'char_protagonist'
    local command = {
        character_id = character_id,
        source_type = 'QUEST',
        source_reference = overrides.source_reference
            or 'quest_main_001:reward:1',
    }
    local state = {
        character_id = character_id,
        definition_version = 1,
        level = 1,
        experience = 0,
        awakening_rank = 0,
        unlocked_talent_ids = {},
        created_receipt_id = receipt_id,
        revision = 0,
    }
    local talent_proof = TalentListDigest.derive(
        state.unlocked_talent_ids
    )
    assert.equal(talent_proof.ok, true)
    local result = {
        operation_type = CREATE,
        character_id = character_id,
        already_owned = false,
        definition_version = 1,
        level = 1,
        experience = 0,
        unlocked_talent_count = talent_proof.value.count,
        unlocked_talent_digest = talent_proof.value.digest,
        created_receipt_id = receipt_id,
        character_revision = 0,
    }
    local command_digest = digest(
        'character_create_owned_command',
        COMMAND_FIELDS,
        command
    )
    local result_digest = digest(
        'character_create_owned_result',
        RESULT_FIELDS,
        {
            character_id = result.character_id,
            already_owned = result.already_owned,
            definition_version = result.definition_version,
            level = result.level,
            experience = result.experience,
            unlocked_talent_count = result.unlocked_talent_count,
            unlocked_talent_digest = result.unlocked_talent_digest,
            created_receipt_id = result.created_receipt_id,
            character_revision = result.character_revision,
        }
    )
    return {
        context = context(overrides.context_suffix or 'commit', receipt_id),
        player_save_scope = overrides.player_save_scope or 'player001',
        operation_type = CREATE,
        receipt_id = receipt_id,
        transaction_id = overrides.transaction_id
            or external_transaction_id(
                overrides.context_suffix or 'commit'
            ),
        command_digest = command_digest,
        expected_character_save_revision =
            overrides.expected_character_save_revision or 0,
        change_type = 'INSERT',
        command = command,
        after_state = state,
        result_digest = result_digest,
        result = result,
    }
end

local function query_request(commit_request, overrides)
    overrides = overrides or {}
    local expected_character_save_revision = rawget(
        overrides,
        'expected_character_save_revision'
    )
    if expected_character_save_revision == nil then
        expected_character_save_revision =
            commit_request.expected_character_save_revision
    end
    local request = {
        context = context(overrides.context_suffix or 'query'),
        player_save_scope = overrides.player_save_scope
            or commit_request.player_save_scope,
        original_request_key = commit_request.context.idempotency_key,
        receipt_id = commit_request.receipt_id,
        transaction_id = commit_request.transaction_id,
        operation_type = commit_request.operation_type,
        command_digest = overrides.command_digest
            or commit_request.command_digest,
        expected_result_digest = overrides.expected_result_digest
            or commit_request.result_digest,
        expected_character_save_revision =
            expected_character_save_revision,
        command = deep_copy(overrides.command or commit_request.command),
    }
    return request
end

local function query_reuse_details(request)
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

local function create_no_change_request(before_state)
    local receipt_id = 'character:create:fake_existing_receipt_001'
    local command = {
        character_id = before_state.character_id,
        source_type = 'QUEST',
        source_reference = 'quest_main_010:reward:1',
    }
    local talent_proof = TalentListDigest.derive(
        before_state.unlocked_talent_ids
    )
    assert.equal(talent_proof.ok, true)
    local result = {
        operation_type = CREATE,
        character_id = before_state.character_id,
        already_owned = true,
        definition_version = before_state.definition_version,
        level = before_state.level,
        experience = before_state.experience,
        unlocked_talent_count = talent_proof.value.count,
        unlocked_talent_digest = talent_proof.value.digest,
        created_receipt_id = before_state.created_receipt_id,
        character_revision = before_state.revision,
    }
    return {
        context = context('create_existing', receipt_id),
        player_save_scope = 'player001',
        operation_type = CREATE,
        receipt_id = receipt_id,
        transaction_id = 'character_fake_create_existing_tx_001',
        command_digest = digest(
            'character_create_owned_command',
            COMMAND_FIELDS,
            command
        ),
        expected_character_save_revision = 9,
        change_type = 'NO_CHANGE',
        command = command,
        before_state = deep_copy(before_state),
        result_digest = digest(
            'character_create_owned_result',
            RESULT_FIELDS,
            {
                character_id = result.character_id,
                already_owned = result.already_owned,
                definition_version = result.definition_version,
                level = result.level,
                experience = result.experience,
                unlocked_talent_count = result.unlocked_talent_count,
                unlocked_talent_digest = result.unlocked_talent_digest,
                created_receipt_id = result.created_receipt_id,
                character_revision = result.character_revision,
            }
        ),
        result = result,
    }
end

local function experience_update_request(before_state)
    local receipt_id = 'character:experience:fake_update_receipt_001'
    local command = {
        character_id = before_state.character_id,
        created_receipt_id = before_state.created_receipt_id,
        amount = 50,
        reason = 'QUEST_REWARD',
        expected_revision = before_state.revision,
        reward_ref_count = 0,
        reward_plan_digest = ZERO_DIGEST,
    }
    local after_state = deep_copy(before_state)
    after_state.experience = before_state.experience + command.amount
    after_state.revision = before_state.revision + 1
    local result = {
        operation_type = EXPERIENCE,
        character_id = before_state.character_id,
        amount = command.amount,
        reason = command.reason,
        old_experience = before_state.experience,
        new_experience = after_state.experience,
        old_level = before_state.level,
        new_level = after_state.level,
        character_revision = after_state.revision,
        reward_status = 'NOT_REQUIRED',
        reward_receipt_id = 'none',
        reward_result_digest = ZERO_DIGEST,
    }
    return {
        context = context('experience_update', receipt_id),
        player_save_scope = 'player001',
        operation_type = EXPERIENCE,
        receipt_id = receipt_id,
        transaction_id = 'character_fake_progression_saga_tx_001',
        command_digest = digest(
            'character_grant_experience_command',
            EXPERIENCE_COMMAND_FIELDS,
            command
        ),
        expected_character_save_revision = 9,
        change_type = 'UPDATE',
        command = command,
        before_state = deep_copy(before_state),
        after_state = after_state,
        result_digest = digest(
            'character_grant_experience_result',
            EXPERIENCE_RESULT_FIELDS,
            {
                character_id = result.character_id,
                amount = result.amount,
                reason = result.reason,
                old_experience = result.old_experience,
                new_experience = result.new_experience,
                old_level = result.old_level,
                new_level = result.new_level,
                character_revision = result.character_revision,
                reward_status = result.reward_status,
                reward_receipt_id = result.reward_receipt_id,
                reward_result_digest = result.reward_result_digest,
            }
        ),
        result = result,
    }
end

local function committed_reward_experience_request(
    before_state,
    reward_receipt_id,
    overrides
)
    overrides = overrides or {}
    local request = experience_update_request(before_state)
    request.command.reward_ref_count = 1
    request.command.reward_plan_digest = overrides.reward_plan_digest
        or string.rep('b', 64)
    request.after_state.level = before_state.level + 1
    request.result.new_level = request.after_state.level
    request.result.reward_status = 'COMMITTED'
    request.result.reward_receipt_id = reward_receipt_id
    request.result.reward_result_digest = overrides.reward_result_digest
        or string.rep('c', 64)
    request.command_digest = digest(
        'character_grant_experience_command',
        EXPERIENCE_COMMAND_FIELDS,
        request.command
    )
    request.result_digest = digest(
        'character_grant_experience_result',
        EXPERIENCE_RESULT_FIELDS,
        {
            character_id = request.result.character_id,
            amount = request.result.amount,
            reason = request.result.reason,
            old_experience = request.result.old_experience,
            new_experience = request.result.new_experience,
            old_level = request.result.old_level,
            new_level = request.result.new_level,
            character_revision = request.result.character_revision,
            reward_status = request.result.reward_status,
            reward_receipt_id = request.result.reward_receipt_id,
            reward_result_digest = request.result.reward_result_digest,
        }
    )
    return request
end

local function rename_update_request(before_state)
    local receipt_id = 'character:rename:fake_update_receipt_001'
    local command = {
        character_id = before_state.character_id,
        created_receipt_id = before_state.created_receipt_id,
        new_name = 'MistHero',
        expected_revision = before_state.revision,
    }
    local after_state = deep_copy(before_state)
    after_state.custom_name = command.new_name
    after_state.revision = before_state.revision + 1
    local result = {
        operation_type = RENAME,
        character_id = before_state.character_id,
        new_name = command.new_name,
        character_revision = after_state.revision,
    }
    return {
        context = context('rename_update', receipt_id),
        player_save_scope = 'player001',
        operation_type = RENAME,
        receipt_id = receipt_id,
        transaction_id = 'character_fake_progression_saga_tx_001',
        command_digest = digest(
            'character_rename_protagonist_command',
            RENAME_COMMAND_FIELDS,
            command
        ),
        expected_character_save_revision = 10,
        change_type = 'UPDATE',
        command = command,
        before_state = deep_copy(before_state),
        after_state = after_state,
        result_digest = digest(
            'character_rename_protagonist_result',
            RENAME_RESULT_FIELDS,
            {
                character_id = result.character_id,
                new_name = result.new_name,
                character_revision = result.character_revision,
            }
        ),
        result = result,
    }
end

local function load_request(scope, character_id, suffix)
    return {
        context = context(suffix or 'load'),
        player_save_scope = scope,
        character_id = character_id,
    }
end

local function invoke_and_tick(fake, operation, request)
    local completion
    local completion_count = 0
    local admission = fake[operation](fake, request, function(result)
        completion_count = completion_count + 1
        completion = result
    end)
    assert.equal(
        admission.ok,
        true,
        operation .. ' admission failed with '
            .. tostring(admission.error and admission.error.code)
            .. ':'
            .. tostring(
                admission.error
                    and admission.error.details
                    and admission.error.details.reason
            )
    )
    assert.deep_equal(admission.value, { accepted = true })
    assert.is_nil(completion, operation .. ' callback ran inline')
    assert.equal(completion_count, 0)
    local ticked = fake:tick(0)
    assert.equal(ticked.ok, true)
    assert.equal(ticked.value.processed_deliveries, 1)
    assert.not_nil(completion)
    assert.equal(completion_count, 1)
    assert.equal(fake:tick(0).value.processed_deliveries, 0)
    assert.equal(completion_count, 1)
    return completion
end

local function seed_state(receipt_id)
    return {
        character_id = 'char_protagonist',
        definition_version = 1,
        level = 1,
        experience = 0,
        awakening_rank = 0,
        unlocked_talent_ids = {},
        created_receipt_id = receipt_id,
        revision = 0,
    }
end

return {
    case('stateful fake isolates players and freezes every outward snapshot', function()
        local original = seed_state('character:create:seed_receipt_001')
        local fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 3,
                    receipt_save_revision = 0,
                    characters = { original },
                },
            },
        })
        assert.equal(fake:get_contract(), CharacterRepository)
        assert.equal(
            CharacterRepository:validate_implementation(fake).ok,
            true
        )

        original.level = 99
        local found = invoke_and_tick(
            fake,
            'load_character',
            load_request('player001', 'char_protagonist', 'load_found')
        )
        assert.equal(found.ok, true)
        assert.equal(found.value.status, 'FOUND')
        assert.equal(found.value.state.level, 1)
        found.value.state.level = 88

        local repeated = invoke_and_tick(
            fake,
            'load_character',
            load_request('player001', 'char_protagonist', 'load_repeat')
        )
        assert.equal(repeated.value.state.level, 1)

        local isolated = invoke_and_tick(
            fake,
            'load_character',
            load_request('player002', 'char_protagonist', 'load_other')
        )
        assert.equal(isolated.value.status, 'NOT_FOUND')
        assert.equal(isolated.value.character_save_revision, 0)

        local snapshot = fake:get_authority_snapshot()
        snapshot.players.player001.characters.char_protagonist.level = 77
        assert.equal(
            fake:get_authority_snapshot().players.player001.characters
                .char_protagonist.level,
            1
        )
    end),

    case('commit applies once and same identity replays the frozen result', function()
        local fake = FakeCharacterRepository.new()
        local request = create_request()
        local original = deep_copy(request)
        local completion
        local admission = fake:commit_character_transaction(
            request,
            function(result)
                completion = result
            end
        )
        assert.equal(admission.ok, true)
        assert.is_nil(completion)
        request.after_state.level = 50
        request.result.level = 50
        fake:tick(0)
        assert.equal(completion.ok, true)
        assert.equal(completion.value.result.level, 1)
        assert.equal(
            completion.value.transaction_id,
            original.transaction_id
        )
        assert.equal(completion.value.character_save_revision, 1)
        assert.equal(completion.value.receipt_save_revision, 1)
        assert.equal(fake:get_apply_count(original.receipt_id), 1)

        completion.value.result.level = 60
        local replay = deep_copy(original)
        replay.context = context('commit_replay', replay.receipt_id)
        local replayed = invoke_and_tick(
            fake,
            'commit_character_transaction',
            replay
        )
        assert.equal(replayed.ok, true)
        assert.equal(replayed.value.result.level, 1)
        assert.equal(fake:get_apply_count(original.receipt_id), 1)

        local loaded = invoke_and_tick(
            fake,
            'load_character',
            load_request('player001', 'char_protagonist', 'load_committed')
        )
        assert.equal(loaded.value.state.level, 1)
    end),

    case('all character operations apply exact state and dual revisions once', function()
        local original = seed_state(
            'character:create:operation_matrix_seed_001'
        )
        original.level = 2
        original.experience = 100
        original.revision = 7
        local fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 9,
                    receipt_save_revision = 11,
                    characters = { original },
                },
            },
        })
        local create_existing = create_no_change_request(original)
        local experience_update = experience_update_request(original)
        local rename_update = rename_update_request(
            experience_update.after_state
        )
        assert.equal(
            experience_update.transaction_id,
            rename_update.transaction_id
        )
        local steps = {
            {
                request = create_existing,
                expected_character_save_revision = 9,
                expected_receipt_save_revision = 12,
                expected_character_revision = 7,
            },
            {
                request = experience_update,
                expected_character_save_revision = 10,
                expected_receipt_save_revision = 13,
                expected_character_revision = 8,
            },
            {
                request = rename_update,
                expected_character_save_revision = 11,
                expected_receipt_save_revision = 14,
                expected_character_revision = 9,
            },
        }
        local index
        for index = 1, #steps do
            local step = steps[index]
            local completion = invoke_and_tick(
                fake,
                'commit_character_transaction',
                step.request
            )
            assert.equal(completion.ok, true)
            assert.equal(completion.value.status, 'COMMITTED')
            assert.equal(
                completion.value.transaction_id,
                step.request.transaction_id
            )
            assert.equal(
                completion.value.character_save_revision,
                step.expected_character_save_revision
            )
            assert.equal(
                completion.value.receipt_save_revision,
                step.expected_receipt_save_revision
            )
            assert.equal(
                completion.value.character_revision,
                step.expected_character_revision
            )
            assert.equal(fake:get_apply_count(step.request.receipt_id), 1)

            local queried = invoke_and_tick(
                fake,
                'query_character_transaction',
                query_request(step.request, {
                    context_suffix = 'matrix_query_' .. index,
                })
            )
            assert.equal(queried.ok, true)
            assert.equal(queried.value.status, 'COMMITTED')
            assert.equal(
                queried.value.expected_result_digest,
                step.request.result_digest
            )
            assert.equal(
                queried.value.expected_character_save_revision,
                step.request.expected_character_save_revision
            )
            assert.equal(
                queried.value.transaction_id,
                step.request.transaction_id
            )
        end

        local loaded = invoke_and_tick(
            fake,
            'load_character',
            load_request('player001', 'char_protagonist', 'matrix_load')
        )
        assert.equal(loaded.ok, true)
        assert.equal(loaded.value.character_save_revision, 11)
        assert.equal(loaded.value.state.experience, 150)
        assert.equal(loaded.value.state.custom_name, 'MistHero')
        assert.equal(loaded.value.state.revision, 9)
    end),

    case('receipt cannot be rebound to another payload or transaction', function()
        local fake = FakeCharacterRepository.new()
        local request = create_request({
            receipt_id = 'character:create:reuse_receipt_001',
        })
        assert.equal(invoke_and_tick(
            fake,
            'commit_character_transaction',
            request
        ).ok, true)

        local rebound = deep_copy(request)
        rebound.context = context('transaction_rebind', rebound.receipt_id)
        rebound.transaction_id = 'tx_other_identity_001'
        local rebound_callback_count = 0
        local rebound_rejected = fake:commit_character_transaction(
            rebound,
            function()
                rebound_callback_count = rebound_callback_count + 1
            end
        )
        assert.error_code(rebound_rejected, 'IDEMPOTENCY_KEY_REUSED')
        assert.deep_equal(rebound_rejected.error.details, {
            reason = 'BUSINESS_RECEIPT_IDENTITY_MISMATCH',
            receipt_id = rebound.receipt_id,
            request_key = rebound.context.idempotency_key,
        })
        assert.error_code(
            CharacterRepository:validate_result(
                'commit_character_transaction',
                rebound_rejected,
                rebound,
                'ADMISSION'
            ),
            'IDEMPOTENCY_KEY_REUSED'
        )
        assert.equal(rebound_callback_count, 0)

        local guarded_result = CharacterRepository:guard_implementation(fake)
        assert.equal(guarded_result.ok, true)
        local guarded_callback_count = 0
        local guarded_rejected =
            guarded_result.value:commit_character_transaction(
                rebound,
                function()
                    guarded_callback_count = guarded_callback_count + 1
                end
            )
        assert.error_code(guarded_rejected, 'IDEMPOTENCY_KEY_REUSED')
        assert.deep_equal(guarded_rejected.error.details, {
            reason = 'BUSINESS_RECEIPT_IDENTITY_MISMATCH',
            receipt_id = rebound.receipt_id,
            request_key = rebound.context.idempotency_key,
        })
        assert.is_nil(
            guarded_rejected.error.details.expected_fingerprint
        )
        assert.is_nil(guarded_rejected.error.details.actual_fingerprint)
        assert.equal(guarded_callback_count, 0)
        assert.equal(#fake:get_calls('commit_character_transaction'), 1)

        local cross_player = deep_copy(request)
        cross_player.context = context('receipt_cross_player', request.receipt_id)
        cross_player.player_save_scope = 'player002'
        local cross_player_rejected = fake:commit_character_transaction(
            cross_player,
            function()
                error('cross-player receipt reuse must not callback')
            end
        )
        assert.error_code(cross_player_rejected, 'IDEMPOTENCY_KEY_REUSED')

        local conflicting = create_request({
            receipt_id = request.receipt_id,
            source_reference = 'quest_main_002:reward:1',
            context_suffix = 'reuse_conflict',
        })
        local callback_count = 0
        local rejected = fake:commit_character_transaction(
            conflicting,
            function()
                callback_count = callback_count + 1
            end
        )
        assert.error_code(rejected, 'IDEMPOTENCY_KEY_REUSED')
        assert.equal(callback_count, 0)
        assert.equal(fake:tick(0).value.processed_deliveries, 0)
        assert.equal(#fake:get_calls('commit_character_transaction'), 1)
        assert.equal(fake:get_apply_count(request.receipt_id), 1)
    end),

    case('typed identity and receipt ownership histories reject repurposing', function()
        local function assert_sync_reuse(fake, request, call_count)
            local callback_count = 0
            local rejected = fake:commit_character_transaction(
                request,
                function()
                    callback_count = callback_count + 1
                end
            )
            assert.error_code(rejected, 'IDEMPOTENCY_KEY_REUSED')
            assert.equal(callback_count, 0)
            assert.equal(
                #fake:get_calls('commit_character_transaction'),
                call_count
            )
            assert.equal(fake:tick(0).value.processed_deliveries, 0)
        end

        local old_receipt = 'typed_receipt_history_001'
        local old_transaction = 'typed_transaction_history_001'
        local fake = FakeCharacterRepository.new()
        local first = create_request({
            receipt_id = old_receipt,
            transaction_id = old_transaction,
            context_suffix = 'typed_history_first',
        })
        assert.equal(invoke_and_tick(
            fake,
            'commit_character_transaction',
            first
        ).ok, true)
        local after_first = fake:get_authority_snapshot()

        local transaction_reuses_receipt = create_request({
            receipt_id = 'typed_receipt_new_001',
            transaction_id = old_receipt,
            character_id = 'char_companion',
            expected_character_save_revision = 1,
            context_suffix = 'typed_tx_reuses_receipt',
        })
        assert_sync_reuse(fake, transaction_reuses_receipt, 1)
        assert.deep_equal(fake:get_authority_snapshot(), after_first)

        local receipt_reuses_transaction = create_request({
            receipt_id = old_transaction,
            transaction_id = 'typed_transaction_new_001',
            character_id = 'char_companion',
            expected_character_save_revision = 1,
            context_suffix = 'typed_receipt_reuses_tx',
        })
        assert_sync_reuse(fake, receipt_reuses_transaction, 1)
        assert.deep_equal(fake:get_authority_snapshot(), after_first)

        local transaction_reuses_command_digest = create_request({
            receipt_id = 'typed_after_command_digest_receipt_001',
            transaction_id = first.command_digest,
            character_id = 'char_companion',
            expected_character_save_revision = 1,
            context_suffix = 'typed_tx_reuses_command_digest',
        })
        assert_sync_reuse(fake, transaction_reuses_command_digest, 1)
        assert.deep_equal(fake:get_authority_snapshot(), after_first)

        local transaction_reuses_result_digest = create_request({
            receipt_id = 'typed_after_result_digest_receipt_001',
            transaction_id = first.result_digest,
            character_id = 'char_companion',
            expected_character_save_revision = 1,
            context_suffix = 'typed_tx_reuses_result_digest',
        })
        assert_sync_reuse(fake, transaction_reuses_result_digest, 1)
        assert.deep_equal(fake:get_authority_snapshot(), after_first)

        local forged_created_state = seed_state(
            first.context.idempotency_key
        )
        local created_receipt_reuses_transport = rename_update_request(
            forged_created_state
        )
        created_receipt_reuses_transport.receipt_id =
            'character:rename:created_reuses_transport_001'
        created_receipt_reuses_transport.context = context(
            'typed_created_reuses_transport',
            created_receipt_reuses_transport.receipt_id
        )
        created_receipt_reuses_transport.transaction_id =
            'typed_created_reuses_transport_tx_001'
        assert_sync_reuse(
            fake,
            created_receipt_reuses_transport,
            1
        )
        assert.deep_equal(fake:get_authority_snapshot(), after_first)

        local same_category_fake = FakeCharacterRepository.new()
        local saga_transaction = 'typed_shared_saga_transaction_001'
        local saga_first = create_request({
            receipt_id = 'typed_same_category_receipt_001',
            transaction_id = saga_transaction,
            context_suffix = 'typed_same_category_first',
        })
        assert.equal(invoke_and_tick(
            same_category_fake,
            'commit_character_transaction',
            saga_first
        ).ok, true)
        local saga_second = create_request({
            receipt_id = 'typed_same_category_receipt_002',
            transaction_id = saga_transaction,
            character_id = 'char_companion',
            expected_character_save_revision = 1,
            context_suffix = 'typed_same_category_second',
        })
        assert.equal(invoke_and_tick(
            same_category_fake,
            'commit_character_transaction',
            saga_second
        ).ok, true)

        local reward_seed = seed_state(
            'character:create:typed_reward_seed_001'
        )
        reward_seed.level = 2
        reward_seed.experience = 100
        reward_seed.revision = 7
        local reward_fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 9,
                    receipt_save_revision = 3,
                    characters = { reward_seed },
                },
            },
        })
        local reward_request = committed_reward_experience_request(
            reward_seed,
            'typed_reward_history_001'
        )
        assert.equal(invoke_and_tick(
            reward_fake,
            'commit_character_transaction',
            reward_request
        ).ok, true)
        local reward_snapshot = reward_fake:get_authority_snapshot()
        local repeated_reward = committed_reward_experience_request(
            reward_request.after_state,
            reward_request.result.reward_receipt_id
        )
        repeated_reward.receipt_id =
            'character:experience:second_reward_owner_001'
        repeated_reward.context = context(
            'typed_second_reward_owner',
            repeated_reward.receipt_id
        )
        repeated_reward.transaction_id =
            'typed_second_reward_owner_tx_001'
        repeated_reward.expected_character_save_revision = 10
        assert_sync_reuse(reward_fake, repeated_reward, 1)
        assert.deep_equal(
            reward_fake:get_authority_snapshot(),
            reward_snapshot
        )
        local reward_reused_as_main = create_request({
            receipt_id = reward_request.result.reward_receipt_id,
            transaction_id = 'typed_after_reward_main_tx_001',
            character_id = 'char_companion',
            expected_character_save_revision = 10,
            context_suffix = 'typed_reward_reused_as_main',
        })
        assert_sync_reuse(reward_fake, reward_reused_as_main, 1)
        assert.deep_equal(
            reward_fake:get_authority_snapshot(),
            reward_snapshot
        )
        local reward_reused_as_transaction = create_request({
            receipt_id = 'typed_after_reward_receipt_001',
            transaction_id = reward_request.result.reward_receipt_id,
            character_id = 'char_companion',
            expected_character_save_revision = 10,
            context_suffix = 'typed_reward_reused_as_tx',
        })
        assert_sync_reuse(
            reward_fake,
            reward_reused_as_transaction,
            1
        )
        assert.deep_equal(
            reward_fake:get_authority_snapshot(),
            reward_snapshot
        )

        local player_a = seed_state(
            'character:create:typed_owner_player_a_001'
        )
        player_a.level = 2
        player_a.experience = 100
        player_a.revision = 7
        local player_b = seed_state('typed_owner_player_b_created_001')
        player_b.character_id = 'char_companion'
        local owner_fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 9,
                    receipt_save_revision = 3,
                    characters = { player_a },
                },
                {
                    player_save_scope = 'player002',
                    character_save_revision = 0,
                    receipt_save_revision = 0,
                    characters = { player_b },
                },
            },
        })
        local owner_collision = committed_reward_experience_request(
            player_a,
            player_b.created_receipt_id
        )
        local owner_before = owner_fake:get_authority_snapshot()
        assert_sync_reuse(owner_fake, owner_collision, 0)
        assert.deep_equal(owner_fake:get_authority_snapshot(), owner_before)
    end),

    case('experience nested digests share global identity history without query ownership', function()
        local function assert_sync_reuse(fake, request, call_count)
            assert.equal(
                CharacterRepository:sanitize_request(
                    'commit_character_transaction',
                    request
                ).ok,
                true
            )
            local before = fake:get_authority_snapshot()
            local callback_count = 0
            local rejected = fake:commit_character_transaction(
                request,
                function()
                    callback_count = callback_count + 1
                end
            )
            assert.error_code(rejected, 'IDEMPOTENCY_KEY_REUSED')
            assert.equal(callback_count, 0)
            assert.equal(
                #fake:get_calls('commit_character_transaction'),
                call_count
            )
            assert.equal(fake:tick(0).value.processed_deliveries, 0)
            assert.deep_equal(fake:get_authority_snapshot(), before)
        end

        local primary_receipt = string.rep('a', 64)
        local reward_plan_digest = string.rep('d', 64)
        local transport_target_receipt =
            'character:create:nested_transport_target_001'
        local reward_result_digest = transport_key(
            transport_target_receipt
        )
        local original = seed_state(
            'character:create:nested_digest_seed_001'
        )
        original.level = 2
        original.experience = 100
        original.revision = 7
        local fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 9,
                    receipt_save_revision = 3,
                    characters = { original },
                },
            },
        })
        local first = committed_reward_experience_request(
            original,
            'nested_digest_reward_receipt_001',
            {
                reward_plan_digest = reward_plan_digest,
                reward_result_digest = reward_result_digest,
            }
        )
        first.receipt_id = primary_receipt
        first.context = context('nested_digest_first', primary_receipt)
        first.transaction_id = 'nested_digest_first_transaction_001'

        local first_completion
        local first_completion_count = 0
        local admitted = fake:commit_character_transaction(
            first,
            function(result)
                first_completion_count = first_completion_count + 1
                first_completion = result
            end
        )
        assert.equal(admitted.ok, true)
        assert.deep_equal(admitted.value, { accepted = true })
        assert.equal(first_completion_count, 0)

        local plan_as_cross_player_receipt = create_request({
            receipt_id = reward_plan_digest,
            player_save_scope = 'player002',
            context_suffix = 'nested_plan_as_receipt',
        })
        assert.equal(
            CharacterRepository:sanitize_request(
                'commit_character_transaction',
                plan_as_cross_player_receipt
            ).ok,
            true
        )
        local reservation_callback_count = 0
        local reservation_rejected =
            fake:commit_character_transaction(
                plan_as_cross_player_receipt,
                function()
                    reservation_callback_count =
                        reservation_callback_count + 1
                end
            )
        assert.error_code(
            reservation_rejected,
            'IDEMPOTENCY_KEY_REUSED'
        )
        assert.equal(reservation_callback_count, 0)
        assert.equal(first_completion_count, 0)
        assert.equal(
            #fake:get_calls('commit_character_transaction'),
            1
        )

        assert.equal(fake:tick(0).value.processed_deliveries, 1)
        assert.equal(first_completion_count, 1)
        assert.equal(first_completion.ok, true)
        assert.equal(fake:get_apply_count(first.receipt_id), 1)
        local after_first = fake:get_authority_snapshot()

        local result_as_transaction = create_request({
            receipt_id = 'nested_result_as_transaction_receipt_001',
            transaction_id = reward_result_digest,
            player_save_scope = 'player002',
            context_suffix = 'nested_result_as_transaction',
        })
        assert_sync_reuse(fake, result_as_transaction, 1)

        local result_as_transport = create_request({
            receipt_id = transport_target_receipt,
            player_save_scope = 'player002',
            context_suffix = 'nested_result_as_transport',
        })
        assert.equal(
            result_as_transport.context.idempotency_key,
            reward_result_digest
        )
        assert_sync_reuse(fake, result_as_transport, 1)

        local receipt_as_later_plan =
            committed_reward_experience_request(
                first.after_state,
                'nested_reverse_reward_receipt_001',
                {
                    reward_plan_digest = primary_receipt,
                    reward_result_digest = string.rep('e', 64),
                }
            )
        receipt_as_later_plan.receipt_id =
            'character:experience:nested_reverse_receipt_001'
        receipt_as_later_plan.context = context(
            'nested_reverse_plan',
            receipt_as_later_plan.receipt_id
        )
        receipt_as_later_plan.transaction_id =
            'nested_reverse_plan_transaction_001'
        receipt_as_later_plan.expected_character_save_revision = 10
        assert_sync_reuse(fake, receipt_as_later_plan, 1)

        local collision_query = query_request(
            receipt_as_later_plan,
            { context_suffix = 'nested_plan_history_query' }
        )
        assert.equal(
            CharacterRepository:sanitize_request(
                'query_character_transaction',
                collision_query
            ).ok,
            true
        )
        local query_rejected = invoke_and_tick(
            fake,
            'query_character_transaction',
            collision_query
        )
        assert.error_code(query_rejected, 'IDEMPOTENCY_KEY_REUSED')
        assert.equal(
            #fake:get_calls('query_character_transaction'),
            1
        )
        assert.deep_equal(fake:get_authority_snapshot(), after_first)

        local novel_plan_digest = string.rep('f', 64)
        local unbound_state = seed_state(
            'character:create:nested_query_seed_001'
        )
        local unbound_source = committed_reward_experience_request(
            unbound_state,
            'nested_query_reward_receipt_001',
            {
                reward_plan_digest = novel_plan_digest,
                reward_result_digest = string.rep('1', 64),
            }
        )
        unbound_source.receipt_id =
            'character:experience:nested_query_missing_001'
        unbound_source.context = context(
            'nested_query_missing',
            unbound_source.receipt_id
        )
        unbound_source.transaction_id =
            'nested_query_missing_transaction_001'
        unbound_source.expected_character_save_revision = 0
        local unbound_fake = FakeCharacterRepository.new()
        local not_found = invoke_and_tick(
            unbound_fake,
            'query_character_transaction',
            query_request(unbound_source, {
                context_suffix = 'nested_query_not_found',
            })
        )
        assert.equal(not_found.ok, true)
        assert.equal(not_found.value.status, 'NOT_FOUND')

        local after_unbound_query = create_request({
            receipt_id = novel_plan_digest,
            context_suffix = 'nested_query_does_not_claim_plan',
        })
        local committed_after_query = invoke_and_tick(
            unbound_fake,
            'commit_character_transaction',
            after_unbound_query
        )
        assert.equal(committed_after_query.ok, true)
        assert.equal(
            unbound_fake:get_apply_count(after_unbound_query.receipt_id),
            1
        )
    end),

    case('CAS conflict completes asynchronously without changing authority', function()
        local fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 2,
                    receipt_save_revision = 0,
                    characters = {},
                },
            },
        })
        local request = create_request({
            receipt_id = 'character:create:cas_receipt_001',
            expected_character_save_revision = 1,
        })
        local completion = invoke_and_tick(
            fake,
            'commit_character_transaction',
            request
        )
        assert.error_code(completion, 'SAVE_REVISION_CONFLICT')
        assert.equal(
            completion.error.details.request_key,
            request.context.idempotency_key
        )
        assert.equal(fake:get_apply_count(request.receipt_id), 0)
        local snapshot = fake:get_authority_snapshot()
        assert.equal(snapshot.players.player001.character_save_revision, 2)
        assert.is_nil(snapshot.receipts[request.receipt_id])

        local repurposed = create_request({
            receipt_id = request.receipt_id,
            transaction_id = 'character_fake_cas_repurpose_tx_001',
            character_id = 'char_companion',
            expected_character_save_revision = 2,
            context_suffix = 'cas_repurpose',
        })
        local callback_count = 0
        local original_pairs = _G.pairs
        _G.pairs = function()
            return function() return nil end, nil, nil
        end
        local call_ok, reuse_rejected = pcall(function()
            return fake:commit_character_transaction(
                repurposed,
                function()
                    callback_count = callback_count + 1
                end
            )
        end)
        _G.pairs = original_pairs
        assert.equal(call_ok, true)
        assert.error_code(reuse_rejected, 'IDEMPOTENCY_KEY_REUSED')
        assert.equal(callback_count, 0)
        assert.equal(#fake:get_calls('commit_character_transaction'), 1)
        assert.equal(fake:tick(0).value.processed_deliveries, 0)
        assert.deep_equal(fake:get_authority_snapshot(), snapshot)
    end),

    case('accepted unknown reconciles to committed and never reapplies', function()
        local fake = FakeCharacterRepository.new()
        local request = create_request({
            receipt_id = 'character:create:unknown_receipt_001',
        })
        assert.equal(fake:inject_commit_fault(
            request.receipt_id,
            'COMMIT_THEN_UNKNOWN'
        ).ok, true)
        local unknown = invoke_and_tick(
            fake,
            'commit_character_transaction',
            request
        )
        assert.error_code(unknown, 'PLATFORM_RESULT_UNKNOWN')
        assert.equal(unknown.error.retryable, false)
        assert.equal(unknown.error.details.recovery, 'QUERY_OR_RECONCILE')
        assert.equal(
            unknown.error.details.request_key,
            request.context.idempotency_key
        )
        assert.equal(fake:get_apply_count(request.receipt_id), 1)

        local reconciled = invoke_and_tick(
            fake,
            'query_character_transaction',
            query_request(request)
        )
        assert.equal(reconciled.ok, true)
        assert.equal(reconciled.value.status, 'COMMITTED')
        assert.equal(reconciled.value.transaction_id, request.transaction_id)
        assert.equal(reconciled.value.character_save_revision, 1)
        assert.equal(reconciled.value.receipt_save_revision, 1)
        reconciled.value.result.level = 90

        local query_again = invoke_and_tick(
            fake,
            'query_character_transaction',
            query_request(request, { context_suffix = 'query_again' })
        )
        assert.equal(query_again.value.result.level, 1)
        assert.equal(fake:get_apply_count(request.receipt_id), 1)
    end),

    case('malicious completion faults reconcile without poisoning diagnostics', function()
        local modes = {
            'COMMIT_THEN_WRONG_REQUEST_KEY',
            'COMMIT_THEN_MALFORMED',
        }
        local index
        for index = 1, #modes do
            local fake = FakeCharacterRepository.new()
            local request = create_request({
                receipt_id = 'character:create:completion_fault_00'
                    .. index,
                context_suffix = 'completion_fault_' .. index,
            })
            assert.equal(fake:inject_commit_fault(
                request.receipt_id,
                modes[index]
            ).ok, true)
            local completion = invoke_and_tick(
                fake,
                'commit_character_transaction',
                request
            )
            assert.error_code(completion, 'PLATFORM_RESULT_UNKNOWN')
            assert.equal(completion.error.retryable, false)
            assert.equal(
                completion.error.details.request_key,
                request.context.idempotency_key
            )
            assert.equal(
                completion.error.details.recovery,
                'QUERY_OR_RECONCILE'
            )
            assert.equal(
                completion.error.details.reason,
                'COMPLETION_RESULT_UNKNOWN'
            )
            assert.equal(
                completion.error.details.cause_code,
                'ADAPTER_COMPLETION_AMBIGUOUS'
            )
            assert.error_code(
                CharacterRepository:validate_result(
                    'commit_character_transaction',
                    completion,
                    request,
                    'COMPLETION'
                ),
                'PLATFORM_RESULT_UNKNOWN'
            )
            assert.equal(
                fake:get_apply_count(request.receipt_id),
                1,
                'fault completion did not commit; cause='
                    .. tostring(completion.error.details.cause_code)
                    .. ' issues='
                    .. tostring(fake:get_diagnostics().script_issue_count)
            )
            assert.equal(fake:get_diagnostics().script_issue_count, 0)

            local queried = invoke_and_tick(
                fake,
                'query_character_transaction',
                query_request(request, {
                    context_suffix = 'completion_fault_query_' .. index,
                })
            )
            assert.equal(queried.ok, true)
            assert.equal(queried.value.status, 'COMMITTED')
            assert.equal(fake:verify_exhausted().ok, true)
        end
    end),

    case('pending injected faults participate in exhaustion checks', function()
        local fake = FakeCharacterRepository.new()
        local request = create_request({
            receipt_id = 'character:create:pending_fault_receipt_001',
            context_suffix = 'pending_fault',
        })
        assert.equal(fake:inject_commit_fault(
            request.receipt_id,
            'COMMIT_THEN_UNKNOWN'
        ).ok, true)
        local pending = fake:verify_exhausted()
        assert.error_code(pending, 'FAKE_NOT_EXHAUSTED')
        assert.equal(pending.error.details.pending_commit_fault_count, 1)
        assert.equal(fake:get_diagnostics().pending_commit_fault_count, 1)
        assert.throws(function()
            fake:assert_exhausted()
        end, 'not exhausted')

        local completion = invoke_and_tick(
            fake,
            'commit_character_transaction',
            request
        )
        assert.error_code(completion, 'PLATFORM_RESULT_UNKNOWN')
        assert.equal(fake:get_diagnostics().pending_commit_fault_count, 0)
        assert.equal(fake:verify_exhausted().ok, true)
        assert.equal(fake:assert_exhausted(), true)
    end),

    case('unresolved transaction blocks a second commit with exact recovery details', function()
        local fake = FakeCharacterRepository.new()
        local first = create_request({
            receipt_id = 'character:create:recovery_receipt_001',
            context_suffix = 'recovery_first',
        })
        assert.equal(fake:inject_commit_fault(
            first.receipt_id,
            'RECOVERY_REQUIRED_THEN_UNKNOWN'
        ).ok, true)
        local first_completion = invoke_and_tick(
            fake,
            'commit_character_transaction',
            first
        )
        assert.error_code(first_completion, 'PLATFORM_RESULT_UNKNOWN')
        assert.equal(fake:get_apply_count(first.receipt_id), 0)

        local second = create_request({
            receipt_id = 'character:create:recovery_receipt_002',
            context_suffix = 'recovery_second',
        })
        local blocked
        local blocked_count = 0
        local original_next = _G.next
        _G.next = function() return nil end
        local call_ok, admission = pcall(function()
            return fake:commit_character_transaction(second, function(result)
                blocked_count = blocked_count + 1
                blocked = result
            end)
        end)
        _G.next = original_next
        assert.equal(call_ok, true)
        assert.equal(admission.ok, true)
        assert.is_nil(blocked)
        assert.equal(blocked_count, 0)
        assert.equal(fake:tick(0).value.processed_deliveries, 1)
        assert.equal(blocked_count, 1)
        assert.error_code(blocked, 'TRANSACTION_RECOVERY_REQUIRED')
        assert.equal(blocked.error.retryable, false)
        assert.deep_equal(blocked.error.details, {
            reason = 'EARLIER_CHARACTER_TRANSACTION_UNRESOLVED',
            request_key = second.context.idempotency_key,
            recovery = 'QUERY_OR_RECONCILE',
            receipt_id = second.receipt_id,
            transaction_id = second.transaction_id,
        })

        local guarded = CharacterRepository:guard_implementation(fake)
        assert.equal(guarded.ok, true)
        local guarded_blocked
        local guarded_callback_count = 0
        local guarded_admission =
            guarded.value:commit_character_transaction(
                second,
                function(result)
                    guarded_callback_count = guarded_callback_count + 1
                    guarded_blocked = result
                end
            )
        assert.equal(guarded_admission.ok, true)
        assert.is_nil(guarded_blocked)
        assert.equal(guarded_callback_count, 0)
        assert.equal(fake:tick(0).value.processed_deliveries, 1)
        assert.error_code(
            guarded_blocked,
            'TRANSACTION_RECOVERY_REQUIRED'
        )
        assert.deep_equal(guarded_blocked.error.details, {
            reason = 'EARLIER_CHARACTER_TRANSACTION_UNRESOLVED',
            request_key = second.context.idempotency_key,
            recovery = 'QUERY_OR_RECONCILE',
            receipt_id = second.receipt_id,
            transaction_id = second.transaction_id,
        })
        assert.equal(guarded_callback_count, 1)
        assert.equal(fake:get_apply_count(second.receipt_id), 0)
        assert.is_nil(
            fake:get_authority_snapshot().receipts[second.receipt_id]
        )

        local queried = invoke_and_tick(
            fake,
            'query_character_transaction',
            query_request(first, { context_suffix = 'recovery_query' })
        )
        assert.equal(queried.ok, true)
        assert.equal(queried.value.status, 'RECOVERY_REQUIRED')
        assert.equal(
            queried.value.expected_character_save_revision,
            first.expected_character_save_revision
        )
    end),

    case('known read only scope rejects synchronously without callback or queue', function()
        local fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 0,
                    receipt_save_revision = 0,
                    read_only = true,
                    characters = {},
                },
            },
        })
        local request = create_request({
            receipt_id = 'character:create:readonly_receipt_001',
        })
        assert.equal(fake:inject_commit_fault(
            request.receipt_id,
            'COMMIT_THEN_UNKNOWN'
        ).ok, true)
        local callback_count = 0
        local rejected = fake:commit_character_transaction(
            request,
            function()
                callback_count = callback_count + 1
            end
        )
        assert.error_code(rejected, 'SAVE_READ_ONLY')
        assert.equal(callback_count, 0)
        assert.equal(#fake:get_calls('commit_character_transaction'), 0)
        assert.equal(fake:tick(0).value.processed_deliveries, 0)
        assert.equal(fake:get_apply_count(request.receipt_id), 0)
        assert.equal(
            fake:get_pending_faults()[request.receipt_id],
            'COMMIT_THEN_UNKNOWN'
        )
    end),

    case('isolated character rejects writes synchronously with zero side effects', function()
        local fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 4,
                    receipt_save_revision = 2,
                    characters = {},
                    isolated = {
                        {
                            character_id = 'char_protagonist',
                            issue_codes = {
                                'CHARACTER_CONFIG_MISSING',
                            },
                        },
                    },
                },
            },
        })
        local request = create_request({
            receipt_id = 'character:create:isolated_receipt_001',
            expected_character_save_revision = 4,
        })
        assert.equal(fake:inject_commit_fault(
            request.receipt_id,
            'COMMIT_THEN_UNKNOWN'
        ).ok, true)
        local before = fake:get_authority_snapshot()
        local callback_count = 0
        local rejected = fake:commit_character_transaction(
            request,
            function()
                callback_count = callback_count + 1
            end
        )
        assert.error_code(rejected, 'SAVE_READ_ONLY')
        assert.equal(
            rejected.error.details.reason,
            'PLAYER_CHARACTER_SECTION_READ_ONLY'
        )
        assert.equal(callback_count, 0)
        assert.equal(#fake:get_calls('commit_character_transaction'), 0)
        assert.equal(fake:tick(0).value.processed_deliveries, 0)
        assert.equal(fake:get_apply_count(request.receipt_id), 0)
        assert.deep_equal(fake:get_authority_snapshot(), before)
        assert.equal(
            fake:get_pending_faults()[request.receipt_id],
            'COMMIT_THEN_UNKNOWN'
        )
    end),

    case('constructor rejects hostile metatables without invoking them', function()
        local invoked = 0
        local hostile = setmetatable({}, {
            __index = function()
                invoked = invoked + 1
                return nil
            end,
            __pairs = function()
                invoked = invoked + 1
                return next, {}, nil
            end,
        })
        assert.throws(function()
            FakeCharacterRepository.new(hostile)
        end, 'metatable')
        assert.equal(invoked, 0)

        local hostile_row = setmetatable({
            player_save_scope = 'player001',
        }, {
            __index = function()
                invoked = invoked + 1
                return nil
            end,
            __pairs = function()
                invoked = invoked + 1
                return next, {}, nil
            end,
        })
        assert.throws(function()
            FakeCharacterRepository.new({ players = { hostile_row } })
        end, 'metatable')
        assert.equal(invoked, 0)

        assert.throws(function()
            FakeCharacterRepository.new({ unexpected = true })
        end, 'unknown field')

        local shared_characters = {}
        assert.throws(function()
            FakeCharacterRepository.new({
                players = {
                    {
                        player_save_scope = 'player001',
                        characters = shared_characters,
                    },
                    {
                        player_save_scope = 'player002',
                        characters = shared_characters,
                    },
                },
            })
        end, 'shared table references')
    end),

    case('constructor never treats false options or seed values as missing', function()
        assert.throws(function()
            FakeCharacterRepository.new(false)
        end, 'options must be a table')
        assert.throws(function()
            FakeCharacterRepository.new({ players = false })
        end, 'players must be a dense array')
        assert.throws(function()
            FakeCharacterRepository.new({ commit_faults = false })
        end, 'commit_faults must be a dense array')

        local false_seed_fields = {
            'character_save_revision',
            'receipt_save_revision',
            'characters',
            'isolated',
        }
        local index
        for index = 1, #false_seed_fields do
            local row = {
                player_save_scope = 'player001',
            }
            row[false_seed_fields[index]] = false
            assert.throws(function()
                FakeCharacterRepository.new({ players = { row } })
            end, 'FakeCharacterRepository')
        end
    end),

    case('seeded creation receipts are globally unique and remain reserved', function()
        local seeded_receipt = 'character:create:seed_reserved_receipt_001'
        local first = seed_state(seeded_receipt)
        local second = seed_state(seeded_receipt)
        second.character_id = 'char_companion'
        assert.throws(function()
            FakeCharacterRepository.new({
                players = {
                    {
                        player_save_scope = 'player001',
                        characters = { first },
                    },
                    {
                        player_save_scope = 'player002',
                        characters = { second },
                    },
                },
            })
        end, 'globally unique')

        local fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    characters = { first },
                },
            },
        })
        local request = create_request({
            receipt_id = seeded_receipt,
            character_id = 'char_companion',
            context_suffix = 'seed_receipt_reuse',
        })
        assert.equal(fake:inject_commit_fault(
            request.receipt_id,
            'COMMIT_THEN_UNKNOWN'
        ).ok, true)
        local before = fake:get_authority_snapshot()
        local callback_count = 0
        local rejected = fake:commit_character_transaction(
            request,
            function()
                callback_count = callback_count + 1
            end
        )
        assert.error_code(rejected, 'IDEMPOTENCY_KEY_REUSED')
        assert.deep_equal(rejected.error.details, {
            reason = 'BUSINESS_RECEIPT_IDENTITY_MISMATCH',
            receipt_id = request.receipt_id,
            request_key = request.context.idempotency_key,
        })
        assert.equal(callback_count, 0)
        assert.equal(#fake:get_calls('commit_character_transaction'), 0)
        assert.equal(fake:tick(0).value.processed_deliveries, 0)
        assert.deep_equal(fake:get_authority_snapshot(), before)
        assert.equal(
            fake:get_pending_faults()[request.receipt_id],
            'COMMIT_THEN_UNKNOWN'
        )
    end),

    case('queries bind accepted proofs and receipt owner roles', function()
        local cas_fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 2,
                    receipt_save_revision = 0,
                    characters = {},
                },
            },
        })
        local conflicted = create_request({
            receipt_id = 'character:create:query_proof_receipt_001',
            expected_character_save_revision = 1,
            context_suffix = 'query_proof_conflict',
        })
        assert.error_code(invoke_and_tick(
            cas_fake,
            'commit_character_transaction',
            conflicted
        ), 'SAVE_REVISION_CONFLICT')
        assert.is_nil(
            cas_fake:get_authority_snapshot().receipts[
                conflicted.receipt_id
            ]
        )

        local exact_query = query_request(conflicted, {
            context_suffix = 'query_proof_exact',
        })
        local not_found = invoke_and_tick(
            cas_fake,
            'query_character_transaction',
            exact_query
        )
        assert.equal(not_found.ok, true)
        assert.equal(not_found.value.status, 'NOT_FOUND')

        local mutated_query = query_request(conflicted, {
            context_suffix = 'query_proof_mutated',
        })
        mutated_query.transaction_id = 'query_proof_mutated_tx_001'
        local mutated_rejected = invoke_and_tick(
            cas_fake,
            'query_character_transaction',
            mutated_query
        )
        assert.error_code(mutated_rejected, 'IDEMPOTENCY_KEY_REUSED')
        assert.deep_equal(
            mutated_rejected.error.details,
            query_reuse_details(mutated_query)
        )
        assert.equal(cas_fake:get_apply_count(conflicted.receipt_id), 0)

        local seed = seed_state(
            'character:create:query_owner_seed_receipt_001'
        )
        seed.level = 2
        seed.experience = 100
        seed.revision = 7
        local owner_fake = FakeCharacterRepository.new({
            players = {
                {
                    player_save_scope = 'player001',
                    character_save_revision = 9,
                    receipt_save_revision = 3,
                    characters = { seed },
                },
            },
        })
        local reward = committed_reward_experience_request(
            seed,
            'character:reward:query_owner_reward_001'
        )
        assert.equal(invoke_and_tick(
            owner_fake,
            'commit_character_transaction',
            reward
        ).ok, true)
        local owner_snapshot = owner_fake:get_authority_snapshot()

        local function assert_query_reuse(query)
            assert.equal(CharacterRepository:sanitize_request(
                'query_character_transaction',
                query
            ).ok, true)
            local rejected = invoke_and_tick(
                owner_fake,
                'query_character_transaction',
                query
            )
            assert.error_code(rejected, 'IDEMPOTENCY_KEY_REUSED')
            assert.deep_equal(
                rejected.error.details,
                query_reuse_details(query)
            )
            assert.deep_equal(
                owner_fake:get_authority_snapshot(),
                owner_snapshot
            )
        end

        local forbidden_main_receipts = {
            seed.created_receipt_id,
            reward.result.reward_receipt_id,
        }
        local index
        for index = 1, #forbidden_main_receipts do
            local source = create_request({
                receipt_id = forbidden_main_receipts[index],
                transaction_id = 'query_owner_main_tx_00' .. index,
                character_id = 'char_companion',
                expected_character_save_revision = 10,
                context_suffix = 'query_owner_main_' .. index,
            })
            assert_query_reuse(query_request(source, {
                context_suffix = 'query_owner_main_query_' .. index,
            }))
        end

        local cross_player_source = create_request({
            receipt_id = seed.created_receipt_id,
            transaction_id = 'query_owner_cross_player_tx_001',
            character_id = 'char_companion',
            expected_character_save_revision = 0,
            context_suffix = 'query_owner_cross_player',
        })
        local cross_player = invoke_and_tick(
            owner_fake,
            'query_character_transaction',
            query_request(cross_player_source, {
                player_save_scope = 'player002',
                context_suffix = 'query_owner_cross_player_query',
            })
        )
        assert.equal(cross_player.ok, true)
        assert.equal(cross_player.value.status, 'NOT_FOUND')

        local forbidden_created_receipts = {
            reward.receipt_id,
            reward.result.reward_receipt_id,
        }
        for index = 1, #forbidden_created_receipts do
            local forged_state = seed_state(
                forbidden_created_receipts[index]
            )
            local source = rename_update_request(forged_state)
            source.receipt_id =
                'character:rename:query_owner_created_00' .. index
            source.context = context(
                'query_owner_created_' .. index,
                source.receipt_id
            )
            source.transaction_id =
                'query_owner_created_tx_00' .. index
            assert_query_reuse(query_request(source, {
                context_suffix = 'query_owner_created_query_' .. index,
            }))
        end

        local valid_created_state = seed_state(seed.created_receipt_id)
        local valid_created_source = rename_update_request(
            valid_created_state
        )
        valid_created_source.receipt_id =
            'character:rename:query_owner_valid_created_001'
        valid_created_source.context = context(
            'query_owner_valid_created',
            valid_created_source.receipt_id
        )
        valid_created_source.transaction_id =
            'query_owner_valid_created_tx_001'
        local valid_created = invoke_and_tick(
            owner_fake,
            'query_character_transaction',
            query_request(valid_created_source, {
                context_suffix = 'query_owner_valid_created_query',
            })
        )
        assert.equal(valid_created.ok, true)
        assert.equal(valid_created.value.status, 'NOT_FOUND')
    end),

    case('transaction queries do not cross player boundaries or accept mismatch', function()
        local fake = FakeCharacterRepository.new()
        local request = create_request({
            receipt_id = 'isolation_receipt_001',
        })
        assert.equal(invoke_and_tick(
            fake,
            'commit_character_transaction',
            request
        ).ok, true)

        local other_player = invoke_and_tick(
            fake,
            'query_character_transaction',
            query_request(request, { player_save_scope = 'player002' })
        )
        assert.equal(other_player.ok, true)
        assert.equal(other_player.value.status, 'NOT_FOUND')
        assert.equal(
            other_player.value.expected_character_save_revision,
            request.expected_character_save_revision
        )
        assert.is_nil(other_player.value.result)

        local cross_type_probes = {
            create_request({
                receipt_id = 'isolation_probe_receipt_001',
                transaction_id = request.receipt_id,
                character_id = 'char_probe_1',
                context_suffix = 'isolation_probe_1',
            }),
            create_request({
                receipt_id = request.transaction_id,
                transaction_id = 'isolation_probe_tx_002',
                character_id = 'char_probe_2',
                context_suffix = 'isolation_probe_2',
            }),
            create_request({
                receipt_id = 'isolation_probe_receipt_003',
                transaction_id = request.command_digest,
                character_id = 'char_probe_3',
                context_suffix = 'isolation_probe_3',
            }),
            create_request({
                receipt_id = request.context.idempotency_key,
                transaction_id = 'isolation_probe_tx_004',
                character_id = 'char_probe_4',
                context_suffix = 'isolation_probe_4',
            }),
        }
        local probe_index
        for probe_index = 1, #cross_type_probes do
            local probe = query_request(cross_type_probes[probe_index], {
                player_save_scope = 'player002',
                context_suffix = 'isolation_probe_query_'
                    .. tostring(probe_index),
            })
            local sanitized_probe = CharacterRepository:sanitize_request(
                'query_character_transaction',
                probe
            )
            assert.equal(
                sanitized_probe.ok,
                true,
                'cross-type probe ' .. tostring(probe_index)
                    .. ' failed sanitization: '
                    .. tostring(
                        sanitized_probe.error
                            and sanitized_probe.error.details
                            and sanitized_probe.error.details.reason
                    )
            )
            local hidden = invoke_and_tick(
                fake,
                'query_character_transaction',
                probe
            )
            assert.equal(hidden.ok, true)
            assert.equal(hidden.value.status, 'NOT_FOUND')
        end

        local altered = create_request({
            receipt_id = request.receipt_id,
            source_reference = 'quest_main_999:reward:1',
        })
        local altered_query = query_request(altered)
        local mismatched = invoke_and_tick(
            fake,
            'query_character_transaction',
            altered_query
        )
        assert.error_code(mismatched, 'IDEMPOTENCY_KEY_REUSED')
        assert.deep_equal(
            mismatched.error.details,
            query_reuse_details(altered_query)
        )

        local wrong_result_query = query_request(request, {
            context_suffix = 'query_wrong_result',
            expected_result_digest = string.rep('f', 64),
        })
        wrong_result_query.context.idempotency_key = transport_key(
            'character:query:optional_context_key_001'
        )
        local wrong_result = invoke_and_tick(
            fake,
            'query_character_transaction',
            wrong_result_query
        )
        assert.error_code(wrong_result, 'IDEMPOTENCY_KEY_REUSED')
        assert.deep_equal(
            wrong_result.error.details,
            query_reuse_details(wrong_result_query)
        )
        assert.is_nil(wrong_result.error.details.request_key)

        local wrong_expected_revision_query = query_request(request, {
            context_suffix = 'query_wrong_expected_revision',
            expected_character_save_revision =
                request.expected_character_save_revision + 1,
        })
        local cross_query_replay = CharacterRepository:validate_result(
            'query_character_transaction',
            wrong_result,
            wrong_expected_revision_query,
            'COMPLETION'
        )
        assert.error_code(cross_query_replay, 'PORT_RESULT_INVALID')
        local wrong_expected_revision = invoke_and_tick(
            fake,
            'query_character_transaction',
            wrong_expected_revision_query
        )
        assert.error_code(
            wrong_expected_revision,
            'IDEMPOTENCY_KEY_REUSED'
        )
        assert.deep_equal(
            wrong_expected_revision.error.details,
            query_reuse_details(wrong_expected_revision_query)
        )

        local cross_typed_source = create_request({
            receipt_id = 'character:create:query_collision_receipt_001',
            transaction_id = request.context.idempotency_key,
            character_id = 'char_companion',
            expected_character_save_revision = 1,
            context_suffix = 'query_cross_typed_history',
        })
        local cross_typed_query = query_request(cross_typed_source)
        local before_cross_typed_query = fake:get_authority_snapshot()
        local cross_typed_rejected = invoke_and_tick(
            fake,
            'query_character_transaction',
            cross_typed_query
        )
        assert.error_code(
            cross_typed_rejected,
            'IDEMPOTENCY_KEY_REUSED'
        )
        assert.deep_equal(
            cross_typed_rejected.error.details,
            query_reuse_details(cross_typed_query)
        )
        assert.deep_equal(
            fake:get_authority_snapshot(),
            before_cross_typed_query
        )

        local forged_query_state = seed_state(request.result_digest)
        local forged_query_source = rename_update_request(
            forged_query_state
        )
        forged_query_source.receipt_id =
            'character:rename:query_created_reuses_digest_001'
        forged_query_source.context = context(
            'query_created_reuses_digest',
            forged_query_source.receipt_id
        )
        forged_query_source.transaction_id =
            'query_created_reuses_digest_tx_001'
        local forged_created_query = query_request(
            forged_query_source,
            { context_suffix = 'query_created_digest_collision' }
        )
        assert.equal(
            CharacterRepository:sanitize_request(
                'query_character_transaction',
                forged_created_query
            ).ok,
            true
        )
        local forged_created_rejected = invoke_and_tick(
            fake,
            'query_character_transaction',
            forged_created_query
        )
        assert.error_code(
            forged_created_rejected,
            'IDEMPOTENCY_KEY_REUSED'
        )
        assert.deep_equal(
            forged_created_rejected.error.details,
            query_reuse_details(forged_created_query)
        )

        local unbound_source = create_request({
            receipt_id = 'character:create:query_unbound_receipt_001',
            character_id = 'char_companion',
            expected_character_save_revision = 1,
            context_suffix = 'query_unbound_history',
        })
        local unbound_query = query_request(unbound_source)
        local not_found = invoke_and_tick(
            fake,
            'query_character_transaction',
            unbound_query
        )
        assert.equal(not_found.ok, true)
        assert.equal(not_found.value.status, 'NOT_FOUND')

        local after_query_commit = create_request({
            receipt_id = 'character:create:after_query_receipt_001',
            transaction_id = unbound_query.original_request_key,
            character_id = 'char_companion',
            expected_character_save_revision = 1,
            context_suffix = 'after_query_identity',
        })
        assert.equal(invoke_and_tick(
            fake,
            'commit_character_transaction',
            after_query_commit
        ).ok, true)
        assert.equal(
            fake:get_apply_count(after_query_commit.receipt_id),
            1
        )
        assert.equal(fake:get_apply_count(request.receipt_id), 1)
    end),
}
