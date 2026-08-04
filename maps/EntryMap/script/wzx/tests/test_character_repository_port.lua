local CanonicalReceiptHashV1 = require 'wzx.domain.common.canonical_receipt_hash_v1'
local CharacterReceiptCodec = require 'wzx.domain.character.character_receipt_codec'
local CharacterRepository = require 'wzx.application.ports.character_repository'
local Harness = require 'wzx.tests.harness'
local PortContract = require 'wzx.application.ports.port_contract'
local RuntimeId = require 'wzx.domain.common.runtime_id'
local TalentListDigest = require 'wzx.domain.character.talent_list_digest'
local Utf8Text = require 'wzx.domain.character.utf8_text'

local case = Harness.case
local assert = Harness.assert

local CREATE = 'CREATE_OWNED_CHARACTER'
local EXPERIENCE = 'GRANT_CHARACTER_EXPERIENCE'
local RENAME = 'RENAME_PROTAGONIST'
local ZERO_DIGEST = string.rep('0', 64)
local WUZHOU_HERO_UTF8 = string.char(
    0xe9, 0x9b, 0xbe,
    0xe5, 0xb7, 0x9e,
    0xe4, 0xbe, 0xa0
)

local TRANSPORT_SPEC = {
    { name = 'receipt_id', type = 'STRING' },
}

local COMMAND_SPECS = {
    [CREATE] = {
        namespace = 'character_create_owned_command',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'source_type', type = 'STRING' },
            { name = 'source_reference', type = 'STRING' },
        },
    },
    [EXPERIENCE] = {
        namespace = 'character_grant_experience_command',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'created_receipt_id', type = 'STRING' },
            { name = 'amount', type = 'INTEGER' },
            { name = 'reason', type = 'STRING' },
            { name = 'expected_revision', type = 'INTEGER' },
            { name = 'reward_ref_count', type = 'INTEGER' },
            { name = 'reward_plan_digest', type = 'STRING' },
        },
    },
    [RENAME] = {
        namespace = 'character_rename_protagonist_command',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'created_receipt_id', type = 'STRING' },
            { name = 'new_name', type = 'STRING' },
            { name = 'expected_revision', type = 'INTEGER' },
        },
    },
}

local RESULT_SPECS = {
    [CREATE] = {
        namespace = 'character_create_owned_result',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'already_owned', type = 'BOOLEAN' },
            { name = 'definition_version', type = 'INTEGER' },
            { name = 'level', type = 'INTEGER' },
            { name = 'experience', type = 'INTEGER' },
            { name = 'unlocked_talent_count', type = 'INTEGER' },
            { name = 'unlocked_talent_digest', type = 'STRING' },
            { name = 'created_receipt_id', type = 'STRING' },
            { name = 'character_revision', type = 'INTEGER' },
        },
    },
    [EXPERIENCE] = {
        namespace = 'character_grant_experience_result',
        fields = {
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
        },
    },
    [RENAME] = {
        namespace = 'character_rename_protagonist_result',
        fields = {
            { name = 'character_id', type = 'STRING' },
            { name = 'new_name', type = 'STRING' },
            { name = 'character_revision', type = 'INTEGER' },
        },
    },
}

local function deep_copy(value, seen)
    if type(value) ~= 'table' then
        return value
    end
    seen = seen or {}
    if seen[value] ~= nil then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    local key
    for key in pairs(value) do
        copy[deep_copy(key, seen)] = deep_copy(value[key], seen)
    end
    return copy
end

local function digest(namespace, fields, values)
    local derived = CanonicalReceiptHashV1.derive(namespace, fields, values)
    assert.equal(derived.ok, true)
    return derived.value.digest
end

local function transport_key(receipt_id)
    return digest(
        'character_repository_idempotency',
        TRANSPORT_SPEC,
        { receipt_id = receipt_id }
    )
end

local function talent_proof(talent_ids)
    local derived = TalentListDigest.derive(talent_ids)
    assert.equal(derived.ok, true)
    return derived.value
end

local function read_context(suffix)
    suffix = suffix or '001'
    return {
        request_id = 'request_' .. suffix,
        correlation_id = 'correlation_' .. suffix,
        attempt = 1,
    }
end

local function mutation_context(receipt_id, suffix)
    local context = read_context(suffix)
    context.idempotency_key = transport_key(receipt_id)
    return context
end

local function command_digest(operation_type, command)
    local spec = COMMAND_SPECS[operation_type]
    return digest(spec.namespace, spec.fields, command)
end

