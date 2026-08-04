local Harness = require 'wzx.tests.harness'
local CombatEvent = require 'wzx.domain.common.combat_event'
local DomainEvent = require 'wzx.domain.common.domain_event'
local TableShape = require 'wzx.domain.common.table_shape'

local case = Harness.case
local assert = Harness.assert

local function hostile_table(metamethod_name, calls)
    local metatable = {}
    if metamethod_name == '__index' then
        metatable.__index = function()
            calls.count = calls.count + 1
            return 'forged'
        end
    elseif metamethod_name == '__pairs' then
        metatable.__pairs = function()
            calls.count = calls.count + 1
            return next, {}, nil
        end
    elseif metamethod_name == '__len' then
        metatable.__len = function()
            calls.count = calls.count + 1
            return 0
        end
    else
        error('unsupported hostile metamethod: ' .. tostring(metamethod_name))
    end
    return setmetatable({ stored = true }, metatable)
end

local function assert_plain_table_rejected(result, expected_path, calls)
    assert.error_code(result, 'TABLE_SHAPE_INVALID')
    assert.error_reason(result, 'PLAIN_TABLE_REQUIRED')
    assert.equal(result.error.details.path, expected_path)
    assert.equal(calls.count, 0)
end

local function domain_event()
    return {
        event_id = 'quest:main:1',
        event_type = 'QuestStarted',
        schema_version = 1,
        aggregate_id = 'quest:main',
        revision = 1,
        occurred_at = 123456,
        correlation_id = 'session1',
        source_occurrence_id = 'occurrence1',
        source_system = '09',
        payload = {
            quest_id = 'quest_main',
        },
    }
end

local function combat_fields(sequence, action_index)
    return {
        combat_id = 'combat001',
        sequence = sequence,
        action_index = action_index,
        event_type = 'DamageApplied',
        schema_version = 1,
        source_system = '06',
        payload = {
            amount = 17,
            target_id = 'unit:defender:1',
        },
    }
end