local function result_values(operation_type, result)
    if operation_type == CREATE then
        return {
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
    end
    if operation_type == EXPERIENCE then
        return {
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
    end
    return {
        character_id = result.character_id,
        new_name = result.new_name,
        character_revision = result.character_revision,
    }
end

local function result_digest(operation_type, result)
    local spec = RESULT_SPECS[operation_type]
    return digest(spec.namespace, spec.fields, result_values(operation_type, result))
end

local function state(overrides)
    local value = {
        character_id = 'char_protagonist',
        definition_version = 3,
        level = 2,
        experience = 100,
        awakening_rank = 0,
        unlocked_talent_ids = {
            'talent_alpha',
            'talent_beta',
        },
        created_receipt_id = 'character:create:original_001',
        revision = 7,
    }
    local key
    for key, override in pairs(overrides or {}) do
        value[key] = override
    end
    return value
end

local function create_insert_request()
    local receipt_id = 'character:create:receipt_001'
    local command = {
        character_id = 'char_protagonist',
        source_type = 'QUEST',
        source_reference = 'quest_main_001:reward:1',
    }
    local after_state = state({
        level = 1,
        experience = 0,
        created_receipt_id = receipt_id,
        revision = 0,
    })
    local talents = talent_proof(after_state.unlocked_talent_ids)
    local result = {
        operation_type = CREATE,
        character_id = after_state.character_id,
        already_owned = false,
        definition_version = after_state.definition_version,
        level = after_state.level,
        experience = after_state.experience,
        unlocked_talent_count = talents.count,
        unlocked_talent_digest = talents.digest,
        created_receipt_id = after_state.created_receipt_id,
        character_revision = after_state.revision,
    }
    local request = {
        context = mutation_context(receipt_id, 'create_insert'),
        player_save_scope = 'player001',
        operation_type = CREATE,
        receipt_id = receipt_id,
        command_digest = command_digest(CREATE, command),
        expected_character_save_revision = 0,
        change_type = 'INSERT',
        command = command,
        after_state = after_state,
        result_digest = result_digest(CREATE, result),
        result = result,
    }
    request.transaction_id = 'character_create_insert_tx_001'
    return request
end

local function create_no_change_request()
    local receipt_id = 'character:create:receipt_002'
    local command = {
        character_id = 'char_protagonist',
        source_type = 'QUEST',
        source_reference = 'quest_main_002:reward:1',
    }
    local before_state = state()
    local talents = talent_proof(before_state.unlocked_talent_ids)
    local result = {
        operation_type = CREATE,
        character_id = before_state.character_id,
        already_owned = true,
        definition_version = before_state.definition_version,
        level = before_state.level,
        experience = before_state.experience,
        unlocked_talent_count = talents.count,
        unlocked_talent_digest = talents.digest,
        created_receipt_id = before_state.created_receipt_id,
        character_revision = before_state.revision,
    }
    local request = {
        context = mutation_context(receipt_id, 'create_existing'),
        player_save_scope = 'player001',
        operation_type = CREATE,
        receipt_id = receipt_id,
        command_digest = command_digest(CREATE, command),
        expected_character_save_revision = 9,
        change_type = 'NO_CHANGE',
        command = command,
        before_state = before_state,
        result_digest = result_digest(CREATE, result),
        result = result,
    }
    request.transaction_id = 'character_create_existing_tx_001'
    return request
end

local function experience_request(level_increase, planned_reward_count)
    local receipt_id = level_increase
        and 'character:experience:receipt_level_001'
        or 'character:experience:receipt_001'
    local before_state = state()
    local amount = level_increase and 200 or 50
    local after_state = state({
        level = level_increase and 3 or 2,
        experience = before_state.experience + amount,
        revision = before_state.revision + 1,
    })
    local command = {
        character_id = before_state.character_id,
        created_receipt_id = before_state.created_receipt_id,
        amount = amount,
        reason = 'QUEST_REWARD',
        expected_revision = before_state.revision,
        reward_ref_count = planned_reward_count == nil
            and (level_increase and 1 or 0)
            or planned_reward_count,
        reward_plan_digest = (planned_reward_count == nil
                and level_increase
                or planned_reward_count ~= nil and planned_reward_count > 0)
            and string.rep('b', 64)
            or ZERO_DIGEST,
    }
    local reward_required = command.reward_ref_count > 0
    local result = {
        operation_type = EXPERIENCE,
        character_id = before_state.character_id,
        amount = amount,
        reason = command.reason,
        old_experience = before_state.experience,
        new_experience = after_state.experience,
        old_level = before_state.level,
        new_level = after_state.level,
        character_revision = after_state.revision,
        reward_status = reward_required and 'COMMITTED' or 'NOT_REQUIRED',
        reward_receipt_id = reward_required
            and 'character:level_reward:receipt_001'
            or 'none',
        reward_result_digest = reward_required and string.rep('a', 64)
            or ZERO_DIGEST,
    }
    local request = {
        context = mutation_context(receipt_id, 'experience'),
        player_save_scope = 'player001',
        operation_type = EXPERIENCE,
        receipt_id = receipt_id,
        command_digest = command_digest(EXPERIENCE, command),
        expected_character_save_revision = 9,
        change_type = 'UPDATE',
        command = command,
        before_state = before_state,
        after_state = after_state,
        result_digest = result_digest(EXPERIENCE, result),
        result = result,
    }
    request.transaction_id = level_increase
        and 'character_experience_level_tx_001'
        or 'character_experience_tx_001'
    return request
end

local function rename_request()
    local receipt_id = 'character:rename:receipt_001'
    local before_state = state({ custom_name = '旧名' })
    local after_state = state({
        custom_name = '新名',
        revision = before_state.revision + 1,
    })
    local command = {
        character_id = before_state.character_id,
        created_receipt_id = before_state.created_receipt_id,
        new_name = after_state.custom_name,
        expected_revision = before_state.revision,
    }
    local result = {
        operation_type = RENAME,
        character_id = after_state.character_id,
        new_name = after_state.custom_name,
        character_revision = after_state.revision,
    }
    local request = {
        context = mutation_context(receipt_id, 'rename'),
        player_save_scope = 'player001',
        operation_type = RENAME,
        receipt_id = receipt_id,
        command_digest = command_digest(RENAME, command),
        expected_character_save_revision = 9,
        change_type = 'UPDATE',
        command = command,
        before_state = before_state,
        after_state = after_state,
        result_digest = result_digest(RENAME, result),
        result = result,
    }
    request.transaction_id = 'character_rename_tx_001'
    return request
end

local function commit_success(request)
    local character_save_revision = request.expected_character_save_revision
    if request.change_type ~= 'NO_CHANGE' then
        character_save_revision = character_save_revision + 1
    end
    return {
        status = 'COMMITTED',
        player_save_scope = request.player_save_scope,
        request_key = request.context.idempotency_key,
        receipt_id = request.receipt_id,
        transaction_id = request.transaction_id,
        operation_type = request.operation_type,
        command_digest = request.command_digest,
        character_save_revision = character_save_revision,
        receipt_save_revision = 12,
        character_revision = request.result.character_revision,
        result_digest = request.result_digest,
        result = deep_copy(request.result),
    }
end

local function query_request(commit_request)
    return {
        context = read_context('query'),
        player_save_scope = commit_request.player_save_scope,
        original_request_key = commit_request.context.idempotency_key,
        receipt_id = commit_request.receipt_id,
        transaction_id = commit_request.transaction_id,
        operation_type = commit_request.operation_type,
        command_digest = commit_request.command_digest,
        expected_result_digest = commit_request.result_digest,
        expected_character_save_revision =
            commit_request.expected_character_save_revision,
        command = deep_copy(commit_request.command),
    }
end

local function query_value(request, status, committed_request)
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
        local committed = commit_success(committed_request)
        value.character_save_revision = committed.character_save_revision
        value.receipt_save_revision = committed.receipt_save_revision
        value.character_revision = committed.character_revision
        value.result_digest = committed.result_digest
        value.result = committed.result
    end
    return value
end

local function assert_request_ok(operation, request)
    local checked = CharacterRepository:validate_request(operation, request)
    assert.equal(checked.ok, true)
end

local function assert_request_invalid(operation, request)
    local checked = CharacterRepository:validate_request(operation, request)
    assert.error_code(checked, 'PORT_REQUEST_INVALID')
end

local function assert_success_ok(operation, value, request)
    local checked = CharacterRepository:validate_result(
        operation,
        PortContract.ok(value),
        request
    )
    assert.equal(checked.ok, true)
end

local function assert_success_invalid(operation, value, request)
    local checked = CharacterRepository:validate_result(
        operation,
        PortContract.ok(value),
        request
    )
    assert.error_code(checked, 'PORT_RESULT_INVALID')
end

return {
    case('character repository exposes three exact protected operations', function()
        assert.equal(CharacterRepository.name, 'CharacterRepository')
        assert.equal(CharacterRepository.contract_version, 1)
        assert.equal(#CharacterRepository.operations, 3)
        assert.deep_equal({
            CharacterRepository.operations[1].name,
            CharacterRepository.operations[2].name,
            CharacterRepository.operations[3].name,
        }, {
            'load_character',
            'commit_character_transaction',
            'query_character_transaction',
        })

        local load = CharacterRepository:get_operation('load_character')
        local commit = CharacterRepository:get_operation(
            'commit_character_transaction'
        )
        local query = CharacterRepository:get_operation(
            'query_character_transaction'
        )
        assert.not_nil(load)
        assert.not_nil(commit)
        assert.not_nil(query)
        assert.equal(load.mutating, false)
        assert.equal(load.requires_idempotency, false)
        assert.equal(commit.mutating, true)
        assert.equal(commit.requires_idempotency, true)
        assert.equal(query.mutating, false)
        assert.equal(query.requires_idempotency, false)
        assert.deep_equal(load.request_fields, {
            'player_save_scope',
            'character_id',
        })
        assert.deep_equal(commit.request_fields, {
            'player_save_scope',
            'operation_type',
            'receipt_id',
            'transaction_id',
            'command_digest',
            'expected_character_save_revision',
            'change_type',
            'command',
            'before_state',
            'after_state',
            'result_digest',
            'result',
        })
        assert.deep_equal(commit.error_codes, {
            'SAVE_REVISION_CONFLICT',
            'SAVE_READ_ONLY',
            'TRANSACTION_RECOVERY_REQUIRED',
        })
        assert.deep_equal(query.request_fields, {
            'player_save_scope',
            'original_request_key',
            'receipt_id',
            'transaction_id',
            'operation_type',
            'command_digest',
            'expected_result_digest',
            'expected_character_save_revision',
            'command',
        })
        assert.is_nil(CharacterRepository:get_operation('unknown_operation'))
        commit.request_fields[1] = 'tampered'
        assert.equal(
            CharacterRepository:get_operation(
                'commit_character_transaction'
            ).request_fields[1],
            'player_save_scope'
        )
        assert.throws(function()
            CharacterRepository.name = 'mutated'
        end, 'read-only')
        assert.throws(function()
            CharacterRepository.validate_request = function()
            end
        end, 'read-only')
    end),

    case('character command and transport golden vectors are frozen', function()
        assert.deep_equal(
            talent_proof({ 'talent_alpha', 'talent_beta' }),
            {
                count = 2,
                digest = '6b73a7def3f83d6567df159a2b2ea42780303c471df77d777e00da797f33c59f',
            }
        )
        assert.equal(command_digest(CREATE, {
            character_id = 'char_protagonist',
            source_type = 'QUEST',
            source_reference = 'quest_main_001:reward:1',
        }), '9e9fbc4fe3b334f2c6e1ca50bcd6cd61aba0834de7a7b16bb9b804e238d8c251')
        assert.equal(command_digest(EXPERIENCE, {
            character_id = 'char_protagonist',
            created_receipt_id = 'character:create:original_001',
            amount = 1250,
            reason = 'QUEST_REWARD',
            expected_revision = 7,
            reward_ref_count = 0,
            reward_plan_digest = ZERO_DIGEST,
        }), 'e61dd655ad94e841e78096baf9b41a5d82c515c6e44406bbe03ff3f72ac6cc30')
        assert.equal(command_digest(RENAME, {
            character_id = 'char_protagonist',
            created_receipt_id = 'character:create:original_001',
            new_name = WUZHOU_HERO_UTF8,
            expected_revision = 7,
        }), '3aa228707e4cb550049ff4c212ce8ef80184dd591079f30e05e3293ec6dc0eca')
        assert.equal(
            transport_key('character:create:receipt_001'),
            'e2182dd381e7fd04fd033e0ecf75c15c295d96fa0843fce9ca6c7a090054dae1'
        )
        assert.equal(result_digest(CREATE, {
            operation_type = CREATE,
            character_id = 'char_protagonist',
            already_owned = false,
            definition_version = 3,
            level = 1,
            experience = 0,
            unlocked_talent_count = 2,
            unlocked_talent_digest =
                '6b73a7def3f83d6567df159a2b2ea42780303c471df77d777e00da797f33c59f',
            created_receipt_id = 'character:create:receipt_001',
            character_revision = 0,
        }), '31d0259e31bbc6e0d18bba90d8936805872a07b7ed6bc4c3d809924bc62babe2')
        assert.equal(result_digest(EXPERIENCE, {
            operation_type = EXPERIENCE,
            character_id = 'char_protagonist',
            amount = 50,
            reason = 'QUEST_REWARD',
            old_experience = 100,
            new_experience = 150,
            old_level = 2,
            new_level = 2,
            character_revision = 8,
            reward_status = 'NOT_REQUIRED',
            reward_receipt_id = 'none',
            reward_result_digest = ZERO_DIGEST,
        }), '8cd8122a8b74728873659b8091d36946a22af7d8a5d9e2e01e54830509935a4b')
        assert.equal(result_digest(RENAME, {
            operation_type = RENAME,
            character_id = 'char_protagonist',
            new_name = WUZHOU_HERO_UTF8,
            character_revision = 8,
        }), '0c4a183f6634b186c17beee7ca26fcc5866ce1451b74e4e6e96ac535ff446930')
    end),

    case('talent list proofs require one canonical ordered talent set', function()
        assert.deep_equal(TalentListDigest.derive({}).value, {
            count = 0,
            digest =
                'b68990fe11e1ef2350c573fcc7c5bef92c6c0c221081e2de25fc91ca8f954d1b',
        })
        assert.error_reason(
            TalentListDigest.derive({ 'talent_beta', 'talent_alpha' }),
            'STRICT_ASCENDING_ORDER_REQUIRED'
        )
        assert.error_reason(
            TalentListDigest.derive({ 'talent_alpha', 'talent_alpha' }),
            'STRICT_ASCENDING_ORDER_REQUIRED'
        )
        assert.error_reason(
            TalentListDigest.derive({ 'char_alpha' }),
            'TALENT_ID_INVALID'
        )
        assert.error_reason(
            TalentListDigest.derive({ [1] = 'talent_alpha', [3] = 'talent_beta' }),
            'PLAIN_DENSE_ARRAY_REQUIRED'
        )
        assert.error_reason(
            TalentListDigest.derive(setmetatable({ 'talent_alpha' }, {})),
            'PLAIN_DENSE_ARRAY_REQUIRED'
        )
    end),

    case('load validates found missing and isolated exact unions', function()
        local request = {
            context = read_context('load'),
            player_save_scope = 'player001',
            character_id = 'char_protagonist',
        }
        assert_request_ok('load_character', request)
        assert_success_ok('load_character', {
            status = 'FOUND',
            player_save_scope = request.player_save_scope,
            character_id = request.character_id,
            character_save_revision = 9,
            state = state(),
        }, request)
        assert_success_ok('load_character', {
            status = 'NOT_FOUND',
            player_save_scope = request.player_save_scope,
            character_id = request.character_id,
            character_save_revision = 9,
        }, request)
        assert_success_ok('load_character', {
            status = 'READ_ONLY_ISOLATED',
            player_save_scope = request.player_save_scope,
            character_id = request.character_id,
            character_save_revision = 9,
            issue_codes = {
                'CHARACTER_CONFIG_MISSING',
                'CHARACTER_DEFINITION_VERSION_MIGRATION_REQUIRED',
                'CHARACTER_DEFINITION_VERSION_UNAVAILABLE',
                'CHARACTER_TALENT_CONFIG_MISSING',
            },
        }, request)

        local leaked = {
            status = 'READ_ONLY_ISOLATED',
            player_save_scope = request.player_save_scope,
            character_id = request.character_id,
            character_save_revision = 9,
            issue_codes = { 'CHARACTER_CONFIG_MISSING' },
            state = state(),
        }
        assert_success_invalid('load_character', leaked, request)

        local invalid_issue = {
            status = 'READ_ONLY_ISOLATED',
            player_save_scope = request.player_save_scope,
            character_id = request.character_id,
            character_save_revision = 9,
            issue_codes = { 'CHARACTER_UNKNOWN_ID' },
        }
        assert_success_invalid('load_character', invalid_issue, request)
        invalid_issue.issue_codes = { 'SAVE_ENVELOPE_INVALID' }
        assert_success_invalid('load_character', invalid_issue, request)
    end),

    case('load rejects mismatched and structurally unsafe state', function()
        local request = {
            context = read_context('load_invalid'),
            player_save_scope = 'player001',
            character_id = 'char_protagonist',
        }
        local value = {
            status = 'FOUND',
            player_save_scope = request.player_save_scope,
            character_id = request.character_id,
            character_save_revision = 9,
            state = state(),
        }
        value.state.unlocked_talent_ids = {
            'talent_beta',
            'talent_alpha',
        }
        assert_success_invalid('load_character', value, request)

        value.state = state({ revision = 10 })
        assert_success_invalid('load_character', value, request)
        value.state = state()
        value.character_id = 'char_other'
        assert_success_invalid('load_character', value, request)
    end),

    case('commit accepts create insert and already-owned no-change', function()
        local insert = create_insert_request()
        local no_change = create_no_change_request()
        assert_request_ok('commit_character_transaction', insert)
        assert_request_ok('commit_character_transaction', no_change)
        assert_success_ok(
            'commit_character_transaction',
            commit_success(insert),
            insert
        )
        assert_success_ok(
            'commit_character_transaction',
            commit_success(no_change),
            no_change
        )
        local no_change_result = commit_success(no_change)
        assert.equal(
            no_change_result.character_save_revision,
            no_change.expected_character_save_revision
        )
        assert.equal(no_change_result.receipt_save_revision, 12)
    end),

    case('commit accepts bounded experience and rename updates', function()
        local experience = experience_request(false)
        local level_up = experience_request(true)
        local level_up_without_rewards = experience_request(true, 0)
        local rename = rename_request()
        assert_request_ok('commit_character_transaction', experience)
        assert_request_ok('commit_character_transaction', level_up)
        assert_request_ok(
            'commit_character_transaction',
            level_up_without_rewards
        )
        assert_request_ok('commit_character_transaction', rename)
        assert_success_ok(
            'commit_character_transaction',
            commit_success(experience),
            experience
        )
        assert_success_ok(
            'commit_character_transaction',
            commit_success(rename),
            rename
        )
        assert_success_ok(
            'commit_character_transaction',
            commit_success(level_up_without_rewards),
            level_up_without_rewards
        )
    end),

    case('commit accepts atomic transaction ids and rejects malformed ids', function()
        local request = create_insert_request()
        request.context.idempotency_key = 'wrong_key'
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.transaction_id = 'coordinator_atomic_tx_987'
        assert_request_ok('commit_character_transaction', request)

        request = create_insert_request()
        request.transaction_id = 'T' .. string.rep('a', 63)
        assert_request_ok('commit_character_transaction', request)

        request = create_insert_request()
        request.transaction_id = request.context.idempotency_key
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.transaction_id = request.command_digest
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.transaction_id = request.result_digest
        assert_request_invalid('commit_character_transaction', request)

        request = rename_request()
        request.receipt_id = request.command_digest
        request.context.idempotency_key = transport_key(request.receipt_id)
        assert_request_invalid('commit_character_transaction', request)

        request = rename_request()
        request.receipt_id = request.result_digest
        request.context.idempotency_key = transport_key(request.receipt_id)
        assert_request_invalid('commit_character_transaction', request)

        request = rename_request()
        request.before_state.created_receipt_id = request.result_digest
        request.after_state.created_receipt_id = request.result_digest
        request.command.created_receipt_id = request.result_digest
        request.command_digest = command_digest(RENAME, request.command)
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.transaction_id = 'T' .. string.rep('a', 64)
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.transaction_id = 'character_tx:' .. string.rep('f', 64)
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.command_digest = string.rep('b', 64)
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.command.extra = true
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.receipt_id = 'none'
        request.context.idempotency_key = transport_key(request.receipt_id)
        assert_request_invalid('commit_character_transaction', request)

        request = create_no_change_request()
        request.before_state.created_receipt_id = 'none'
        request.result.created_receipt_id = 'none'
        request.result_digest = result_digest(CREATE, request.result)
        assert_request_invalid('commit_character_transaction', request)

        request = rename_request()
        request.command.new_name = '被篡改'
        assert_request_invalid('commit_character_transaction', request)
    end),

    case('commit rejects invalid change matrices and forbidden state changes', function()
        local request = create_insert_request()
        request.before_state = state()
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.after_state.unlocked_talent_ids = {
            'talent_alpha',
            'talent_backdoor',
        }
        assert_request_invalid('commit_character_transaction', request)

        request = create_no_change_request()
        request.after_state = deep_copy(request.before_state)
        assert_request_invalid('commit_character_transaction', request)

        request = create_no_change_request()
        request.before_state.created_receipt_id = request.receipt_id
        request.result.created_receipt_id = request.receipt_id
        request.result_digest = result_digest(CREATE, request.result)
        assert_request_invalid('commit_character_transaction', request)

        local no_change_identity_fields = {
            'transaction_id',
            'command_digest',
        }
        local identity_index
        for identity_index = 1, #no_change_identity_fields do
            request = create_no_change_request()
            local identity = request[no_change_identity_fields[identity_index]]
            request.before_state.created_receipt_id = identity
            request.result.created_receipt_id = identity
            request.result_digest = result_digest(CREATE, request.result)
            assert_request_invalid('commit_character_transaction', request)
        end

        request = create_no_change_request()
        local no_change_transport = request.context.idempotency_key
        request.before_state.created_receipt_id = no_change_transport
        request.result.created_receipt_id = no_change_transport
        request.result_digest = result_digest(CREATE, request.result)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(false)
        request.after_state.unlocked_talent_ids = { 'talent_changed' }
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(true, 2)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(false)
        request.receipt_id = request.before_state.created_receipt_id
        request.context.idempotency_key = transport_key(request.receipt_id)
        assert_request_invalid('commit_character_transaction', request)

        request = rename_request()
        request.receipt_id = request.before_state.created_receipt_id
        request.context.idempotency_key = transport_key(request.receipt_id)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(false)
        request.after_state.created_receipt_id = 'character:create:tampered'
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(false)
        request.command.created_receipt_id = 'character:create:other_001'
        request.command_digest = command_digest(EXPERIENCE, request.command)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(false)
        request.before_state.created_receipt_id = request.transaction_id
        request.after_state.created_receipt_id = request.transaction_id
        request.command.created_receipt_id = request.transaction_id
        request.command_digest = command_digest(EXPERIENCE, request.command)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(false)
        local transport_identity = request.context.idempotency_key
        request.before_state.created_receipt_id = transport_identity
        request.after_state.created_receipt_id = transport_identity
        request.command.created_receipt_id = transport_identity
        request.command_digest = command_digest(EXPERIENCE, request.command)
        assert_request_invalid('commit_character_transaction', request)

        request = rename_request()
        request.after_state.experience = request.after_state.experience + 1
        assert_request_invalid('commit_character_transaction', request)

        request = rename_request()
        request.command.new_name = request.before_state.custom_name
        request.command_digest = command_digest(RENAME, request.command)
        request.after_state.custom_name = request.before_state.custom_name
        request.result.new_name = request.before_state.custom_name
        request.result_digest = result_digest(RENAME, request.result)
        assert_request_invalid('commit_character_transaction', request)
    end),

    case('commit rejects result and reward binding tampering', function()
        local request = experience_request(false)
        request.result_digest = string.rep('c', 64)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(true)
        request.result.reward_status = 'NOT_REQUIRED'
        request.result.reward_receipt_id = 'none'
        request.result.reward_result_digest = ZERO_DIGEST
        request.result_digest = result_digest(EXPERIENCE, request.result)
        assert_request_invalid('commit_character_transaction', request)

        request = create_insert_request()
        request.result.already_owned = true
        request.result_digest = result_digest(CREATE, request.result)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(true)
        request.result.reward_receipt_id = request.receipt_id
        request.result_digest = result_digest(EXPERIENCE, request.result)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(true)
        request.result.reward_receipt_id = request.before_state.created_receipt_id
        request.result_digest = result_digest(EXPERIENCE, request.result)
        assert_request_invalid('commit_character_transaction', request)

        local reused_identities = {
            function(value)
                return value.context.idempotency_key
            end,
            function(value)
                return value.transaction_id
            end,
            function(value)
                return value.command_digest
            end,
        }
        local index
        for index = 1, #reused_identities do
            request = experience_request(true)
            request.result.reward_receipt_id = reused_identities[index](request)
            request.result_digest = result_digest(EXPERIENCE, request.result)
            assert_request_invalid('commit_character_transaction', request)
        end

        request = experience_request(true)
        request.result.reward_receipt_id = request.command.reward_plan_digest
        request.result_digest = result_digest(EXPERIENCE, request.result)
        assert_request_invalid('commit_character_transaction', request)

        local nested_digests = {
            function(value)
                return value.command.reward_plan_digest
            end,
            function(value)
                return value.result.reward_result_digest
            end,
        }
        for index = 1, #nested_digests do
            request = experience_request(true)
            local nested_digest = nested_digests[index](request)
            request.receipt_id = nested_digest
            request.context.idempotency_key = transport_key(nested_digest)
            assert_request_invalid('commit_character_transaction', request)

            request = experience_request(true)
            request.transaction_id = nested_digests[index](request)
            assert_request_invalid('commit_character_transaction', request)
        end

        request = experience_request(true)
        local plan_digest = request.command.reward_plan_digest
        request.before_state.created_receipt_id = plan_digest
        request.after_state.created_receipt_id = plan_digest
        request.command.created_receipt_id = plan_digest
        request.command_digest = command_digest(EXPERIENCE, request.command)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(false, 1)
        assert_request_invalid('commit_character_transaction', request)

        request = experience_request(false)
        request.command.reward_plan_digest = string.rep('b', 64)
        request.command_digest = command_digest(EXPERIENCE, request.command)
        assert_request_invalid('commit_character_transaction', request)
    end),

    case('experience top-level and nested digest roles stay separate', function()
        local request_mutations = {
            function(request)
                request.result.reward_result_digest = request.command_digest
                request.result_digest = result_digest(EXPERIENCE, request.result)
            end,
            function(request)
                request.command.reward_plan_digest = request.result_digest
                request.command_digest = command_digest(
                    EXPERIENCE,
                    request.command
                )
            end,
            function(request)
                request.command.reward_plan_digest =
                    request.result.reward_result_digest
                request.command_digest = command_digest(
                    EXPERIENCE,
                    request.command
                )
            end,
        }
        local index
        for index = 1, #request_mutations do
            local request = experience_request(true)
            request_mutations[index](request)
            assert_request_invalid('commit_character_transaction', request)
        end

        local committed_request = experience_request(true)
        local query = query_request(committed_request)
        query.command.reward_plan_digest = query.expected_result_digest
        query.command_digest = command_digest(EXPERIENCE, query.command)
        assert_request_invalid('query_character_transaction', query)

        local value = commit_success(committed_request)
        value.result.reward_result_digest = value.command_digest
        value.result_digest = result_digest(EXPERIENCE, value.result)
        assert_success_invalid('commit_character_transaction', value, nil)

        query = query_request(committed_request)
        value = query_value(query, 'COMMITTED', committed_request)
        value.result.reward_result_digest = value.command_digest
        value.result_digest = result_digest(EXPERIENCE, value.result)
        value.expected_result_digest = value.result_digest
        assert_success_invalid('query_character_transaction', value, nil)
    end),

    case('commit success binds every identity and rejects dynamic replay fields', function()
        local request = create_insert_request()
        local value = commit_success(request)
        value.request_key = 'wrong_key'
        assert_success_invalid('commit_character_transaction', value, request)

        value = commit_success(request)
        value.transaction_id = 'other_atomic_tx_001'
        assert_success_invalid('commit_character_transaction', value, request)

        value = commit_success(request)
        value.replayed = true
        assert_success_invalid('commit_character_transaction', value, request)

        value = commit_success(request)
        value.result.level = value.result.level + 1
        assert_success_invalid('commit_character_transaction', value, request)

        value = commit_success(request)
        value.character_save_revision = value.character_save_revision + 1
        assert_success_invalid('commit_character_transaction', value, request)

        local reward_request = experience_request(true)
        value = commit_success(reward_request)
        value.result.reward_receipt_id = value.request_key
        value.result_digest = result_digest(EXPERIENCE, value.result)
        assert_success_invalid('commit_character_transaction', value, nil)
    end),

    case('query validates all recovery states and committed replay', function()
        local commit_request = experience_request(false)
        local request = query_request(commit_request)
        assert_request_ok('query_character_transaction', request)
        local statuses = {
            'PREPARING',
            'PREPARED',
            'APPLYING',
            'UNKNOWN',
            'COMMITTED',
            'RECOVERY_REQUIRED',
            'COMPENSATED',
            'FAILED_BEFORE_APPLY',
            'NOT_FOUND',
        }
        local index
        for index = 1, #statuses do
            assert_success_ok(
                'query_character_transaction',
                query_value(request, statuses[index], commit_request),
                request
            )
        end

        local non_committed_identity_reuse = {
            function(value)
                value.receipt_id = value.command_digest
            end,
            function(value)
                value.receipt_id = value.expected_result_digest
            end,
            function(value)
                value.original_request_key = value.command_digest
            end,
            function(value)
                value.original_request_key = value.expected_result_digest
            end,
            function(value)
                value.command_digest = value.expected_result_digest
            end,
        }
        for index = 1, #non_committed_identity_reuse do
            local value = query_value(request, 'NOT_FOUND', commit_request)
            non_committed_identity_reuse[index](value)
            assert_success_invalid(
                'query_character_transaction',
                value,
                nil
            )
        end
    end),

    case('query closes create result semantics after digest recomputation', function()
        local commit_request = create_insert_request()
        local request = query_request(commit_request)
        local mutations = {
            function(value)
                value.result.level = 10
            end,
            function(value)
                value.result.experience = 999
            end,
            function(value)
                value.result.character_revision = 1
                value.character_revision = 1
            end,
            function(value)
                value.result.created_receipt_id = 'character:create:forged_001'
            end,
        }
        local index
        for index = 1, #mutations do
            local value = query_value(request, 'COMMITTED', commit_request)
            mutations[index](value)
            value.result_digest = result_digest(CREATE, value.result)
            assert_success_invalid('query_character_transaction', value, request)
        end

        commit_request = create_no_change_request()
        request = query_request(commit_request)
        local value = query_value(request, 'COMMITTED', commit_request)
        assert_success_ok('query_character_transaction', value, request)
        value.result.created_receipt_id = request.receipt_id
        value.result_digest = result_digest(CREATE, value.result)
        assert_success_invalid('query_character_transaction', value, request)

        local historical_identity_reuse = {
            function(query)
                return query.original_request_key
            end,
            function(query)
                return query.transaction_id
            end,
            function(query)
                return query.command_digest
            end,
        }
        local identity_index
        for identity_index = 1, #historical_identity_reuse do
            commit_request = create_no_change_request()
            request = query_request(commit_request)
            value = query_value(request, 'COMMITTED', commit_request)
            value.result.created_receipt_id =
                historical_identity_reuse[identity_index](request)
            value.result_digest = result_digest(CREATE, value.result)
            value.expected_result_digest = value.result_digest
            request.expected_result_digest = value.result_digest
            assert_success_invalid(
                'query_character_transaction',
                value,
                request
            )
        end
    end),

    case('query binds committed experience to the expected result digest', function()
        local commit_request = experience_request(false)
        local request = query_request(commit_request)
        local missing = deep_copy(request)
        missing.expected_result_digest = nil
        assert_request_invalid('query_character_transaction', missing)

        missing = deep_copy(request)
        missing.expected_character_save_revision = nil
        assert_request_invalid('query_character_transaction', missing)

        local value = query_value(request, 'COMMITTED', commit_request)
        value.character_save_revision = 9007199254740991
        assert_success_invalid('query_character_transaction', value, request)

        value = query_value(request, 'COMMITTED', commit_request)
        value.expected_result_digest = string.rep('d', 64)
        assert_success_invalid('query_character_transaction', value, nil)

        value = query_value(request, 'NOT_FOUND', commit_request)
        value.expected_character_save_revision =
            value.expected_character_save_revision + 1
        assert_success_invalid('query_character_transaction', value, request)

        value = query_value(request, 'COMMITTED', commit_request)
        value.result.old_experience = 1000
        value.result.new_experience = 1050
        value.result.old_level = 99
        value.result.new_level = 99
        value.result_digest = result_digest(EXPERIENCE, value.result)
        assert_success_invalid('query_character_transaction', value, request)

        commit_request = experience_request(true, 2)
        request = query_request(commit_request)
        value = query_value(request, 'COMMITTED', commit_request)
        assert_success_invalid('query_character_transaction', value, request)

        local reused_identities = {
            function(query)
                return query.receipt_id
            end,
            function(query)
                return query.command.created_receipt_id
            end,
            function(query)
                return query.original_request_key
            end,
            function(query)
                return query.transaction_id
            end,
            function(query)
                return query.command_digest
            end,
        }
        local index
        for index = 1, #reused_identities do
            commit_request = experience_request(true)
            request = query_request(commit_request)
            value = query_value(request, 'COMMITTED', commit_request)
            value.result.reward_receipt_id = reused_identities[index](request)
            value.result_digest = result_digest(EXPERIENCE, value.result)
            value.expected_result_digest = value.result_digest
            request.expected_result_digest = value.result_digest
            assert_success_invalid(
                'query_character_transaction',
                value,
                request
            )
        end

        commit_request = experience_request(true)
        request = query_request(commit_request)
        local plan_reuse = deep_copy(request)
        plan_reuse.receipt_id = plan_reuse.command.reward_plan_digest
        plan_reuse.original_request_key = transport_key(
            plan_reuse.receipt_id
        )
        assert_request_invalid('query_character_transaction', plan_reuse)

        plan_reuse = deep_copy(request)
        plan_reuse.transaction_id = plan_reuse.command.reward_plan_digest
        assert_request_invalid('query_character_transaction', plan_reuse)

        plan_reuse = deep_copy(request)
        plan_reuse.command.created_receipt_id =
            plan_reuse.command.reward_plan_digest
        plan_reuse.command_digest = command_digest(
            EXPERIENCE,
            plan_reuse.command
        )
        assert_request_invalid('query_character_transaction', plan_reuse)

        request.transaction_id = commit_request.result.reward_result_digest
        value = query_value(request, 'COMMITTED', commit_request)
        value.transaction_id = request.transaction_id
        assert_success_invalid(
            'query_character_transaction',
            value,
            request
        )

        commit_request = experience_request(true)
        request = query_request(commit_request)
        value = query_value(request, 'COMMITTED', commit_request)
        value.result.reward_receipt_id =
            request.command.reward_plan_digest
        value.result_digest = result_digest(EXPERIENCE, value.result)
        value.expected_result_digest = value.result_digest
        request.expected_result_digest = value.result_digest
        assert_success_invalid(
            'query_character_transaction',
            value,
            request
        )

        commit_request = experience_request(false, 1)
        request = query_request(commit_request)
        assert_request_ok('query_character_transaction', request)
        value = query_value(request, 'COMMITTED', commit_request)
        assert_success_invalid('query_character_transaction', value, request)
    end),

    case('query rejects wrong keys echoes and result fields on noncommit states', function()
        local commit_request = rename_request()
        local request = query_request(commit_request)
        local reused_receipt = deep_copy(request)
        reused_receipt.receipt_id = reused_receipt.command_digest
        reused_receipt.original_request_key = transport_key(
            reused_receipt.receipt_id
        )
        assert_request_invalid(
            'query_character_transaction',
            reused_receipt
        )

        reused_receipt = deep_copy(request)
        reused_receipt.receipt_id = reused_receipt.expected_result_digest
        reused_receipt.original_request_key = transport_key(
            reused_receipt.receipt_id
        )
        assert_request_invalid(
            'query_character_transaction',
            reused_receipt
        )

        local wrong = deep_copy(request)
        wrong.original_request_key = 'wrong_key'
        assert_request_invalid('query_character_transaction', wrong)

        wrong = deep_copy(request)
        wrong.transaction_id = 'character_tx:' .. string.rep('f', 64)
        assert_request_invalid('query_character_transaction', wrong)

        wrong = deep_copy(request)
        wrong.transaction_id = wrong.original_request_key
        assert_request_invalid('query_character_transaction', wrong)

        wrong = deep_copy(request)
        wrong.transaction_id = wrong.command_digest
        assert_request_invalid('query_character_transaction', wrong)

        wrong = deep_copy(request)
        wrong.transaction_id = wrong.expected_result_digest
        assert_request_invalid('query_character_transaction', wrong)

        wrong = deep_copy(request)
        wrong.command.expected_revision =
            wrong.expected_character_save_revision + 1
        wrong.command_digest = command_digest(RENAME, wrong.command)
        assert_request_invalid('query_character_transaction', wrong)

        local created_identity_reuse = {
            function(query)
                return query.receipt_id
            end,
            function(query)
                return query.original_request_key
            end,
            function(query)
                return query.transaction_id
            end,
        }
        local identity_index
        for identity_index = 1, #created_identity_reuse do
            wrong = deep_copy(request)
            wrong.command.created_receipt_id =
                created_identity_reuse[identity_index](wrong)
            wrong.command_digest = command_digest(RENAME, wrong.command)
            assert_request_invalid('query_character_transaction', wrong)
        end

        local value = query_value(request, 'NOT_FOUND', commit_request)
        value.result = deep_copy(commit_request.result)
        assert_success_invalid('query_character_transaction', value, request)

        value = query_value(request, 'NOT_FOUND', commit_request)
        local other_expected = deep_copy(request)
        other_expected.expected_result_digest = string.rep('d', 64)
        assert_success_invalid(
            'query_character_transaction',
            value,
            other_expected
        )

        value = query_value(request, 'COMMITTED', commit_request)
        value.receipt_id = 'character:rename:other_receipt'
        assert_success_invalid('query_character_transaction', value, request)

        value = query_value(request, 'COMMITTED', commit_request)
        value.transaction_id = 'other_atomic_tx_001'
        assert_success_invalid('query_character_transaction', value, request)

        value = query_value(request, 'COMMITTED', commit_request)
        value.result.new_name = '被篡改'
        assert_success_invalid('query_character_transaction', value, request)

        value = query_value(request, 'COMMITTED', commit_request)
        value.result.new_name = 'another_valid_name'
        value.result_digest = result_digest(RENAME, value.result)
        assert_success_invalid('query_character_transaction', value, request)
    end),

    case('commit error allowlist is closed', function()
        local request = create_insert_request()
        local allowed = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_READ_ONLY', {
                reason = 'PLAYER_CHARACTER_SECTION_READ_ONLY',
                request_key = request.context.idempotency_key,
            }, false),
            request
        )
        assert.error_code(allowed, 'SAVE_READ_ONLY')

        local denied = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('UNDECLARED_CHARACTER_ERROR', {
                request_key = request.context.idempotency_key,
            }, false),
            request
        )
        assert.error_code(denied, 'PORT_RESULT_INVALID')
    end),

    case('read-only completions reject unscoped cause detail leaks', function()
        local load_request = {
            context = read_context('load_error'),
            player_save_scope = 'player001',
            character_id = 'char_protagonist',
        }
        local query = query_request(experience_request(false))
        local scenarios = {
            {
                operation = 'load_character',
                request = load_request,
                code = 'PLATFORM_RATE_LIMITED',
                details = {
                    cause_code = 'SAVE_STORE_SLOT_FAILURE',
                },
            },
            {
                operation = 'query_character_transaction',
                request = query,
                code = 'PORT_ADAPTER_FAILED',
                details = {
                    cause_code = 'SAVE_STORE_SLOT_FAILURE',
                },
            },
            {
                operation = 'load_character',
                request = load_request,
                code = 'PLATFORM_UNAVAILABLE',
                details = {
                    reason = 'FAKE_INJECTED_UNAVAILABLE',
                    cause_code = 'SAVE_STORE_SLOT_FAILURE',
                },
            },
        }
        local index
        for index = 1, #scenarios do
            local scenario = scenarios[index]
            local checked = CharacterRepository:validate_result(
                scenario.operation,
                PortContract.error(
                    scenario.code,
                    scenario.details,
                    false
                ),
                scenario.request,
                'COMPLETION'
            )
            assert.error_code(checked, 'PORT_RESULT_INVALID')
        end
    end),

    case('error validators bind phase recovery and exact detail fields', function()
        local request = create_insert_request()
        local admission = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_READ_ONLY', {
                reason = 'PLAYER_CHARACTER_SECTION_READ_ONLY',
            }, false),
            request,
            'ADMISSION'
        )
        assert.error_code(admission, 'SAVE_READ_ONLY')

        local wrong_admission_key = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_READ_ONLY', {
                reason = 'PLAYER_CHARACTER_SECTION_READ_ONLY',
                request_key = string.rep('f', 64),
            }, false),
            request,
            'ADMISSION'
        )
        assert.error_code(wrong_admission_key, 'PORT_RESULT_INVALID')

        local wrong_admission_revision = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_REVISION_CONFLICT', {
                expected_character_save_revision = 1,
            }, false),
            request,
            'ADMISSION'
        )
        assert.error_code(wrong_admission_revision, 'PORT_RESULT_INVALID')

        local completion = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_REVISION_CONFLICT', {
                request_key = request.context.idempotency_key,
                expected_character_save_revision = 0,
                actual_character_save_revision = 1,
                actual_receipt_save_revision = 1,
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(completion, 'SAVE_REVISION_CONFLICT')

        local isolated_read_only = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_READ_ONLY', {
                reason = 'CHARACTER_READ_ONLY_ISOLATED',
                request_key = request.context.idempotency_key,
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(isolated_read_only, 'SAVE_READ_ONLY')

        local recovery_admission = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('TRANSACTION_RECOVERY_REQUIRED', {
                reason = 'EARLIER_CHARACTER_TRANSACTION_UNRESOLVED',
            }, false),
            request,
            'ADMISSION'
        )
        assert.error_code(
            recovery_admission,
            'TRANSACTION_RECOVERY_REQUIRED'
        )

        local blind_recovery_admission = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('TRANSACTION_RECOVERY_REQUIRED', {
                reason = 'EARLIER_CHARACTER_TRANSACTION_UNRESOLVED',
                recovery = 'BLIND_RETRY',
            }, false),
            request,
            'ADMISSION'
        )
        assert.error_code(
            blind_recovery_admission,
            'PORT_RESULT_INVALID'
        )

        local recovery_details = {
            reason = 'EARLIER_CHARACTER_TRANSACTION_UNRESOLVED',
            request_key = request.context.idempotency_key,
            recovery = 'QUERY_OR_RECONCILE',
            receipt_id = request.receipt_id,
            transaction_id = request.transaction_id,
        }
        local recovery_completion = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error(
                'TRANSACTION_RECOVERY_REQUIRED',
                recovery_details,
                false
            ),
            request,
            'COMPLETION'
        )
        assert.error_code(
            recovery_completion,
            'TRANSACTION_RECOVERY_REQUIRED'
        )

        local retryable_recovery = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error(
                'TRANSACTION_RECOVERY_REQUIRED',
                recovery_details,
                true
            ),
            request,
            'COMPLETION'
        )
        assert.error_code(retryable_recovery, 'PORT_RESULT_INVALID')

        local fields = { 'arbitrary', 'slot', 'envelope', 'store' }
        local index
        for index = 1, #fields do
            local details = {
                reason = 'PLAYER_CHARACTER_SECTION_READ_ONLY',
                request_key = request.context.idempotency_key,
            }
            details[fields[index]] = 'raw'
            local leaked = CharacterRepository:validate_result(
                'commit_character_transaction',
                PortContract.error('SAVE_READ_ONLY', details, false),
                request,
                'COMPLETION'
            )
            assert.error_code(leaked, 'PORT_RESULT_INVALID')
        end

        local missing_key = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_READ_ONLY', {
                reason = 'PLAYER_CHARACTER_SECTION_READ_ONLY',
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(missing_key, 'PORT_RESULT_INVALID')

        local valid_unknown = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('PLATFORM_RESULT_UNKNOWN', {
                reason = 'COMPLETION_RESULT_UNKNOWN',
                request_key = request.context.idempotency_key,
                recovery = 'QUERY_OR_RECONCILE',
                cause_code = 'ADAPTER_COMPLETION_AMBIGUOUS',
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(valid_unknown, 'PLATFORM_RESULT_UNKNOWN')

        local generated_unknowns = {
            {
                'COMPLETION_REQUEST_KEY_MISMATCH',
                'PORT_RESULT_INVALID',
            },
            {
                'ACCEPTED_MUTATION_HAS_AMBIGUOUS_PLATFORM_ERROR',
                'PLATFORM_UNAVAILABLE',
            },
            {
                'INTERNAL_ERROR_IS_NOT_PLATFORM_CONCLUSION',
                'FAKE_SCRIPT_INVALID',
            },
            {
                'CALLBACK_RESULT_CONTRACT_INVALID',
                'PORT_RESULT_INVALID',
            },
        }
        for index = 1, #generated_unknowns do
            local entry = generated_unknowns[index]
            local normalized = CharacterRepository:validate_result(
                'commit_character_transaction',
                PortContract.error('PLATFORM_RESULT_UNKNOWN', {
                    reason = entry[1],
                    request_key = request.context.idempotency_key,
                    recovery = 'QUERY_OR_RECONCILE',
                    cause_code = entry[2],
                }, false),
                request,
                'COMPLETION'
            )
            assert.error_code(normalized, 'PLATFORM_RESULT_UNKNOWN')
        end

        local missing_recovery = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('PLATFORM_RESULT_UNKNOWN', {
                reason = 'COMPLETION_RESULT_UNKNOWN',
                request_key = request.context.idempotency_key,
                cause_code = 'ADAPTER_COMPLETION_AMBIGUOUS',
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(missing_recovery, 'PORT_RESULT_INVALID')

        local missing_cause = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('PLATFORM_RESULT_UNKNOWN', {
                reason = 'COMPLETION_RESULT_UNKNOWN',
                request_key = request.context.idempotency_key,
                recovery = 'QUERY_OR_RECONCILE',
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(missing_cause, 'PORT_RESULT_INVALID')

        local leaking_cause = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('PLATFORM_RESULT_UNKNOWN', {
                reason = 'COMPLETION_RESULT_UNKNOWN',
                request_key = request.context.idempotency_key,
                recovery = 'QUERY_OR_RECONCILE',
                cause_code = 'SAVE' .. '_STORE_SLOT_FAILURE',
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(leaking_cause, 'PORT_RESULT_INVALID')

        local missing_conflict_fields = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_REVISION_CONFLICT', {
                request_key = request.context.idempotency_key,
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(missing_conflict_fields, 'PORT_RESULT_INVALID')

        local wrong_conflict_revision = CharacterRepository:validate_result(
            'commit_character_transaction',
            PortContract.error('SAVE_REVISION_CONFLICT', {
                request_key = request.context.idempotency_key,
                expected_character_save_revision = 1,
                actual_character_save_revision = 2,
                actual_receipt_save_revision = 2,
            }, false),
            request,
            'COMPLETION'
        )
        assert.error_code(wrong_conflict_revision, 'PORT_RESULT_INVALID')

        local retryable_errors = {
            PortContract.error('SAVE_READ_ONLY', {
                reason = 'CHARACTER_READ_ONLY_ISOLATED',
                request_key = request.context.idempotency_key,
            }, true),
            PortContract.error('SAVE_REVISION_CONFLICT', {
                request_key = request.context.idempotency_key,
                expected_character_save_revision = 0,
                actual_character_save_revision = 1,
                actual_receipt_save_revision = 1,
            }, true),
            PortContract.error('IDEMPOTENCY_KEY_REUSED', {
                reason = 'BUSINESS_RECEIPT_IDENTITY_MISMATCH',
                receipt_id = request.receipt_id,
                request_key = request.context.idempotency_key,
            }, true),
        }
        for index = 1, #retryable_errors do
            local retried = CharacterRepository:validate_result(
                'commit_character_transaction',
                retryable_errors[index],
                request,
                'COMPLETION'
            )
            assert.error_code(retried, 'PORT_RESULT_INVALID')
        end

        local query = query_request(experience_request(false))
        query.context.idempotency_key = transport_key(
            'character:query:optional_context_001'
        )
        assert_request_ok('query_character_transaction', query)
        local query_reuse = CharacterRepository:validate_result(
            'query_character_transaction',
            PortContract.error('IDEMPOTENCY_KEY_REUSED', {
                reason = 'CHARACTER_TRANSACTION_IDENTITY_MISMATCH',
                player_save_scope = query.player_save_scope,
                original_request_key = query.original_request_key,
                receipt_id = query.receipt_id,
                transaction_id = query.transaction_id,
                operation_type = query.operation_type,
                command_digest = query.command_digest,
                expected_result_digest = query.expected_result_digest,
                expected_character_save_revision =
                    query.expected_character_save_revision,
            }, false),
            query,
            'COMPLETION'
        )
        assert.error_code(query_reuse, 'IDEMPOTENCY_KEY_REUSED')

        query = query_request(experience_request(false))
        query.context.idempotency_key = 'query_key_001'
        assert_request_ok('query_character_transaction', query)
        local query_unknown = CharacterRepository:validate_result(
            'query_character_transaction',
            PortContract.error('PLATFORM_RESULT_UNKNOWN', {
                reason = 'COMPLETION_RESULT_UNKNOWN',
                request_key = query.context.idempotency_key,
                recovery = 'QUERY_OR_RECONCILE',
                cause_code = 'ADAPTER_COMPLETION_AMBIGUOUS',
            }, false),
            query,
            'COMPLETION'
        )
        assert.error_code(query_unknown, 'PLATFORM_RESULT_UNKNOWN')

        local wrong_query_key = CharacterRepository:validate_result(
            'query_character_transaction',
            PortContract.error('PLATFORM_RESULT_UNKNOWN', {
                reason = 'COMPLETION_RESULT_UNKNOWN',
                request_key = query.original_request_key,
                recovery = 'QUERY_OR_RECONCILE',
                cause_code = 'ADAPTER_COMPLETION_AMBIGUOUS',
            }, false),
            query,
            'COMPLETION'
        )
        assert.error_code(wrong_query_key, 'PORT_RESULT_INVALID')

        query = query_request(experience_request(false))
        query_unknown = CharacterRepository:validate_result(
            'query_character_transaction',
            PortContract.error('PLATFORM_RESULT_UNKNOWN', {
                reason = 'COMPLETION_RESULT_UNKNOWN',
                request_key = query.original_request_key,
                recovery = 'QUERY_OR_RECONCILE',
                cause_code = 'ADAPTER_COMPLETION_AMBIGUOUS',
            }, false),
            query,
            'COMPLETION'
        )
        assert.error_code(query_unknown, 'PLATFORM_RESULT_UNKNOWN')

        local forbidden_reasons = {
            'ARBITRARY_FREE_TEXT',
            'PLAYER_CHARACTER_' .. 'SAVE' .. '_STORE_DETAIL',
            'PLAYER_CHARACTER_' .. 'SLOT' .. '_ID_DETAIL',
            'PLAYER_CHARACTER_' .. 'SAVE' .. '_ENVELOPE_DETAIL',
        }
        for index = 1, #forbidden_reasons do
            local leaked_reason = CharacterRepository:validate_result(
                'commit_character_transaction',
                PortContract.error('SAVE_READ_ONLY', {
                    reason = forbidden_reasons[index],
                    request_key = request.context.idempotency_key,
                }, false),
                request,
                'COMPLETION'
            )
            assert.error_code(leaked_reason, 'PORT_RESULT_INVALID')
        end
    end),

    case('guard normalizes malicious recovery details to safe unknown', function()
        local pending
        local received
        local request = create_insert_request()
        local implementation = {
            load_character = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
            commit_character_transaction = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
            query_character_transaction = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
        }
        local guarded = CharacterRepository:guard_implementation(implementation)
        assert.equal(guarded.ok, true)
        local admission = guarded.value:commit_character_transaction(
            request,
            function(result)
                received = result
            end
        )
        assert.equal(admission.ok, true)
        assert.equal(admission.value.accepted, true)
        assert.is_nil(received)

        assert.equal(pending(PortContract.error(
            'TRANSACTION_RECOVERY_REQUIRED',
            {
                request_key = request.context.idempotency_key,
                reason = 'RECOVERY_DETAIL_LEAK_ATTEMPT',
                slot = 3,
            },
            true
        )), true)
        assert.error_code(received, 'PLATFORM_RESULT_UNKNOWN')
        assert.equal(received.error.retryable, false)
        assert.equal(
            received.error.details.request_key,
            request.context.idempotency_key
        )
        assert.equal(
            received.error.details.recovery,
            'QUERY_OR_RECONCILE'
        )
        assert.equal(received.error.details.cause_code, 'PORT_RESULT_INVALID')
        assert.is_nil(received.error.details.slot)
    end),

    case('guard closes wrong query completion keys with self-validating errors', function()
        local pending
        local received
        local implementation = {
            load_character = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
            commit_character_transaction = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
            query_character_transaction = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
        }
        local guarded = CharacterRepository:guard_implementation(implementation)
        assert.equal(guarded.ok, true)
        local request = query_request(experience_request(false))
        request.context.idempotency_key = 'query_key_001'
        local admission = guarded.value:query_character_transaction(
            request,
            function(result)
                received = result
            end
        )
        assert.equal(admission.ok, true)
        assert.is_nil(received)
        assert.equal(pending(PortContract.error('PLATFORM_RESULT_UNKNOWN', {
            reason = 'COMPLETION_RESULT_UNKNOWN',
            request_key = request.original_request_key,
            recovery = 'QUERY_OR_RECONCILE',
            cause_code = 'ADAPTER_COMPLETION_AMBIGUOUS',
        }, false)), true)
        assert.error_code(received, 'PORT_RESULT_INVALID')
        assert.is_nil(received.error.details)
        assert.error_code(
            CharacterRepository:validate_result(
                'query_character_transaction',
                received,
                request,
                'COMPLETION'
            ),
            'PORT_RESULT_INVALID'
        )
    end),

    case('guard converts accepted mutation identity mismatch to unknown', function()
        local pending
        local implementation = {
            load_character = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
            commit_character_transaction = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
            query_character_transaction = function(_, _, complete)
                pending = complete
                return PortContract.ok({ accepted = true })
            end,
        }
        local guarded = CharacterRepository:guard_implementation(implementation)
        assert.equal(guarded.ok, true)
        local request = create_insert_request()
        local received
        local admission = guarded.value:commit_character_transaction(
            request,
            function(result)
                received = result
            end
        )
        assert.equal(admission.ok, true)
        assert.equal(admission.value.accepted, true)
        assert.is_nil(received)

        local value = commit_success(request)
        value.request_key = 'wrong_key'
        assert.equal(pending(PortContract.ok(value)), true)
        assert.error_code(received, 'PLATFORM_RESULT_UNKNOWN')
        assert.equal(received.error.retryable, false)
        assert.equal(received.error.details.recovery, 'QUERY_OR_RECONCILE')
        assert.equal(
            received.error.details.request_key,
            request.context.idempotency_key
        )
    end),

    case('guard rejects inline mutation completion without leaking callback', function()
        local request = create_insert_request()
        local callback_count = 0
        local implementation = {
            load_character = function()
                return PortContract.ok({ accepted = true })
            end,
            commit_character_transaction = function(_, _, complete)
                complete(PortContract.ok(commit_success(request)))
                return PortContract.ok({ accepted = true })
            end,
            query_character_transaction = function()
                return PortContract.ok({ accepted = true })
            end,
        }
        local guarded = CharacterRepository:guard_implementation(implementation)
        assert.equal(guarded.ok, true)
        local admission = guarded.value:commit_character_transaction(
            request,
            function()
                callback_count = callback_count + 1
            end
        )
        assert.error_code(admission, 'PLATFORM_RESULT_UNKNOWN')
        assert.equal(callback_count, 0)
        assert.equal(admission.error.details.recovery, 'QUERY_OR_RECONCILE')
        assert.equal(
            admission.error.details.request_key,
            request.context.idempotency_key
        )
        local self_checked = CharacterRepository:validate_result(
            'commit_character_transaction',
            admission,
            request,
            'ADMISSION'
        )
        assert.error_code(self_checked, 'PLATFORM_RESULT_UNKNOWN')
    end),

    case('guard admission failures remain self-validating', function()
        local request = create_insert_request()
        local scenarios = {
            {
                cause_code = 'PORT_ADAPTER_FAILED',
                commit = function()
                    error('injected adapter failure')
                end,
            },
            {
                cause_code = 'PORT_ADAPTER_RETURN_INVALID',
                commit = function()
                    return PortContract.ok({ accepted = false })
                end,
            },
        }
        local index
        for index = 1, #scenarios do
            local scenario = scenarios[index]
            local implementation = {
                load_character = function()
                    return PortContract.ok({ accepted = true })
                end,
                commit_character_transaction = scenario.commit,
                query_character_transaction = function()
                    return PortContract.ok({ accepted = true })
                end,
            }
            local guarded = CharacterRepository:guard_implementation(
                implementation
            )
            assert.equal(guarded.ok, true)
            local outward = guarded.value:commit_character_transaction(
                request,
                function()
                    error('callback must not run')
                end
            )
            assert.error_code(outward, 'PLATFORM_RESULT_UNKNOWN')
            assert.equal(
                outward.error.details.cause_code,
                scenario.cause_code
            )
            local self_checked = CharacterRepository:validate_result(
                'commit_character_transaction',
                outward,
                request,
                'ADMISSION'
            )
            assert.error_code(self_checked, 'PLATFORM_RESULT_UNKNOWN')
            local required_identity_fields = {
                'request_key',
                'recovery',
            }
            local field_index
            for field_index = 1, #required_identity_fields do
                local malformed = deep_copy(outward)
                malformed.error.details[
                    required_identity_fields[field_index]
                ] = nil
                local rejected = CharacterRepository:validate_result(
                    'commit_character_transaction',
                    malformed,
                    request,
                    'ADMISSION'
                )
                assert.error_code(rejected, 'PORT_RESULT_INVALID')
            end
        end
    end),

    case('hostile nested tables fail closed without invoking metamethods', function()
        local calls = 0
        local function invoked()
            calls = calls + 1
            error('hostile metamethod must not run')
        end
        local function hostile_table()
            return setmetatable({}, {
                __index = invoked,
                __newindex = invoked,
                __pairs = invoked,
                __len = invoked,
                __metatable = 'locked',
            })
        end

        local request = create_insert_request()
        request.command = hostile_table()
        assert_request_invalid('commit_character_transaction', request)
        assert.equal(calls, 0)

        request = create_insert_request()
        local value = commit_success(request)
        value.result = hostile_table()
        assert_success_invalid('commit_character_transaction', value, request)
        assert.equal(calls, 0)
    end),

    case('validators reject unknown fields after global pairs monkeypatch', function()
        local valid_request = create_insert_request()
        local request = deep_copy(valid_request)
        request.slot_id = 3
        local value = commit_success(valid_request)
        value.slot_id = 3
        local original_pairs = pairs
        _G.pairs = function()
            return function()
                return nil
            end
        end
        local ok, raised = pcall(function()
            assert_request_invalid('commit_character_transaction', request)
            assert_success_invalid(
                'commit_character_transaction',
                value,
                valid_request
            )
        end)
        _G.pairs = original_pairs
        if not ok then
            error(raised)
        end
    end),

    case('validators retain captured security dependencies after monkeypatch', function()
        local request = rename_request()
        local create = create_insert_request()
        local success_envelope = PortContract.ok(commit_success(request))
        local originals = {
            canonical_derive = CanonicalReceiptHashV1.derive,
            transport = CharacterReceiptCodec.derive_transport_request_key,
            content = RuntimeId.validate_content,
            derived = RuntimeId.validate_derived,
            component = RuntimeId.validate_component,
            reference = RuntimeId.validate_source_reference,
            talent_digest = TalentListDigest.derive,
            utf8 = Utf8Text.is_valid,
            math_floor = math.floor,
            string_match = string.match,
        }
        local function hostile()
            error('monkeypatched dependency must not be invoked')
        end
        CanonicalReceiptHashV1.derive = hostile
        CharacterReceiptCodec.derive_transport_request_key = hostile
        RuntimeId.validate_content = hostile
        RuntimeId.validate_derived = hostile
        RuntimeId.validate_component = hostile
        RuntimeId.validate_source_reference = hostile
        TalentListDigest.derive = hostile
        Utf8Text.is_valid = hostile
        math.floor = hostile
        string.match = hostile

        local ok, raised = pcall(function()
            assert_request_ok('commit_character_transaction', create)
            assert_request_ok('commit_character_transaction', request)
            local checked = CharacterRepository:validate_result(
                'commit_character_transaction',
                success_envelope,
                request
            )
            assert.equal(checked.ok, true)
        end)

        CanonicalReceiptHashV1.derive = originals.canonical_derive
        CharacterReceiptCodec.derive_transport_request_key = originals.transport
        RuntimeId.validate_content = originals.content
        RuntimeId.validate_derived = originals.derived
        RuntimeId.validate_component = originals.component
        RuntimeId.validate_source_reference = originals.reference
        TalentListDigest.derive = originals.talent_digest
        Utf8Text.is_valid = originals.utf8
        math.floor = originals.math_floor
        string.match = originals.string_match
        if not ok then
            error(raised)
        end
    end),
}