return {
    case('generic domain events accept only the shared envelope fields', function()
        local event = domain_event()
        local validated = DomainEvent.validate(event)
        assert.equal(validated.ok, true)

        event.combat_id = 'combat001'
        validated = DomainEvent.validate(event)
        assert.error_code(validated, 'DOMAIN_EVENT_INVALID')
        assert.error_reason(validated, 'UNKNOWN_FIELD')

        validated = DomainEvent.validate(event, { allow_specialized_fields = true })
        assert.equal(validated.ok, true)
    end),

    case('domain event validates fact names, revision, source, and payload shape', function()
        local event = domain_event()
        event.event_type = 'quest_started'
        assert.error_reason(DomainEvent.validate(event), 'COMPLETED_FACT_NAME_REQUIRED')

        event = domain_event()
        event.revision = -1
        assert.error_reason(DomainEvent.validate(event), 'NON_NEGATIVE_INTEGER_REQUIRED')

        event = domain_event()
        event.source_system = '9'
        assert.error_reason(DomainEvent.validate(event), 'TWO_DIGIT_SYSTEM_ID_REQUIRED')

        event = domain_event()
        event.payload = { invalid = 1.5 }
        assert.error_reason(DomainEvent.validate(event), 'PAYLOAD_INVALID')

        event = domain_event()
        event.payload = 'quest_main'
        assert.error_reason(DomainEvent.validate(event), 'TABLE_REQUIRED')
    end),

    case('domain event correlation and occurrence IDs are atomic', function()
        local event = domain_event()
        event.correlation_id = 'session:1'
        assert.error_reason(DomainEvent.validate(event), 'IDENTIFIER_INVALID')

        event = domain_event()
        event.source_occurrence_id = 'source:1'
        assert.error_reason(DomainEvent.validate(event), 'IDENTIFIER_INVALID')

        event = domain_event()
        event.causation_id = 'quest:main:0'
        assert.equal(DomainEvent.validate(event).ok, true)
    end),

    case('combat event specialization derives identity and revision from sequence', function()
        local created = CombatEvent.create(combat_fields(7, 3))
        assert.equal(created.ok, true)
        local event = created.value
        assert.equal(event.event_id, 'combat001:7')
        assert.equal(event.aggregate_id, 'combat001')
        assert.equal(event.revision, 7)
        assert.equal(event.sequence, 7)
        assert.is_nil(event.occurred_at)
        assert.equal(CombatEvent.validate(event).ok, true)

        event.revision = 6
        assert.error_reason(CombatEvent.validate(event), 'COMBAT_REVISION_MUST_EQUAL_SEQUENCE')
    end),

    case('combat sequence increments across events in the same action', function()
        local first = CombatEvent.create(combat_fields(10, 4)).value
        local second = CombatEvent.create(combat_fields(11, 4)).value
        local validated = CombatEvent.validate_sequence({ first, second }, 'combat001', 10)
        assert.equal(validated.ok, true)
        assert.equal(validated.value.next_sequence, 12)

        second.sequence = 12
        second.event_id = 'combat001:12'
        second.revision = 12
        validated = CombatEvent.validate_sequence({ first, second }, 'combat001', 10)
        assert.error_reason(validated, 'EVENT_SEQUENCE_GAP')

        assert.error_reason(
            CombatEvent.validate_sequence({}, 'combat:derived', 1),
            'ATOMIC_COMBAT_ID_REQUIRED'
        )
        assert.error_reason(
            CombatEvent.validate_sequence({}, 'combat001', 0),
            'POSITIVE_INTEGER_REQUIRED'
        )
    end),

    case('combat events reject timestamps and mismatched combat identity', function()
        local event = CombatEvent.create(combat_fields(1, 0)).value
        event.occurred_at = 1
        assert.error_code(CombatEvent.validate(event), 'COMBAT_EVENT_INVALID')
        assert.error_reason(CombatEvent.validate(event), 'FIELD_MUST_BE_ABSENT')

        event = CombatEvent.create(combat_fields(1, 0)).value
        event.event_id = 'other:1'
        assert.error_reason(CombatEvent.validate(event), 'COMBAT_EVENT_ID_MISMATCH')

        event = CombatEvent.create(combat_fields(1, 0)).value
        event.aggregate_id = 'other'
        assert.error_reason(CombatEvent.validate(event), 'COMBAT_AGGREGATE_ID_MISMATCH')

        local invalid_fields = combat_fields(1, 0)
        invalid_fields.combat_id = 'combat:001'
        assert.error_reason(
            CombatEvent.create(invalid_fields),
            'ATOMIC_COMBAT_ID_REQUIRED'
        )

        invalid_fields = combat_fields(1, 0)
        invalid_fields.payload = false
        assert.error_reason(
            CombatEvent.create(invalid_fields),
            'DOMAIN_EVENT_ENVELOPE_INVALID'
        )

        invalid_fields = combat_fields(1, 100)
        assert.error_reason(
            CombatEvent.create(invalid_fields),
            'ACTION_INDEX_OUT_OF_RANGE'
        )
    end),

    case('table shape enforces exact table depth and detects active cycles', function()
        local depth_two = {
            child = {
                value = 1,
            },
        }
        assert.equal(TableShape.validate_serializable(depth_two, 2).ok, true)

        local depth_three = {
            child = {
                grandchild = {
                    value = 1,
                },
            },
        }
        local validated = TableShape.validate_serializable(depth_three, 2)
        assert.error_code(validated, 'TABLE_SHAPE_INVALID')
        assert.error_reason(validated, 'MAXIMUM_TABLE_DEPTH_EXCEEDED')
        assert.equal(validated.error.details.path, '$.child.grandchild')

        local cycle = {}
        cycle.self = cycle
        validated = TableShape.validate_serializable(cycle, 4)
        assert.error_reason(validated, 'TABLE_CYCLE_DETECTED')
        assert.equal(validated.error.details.path, '$.self')
    end),

    case('table shape rejects lossy values and deep copy is isolated', function()
        assert.error_reason(
            TableShape.validate_serializable({ fractional = 1.5 }, 2),
            'INTEGER_REQUIRED'
        )
        assert.error_reason(
            TableShape.validate_serializable({ callback = function() end }, 2),
            'SERIALIZABLE_VALUE_REQUIRED'
        )
        assert.error_reason(
            TableShape.validate_serializable({ [0] = 'invalid' }, 2),
            'NON_EMPTY_STRING_MAP_KEY_REQUIRED'
        )

        local source = { nested = { value = 7 }, list = { 1, 2 } }
        local copied = TableShape.deep_copy_serializable(source, 3)
        assert.equal(copied.ok, true)
        assert.truthy(copied.value ~= source)
        assert.truthy(copied.value.nested ~= source.nested)
        copied.value.nested.value = 99
        assert.equal(source.nested.value, 7)
    end),

    case('table shape rejects hostile root metatables without invoking them', function()
        local metamethods = { '__index', '__pairs', '__len' }
        local index
        for index = 1, #metamethods do
            local calls = { count = 0 }
            local value = hostile_table(metamethods[index], calls)

            assert_plain_table_rejected(
                TableShape.validate_serializable(value, 3),
                '$',
                calls
            )
            assert_plain_table_rejected(
                TableShape.deep_copy_serializable(value, 3),
                '$',
                calls
            )
        end
    end),

    case('table shape rejects hostile nested metatables without invoking them', function()
        local metamethods = { '__index', '__pairs', '__len' }
        local index
        for index = 1, #metamethods do
            local calls = { count = 0 }
            local value = {
                nested = hostile_table(metamethods[index], calls),
            }

            assert_plain_table_rejected(
                TableShape.validate_serializable(value, 3),
                '$.nested',
                calls
            )
            assert_plain_table_rejected(
                TableShape.deep_copy_serializable(value, 3),
                '$.nested',
                calls
            )
        end
    end),
}
